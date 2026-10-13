#include <gtest/gtest.h>
#include <nlohmann/json.hpp>

#include "Audio/SoundManager.h"
#include "Interface/IShaderValueUpdater.h"
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneLayerReference.hpp"
#include "SpecTexs.hpp"
#include "WPSceneParser.hpp"
#include "VulkanRender/CopyPass.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "RenderGraph/RenderGraph.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace
{
using namespace wallpaper;

class MemoryFs final : public fs::Fs {
public:
    explicit MemoryFs(std::map<std::string, std::string> files): m_files(std::move(files)) {}

    bool Contains(std::string_view path) const override {
        return m_files.contains(std::string(path));
    }

    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        const auto it = m_files.find(std::string(path));
        if (it == m_files.end()) return nullptr;
        const auto& s = it->second;
        return std::make_shared<fs::MemBinaryStream>(std::vector<uint8_t>(s.begin(), s.end()));
    }

    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    std::map<std::string, std::string> m_files;
};

constexpr std::string_view kVert = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
constexpr std::string_view kFrag = R"(uniform sampler2D g_Texture0;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord);
}
)";

std::string SceneJson(std::string_view objects) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":64,"height":32}
      },
      "objects": )") + std::string(objects) + "}";
}

void MountFiles(fs::VFS& vfs, std::map<std::string, std::string> extra = {}) {
    auto files = std::map<std::string, std::string> {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["solid"]}]})" },
        { "/linked.json", R"({"width":64,"height":32,"material":"linked_mat.json"})" },
        { "/shaders/genericimage.vert", std::string(kVert) },
        { "/shaders/genericimage.frag", std::string(kFrag) },
        { "/materials/solid.tex", "" },
    };
    for (auto& [path, content] : extra) files[path] = std::move(content);
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

std::shared_ptr<Scene> ParseScene(fs::VFS& vfs, std::string_view objects,
                                  std::map<std::string, std::string> extra = {}) {
    MountFiles(vfs, std::move(extra));
    audio::SoundManager sound;
    WPSceneParser       parser;
    return parser.Parse("layer-texture", SceneJson(objects), vfs, sound);
}

const vulkan::CustomShaderPass* FindPassByNode(
    const rg::RenderGraph& graph, std::string_view name) {
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const vulkan::CustomShaderPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().node != nullptr &&
            pass->desc().node->Name() == name) {
            return pass;
        }
    }
    return nullptr;
}

size_t PassIndexByNode(const rg::RenderGraph& graph, std::string_view name) {
    size_t index = 0;
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const vulkan::CustomShaderPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().node != nullptr &&
            pass->desc().node->Name() == name) {
            return index;
        }
        ++index;
    }
    return static_cast<size_t>(-1);
}

const vulkan::CopyPass* FindLinkCopy(const rg::RenderGraph& graph, std::string_view dst) {
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const vulkan::CopyPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().dst == dst) return pass;
    }
    return nullptr;
}

const vulkan::CustomShaderPass* FindPassByOutput(const rg::RenderGraph& graph,
                                                 std::string_view output) {
    const vulkan::CustomShaderPass* found = nullptr;
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const vulkan::CustomShaderPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().output == output) found = pass;
    }
    return found;
}

// A 64x32 canvas with camera parallax on, so a test can move the cursor and see
// whether the shift reaches an image it must not.
std::string ParallaxSceneJson(std::string_view objects) {
    return std::string(R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0.2,0.2,0.2], "skylightcolor":[0.3,0.3,0.3],
        "clearcolor":[0,0,0], "cameraparallax":true,
        "cameraparallaxamount":1, "cameraparallaxdelay":0.1,
        "cameraparallaxmouseinfluence":1,
        "orthogonalprojection":{"width":64,"height":32}
      },
      "objects": )") + std::string(objects) + "}";
}

std::map<std::string, std::string> CopyEffectFiles() {
    return {
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"materials/copy.json"}]})" },
        { "/materials/copy.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]} )" },
    };
}

void AddScreenTarget(Scene& scene) {
    scene.renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width = 64, .height = 32, .allowReuse = true,
    };
}

/// Asks the value updater, as a backend does before drawing `pass`, for the
/// uniforms named in `wanted`, through the camera the pass draws with.
std::map<std::string, ShaderValue, std::less<>> PassUniforms(
    Scene& scene, const vulkan::CustomShaderPass& pass, std::vector<std::string_view> wanted) {
    auto*          node = pass.desc().node;
    const uint32_t slot = pass.desc().material_slot;
    auto&          updater = *scene.shaderValueUpdater;
    updater.InitUniforms(node, slot, [&wanted](std::string_view name) {
        return std::find(wanted.begin(), wanted.end(), name) != wanted.end();
    });
    const std::string camera = node->Camera();
    if (! pass.desc().camera_override.empty()) node->SetCamera(pass.desc().camera_override);
    sprite_map_t                                    sprites;
    std::map<std::string, ShaderValue, std::less<>> values;
    updater.UpdateUniforms(node, slot, sprites, [&values](std::string_view name, const ShaderValue& v) {
        values[std::string(name)] = v;
    });
    node->SetCamera(camera);
    return values;
}

/// Where `pass` puts a corner of its card, in normalised device coordinates.
Eigen::Vector2d CardCornerNdc(Scene& scene, const vulkan::CustomShaderPass& pass,
                              Eigen::Vector2d corner) {
    const auto uniforms = PassUniforms(scene, pass, { "g_ModelViewProjectionMatrix" });
    const auto found    = uniforms.find("g_ModelViewProjectionMatrix");
    if (found == uniforms.end() || found->second.size() != 16) {
        ADD_FAILURE() << "the pass was given no model-view-projection matrix";
        return Eigen::Vector2d::Constant(std::nan(""));
    }
    const Eigen::Matrix4f mvp  = Eigen::Map<const Eigen::Matrix4f>(found->second.data());
    const Eigen::Vector4f clip = mvp * Eigen::Vector4f(corner.x(), corner.y(), 0.0f, 1.0f);
    return { clip.x() / clip.w(), clip.y() / clip.w() };
}

void ExpectCardFillsItsTarget(Scene& scene, const vulkan::CustomShaderPass& pass,
                              Eigen::Vector2d half_extent) {
    const auto lower_left  = CardCornerNdc(scene, pass, -half_extent);
    const auto upper_right = CardCornerNdc(scene, pass, half_extent);
    EXPECT_NEAR(lower_left.x(), -1.0, 1e-4);
    EXPECT_NEAR(lower_left.y(), -1.0, 1e-4);
    EXPECT_NEAR(upper_right.x(), 1.0, 1e-4);
    EXPECT_NEAR(upper_right.y(), 1.0, 1e-4);
}

} // namespace

TEST(LayerTextureReference, CompositeIdIsTheAuthoredSyntax) {
    LayerCompositeSlot slot = LayerCompositeSlot::None;
    const auto         id   = ParseImageLayerCompositeId("_rt_imageLayerComposite_14942_a", &slot);
    ASSERT_TRUE(id.has_value());
    EXPECT_EQ(*id, 14942);
    EXPECT_EQ(slot, LayerCompositeSlot::A);
    EXPECT_EQ(ParseImageLayerCompositeId("_rt_imageLayerComposite_14942_b", &slot).value_or(0),
              14942);
    EXPECT_EQ(slot, LayerCompositeSlot::B);
    EXPECT_TRUE(ParseImageLayerCompositeId("_rt_imageLayerComposite_159").has_value());
}

TEST(LayerTextureReference, ForwardReferenceResolvesById) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":160,"name":"consumer","image":"linked.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_159_a"]}]}]},
      {"id":159,"name":"source","image":"image.json"}
    ])");
    const auto index = BuildLayerObjectIndex(objects);
    auto       resolved =
        ResolveLayerTextureName("_rt_imageLayerComposite_159_a", index, nullptr);
    EXPECT_TRUE(resolved.is_layer);
    EXPECT_EQ(resolved.source_id, 159);
    EXPECT_TRUE(resolved.error.empty());
    EXPECT_EQ(resolved.resolved, GenLinkTex(159));
}

TEST(LayerTextureReference, DuplicateNameIsExplicit) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":1,"name":"dup","image":"image.json"},
      {"id":2,"name":"dup","image":"image.json"}
    ])");
    const auto index    = BuildLayerObjectIndex(objects);
    auto       resolved = ResolveLayerTextureName("dup", index, nullptr);
    EXPECT_TRUE(resolved.is_layer);
    EXPECT_EQ(resolved.error, kLayerTextureDuplicateName);
    EXPECT_NE(resolved.resolved, GenLinkTex(1));
}

TEST(LayerTextureReference, MissingTargetIsExplicit) {
    const auto objects = nlohmann::json::parse(R"([{"id":1,"name":"only","image":"image.json"}])");
    const auto index   = BuildLayerObjectIndex(objects);
    auto       resolved =
        ResolveLayerTextureName("_rt_imageLayerComposite_99_a", index, nullptr);
    EXPECT_TRUE(resolved.is_layer);
    EXPECT_EQ(resolved.error, kLayerTextureMissingTarget);
}

TEST(LayerTextureReference, CycleIsExplicit) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":1,"name":"a","image":"image.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_2_a"]}]}]},
      {"id":2,"name":"b","image":"image.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_1_a"]}]}]}
    ])");
    const auto index = BuildLayerObjectIndex(objects);
    const auto refs  = CollectLayerTextureRefs(objects, index, nullptr);
    EXPECT_EQ(ClassifyLayerTextureReferences(refs, index), kLayerTextureIllegalCycle);
}

TEST(LayerTextureReference, SelfBIsHistoryFeedback) {
    const auto objects = nlohmann::json::parse(R"([
      {"id":7,"name":"self","image":"image.json",
       "effects":[{"passes":[{"textures":["_rt_imageLayerComposite_7_b"]}]}]}
    ])");
    const auto index = BuildLayerObjectIndex(objects);
    const auto refs  = CollectLayerTextureRefs(objects, index, nullptr);
    EXPECT_EQ(ClassifyLayerTextureReferences(refs, index), kLayerTextureHistoryFeedback);
}

TEST(LayerTextureReference, FileNameIsNotALayerEvenWhenNamesMatch) {
    fs::VFS vfs;
    MountFiles(vfs);
    const auto objects = nlohmann::json::parse(R"([
      {"id":1,"name":"solid","image":"image.json"}
    ])");
    const auto index    = BuildLayerObjectIndex(objects);
    auto       resolved = ResolveLayerTextureName("solid", index, &vfs);
    EXPECT_FALSE(resolved.is_layer);
    EXPECT_EQ(resolved.resolved, "solid");
}

TEST(LayerTextureReference, ParserKeepsInvisibleCompositeSource) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":159,"name":"source","image":"image.json","visible":false},
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]}
      ])",
      {{ "/linked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }});
    ASSERT_NE(parsed, nullptr);
    EXPECT_TRUE(parsed->layer_texture_error.empty());
    EXPECT_TRUE(parsed->layer_texture_sources.contains(159));
    SceneNode* source = nullptr;
    for (auto& child : parsed->sceneGraph->GetChildren()) {
        if (child->Name() == "source") source = child.get();
    }
    ASSERT_NE(source, nullptr);
    EXPECT_FALSE(source->Visible());
    EXPECT_TRUE(source->MustProduce());
}

// A model may tile a layer texture hundreds of times (UVs far outside 0..1).
// Clamping smeared the edge texels into solid bands across it.
TEST(LayerTextureReference, CompositeAddressingFollowsTheSourceLayersClampUvs) {
    const auto wrap_for = [](std::string_view clamp) {
        fs::VFS vfs;
        auto    parsed = ParseScene(vfs, std::string(R"([
            {"id":159,"name":"source","image":"image.json","visible":false)") +
                std::string(clamp) + R"(},
            {"id":160,"name":"consumer","image":"linked.json","dependencies":[159]}
          ])",
          {{ "/linked_mat.json",
             R"({"passes":[{"shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }});
        EXPECT_NE(parsed, nullptr);
        const auto* target =
            parsed == nullptr ? nullptr : parsed->FindRenderTarget(LayerCompositeTargetKey(159));
        EXPECT_NE(target, nullptr);
        return target == nullptr ? std::pair { TextureWrap::REPEAT, TextureWrap::REPEAT }
                                 : std::pair { target->sample.wrapS, target->sample.wrapT };
    };
    const auto clamp  = std::pair { TextureWrap::CLAMP_TO_EDGE, TextureWrap::CLAMP_TO_EDGE };
    const auto repeat = std::pair { TextureWrap::REPEAT, TextureWrap::REPEAT };
    EXPECT_EQ(wrap_for(",\"clampuvs\":false"), repeat);
    EXPECT_EQ(wrap_for(",\"clampuvs\":true"), clamp);
    EXPECT_EQ(wrap_for(""), clamp);
}

TEST(LayerTextureReference, ExternalMaterialsKeepHiddenTransitiveProducers) {
    fs::VFS vfs;
    auto parsed = ParseScene(vfs, R"([
        {"id":159,"name":"source","image":"image.json","visible":false},
        {"id":161,"name":"consumer","image":"outer.json"},
        {"id":160,"name":"middle","image":"linked.json","visible":false}
      ])",
      {{ "/outer.json", R"({"width":64,"height":32,"material":"outer_mat.json"})" },
       { "/outer_mat.json",
         R"({"passes":[{"shader":"genericimage","textures":["_rt_imageLayerComposite_160_a"]}]})" },
       { "/linked_mat.json",
         R"({"passes":[{"shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }});
    ASSERT_NE(parsed, nullptr);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* source = FindPassByNode(*graph, "source");
    const auto* middle = FindPassByNode(*graph, "middle");
    ASSERT_NE(source, nullptr);
    ASSERT_NE(middle, nullptr);
    EXPECT_FALSE(source->desc().node->Visible());
    EXPECT_FALSE(middle->desc().node->Visible());
    EXPECT_EQ(source->desc().output, LayerCompositeTargetKey(159));
    EXPECT_EQ(middle->desc().output, LayerCompositeTargetKey(160));
    EXPECT_LT(PassIndexByNode(*graph, "source"), PassIndexByNode(*graph, "middle"));
    EXPECT_LT(PassIndexByNode(*graph, "middle"), PassIndexByNode(*graph, "consumer"));
}

TEST(LayerTextureReference, ProducerRunsBeforeConsumer) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]},
        {"id":159,"name":"source","image":"image.json","visible":false}
      ])",
      {{ "/linked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }});
    ASSERT_NE(parsed, nullptr);
    parsed->renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width = 64, .height = 32, .allowReuse = true,
    };
    parsed->cameras["effect"] = std::make_shared<SceneCamera>(64, 32, 0.01f, 100.0f);
    parsed->activeCamera      = nullptr;

    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* consumer = FindPassByNode(*graph, "consumer");
    ASSERT_NE(consumer, nullptr);
    ASSERT_FALSE(consumer->desc().textures.empty());
    EXPECT_EQ(consumer->desc().textures[0], GenLinkTex(159));

    const auto source_index   = PassIndexByNode(*graph, "source");
    const auto consumer_index = PassIndexByNode(*graph, "consumer");
    EXPECT_NE(source_index, static_cast<size_t>(-1));
    EXPECT_LT(source_index, consumer_index);

    const auto* link = FindLinkCopy(*graph, GenLinkTex(159));
    ASSERT_NE(link, nullptr);
    EXPECT_NE(link->desc().src, SpecTex_Default);
    EXPECT_EQ(link->desc().src, LayerCompositeTargetKey(159));
}

TEST(LayerTextureReference, EffectChainSourceLinksFromCompositeNotDefault) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":159,"name":"source","image":"image.json","visible":false,
         "effects":[{"file":"effects/copy/effect.json","visible":true}]},
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]}
      ])",
      {{ "/linked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" },
        { "/effects/copy/effect.json",
          R"({"name":"copy","passes":[{"material":"materials/copy.json"}]})" },
        { "/materials/copy.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":[null]}]} )" }});
    ASSERT_NE(parsed, nullptr);
    EXPECT_TRUE(parsed->layer_texture_error.empty());
    EXPECT_TRUE(parsed->layer_texture_sources.contains(159));
    parsed->renderTargets[std::string(SpecTex_Default)] = SceneRenderTarget {
        .width = 64, .height = 32, .allowReuse = true,
    };
    if (parsed->cameras.find("effect") == parsed->cameras.end()) {
        parsed->cameras["effect"] = std::make_shared<SceneCamera>(64, 32, 0.01f, 100.0f);
    }
    parsed->activeCamera = nullptr;

    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* consumer = FindPassByNode(*graph, "consumer");
    ASSERT_NE(consumer, nullptr);
    ASSERT_FALSE(consumer->desc().textures.empty());
    EXPECT_EQ(consumer->desc().textures[0], GenLinkTex(159));

    const auto* link = FindLinkCopy(*graph, GenLinkTex(159));
    ASSERT_NE(link, nullptr) << "the consumer never received a copy of the source composite";
    EXPECT_NE(link->desc().src, SpecTex_Default);
    EXPECT_EQ(link->desc().src, LayerCompositeTargetKey(159));

    const auto* composite = FindPassByOutput(*graph, LayerCompositeTargetKey(159));
    ASSERT_NE(composite, nullptr);
    EXPECT_NE(composite->desc().output, SpecTex_Default);
}

TEST(LayerTextureReference, AnnotationDefaultBindsItsSlotWithoutClaimingTheAuthorBoundIt) {
    // A sampler annotation's `default` exists so an unbound slot still samples
    // something sane. Its `combo` answers a different question -- did the
    // material bind a texture here -- and answering yes from the default turns
    // the shader's optional feature on permanently. `rounded_mask` then reads
    // its corner radius out of a white default instead of `u_Radius` and masks
    // every layer it touches into a circle.
    constexpr std::string_view kMaskFrag = R"(uniform sampler2D g_Texture0;
uniform sampler2D g_Texture1; // {"combo":"MASKED","default":"solid"}
varying vec2 v_TexCoord;
void main() {
#if MASKED
  gl_FragColor = texture(g_Texture1, v_TexCoord);
#else
  gl_FragColor = texture(g_Texture0, v_TexCoord);
#endif
}
)";
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"masked","image":"masked.json"}
      ])",
      {{ "/masked.json", R"({"width":64,"height":32,"material":"masked_mat.json"})" },
       { "/masked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"masked","textures":["solid"]}]})" },
       { "/shaders/masked.vert", std::string(kVert) },
       { "/shaders/masked.frag", std::string(kMaskFrag) }});
    ASSERT_NE(parsed, nullptr);

    SceneNode* node = nullptr;
    for (auto& child : parsed->sceneGraph->GetChildren()) {
        if (child->Name() == "masked") node = child.get();
    }
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);

    // With the combo off the shader takes its `#else` branch, so the authored
    // slot 0 is the one sampled and survives. Reporting the default as an
    // author binding compiles the other branch instead, which stops sampling
    // slot 0 and clears it -- that is what this asserts against.
    ASSERT_FALSE(material->textures.empty());
    EXPECT_EQ(material->textures[0], "solid");
    // The default slot is never read under that branch, so nothing holds a
    // texture it does not sample.
    EXPECT_TRUE(material->textures.size() < 2u || material->textures[1].empty());
    // The `#if MASKED` branch must not have been compiled in, so the pass
    // samples slot 0 the way the author wrote it.
    EXPECT_EQ(std::count(material->defines.begin(), material->defines.end(), "MASKED"), 0);
}

// Another layer samples `_rt_imageLayerComposite_<id>` as the source layer's
// card in that layer's own texture space. Drawn through the scene's camera, the
// composite followed where the layer sat, how far a camera layer zoomed and
// where the cursor pushed it, so a planet assembled from hidden layers slid out
// from under its own mask.
TEST(LayerTextureReference, AReferencedLayerIsItsCardWhereverTheSceneShowsIt) {
    fs::VFS vfs;
    MountFiles(vfs,
               { { "/linked_mat.json",
                   R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" } });
    audio::SoundManager sound;
    WPSceneParser       parser;
    auto                parsed = parser.Parse("layer-composite-camera", ParallaxSceneJson(R"([
        {"id":9,"name":"shot","camera":"default","origin":[8,4,500],
         "angles":[0,0,0],"fov":50,"zoom":2},
        {"id":159,"name":"source","image":"image.json","origin":[20,10,0],
         "scale":[0.5,0.5,1],"parallaxDepth":"1 1","visible":false},
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]}
      ])"),
                                     vfs,
                                     sound);
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    // The cursor in a corner, long enough for the smoothing to arrive: a layer
    // at depth 1 on screen is pushed by parallax now.
    parsed->shaderValueUpdater->MouseInput(1.0, 0.0);
    parsed->frameTime = 1.0;
    parsed->shaderValueUpdater->FrameBegin();

    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* composite = FindPassByOutput(*graph, LayerCompositeTargetKey(159));
    ASSERT_NE(composite, nullptr);
    ExpectCardFillsItsTarget(*parsed, *composite, { 32.0, 16.0 });
    // Nor does the cursor: the composite is not kept out of reuse for parallax.
    EXPECT_FALSE(composite->staticPassDesc(*parsed).dynamic_reasons &
                 vulkan::DynamicReason::PointerUniform);
}

// A layer's composite is copied into its link texture while the graph is
// built, so its size is known only then, and the value updater reports it every
// frame. A zero folded into the material at parse time in its place was divided
// by: in the consumer's card padding, which made every texture coordinate of
// the card NaN, and by `uv * size.z / size.x` wherever a shader maps
// coordinates through it.
TEST(LayerTextureReference, AReferencedCompositeIsSampledAtItsRealSize) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":159,"name":"source","image":"image.json","visible":false},
        {"id":160,"name":"consumer","image":"linked.json","visible":true,
         "dependencies":[159]}
      ])",
      {{ "/linked_mat.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_159_a"]}]})" }});
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* consumer = FindPassByNode(*graph, "consumer");
    ASSERT_NE(consumer, nullptr);
    ASSERT_NE(consumer->desc().node->Mesh(), nullptr);
    const auto* material =
        consumer->desc().node->Mesh()->MaterialForSlot(consumer->desc().material_slot);
    ASSERT_NE(material, nullptr);

    // The consumer's card maps the whole linked image.
    const auto& vertices = consumer->desc().node->Mesh()->GetVertexArray(0);
    const auto  offsets  = vertices.GetAttrOffsetMap();
    const auto  texcoord = offsets.find(std::string(WE_IN_TEXCOORD));
    ASSERT_NE(texcoord, offsets.end());
    for (std::size_t vertex = 0; vertex < vertices.VertexCount(); ++vertex) {
        const float* uv = vertices.Data() + vertex * vertices.OneSize() +
                          texcoord->second.offset / sizeof(float);
        for (int axis = 0; axis < 2; ++axis) {
            EXPECT_TRUE(uv[axis] == 0.0f || uv[axis] == 1.0f)
                << "vertex " << vertex << " axis " << axis << " maps " << uv[axis];
        }
    }

    // A backend declares the link target from the composite as it prepares the
    // copy (CopyPass, ScenePassDescription); this harness prepares none, so it
    // declares it the same way.
    parsed->renderTargets[GenLinkTex(159)] =
        parsed->renderTargets.at(LayerCompositeTargetKey(159));
    const auto live = PassUniforms(*parsed, *consumer, { "g_Texture0Resolution" });
    // The backends upload in opposite orders: Metal writes the material's
    // constants and then the value updater's live values, Vulkan the live
    // values and then the constants. Whichever lands last, the shader must
    // read the composite's real size.
    for (const bool constants_last : { false, true }) {
        SCOPED_TRACE(constants_last ? "constants uploaded last, as Vulkan does"
                                    : "live values uploaded last, as Metal does");
        std::map<std::string, ShaderValue, std::less<>> uploaded;
        const auto upload = [&uploaded](const auto& values) {
            for (const auto& [name, value] : values) uploaded[std::string(name)] = value;
        };
        if (constants_last) {
            upload(live);
            upload(material->customShader.constValues);
        } else {
            upload(material->customShader.constValues);
            upload(live);
        }
        const auto size = uploaded.find("g_Texture0Resolution");
        ASSERT_NE(size, uploaded.end()) << "nothing gives the shader the linked composite's size";
        ASSERT_EQ(size->second.size(), 4u);
        EXPECT_FLOAT_EQ(size->second[0], 64.0f);
        EXPECT_FLOAT_EQ(size->second[1], 32.0f);
    }
}

// A compose layer draws its children into its own target through a camera
// that spans the layer's card, each child where it sits inside the layer. That
// is not a layer-local camera: placing the children at identity would pile them
// all onto the centre of the target.
TEST(LayerTextureReference, ComposeChildrenKeepTheirPlaceInsideTheLayer) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"container","image":"models/util/composelayer.json",
         "size":[64,32],"origin":[32,16,0],"copybackground":false},
        {"id":2,"name":"child","parent":1,"image":"small.json","origin":[10,5,0]}
      ])",
      {{ "/models/util/composelayer.json",
         R"({"passthrough":true,"material":"materials/util/composelayer.json"})" },
       { "/materials/util/composelayer.json",
         R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_FullFrameBuffer"]}]})" },
       { "/materials/util/effectpassthrough.json",
         R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage"}]})" },
       { "/small.json", R"({"width":16,"height":8,"material":"mat.json"})" }});
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* child = FindPassByNode(*graph, "child");
    ASSERT_NE(child, nullptr);

    const auto corner = CardCornerNdc(*parsed, *child, { 8.0, 4.0 });
    EXPECT_NEAR(corner.x(), (10.0 + 8.0) / 32.0, 1e-4);
    EXPECT_NEAR(corner.y(), (5.0 + 4.0) / 16.0, 1e-4);
}

// A compose layer that only copies the background behind it adds nothing on
// screen and used to be skipped outright. A mask drawn after other layers can
// still sample it to paint that background back -- a toggle's clouds clipped to
// its pill -- and then found no texture at all: the layer has to be drawn into
// its composite, and only there, since its card covers its whole target.
TEST(LayerTextureReference, ABareComposeLayerAnotherSamplesIsDrawnOnlyIntoItsComposite) {
    const auto compose_files = [] {
        return std::map<std::string, std::string> {
            { "/models/util/composelayer.json",
              R"({"passthrough":true,"material":"materials/util/composelayer.json"})" },
            { "/materials/util/composelayer.json",
              R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_FullFrameBuffer"]}]})" },
            { "/linked_mat.json",
              R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_89_a"]}]})" },
        };
    };
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"backdrop","image":"image.json"},
        {"id":89,"name":"behind","image":"models/util/composelayer.json",
         "size":[64,32],"origin":[32,16,0]},
        {"id":2,"name":"clouds","image":"image.json"},
        {"id":22,"name":"mask","image":"linked.json","dependencies":[89]}
      ])", compose_files());
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);

    std::vector<std::string> behind_outputs;
    for (const auto id : graph->topologicalOrder()) {
        auto* pass = dynamic_cast<const vulkan::CustomShaderPass*>(graph->getPass(id));
        if (pass != nullptr && pass->desc().node != nullptr &&
            pass->desc().node->Name() == "behind") {
            behind_outputs.push_back(pass->desc().output);
        }
    }
    EXPECT_EQ(behind_outputs, std::vector<std::string> { LayerCompositeTargetKey(89) });

    const auto* mask = FindPassByNode(*graph, "mask");
    ASSERT_NE(mask, nullptr);
    ASSERT_FALSE(mask->desc().textures.empty());
    EXPECT_EQ(mask->desc().textures[0], GenLinkTex(89));
    const auto* link = FindLinkCopy(*graph, GenLinkTex(89));
    ASSERT_NE(link, nullptr) << "the mask was given nothing to sample";
    EXPECT_EQ(link->desc().src, LayerCompositeTargetKey(89));
    EXPECT_LT(PassIndexByNode(*graph, "behind"), PassIndexByNode(*graph, "clouds"));

    // Nobody samples it: it stays out of the graph, as before.
    fs::VFS unused_vfs;
    auto    unused = ParseScene(unused_vfs, R"([
        {"id":1,"name":"backdrop","image":"image.json"},
        {"id":89,"name":"behind","image":"models/util/composelayer.json",
         "size":[64,32],"origin":[32,16,0]}
      ])", compose_files());
    ASSERT_NE(unused, nullptr);
    AddScreenTarget(*unused);
    const auto unused_graph = sceneToRenderGraph(*unused);
    ASSERT_NE(unused_graph, nullptr);
    EXPECT_EQ(FindPassByNode(*unused_graph, "behind"), nullptr);
}

// A wallpaper whose settings offer a choice -- a theme, a language, a date
// format -- usually ships every option as a layer and hides all but the chosen
// one through its properties. Changing a property reloads the scene, so a layer
// they hide cannot appear before the next parse unless a script shows it. Its
// passes, and the effect targets they would allocate, stay out of the graph
// until then; a layer a script drives, or one another layer samples, stays in.
TEST(HiddenLayers, ALayerItsPropertiesHideStaysOutOfTheGraphUntilSomethingShowsIt) {
    const ProjectProperties properties {
        { "light", RuntimeScalarValue::Bool(true) },
        { "dark", RuntimeScalarValue::Bool(false) },
    };
    auto files = CopyEffectFiles();
    files["/linked_mat.json"] =
        R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["_rt_imageLayerComposite_6_a"]}]})";
    fs::VFS vfs;
    MountFiles(vfs, std::move(files));
    audio::SoundManager sound;
    WPSceneParser       parser;
    auto                parsed = parser.Parse(
        SceneParseRequest { .scene_id = "hidden-layers", .project_properties = &properties },
        SceneJson(R"([
        {"id":1,"name":"chosen","image":"image.json","visible":{"user":"light","value":false},
         "effects":[{"file":"effects/copy/effect.json","visible":true}]},
        {"id":2,"name":"unchosen","image":"image.json","visible":{"user":"dark","value":true},
         "effects":[{"file":"effects/copy/effect.json","visible":true}]},
        {"id":3,"name":"group","visible":{"user":"dark","value":true}},
        {"id":4,"name":"member","image":"image.json","parent":3,
         "effects":[{"file":"effects/copy/effect.json","visible":true}]},
        {"id":5,"name":"scripted","image":"image.json",
         "visible":{"script":"export function update(value) { return value; }",
                    "user":"dark","value":true}},
        {"id":6,"name":"source","image":"image.json","visible":{"user":"dark","value":true}},
        {"id":7,"name":"consumer","image":"linked.json","dependencies":[6]}
      ])"),
        vfs,
        sound);
    ASSERT_NE(parsed, nullptr);
    ASSERT_NE(parsed->runtime, nullptr);
    AddScreenTarget(*parsed);
    auto& runtime = *parsed->runtime;

    // Every pass a layer owns, its effect steps included, counted by the layer
    // whose visibility decides whether it draws.
    const auto passes_of = [](const rg::RenderGraph& graph, std::string_view name) {
        std::size_t count = 0;
        for (const auto id : graph.topologicalOrder()) {
            auto* pass = dynamic_cast<const vulkan::CustomShaderPass*>(graph.getPass(id));
            if (pass == nullptr) continue;
            const auto* owner = pass->desc().visibility_node != nullptr
                                    ? pass->desc().visibility_node
                                    : pass->desc().node;
            if (owner != nullptr && owner->Name() == name) ++count;
        }
        return count;
    };

    auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    EXPECT_GT(passes_of(*graph, "chosen"), 1u) << "the chosen layer lost its effect";
    EXPECT_EQ(passes_of(*graph, "unchosen"), 0u) << "a layer its properties hide was drawn";
    EXPECT_EQ(passes_of(*graph, "member"), 0u) << "a hidden group's member was drawn";
    EXPECT_EQ(passes_of(*graph, "scripted"), 1u)
        << "a layer whose script decides its visibility must stay in the graph";
    EXPECT_EQ(passes_of(*graph, "source"), 1u) << "a hidden layer another samples must still draw";

    // Showing a layer that is already in the graph changes nothing about it.
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag());
    ASSERT_TRUE(runtime.SetNodeVisible("scripted", true));
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag());

    // What `layer.visible = true` from a SceneScript reaches.
    ASSERT_TRUE(runtime.SetNodeVisible("unchosen", true));
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag())
        << "a script showed a layer the graph left out, and nothing asked for a new graph";
    graph = sceneToRenderGraph(*parsed);
    EXPECT_EQ(passes_of(*graph, "unchosen"), passes_of(*graph, "chosen"));
    // From now on the script decides: hidden again, it keeps its passes, so a
    // script that blinks a layer asks for one new graph and not one per blink.
    ASSERT_TRUE(runtime.SetNodeVisible("unchosen", false));
    ASSERT_TRUE(runtime.SetNodeVisible("unchosen", true));
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag());
    ASSERT_TRUE(runtime.SetNodeVisible("unchosen", false));
    graph = sceneToRenderGraph(*parsed);
    EXPECT_EQ(passes_of(*graph, "unchosen"), passes_of(*graph, "chosen"));

    // The group's member shows when the group does.
    ASSERT_TRUE(runtime.SetNodeVisible("group", true));
    EXPECT_TRUE(runtime.ConsumeSceneGraphMutationFlag());
    graph = sceneToRenderGraph(*parsed);
    EXPECT_EQ(passes_of(*graph, "member"), passes_of(*graph, "chosen"));
    ASSERT_TRUE(runtime.SetNodeVisible("group", false));

    // A property applied in place, rather than by a reload, shows the rest.
    fs::VFS             reload_vfs;
    MountFiles(reload_vfs, CopyEffectFiles());
    auto in_place = parser.Parse(
        SceneParseRequest { .scene_id = "hidden-layers", .project_properties = &properties },
        SceneJson(R"([
        {"id":2,"name":"unchosen","image":"image.json","visible":{"user":"dark","value":true},
         "effects":[{"file":"effects/copy/effect.json","visible":true}]}
      ])"),
        reload_vfs,
        sound);
    ASSERT_NE(in_place, nullptr);
    AddScreenTarget(*in_place);
    graph = sceneToRenderGraph(*in_place);
    EXPECT_EQ(passes_of(*graph, "unchosen"), 0u);
    in_place->runtime->ApplyProjectPropertyOverride({ { "dark", RuntimeScalarValue::Bool(true) } });
    in_place->runtime->Tick(1.0 / 60.0);
    EXPECT_TRUE(in_place->runtime->ConsumeSceneGraphMutationFlag())
        << "a property shown in place left its layer out of the graph";
    graph = sceneToRenderGraph(*in_place);
    EXPECT_GT(passes_of(*graph, "unchosen"), 1u);
}

// A fullscreen layer post-processes the screen, so its result has to land on
// all of it. Drawn through the scene camera, a camera layer's zoom shrank it to
// a window on the canvas with the unprocessed scene around it.
TEST(CameraFraming, AFullscreenLayerCoversTheScreenWhateverTheShot) {
    fs::VFS vfs;
    auto    extra = CopyEffectFiles();
    extra["/post.json"] = R"({"fullscreen":true,"passthrough":true,"material":"mat.json"})";
    auto parsed = ParseScene(vfs, R"([
        {"id":9,"name":"shot","camera":"default","origin":[8,4,500],
         "angles":[0,0,0],"fov":50,"zoom":2},
        {"id":1,"name":"backdrop","image":"image.json","origin":[32,16,0]},
        {"id":2,"name":"post","image":"post.json",
         "effects":[{"file":"effects/copy/effect.json","visible":true}]}
      ])",
                             std::move(extra));
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);

    // The scene itself is still shown twice as close about (40, 20).
    const auto* backdrop = FindPassByNode(*graph, "backdrop");
    ASSERT_NE(backdrop, nullptr);
    const auto corner = CardCornerNdc(*parsed, *backdrop, { 32.0, 16.0 });
    EXPECT_NEAR(corner.x(), 1.5, 1e-4);
    EXPECT_NEAR(corner.y(), 1.5, 1e-4);

    // The post layer's result, the last thing drawn to the screen, covers it.
    const auto* post = FindPassByOutput(*graph, SpecTex_Default);
    ASSERT_NE(post, nullptr);
    ASSERT_NE(post, backdrop);
    ExpectCardFillsItsTarget(*parsed, *post, { 32.0, 16.0 });
}

TEST(CameraFraming, OpaqueGeometryPrecedesTransparentCardsOnlyWhenRequested) {
    for (const bool enabled : { false, true }) {
        fs::VFS vfs;
        MountFiles(vfs, {
            { "/opaque.json", R"({"width":64,"height":32,"material":"opaque_mat.json"})" },
            { "/opaque_mat.json",
              R"({"passes":[{"shader":"genericimage","blending":"disabled","depthtest":"enabled","depthwrite":"enabled","textures":["solid"]}]})" },
        });
        auto json = nlohmann::json::parse(SceneJson(R"([
            {"id":1,"name":"glow","image":"image.json"},
            {"id":2,"name":"background","image":"opaque.json"}
          ])"));
        json["general"]["orthogonalprojection"] = nullptr;
        json["general"]["transparentsorting"] = enabled;
        audio::SoundManager sound;
        WPSceneParser parser;
        auto scene = parser.Parse("opaque-before-glow", json.dump(), vfs, sound);
        ASSERT_NE(scene, nullptr);
        const auto graph = sceneToRenderGraph(*scene);
        ASSERT_NE(graph, nullptr);
        ASSERT_NE(FindPassByNode(*graph, "glow"), nullptr);
        ASSERT_NE(FindPassByNode(*graph, "background"), nullptr);
        EXPECT_EQ(PassIndexByNode(*graph, "background") < PassIndexByNode(*graph, "glow"),
                  enabled);
    }
}

TEST(CameraFraming, AFullscreenEffectCoversAPerspectiveScene) {
    fs::VFS vfs;
    auto extra = CopyEffectFiles();
    extra["/post.json"] = R"({"fullscreen":true,"passthrough":true,"material":"mat.json"})";
    MountFiles(vfs, std::move(extra));
    auto json = nlohmann::json::parse(SceneJson(R"([
        {"id":9,"name":"shot","camera":"default","origin":[2,1,6],"fov":50},
        {"id":2,"name":"post","image":"post.json",
         "effects":[{"file":"effects/copy/effect.json","visible":true}]}
      ])"));
    json["general"]["orthogonalprojection"] = nullptr;
    audio::SoundManager sound;
    WPSceneParser parser;
    auto parsed = parser.Parse("perspective-post", json.dump(), vfs, sound);
    ASSERT_NE(parsed, nullptr);
    ASSERT_TRUE(parsed->activeCamera->IsPerspective());
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* post = FindPassByOutput(*graph, SpecTex_Default);
    ASSERT_NE(post, nullptr);
    const Eigen::Vector2d half_extent(parsed->scene_extent[0] / 2.0,
                                      parsed->scene_extent[1] / 2.0);
    ExpectCardFillsItsTarget(*parsed, *post, half_extent);
    parsed->activeCamera->SetFov(75);
    parsed->activeCamera->Update();
    ExpectCardFillsItsTarget(*parsed, *post, half_extent);
}

// The static-result cache reuses a target's pixels while every pass writing it
// samples the same. A camera layer zooming or panning the scene moves no node
// and rebuilds no graph, so a sample blind to the camera served the first
// frame of an intro for as long as it played.
TEST(CameraFraming, MovingTheCameraChangesTheStaticSampleOfAPassItDraws) {
    fs::VFS vfs;
    auto    parsed = ParseScene(vfs, R"([
        {"id":1,"name":"backdrop","image":"image.json","origin":[32,16,0]}
      ])");
    ASSERT_NE(parsed, nullptr);
    AddScreenTarget(*parsed);
    const auto graph = sceneToRenderGraph(*parsed);
    ASSERT_NE(graph, nullptr);
    const auto* backdrop = FindPassByNode(*graph, "backdrop");
    ASSERT_NE(backdrop, nullptr);

    const auto still = backdrop->frameSample(*parsed).hash;
    EXPECT_EQ(backdrop->frameSample(*parsed).hash, still) << "an unchanged pass must be reusable";
    parsed->FrameCanvas(2.0, Eigen::Vector2f(8.0f, 4.0f));
    EXPECT_NE(backdrop->frameSample(*parsed).hash, still)
        << "the view moved and the pass would still be reused";
}
