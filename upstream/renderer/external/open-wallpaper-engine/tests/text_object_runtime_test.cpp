#include "Audio/SoundManager.h"
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Interface/IImageParser.h"
#include "RenderGraph/RenderGraph.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/VirtualAssetRegistry.hpp"
#include <atomic>
#include <chrono>
#include "Runtime/SceneRuntimeContext.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"
#include "WPShaderValueUpdater.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scripting/ScriptEngine.hpp"
#include "Project/ProjectProperties.hpp"
#include "SpecTexs.hpp"
#include "Shader/RustShaderBridge.hpp"
#include "Text/SystemFontResolver.hpp"
#include "Text/TextLayer.hpp"
#include "Vulkan/Shader.hpp"
#include "Vulkan/ShaderComp.hpp"
#include "WPSceneParser.hpp"
#include "WPPkgFs.hpp"

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_ADVANCES_H
#include <gtest/gtest.h>
#include <spirv_reflect.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include <unistd.h>

namespace wallpaper
{
namespace vulkan
{
bool ReflectCustomShader(const SceneShader& shader, std::vector<Uni_ShaderSpv>& spvs,
                         ShaderReflected& ref);
} // namespace vulkan

namespace
{

// Opt-in local-asset diagnostic: parser, scripts and render graph only. No
// Vulkan device, window, audio device or desktop state is created.
TEST(TextObjectRuntime, LonelyCatHeadlessRegression) {
    const auto* project = std::getenv("WE_TEST_PROJECT");
    const auto* assets = std::getenv("WE_TEST_ASSETS");
    const auto* cache = std::getenv("WE_TEST_CACHE");
    if (!project || !assets || !cache) GTEST_SKIP() << "No local scene fixture requested";
    fs::VFS vfs;
    ASSERT_TRUE(vfs.Mount("/assets", fs::CreatePhysicalFs(assets), "assets"));
    ASSERT_TRUE(vfs.Mount("/assets", fs::WPPkgFs::CreatePkgFs(
        (std::filesystem::path(project).parent_path() / "scene.pkg").string())));
    ASSERT_TRUE(vfs.Mount("/cache", fs::CreatePhysicalFs(cache, true), "cache"));
    ASSERT_TRUE(InstallVirtualAssets(vfs));
    ProjectProperties properties;
    std::string error;
    ASSERT_TRUE(ParseProjectProperties(project, &properties, &error)) << error;
    auto source = vfs.Open("/assets/scene.json");
    ASSERT_NE(source, nullptr);
    audio::SoundManager sound(audio::SoundManager::OutputBackend::Null);
    WPSceneParser parser;
    WPShaderParser::ClearProgramCache();
    WPShaderParser::ResetStartupMetrics();
    const auto started = std::chrono::steady_clock::now();
    auto scene = parser.Parse(SceneParseRequest {
        .scene_id = "local-regression", .project_path = project,
        .project_properties = &properties, .pkg_version = 22,
    }, source->ReadAllStr(), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    for (int i = 0; i < 3; ++i) scene->runtime->Tick(1.0 / 60.0);
    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
    const auto metrics = WPShaderParser::GetStartupMetrics();
    std::printf("Headless parse %.1f ms; shader hits=%llu misses=%llu compile=%.1f ms\n",
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count(),
        static_cast<unsigned long long>(metrics.cache_hits),
        static_cast<unsigned long long>(metrics.cache_misses), metrics.compile_ms);
    EXPECT_GT(metrics.cache_hits, 0u);
    if (std::getenv("WE_TEST_EXPECT_WARM")) EXPECT_EQ(metrics.cache_misses, 0u);
    EXPECT_EQ(scene->runtime->NodeText("__we_text_312").size(), 5u);
    EXPECT_FALSE(scene->runtime->NodeText("__we_text_150").empty());
}

constexpr uint32_t kSpirvMagic = 0x07230203u;
constexpr int32_t  kTexFormatR8 = 9;

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

class TestTexBytes {
public:
    void Stamp(char kind, int version) {
        char stamp[9] {};
        std::snprintf(stamp, sizeof(stamp), "TEX%c%04d", kind, version);
        Append(stamp, sizeof(stamp));
    }

    void I32(int32_t value) { Append(&value, sizeof(value)); }
    void U32(uint32_t value) { Append(&value, sizeof(value)); }

    std::string Take() {
        return std::string(reinterpret_cast<const char*>(m_bytes.data()), m_bytes.size());
    }

private:
    void Append(const void* data, std::size_t size) {
        const auto* p = static_cast<const uint8_t*>(data);
        m_bytes.insert(m_bytes.end(), p, p + size);
    }

    std::vector<uint8_t> m_bytes;
};

std::string BuildTextureHeaderFixture(int32_t format) {
    TestTexBytes b;
    b.Stamp('V', 5);
    b.Stamp('I', 1);
    b.I32(format);
    b.U32(0);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(1);
    b.I32(0);
    b.Stamp('B', 3);
    b.I32(1);
    b.I32(static_cast<int32_t>(ImageType::UNKNOWN));
    b.I32(0);
    return b.Take();
}

void MountAssets(fs::VFS& vfs, std::map<std::string, std::string> files = {}) {
    ASSERT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
}

bool MountPhysicalAssets(fs::VFS& vfs, const std::filesystem::path& assets_path) {
    auto physical_fs = fs::CreatePhysicalFs(assets_path.string());
    if (physical_fs == nullptr) return false;
    return vfs.Mount("/assets", std::move(physical_fs), "assets");
}

std::filesystem::path HomePath() {
    const char* home = std::getenv("HOME");
    return home != nullptr ? std::filesystem::path(home) : std::filesystem::path();
}

std::optional<std::string> ReadTextFile(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (! input.good()) return std::nullopt;
    std::string content((std::istreambuf_iterator<char>(input)),
                        std::istreambuf_iterator<char>());
    return content;
}

std::string MinimalSceneObjects(std::string objects_json) {
    return R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0,0,0], "skylightcolor":[0,0,0],
        "clearcolor":[0,0,0], "cameraparallax":false,
        "cameraparallaxamount":0, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":0,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": )" +
           objects_json + "\n}";
}

SceneNode* FindRootChild(Scene& scene, std::string_view name) {
    if (scene.sceneGraph == nullptr) return nullptr;
    const auto& children = scene.sceneGraph->GetChildren();
    const auto  it       = std::find_if(children.begin(), children.end(), [name](const auto& node) {
        return node != nullptr && node->Name() == name;
    });
    return it == children.end() ? nullptr : it->get();
}

struct MeshBounds {
    float min_x { 0.0f };
    float max_x { 0.0f };
    float min_y { 0.0f };
    float max_y { 0.0f };

    Eigen::Vector2f Size() const { return Eigen::Vector2f(max_x - min_x, max_y - min_y); }
};

MeshBounds MeshLocalBounds(const SceneMesh& mesh) {
    const auto& vertices = mesh.GetVertexArray(0);
    const auto  stride   = vertices.OneSize();
    const auto* data     = vertices.Data();
    if (data == nullptr || vertices.VertexCount() == 0 || stride < 2u) {
        return {};
    }

    MeshBounds bounds {
        .min_x = data[0],
        .max_x = data[0],
        .min_y = data[1],
        .max_y = data[1],
    };
    for (std::size_t index = 1; index < vertices.VertexCount(); ++index) {
        const float x = data[index * stride + 0u];
        const float y = data[index * stride + 1u];
        bounds.min_x  = std::min(bounds.min_x, x);
        bounds.max_x  = std::max(bounds.max_x, x);
        bounds.min_y  = std::min(bounds.min_y, y);
        bounds.max_y  = std::max(bounds.max_y, y);
    }
    return bounds;
}

Eigen::Vector2f MeshSize(const SceneMesh& mesh) {
    return MeshLocalBounds(mesh).Size();
}

Eigen::Vector2f MeshCenter(const SceneMesh& mesh) {
    const auto bounds = MeshLocalBounds(mesh);
    return Eigen::Vector2f((bounds.min_x + bounds.max_x) * 0.5f,
                           (bounds.min_y + bounds.max_y) * 0.5f);
}

struct TexCoordBounds {
    float min_u { 0.0f };
    float max_u { 0.0f };
    float min_v { 0.0f };
    float max_v { 0.0f };
};

TexCoordBounds MeshTexCoordBounds(const SceneMesh& mesh) {
    const auto& vertices = mesh.GetVertexArray(0);
    const auto  stride   = vertices.OneSize();
    const auto* data     = vertices.Data();
    if (data == nullptr || vertices.VertexCount() == 0) {
        return {};
    }

    const auto offsets = vertices.GetAttrOffsetMap();
    const auto offset_iterator = offsets.find(WE_IN_TEXCOORD.data());
    if (offset_iterator == offsets.end()) return {};
    const auto tex_offset = offset_iterator->second.offset / sizeof(float);

    TexCoordBounds bounds {
        .min_u = data[tex_offset + 0u],
        .max_u = data[tex_offset + 0u],
        .min_v = data[tex_offset + 1u],
        .max_v = data[tex_offset + 1u],
    };
    for (std::size_t index = 1; index < vertices.VertexCount(); ++index) {
        const auto base = index * stride + tex_offset;
        const float u  = data[base + 0u];
        const float v  = data[base + 1u];
        bounds.min_u   = std::min(bounds.min_u, u);
        bounds.max_u   = std::max(bounds.max_u, u);
        bounds.min_v   = std::min(bounds.min_v, v);
        bounds.max_v   = std::max(bounds.max_v, v);
    }
    return bounds;
}

void ExpectTextEffectFboCoversFinalMesh(const SceneRenderTarget& fbo,
                                        const SceneMesh& final_mesh,
                                        int32_t target_width,
                                        int32_t target_height) {
    const auto final_mesh_size = MeshSize(final_mesh);
    const auto uv_bounds       = MeshTexCoordBounds(final_mesh);
    const auto effective_width =
        static_cast<float>(fbo.width) * (uv_bounds.max_u - uv_bounds.min_u);
    const auto effective_height =
        static_cast<float>(fbo.height) * (uv_bounds.max_v - uv_bounds.min_v);
    constexpr float kUvResolutionTolerance = 1.0e-3f;
    EXPECT_GE(effective_width + kUvResolutionTolerance,
              std::min(static_cast<float>(target_width), std::ceil(final_mesh_size.x())));
    EXPECT_GE(effective_height + kUvResolutionTolerance,
              std::min(static_cast<float>(target_height), std::ceil(final_mesh_size.y())));
}

bool ShaderUsesUniformMember(const ShaderCode& spirv, std::string_view member_name) {
    spv_reflect::ShaderModule module(spirv, SPV_REFLECT_MODULE_FLAG_NO_COPY);

    uint32_t binding_count = 0;
    if (module.EnumerateDescriptorBindings(&binding_count, nullptr) != SPV_REFLECT_RESULT_SUCCESS) {
        return false;
    }

    std::vector<SpvReflectDescriptorBinding*> bindings(binding_count);
    if (module.EnumerateDescriptorBindings(&binding_count, bindings.data()) !=
        SPV_REFLECT_RESULT_SUCCESS) {
        return false;
    }

    for (const auto* binding : bindings) {
        if (binding == nullptr || ! binding->accessed ||
            binding->descriptor_type != SPV_REFLECT_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
            continue;
        }
        const auto& block = binding->block;
        for (uint32_t index = 0; index < block.member_count; ++index) {
            const auto* name = block.members[index].name;
            if (name != nullptr && member_name == name) return true;
        }
    }
    return false;
}

bool ShaderUsesUniformMember(const SceneShader& shader, std::string_view member_name) {
    if (shader.rust_reflection_json.has_value()) {
        shader::RustShaderOutput output;
        try {
            shader::ApplyRustShaderReflectionJson(*shader.rust_reflection_json, output);
            for (const auto& block : output.reflection.blocks) {
                if (block.member_map.contains(std::string(member_name))) return true;
            }
            return false;
        } catch (const std::exception&) {
        }
    }

    for (const auto& code : shader.codes) {
        if (ShaderUsesUniformMember(code, member_name)) return true;
    }
    return false;
}

int VisibleAlphaPixels(const Image& image) {
    int visible_pixels = 0;
    if (image.slots.empty() || image.slots[0].mipmaps.empty()) return visible_pixels;

    const auto& mip = image.slots[0].mipmaps[0];
    if (mip.data == nullptr) return visible_pixels;
    for (int y = 0; y < mip.height; ++y) {
        for (int x = 0; x < mip.width; ++x) {
            const auto alpha =
                mip.data.get()[(static_cast<std::size_t>(y) * mip.width + x) * 4u + 3u];
            if (alpha > 0u) ++visible_pixels;
        }
    }
    return visible_pixels;
}

const vulkan::CustomShaderPass* FindCustomPassForNode(const rg::RenderGraph& graph,
                                                      const SceneNode*       node) {
    for (const auto id : graph.topologicalOrder()) {
        auto* pass = dynamic_cast<const vulkan::CustomShaderPass*>(graph.getPass(id));
        if (pass != nullptr && pass->desc().node == node) return pass;
    }
    return nullptr;
}

void PumpTextUntilClean(SceneRuntimeContext& runtime, int max_attempts = 200) {
    for (int attempt = 0; attempt < max_attempts; ++attempt) {
        runtime.PumpTextLayerCache();
        bool any_dirty = false;
        for (std::string_view name : { "caption", "clock", "Clock" }) {
            any_dirty = any_dirty || runtime.NodeTextDirty(name);
        }
        if (! any_dirty) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}

bool ReflectShaderDescriptors(const SceneShader& shader, vulkan::ShaderReflected& reflected) {
    std::vector<vulkan::Uni_ShaderSpv> spvs;
    return vulkan::ReflectCustomShader(shader, spvs, reflected);
}

SceneShader CompileTextShaderForSpirvReflection(fs::VFS& vfs) {
    (void)vfs;
    std::string vertex_src =
        "#version 450\n"
        "layout(location = 0) in vec3 a_Position;\n"
        "layout(binding = 1) uniform GlobalUniforms {\n"
        "  mat4 g_ModelViewProjectionMatrix;\n"
        "};\n"
        "void main() {\n"
        "  gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
        "}\n";
    std::string fragment_src = "#version 450\n"
                               "layout(binding = 0) uniform sampler2D g_Texture0;\n"
                               "layout(location = 0) out vec4 glOutColor;\n"
                               "void main() {\n"
                               "  glOutColor = texture(g_Texture0, vec2(0.5));\n"
                               "}\n";

    std::vector<vulkan::ShaderCompUnit> units {
        vulkan::ShaderCompUnit {
            .stage = EShLangVertex,
            .src   = std::move(vertex_src),
        },
        vulkan::ShaderCompUnit {
            .stage = EShLangFragment,
            .src   = std::move(fragment_src),
        },
    };

    vulkan::ShaderCompOpt opt;
    opt.client_ver             = glslang::EShTargetVulkan_1_1;
    opt.auto_map_bindings      = true;
    opt.auto_map_locations     = true;
    opt.relaxed_errors_glsl    = true;
    opt.relaxed_rules_vulkan   = true;
    opt.suppress_warnings_glsl = true;

    WPShaderParser::InitGlslang();
    std::vector<vulkan::Uni_ShaderSpv> compiled;
    const bool ok = vulkan::CompileAndLinkShaderUnits(units, opt, compiled);
    WPShaderParser::FinalGlslang();
    if (! ok || compiled.size() != 2u) return {};

    SceneShader shader;
    shader.name = "text";
    shader.codes.reserve(compiled.size());
    for (auto& spv : compiled) {
        shader.codes.emplace_back(std::move(spv->spirv));
    }
    return shader;
}

std::optional<VkDescriptorSetLayoutBinding>
ShaderDescriptorBinding(const std::vector<ShaderCode>& spirv, std::string_view name) {
    std::vector<vulkan::Uni_ShaderSpv> spvs;
    vulkan::ShaderReflected            reflected;
    if (! vulkan::GenReflect(spirv, spvs, reflected)) return std::nullopt;

    const auto iterator = reflected.binding_map.find(std::string(name));
    if (iterator == reflected.binding_map.end()) return std::nullopt;

    return iterator->second;
}

std::optional<VkDescriptorSetLayoutBinding>
ShaderDescriptorBinding(const SceneShader& shader, std::string_view name) {
    vulkan::ShaderReflected reflected;
    if (! ReflectShaderDescriptors(shader, reflected)) {
        return std::nullopt;
    }

    const auto iterator = reflected.binding_map.find(std::string(name));
    if (iterator == reflected.binding_map.end()) return std::nullopt;

    return iterator->second;
}

std::vector<VkDescriptorSetLayoutBinding>
ShaderDescriptorBindings(const std::vector<ShaderCode>& spirv) {
    std::vector<vulkan::Uni_ShaderSpv> spvs;
    vulkan::ShaderReflected            reflected;
    if (! vulkan::GenReflect(spirv, spvs, reflected)) return {};

    std::vector<VkDescriptorSetLayoutBinding> bindings;
    bindings.reserve(reflected.binding_map.size());
    for (const auto& [name, binding] : reflected.binding_map) {
        (void)name;
        bindings.push_back(binding);
    }
    return bindings;
}

std::vector<VkDescriptorSetLayoutBinding>
ShaderDescriptorBindings(const SceneShader& shader) {
    vulkan::ShaderReflected reflected;
    if (! ReflectShaderDescriptors(shader, reflected)) {
        return {};
    }

    std::vector<VkDescriptorSetLayoutBinding> bindings;
    bindings.reserve(reflected.binding_map.size());
    for (const auto& [name, binding] : reflected.binding_map) {
        (void)name;
        bindings.push_back(binding);
    }
    return bindings;
}

} // namespace

TEST(TextObjectRuntime, WidthAndRowLimitsProduceTheSamePixelsAsExplicitLineBreaks) {
    TextLayerState state {
        .font_key = "systemfont_sansserif",
        .resolved_font_path = ResolveSystemFontPath("systemfont_sansserif"),
        .point_size = 10.0f,
        .horizontal_align = "left",
        .vertical_align = "top",
    };
    const auto pixels = [](const TextLayerState& text) {
        const auto size = MeasureTextLayerSize(text);
        const auto width = static_cast<uint32_t>(std::ceil(size.x()));
        const auto height = static_cast<uint32_t>(std::ceil(size.y()));
        std::vector<uint8_t> rgba(static_cast<size_t>(width) * height * 4, 0);
        RasterizeTextLayer(text, width, height, rgba);
        return std::make_pair(std::array<uint32_t, 2> {width, height}, rgba);
    };
    for (const std::string word : {std::string("WW"), std::string("éé")}) {
        state.text = word;
        const float width = MeasureTextLayerSize(state).x();
        auto expected = state;
        expected.text = word + "\n" + word;
        auto limited = state;
        limited.text = word + " " + word;
        limited.limit_width = true;
        limited.max_width = width;
        EXPECT_EQ(pixels(limited), pixels(expected));
        limited.text += "\n" + word;
        limited.limit_rows = true;
        limited.max_rows = 2;
        EXPECT_EQ(pixels(limited), pixels(expected));
    }
}

TEST(TextObjectRuntime, EllipsisFitsTheLastVisibleRowAndLimitFlagsRemainIndependent) {
    TextLayerState expected {
        .text = "WW…",
        .font_key = "systemfont_sansserif",
        .resolved_font_path = ResolveSystemFontPath("systemfont_sansserif"),
        .point_size = 10.0f,
        .horizontal_align = "left",
        .vertical_align = "top",
    };
    const auto size = MeasureTextLayerSize(expected);
    TextLayerState limited = expected;
    limited.text = "WWWWWWWW";
    limited.max_width = size.x();
    limited.max_rows = 1;
    limited.limit_width = limited.limit_rows = limited.use_ellipsis = true;
    EXPECT_TRUE(MeasureTextLayerSize(limited).isApprox(size));
    const auto width = static_cast<uint32_t>(std::ceil(size.x()));
    const auto height = static_cast<uint32_t>(std::ceil(size.y()));
    std::vector<uint8_t> actual(static_cast<size_t>(width) * height * 4, 0), reference(actual.size(), 0);
    RasterizeTextLayer(limited, width, height, actual);
    RasterizeTextLayer(expected, width, height, reference);
    EXPECT_EQ(actual, reference);
    EXPECT_TRUE(std::any_of(actual.begin(), actual.end(), [](uint8_t byte) { return byte != 0; }));
    limited.limit_width = false;
    EXPECT_GT(MeasureTextLayerSize(limited).x(), size.x());
    limited.limit_width = true;
    limited.limit_rows = false;
    EXPECT_GT(MeasureTextLayerSize(limited).y(), size.y());
}

TEST(TextObjectRuntime, ParsedLimitsContinueToConstrainDynamicText) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound(audio::SoundManager::OutputBackend::Null);
    WPSceneParser parser;
    ProjectProperties properties;
    auto scene = parser.Parse(SceneParseRequest { .scene_id = "text-limits", .project_properties = &properties },
        MinimalSceneObjects(R"([{"id":1,"name":"caption","text":"ABCDEFGHIJKLMN","font":"Arial",
            "pointsize":10,"maxwidth":120,"maxrows":2,"limitwidth":true,"limitrows":true,
            "limituseellipsis":true,"visible":true}])"), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    const auto original = scene->runtime->NodeSize("caption");
    EXPECT_GT(original.x(), 0.0f);
    EXPECT_LE(original.x(), 120.0f);
    ASSERT_TRUE(scene->runtime->SetNodeText("caption", std::string(100, 'W')));
    PumpTextUntilClean(*scene->runtime);
    const auto changed = scene->runtime->NodeSize("caption");
    EXPECT_LE(changed.x(), 120.0f);
    EXPECT_FLOAT_EQ(changed.y(), original.y());
    EXPECT_EQ(scene->runtime->NodeText("caption"), std::string(100, 'W'));
}

TEST(TextObjectRuntime, ParserCreatesRuntimeTextNodeAndState) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "text-object",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": {"value": "hello"},
            "font": {"value": "Arial"},
            "pointsize": 20,
            "padding": 4,
            "origin": [100, 50, 0],
            "horizontalalign": "right",
            "verticalalign": "bottom",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_TRUE(scene->runtime->HasNodeNamed("caption"));
    EXPECT_EQ(scene->runtime->NodeText("caption"), "hello");

    const auto size = scene->runtime->NodeSize("caption");
    EXPECT_GT(size.x(), 8.0f);
    EXPECT_GT(size.y(), 8.0f);

    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    // The layer's alignment hangs the card from its origin and leaves the node on it.
    EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(100.0f, 50.0f, 0.0f)));
    const auto layout = scene->runtime->NodeTextLayout("caption");
    ASSERT_TRUE(layout.has_value());
    const auto bounds = MeshLocalBounds(*node->Mesh());
    // Right aligned: the card ends on the origin. Bottom aligned: the descender line of the
    // last row is on it, so the card reaches one ascender and one descender above.
    EXPECT_NEAR(bounds.max_x, 0.0f, 1.0e-3f);
    EXPECT_NEAR(bounds.min_x, -size.x(), 1.0e-3f);
    EXPECT_NEAR(bounds.max_y, layout->top + layout->descender, 1.0e-3f);
}

TEST(TextObjectRuntime, ParserCreatesRenderableTextMaterialAndTexture) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "text-renderable-material",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "I I",
            "font": "Arial",
            "pointsize": 20,
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);

    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    EXPECT_EQ(material->name, "text");
    ASSERT_EQ(material->textures.size(), 1u);
    EXPECT_FALSE(material->textures.front().empty());
    EXPECT_FALSE(IsSpecTex(material->textures.front()));
    EXPECT_TRUE(scene->textures.contains(material->textures.front()));
    auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
    const auto& mip = image->slots[0].mipmaps[0];
    ASSERT_NE(mip.data, nullptr);
    ASSERT_GT(mip.width, 1);
    ASSERT_GT(mip.height, 1);
    bool has_visible_alpha            = false;
    bool has_transparent_space_column = false;
    for (int y = 1; y < mip.height - 1; ++y) {
        for (int x = 1; x < mip.width - 1; ++x) {
            const auto alpha =
                mip.data.get()[(static_cast<std::size_t>(y) * mip.width + x) * 4u + 3u];
            has_visible_alpha = has_visible_alpha || alpha > 0u;
        }
    }
    const int min_space_x = mip.width / 4;
    const int max_space_x = (mip.width * 3) / 4;
    for (int x = min_space_x; x < max_space_x && ! has_transparent_space_column; ++x) {
        bool column_clear = true;
        for (int y = 1; y < mip.height - 1; ++y) {
            const auto alpha =
                mip.data.get()[(static_cast<std::size_t>(y) * mip.width + x) * 4u + 3u];
            if (alpha != 0u) {
                column_clear = false;
                break;
            }
        }
        has_transparent_space_column = column_clear;
    }
    EXPECT_TRUE(has_visible_alpha);
    EXPECT_TRUE(has_transparent_space_column);
    ASSERT_NE(material->customShader.shader, nullptr);
    ASSERT_EQ(material->customShader.shader->codes.size(), 2u);
    for (const auto& code : material->customShader.shader->codes) {
        ASSERT_FALSE(code.empty());
        EXPECT_EQ(code.front(), kSpirvMagic);
    }
    EXPECT_TRUE(ShaderUsesUniformMember(*material->customShader.shader,
                                        "g_ModelViewProjectionMatrix"));
    const auto texture_binding =
        ShaderDescriptorBinding(*material->customShader.shader, "g_Texture0");
    ASSERT_TRUE(texture_binding.has_value());
    const bool has_rust_reflection = material->customShader.shader->rust_reflection_json.has_value();
    EXPECT_EQ(texture_binding->descriptorType,
              has_rust_reflection ? VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
                                  : VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
    const auto descriptor_bindings = ShaderDescriptorBindings(*material->customShader.shader);
    ASSERT_FALSE(descriptor_bindings.empty());
    bool has_uniform_buffer_descriptor = false;
    bool has_sampler_descriptor        = ! has_rust_reflection;
    for (const auto& binding : descriptor_bindings) {
        if (binding.descriptorType == VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
            has_uniform_buffer_descriptor = true;
            EXPECT_NE(binding.binding, texture_binding->binding);
        }
        if (binding.descriptorType == VK_DESCRIPTOR_TYPE_SAMPLER) {
            has_sampler_descriptor = true;
            EXPECT_NE(binding.binding, texture_binding->binding);
        }
    }
    EXPECT_TRUE(has_uniform_buffer_descriptor);
    EXPECT_TRUE(has_sampler_descriptor);
    EXPECT_EQ(material->blenmode, BlendMode::Translucent);
}

namespace {

// A 640x360 canvas whose camera parallax is on, with a cursor that rests at the
// centre of the view and is followed at once (amount 0.5, no delay).
std::string ParallaxTextScene(std::string objects_json) {
    return R"({
      "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
      "general": {
        "ambientcolor":[0,0,0], "skylightcolor":[0,0,0],
        "clearcolor":[0,0,0], "cameraparallax":true,
        "cameraparallaxamount":0.5, "cameraparallaxdelay":0,
        "cameraparallaxmouseinfluence":1,
        "orthogonalprojection":{"width":640,"height":360}
      },
      "objects": )" +
           objects_json + "\n}";
}

// How far the model matrix a pass hands its shader sits from where the layer's
// node places it: the whole of what camera parallax does to a layer.
Eigen::Vector2f ParallaxDisplacement(WPShaderValueUpdater& updater, SceneNode& node) {
    sprite_map_t sprites;
    ShaderValue  model;
    updater.UpdateUniforms(&node, sprites, [&](std::string_view name, const ShaderValue& value) {
        if (name == "g_ModelMatrix") model = value;
    });
    node.UpdateTrans();
    return Eigen::Vector2f(model[12] - static_cast<float>(node.ModelTrans()(0, 3)),
                           model[13] - static_cast<float>(node.ModelTrans()(1, 3)));
}

} // namespace

// Wallpaper Engine moves every layer by the camera parallax, a text layer drawn
// straight onto the scene included: by its distance from the eased cursor point,
// times its `parallaxDepth` and the scene's amount, so with the cursor centred a
// layer off the centre already sits further out. A text layer without effects has
// no record of its own in the value updater unless the parser makes one, which left
// it where its origin put it however the cursor moved while the layers around it,
// at the same depth, moved.
TEST(TextObjectRuntime, CameraParallaxMovesAPlainTextLayerByItsDepth) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    auto scene = parser.Parse(SceneParseRequest { .scene_id           = "text-parallax",
                                                  .project_properties = &properties },
                              ParallaxTextScene(R"([
          {"id":1,"name":"caption","text":"hello","font":"Arial","pointsize":20,
           "origin":[420,260,0],"parallaxDepth":[0.2,0.4],"visible":true}
        ])"),
                              vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    auto* node    = FindRootChild(*scene, "caption");
    auto* updater = dynamic_cast<WPShaderValueUpdater*>(scene->shaderValueUpdater.get());
    ASSERT_NE(node, nullptr);
    ASSERT_NE(updater, nullptr);
    updater->InitUniforms(node, [](std::string_view name) {
        return name == "g_ModelMatrix" || name == "g_ModelViewProjectionMatrix";
    });
    node->UpdateTrans();
    const float x = static_cast<float>(node->ModelTrans()(0, 3));
    const float y = static_cast<float>(node->ModelTrans()(1, 3));

    // The cursor at the centre of the view (320, 180): (position - centre) x amount x depth.
    updater->FrameBegin();
    const auto rest = ParallaxDisplacement(*updater, *node);
    EXPECT_NEAR(rest.x(), (x - 320.0f) * 0.5f * 0.2f, 1e-3f);
    EXPECT_NEAR(rest.y(), (y - 180.0f) * 0.5f * 0.4f, 1e-3f);

    // The cursor against the right edge moves the point the layer is measured from.
    updater->MouseInput(1.0, 0.5);
    scene->frameTime = 1.0;
    updater->FrameBegin();
    const auto moved = ParallaxDisplacement(*updater, *node);
    EXPECT_NEAR(moved.x(), (x - 640.0f) * 0.5f * 0.2f, 1e-3f);
    EXPECT_NEAR(moved.y(), (y - 180.0f) * 0.5f * 0.4f, 1e-3f);

    // The static-reuse cache and the on-demand clock learn of it from the pass: one
    // that follows the cursor is redrawn, and wakes a still scene for the pointer.
    EXPECT_NE(updater->FrameVaryingUniforms(node, 0, "") & frame_varying_uniform::kParallax, 0u);
}

// Parallax is measured from the outermost layer of a tree and takes its depth, as
// for every other layer; the depth a text layer under a group keeps in the file
// is stale.
TEST(TextObjectRuntime, ATextLayerUnderAGroupRidesTheGroupsParallax) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    auto scene = parser.Parse(SceneParseRequest { .scene_id           = "text-parallax-group",
                                                  .project_properties = &properties },
                              ParallaxTextScene(R"([
          {"id":1,"name":"group","origin":[320,180,0],"parallaxDepth":[0.5,0.5]},
          {"id":2,"name":"caption","parent":1,"text":"hello","font":"Arial","pointsize":20,
           "origin":[100,80,0],"parallaxDepth":[9,9],"visible":true}
        ])"),
                              vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    auto* group   = FindRootChild(*scene, "group");
    auto* updater = dynamic_cast<WPShaderValueUpdater*>(scene->shaderValueUpdater.get());
    ASSERT_NE(group, nullptr);
    ASSERT_NE(updater, nullptr);
    ASSERT_EQ(group->GetChildren().size(), 1u);
    auto* node = group->GetChildren().front().get();
    ASSERT_EQ(node->Name(), "caption");
    updater->InitUniforms(node, [](std::string_view name) { return name == "g_ModelMatrix"; });

    // The group sits at the centre of the view, so the cursor centred leaves the tree alone.
    updater->FrameBegin();
    EXPECT_LT(ParallaxDisplacement(*updater, *node).norm(), 1e-3f);
    // The cursor against the right edge moves the whole tree by the group's distance
    // from it, at the group's depth.
    updater->MouseInput(1.0, 0.5);
    scene->frameTime = 1.0;
    updater->FrameBegin();
    const auto moved = ParallaxDisplacement(*updater, *node);
    EXPECT_NEAR(moved.x(), (320.0f - 640.0f) * 0.5f * 0.5f, 1e-3f);
    EXPECT_NEAR(moved.y(), 0.0f, 1e-3f);
}

TEST(TextObjectRuntime, ParserRoutesTextObjectEffectsThroughImageEffectLayer) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "passes": [
                          { "material": "materials/effects/gradient.json" }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null],
                          "constantshadervalues": {
                            "gradient": "0.1 0.2 0.3"
                          }
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "uniform float g_Time;\n"
                      "uniform vec3 u_Gradient; // {\"material\":\"gradient\",\"default\":\"1 1 1\"}\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { vec4 albedo = texture(g_Texture0, v_TexCoord); gl_FragColor = vec4(u_Gradient * abs(cos(g_Time)), albedo.a); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-effect",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": "hello",
              "font": "Arial",
              "pointsize": 20,
              "origin": "0 0 0",
              "size": "200 40",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true,
                  "passes": [
                    {
                      "constantshadervalues": {
                        "gradient": "0.25 0.5 0.75"
                      }
                    }
                  ]
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_FALSE(text->Camera().empty());
    ASSERT_TRUE(scene->cameras.contains(text->Camera()));
    ASSERT_TRUE(scene->cameras.at(text->Camera())->HasImgEffect());

    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);

    auto* effect_node = scene->cameras.at(text->Camera())
                            ->GetImgEffect()
                            ->GetEffect(0)
                            ->nodes.front()
                            .sceneNode.get();
    auto* updater = dynamic_cast<WPShaderValueUpdater*>(scene->shaderValueUpdater.get());
    ASSERT_NE(updater, nullptr);
    updater->InitUniforms(effect_node, [](std::string_view name) {
        return name == "g_Time";
    });

    scene->PassFrameTime(0.5);
    sprite_map_t sprites;
    std::unordered_map<std::string, ShaderValue> updates;
    updater->UpdateUniforms(effect_node, sprites, [&](std::string_view name, const ShaderValue& value) {
        updates.emplace(std::string(name), value);
    });
    ASSERT_TRUE(updates.contains("g_Time"));
    EXPECT_FLOAT_EQ(updates.at("g_Time")[0], 0.5f);
}

TEST(TextObjectRuntime, TextEffectVisibilityFollowsTheBoundUserProperty) {
    // The scene file's `value` is the editor's default; the property decides.
    fs::VFS vfs;
    std::map<std::string, std::string> files;
    for (const std::string name : { "chosen", "unchosen" }) {
        files["/effects/" + name + "/effect.json"] =
            R"({"name":")" + name + R"(","passes":[{"material":"materials/effects/)" + name +
            R"(.json"}]})";
        files["/materials/effects/" + name + ".json"] =
            R"({"passes":[{"shader":"effects/)" + name + R"(","textures":[null]}]})";
        files["/shaders/effects/" + name + ".vert"] =
            "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
            "in vec3 a_Position;\n"
            "in vec2 a_TexCoord;\n"
            "out vec2 v_TexCoord;\n"
            "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n";
        files["/shaders/effects/" + name + ".frag"] =
            "uniform sampler2D g_Texture0;\n"
            "in vec2 v_TexCoord;\n"
            "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n";
    }
    MountAssets(vfs, files);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
        { "glow", RuntimeScalarValue::Bool(true) },
        { "style", RuntimeScalarValue::String("2") },
    };
    SceneParseRequest request {
        .scene_id           = "text-effect-user-visibility",
        .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": "hello",
              "font": "Arial",
              "pointsize": 20,
              "origin": "0 0 0",
              "size": "200 40",
              "visible": true,
              "effects": [
                {"file": "effects/chosen/effect.json", "id": 2,
                 "visible": {"user": "glow", "value": false}},
                {"file": "effects/unchosen/effect.json", "id": 3,
                 "visible": {"user": {"name": "style", "condition": "1"}, "value": true}}
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_TRUE(scene->cameras.contains(text->Camera()));
    auto& layer = *scene->cameras.at(text->Camera())->GetImgEffect();
    ASSERT_EQ(layer.EffectCount(), 1u);
    const auto* material = layer.GetEffect(0)->nodes.front().sceneNode->Mesh()->Material();
    ASSERT_NE(material, nullptr);
    EXPECT_EQ(material->name, "effects/chosen");
}

TEST(TextObjectRuntime, RuntimeTextEffectTargetsResizeWithTextRasterSize) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "fbos": [
                          { "name": "_rt_BlurBuffer", "scale": 2 }
                        ],
                        "passes": [
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "previous", "index": 0 }
                            ],
                            "target": "_rt_BlurBuffer"
                          },
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "_rt_BlurBuffer", "index": 0 }
                            ]
                          }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-effect-resize",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": "a",
              "font": "Arial",
              "pointsize": 20,
              "padding": 0,
              "origin": "0 0 0",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    auto* pingpong = scene->FindRenderTarget(effect_layer->FirstTarget());
    ASSERT_NE(pingpong, nullptr);
    const auto initial_pingpong_width = pingpong->width;
    const auto initial_camera_width   = camera->Width();
    auto* fbo = scene->FindRenderTarget(
        effect_layer->GetEffect(0)->nodes.front().output);
    ASSERT_NE(fbo, nullptr);
    const auto initial_fbo_width = fbo->width;
    const auto initial_text_mesh_size = MeshSize(*text->Mesh());
    const auto initial_final_mesh_size = MeshSize(effect_layer->FinalMesh());

    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    auto* resolved_final = effect_layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved_final, nullptr);
    ASSERT_NE(resolved_final->Mesh(), nullptr);
    EXPECT_TRUE(resolved_final->Mesh()->Dynamic());

    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "a much longer caption for effects"));
    PumpTextUntilClean(*scene->runtime);

    pingpong = scene->FindRenderTarget(effect_layer->FirstTarget());
    ASSERT_NE(pingpong, nullptr);
    fbo = scene->FindRenderTarget(effect_layer->GetEffect(0)->nodes.front().output);
    ASSERT_NE(fbo, nullptr);
    EXPECT_EQ(pingpong->width, initial_pingpong_width);
    EXPECT_EQ(camera->Width(), initial_camera_width);
    EXPECT_EQ(static_cast<int>(camera->Width()), pingpong->width);
    EXPECT_EQ(static_cast<int>(camera->Height()), pingpong->height);
    const auto resized_text_mesh_size = MeshSize(*text->Mesh());
    const auto resized_final_mesh_size = MeshSize(effect_layer->FinalMesh());
    ExpectTextEffectFboCoversFinalMesh(*fbo,
                                       effect_layer->FinalMesh(),
                                       pingpong->width,
                                       pingpong->height);
    EXPECT_EQ(fbo->width, initial_fbo_width);
    EXPECT_GT(resized_text_mesh_size.x(), initial_text_mesh_size.x());
    EXPECT_GT(resized_final_mesh_size.x(), initial_final_mesh_size.x());
    EXPECT_NEAR(resized_final_mesh_size.x(), resized_text_mesh_size.x(), 1.0f);
    EXPECT_NEAR(resized_final_mesh_size.y(), resized_text_mesh_size.y(), 1.0f);
    const auto uv_bounds = MeshTexCoordBounds(effect_layer->FinalMesh());
    EXPECT_GE(uv_bounds.min_u, 0.0f);
    EXPECT_LE(uv_bounds.max_u, 1.0f);
    EXPECT_GE(uv_bounds.min_v, 0.0f);
    EXPECT_LE(uv_bounds.max_v, 1.0f);

    ASSERT_EQ(resolved_final, effect_layer->ResolvedFinalRenderNode());
    ASSERT_NE(resolved_final->Mesh(), nullptr);
    EXPECT_TRUE(resolved_final->Mesh()->Dynamic());
    const auto resolved_final_mesh_size = MeshSize(*resolved_final->Mesh());
    EXPECT_NEAR(resolved_final_mesh_size.x(), resized_text_mesh_size.x(), 1.0f);
    EXPECT_NEAR(resolved_final_mesh_size.y(), resized_text_mesh_size.y(), 1.0f);
    const auto resolved_uv_bounds = MeshTexCoordBounds(*resolved_final->Mesh());
    EXPECT_GE(resolved_uv_bounds.min_u, 0.0f);
    EXPECT_LE(resolved_uv_bounds.max_u, 1.0f);
    EXPECT_GE(resolved_uv_bounds.min_v, 0.0f);
    EXPECT_LE(resolved_uv_bounds.max_v, 1.0f);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, ParserTextEffectFinalUvsUseRoundedRenderTargetExtent) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "passes": [
                          { "material": "materials/effects/gradient.json" }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-effect-rounded-uvs",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": "a",
              "font": "Arial",
              "pointsize": 20.125,
              "padding": 0,
              "origin": "0 0 0",
              "size": [93.6, 41.6],
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    const auto final_mesh_size = MeshSize(effect_layer->FinalMesh());
    const auto uv_bounds       = MeshTexCoordBounds(effect_layer->FinalMesh());
    const auto expected_u_span = final_mesh_size.x() / static_cast<float>(camera->Width());
    const auto expected_v_span = final_mesh_size.y() / static_cast<float>(camera->Height());
    EXPECT_NEAR(uv_bounds.max_u - uv_bounds.min_u, expected_u_span, 1.0e-5f);
    EXPECT_NEAR(uv_bounds.max_v - uv_bounds.min_v, expected_v_span, 1.0e-5f);
    EXPECT_LT(uv_bounds.max_u - uv_bounds.min_u, 1.0f);
    EXPECT_LT(uv_bounds.max_v - uv_bounds.min_v, 1.0f);
}

TEST(TextObjectRuntime, OversizedTextEffectClipsFinalMeshToBoundedTarget) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "fbos": [
                          { "name": "_rt_BlurBuffer", "scale": 2 }
                        ],
                        "passes": [
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "previous", "index": 0 }
                            ],
                            "target": "_rt_BlurBuffer"
                          },
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "_rt_BlurBuffer", "index": 0 }
                            ]
                          }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-effect-oversized-cap",
          .project_properties = &properties,
    };
    const std::string oversized_text(260, 'W');

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": ")JSON" + oversized_text +
                                                  R"JSON(",
              "font": "Arial",
              "pointsize": 40,
              "padding": 0,
              "origin": "0 0 0",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_NE(text->Mesh(), nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    const auto layout = scene->runtime->NodeTextLayout("caption");
    ASSERT_TRUE(layout.has_value());
    ASSERT_GT(layout->card.x(), 4096.0f);
    EXPECT_LE(camera->Width(), 4096.0);
    EXPECT_LE(camera->Height(), 4096.0);

    auto* pingpong = scene->FindRenderTarget(effect_layer->FirstTarget());
    ASSERT_NE(pingpong, nullptr);
    EXPECT_LE(pingpong->width, 4096);
    EXPECT_LE(pingpong->height, 4096);
    auto* fbo = scene->FindRenderTarget(effect_layer->GetEffect(0)->nodes.front().output);
    ASSERT_NE(fbo, nullptr);

    const auto text_mesh_size = MeshSize(*text->Mesh());
    EXPECT_GT(text_mesh_size.x(), static_cast<float>(pingpong->width));
    const auto final_mesh_size = MeshSize(effect_layer->FinalMesh());
    ExpectTextEffectFboCoversFinalMesh(*fbo,
                                       effect_layer->FinalMesh(),
                                       pingpong->width,
                                       pingpong->height);
    EXPECT_NEAR(final_mesh_size.x(), static_cast<float>(pingpong->width), 1.0f);
    EXPECT_LE(final_mesh_size.y(), static_cast<float>(pingpong->height));
    const auto uv_bounds = MeshTexCoordBounds(effect_layer->FinalMesh());
    EXPECT_FLOAT_EQ(uv_bounds.min_u, 0.0f);
    EXPECT_FLOAT_EQ(uv_bounds.max_u, 1.0f);
    EXPECT_GE(uv_bounds.min_v, 0.0f);
    EXPECT_LE(uv_bounds.max_v, 1.0f);

    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    auto* resolved_final = effect_layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved_final, nullptr);
    ASSERT_NE(resolved_final->Mesh(), nullptr);
    const auto resolved_final_size = MeshSize(*resolved_final->Mesh());
    EXPECT_NEAR(resolved_final_size.x(), static_cast<float>(pingpong->width), 1.0f);
    const auto resolved_uv_bounds = MeshTexCoordBounds(*resolved_final->Mesh());
    EXPECT_FLOAT_EQ(resolved_uv_bounds.min_u, 0.0f);
    EXPECT_FLOAT_EQ(resolved_uv_bounds.max_u, 1.0f);
    EXPECT_GE(resolved_uv_bounds.min_v, 0.0f);
    EXPECT_LE(resolved_uv_bounds.max_v, 1.0f);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, SceneScriptTextEffectMutationKeepsFinalUvsInCapacity) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "passes": [
                          { "material": "materials/effects/gradient.json" }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-effect-script-mutation",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": {
                "text": "a",
                "script": "engine.on('cursorDown', function() { thisLayer.text = 'a much longer caption for effects'; })"
              },
              "font": "Arial",
              "pointsize": 20,
              "padding": 0,
              "origin": "0 0 0",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    scene->runtime->DispatchCursorDown();
    PumpTextUntilClean(*scene->runtime);

    EXPECT_EQ(scene->runtime->NodeText("caption"), "a much longer caption for effects");
    const auto uv_bounds = MeshTexCoordBounds(effect_layer->FinalMesh());
    EXPECT_GE(uv_bounds.min_u, 0.0f);
    EXPECT_LE(uv_bounds.max_u, 1.0f);
    EXPECT_GE(uv_bounds.min_v, 0.0f);
    EXPECT_LE(uv_bounds.max_v, 1.0f);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, AlignedTextEffectTracksMeasuredRenderFrameWhenRasterExpands) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "fbos": [
                          { "name": "_rt_BlurBuffer", "scale": 2 }
                        ],
                        "passes": [
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "previous", "index": 0 }
                            ],
                            "target": "_rt_BlurBuffer"
                          },
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "_rt_BlurBuffer", "index": 0 }
                            ]
                          }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "aligned-text-effect-raster-camera",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": {
                "value": "a",
                "script": "export function update(value) { return 'a much longer caption for explicit effects'; }"
              },
              "font": "Arial",
              "pointsize": 20,
              "padding": 0,
              "origin": "0 0 0",
              "horizontalalign": "right",
              "verticalalign": "bottom",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_NE(text->Mesh(), nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);
    scene->runtime->Tick(1.0 / 60.0);
    PumpTextUntilClean(*scene->runtime);

    EXPECT_EQ(scene->runtime->NodeText("caption"),
              "a much longer caption for explicit effects");

    const auto state = scene->runtime->NodeTextState("caption");
    const auto layout = scene->runtime->NodeTextLayout("caption");
    ASSERT_TRUE(state.has_value());
    ASSERT_TRUE(layout.has_value());
    // The card is the text the script wrote, and the layer is placed by the edges of it.
    const auto card = scene->runtime->NodeSize("caption");
    EXPECT_TRUE(card.isApprox(layout->card));
    EXPECT_GT(card.x(), 400.0f);
    EXPECT_TRUE(text->Translate().isApprox(Eigen::Vector3f::Zero()));
    const auto render_frame = TextLayerRenderFrameForLayout(*state, *layout);
    EXPECT_NEAR(render_frame.center.x(), -card.x() * 0.5f, 1.0e-3f);

    const auto text_mesh_size = MeshSize(*text->Mesh());
    EXPECT_NEAR(text_mesh_size.x(), render_frame.size.x(), 1.0f);
    EXPECT_NEAR(text_mesh_size.y(), render_frame.size.y(), 1.0f);
    const auto text_mesh_center = MeshCenter(*text->Mesh());
    EXPECT_NEAR(text_mesh_center.x(), render_frame.center.x(), 1.0e-4f);
    EXPECT_NEAR(text_mesh_center.y(), render_frame.center.y(), 1.0e-4f);

    auto* pingpong = scene->FindRenderTarget(effect_layer->FirstTarget());
    ASSERT_NE(pingpong, nullptr);
    auto* fbo = scene->FindRenderTarget(effect_layer->GetEffect(0)->nodes.front().output);
    ASSERT_NE(fbo, nullptr);
    EXPECT_GE(pingpong->width, static_cast<int32_t>(std::lround(render_frame.size.x())));
    EXPECT_GE(pingpong->height, static_cast<int32_t>(std::lround(render_frame.size.y())));
    EXPECT_EQ(static_cast<int32_t>(std::lround(camera->Width())), pingpong->width);
    EXPECT_EQ(static_cast<int32_t>(std::lround(camera->Height())), pingpong->height);

    const auto final_mesh_size = MeshSize(effect_layer->FinalMesh());
    ExpectTextEffectFboCoversFinalMesh(*fbo,
                                       effect_layer->FinalMesh(),
                                       pingpong->width,
                                       pingpong->height);
    EXPECT_NEAR(final_mesh_size.x(), render_frame.size.x(), 1.0f);
    EXPECT_NEAR(final_mesh_size.y(), render_frame.size.y(), 1.0f);
    const auto final_mesh_center = MeshCenter(effect_layer->FinalMesh());
    EXPECT_NEAR(final_mesh_center.x(), render_frame.center.x(), 1.0e-4f);
    EXPECT_NEAR(final_mesh_center.y(), render_frame.center.y(), 1.0e-4f);
    const auto uv_bounds = MeshTexCoordBounds(effect_layer->FinalMesh());
    EXPECT_GE(uv_bounds.min_u, 0.0f);
    EXPECT_LE(uv_bounds.max_u, 1.0f);
    EXPECT_GE(uv_bounds.min_v, 0.0f);
    EXPECT_LE(uv_bounds.max_v, 1.0f);

    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    auto* resolved_final = effect_layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved_final, nullptr);
    ASSERT_NE(resolved_final->Mesh(), nullptr);
    const auto resolved_final_mesh_size = MeshSize(*resolved_final->Mesh());
    EXPECT_NEAR(resolved_final_mesh_size.x(), render_frame.size.x(), 1.0f);
    EXPECT_NEAR(resolved_final_mesh_size.y(), render_frame.size.y(), 1.0f);
    const auto resolved_final_mesh_center = MeshCenter(*resolved_final->Mesh());
    EXPECT_NEAR(resolved_final_mesh_center.x(), render_frame.center.x(), 1.0e-4f);
    EXPECT_NEAR(resolved_final_mesh_center.y(), render_frame.center.y(), 1.0e-4f);

    EXPECT_TRUE(scene->runtime->ConsumeSceneGraphMutationFlag());
    PumpTextUntilClean(*scene->runtime);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, AlignedTextEffectCoversMeasuredRasterWithoutScaling) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/effects/gradient/effect.json",
                      R"JSON({
                        "name": "gradient",
                        "version": 1,
                        "fbos": [
                          { "name": "_rt_BlurBuffer", "scale": 2 }
                        ],
                        "passes": [
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "previous", "index": 0 }
                            ],
                            "target": "_rt_BlurBuffer"
                          },
                          {
                            "material": "materials/effects/gradient.json",
                            "bind": [
                              { "name": "_rt_BlurBuffer", "index": 0 }
                            ]
                          }
                        ]
                      })JSON" },
                    { "/materials/effects/gradient.json",
                      R"JSON({
                        "passes": [{
                          "shader": "effects/gradient",
                          "textures": [null]
                        }]
                      })JSON" },
                    { "/shaders/effects/gradient.vert",
                      "layout(binding = 1) uniform mat4 g_ModelViewProjectionMatrix;\n"
                      "in vec3 a_Position;\n"
                      "in vec2 a_TexCoord;\n"
                      "out vec2 v_TexCoord;\n"
                      "void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }\n" },
                    { "/shaders/effects/gradient.frag",
                      "uniform sampler2D g_Texture0;\n"
                      "in vec2 v_TexCoord;\n"
                      "void main() { gl_FragColor = texture(g_Texture0, v_TexCoord); }\n" },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "aligned-text-effect-measured-raster",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
            {
              "id": 1,
              "name": "caption",
              "text": "Saturday Saturday Saturday",
              "font": "Arial",
              "pointsize": 20,
              "padding": 0,
              "origin": "0 0 0",
              "horizontalalign": "right",
              "verticalalign": "bottom",
              "visible": true,
              "effects": [
                {
                  "file": "effects/gradient/effect.json",
                  "id": 2,
                  "visible": true
                }
              ]
            }
          ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* text = FindRootChild(*scene, "caption");
    ASSERT_NE(text, nullptr);
    ASSERT_NE(text->Mesh(), nullptr);
    ASSERT_FALSE(text->Camera().empty());
    auto camera = scene->cameras.at(text->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    const auto layout = scene->runtime->NodeTextLayout("caption");
    ASSERT_TRUE(layout.has_value());
    const auto card = scene->runtime->NodeSize("caption");
    EXPECT_TRUE(card.isApprox(layout->card));

    const auto text_mesh_size = MeshSize(*text->Mesh());
    EXPECT_NEAR(text_mesh_size.x(), card.x(), 1.0f);
    EXPECT_NEAR(text_mesh_size.y(), card.y(), 1.0f);
    // The card hangs from the layer's origin by the edges it is aligned to: its right edge
    // is on the origin, and the descender line of its last row.
    const auto text_mesh_center = MeshCenter(*text->Mesh());
    EXPECT_NEAR(text_mesh_center.x(), layout->centre.x(), 1.0e-4f);
    EXPECT_NEAR(text_mesh_center.y(), layout->centre.y(), 1.0e-4f);
    EXPECT_NEAR(text_mesh_center.x(), -card.x() * 0.5f, 1.0e-4f);

    auto* pingpong = scene->FindRenderTarget(effect_layer->FirstTarget());
    ASSERT_NE(pingpong, nullptr);
    auto* fbo = scene->FindRenderTarget(effect_layer->GetEffect(0)->nodes.front().output);
    ASSERT_NE(fbo, nullptr);
    EXPECT_GE(pingpong->width, static_cast<int32_t>(std::ceil(card.x())));
    EXPECT_GE(pingpong->height, static_cast<int32_t>(std::ceil(card.y())));
    EXPECT_EQ(static_cast<int32_t>(std::lround(camera->Width())), pingpong->width);
    EXPECT_EQ(static_cast<int32_t>(std::lround(camera->Height())), pingpong->height);
    EXPECT_NEAR(camera->GetPosition().x(), text_mesh_center.x(), 1.0e-4);
    EXPECT_NEAR(camera->GetPosition().y(), text_mesh_center.y(), 1.0e-4);

    const auto final_mesh_size = MeshSize(effect_layer->FinalMesh());
    ExpectTextEffectFboCoversFinalMesh(*fbo,
                                       effect_layer->FinalMesh(),
                                       pingpong->width,
                                       pingpong->height);
    EXPECT_NEAR(final_mesh_size.x(), card.x(), 1.0f);
    EXPECT_NEAR(final_mesh_size.y(), card.y(), 1.0f);
    EXPECT_NEAR(MeshCenter(effect_layer->FinalMesh()).x(), text_mesh_center.x(), 1.0e-4f);
    EXPECT_NEAR(MeshCenter(effect_layer->FinalMesh()).y(), text_mesh_center.y(), 1.0e-4f);

    auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    auto* resolved_final = effect_layer->ResolvedFinalRenderNode();
    ASSERT_NE(resolved_final, nullptr);
    ASSERT_NE(resolved_final->Mesh(), nullptr);
    const auto resolved_final_mesh_size = MeshSize(*resolved_final->Mesh());
    EXPECT_NEAR(resolved_final_mesh_size.x(), card.x(), 1.0f);
    EXPECT_NEAR(resolved_final_mesh_size.y(), card.y(), 1.0f);
    EXPECT_NEAR(MeshCenter(*resolved_final->Mesh()).x(), text_mesh_center.x(), 1.0e-4f);
    EXPECT_NEAR(MeshCenter(*resolved_final->Mesh()).y(), text_mesh_center.y(), 1.0e-4f);

    EXPECT_TRUE(text->Translate().isApprox(Eigen::Vector3f::Zero()));
}

TEST(TextObjectRuntime, ParserStabilizesCascadingRustShaderDefaultTextureMetadata) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
                    { "/mat.json",
                      R"({"passes":[{"blending":"translucent","cullmode":"nocull",)"
                      R"("depthtest":"disabled","depthwrite":"disabled",)"
                      R"("shader":"defaulttexture","textures":[""]}]})" },
                    { "/shaders/defaulttexture.vert",
                      R"(
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)" },
                    { "/shaders/defaulttexture.frag",
                      R"(
uniform sampler2D g_Texture0; // {"material":"albedo","default":"fallback-r8.tex"}
#ifndef TEX0FORMAT
// [COMBO] {"combo":"FIRST_PASS_ONLY","default":1}
#endif
#if FIRST_PASS_ONLY
uniform float g_StaleFirstPassMarker; // {"default":1.0}
#endif
#if TEX0FORMAT == 9
uniform sampler2D g_Texture1; // {"material":"second","default":"second-r8.tex"}
#endif
#if TEX1FORMAT == 9
uniform float g_CascadedDefaultObserved; // {"default":1.0}
#endif
varying vec2 v_TexCoord;
void main() {
  vec4 texel = texture(g_Texture0, v_TexCoord);
#if TEX1FORMAT == 9
  texel += texture(g_Texture1, v_TexCoord) * 0.001;
  texel.r += g_CascadedDefaultObserved * 0.001;
#endif
  gl_FragColor = texel;
}
)" },
                    { "/materials/fallback-r8.tex.tex", BuildTextureHeaderFixture(kTexFormatR8) },
                    { "/materials/second-r8.tex.tex", BuildTextureHeaderFixture(kTexFormatR8) },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "rust-default-texture-material",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "defaulted image",
            "image": "image.json",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* node = FindRootChild(*scene, "defaulted image");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 2u);
    EXPECT_EQ(material->textures[0], "fallback-r8.tex");
    EXPECT_EQ(material->textures[1], "second-r8.tex");
    EXPECT_TRUE(scene->textures.contains("fallback-r8.tex"));
    EXPECT_TRUE(scene->textures.contains("second-r8.tex"));
    ASSERT_NE(material->customShader.shader, nullptr);
    EXPECT_TRUE(ShaderUsesUniformMember(*material->customShader.shader,
                                        "g_CascadedDefaultObserved"));
    EXPECT_FALSE(ShaderUsesUniformMember(*material->customShader.shader,
                                         "g_StaleFirstPassMarker"));
}

TEST(TextObjectRuntime, MissingOrInvalidReflectionFailsWithoutLegacyFallback) {
    fs::VFS vfs;
    MountAssets(vfs);
    SceneShader shader = CompileTextShaderForSpirvReflection(vfs);
    ASSERT_FALSE(shader.codes.empty());
    vulkan::ShaderReflected reflected;
    EXPECT_FALSE(ReflectShaderDescriptors(shader, reflected));
    shader.rust_reflection_json = "{ incomplete metadata";
    EXPECT_FALSE(ReflectShaderDescriptors(shader, reflected));
    shader.rust_reflection_json = "{}";
    EXPECT_FALSE(ReflectShaderDescriptors(shader, reflected));
}

TEST(TextObjectRuntime, ResourceFreeShaderUsesItsValidEmptyRustReflection) {
    shader::RustShaderRequest request;
    request.shader_name = "empty-resource-reflection";
    request.cache_enabled = false;
    request.stages = {
        {ShaderType::VERTEX, "void main(){gl_Position=vec4(0.0,0.0,0.0,1.0);}"},
        {ShaderType::FRAGMENT, "void main(){gl_FragColor=vec4(1.0);}"},
    };
    shader::RustShaderOutput compiled;
    ASSERT_TRUE(shader::CompileRustShaderProgram(request, compiled)) << shader::LastRustShaderError();
    SceneShader source;
    source.codes = compiled.codes;
    source.rust_reflection_json = compiled.reflection_json;
    vulkan::ShaderReflected reflected;
    ASSERT_TRUE(ReflectShaderDescriptors(source, reflected));
    EXPECT_TRUE(reflected.binding_map.empty());
    EXPECT_TRUE(reflected.blocks.empty());
    EXPECT_TRUE(reflected.input_location_map.empty());
}

TEST(TextObjectRuntime, RasterizedTextUsesFontPixelSizeAndAntialiasesEdges) {
    TextLayerState state {
        .text                   = "Hg",
        .font_key               = "systemfont_Helvetica",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "Helvetica",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_Helvetica"),
        .point_size             = 40.0f,
        .padding                = { 4.0f, 4.0f },
    };
#ifdef __APPLE__
    ASSERT_FALSE(state.resolved_font_path.empty());
#endif

    constexpr uint32_t   width  = 420;
    constexpr uint32_t   height = 220;
    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);

    int  min_y                  = static_cast<int>(height);
    int  max_y                  = -1;
    bool has_partial_alpha_edge = false;
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const auto alpha = rgba[(static_cast<std::size_t>(y) * width + x) * 4u + 3u];
            if (alpha == 0u) continue;
            min_y                  = std::min(min_y, static_cast<int>(y));
            max_y                  = std::max(max_y, static_cast<int>(y));
            has_partial_alpha_edge = has_partial_alpha_edge || (alpha > 0u && alpha < 255u);
        }
    }

    ASSERT_GE(max_y, min_y);
    EXPECT_GT(max_y - min_y + 1, 110);
    EXPECT_TRUE(has_partial_alpha_edge);
}

TEST(TextObjectRuntime, SansSerifAliasRasterizesClockDigits) {
    TextLayerState state {
        .text                   = "12:34",
        .font_key               = "systemfont_sansserif",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "sansserif",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_sansserif"),
        .point_size             = 33.0f,
        .padding                = { 32.0f, 32.0f },
        .color                  = Eigen::Vector3f(1.0f, 0.81176f, 0.87059f),
        .horizontal_align       = "center",
        .vertical_align         = "center",
    };
#ifdef __APPLE__
    ASSERT_FALSE(state.resolved_font_path.empty());
#endif

    const auto     size   = TextLayerRasterSize(state);
    const uint32_t width  = static_cast<uint32_t>(std::ceil(size.x()));
    const uint32_t height = static_cast<uint32_t>(std::ceil(size.y()));
    ASSERT_GT(width, 0u);
    ASSERT_GT(height, 0u);

    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);

    int visible_pixels = 0;
    int max_alpha      = 0;
    for (std::size_t offset = 3; offset < rgba.size(); offset += 4u) {
        const auto alpha = rgba[offset];
        if (alpha == 0u) continue;
        ++visible_pixels;
        max_alpha = std::max(max_alpha, static_cast<int>(alpha));
    }

    EXPECT_GT(visible_pixels, 200);
    EXPECT_GT(max_alpha, 128);
}

TEST(TextObjectRuntime, ParserResolvesFamilyFontsForFreeTypeRasterization) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "text-family-freetype",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "Hg",
            "font": "Helvetica",
            "pointsize": 40,
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    const auto state = scene->runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->resolved_font_kind, "family");
#ifdef __APPLE__
    EXPECT_FALSE(state->resolved_font_path.empty());
#endif
    const auto runtime_size = scene->runtime->NodeSize("caption");
    EXPECT_GT(runtime_size.x(), 130.0f);
    EXPECT_GT(runtime_size.y(), 120.0f);
    EXPECT_LT(runtime_size.x(), 280.0f);
    EXPECT_LT(runtime_size.y(), 220.0f);

    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto& vertex_array = node->Mesh()->GetVertexArray(0);
    ASSERT_EQ(vertex_array.VertexCount(), 4u);
    const float* vertices = vertex_array.Data();
    ASSERT_NE(vertices, nullptr);
    const auto stride = vertex_array.OneSize();
    float      min_x  = vertices[0];
    float      max_x  = vertices[0];
    float      min_y  = vertices[1];
    float      max_y  = vertices[1];
    for (std::size_t index = 1; index < vertex_array.VertexCount(); ++index) {
        const float x = vertices[index * stride + 0u];
        const float y = vertices[index * stride + 1u];
        min_x         = std::min(min_x, x);
        max_x         = std::max(max_x, x);
        min_y         = std::min(min_y, y);
        max_y         = std::max(max_y, y);
    }
    EXPECT_NEAR(max_x - min_x, runtime_size.x(), 1.0f);
    EXPECT_NEAR(max_y - min_y, runtime_size.y(), 1.0f);

    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    ASSERT_EQ(image->slots.size(), 1u);
    ASSERT_EQ(image->slots[0].mipmaps.size(), 1u);
    const auto& mip = image->slots[0].mipmaps[0];
    ASSERT_NE(mip.data, nullptr);

    bool has_partial_alpha_edge = false;
    for (int y = 0; y < mip.height && ! has_partial_alpha_edge; ++y) {
        for (int x = 0; x < mip.width; ++x) {
            const auto alpha =
                mip.data.get()[(static_cast<std::size_t>(y) * mip.width + x) * 4u + 3u];
            if (alpha > 0u && alpha < 255u) {
                has_partial_alpha_edge = true;
                break;
            }
        }
    }
    EXPECT_TRUE(has_partial_alpha_edge);
}

TEST(TextObjectRuntime, FreeTypeEstimatedSizeContainsTallGlyphs) {
    TextLayerState state {
        .text                   = "Hg",
        .font_key               = "systemfont_Helvetica",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "Helvetica",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_Helvetica"),
        .point_size             = 40.0f,
        .padding                = { 4.0f, 4.0f },
    };
#ifdef __APPLE__
    ASSERT_FALSE(state.resolved_font_path.empty());
#endif

    const auto size = TextLayerRasterSize(state);
    EXPECT_GT(size.x(), 130.0f);
    EXPECT_GT(size.y(), 120.0f);
    EXPECT_LT(size.x(), 280.0f);
    EXPECT_LT(size.y(), 220.0f);

    std::vector<uint8_t> rgba(static_cast<std::size_t>(std::ceil(size.x())) *
                                  static_cast<std::size_t>(std::ceil(size.y())) * 4u,
                              0u);
    RasterizeTextLayer(state,
                       static_cast<uint32_t>(std::ceil(size.x())),
                       static_cast<uint32_t>(std::ceil(size.y())),
                       rgba);

    bool has_visible_alpha = false;
    for (std::size_t offset = 3; offset < rgba.size(); offset += 4u) {
        if (rgba[offset] > 0u) {
            has_visible_alpha = true;
            break;
        }
    }
    EXPECT_TRUE(has_visible_alpha);
}

// A padded, centred row has its ink in the middle of the card, whatever the card's width.
TEST(TextObjectRuntime, CenteredTextIsCenteredInItsCard) {
    TextLayerState state {
        .text                   = "Saturday",
        .font_key               = "systemfont_Helvetica",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "Helvetica",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_Helvetica"),
        .point_size             = 20.0f,
        .padding                = { 32.0f, 32.0f },
        .horizontal_align       = "center",
        .vertical_align         = "center",
    };
#ifdef __APPLE__
    ASSERT_FALSE(state.resolved_font_path.empty());
#endif

    const auto size = TextLayerRasterSize(state);
    EXPECT_TRUE(size.isApprox(MeasureTextLayerSize(state)));

    const uint32_t       width  = static_cast<uint32_t>(std::ceil(size.x()));
    const uint32_t       height = static_cast<uint32_t>(std::ceil(size.y()));
    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);

    int min_x = static_cast<int>(width);
    int max_x = -1;
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const auto alpha = rgba[(static_cast<std::size_t>(y) * width + x) * 4u + 3u];
            if (alpha == 0u) continue;
            min_x = std::min(min_x, static_cast<int>(x));
            max_x = std::max(max_x, static_cast<int>(x));
        }
    }

    ASSERT_GE(max_x, min_x);
    const float ink_center = (static_cast<float>(min_x) + static_cast<float>(max_x)) * 0.5f;
    EXPECT_NEAR(ink_center, static_cast<float>(width) * 0.5f, 4.0f);
    EXPECT_GE(min_x, 32);
    EXPECT_LE(max_x, static_cast<int>(width) - 32);
}

TEST(TextObjectRuntime, DynamicTextTransformSettingsUpdateRuntimeNode) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "text_origin", RuntimeScalarValue::String("30 40 0") },
          { "text_scale", RuntimeScalarValue::Float(2.5f) },
    };
    SceneParseRequest request {
        .scene_id           = "text-dynamic-transform",
        .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "clock",
            "font": "Arial",
            "pointsize": 20,
            "origin": {"value": "10 20 0", "user": "text_origin"},
            "scale": {"value": "1 1 1", "user": "text_scale"},
            "horizontalalign": "center",
            "verticalalign": "center",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);

    EXPECT_FLOAT_EQ(node->Translate().x(), 30.0f);
    EXPECT_FLOAT_EQ(node->Translate().y(), 40.0f);
    EXPECT_FLOAT_EQ(node->Scale().x(), 2.5f);
    EXPECT_FLOAT_EQ(node->Scale().y(), 2.5f);

    scene->runtime->ApplyProjectPropertyOverride({
        { "text_origin", RuntimeScalarValue::String("50 60 0") },
        { "text_scale", RuntimeScalarValue::Float(3.0f) },
    });
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_FLOAT_EQ(node->Translate().x(), 50.0f);
    EXPECT_FLOAT_EQ(node->Translate().y(), 60.0f);
    EXPECT_FLOAT_EQ(node->Scale().x(), 3.0f);
    EXPECT_FLOAT_EQ(node->Scale().y(), 3.0f);
}

TEST(TextObjectRuntime, DynamicTextTransformScriptsUseCanvasSize) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "x", RuntimeScalarValue::Float(0.8f) },
          { "y", RuntimeScalarValue::Float(0.25f) },
    };
    SceneParseRequest request {
        .scene_id           = "text-dynamic-transform-script",
        .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              R"JSON({
          "camera": {"center":[0,0,0], "eye":[0,0,1], "up":[0,1,0]},
          "general": {
            "ambientcolor":[0,0,0], "skylightcolor":[0,0,0],
            "clearcolor":[0,0,0], "cameraparallax":false,
            "cameraparallaxamount":0, "cameraparallaxdelay":0,
            "cameraparallaxmouseinfluence":0,
            "orthogonalprojection":{"width":1000,"height":500}
          },
          "objects": [
            {
              "id": 1,
              "name": "caption",
              "text": "clock",
              "font": "Arial",
              "pointsize": 20,
              "origin": {
                "value": "0 0 0",
                "scriptproperties": {
                  "x": {"user": "x", "value": 0.5},
                  "y": {"user": "y", "value": 0.5}
                },
                "script": "export var scriptProperties = createScriptProperties().addSlider({name:'x',value:0.5}).addSlider({name:'y',value:0.5}).finish(); export function update(value) { value.x = scriptProperties.x * engine.canvasSize.x; value.y = scriptProperties.y * engine.canvasSize.y; return value; }"
              },
              "horizontalalign": "center",
              "verticalalign": "center",
              "visible": true
            }
          ]
        })JSON",
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);

    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_FLOAT_EQ(node->Translate().x(), 800.0f);
    EXPECT_FLOAT_EQ(node->Translate().y(), 125.0f);
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, ParserUsesUniqueTextureKeysForDuplicateTextLayerNames) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "duplicate-text-names",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "duplicate",
            "text": "first",
            "font": "Arial",
            "pointsize": 20,
            "visible": true
          },
          {
            "id": 2,
            "name": "duplicate",
            "text": "second much wider",
            "font": "Arial",
            "pointsize": 20,
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->sceneGraph, nullptr);
    auto* first  = FindRootChild(*scene, "__we_text_1");
    auto* second = FindRootChild(*scene, "__we_text_2");
    ASSERT_NE(first, nullptr);
    ASSERT_NE(second, nullptr);
    ASSERT_NE(first->Mesh(), nullptr);
    ASSERT_NE(second->Mesh(), nullptr);
    auto* first_material  = first->Mesh()->MaterialForSlot(0);
    auto* second_material = second->Mesh()->MaterialForSlot(0);
    ASSERT_NE(first_material, nullptr);
    ASSERT_NE(second_material, nullptr);
    ASSERT_EQ(first_material->textures.size(), 1u);
    ASSERT_EQ(second_material->textures.size(), 1u);

    EXPECT_NE(first_material->textures.front(), second_material->textures.front());
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_text_1"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_text_2"));
    EXPECT_EQ(scene->runtime->NodeText("__we_text_1"), "first");
    EXPECT_EQ(scene->runtime->NodeText("__we_text_2"), "second much wider");
}

TEST(TextObjectRuntime, TextLabelDoesNotStealAnotherLayersName) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
        .scene_id           = "text-name-collision",
        .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
          {
            "id": 10,
            "name": "s",
            "solid": true,
            "scale": "0.20000 0.20000 0.20000",
            "visible": true
          },
          {
            "id": 11,
            "name": "s",
            "text": "label",
            "font": "Arial",
            "pointsize": 32,
            "scale": "0.00010 0.00010 1.00000",
            "visible": true
          },
          {
            "id": 12,
            "name": "driver",
            "origin": {
              "value": "0 0 0",
              "script": "export function update(value) { var layer = thisScene.getLayer('s'); if (layer) layer.scale = {x: 5, y: 5, z: 5}; return value; }"
            }
          }
        ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* body = FindRootChild(*scene, "s");
    auto* label = FindRootChild(*scene, "__we_text_11");
    ASSERT_NE(body, nullptr);
    ASSERT_NE(label, nullptr);

    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_FLOAT_EQ(body->Scale().x(), 5.0f);
    EXPECT_FLOAT_EQ(body->Scale().y(), 5.0f);
    EXPECT_FLOAT_EQ(body->Scale().z(), 5.0f);
    EXPECT_NEAR(label->Scale().x(), 0.0001f, 1e-6f);
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, ParserReadsSupportedTextFormsIntoRuntimeState) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-forms",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "plain", "text": "plain text", "font": "Arial", "visible": true},
          {"id": 2, "name": "nested", "text": {"text": "nested text"}, "font": {"value": "Arial"}, "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->NodeText("plain"), "plain text");
    EXPECT_EQ(scene->runtime->NodeText("nested"), "nested text");
}

TEST(TextObjectRuntime, ParserResolvesFontFamiliesAssetsAndSystemFontAliases) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    { "/fonts/asset.ttf", "fake-font-bytes" },
                    { "/fonts/prefixed.ttf", "fake-font-bytes" },
                });
    ASSERT_TRUE(vfs.Mount("/provided",
                          std::make_unique<MemoryFs>(std::map<std::string, std::string> {
                              { "/absolute.otf", "fake-font-bytes" },
                          })));
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-fonts",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "family", "text": "a", "font": "Arial", "visible": true},
          {"id": 2, "name": "asset", "text": "a", "font": "fonts/asset.ttf", "visible": true},
          {"id": 3, "name": "system", "text": "a", "font": "systemfont_Helvetica", "visible": true},
          {"id": 4, "name": "provided", "text": "a", "font": "/provided/absolute.otf", "visible": true},
          {"id": 5, "name": "prefixed", "text": "a", "font": "assets/fonts/prefixed.ttf", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    auto family = scene->runtime->NodeTextState("family");
    ASSERT_TRUE(family.has_value());
    EXPECT_EQ(family->resolved_font_kind, "family");
    EXPECT_EQ(family->resolved_font_identity, "Arial");

    auto asset = scene->runtime->NodeTextState("asset");
    ASSERT_TRUE(asset.has_value());
    EXPECT_EQ(asset->resolved_font_kind, "asset");
    EXPECT_EQ(asset->resolved_font_path, "/assets/fonts/asset.ttf");
    EXPECT_EQ(std::string(asset->resolved_font_data.begin(), asset->resolved_font_data.end()),
              "fake-font-bytes");

    auto system = scene->runtime->NodeTextState("system");
    ASSERT_TRUE(system.has_value());
    EXPECT_EQ(system->resolved_font_kind, "system");
    EXPECT_EQ(system->resolved_font_identity, "Helvetica");

    auto provided = scene->runtime->NodeTextState("provided");
    ASSERT_TRUE(provided.has_value());
    EXPECT_EQ(provided->resolved_font_kind, "asset");
    EXPECT_EQ(provided->resolved_font_path, "/provided/absolute.otf");
    EXPECT_EQ(std::string(provided->resolved_font_data.begin(), provided->resolved_font_data.end()),
              "fake-font-bytes");

    auto prefixed = scene->runtime->NodeTextState("prefixed");
    ASSERT_TRUE(prefixed.has_value());
    EXPECT_EQ(prefixed->resolved_font_kind, "asset");
    EXPECT_EQ(prefixed->resolved_font_path, "/assets/fonts/prefixed.ttf");
}

TEST(TextObjectRuntime, TextLayerStateCopiesShareResolvedFontData) {
    TextLayerState state {
        .text               = "fps: 60",
        .resolved_font_data = std::vector<uint8_t>(1024, 42),
    };

    const auto copy = state;

    ASSERT_FALSE(state.resolved_font_data.empty());
    ASSERT_FALSE(copy.resolved_font_data.empty());
    EXPECT_EQ(copy.resolved_font_data.data(), state.resolved_font_data.data());
}

TEST(TextObjectRuntime, ParserMapsSystemFontAliasesToPlatformFontPath) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-system-font-path",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "system", "text": "a", "font": "systemfont_Helvetica", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    auto system = scene->runtime->NodeTextState("system");
    ASSERT_TRUE(system.has_value());
    EXPECT_EQ(system->resolved_font_kind, "system");
    EXPECT_EQ(system->resolved_font_identity, "Helvetica");
#ifdef __APPLE__
    EXPECT_FALSE(system->resolved_font_path.empty());
#else
    EXPECT_TRUE(system->resolved_font_path.empty());
#endif
}

TEST(TextObjectRuntime, HiddenTextStillCreatesNodeAndRuntimeState) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "hidden-text",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "hiddenCaption", "text": "secret", "font": "Arial", "visible": false}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_TRUE(scene->runtime->HasNodeNamed("hiddenCaption"));
    EXPECT_EQ(scene->runtime->NodeText("hiddenCaption"), "secret");
    auto* node = FindRootChild(*scene, "hiddenCaption");
    ASSERT_NE(node, nullptr);
    EXPECT_FALSE(node->Visible());
}

TEST(TextObjectRuntime, TextVisibleScriptUpdatesVisibilityOnTick) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-visible-script",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "scripted",
            "font": "Arial",
            "visible": {
              "value": true,
              "script": "export function update(value) { return false; }"
            }
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);

    scene->runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(node->Visible());
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, TextVisibleUserBindingFollowsProjectOverride) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "show_text", RuntimeScalarValue::Bool(true) },
    };
    SceneParseRequest request {
        .scene_id           = "text-visible-user",
        .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "user",
            "font": "Arial",
            "visible": {"value": true, "user": "show_text"}
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    EXPECT_TRUE(node->Visible());

    scene->runtime->ApplyProjectPropertyOverride({
        { "show_text", RuntimeScalarValue::Bool(false) },
    });
    scene->runtime->Tick(1.0 / 60.0);
    EXPECT_FALSE(node->Visible());
}

TEST(TextObjectRuntime, TextScriptsWaitForTheNormalTickBeforeReadingSharedState) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound;
    WPSceneParser parser;
    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id = "text-shared-order", .project_properties = &properties,
    };
    auto scene = parser.Parse(request, MinimalSceneObjects(R"([
        {"id":1,"name":"producer","visible":{"value":true,
         "script":"export function update() { shared.number = (shared.number || 6) + 1; return true; }"}},
        {"id":2,"name":"caption","font":"Arial","text":{"value":"waiting",
         "script":"export function update() { return shared.number.toFixed(1); }"}}
      ])"), vfs, sound);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
    scene->runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "7.0");
    scene->runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "8.0");
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, StaticObjectTextDoesNotOverwriteRuntimeMutationOnTick) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-static-object-field",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": {"text": "before"},
            "font": "Arial",
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "before");

    scene->runtime->SetNodeText("caption", "after");
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_EQ(scene->runtime->NodeText("caption"), "after");
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, EventOnlyTextScriptDoesNotOverwriteRuntimeMutationOnTick) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-event-script-object-field",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
          {
            "id": 1,
            "name": "caption",
            "text": {
              "value": "before",
              "script": "engine.on('custom', function() {})"
            },
            "font": "Arial",
            "visible": true
          }
        ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "before");

    scene->runtime->SetNodeText("caption", "after");
    scene->runtime->Tick(1.0 / 60.0);

    EXPECT_EQ(scene->runtime->NodeText("caption"), "after");
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, EventOnlyTextScriptRegistersAsSceneScript) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-event-script-scene-script",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
          {
            "id": 1,
            "name": "caption",
            "text": {
              "value": "before",
              "script": "engine.on('cursorDown', function() { thisLayer.text = 'clicked'; })"
            },
            "font": "Arial",
            "visible": true
          }
        ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "before");
    EXPECT_EQ(scene->runtime->sceneScriptCount(), 1u);

    scene->runtime->DispatchCursorDown(0);

    EXPECT_EQ(scene->runtime->NodeText("caption"), "clicked");
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

// Wallpaper Engine keeps a string a script wrote to `thisLayer.text` from
// `update()` when `update()` returns nothing, and the scene file's value is only
// the text the layer starts with. The clock scripts that write the time only when
// the minute changes show their placeholder otherwise.
TEST(TextObjectRuntime, ScriptTextWrittenInUpdateIsKeptWhenUpdateReturnsNothing) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-script-write-kept",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
          {
            "id": 1,
            "name": "caption",
            "text": {
              "value": "placeholder",
              "script": "var last; export function update() { var s = 'live'; if (s !== last) { last = s; thisLayer.text = s; } }"
            },
            "font": "Arial",
            "visible": true
          }
        ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "placeholder");

    // The script writes on its first tick only; the ticks after it write
    // nothing, and the layer must not fall back to the placeholder.
    for (int tick = 0; tick < 3; ++tick) {
        scene->runtime->Tick(1.0 / 30.0);
        PumpTextUntilClean(*scene->runtime);
        EXPECT_EQ(scene->runtime->NodeText("caption"), "live") << "tick " << tick;
    }
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, ScriptReadsTheTextItWroteOnTheNextUpdate) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-script-write-continues",
          .project_properties = &properties,
    };

    // `update(value)` is handed the property's current string. Each step below
    // is reached only if the previous explicit write became that string.
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
          {
            "id": 1,
            "name": "caption",
            "text": {
              "value": "placeholder",
              "script": "export function update(value) { if (value === 'placeholder') thisLayer.text = 'first'; else if (value === 'first') thisLayer.text = 'second'; }"
            },
            "font": "Arial",
            "visible": true
          }
        ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    const std::string expected[] = { "first", "second", "second" };
    for (const auto& text : expected) {
        scene->runtime->Tick(1.0 / 30.0);
        PumpTextUntilClean(*scene->runtime);
        EXPECT_EQ(scene->runtime->NodeText("caption"), text);
    }
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, ScriptReturnValueStillReplacesTextTheScriptWrote) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-script-write-then-return",
          .project_properties = &properties,
    };

    // A script that writes and also returns: the value it returns is the
    // property's result, as it always was.
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
          {
            "id": 1,
            "name": "caption",
            "text": {
              "value": "placeholder",
              "script": "export function update() { thisLayer.text = 'written'; return 'returned'; }"
            },
            "font": "Arial",
            "visible": true
          }
        ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    for (int tick = 0; tick < 2; ++tick) {
        scene->runtime->Tick(1.0 / 30.0);
        PumpTextUntilClean(*scene->runtime);
        EXPECT_EQ(scene->runtime->NodeText("caption"), "returned") << "tick " << tick;
    }
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

// Two scripts writing one text: the property's own script decides it. A media
// widget's title layer carries a text script that returns the (empty) title and a
// visibility script that writes the sound layer's name every tick, and Wallpaper
// Engine's frame of it shows the empty title. Which script Wallpaper Engine
// lets win in general is not established; the one frame is what this keeps.
TEST(TextObjectRuntime, TextWrittenByAnotherScriptDoesNotReplaceWhatTheTextScriptReturns) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-written-by-another-script",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
          {
            "id": 1,
            "name": "caption",
            "text": {
              "value": "placeholder",
              "script": "export function update(value) { return ''; }"
            },
            "font": "Arial",
            "visible": {
              "value": true,
              "script": "export function update() { thisLayer.text = 'from the visibility script'; }"
            }
          },
          {
            "id": 2,
            "name": "writer",
            "text": "writer",
            "font": "Arial",
            "visible": {
              "value": true,
              "script": "export function update() { thisScene.getLayer('caption').text = 'from another layer'; thisScene.getLayer('plain').text = 'written'; }"
            }
          },
          {
            "id": 3,
            "name": "plain",
            "text": "plain",
            "font": "Arial",
            "visible": true
          }
        ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    for (int tick = 0; tick < 3; ++tick) {
        scene->runtime->Tick(1.0 / 30.0);
        PumpTextUntilClean(*scene->runtime);
        EXPECT_EQ(scene->runtime->NodeText("caption"), "") << "tick " << tick;
        // A text no property or script is bound to just takes what is written.
        EXPECT_EQ(scene->runtime->NodeText("plain"), "written") << "tick " << tick;
    }
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

// What a text script writes to another layer's text is that layer's business:
// the writer keeps its own value, and the layer's own script has its say.
TEST(TextObjectRuntime, TextScriptWritingAnotherLayersTextKeepsItsOwnValue) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-script-writes-other-layer",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"JSON([
          {
            "id": 1,
            "name": "writer",
            "text": {
              "value": "writer placeholder",
              "script": "export function update() { thisScene.getLayer('target').text = 'from the writer'; }"
            },
            "font": "Arial",
            "visible": true
          },
          {
            "id": 2,
            "name": "target",
            "text": {
              "value": "target placeholder",
              "script": "export function update() { return 'from the target'; }"
            },
            "font": "Arial",
            "visible": true
          }
        ])JSON"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    for (int tick = 0; tick < 3; ++tick) {
        scene->runtime->Tick(1.0 / 30.0);
        PumpTextUntilClean(*scene->runtime);
        EXPECT_EQ(scene->runtime->NodeText("writer"), "writer placeholder") << "tick " << tick;
        EXPECT_EQ(scene->runtime->NodeText("target"), "from the target") << "tick " << tick;
    }
    EXPECT_EQ(scene->runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, TextParentReusesPlaceholderWhenChildAppearsFirst) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-placeholder",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 2, "name": "childText", "parent": 1, "text": "child", "font": "Arial", "visible": true},
          {"id": 1, "name": "parentText", "text": "parent", "font": "Arial", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* parent = FindRootChild(*scene, "parentText");
    ASSERT_NE(parent, nullptr);
    EXPECT_NE(parent->Mesh(), nullptr);
    ASSERT_EQ(parent->GetChildren().size(), 1u);
    EXPECT_EQ(parent->GetChildren().front()->Name(), "childText");
    EXPECT_EQ(parent->GetChildren().front()->Parent(), parent);
}

TEST(TextObjectRuntime, UnnamedTextPlaceholderDoesNotLeaveStaleRuntimeLayerKey) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "unnamed-text-placeholder",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 2, "name": "childText", "parent": 1, "text": "child", "font": "Arial", "visible": true},
          {"id": 1, "text": "parent", "font": "Arial", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    EXPECT_FALSE(scene->runtime->HasNodeNamed("__we_layer_1"));
    EXPECT_TRUE(scene->runtime->HasNodeNamed("__we_text_1"));
    EXPECT_EQ(scene->runtime->NodeText("__we_text_1"), "parent");
}

TEST(TextObjectRuntime, TextStateUsesRuntimeRgbaTextureBackend) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text       = "layout only",
                                   .font_key   = "Arial",
                                   .point_size = 12.0f,
                               });

    const auto state = runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->render_backend, "runtime-rgba-texture");
}

TEST(TextObjectRuntime, RuntimeTextMutationUpdatesPersistentTextAndSize) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text             = "a",
                                   .font_key         = "Arial",
                                   .point_size       = 10.0f,
                                   .padding          = { 2.0f, 2.0f },
                                   .horizontal_align = "left",
                                   .vertical_align   = "top",
                               });

    const auto before       = runtime->NodeSize("caption");
    const auto before_state = runtime->NodeTextState("caption");
    ASSERT_TRUE(before_state.has_value());
    EXPECT_FALSE(before_state->texture_cache_key.empty());
    EXPECT_EQ(before_state->cache_revision, 1u);
    ASSERT_TRUE(runtime->SetNodeText("caption", "longer text"));

    EXPECT_EQ(runtime->NodeText("caption"), "longer text");
    EXPECT_TRUE(runtime->NodeTextDirty("caption"));

    PumpTextUntilClean(*runtime);

    const auto after = runtime->NodeSize("caption");
    EXPECT_GT(after.x(), before.x());
    EXPECT_FLOAT_EQ(after.y(), before.y());
    const auto dirty_state = runtime->NodeTextState("caption");
    ASSERT_TRUE(dirty_state.has_value());
    EXPECT_EQ(dirty_state->cache_revision, before_state->cache_revision + 1u);
    EXPECT_FALSE(dirty_state->cache_dirty);
    EXPECT_FALSE(dirty_state->full_dirty);

    runtime->ClearNodeTextDirty("caption");
    const auto clean_state = runtime->NodeTextState("caption");
    ASSERT_TRUE(clean_state.has_value());
    EXPECT_EQ(clean_state->text, "longer text");
    EXPECT_EQ(clean_state->cache_revision, dirty_state->cache_revision);
    EXPECT_FALSE(clean_state->cache_dirty);
    EXPECT_FALSE(clean_state->full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
}

TEST(TextObjectRuntime, UnchangedRuntimeTextMutationSkipsDirtyAndCacheRevision) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text             = "12:34",
                                   .font_key         = "systemfont_sansserif",
                                   .point_size       = 33.0f,
                                   .padding          = { 32.0f, 32.0f },
                                   .horizontal_align = "center",
                                   .vertical_align   = "center",
                               });
    runtime->RegisterTextValue("caption", std::make_unique<DynamicValue>("12:34"));
    runtime->ClearNodeTextDirty("caption");
    ASSERT_FALSE(runtime->ConsumeSceneGraphMutationFlag());

    const auto before_state = runtime->NodeTextState("caption");
    ASSERT_TRUE(before_state.has_value());
    ASSERT_FALSE(before_state->cache_dirty);
    ASSERT_FALSE(before_state->full_dirty);

    ResetTextLayerMeasurementCountForTests();
    runtime->Tick(1.0 / 60.0);

    const auto after_state = runtime->NodeTextState("caption");
    ASSERT_TRUE(after_state.has_value());
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_EQ(after_state->cache_revision, before_state->cache_revision);
    EXPECT_FALSE(after_state->cache_dirty);
    EXPECT_FALSE(after_state->full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
    EXPECT_FALSE(runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, Workshop3409533530ClockParentKeepsVisibleRuntimeTexture) {
    fs::VFS vfs;
    MountAssets(vfs,
                {
                    {
                        "/fonts/workshop/3261114750/SourceHanSansCN-Normal.otf",
                        "not-used-by-clock",
                    },
                });
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "clock", RuntimeScalarValue::Bool(true) },
          { "time", RuntimeScalarValue::Bool(true) },
          { "x", RuntimeScalarValue::Float(0.8f) },
          { "y", RuntimeScalarValue::Float(0.25f) },
          { "newproperty1", RuntimeScalarValue::String("1 0.8117647 0.8705882") },
          { "newproperty2", RuntimeScalarValue::Float(2.5f) },
    };
    SceneParseRequest request {
          .scene_id           = "workshop-3409533530-clock-repro",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              R"JSON({
          "camera": {"center":"0.00000 0.00000 -1.00000", "eye":"0.00000 0.00000 0.00000", "up":"0.00000 1.00000 0.00000"},
          "general": {
            "ambientcolor":"0.30000 0.30000 0.30000",
            "skylightcolor":"0.30000 0.30000 0.30000",
            "clearcolor":"0.70000 0.70000 0.70000",
            "clearenabled":true,
            "cameraparallax":false,
            "cameraparallaxamount":0,
            "cameraparallaxdelay":0,
            "cameraparallaxmouseinfluence":0,
            "orthogonalprojection":{"width":3840,"height":2160}
          },
          "objects": [
            {
              "id": 31,
              "name": "Clock",
              "text": {
                "value": "06:15",
                "scriptproperties": {
                  "delimiter": ":",
                  "showCD": false,
                  "showTime": false,
                  "use12hFormat": {"user": "show12h", "value": false}
                },
                "script": "export var scriptProperties = createScriptProperties().addCheckbox({name:'use12hFormat',value:false}).addText({name:'delimiter',value:':'}).addCheckbox({name:'showTime',value:false}).addCheckbox({name:'showCD',value:false}).finish(); export function update(value) { let time = new Date(); var hours = time.getHours(); if (scriptProperties.use12hFormat) { hours %= 12; if (hours == 0) hours = 12; } hours = ('00' + hours).slice(-2); let minutes = ('00' + time.getMinutes()).slice(-2); value = hours + scriptProperties.delimiter + minutes; if (scriptProperties.showTime) value = '\\0'; if (scriptProperties.showCD) value = '\\0'; return value; }"
              },
              "font": "systemfont_sansserif",
              "pointsize": 33.0,
              "padding": 32,
              "size": "342.00000 156.00000",
              "origin": {
                "value": "0.00000 0.00000 0.00000",
                "scriptproperties": {
                  "x": {"user": "x", "value": 1},
                  "y": {"user": "y", "value": 1}
                },
                "script": "export var scriptProperties = createScriptProperties().addSlider({name:'x',value:0.5}).addSlider({name:'y',value:0.5}).finish(); export function update(value) { value.x = scriptProperties.x * engine.canvasSize.x; value.y = scriptProperties.y * engine.canvasSize.y; return value; }"
              },
              "scale": {"user": "newproperty2", "value": "2.50000 2.50000 2.50000"},
              "visible": {"user": "clock", "value": true},
              "color": {"user": "newproperty1", "value": "1.00000 0.81176 0.87059"},
              "horizontalalign": "center",
              "verticalalign": "center",
              "anchor": "none"
            },
            {
              "id": 32,
              "name": "Date",
              "parent": 31,
              "text": "DATE",
              "font": "systemfont_sansserif",
              "pointsize": 20.0,
              "padding": 36,
              "size": "987.00000 125.00000",
              "origin": "283.14212 -113.36209 0.00000",
              "scale": "0.28000 0.28000 0.00000",
              "visible": {"user": "time", "value": true},
              "horizontalalign": "right",
              "verticalalign": "center",
              "anchor": "none"
            },
            {
              "id": 33,
              "name": "Dy",
              "parent": 31,
              "text": "PM",
              "font": "systemfont_sansserif",
              "pointsize": 32.0,
              "padding": 32,
              "size": "190.00000 200.00000",
              "origin": "230.29727 -31.03779 0.00000",
              "scale": "0.61854 0.56577 0.43846",
              "horizontalalign": "center",
              "verticalalign": "center",
              "anchor": "none"
            }
          ]
        })JSON",
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* runtime = scene->runtime.get();

    auto* clock = FindRootChild(*scene, "Clock");
    ASSERT_NE(clock, nullptr);
    ASSERT_NE(clock->Mesh(), nullptr);
    ASSERT_EQ(clock->GetChildren().size(), 2u);
    EXPECT_EQ(clock->GetChildren().front()->Name(), "Date");
    EXPECT_EQ(clock->GetChildren().back()->Name(), "Dy");

    runtime->Tick(1.0 / 60.0);
    PumpTextUntilClean(*runtime);

    EXPECT_TRUE(runtime->NodeVisible("Clock"));
    EXPECT_TRUE(clock->EffectiveVisible());
    EXPECT_NE(runtime->NodeText("Clock"), std::string("\0", 1));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);

    const auto translate = runtime->NodeTranslate("Clock");
    const auto scale     = runtime->NodeScale("Clock");
    EXPECT_NEAR(translate.x(), 3072.0f, 1.0e-3f);
    EXPECT_NEAR(translate.y(), 540.0f, 1.0e-3f);
    EXPECT_NEAR(scale.x(), 2.5f, 1.0e-3f);
    EXPECT_NEAR(scale.y(), 2.5f, 1.0e-3f);

    auto state = runtime->NodeTextState("Clock");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->resolved_font_kind, "system");
#ifdef __APPLE__
    EXPECT_FALSE(state->resolved_font_path.empty());
#endif

    auto* material = clock->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    // The authored `size` is ignored: the texture is the card of the time it shows.
    const auto card = MeasureTextLayerSize(*state);
    EXPECT_EQ(image->header.width, static_cast<int>(std::ceil(card.x())));
    EXPECT_EQ(image->header.height, static_cast<int>(std::ceil(card.y())));
    EXPECT_GT(image->header.width, 100);
    EXPECT_GT(VisibleAlphaPixels(*image), 200);

    runtime->ClearNodeTextDirty("Clock");
    ResetTextLayerMeasurementCountForTests();
    runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
}

TEST(TextObjectRuntime, Workshop3409533530FullSceneKeepsClockRenderPassAndTexture) {
    const auto home = HomePath();
    if (home.empty()) GTEST_SKIP() << "HOME is not set";

    const auto workshop_root =
        home / "Library/Application Support/Steam/steamapps/workshop/content/431960/3409533530";
    const auto project_json = ReadTextFile(workshop_root / "project.json");
    if (! project_json.has_value() || ! std::filesystem::exists(workshop_root / "scene.pkg")) {
        GTEST_SKIP() << "local workshop 3409533530 package is not available";
    }

    fs::VFS vfs;
    const auto common_assets =
        home / "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets";
    if (std::filesystem::exists(common_assets)) {
        ASSERT_TRUE(MountPhysicalAssets(vfs, common_assets));
    }
    ASSERT_TRUE(vfs.Mount("/assets", fs::WPPkgFs::CreatePkgFs((workshop_root / "scene.pkg").string())));
    auto scene_stream = vfs.Open("/assets/scene.json");
    ASSERT_NE(scene_stream, nullptr);
    const auto scene_json = scene_stream->ReadAllStr();

    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties {
          { "clock", RuntimeScalarValue::Bool(true) },
          { "time", RuntimeScalarValue::Bool(true) },
          { "x", RuntimeScalarValue::Float(0.8f) },
          { "y", RuntimeScalarValue::Float(0.25f) },
          { "newproperty1", RuntimeScalarValue::String("1 0.8117647 0.8705882") },
          { "newproperty2", RuntimeScalarValue::Float(2.5f) },
    };
    SceneParseRequest request {
          .scene_id           = "workshop-3409533530-full-scene-clock-repro",
          .project_path       = (workshop_root / "project.json").string(),
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request, scene_json, vfs, sound_manager);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);

    auto* clock = FindRootChild(*scene, "Clock");
    ASSERT_NE(clock, nullptr);
    ASSERT_NE(clock->Mesh(), nullptr);
    EXPECT_GE(clock->GetChildren().size(), 4u);

    auto* runtime = scene->runtime.get();
    runtime->Tick(1.0 / 60.0);
    runtime->PumpTextLayerCache();

    EXPECT_TRUE(runtime->NodeVisible("Clock"));
    EXPECT_TRUE(clock->EffectiveVisible());
    EXPECT_NE(runtime->NodeText("Clock"), std::string("\0", 1));
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);

    auto* material = clock->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    EXPECT_EQ(material->textures.front(), TextTextureName("Clock"));
    auto image = scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    EXPECT_GT(VisibleAlphaPixels(*image), 200);

    const auto graph = sceneToRenderGraph(*scene);
    ASSERT_NE(graph, nullptr);
    const auto* clock_pass = FindCustomPassForNode(*graph, clock);
    ASSERT_NE(clock_pass, nullptr);
    ASSERT_EQ(clock_pass->desc().textures.size(), 1u);
    EXPECT_EQ(clock_pass->desc().textures.front(), TextTextureName("Clock"));
    EXPECT_EQ(clock_pass->desc().visibility_node, clock);
    EXPECT_EQ(clock_pass->desc().output, SpecTex_Default);
    EXPECT_NE(clock_pass->desc().uploaded_mesh_dirty_generation, clock->Mesh()->DirtyGeneration());

    runtime->ClearNodeTextDirty("Clock");
    ResetTextLayerMeasurementCountForTests();
    runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
}

TEST(TextObjectRuntime, DynamicTextPassStartsWithPendingInitialZeroGenerationUpload) {
    SceneMesh mesh(MeshUpdate::OnEvent);
    ASSERT_TRUE(mesh.Dynamic());
    ASSERT_EQ(mesh.DirtyGeneration(), 0u);

    vulkan::CustomShaderPass::Desc desc;
    vulkan::CustomShaderPass       pass(desc);

    EXPECT_NE(pass.desc().uploaded_mesh_dirty_generation, mesh.DirtyGeneration());
}

TEST(TextObjectRuntime, RuntimeTextMutationResizesRenderableMesh) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-runtime-mesh-resize",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "caption", "text": "a", "font": "Arial", "pointsize": 10, "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    EXPECT_TRUE(node->Mesh()->Dynamic());

    auto mesh_width = [](const SceneMesh& mesh) {
        const auto& vertices = mesh.GetVertexArray(0);
        const auto  stride   = vertices.OneSize();
        const auto* data     = vertices.Data();
        float       min_x    = data[0];
        float       max_x    = data[0];
        for (std::size_t index = 1; index < vertices.VertexCount(); ++index) {
            const float x = data[index * stride];
            min_x         = std::min(min_x, x);
            max_x         = std::max(max_x, x);
        }
        return max_x - min_x;
    };

    const auto before_size  = scene->runtime->NodeSize("caption");
    const auto before_width = mesh_width(*node->Mesh());

    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "aaaaaaaaaa"));
    PumpTextUntilClean(*scene->runtime);

    const auto after_size  = scene->runtime->NodeSize("caption");
    const auto after_width = mesh_width(*node->Mesh());
    EXPECT_GT(after_size.x(), before_size.x());
    EXPECT_GT(after_width, before_width);
    EXPECT_NEAR(after_width, after_size.x(), 1.0f);
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, AlignedTextKeepsItsNodeAndMovesItsCardWhenTheTextChanges) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-reanchor",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "caption", "text": "a", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "horizontalalign": "right", "verticalalign": "bottom", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    const Eigen::Vector3f origin(100.0f, 50.0f, 0.0f);
    EXPECT_TRUE(node->Translate().isApprox(origin));
    const auto before_size = scene->runtime->NodeSize("caption");
    EXPECT_NEAR(MeshLocalBounds(*node->Mesh()).max_x, 0.0f, 1.0e-3f);

    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "aaaaaaaaaa"));
    PumpTextUntilClean(*scene->runtime);

    // The layer is where the scene put it, and the card grew to the left of it: the right
    // edge of the text is still on the origin.
    const auto after_size = scene->runtime->NodeSize("caption");
    EXPECT_GT(after_size.x(), before_size.x());
    EXPECT_TRUE(node->Translate().isApprox(origin));
    const auto bounds = MeshLocalBounds(*node->Mesh());
    EXPECT_NEAR(bounds.max_x, 0.0f, 1.0e-3f);
    EXPECT_NEAR(bounds.min_x, -after_size.x(), 1.0e-3f);
    // Bottom aligned: the descender line of the (only) row is on the origin.
    const auto layout = scene->runtime->NodeTextLayout("caption");
    ASSERT_TRUE(layout.has_value());
    EXPECT_NEAR(bounds.max_y, layout->top + layout->descender, 1.0e-3f);
    EXPECT_NEAR(bounds.min_y, layout->bottom + layout->descender, 1.0e-3f);
}

TEST(TextObjectRuntime, AScaledAlignedTextHasItsCardEdgeOnTheOriginWhateverItsSize) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-scaled-reanchor",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "caption", "text": "aa", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "scale": [2, 3, 1], "horizontalalign": "right", "verticalalign": "bottom", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);

    // The node is the origin the scene gave; the card, at the layer's scale of (2, 3), ends
    // on the origin and its bottom-aligned descender line is on it.
    const auto world_edges = [&] {
        const auto  bounds = MeshLocalBounds(*node->Mesh());
        const auto  layout = scene->runtime->NodeTextLayout("caption");
        EXPECT_TRUE(layout.has_value());
        EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(100.0f, 50.0f, 0.0f)));
        EXPECT_NEAR(node->Translate().x() + 2.0f * bounds.max_x, 100.0f, 1.0e-3f);
        EXPECT_NEAR(node->Translate().y() + 3.0f * bounds.max_y,
                    50.0f + 3.0f * (layout->top + layout->descender), 1.0e-3f);
        return node->Translate().x() + 2.0f * bounds.min_x;
    };
    const auto size = scene->runtime->NodeSize("caption");
    EXPECT_NEAR(world_edges(), 100.0f - 2.0f * size.x(), 1.0e-3f);

    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "aaaaaa"));
    PumpTextUntilClean(*scene->runtime);
    const auto resized = scene->runtime->NodeSize("caption");
    EXPECT_GT(resized.x(), size.x());
    EXPECT_NEAR(world_edges(), 100.0f - 2.0f * resized.x(), 1.0e-3f);
}

TEST(TextObjectRuntime, PumpTextLayerCacheClearsDirtyStateWithoutLosingText) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text       = "before",
                                   .font_key   = "Arial",
                                   .point_size = 12.0f,
                               });

    ASSERT_TRUE(runtime->SetNodeText("caption", "after"));
    ASSERT_TRUE(runtime->NodeTextDirty("caption"));
    PumpTextUntilClean(*runtime);

    const auto state = runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_EQ(state->text, "after");
    EXPECT_FALSE(state->cache_dirty);
    EXPECT_FALSE(state->full_dirty);
    EXPECT_FALSE(runtime->NodeTextDirty("caption"));
}

TEST(TextObjectRuntime, PumpTextLayerCacheDoesNotKeepDirtyWhenSceneCannotAcceptRuntimeTexture) {
    Scene scene;
    scene.runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(scene.runtime, nullptr);
    scene.runtime->AttachScene(&scene);

    auto node = std::make_shared<SceneNode>();
    scene.runtime->RegisterNode("caption", node.get());
    scene.runtime->RegisterTextLayer("caption",
                                     TextLayerState {
                                         .text       = "before",
                                         .font_key   = "Arial",
                                         .point_size = 12.0f,
                                     });

    ASSERT_TRUE(scene.runtime->SetNodeText("caption", "after"));
    ASSERT_TRUE(scene.runtime->NodeTextDirty("caption"));

    PumpTextUntilClean(*scene.runtime);

    const auto state = scene.runtime->NodeTextState("caption");
    ASSERT_TRUE(state.has_value());
    EXPECT_FALSE(state->cache_dirty);
    EXPECT_FALSE(state->full_dirty);
    EXPECT_FALSE(scene.runtime->NodeTextDirty("caption"));
    EXPECT_FALSE(scene.runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, PumpTextLayerCacheRerasterizesAttachedSceneTexture) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-rerasterize",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "caption", "text": "a", "font": "Arial", "pointsize": 20, "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    const auto texture_name = material->textures.front();

    auto before = scene->imageParser->Parse(texture_name);
    ASSERT_NE(before, nullptr);
    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "aaaaaa"));
    ASSERT_TRUE(scene->runtime->NodeTextDirty("caption"));

    PumpTextUntilClean(*scene->runtime);

    auto after = scene->imageParser->Parse(texture_name);
    ASSERT_NE(after, nullptr);
    EXPECT_NE(before->key, after->key);
    EXPECT_GT(after->header.width, before->header.width);
    EXPECT_FALSE(scene->runtime->NodeTextDirty("caption"));
    EXPECT_FALSE(scene->runtime->ConsumeSceneGraphMutationFlag());
}

TEST(TextObjectRuntime, PumpTextLayerCacheSkipsHiddenTextUntilVisible) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "hidden-text-cache-pump",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "before",
            "font": "Arial",
            "pointsize": 20,
            "visible": false
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    const auto texture_name = material->textures.front();

    auto before = scene->imageParser->Parse(texture_name);
    ASSERT_NE(before, nullptr);
    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "after"));
    ASSERT_TRUE(scene->runtime->NodeTextDirty("caption"));

    scene->runtime->PumpTextLayerCache();

    auto hidden = scene->imageParser->Parse(texture_name);
    ASSERT_NE(hidden, nullptr);
    EXPECT_EQ(hidden->key, before->key);
    EXPECT_TRUE(scene->runtime->NodeTextDirty("caption"));

    scene->runtime->SetNodeVisible("caption", true);
    PumpTextUntilClean(*scene->runtime);

    auto visible = scene->imageParser->Parse(texture_name);
    ASSERT_NE(visible, nullptr);
    EXPECT_NE(visible->key, before->key);
    EXPECT_FALSE(scene->runtime->NodeTextDirty("caption"));
}

TEST(TextObjectRuntime, RuntimeTextMutationDoesNotMeasureSynchronously) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text          = "fps: 59",
                                   .font_key      = "Arial",
                                   .point_size    = 20.0f,
                                   .padding       = { 32.0f, 32.0f },
                               });
    runtime->ClearNodeTextDirty("caption");
    ASSERT_FALSE(runtime->NodeTextDirty("caption"));

    ResetTextLayerMeasurementCountForTests();
    ASSERT_TRUE(runtime->SetNodeText("caption", "fps: 60"));

    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_TRUE(runtime->NodeTextDirty("caption"));
}

TEST(TextObjectRuntime, RuntimeTextMutationDefersVisibleTextPreparation) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "visible-text-async-preparation",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "before",
            "font": "Arial",
            "pointsize": 28,
            "padding": 32,
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto* node = FindRootChild(*scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    ASSERT_EQ(material->textures.size(), 1u);
    const auto texture_name = material->textures.front();

    auto before = scene->imageParser->Parse(texture_name);
    ASSERT_NE(before, nullptr);

    ResetTextLayerMeasurementCountForTests();
    ASSERT_TRUE(scene->runtime->SetNodeText("caption", "after after after"));
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 0u);
    EXPECT_EQ(scene->runtime->NodeText("caption"), "after after after");
    EXPECT_TRUE(scene->runtime->NodeTextDirty("caption"));

    scene->runtime->PumpTextLayerCache();
    auto queued = scene->imageParser->Parse(texture_name);
    ASSERT_NE(queued, nullptr);
    EXPECT_EQ(queued->key, before->key);
    EXPECT_TRUE(scene->runtime->NodeTextDirty("caption"));

    std::shared_ptr<Image> updated;
    for (int attempt = 0; attempt < 200; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        scene->runtime->PumpTextLayerCache();
        updated = scene->imageParser->Parse(texture_name);
        ASSERT_NE(updated, nullptr);
        if (updated->key != before->key) break;
    }

    ASSERT_NE(updated, nullptr);
    EXPECT_NE(updated->key, before->key);
    EXPECT_FALSE(scene->runtime->NodeTextDirty("caption"));
}

TEST(TextObjectRuntime, TextCacheKeysAreUniquePerLayerEvenWithSameFontAndSize) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto first  = std::make_shared<SceneNode>();
    auto second = std::make_shared<SceneNode>();
    runtime->RegisterNode("first", first.get());
    runtime->RegisterNode("second", second.get());
    runtime->RegisterTextLayer("first",
                               TextLayerState {
                                   .text       = "one",
                                   .font_key   = "Arial",
                                   .point_size = 12.0f,
                               });
    runtime->RegisterTextLayer("second",
                               TextLayerState {
                                   .text       = "two",
                                   .font_key   = "Arial",
                                   .point_size = 12.0f,
                               });

    const auto first_state  = runtime->NodeTextState("first");
    const auto second_state = runtime->NodeTextState("second");
    ASSERT_TRUE(first_state.has_value());
    ASSERT_TRUE(second_state.has_value());
    EXPECT_NE(first_state->texture_cache_key, second_state->texture_cache_key);
}

// A text object has no `alignment` key in Wallpaper Engine's registry, only
// `horizontalalign`, `verticalalign` and the screen `anchor`: a scene that carries
// one has it ignored, so a layer with only that key is centred like any other.
TEST(TextObjectRuntime, HorizontalAlignIsTheOnlyKeyThatAlignsTheTextHorizontally) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-align-horizontal",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "fallback", "text": "aaaa", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "alignment": "left", "visible": true},
          {"id": 2, "name": "override", "text": "aaaa", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "alignment": "left", "horizontalalign": "right", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* fallback = FindRootChild(*scene, "fallback");
    auto* override = FindRootChild(*scene, "override");
    ASSERT_NE(fallback, nullptr);
    ASSERT_NE(override, nullptr);
    // Neither is moved: the key only says which edge of the text the origin sits on. The
    // key-less layer is centred (the card straddles the origin), the other ends on it.
    for (auto* node : { fallback, override }) {
        EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(100.0f, 50.0f, 0.0f)));
    }
    ASSERT_NE(fallback->Mesh(), nullptr);
    ASSERT_NE(override->Mesh(), nullptr);
    EXPECT_NEAR(MeshCenter(*fallback->Mesh()).x(), 0.0f, 1.0e-3f);
    EXPECT_NEAR(MeshLocalBounds(*override->Mesh()).max_x, 0.0f, 1.0e-3f);
    EXPECT_LT(MeshCenter(*override->Mesh()).x(), -1.0f);
    EXPECT_EQ(scene->runtime->NodeTextState("fallback")->horizontal_align, "center");
}

TEST(TextObjectRuntime, VerticalAlignIsTheOnlyKeyThatAlignsTheTextVertically) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;
    ProjectProperties   properties;
    SceneParseRequest   request {
          .scene_id           = "text-align-vertical",
          .project_properties = &properties,
    };

    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {"id": 1, "name": "fallback", "text": "aaaa", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "alignment": "top", "visible": true},
          {"id": 2, "name": "override", "text": "aaaa", "font": "Arial", "pointsize": 10, "origin": [100, 50, 0], "alignment": "top", "verticalalign": "bottom", "visible": true}
        ])"),
                              vfs,
                              sound_manager);

    ASSERT_NE(scene, nullptr);
    auto* fallback = FindRootChild(*scene, "fallback");
    auto* override = FindRootChild(*scene, "override");
    ASSERT_NE(fallback, nullptr);
    ASSERT_NE(override, nullptr);
    for (auto* node : { fallback, override }) {
        EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(100.0f, 50.0f, 0.0f)));
    }
    ASSERT_NE(fallback->Mesh(), nullptr);
    ASSERT_NE(override->Mesh(), nullptr);
    // The key-less layer is centred on its rows, the other has the text above its origin.
    EXPECT_GT(MeshCenter(*override->Mesh()).y(), MeshCenter(*fallback->Mesh()).y() + 1.0f);
    EXPECT_NEAR(MeshCenter(*fallback->Mesh()).x(), 0.0f, 1.0e-3f);
    EXPECT_NEAR(MeshCenter(*override->Mesh()).x(), 0.0f, 1.0e-3f);
    EXPECT_EQ(scene->runtime->NodeTextState("fallback")->vertical_align, "center");
}

TEST(TextObjectRuntime, ScriptThisLayerTextSetterMutatesRuntimeText) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {});
    ASSERT_NE(runtime, nullptr);

    auto node = std::make_shared<SceneNode>();
    runtime->RegisterNode("caption", node.get());
    runtime->RegisterTextLayer("caption",
                               TextLayerState {
                                   .text       = "before",
                                   .font_key   = "Arial",
                                   .point_size = 12.0f,
                                   .padding    = { 0.0f, 0.0f },
                               });

    auto program = runtime->scriptEngine().CreatePropertyScriptProgram(runtime.get(),
                                                                       R"JS(
export function update(value) {
  thisLayer.text = "after";
  var indirect = thisScene.getLayer('caption');
  indirect.text = indirect.text + " indirect";
  return thisLayer.text === "after indirect" ? 1 : -1;
}
)JS",
                                                                       "caption",
                                                                       {},
                                                                       DynamicValue(0.0f),
                                                                       runtime->hostContext());
    ASSERT_NE(program, nullptr);

    const auto result = program->Evaluate(runtime->hostContext(), DynamicValue(0.0f));
    ASSERT_NE(result, nullptr);
    EXPECT_FLOAT_EQ(result->getFloat(), 1.0f);
    EXPECT_EQ(runtime->NodeText("caption"), "after indirect");
    EXPECT_EQ(runtime->scriptErrorCount(), 0u);
}

TEST(TextObjectRuntime, FontFallbackHandlesFamiliesMissingFilesAndCorruptAssets) {
#ifdef __APPLE__
    const auto reference_path = ResolveSystemFontPath("systemfont_sansserif");
    ASSERT_FALSE(reference_path.empty());
    std::ifstream font_file(reference_path, std::ios::binary);
    const std::vector<uint8_t> valid_font((std::istreambuf_iterator<char>(font_file)), {});
    ASSERT_FALSE(valid_font.empty());
    for (const auto* family : {"systemfont_consolas", "systemfont_Segoe UI", "Arial",
                              "systemfont_serif", "systemfont_monospace", "missing-font-98765", ""}) {
        for (const auto* text : {"08:36", "Monday September", "Bonjour 你好"}) {
            TextLayerState reference {
                .text = text, .font_key = family,
                .resolved_font_path = ResolveSystemFontPath(family), .point_size = 20, .padding = { 4.0f, 4.0f },
            };
            if (reference.resolved_font_path.empty()) reference.resolved_font_path = reference_path;
            const auto raster = [](const TextLayerState& state) {
                const auto size = TextLayerRasterSize(state);
                const auto width = static_cast<uint32_t>(std::ceil(size.x()));
                const auto height = static_cast<uint32_t>(std::ceil(size.y()));
                std::vector<uint8_t> rgba(width * height * 4, 0);
                RasterizeTextLayer(state, width, height, rgba);
                return rgba;
            };
            const auto expected = raster(reference);
            for (int failure = 0; failure < 3; ++failure) {
                SCOPED_TRACE(::testing::Message() << family << ':' << text << ':' << failure);
                auto state = reference;
                state.resolved_font_path = failure == 0 ? "" : "/missing/workshop/font.ttf";
                if (failure == 2) state.resolved_font_data = std::vector<uint8_t>{1,2,3,4};
                EXPECT_EQ(TextLayerRasterSize(state), TextLayerRasterSize(reference));
                EXPECT_EQ(raster(state), expected);
            }
            // A valid embedded font wins even when the requested family is absent.
            auto embedded = reference;
            embedded.resolved_font_path = "/virtual/font.ttf";
            embedded.resolved_font_data = valid_font;
            auto installed = reference;
            installed.resolved_font_path = reference_path;
            EXPECT_EQ(raster(embedded), raster(installed));
        }
    }
#endif
}

TEST(TextObjectRuntime, MissingWindowsFontUsesRealGlyphsInsteadOfRectangles) {
#ifdef __APPLE__
    TextLayerState state {
        .text = "08:36",
        .font_key = "systemfont_consolas",
        .resolved_font_path = ResolveSystemFontPath("systemfont_consolas"),
        .point_size = 33.0f,
        .padding = { 32.0f, 32.0f },
    };
    ASSERT_FALSE(state.resolved_font_path.empty());
    EXPECT_TRUE(std::filesystem::exists(state.resolved_font_path));
    EXPECT_FALSE(ResolveSystemFontPath("systemfont_missing-workshop-font-12345").empty());
    const auto size = TextLayerRasterSize(state);
    const auto width = static_cast<uint32_t>(std::ceil(size.x()));
    const auto height = static_cast<uint32_t>(std::ceil(size.y()));
    std::vector<uint8_t> rgba(width * height * 4, 0);
    RasterizeTextLayer(state, width, height, rgba);
    uint32_t min_y = height, max_y = 0;
    std::size_t antialiased = 0;
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const auto alpha = rgba[(y * width + x) * 4 + 3];
            if (alpha) { min_y = std::min(min_y, y); max_y = std::max(max_y, y); }
            if (alpha > 0 && alpha < 255) ++antialiased;
        }
    }
    EXPECT_GT(max_y - min_y, 60u); // Placeholder bars were only 30 px tall.
    EXPECT_GT(antialiased, 100u);
#endif
}

TEST(TextObjectRuntime, ResolvesWallpaperEngineSansSerifSystemFontAlias) {
#ifdef __APPLE__
    EXPECT_FALSE(ResolveSystemFontPath("systemfont_sansserif").empty());
#endif
}

TEST(TextObjectRuntime, FreeTypeRasterizationFallsBackForMissingPrimaryGlyph) {
#ifdef __APPLE__
    TextLayerState state {
        .text                   = "\xE4\xB8\xAD",
        .font_key               = "systemfont_Helvetica",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "Helvetica",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_Helvetica"),
        .point_size             = 40.0f,
        .padding                = { 4.0f, 4.0f },
    };
    ASSERT_FALSE(state.resolved_font_path.empty());

    const auto size = TextLayerRasterSize(state);
    EXPECT_GT(size.x(), 40.0f);
    EXPECT_GT(size.y(), 40.0f);

    const auto           width  = static_cast<uint32_t>(std::ceil(size.x()));
    const auto           height = static_cast<uint32_t>(std::ceil(size.y()));
    std::vector<uint8_t> rgba(static_cast<std::size_t>(width) * height * 4u, 0u);
    RasterizeTextLayer(state, width, height, rgba);

    TextLayerState unsupported_state = state;
    unsupported_state.text           = "\xF4\x8F\xBF\xBF";
    const auto unsupported_size      = TextLayerRasterSize(unsupported_state);
    const auto unsupported_width     = static_cast<uint32_t>(std::ceil(unsupported_size.x()));
    const auto unsupported_height    = static_cast<uint32_t>(std::ceil(unsupported_size.y()));
    std::vector<uint8_t> unsupported_rgba(
        static_cast<std::size_t>(unsupported_width) * unsupported_height * 4u, 0u);
    RasterizeTextLayer(unsupported_state, unsupported_width, unsupported_height, unsupported_rgba);

    int min_x = static_cast<int>(width);
    int max_x = -1;
    int min_y = static_cast<int>(height);
    int max_y = -1;
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            const auto alpha = rgba[(static_cast<std::size_t>(y) * width + x) * 4u + 3u];
            if (alpha == 0u) continue;
            min_x = std::min(min_x, static_cast<int>(x));
            max_x = std::max(max_x, static_cast<int>(x));
            min_y = std::min(min_y, static_cast<int>(y));
            max_y = std::max(max_y, static_cast<int>(y));
        }
    }

    ASSERT_GE(max_x, min_x);
    ASSERT_GE(max_y, min_y);
    EXPECT_GT(max_x - min_x + 1, 20);
    EXPECT_GT(max_y - min_y + 1, 20);
    EXPECT_NE(rgba, unsupported_rgba);
#endif
}


TEST(TextObjectRuntime, AWaitingClockIsNotStarvedByNewerReadoutUpdates) {
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound;
    WPSceneParser parser;
    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id = "text-queue-fairness", .project_properties = &properties,
    };
    auto scene = parser.Parse(request, MinimalSceneObjects(R"([
        {"id":1,"name":"clock","text":"00:00","font":"Arial","pointsize":20},
        {"id":2,"name":"caption","text":"idle","font":"Arial","pointsize":20}
      ])"), vfs, sound);
    ASSERT_NE(scene, nullptr);
    auto& runtime = *scene->runtime;
    const auto before = scene->imageParser->Parse(TextTextureName("clock"));
    ASSERT_NE(before, nullptr);
    struct Gate {
        std::mutex mutex;
        std::condition_variable cv;
        int completed { 0 };
        int released { 0 };
        bool stop { false };
    };
    auto gate = std::make_shared<Gate>();
    runtime.SetContentWakeHandler([gate] {
        std::unique_lock lock(gate->mutex);
        const int completed = ++gate->completed;
        gate->cv.notify_all();
        gate->cv.wait(lock, [&] { return gate->stop || gate->released >= completed; });
    });
    struct ReleaseGate {
        SceneRuntimeContext& runtime;
        std::shared_ptr<Gate> gate;
        ~ReleaseGate() {
            {
                std::lock_guard lock(gate->mutex);
                gate->stop = true;
            }
            gate->cv.notify_all();
            runtime.SetContentWakeHandler({});
        }
    } release { runtime, gate };
    const auto wait_for = [&](int count) {
        std::unique_lock lock(gate->mutex);
        return gate->cv.wait_for(lock, std::chrono::seconds(2),
                                 [&] { return gate->completed >= count; });
    };
    ASSERT_TRUE(runtime.SetNodeText("caption", "first"));
    runtime.PumpTextLayerCache();
    ASSERT_TRUE(wait_for(1));
    ASSERT_TRUE(runtime.SetNodeText("clock", "12:34"));
    runtime.PumpTextLayerCache();
    ASSERT_TRUE(runtime.SetNodeText("caption", "second"));
    runtime.PumpTextLayerCache();
    ASSERT_TRUE(runtime.SetNodeText("caption", "third"));
    runtime.PumpTextLayerCache();
    {
        std::lock_guard lock(gate->mutex);
        gate->released = 1;
    }
    gate->cv.notify_all();
    ASSERT_TRUE(wait_for(2));
    runtime.PumpTextLayerCache();
    const auto updated = scene->imageParser->Parse(TextTextureName("clock"));
    ASSERT_NE(updated, nullptr);
    EXPECT_NE(updated->key, before->key);
    EXPECT_FALSE(runtime.NodeTextDirty("clock"));
    EXPECT_TRUE(runtime.NodeTextDirty("caption"));

    // Complete "third", then change the requested value before publishing it.
    // The readout must show the completed glyphs, not stay blank until it stops.
    const auto third = runtime.NodeTextState("caption").value();
    {
        std::lock_guard lock(gate->mutex);
        gate->released = 2;
    }
    gate->cv.notify_all();
    ASSERT_TRUE(wait_for(3));
    ASSERT_TRUE(runtime.SetNodeText("caption", "fourth"));
    runtime.PumpTextLayerCache();
    const auto expect_pixels = [&](const TextLayerState& state) {
        const auto image = scene->imageParser->Parse(TextTextureName("caption"));
        ASSERT_NE(image, nullptr);
        ASSERT_FALSE(image->slots.empty());
        ASSERT_FALSE(image->slots[0].mipmaps.empty());
        const auto& mip = image->slots[0].mipmaps[0];
        const auto size = TextLayerRasterSize(state);
        ASSERT_EQ(mip.width, static_cast<int>(std::ceil(size.x())));
        ASSERT_EQ(mip.height, static_cast<int>(std::ceil(size.y())));
        std::vector<uint8_t> expected(static_cast<std::size_t>(mip.width) * mip.height * 4);
        RasterizeTextLayer(state, mip.width, mip.height, expected);
        ASSERT_NE(mip.data, nullptr);
        EXPECT_TRUE(std::equal(expected.begin(), expected.end(), mip.data.get()));
    };
    expect_pixels(third);
    EXPECT_EQ(runtime.NodeText("caption"), "fourth");
    EXPECT_TRUE(runtime.NodeTextDirty("caption"));
    EXPECT_TRUE(runtime.TextLayoutInFlight());
    {
        std::lock_guard lock(gate->mutex);
        gate->released = 3;
    }
    gate->cv.notify_all();
    ASSERT_TRUE(wait_for(4));
    runtime.PumpTextLayerCache();
    expect_pixels(runtime.NodeTextState("caption").value());
    EXPECT_FALSE(runtime.NodeTextDirty("caption"));
    EXPECT_FALSE(runtime.TextLayoutInFlight());
}

TEST(TextObjectRuntime, PreparedTextWakesWhoeverOwnsTheFrameClock) {
    // A scene that has gone quiet has no clock left to notice that the text
    // worker finished. Without this the new image would sit in the queue until
    // something unrelated happened to ask for a frame -- which, for a wallpaper
    // that idles correctly, is never.
    fs::VFS vfs;
    MountAssets(vfs);
    audio::SoundManager sound_manager;
    WPSceneParser       parser;

    ProjectProperties properties;
    SceneParseRequest request {
        .scene_id           = "text-wake-handler",
        .project_properties = &properties,
    };
    auto scene = parser.Parse(request,
                              MinimalSceneObjects(R"([
          {
            "id": 1,
            "name": "caption",
            "text": "hello",
            "font": "Arial",
            "pointsize": 20,
            "visible": true
          }
        ])"),
                              vfs,
                              sound_manager);
    ASSERT_NE(scene, nullptr);
    ASSERT_NE(scene->runtime, nullptr);
    auto& runtime = *scene->runtime;

    std::atomic<int> wakes { 0 };
    runtime.SetContentWakeHandler([&wakes] { wakes.fetch_add(1, std::memory_order_relaxed); });

    // Settle whatever the parse left pending, so the counts below are about the
    // change this test makes and not about loading.
    for (int i = 0; i < 200 && runtime.TextLayoutInFlight(); ++i) {
        runtime.PumpTextLayerCache();
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    ASSERT_FALSE(runtime.TextLayoutInFlight()) << "the parse's own layout never finished";
    wakes.store(0, std::memory_order_relaxed);

    ASSERT_TRUE(runtime.SetNodeText("caption", "a different caption"));
    EXPECT_TRUE(runtime.TextLayoutInFlight())
        << "a changed caption did not register as work in flight";

    for (int i = 0; i < 200 && runtime.TextLayoutInFlight(); ++i) {
        runtime.PumpTextLayerCache();
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    EXPECT_FALSE(runtime.TextLayoutInFlight()) << "the new caption was never applied";
    EXPECT_GE(wakes.load(std::memory_order_relaxed), 1)
        << "the worker produced an image without asking for the frame that shows it";

    // Writing the caption it already has is not a change, so it must not queue
    // work and must not ask for frames. A wallpaper whose script returns the
    // same string forever has to stay asleep.
    const int settled = wakes.load(std::memory_order_relaxed);
    ASSERT_TRUE(runtime.SetNodeText("caption", "a different caption"));
    EXPECT_FALSE(runtime.TextLayoutInFlight())
        << "rewriting the same caption registered work that does not exist";
    for (int i = 0; i < 20; ++i) {
        runtime.PumpTextLayerCache();
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    EXPECT_EQ(wakes.load(std::memory_order_relaxed), settled)
        << "rewriting the same caption woke the scene up";

    // Detaching has to take effect: nothing may call back into a frame clock
    // that is being torn down.
    runtime.SetContentWakeHandler({});
}

// ---------------------------------------------------------------------------
// Text layout as Wallpaper Engine 2.8.42 sets it: point size at 300 dpi, the
// card's padding, glyph and line spacing, and `blockalign`.
// ---------------------------------------------------------------------------

namespace
{
TextLayerState HelveticaState(std::string text, float point_size) {
    return TextLayerState {
        .text                   = std::move(text),
        .font_key               = "systemfont_Helvetica",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "Helvetica",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_Helvetica"),
        .point_size             = point_size,
        .horizontal_align       = "left",
        .vertical_align         = "top",
    };
}

struct InkBox {
    int  min_x { 1 << 30 };
    int  max_x { -1 };
    int  min_y { 1 << 30 };
    int  max_y { -1 };
    bool Any() const { return max_x >= min_x; }
};

InkBox InkBounds(const std::vector<uint8_t>& rgba, uint32_t width, uint32_t height,
                 uint32_t first_row = 0, uint32_t end_row = 0xFFFFFFFFu) {
    InkBox box;
    for (uint32_t y = first_row; y < std::min(height, end_row); ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            if (rgba[(static_cast<std::size_t>(y) * width + x) * 4u + 3u] == 0u) continue;
            box.min_x = std::min(box.min_x, static_cast<int>(x));
            box.max_x = std::max(box.max_x, static_cast<int>(x));
            box.min_y = std::min(box.min_y, static_cast<int>(y));
            box.max_y = std::max(box.max_y, static_cast<int>(y));
        }
    }
    return box;
}

struct Rastered {
    uint32_t             width { 0 };
    uint32_t             height { 0 };
    std::vector<uint8_t> rgba;
};

Rastered RasterOf(const TextLayerState& state) {
    const auto size = TextLayerRasterSize(state);
    Rastered   out;
    out.width  = static_cast<uint32_t>(std::ceil(size.x()));
    out.height = static_cast<uint32_t>(std::ceil(size.y()));
    out.rgba.assign(static_cast<std::size_t>(out.width) * out.height * 4u, 0u);
    RasterizeTextLayer(state, out.width, out.height, out.rgba);
    return out;
}

} // namespace

TEST(TextObjectRuntime, PointSizeIsRequestedFromTheFontAt300Dpi) {
    auto state = HelveticaState("H", 32.0f);
#ifdef __APPLE__
    ASSERT_FALSE(state.resolved_font_path.empty());
#endif

    // The reference is the call Wallpaper Engine makes: the face sized in points
    // at 300 dpi, whose line height is then the pitch of one row of text.
    FT_Library library = nullptr;
    ASSERT_EQ(FT_Init_FreeType(&library), 0);
    FT_Face face = nullptr;
    ASSERT_EQ(FT_New_Face(library, state.resolved_font_path.c_str(), 0, &face), 0);
    ASSERT_EQ(FT_Set_Char_Size(face, 0, 32 * 64, 300, 300), 0);
    const float line_height = static_cast<float>(face->size->metrics.height >> 6);
    FT_Done_Face(face);
    FT_Done_FreeType(library);

    const auto size = MeasureTextLayerSize(state);
    EXPECT_FLOAT_EQ(size.y(), line_height);
    // 32 pt is 133 pixels of em, not the 128 a flat 4 pixels per point gives.
    EXPECT_GT(line_height, 128.0f * 1.03f);
}

// The layout record is the face's numbers and the block of ink set in them, read against
// FreeType's own: the face sized in points at 300 dpi, its size metrics cut to whole
// pixels as Wallpaper Engine cuts them.
TEST(TextObjectRuntime, LayoutRecordMatchesFreeType) {
    auto state = HelveticaState("H", 32.0f);
#ifdef __APPLE__
    ASSERT_FALSE(state.resolved_font_path.empty());
#endif
    FT_Library library = nullptr;
    ASSERT_EQ(FT_Init_FreeType(&library), 0);
    FT_Face face = nullptr;
    ASSERT_EQ(FT_New_Face(library, state.resolved_font_path.c_str(), 0, &face), 0);
    ASSERT_EQ(FT_Set_Char_Size(face, 0, 32 * 64, 300, 300), 0);
    const float ascender  = static_cast<float>(face->size->metrics.ascender >> 6);
    const float descender = static_cast<float>(-(face->size->metrics.descender >> 6));
    const float pitch     = static_cast<float>(face->size->metrics.height >> 6);
    // The ring of an A with one sits above the ascender of Helvetica.
    ASSERT_EQ(FT_Load_Char(face, 0xC5, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL), 0);
    const float ring_top = static_cast<float>(face->glyph->bitmap_top);
    FT_Done_Face(face);
    FT_Done_FreeType(library);
    ASSERT_GT(descender, 0.0f);
    ASSERT_GT(ring_top, ascender) << "this font's A with a ring no longer rises above its ascender";

    const auto one = MeasureTextLayerLayout(state);
    EXPECT_FLOAT_EQ(one.ascender, ascender);
    EXPECT_FLOAT_EQ(one.descender, descender);
    EXPECT_FLOAT_EQ(one.pitch, pitch);
    EXPECT_EQ(one.rows, 1u);
    // The block is the ascender line down to one pitch below it, which the ink of an H
    // does not leave.
    EXPECT_FLOAT_EQ(one.top, ascender);
    EXPECT_FLOAT_EQ(one.bottom, ascender - pitch);
    EXPECT_LE(one.min_x, 0.0f);
    EXPECT_GT(one.max_x, 0.0f);
    EXPECT_TRUE(one.card.isApprox(one.BlockSize()));
    EXPECT_TRUE(one.padding.isZero());

    // Rows step by the pitch. A line break with nothing after it adds none, a line
    // with nothing in it between two others adds one.
    EXPECT_EQ(MeasureTextLayerLayout(HelveticaState("H\nH", 32.0f)).rows, 2u);
    EXPECT_EQ(MeasureTextLayerLayout(HelveticaState("H\n", 32.0f)).rows, 1u);
    EXPECT_EQ(MeasureTextLayerLayout(HelveticaState("H\n\nH", 32.0f)).rows, 3u);
    state.text      = "H\nH\nH";
    state.spacing   = { 0.0f, 7.0f };
    const auto rows = MeasureTextLayerLayout(state);
    EXPECT_FLOAT_EQ(rows.pitch, pitch + 7.0f);
    EXPECT_FLOAT_EQ(rows.bottom, ascender - 3.0f * (pitch + 7.0f));
    EXPECT_FLOAT_EQ(rows.BlockSize().y(), 3.0f * (pitch + 7.0f));

    // Ink taller than the ascender raises the top of the block, and nothing else.
    const auto ringed = MeasureTextLayerLayout(HelveticaState("\xC3\x85", 32.0f));
    EXPECT_FLOAT_EQ(ringed.top, ring_top);
    EXPECT_FLOAT_EQ(ringed.ascender, ascender);
    EXPECT_FLOAT_EQ(ringed.bottom, ascender - pitch);

    // The card is the block and the padding on both sides, on each axis.
    state.text    = "H";
    state.spacing = Eigen::Vector2f::Zero();
    state.padding = { 8.0f, 3.0f };
    const auto padded = MeasureTextLayerLayout(state);
    EXPECT_TRUE(padded.padding.isApprox(Eigen::Vector2f(8.0f, 3.0f)));
    EXPECT_TRUE(padded.card.isApprox(one.BlockSize() + Eigen::Vector2f(16.0f, 6.0f)));
    EXPECT_TRUE(MeasureTextLayerSize(state).isApprox(padded.card));

    // No text has no block and no rows, and a 2 by 2 card; the face's numbers stay.
    state.text = "";
    const auto empty = MeasureTextLayerLayout(state);
    EXPECT_EQ(empty.rows, 0u);
    EXPECT_TRUE(empty.BlockSize().isZero());
    EXPECT_TRUE(empty.card.isApprox(Eigen::Vector2f(18.0f, 8.0f)));
    EXPECT_FLOAT_EQ(empty.ascender, ascender);
    // It has no offsets either: the 2 by 2 card is on the origin whatever the alignment.
    state.horizontal_align = "right";
    state.vertical_align   = "bottom";
    EXPECT_TRUE(MeasureTextLayerLayout(state).centre.isZero());
}

// Where no font opens the text is laid out in boxes: 0.9 em of ascender, 0.3 em of
// descender and a line of 1.2 em, a glyph 0.6 em wide and 0.45 em of ink.
TEST(TextObjectRuntime, BoxLayoutHasTheSameRecordAsAFace) {
    TextLayerState state {
        .text       = "ab\ncd",
        .point_size = 32.0f,
        .padding    = { 4.0f, 2.0f },
        .spacing    = { 0.0f, 5.0f },
    };
    const float em = 32.0f * 300.0f / 72.0f;
    const auto layout = TextLayerBoxLayoutForTests(state);
    EXPECT_NEAR(layout.ascender, 0.9f * em, 1.0e-3f);
    EXPECT_NEAR(layout.descender, 0.3f * em, 1.0e-3f);
    EXPECT_NEAR(layout.pitch, 1.2f * em + 5.0f, 1.0e-3f);
    EXPECT_EQ(layout.rows, 2u);
    EXPECT_FLOAT_EQ(layout.min_x, 0.0f);
    EXPECT_NEAR(layout.max_x, 0.6f * em + 0.45f * em, 1.0e-3f);
    EXPECT_NEAR(layout.top, 0.9f * em, 1.0e-3f);
    EXPECT_NEAR(layout.bottom, 0.9f * em - 2.0f * (1.2f * em + 5.0f), 1.0e-3f);
    EXPECT_TRUE(layout.card.isApprox(layout.BlockSize() + Eigen::Vector2f(8.0f, 4.0f)));
}

TEST(TextObjectRuntime, PointSizeIsClampedToTheRangeWallpaperEngineAccepts) {
    const auto size_at = [](float point_size) {
        return MeasureTextLayerSize(HelveticaState("Hg", point_size));
    };
    EXPECT_TRUE(size_at(0.1f).isApprox(size_at(1.0f)));
    EXPECT_TRUE(size_at(-4.0f).isApprox(size_at(1.0f)));
    EXPECT_TRUE(size_at(900.0f).isApprox(size_at(256.0f)));
    EXPECT_GT(size_at(256.0f).y(), size_at(255.0f).y() - 1.0f);
    // The fallback, estimate and measured sizes see the same clamp.
    EXPECT_TRUE(EstimateTextLayerSize("Hg", 900.0f, 0.0f).isApprox(
        EstimateTextLayerSize("Hg", 256.0f, 0.0f)));
}

TEST(TextObjectRuntime, EmptyTextIsATwoByTwoCardPlusPadding) {
    auto state    = HelveticaState("", 20.0f);
    state.padding = { 8.0f, 3.0f };
    EXPECT_TRUE(MeasureTextLayerSize(state).isApprox(Eigen::Vector2f(18.0f, 8.0f)));
}

TEST(TextObjectRuntime, CardPaddingSizesTheCardAndNeverNarrowsTheWrap) {
    auto plain = HelveticaState("alpha beta gamma", 12.0f);
    const auto natural = MeasureTextLayerSize(plain);

    auto padded    = plain;
    padded.padding = { 32.0f, 20.0f };
    const auto card = MeasureTextLayerSize(padded);
    EXPECT_FLOAT_EQ(card.x(), natural.x() + 64.0f);
    EXPECT_FLOAT_EQ(card.y(), natural.y() + 40.0f);

    // `maxwidth` is the row's width as authored. A limit that just fits the text
    // keeps it on one row whatever the padding, and the card may be wider than
    // the limit by the padding.
    plain.limit_width  = true;
    plain.max_width    = std::ceil(natural.x()) + 2.0f;
    padded.limit_width = true;
    padded.max_width   = plain.max_width;
    EXPECT_FLOAT_EQ(MeasureTextLayerSize(plain).y(), natural.y());
    EXPECT_FLOAT_EQ(MeasureTextLayerSize(padded).y(), natural.y() + 40.0f);
    EXPECT_FLOAT_EQ(MeasureTextLayerSize(padded).x(), natural.x() + 64.0f);
    EXPECT_GT(MeasureTextLayerSize(padded).x(), padded.max_width);
}

// The card is the block with its padding on every side, whichever way it is aligned: the
// ink is the padding away from the card's edges on every axis.
TEST(TextObjectRuntime, CardPaddingGrowsTheCardOutwardOnEveryAxis) {
    for (const std::string_view horizontal : { "left", "center", "right" }) {
        for (const std::string_view vertical : { "top", "center", "bottom" }) {
            SCOPED_TRACE(std::string(horizontal) + " " + std::string(vertical));
            auto state             = HelveticaState("Hg", 20.0f);
            state.padding          = { 24.0f, 10.0f };
            state.horizontal_align = std::string(horizontal);
            state.vertical_align   = std::string(vertical);
            const auto image       = RasterOf(state);
            const auto box         = InkBounds(image.rgba, image.width, image.height);
            ASSERT_TRUE(box.Any());
            EXPECT_GE(box.min_x, 24);
            EXPECT_LE(box.max_x, static_cast<int>(image.width) - 24);
            EXPECT_GT(box.max_x, static_cast<int>(image.width) - 24 - 8);
            EXPECT_GE(box.min_y, 10);
            EXPECT_LE(box.max_y, static_cast<int>(image.height) - 10);
        }
    }
}

TEST(TextObjectRuntime, SpacingAddsToEveryAdvanceAndToTheLinePitch) {
    auto base = HelveticaState("HHHH", 20.0f);
    const auto natural = MeasureTextLayerSize(base);

    // Three gaps between four glyphs: the advance after the last glyph carries
    // no ink and is not part of the row.
    auto wide       = base;
    wide.spacing    = { 10.0f, 0.0f };
    EXPECT_FLOAT_EQ(MeasureTextLayerSize(wide).x(), natural.x() + 30.0f);
    EXPECT_FLOAT_EQ(MeasureTextLayerSize(wide).y(), natural.y());
    auto tight    = base;
    tight.spacing = { -3.0f, 0.0f };
    EXPECT_FLOAT_EQ(MeasureTextLayerSize(tight).x(), natural.x() - 9.0f);

    // The pixels agree with the measurement.
    const auto plain_ink = InkBounds(RasterOf(base).rgba, RasterOf(base).width, RasterOf(base).height);
    const auto wide_raster = RasterOf(wide);
    const auto wide_ink    = InkBounds(wide_raster.rgba, wide_raster.width, wide_raster.height);
    ASSERT_TRUE(plain_ink.Any());
    ASSERT_TRUE(wide_ink.Any());
    EXPECT_NEAR(static_cast<float>(wide_ink.max_x - wide_ink.min_x),
                static_cast<float>(plain_ink.max_x - plain_ink.min_x) + 30.0f, 1.5f);

    // Rows step by the line height plus `spacing.y`, with no lower bound of one pixel.
    auto rows    = HelveticaState("H\nH\nH", 20.0f);
    const auto three = MeasureTextLayerSize(rows);
    rows.spacing     = { 0.0f, 7.0f };
    EXPECT_FLOAT_EQ(MeasureTextLayerSize(rows).y(), three.y() + 21.0f);
    rows.spacing = { 0.0f, -5.0f };
    EXPECT_FLOAT_EQ(MeasureTextLayerSize(rows).y(), three.y() - 15.0f);
    EXPECT_FLOAT_EQ(MeasureTextLayerSize(rows).x(), three.x());
}

TEST(TextObjectRuntime, SpacingMovesTheRowsOfRasterisedText) {
    auto rows = HelveticaState("H\nH", 20.0f);
    const auto first = RasterOf(rows);
    rows.spacing     = { 0.0f, 12.0f };
    const auto spread = RasterOf(rows);
    const auto half_a = first.height / 2;
    const auto half_b = spread.height / 2;
    const auto a_top  = InkBounds(first.rgba, first.width, first.height, 0, half_a);
    const auto a_low  = InkBounds(first.rgba, first.width, first.height, half_a);
    const auto b_top  = InkBounds(spread.rgba, spread.width, spread.height, 0, half_b);
    const auto b_low  = InkBounds(spread.rgba, spread.width, spread.height, half_b);
    ASSERT_TRUE(a_top.Any() && a_low.Any() && b_top.Any() && b_low.Any());
    EXPECT_EQ(a_top.min_y, b_top.min_y);
    EXPECT_EQ((b_low.min_y - b_top.min_y) - (a_low.min_y - a_top.min_y), 12);
}

TEST(TextObjectRuntime, BlockAlignJustifiesOnlyRowsThatEndedAtAWordWrap) {
    const std::string paragraph =
        "one two three four five six seven eight nine ten eleven twelve thirteen fourteen";
    auto plain = HelveticaState(paragraph + "\nshort words here", 10.0f);
    plain.limit_width = true;
    plain.max_width   = 400.0f;
    auto justified        = plain;
    justified.block_align = true;

    const float pitch = MeasureTextLayerSize(HelveticaState("H", 10.0f)).y();
    const auto  natural = MeasureTextLayerSize(plain);
    ASSERT_GT(natural.y(), pitch * 3.5f) << "the paragraph must wrap onto at least two rows";
    ASSERT_LT(natural.x(), 400.0f);
    // The widest row fills the limit exactly once the wrapped rows are justified.
    EXPECT_NEAR(MeasureTextLayerSize(justified).x(), 400.0f, 0.51f);
    EXPECT_FLOAT_EQ(MeasureTextLayerSize(justified).y(), natural.y());

    const auto before = RasterOf(plain);
    const auto after  = RasterOf(justified);
    ASSERT_EQ(after.height, before.height);
    const auto rows = static_cast<uint32_t>(std::lround(natural.y() / pitch));
    ASSERT_GE(rows, 4u);
    const auto band = [&](const Rastered& image, uint32_t row) {
        return InkBounds(image.rgba, image.width, image.height,
                         static_cast<uint32_t>(std::lround(pitch * static_cast<float>(row))),
                         static_cast<uint32_t>(std::lround(pitch * static_cast<float>(row + 1))));
    };
    for (uint32_t row = 0; row + 2u < rows; ++row) {
        const auto j = band(after, row);
        const auto p = band(before, row);
        ASSERT_TRUE(j.Any() && p.Any());
        // A wrapped row now reaches the limit; none was already there.
        EXPECT_GE(j.max_x, 398) << "row " << row;
        EXPECT_LT(p.max_x, 399) << "row " << row;
    }
    // The last row of the paragraph and the rows of the next one are untouched.
    for (uint32_t row = rows - 2u; row < rows; ++row) {
        const auto j = band(after, row);
        const auto p = band(before, row);
        EXPECT_EQ(j.min_x, p.min_x) << "row " << row;
        EXPECT_EQ(j.max_x, p.max_x) << "row " << row;
    }
}

TEST(TextObjectRuntime, BlockAlignNeedsAWidthLimitAndALineThatWraps) {
    auto state = HelveticaState("one two three four five six", 10.0f);
    state.block_align = true;
    const auto unlimited = MeasureTextLayerSize(state);
    state.block_align = false;
    EXPECT_TRUE(MeasureTextLayerSize(state).isApprox(unlimited));

    // With `maxrows` 1 nothing wraps, so there is no row to justify.
    state.limit_width = true;
    state.max_width   = 90.0f;
    state.limit_rows  = true;
    state.max_rows    = 1;
    const auto single = MeasureTextLayerSize(state);
    state.block_align = true;
    EXPECT_TRUE(MeasureTextLayerSize(state).isApprox(single));
}

namespace
{
// The number of leading characters of the ASCII `text` whose card is no wider
// than `limit`: where a row of that width ends in text that has no break.
std::size_t LongestPrefixWithin(TextLayerState state, const std::string& text, float limit) {
    state.limit_width = false;
    state.limit_rows  = false;
    std::size_t best  = 0;
    for (std::size_t count = 1; count <= text.size(); ++count) {
        state.text = text.substr(0, count);
        if (MeasureTextLayerSize(state).x() > limit) break;
        best = count;
    }
    return best;
}

bool SameRaster(const TextLayerState& a, const TextLayerState& b) {
    const auto left = RasterOf(a);
    const auto right = RasterOf(b);
    return left.width == right.width && left.height == right.height && left.rgba == right.rgba;
}
} // namespace

TEST(TextObjectRuntime, TheLastRowTheLimitAllowsIsCutAtTheGlyphThatDidNotFit) {
    // Rows may wrap at a space while the row limit leaves another row. On the last
    // row there is nothing to wrap to: the row keeps every glyph before the one that
    // did not fit, even when that is part of a word, and the rest is dropped.
    const std::string text = "alpha beta gammadelta epsilon zeta";
    auto limited           = HelveticaState(text, 12.0f);
    const float limit      = MeasureTextLayerSize(HelveticaState("alpha beta gamma", 12.0f)).x() + 0.5f;
    const auto  cut        = LongestPrefixWithin(limited, text, limit);
    ASSERT_GT(cut, std::string("alpha beta g").size());
    ASSERT_NE(text[cut - 1], ' ');
    ASSERT_NE(text[cut], ' ') << "the cut has to fall inside a word";
    limited.limit_width = true;
    limited.max_width   = limit;
    limited.limit_rows  = true;
    limited.max_rows    = 1;

    auto reference = HelveticaState(text.substr(0, cut), 12.0f);
    EXPECT_TRUE(MeasureTextLayerSize(limited).isApprox(MeasureTextLayerSize(reference)));
    EXPECT_TRUE(SameRaster(limited, reference));

    // With a second row allowed the first still wraps at the last space, and the
    // second is the one that is cut inside its word.
    limited.max_rows = 2;
    const std::string rest = "gammadelta epsilon zeta";
    const auto second_cut = LongestPrefixWithin(limited, rest, limit);
    ASSERT_GT(second_cut, 0u);
    ASSERT_LT(second_cut, rest.size());
    ASSERT_NE(rest[second_cut], ' ');
    ASSERT_NE(rest[second_cut - 1], ' ');
    auto two_rows = HelveticaState("alpha beta\n" + rest.substr(0, second_cut), 12.0f);
    EXPECT_TRUE(MeasureTextLayerSize(limited).isApprox(MeasureTextLayerSize(two_rows)));
    EXPECT_TRUE(SameRaster(limited, two_rows));
}

TEST(TextObjectRuntime, AnEllipsisReplacesTheEndOfTheLastRowAtTheGlyphThatDidNotFit) {
    const std::string text = "alpha beta gammadelta epsilon zeta";
    auto limited           = HelveticaState(text, 12.0f);
    const float limit      = MeasureTextLayerSize(HelveticaState("alpha beta gamm\xE2\x80\xA6", 12.0f)).x();
    limited.limit_width    = true;
    limited.max_width      = limit;
    limited.limit_rows     = true;
    limited.max_rows       = 1;
    limited.use_ellipsis   = true;

    // The text before the glyph that did not fit, and the marker, shrunk one
    // character at a time until the marker is inside the limit.
    const auto cut = LongestPrefixWithin(limited, text, limit);
    ASSERT_GT(cut, std::string("alpha beta gamm").size()) << "the cut has to be inside the last word";
    ASSERT_NE(text[cut], ' ');
    std::size_t kept = cut;
    while (kept > 0 && MeasureTextLayerSize(HelveticaState(text.substr(0, kept) + "\xE2\x80\xA6", 12.0f)).x() > limit) {
        --kept;
    }
    ASSERT_GT(kept, std::string("alpha beta").size()) << "the whole word before it would not be kept";
    ASSERT_NE(text[kept - 1], ' ');
    const auto reference = HelveticaState(text.substr(0, kept) + "\xE2\x80\xA6", 12.0f);
    EXPECT_TRUE(MeasureTextLayerSize(limited).isApprox(MeasureTextLayerSize(reference)));
    EXPECT_TRUE(SameRaster(limited, reference));
    EXPECT_LE(MeasureTextLayerSize(limited).x(), limit + 0.001f);
}

TEST(TextObjectRuntime, ALineBreakWithNothingAfterItAddsNoRowAndNoEllipsis) {
    const auto size_of = [](std::string text, bool one_row, bool ellipsis) {
        auto state         = HelveticaState(std::move(text), 14.0f);
        state.limit_rows   = one_row;
        state.max_rows     = 1;
        state.use_ellipsis = ellipsis;
        return state;
    };
    // The text ends with the break: there is no empty row after it.
    EXPECT_TRUE(MeasureTextLayerSize(size_of("ab\n", false, false))
                    .isApprox(MeasureTextLayerSize(size_of("ab", false, false))));
    // And on the last row the limit allows, the break is not text that was cut.
    EXPECT_TRUE(SameRaster(size_of("ab\n", true, true), size_of("ab", false, false)));
    // More text after the break is cut, and the row ends in the marker. A second
    // break counts as more text, an empty row after the first.
    EXPECT_TRUE(SameRaster(size_of("ab\ncd", true, true), size_of("ab\xE2\x80\xA6", false, false)));
    EXPECT_TRUE(SameRaster(size_of("ab\n\n", true, true), size_of("ab\xE2\x80\xA6", false, false)));
    // Without the limit that empty row is a row.
    EXPECT_GT(MeasureTextLayerSize(size_of("ab\n\n", false, false)).y(),
              MeasureTextLayerSize(size_of("ab", false, false)).y() * 1.5f);
}

TEST(TextObjectRuntime, ARowThatWrapsAtADoubleSpaceKeepsAllButOneOfTheSpaces) {
    // The break is at the last space before the glyph that did not fit; a space
    // before that one stays in the row, where `blockalign` has it to widen.
    auto state = HelveticaState("aaaa  bbbb", 14.0f);
    const float limit = MeasureTextLayerSize(HelveticaState("aaaa  b", 14.0f)).x() - 2.0f;
    state.limit_width = true;
    state.max_width   = limit;
    const auto ragged = MeasureTextLayerSize(state);
    ASSERT_LT(ragged.x(), limit - 1.0f) << "the row has to wrap short of the limit";
    ASSERT_GT(ragged.y(), MeasureTextLayerSize(HelveticaState("aaaa", 14.0f)).y() * 1.5f)
        << "the text has to wrap onto a second row";
    state.block_align = true;
    // The first row has a space to widen, so it is stretched to the limit exactly.
    EXPECT_NEAR(MeasureTextLayerSize(state).x(), limit, 0.51f);

    // One space between the words leaves none in the row after the break.
    auto single = HelveticaState("aaaa bbbb", 14.0f);
    single.limit_width = true;
    single.max_width   = MeasureTextLayerSize(HelveticaState("aaaa b", 14.0f)).x() - 2.0f;
    single.block_align = true;
    EXPECT_LT(MeasureTextLayerSize(single).x(), single.max_width - 1.0f);
}

TEST(TextObjectRuntime, ANegativePaddingTakesTheCardInAndOnlyTheTopIsCapped) {
    auto state = HelveticaState("HHHH", 20.0f);
    const auto natural = MeasureTextLayerSize(state);
    state.padding      = { -6.0f, -4.0f };
    EXPECT_TRUE(MeasureTextLayerSize(state).isApprox(natural + Eigen::Vector2f(-12.0f, -8.0f)));
    state.padding = { 900.0f, 600.0f };
    EXPECT_TRUE(MeasureTextLayerSize(state).isApprox(natural + Eigen::Vector2f(1024.0f, 1024.0f)));
    // Taken in further than the text is wide, the card is a pixel, not nothing.
    state.padding = { -4000.0f, -4000.0f };
    EXPECT_TRUE(MeasureTextLayerSize(state).isApprox(Eigen::Vector2f(1.0f, 1.0f)));
}


namespace
{
// A parsed scene of text layers with the files it needs. The file system, sound
// manager and parser outlive the scene.
struct TextSceneFixture {
    fs::VFS                vfs;
    audio::SoundManager    sound { audio::SoundManager::OutputBackend::Null };
    WPSceneParser          parser;
    ProjectProperties      properties;
    std::shared_ptr<Scene> scene;

    TextSceneFixture(const std::string& objects, std::string scene_id,
                     std::map<std::string, std::string> files = {},
                     ProjectProperties initial_properties = {},
                     std::string scene_general_extra = {})
        : properties(std::move(initial_properties)) {
        EXPECT_TRUE(vfs.Mount("/assets", std::make_unique<MemoryFs>(std::move(files))));
        auto document = MinimalSceneObjects(objects);
        if (! scene_general_extra.empty()) {
            // Extra keys of the scene's `general` block, written as `"key":value,`.
            const auto at = document.find("\"general\": {");
            document.insert(at + std::string("\"general\": {").size(), scene_general_extra);
        }
        scene = parser.Parse(SceneParseRequest { .scene_id = std::move(scene_id),
                                                 .project_properties = &properties },
                             document, vfs, sound);
    }

    TextLayerState State(std::string_view name) const {
        if (scene == nullptr || scene->runtime == nullptr) return {};
        return scene->runtime->NodeTextState(name).value_or(TextLayerState {});
    }
};

// Stand-ins for the HDR bloom materials a scene with `hdr` and `bloom` loads, so a
// test can parse such a scene: the pipeline is what matters here, not the glow.
std::map<std::string, std::string> HdrBloomAssets() {
    const std::string vert = "attribute vec3 a_Position;\nattribute vec2 a_TexCoord;\n"
                             "varying vec2 v_TexCoord;\nvoid main() {\n"
                             "  gl_Position = vec4(a_Position, 1.0);\n  v_TexCoord = a_TexCoord;\n}\n";
    const std::string frag = "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\n"
                             "void main() {\n  gl_FragColor = texture(g_Texture0, v_TexCoord);\n}\n";
    std::map<std::string, std::string> files;
    for (const auto* material : { "hdr_downsample_bloom", "hdr_downsample", "hdr_upsample",
                                  "hdr_upsample_cubic", "combine_hdr_upsample_linear" }) {
        files[std::string("/materials/util/") + material + ".json"] =
            std::string(R"({"passes":[{"blending":"normal","cullmode":"nocull","depthtest":"disabled",)"
                        R"("depthwrite":"disabled","shader":")") + material + R"("}]})";
        files[std::string("/shaders/") + material + ".vert"] = vert;
        files[std::string("/shaders/") + material + ".frag"] = frag;
    }
    return files;
}

// What a colour blend needs: a passthrough material and a shader that samples
// the screen when a blend mode is set.
std::map<std::string, std::string> ColorBlendAssets() {
    const std::string vert = R"(attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
void main() {
  gl_Position = vec4(a_Position, 1.0);
  v_TexCoord = a_TexCoord;
}
)";
    const std::string frag = R"(uniform sampler2D g_Texture0;
#if BLENDMODE
uniform sampler2D g_Texture4; // {"hidden":true,"default":"_rt_FullFrameBuffer"}
#endif
uniform vec4 g_Color4;
varying vec2 v_TexCoord;
void main() {
  gl_FragColor = texture(g_Texture0, v_TexCoord) * g_Color4;
#if BLENDMODE
  gl_FragColor.rgb += texture(g_Texture4, v_TexCoord).rgb;
#endif
}
)";
    return {
        // A stand-in for the engine's passthrough material: its own shader name
        // and its own order and values, with the one property the parser relies on,
        // that the material is found at this path and takes a `BLENDMODE` combo.
        { "/materials/util/effectpassthrough.json",
          R"({"passes":[{"cullmode":"nocull","shader":"blend_probe","blending":"translucent",)"
          R"("depthwrite":"disabled","depthtest":"disabled"}]})" },
        { "/shaders/blend_probe.vert", vert },
        { "/shaders/blend_probe.frag", frag },
        { "/effects/tint/effect.json",
          R"({"name":"tint","passes":[{"material":"materials/effects/tint.json"}]})" },
        { "/materials/effects/tint.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled",)"
          R"("depthwrite":"disabled","shader":"effects/tint","textures":[null]}]})" },
        { "/shaders/effects/tint.vert", vert },
        { "/shaders/effects/tint.frag", frag },
    };
}

std::vector<const vulkan::CustomShaderPass*> CustomPasses(const rg::RenderGraph& graph) {
    std::vector<const vulkan::CustomShaderPass*> passes;
    for (const auto id : graph.topologicalOrder()) {
        if (const auto* pass = dynamic_cast<const vulkan::CustomShaderPass*>(graph.getPass(id))) {
            passes.push_back(pass);
        }
    }
    return passes;
}

bool SamplesScreen(const vulkan::CustomShaderPass& pass) {
    const auto& textures = pass.desc().textures;
    return std::any_of(textures.begin(), textures.end(), [](const std::string& texture) {
        return texture.starts_with(SpecTex_Default);
    });
}
} // namespace

TEST(TextObjectRuntime, PaddingAndSpacingReadTheFormsWallpaperEngineReads) {
    // `opaquebackground` makes every one of these a padded layer, so the state
    // shows what was read.
    TextSceneFixture fixture(R"([
      {"id":1,"name":"number","text":"a","font":"Arial","opaquebackground":true,
       "padding":8,"spacing":2,"visible":true},
      {"id":2,"name":"pair","text":"a","font":"Arial","opaquebackground":true,
       "padding":"6.00000 10.00000","spacing":"-3.58 1","visible":true},
      {"id":3,"name":"lone","text":"a","font":"Arial","opaquebackground":true,
       "padding":"5","spacing":"4","visible":true},
      {"id":4,"name":"bound","text":"a","font":"Arial","opaquebackground":true,
       "padding":{"user":"margin","value":"3 4"},"visible":true},
      {"id":5,"name":"absent","text":"a","font":"Arial","opaquebackground":true,"visible":true},
      {"id":6,"name":"huge","text":"a","font":"Arial","opaquebackground":true,
       "padding":"900 -20","visible":true},
      {"id":7,"name":"array","text":"a","font":"Arial","opaquebackground":true,
       "padding":[6,10],"visible":true}
    ])", "text-vec2-forms");
    ASSERT_NE(fixture.scene, nullptr);
    ASSERT_NE(fixture.scene->runtime, nullptr);

    EXPECT_TRUE(fixture.State("number").padding.isApprox(Eigen::Vector2f(8.0f, 8.0f)));
    EXPECT_TRUE(fixture.State("number").spacing.isApprox(Eigen::Vector2f(2.0f, 2.0f)));
    EXPECT_TRUE(fixture.State("pair").padding.isApprox(Eigen::Vector2f(6.0f, 10.0f)));
    EXPECT_TRUE(fixture.State("pair").spacing.isApprox(Eigen::Vector2f(-3.58f, 1.0f)));
    // A string with one number sets only the x lane.
    EXPECT_TRUE(fixture.State("lone").padding.isApprox(Eigen::Vector2f(5.0f, 0.0f)));
    EXPECT_TRUE(fixture.State("lone").spacing.isApprox(Eigen::Vector2f(4.0f, 0.0f)));
    // A binding is read through its value.
    EXPECT_TRUE(fixture.State("bound").padding.isApprox(Eigen::Vector2f(3.0f, 4.0f)));
    // No key: 32 on both axes. Each lane is capped at 512 and not floored: a
    // negative padding stays negative.
    EXPECT_TRUE(fixture.State("absent").padding.isApprox(Eigen::Vector2f(32.0f, 32.0f)));
    EXPECT_TRUE(fixture.State("huge").padding.isApprox(Eigen::Vector2f(512.0f, -20.0f)));
    // A JSON array is not a form the reference reads, so it leaves the default.
    EXPECT_TRUE(fixture.State("array").padding.isApprox(Eigen::Vector2f(32.0f, 32.0f)));
}

TEST(TextObjectRuntime, CardPaddingAppliesOnlyToLayersWallpaperEnginePads) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"plain","text":"a","font":"Arial","padding":"32 32","visible":true},
      {"id":2,"name":"effect","text":"a","font":"Arial","padding":"32 32","visible":true,
       "effects":[{"file":"effects/tint/effect.json","id":10,"visible":true}]},
      {"id":3,"name":"hidden effect","text":"a","font":"Arial","padding":"32 32","visible":true,
       "effects":[{"file":"effects/tint/effect.json","id":11,"visible":false}]},
      {"id":4,"name":"blend","text":"a","font":"Arial","padding":"32 32","colorBlendMode":12,
       "visible":true},
      {"id":5,"name":"add","text":"a","font":"Arial","padding":"32 32","colorBlendMode":31,
       "visible":true},
      {"id":6,"name":"led","text":"a","font":"Arial","padding":"32 32","ledsource":true,
       "visible":true},
      {"id":7,"name":"opaque","text":"a","font":"Arial","padding":"32 32",
       "opaquebackground":true,"visible":true}
    ])", "text-padded-layers", ColorBlendAssets());
    ASSERT_NE(fixture.scene, nullptr);
    ASSERT_NE(fixture.scene->runtime, nullptr);

    const Eigen::Vector2f none = Eigen::Vector2f::Zero();
    const Eigen::Vector2f pad(32.0f, 32.0f);
    EXPECT_TRUE(fixture.State("plain").padding.isApprox(none));
    EXPECT_TRUE(fixture.State("effect").padding.isApprox(pad));
    EXPECT_TRUE(fixture.State("hidden effect").padding.isApprox(none));
    EXPECT_TRUE(fixture.State("blend").padding.isApprox(pad));
    // "Add" is drawn straight onto the scene and does not composite.
    EXPECT_TRUE(fixture.State("add").padding.isApprox(none));
    EXPECT_TRUE(fixture.State("led").padding.isApprox(pad));
    EXPECT_TRUE(fixture.State("opaque").padding.isApprox(pad));

    // The layer's card is its text plus the padding, only where it applies.
    const auto plain = fixture.scene->runtime->NodeSize("plain");
    EXPECT_TRUE(fixture.scene->runtime->NodeSize("effect").isApprox(plain + Eigen::Vector2f(64.0f, 64.0f)));
    EXPECT_TRUE(fixture.scene->runtime->NodeSize("add").isApprox(plain));
}

TEST(TextObjectRuntime, ASceneWithFogPadsEveryTextLayerWhateverItsEffects) {
    // The renderer composites every text layer of a scene that enables distance fog
    // or height fog, so each is padded as a layer with effects is.
    const std::string layers = R"([
      {"id":1,"name":"plain","text":"a","font":"Arial","padding":"32 32","visible":true},
      {"id":2,"name":"add","text":"a","font":"Arial","padding":"32 32","colorBlendMode":31,
       "visible":true}
    ])";
    const Eigen::Vector2f none = Eigen::Vector2f::Zero();
    const Eigen::Vector2f pad(32.0f, 32.0f);
    {
        TextSceneFixture clear(layers, "text-no-fog", ColorBlendAssets());
        ASSERT_NE(clear.scene, nullptr);
        EXPECT_TRUE(clear.State("plain").padding.isApprox(none));
        EXPECT_TRUE(clear.State("add").padding.isApprox(none));
    }
    for (const char* flag : { R"("fogdistance":true,)", R"("fogheight":true,)" }) {
        SCOPED_TRACE(flag);
        TextSceneFixture fogged(layers, std::string("text-fog-") + flag, ColorBlendAssets(), {}, flag);
        ASSERT_NE(fogged.scene, nullptr);
        EXPECT_TRUE(fogged.State("plain").padding.isApprox(pad));
        EXPECT_TRUE(fogged.State("add").padding.isApprox(pad));
        const auto plain_card = fogged.scene->runtime->NodeSize("plain");
        TextSceneFixture clear(layers, "text-fog-reference", ColorBlendAssets());
        EXPECT_TRUE(plain_card.isApprox(clear.scene->runtime->NodeSize("plain") + Eigen::Vector2f(64.0f, 64.0f)));
    }
    // A flag that is false pads nothing.
    TextSceneFixture off(layers, "text-fog-off", ColorBlendAssets(), {},
                         R"("fogdistance":false,"fogheight":false,)");
    ASSERT_NE(off.scene, nullptr);
    EXPECT_TRUE(off.State("plain").padding.isApprox(none));
}

TEST(TextObjectRuntime, StyleColoursFollowTheirPropertiesAndTheBakedKeysAreReadOnceAndHeld) {
    // The outline and shadow colours are uniforms of the card's shader, so a bound
    // one drives it live. Sizes, offsets, opacity and the switches are baked into
    // the card's pixels: a bound one is read as the scene loads, with the value
    // the user has chosen, and noted as load-only so a preview holds it.
    TextSceneFixture fixture(R"([
      {"id":1,"name":"caption","text":"a","font":"Arial","visible":true,
       "outline":{"user":"edge","value":false},
       "outlinethickness":{"user":"thick","value":4},
       "outlinecolor":{"user":"ink","value":"0 0 0"},
       "dropshadow":true,
       "dropshadowsize":{"user":"soft","value":6},
       "dropshadowopacity":{"user":"dim","value":1},
       "dropshadowcolor":{"user":"shade","value":"0 0 0"}}
    ])", "text-style-properties", {},
                             ProjectProperties {
                                 { "edge", RuntimeScalarValue::Bool(true) },
                                 { "thick", RuntimeScalarValue::Float(2.0f) },
                                 { "ink", RuntimeScalarValue::String("1 0 0") },
                                 { "soft", RuntimeScalarValue::Float(1.5f) },
                                 { "dim", RuntimeScalarValue::Float(0.25f) },
                                 { "shade", RuntimeScalarValue::String("0 0 1") },
                             });
    ASSERT_NE(fixture.scene, nullptr);
    ASSERT_NE(fixture.scene->runtime, nullptr);
    auto& runtime = *fixture.scene->runtime;

    // What the user chose, not the editor's default saved in the scene file.
    const auto style = fixture.State("caption").style;
    EXPECT_TRUE(style.outline);
    EXPECT_FLOAT_EQ(style.outline_thickness, 2.0f);
    EXPECT_FLOAT_EQ(style.shadow_size, 1.5f);
    EXPECT_FLOAT_EQ(style.shadow_opacity, 0.25f);

    // The baked keys are held, the colours are not.
    const auto held = runtime.LoadOnlyProperties();
    EXPECT_EQ(held, (std::vector<std::string> { "dim", "edge", "soft", "thick" }));

    auto* node = FindRootChild(*fixture.scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);
    const auto* material = node->Mesh()->Material();
    ASSERT_NE(material, nullptr);
    const auto colour = [&](const char* name) {
        const auto& value = material->customShader.constValues.at(name);
        return Eigen::Vector3f(value[0], value[1], value[2]);
    };
    EXPECT_TRUE(colour("g_OutlineColor").isApprox(Eigen::Vector3f(1.0f, 0.0f, 0.0f)));
    EXPECT_TRUE(colour("g_ShadowColor").isApprox(Eigen::Vector3f(0.0f, 0.0f, 1.0f)));
    runtime.ApplyProjectPropertyOverride({ { "ink", RuntimeScalarValue::String("0 1 0") },
                                           { "shade", RuntimeScalarValue::String("1 1 0") } });
    runtime.Tick(1.0 / 60.0);
    EXPECT_TRUE(colour("g_OutlineColor").isApprox(Eigen::Vector3f(0.0f, 1.0f, 0.0f)));
    EXPECT_TRUE(colour("g_ShadowColor").isApprox(Eigen::Vector3f(1.0f, 1.0f, 0.0f)));

    // A document that asks for other baked values is held at the ones the scene
    // loaded with and says so; the colours move (`shade`, left out, returns to the
    // value the scene loaded with).
    const auto preview = runtime.PreviewProjectPropertyOverride({
        { "edge", RuntimeScalarValue::Bool(false) },
        { "thick", RuntimeScalarValue::Float(9.0f) },
        { "ink", RuntimeScalarValue::String("0 0 1") },
    });
    EXPECT_EQ(preview.changed, (std::vector<std::string> { "ink", "shade" }));
    EXPECT_EQ(preview.deferred, (std::vector<std::string> { "edge", "thick" }));
    runtime.Tick(1.0 / 60.0);
    EXPECT_TRUE(colour("g_OutlineColor").isApprox(Eigen::Vector3f(0.0f, 0.0f, 1.0f)));
    EXPECT_FLOAT_EQ(fixture.State("caption").style.outline_thickness, 2.0f);
}

// Wallpaper Engine reads the two alignment keys as enumerations. A key that is
// missing leaves the layer centred. A key that is there takes the word that
// matches it exactly (case counts), and anything else -- another string, an empty
// one, a number, `null` -- takes the registry's first entry: `left` for the
// horizontal key and `center` for the vertical one, whose registry is built in
// the order center, top, bottom.
TEST(TextObjectRuntime, AlignmentKeysAreReadAsTheEnumRegistryReadsThem) {
    struct Case {
        const char* fields;
        const char* horizontal;
        const char* vertical;
    };
    const std::vector<Case> cases {
        { R"()", "center", "center" },
        { R"(,"horizontalalign":"left","verticalalign":"top")", "left", "top" },
        { R"(,"horizontalalign":"center","verticalalign":"center")", "center", "center" },
        { R"(,"horizontalalign":"right","verticalalign":"bottom")", "right", "bottom" },
        { R"(,"horizontalalign":"Left","verticalalign":"Top")", "left", "center" },
        { R"(,"horizontalalign":"","verticalalign":"")", "left", "center" },
        { R"(,"horizontalalign":"leftt","verticalalign":"middle")", "left", "center" },
        { R"(,"horizontalalign":"RIGHT","verticalalign":"bottomm")", "left", "center" },
        { R"(,"horizontalalign":7,"verticalalign":7)", "left", "center" },
        { R"(,"horizontalalign":null,"verticalalign":null)", "left", "center" },
        // A key that is not a string is not a word. That an object (a value wrapper) is one of
        // those is inferred: the loader that would unwrap it was not found, and no scene has one.
        { R"(,"horizontalalign":{"value":"right"},"verticalalign":{"value":"top"})", "left", "center" },
        { R"(,"horizontalalign":["right"],"verticalalign":true)", "left", "center" },
        { R"(,"horizontalalign":"right")", "right", "center" },
        { R"(,"verticalalign":"top")", "center", "top" },
        { R"(,"alignment":"left")", "center", "center" },
        { R"(,"alignment":"bottom","horizontalalign":"left")", "left", "center" },
    };
    std::string objects = "[";
    for (std::size_t index = 0; index < cases.size(); ++index) {
        if (index != 0) objects += ",";
        objects += R"({"id":)" + std::to_string(index + 1) + R"(,"name":"c)" + std::to_string(index) +
                   R"(","text":"aaaa","font":"Arial","pointsize":10,"visible":true)" +
                   cases[index].fields + "}";
    }
    objects += "]";
    TextSceneFixture fixture(objects, "text-align-enum-registry");
    ASSERT_NE(fixture.scene, nullptr);
    ASSERT_NE(fixture.scene->runtime, nullptr);
    for (std::size_t index = 0; index < cases.size(); ++index) {
        SCOPED_TRACE(cases[index].fields);
        const auto state = fixture.State("c" + std::to_string(index));
        EXPECT_EQ(state.horizontal_align, cases[index].horizontal);
        EXPECT_EQ(state.vertical_align, cases[index].vertical);
    }
}

// The same rule on its own: the exact words, and the registry's first entry for
// everything else. `middle`, `Left` and a word with something after it are not
// words, so none of them places the text.
TEST(TextObjectRuntime, AlignmentWordsParseLikeTheEnumRegistry) {
    EXPECT_EQ(ParseTextHorizontalAlign("left"), TextHorizontalAlign::Left);
    EXPECT_EQ(ParseTextHorizontalAlign("center"), TextHorizontalAlign::Center);
    EXPECT_EQ(ParseTextHorizontalAlign("right"), TextHorizontalAlign::Right);
    for (const std::string_view word : { "", "Left", "RIGHT", "leftt", "middle", "left ", "top", " center" }) {
        SCOPED_TRACE(std::string(word));
        EXPECT_EQ(ParseTextHorizontalAlign(word), TextHorizontalAlign::Left);
    }
    EXPECT_EQ(ParseTextVerticalAlign("top"), TextVerticalAlign::Top);
    EXPECT_EQ(ParseTextVerticalAlign("center"), TextVerticalAlign::Center);
    EXPECT_EQ(ParseTextVerticalAlign("bottom"), TextVerticalAlign::Bottom);
    for (const std::string_view word : { "", "Top", "BOTTOM", "bottomm", "middle", "top ", "left", "topleft" }) {
        SCOPED_TRACE(std::string(word));
        EXPECT_EQ(ParseTextVerticalAlign(word), TextVerticalAlign::Center);
    }
    // The word an alignment is written back as is the one that parses to it.
    for (const auto align : { TextHorizontalAlign::Left, TextHorizontalAlign::Center,
                              TextHorizontalAlign::Right }) {
        EXPECT_EQ(ParseTextHorizontalAlign(TextHorizontalAlignWord(align)), align);
    }
    for (const auto align : { TextVerticalAlign::Bottom, TextVerticalAlign::Center,
                              TextVerticalAlign::Top }) {
        EXPECT_EQ(ParseTextVerticalAlign(TextVerticalAlignWord(align)), align);
    }
}

// Wallpaper Engine multiplies a text layer's colour by its `brightness` only in
// its HDR pipeline, which is the scene asking for HDR with bloom on (the same
// pipeline that gives the shaders their `HDR` combo and 16-bit targets). Everywhere
// else the brightness is 1 whatever the layer says: a layer authored at brightness
// 0 is still drawn in its colour. A property or a script that drives the
// brightness follows the same rule.
TEST(TextObjectRuntime, TextBrightnessAppliesOnlyInTheHdrPipeline) {
    struct Pipeline {
        const char* general;
        bool        hdr;
    };
    for (const auto& pipeline : { Pipeline { "", false }, Pipeline { R"("hdr":true,"bloom":false,)", false },
                                  Pipeline { R"("hdr":true,"bloom":true,)", true } }) {
        SCOPED_TRACE(pipeline.general);
        TextSceneFixture fixture(R"([
          {"id":1,"name":"dark","text":"a","font":"Arial","brightness":0,"visible":true},
          {"id":2,"name":"bright","text":"a","font":"Arial","brightness":2.39,"visible":true},
          {"id":3,"name":"plain","text":"a","font":"Arial","visible":true},
          {"id":4,"name":"bound","text":"a","font":"Arial","brightness":{"user":"glow","value":0.5},
           "visible":true}
        ])", "text-brightness-pipeline", HdrBloomAssets(),
                                 ProjectProperties { { "glow", RuntimeScalarValue::Float(3.0f) } },
                                 pipeline.general);
        ASSERT_NE(fixture.scene, nullptr);
        ASSERT_NE(fixture.scene->runtime, nullptr);
        EXPECT_EQ(fixture.scene->hdr, pipeline.hdr);
        const auto brightness = [&](const char* name) {
            auto* node = FindRootChild(*fixture.scene, name);
            EXPECT_NE(node, nullptr);
            if (node == nullptr || node->Mesh() == nullptr || node->Mesh()->Material() == nullptr) {
                return -1.0f;
            }
            return node->Mesh()->Material()->customShader.constValues.at("g_Brightness")[0];
        };
        EXPECT_FLOAT_EQ(brightness("dark"), pipeline.hdr ? 0.0f : 1.0f);
        EXPECT_FLOAT_EQ(brightness("bright"), pipeline.hdr ? 2.39f : 1.0f);
        EXPECT_FLOAT_EQ(brightness("plain"), 1.0f);
        EXPECT_FLOAT_EQ(brightness("bound"), pipeline.hdr ? 3.0f : 1.0f);
        fixture.scene->runtime->ApplyProjectPropertyOverride(
            { { "glow", RuntimeScalarValue::Float(0.25f) } });
        fixture.scene->runtime->Tick(1.0 / 60.0);
        EXPECT_FLOAT_EQ(brightness("bound"), pipeline.hdr ? 0.25f : 1.0f);
    }
}

// Where the brightness does nothing, a script that drives it still runs: it may
// be doing something else (here it counts for another layer's script), and its
// value is still the layer's brightness for any script that reads it.
TEST(TextObjectRuntime, ABrightnessScriptStillRunsWhereBrightnessDoesNothing) {
    for (const char* general : { "", R"("hdr":true,"bloom":true,)" }) {
        SCOPED_TRACE(general);
        TextSceneFixture fixture(R"([
          {"id":1,"name":"counter","text":"a","font":"Arial","visible":true,
           "brightness":{"value":5,"script":"export function update(value) { shared.runs = (shared.runs || 0) + 1; return value; }"}},
          {"id":2,"name":"reader","font":"Arial","visible":true,
           "text":{"value":"waiting","script":"export function update() { return String(shared.runs || 0); }"}}
        ])", "text-brightness-script", HdrBloomAssets(), {}, general);
        ASSERT_NE(fixture.scene, nullptr);
        ASSERT_NE(fixture.scene->runtime, nullptr);
        auto& runtime = *fixture.scene->runtime;
        EXPECT_EQ(runtime.scriptErrorCount(), 0u);
        runtime.Tick(1.0 / 60.0);
        const auto first = std::stoi(runtime.NodeText("reader"));
        runtime.Tick(1.0 / 60.0);
        const auto second = std::stoi(runtime.NodeText("reader"));
        EXPECT_GT(first, 0);
        EXPECT_EQ(second, first + 1) << "the brightness script has to run once a tick";
        EXPECT_EQ(runtime.scriptErrorCount(), 0u);
    }
}

TEST(TextObjectRuntime, SpacingAndBlockAlignReachTheLayerState) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"set","text":"abc","font":"Arial","spacing":"6 0","blockalign":true,
       "visible":true},
      {"id":2,"name":"unset","text":"abc","font":"Arial","visible":true}
    ])", "text-spacing-state");
    ASSERT_NE(fixture.scene, nullptr);
    ASSERT_NE(fixture.scene->runtime, nullptr);
    EXPECT_TRUE(fixture.State("set").spacing.isApprox(Eigen::Vector2f(6.0f, 0.0f)));
    EXPECT_TRUE(fixture.State("set").block_align);
    EXPECT_TRUE(fixture.State("unset").spacing.isApprox(Eigen::Vector2f::Zero()));
    EXPECT_FALSE(fixture.State("unset").block_align);
    // Spacing is a property of the glyphs, not of the card: a plain layer keeps
    // it. Three glyphs have two gaps between them, each 6 pixels wider.
    EXPECT_NEAR(fixture.scene->runtime->NodeSize("set").x() -
                    fixture.scene->runtime->NodeSize("unset").x(),
                12.0f, 0.01f);
    EXPECT_FLOAT_EQ(fixture.scene->runtime->NodeSize("set").y(),
                    fixture.scene->runtime->NodeSize("unset").y());
}

TEST(TextObjectRuntime, ColorBlendModeMixesTextWithTheScreenThroughThePassthroughPass) {
    const std::string layer = R"([{"id":1,"name":"caption","text":"hello","font":"Arial",
        "pointsize":20,"colorBlendMode":12,"alpha":0.5,"visible":true}])";
    TextSceneFixture blended(layer, "text-color-blend", ColorBlendAssets());
    ASSERT_NE(blended.scene, nullptr);
    auto* node = FindRootChild(*blended.scene, "caption");
    ASSERT_NE(node, nullptr);

    // The text is drawn into a layer target first; the passthrough pass is the
    // layer's last effect and the only pass that reads the screen.
    ASSERT_FALSE(node->Camera().empty());
    auto* layers = blended.scene->cameras.at(node->Camera()).get();
    ASSERT_TRUE(layers->HasImgEffect());
    auto* effect_layer = layers->GetImgEffect().get();
    ASSERT_EQ(effect_layer->EffectCount(), 1u);
    auto* blend_node = effect_layer->GetEffect(0)->nodes.front().sceneNode.get();
    ASSERT_NE(blend_node, nullptr);
    ASSERT_NE(blend_node->Mesh(), nullptr);
    // The layer's own colour and alpha are already in what it blends.
    const auto& values = blend_node->Mesh()->Material()->customShader.constValues;
    ASSERT_TRUE(values.contains("g_Color4"));
    for (std::size_t lane = 0; lane < 4; ++lane) EXPECT_FLOAT_EQ(values.at("g_Color4")[lane], 1.0f);

    // The chain has nothing to spread into, so its buffers are the card, not the
    // room an authored effect over text is given.
    const auto* ping_pong = blended.scene->FindRenderTarget(
        std::string(WE_EFFECT_PPONG_PREFIX_A.data()) + node->Camera());
    ASSERT_NE(ping_pong, nullptr);
    const auto card = TextLayerRasterSize(blended.State("caption"));
    EXPECT_LE(ping_pong->width, static_cast<int32_t>(std::ceil(card.x())) + 1);
    EXPECT_LE(ping_pong->height, static_cast<int32_t>(std::ceil(card.y())) + 1);

    const auto graph = sceneToRenderGraph(*blended.scene);
    ASSERT_NE(graph, nullptr);
    std::size_t screen_readers = 0;
    for (const auto* pass : CustomPasses(*graph)) {
        if (! SamplesScreen(*pass)) continue;
        ++screen_readers;
        // It is the pass that draws onto the scene, as an image layer's is, with
        // the layer's final blend.
        EXPECT_EQ(pass->desc().output, SpecTex_Default);
        const auto* material = pass->desc().node->Mesh()->MaterialForSlot(pass->desc().material_slot);
        ASSERT_NE(material, nullptr);
        EXPECT_EQ(material->blenmode, BlendMode::Translucent);
    }
    EXPECT_EQ(screen_readers, 1u);

    // Mode "none" keeps the plain translucent card and no effect chain.
    TextSceneFixture plain(R"([{"id":1,"name":"caption","text":"hello","font":"Arial",
        "pointsize":20,"visible":true}])", "text-no-blend", ColorBlendAssets());
    ASSERT_NE(plain.scene, nullptr);
    auto* plain_node = FindRootChild(*plain.scene, "caption");
    ASSERT_NE(plain_node, nullptr);
    EXPECT_TRUE(plain_node->Camera().empty());
    EXPECT_EQ(plain_node->Mesh()->Material()->blenmode, BlendMode::Translucent);
}

TEST(TextObjectRuntime, AddColorBlendTextIsDrawnAdditivelyOntoTheScene) {
    const auto parse = [](const std::string& effects) {
        return std::make_unique<TextSceneFixture>(
            R"([{"id":1,"name":"caption","text":"hello","font":"Arial","pointsize":20,
                 "colorBlendMode":31,"visible":true)" + effects + "}]",
            "text-add-blend", ColorBlendAssets());
    };

    // Without effects the text card itself adds; nothing samples the screen.
    auto bare = parse("");
    ASSERT_NE(bare->scene, nullptr);
    auto* node = FindRootChild(*bare->scene, "caption");
    ASSERT_NE(node, nullptr);
    EXPECT_TRUE(node->Camera().empty());
    EXPECT_EQ(node->Mesh()->Material()->blenmode, BlendMode::Additive);

    // With an effect the chain ends in an additive draw onto the scene.
    auto with_effect = parse(R"(,"effects":[{"file":"effects/tint/effect.json","id":2,"visible":true}])");
    ASSERT_NE(with_effect->scene, nullptr);
    const auto graph = sceneToRenderGraph(*with_effect->scene);
    ASSERT_NE(graph, nullptr);
    std::size_t onto_scene = 0;
    for (const auto* pass : CustomPasses(*graph)) {
        EXPECT_FALSE(SamplesScreen(*pass));
        if (pass->desc().output != SpecTex_Default) continue;
        ++onto_scene;
        const auto* material = pass->desc().node->Mesh()->MaterialForSlot(pass->desc().material_slot);
        ASSERT_NE(material, nullptr);
        EXPECT_EQ(material->blenmode, BlendMode::Additive);
    }
    EXPECT_EQ(onto_scene, 1u);
}

namespace
{
// Where the layer's origin is drawn: its draw matrix taken on the point.
Eigen::Vector3d DrawnOrigin(SceneNode& node) {
    node.UpdateTrans();
    return (node.RenderTrans() * Eigen::Vector4d(0.0, 0.0, 0.0, 1.0)).head<3>();
}

Eigen::Vector3d ModelOrigin(SceneNode& node) {
    node.UpdateTrans();
    return node.ModelTrans().block<3, 1>(0, 3);
}

// A display that shows 560 of the canvas's 640 columns from column 10 on, and all of its
// 360 rows: left 10, right 70, top and bottom 0.
CursorViewport PannedViewport() {
    return CursorViewport { .origin = { 10.0f, 0.0f }, .size = { 560.0f, 360.0f },
                            .content_origin = { 10.0f, 0.0f }, .content_size = { 560.0f, 360.0f } };
}
CursorViewport WholeCanvas() {
    return CursorViewport { .origin = { 0.0f, 0.0f }, .size = { 640.0f, 360.0f },
                            .content_origin = { 0.0f, 0.0f }, .content_size = { 640.0f, 360.0f } };
}
} // namespace

TEST(TextObjectRuntime, ScreenAnchorOffsetsPinTheLayerToTheEdgeItNames) {
    // Margins in scene units, y up: positive where the canvas is cropped.
    const PresentedMargins margins { .left = 10.0f, .top = 4.0f, .right = 30.0f, .bottom = 6.0f };
    const auto offset = [&](std::string_view name) {
        return TextScreenAnchorOffset(ParseTextScreenAnchor(name), margins);
    };
    EXPECT_TRUE(offset("center").isApprox(Eigen::Vector2f(-10.0f, 1.0f)));
    EXPECT_TRUE(offset("top").isApprox(Eigen::Vector2f(-10.0f, -4.0f)));
    EXPECT_TRUE(offset("bottom").isApprox(Eigen::Vector2f(-10.0f, 6.0f)));
    EXPECT_TRUE(offset("left").isApprox(Eigen::Vector2f(10.0f, 1.0f)));
    EXPECT_TRUE(offset("right").isApprox(Eigen::Vector2f(-30.0f, 1.0f)));
    EXPECT_TRUE(offset("topleft").isApprox(Eigen::Vector2f(10.0f, -4.0f)));
    EXPECT_TRUE(offset("topright").isApprox(Eigen::Vector2f(-30.0f, -4.0f)));
    EXPECT_TRUE(offset("bottomleft").isApprox(Eigen::Vector2f(10.0f, 6.0f)));
    EXPECT_TRUE(offset("bottomright").isApprox(Eigen::Vector2f(-30.0f, 6.0f)));
    EXPECT_TRUE(offset("none").isZero());
    EXPECT_TRUE(offset("").isZero());
    EXPECT_TRUE(offset("sideways").isZero());
    // The canvas shown whole leaves every layer where it is.
    for (const char* name : { "center", "top", "right", "bottomleft" }) {
        EXPECT_TRUE(TextScreenAnchorOffset(ParseTextScreenAnchor(name), PresentedMargins {}).isZero());
    }
}

TEST(TextObjectRuntime, ScreenAnchoredTextFollowsThePresentedAreaAndNothingElseDoes) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"top right","text":"a","font":"Arial","origin":[600,340,0],
       "anchor":"topright","horizontalalign":"right","verticalalign":"top","visible":true},
      {"id":2,"name":"left","text":"a","font":"Arial","origin":[40,180,0],
       "anchor":"left","horizontalalign":"left","verticalalign":"center","visible":true},
      {"id":3,"name":"centre","text":"a","font":"Arial","origin":[320,180,0],
       "anchor":"center","horizontalalign":"center","verticalalign":"center","visible":true},
      {"id":4,"name":"free","text":"a","font":"Arial","origin":[320,100,0],
       "anchor":"none","horizontalalign":"center","verticalalign":"center","visible":true},
      {"id":5,"name":"no key","text":"a","font":"Arial","origin":[320,100,0],
       "horizontalalign":"center","verticalalign":"center","visible":true},
      {"id":6,"name":"edge only","text":"a","font":"Arial","origin":[320,100,0],
       "anchor":"bottomright","visible":true}
    ])", "text-screen-anchor");
    ASSERT_NE(fixture.scene, nullptr);
    auto& runtime = *fixture.scene->runtime;
    // Let the layers' first layout arrive, which places them around their origins.
    for (int attempt = 0; attempt < 500 && runtime.TextLayoutInFlight(); ++attempt) {
        runtime.PumpTextLayerCache();
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    ASSERT_FALSE(runtime.TextLayoutInFlight());
    const auto names = { "top right", "left", "centre", "free", "no key", "edge only" };
    std::map<std::string, Eigen::Vector3f> resting;
    const auto placed = [&](const char* name) -> Eigen::Vector3f {
        // Where the layer's origin is drawn, which the anchor offset moves.
        return DrawnOrigin(*FindRootChild(*fixture.scene, name)).cast<float>();
    };
    for (const char* name : names) resting[name] = placed(name);

    // `anchor` never names a point of the layer: a layer with only that key sits
    // exactly where one with no key at all does.
    EXPECT_TRUE(resting["edge only"].isApprox(resting["no key"]));

    // The window shows 560 of the canvas's 640 columns, 10 columns in from the
    // left (a pan), and all of its height.
    runtime.SetCursorViewport(CursorViewport {
        .origin = { 10.0f, 0.0f }, .size = { 560.0f, 360.0f },
        .content_origin = { 10.0f, 0.0f }, .content_size = { 560.0f, 360.0f } });
    const auto moved = [&](const char* name) -> Eigen::Vector3f {
        return placed(name) - resting[name];
    };
    // left = 10, right = 640 - 570 = 70, top = bottom = 0.
    EXPECT_TRUE(moved("top right").isApprox(Eigen::Vector3f(-70.0f, 0.0f, 0.0f)));
    EXPECT_TRUE(moved("left").isApprox(Eigen::Vector3f(10.0f, 0.0f, 0.0f)));
    EXPECT_TRUE(moved("centre").isApprox(Eigen::Vector3f(-30.0f, 0.0f, 0.0f)));
    EXPECT_TRUE(moved("free").isZero());
    EXPECT_TRUE(moved("no key").isZero());
    EXPECT_TRUE(moved("edge only").isApprox(Eigen::Vector3f(-70.0f, 0.0f, 0.0f)));

    // A display that shows more than the canvas moves the layers outward.
    runtime.SetCursorViewport(CursorViewport {
        .origin = { 0.0f, -45.0f }, .size = { 640.0f, 450.0f },
        .content_origin = { 0.0f, 0.0f }, .content_size = { 640.0f, 360.0f } });
    EXPECT_TRUE(moved("top right").isApprox(Eigen::Vector3f(0.0f, 45.0f, 0.0f)));
    // Centred, the extra room is the same on both sides, so "center" stays put.
    EXPECT_TRUE(moved("centre").isApprox(Eigen::Vector3f::Zero()));
    EXPECT_TRUE(moved("free").isZero());

    // Presenting the canvas whole puts everything back.
    runtime.SetCursorViewport(CursorViewport {
        .origin = { 0.0f, 0.0f }, .size = { 640.0f, 360.0f },
        .content_origin = { 0.0f, 0.0f }, .content_size = { 640.0f, 360.0f } });
    for (const char* name : names) {
        EXPECT_TRUE(placed(name).isApprox(resting[name])) << name;
    }
}


// ---------------------------------------------------------------------------
// The font shader's outline, blur and drop shadow. The raster of a styled
// layer holds three coverage masks, red the glyph, green the glyph with its
// outline and blue the shadow, with room around the card for what they reach.
// ---------------------------------------------------------------------------

namespace
{
// The box of the pixels of one channel at or above `threshold`.
InkBox ChannelBounds(const Rastered& image, std::size_t channel, uint8_t threshold) {
    InkBox box;
    for (uint32_t y = 0; y < image.height; ++y) {
        for (uint32_t x = 0; x < image.width; ++x) {
            if (image.rgba[(static_cast<std::size_t>(y) * image.width + x) * 4u + channel] <
                threshold) {
                continue;
            }
            box.min_x = std::min(box.min_x, static_cast<int>(x));
            box.max_x = std::max(box.max_x, static_cast<int>(x));
            box.min_y = std::min(box.min_y, static_cast<int>(y));
            box.max_y = std::max(box.max_y, static_cast<int>(y));
        }
    }
    return box;
}

TextLayerState StyledState(float point_size = 40.0f) {
    auto state = HelveticaState("H", point_size);
    state.style.outline_color = Eigen::Vector3f(1.0f, 0.0f, 0.0f);
    return state;
}
} // namespace

TEST(TextObjectRuntime, OutlineGrowsTheGlyphByItsThicknessInPixels) {
    auto plain = StyledState();
    auto outlined          = plain;
    outlined.style.outline = true;
    outlined.style.outline_thickness = 3.0f;
    ASSERT_TRUE(TextStyleActive(outlined.style));
    ASSERT_FALSE(TextStyleActive(plain.style));

    const auto glyph = RasterOf(outlined);
    const auto fill  = ChannelBounds(glyph, 0, 128);
    const auto outer = ChannelBounds(glyph, 1, 128);
    ASSERT_TRUE(fill.Any() && outer.Any());
    // One unit of thickness is one pixel of the finished text.
    EXPECT_NEAR(fill.min_x - outer.min_x, 3, 1);
    EXPECT_NEAR(outer.max_x - fill.max_x, 3, 1);
    EXPECT_NEAR(fill.min_y - outer.min_y, 3, 1);
    EXPECT_NEAR(outer.max_y - fill.max_y, 3, 1);

    // The glyph itself is where plain text puts it, shifted by the room the
    // style asks around the card.
    const auto bare   = RasterOf(plain);
    const auto bare_box = InkBounds(bare.rgba, bare.width, bare.height);
    const int  margin = static_cast<int>((glyph.width - bare.width) / 2u);
    EXPECT_GE(margin, 4);
    EXPECT_EQ(glyph.height - bare.height, static_cast<uint32_t>(2 * margin));
    EXPECT_NEAR(fill.min_x - margin, bare_box.min_x, 1);
    EXPECT_NEAR(fill.max_x - margin, bare_box.max_x, 1);
    EXPECT_NEAR(fill.min_y - margin, bare_box.min_y, 1);
    EXPECT_NEAR(fill.max_y - margin, bare_box.max_y, 1);
    // Reconstructed from the distance field, the glyph keeps its antialiasing:
    // nearly every pixel agrees with plain coverage.
    std::size_t differing = 0, covered = 0;
    for (uint32_t y = 0; y < bare.height; ++y) {
        for (uint32_t x = 0; x < bare.width; ++x) {
            const int a = bare.rgba[(static_cast<std::size_t>(y) * bare.width + x) * 4u + 3u];
            const int r = glyph.rgba[(static_cast<std::size_t>(y + margin) * glyph.width +
                                      (x + margin)) * 4u];
            if (a > 0 || r > 0) ++covered;
            if (std::abs(a - r) > 40) ++differing;
        }
    }
    ASSERT_GT(covered, 100u);
    EXPECT_LT(differing * 50u, covered) << differing << " of " << covered;
}

TEST(TextObjectRuntime, OutlineThicknessIsCappedWithTheGlyphAtlasAndNeverBelowOnePixel) {
    auto state                   = StyledState();
    state.style.outline          = true;
    state.style.outline_thickness = 100.0f;
    const auto huge = RasterOf(state);
    const auto huge_gap = ChannelBounds(huge, 0, 128).min_x - ChannelBounds(huge, 1, 128).min_x;
    // 5.1 pixels of a 32 pixel atlas em, at 166 pixels to the em.
    EXPECT_NEAR(huge_gap, 26.6f, 2.0f);

    state.style.outline_thickness = 0.1f;
    const auto thin = RasterOf(state);
    const auto thin_gap = ChannelBounds(thin, 0, 128).min_x - ChannelBounds(thin, 1, 128).min_x;
    EXPECT_NEAR(thin_gap, 1, 1);
}

TEST(TextObjectRuntime, BlurSoftensEdgesOverItsSizeAndKeepsTheGlyphWhereItIs) {
    auto crisp = StyledState();
    crisp.style.outline = true; // an active style that does not blur
    crisp.style.outline_thickness = 1.0f;
    auto soft          = StyledState();
    soft.style.blur    = true;
    soft.style.blur_size = 3.0f;

    const auto sharp = RasterOf(crisp);
    const auto blurred = RasterOf(soft);
    const auto partial = [](const Rastered& image) {
        std::size_t count = 0;
        for (uint32_t index = 0; index < image.width * image.height; ++index) {
            const auto value = image.rgba[static_cast<std::size_t>(index) * 4u];
            if (value > 20u && value < 235u) ++count;
        }
        return count;
    };
    EXPECT_GT(partial(blurred), partial(sharp) * 2u);

    // The half-coverage edge stays on the glyph's outline; the tail runs past it by a
    // few pixels, on a smoothstep three pixels either side.
    const auto half = ChannelBounds(blurred, 0, 128);
    const auto tail = ChannelBounds(blurred, 0, 8);
    ASSERT_TRUE(half.Any() && tail.Any());
    EXPECT_GE(half.min_x - tail.min_x, 1);
    EXPECT_LE(half.min_x - tail.min_x, 4);
}

TEST(TextObjectRuntime, DropShadowFollowsItsOffsetAndOpacityAndOutlineWidth) {
    auto state                    = StyledState();
    state.style.drop_shadow       = true;
    state.style.shadow_size       = 1.0f;
    state.style.shadow_opacity    = 0.5f;
    state.style.shadow_offset     = { 6.0f, 4.0f };
    const auto shadowed = RasterOf(state);
    const auto glyph    = ChannelBounds(shadowed, 0, 128);
    const auto shadow   = ChannelBounds(shadowed, 2, 32);
    ASSERT_TRUE(glyph.Any() && shadow.Any());
    // The same shape, 6 pixels right and 4 down, a little soft at the edge.
    EXPECT_NEAR((shadow.max_x - glyph.max_x), 6, 2);
    EXPECT_NEAR((shadow.max_y - glyph.max_y), 4, 2);
    EXPECT_NEAR((shadow.min_x - glyph.min_x), 6, 2);
    EXPECT_NEAR((shadow.min_y - glyph.min_y), 4, 2);
    // Opacity is in the mask: the blue channel never reaches more than half.
    int strongest = 0;
    for (std::size_t offset = 2; offset < shadowed.rgba.size(); offset += 4u) {
        strongest = std::max<int>(strongest, shadowed.rgba[offset]);
    }
    EXPECT_NEAR(strongest, 128, 3);

    // Outlined text casts the shadow of the outlined shape.
    auto outlined                    = state;
    outlined.style.outline           = true;
    outlined.style.outline_thickness = 3.0f;
    const auto both        = RasterOf(outlined);
    const auto both_glyph  = ChannelBounds(both, 0, 128);
    const auto both_shadow = ChannelBounds(both, 2, 32);
    EXPECT_NEAR(both_shadow.max_x - both_glyph.max_x, 6 + 3, 2);
    EXPECT_NEAR(both_shadow.max_y - both_glyph.max_y, 4 + 3, 2);
}

TEST(TextObjectRuntime, StyledTextCardGrowsOutwardAndKeepsTheLayoutBoxWhereItWas) {
    auto state             = HelveticaState("Hg", 30.0f);
    state.horizontal_align = "left";
    state.vertical_align   = "top";
    const auto plain_size   = TextLayerRasterSize(state);
    const auto plain_bounds = TextLayerRenderBoundsForLayout(state, MeasureTextLayerLayout(state));
    EXPECT_EQ(TextStyleMargin(state), 0.0f);

    state.style.outline = true;
    state.style.outline_thickness = 4.0f;
    const float margin = TextStyleMargin(state);
    ASSERT_GE(margin, 5.0f);
    const auto size = TextLayerRasterSize(state);
    EXPECT_TRUE(size.isApprox(plain_size + Eigen::Vector2f::Constant(2.0f * margin)));
    // The layout card, which the layer is placed by, does not move: the raster gains
    // the margin on every side.
    EXPECT_TRUE(MeasureTextLayerSize(state).isApprox(plain_size));
    const auto bounds = TextLayerRenderBoundsForLayout(state, MeasureTextLayerLayout(state));
    EXPECT_FLOAT_EQ(bounds.left, plain_bounds.left - margin);
    EXPECT_FLOAT_EQ(bounds.right, plain_bounds.right + margin);
    EXPECT_FLOAT_EQ(bounds.top, plain_bounds.top + margin);
    EXPECT_FLOAT_EQ(bounds.bottom, plain_bounds.bottom - margin);
    // And the text sits in the card where it would without the style.
    const auto styled = RasterOf(state);
    const auto box    = ChannelBounds(styled, 1, 128);
    ASSERT_TRUE(box.Any());
    EXPECT_GE(box.min_x, 1);
    EXPECT_GE(box.min_y, 1);
    EXPECT_LT(box.max_x, static_cast<int>(styled.width) - 1);
}

TEST(TextObjectRuntime, ParserReadsTheFontShaderStyleAndPicksTheStyledShader) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"plain","text":"a","font":"Arial","visible":true},
      {"id":2,"name":"msdf only","text":"a","font":"Arial","msdf":true,"visible":true},
      {"id":3,"name":"outlined","text":"a","font":"Arial","pointsize":26,"outline":true,
       "outlinethickness":2.45,"outlinecolor":"1 0.5 0.25","visible":true},
      {"id":4,"name":"shadowed","text":"a","font":"Arial","dropshadow":true,"dropshadowsize":1.0,
       "dropshadowopacity":0.75,"dropshadowoffset":"2.0 3.0","dropshadowcolor":"0.4 0.3 0.6",
       "visible":true},
      {"id":5,"name":"blurred","text":"a","font":"Arial","msdf":true,"blur":true,"blursize":1.0,
       "visible":true},
      {"id":6,"name":"defaults","text":"a","font":"Arial","outline":true,"blur":true,"dropshadow":true,
       "visible":true}
    ])", "text-style-keys");
    ASSERT_NE(fixture.scene, nullptr);

    EXPECT_FALSE(TextStyleActive(fixture.State("plain").style));
    // `msdf` only picks how the glyph edges are rebuilt.
    EXPECT_FALSE(TextStyleActive(fixture.State("msdf only").style));

    const auto outlined = fixture.State("outlined").style;
    EXPECT_TRUE(outlined.outline);
    EXPECT_FLOAT_EQ(outlined.outline_thickness, 2.45f);
    EXPECT_TRUE(outlined.outline_color.isApprox(Eigen::Vector3f(1.0f, 0.5f, 0.25f)));
    EXPECT_FALSE(outlined.drop_shadow);

    const auto shadowed = fixture.State("shadowed").style;
    EXPECT_TRUE(shadowed.drop_shadow);
    EXPECT_FLOAT_EQ(shadowed.shadow_size, 1.0f);
    EXPECT_FLOAT_EQ(shadowed.shadow_opacity, 0.75f);
    EXPECT_TRUE(shadowed.shadow_offset.isApprox(Eigen::Vector2f(2.0f, 3.0f)));
    EXPECT_TRUE(shadowed.shadow_color.isApprox(Eigen::Vector3f(0.4f, 0.3f, 0.6f)));

    const auto blurred = fixture.State("blurred").style;
    EXPECT_TRUE(blurred.blur);
    EXPECT_FLOAT_EQ(blurred.blur_size, 1.0f);

    // Wallpaper Engine's defaults for the keys being absent.
    const auto defaults = fixture.State("defaults").style;
    EXPECT_FLOAT_EQ(defaults.outline_thickness, 4.0f);
    EXPECT_FLOAT_EQ(defaults.blur_size, 6.0f);
    EXPECT_FLOAT_EQ(defaults.shadow_size, 6.0f);
    EXPECT_FLOAT_EQ(defaults.shadow_opacity, 1.0f);
    EXPECT_TRUE(defaults.shadow_offset.isApprox(Eigen::Vector2f(4.0f, 4.0f)));
    EXPECT_TRUE(defaults.outline_color.isZero());

    const auto shader_of = [&](std::string_view name) -> const SceneMaterial* {
        auto* node = FindRootChild(*fixture.scene, name);
        return node != nullptr && node->Mesh() != nullptr ? node->Mesh()->Material() : nullptr;
    };
    const auto* plain_material    = shader_of("plain");
    const auto* outlined_material = shader_of("outlined");
    const auto* shadowed_material = shader_of("shadowed");
    ASSERT_NE(plain_material, nullptr);
    ASSERT_NE(outlined_material, nullptr);
    ASSERT_NE(shadowed_material, nullptr);
    EXPECT_EQ(plain_material->customShader.shader->name, "text");
    // The glyph is mixed with the outline's colour only for a layer with an
    // outline; a shadow or a blur alone leaves the glyph the layer's colour.
    EXPECT_EQ(outlined_material->customShader.shader->name, "text_styled_outline");
    EXPECT_EQ(shadowed_material->customShader.shader->name, "text_styled");
    // Only the glyph takes the layer's colour; the outline and shadow keep their own.
    const auto& values = outlined_material->customShader.constValues;
    ASSERT_TRUE(values.contains("g_OutlineColor"));
    ASSERT_TRUE(values.contains("g_ShadowColor"));
    EXPECT_FLOAT_EQ(values.at("g_OutlineColor")[1], 0.5f);
    EXPECT_FALSE(plain_material->customShader.constValues.contains("g_OutlineColor"));
    EXPECT_FALSE(shadowed_material->customShader.constValues.contains("g_OutlineColor"));
    EXPECT_TRUE(shadowed_material->customShader.constValues.contains("g_ShadowColor"));
}

TEST(TextObjectRuntime, StyledTextCardCoversTheStyleWhenTheLayerIsParsed) {
    // A layer with an outline gets a larger raster than its text, and its card
    // mesh the same room, so the outline is not cut off at the layout box.
    TextSceneFixture fixture(R"([
      {"id":1,"name":"plain","text":"Hg","font":"Arial","pointsize":20,"visible":true,
       "origin":[100,100,0],"horizontalalign":"left","verticalalign":"top"},
      {"id":2,"name":"outlined","text":"Hg","font":"Arial","pointsize":20,"visible":true,
       "outline":true,"outlinethickness":4,"origin":[100,100,0],"horizontalalign":"left",
       "verticalalign":"top"}
    ])", "text-style-card");
    ASSERT_NE(fixture.scene, nullptr);
    auto* plain    = FindRootChild(*fixture.scene, "plain");
    auto* outlined = FindRootChild(*fixture.scene, "outlined");
    ASSERT_NE(plain, nullptr);
    ASSERT_NE(outlined, nullptr);
    const auto plain_card    = MeshLocalBounds(*plain->Mesh());
    const auto outlined_card = MeshLocalBounds(*outlined->Mesh());
    const float margin = TextStyleMargin(fixture.State("outlined"));
    ASSERT_GT(margin, 4.0f);
    EXPECT_NEAR(outlined_card.min_x, plain_card.min_x - margin, 0.01f);
    EXPECT_NEAR(outlined_card.max_x, plain_card.max_x + margin, 0.01f);
    EXPECT_NEAR(outlined_card.min_y, plain_card.min_y - margin, 0.01f);
    EXPECT_NEAR(outlined_card.max_y, plain_card.max_y + margin, 0.01f);
    // The layer's size, which places it and answers the cursor, is the text's.
    EXPECT_TRUE(fixture.scene->runtime->NodeSize("outlined").isApprox(
        fixture.scene->runtime->NodeSize("plain")));
    // And the texture is that large, with the outline in it.
    auto* material = outlined->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    auto image = fixture.scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    EXPECT_NEAR(image->header.width, plain_card.max_x - plain_card.min_x + 2.0f * margin, 1.0f);
}

TEST(TextObjectRuntime, ATextLayerRegistersItsSolidAndPropagationFlagsForTheCursor) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"plain","text":"a","font":"Arial","visible":true},
      {"id":2,"name":"not solid","text":"a","font":"Arial","solid":false,"visible":true},
      {"id":3,"name":"blocker","text":"a","font":"Arial","disablepropagation":true,"visible":true}
    ])", "text-cursor-target");
    ASSERT_NE(fixture.scene, nullptr);
    ASSERT_NE(fixture.scene->runtime, nullptr);
    const auto target = [&](std::string_view name) {
        return fixture.scene->runtime->NodeCursorTargetOf(name).value_or(
            SceneRuntimeContext::NodeCursorTarget { .hittable = false, .solid = false, .blocks = true });
    };
    // Solid is on unless the scene says otherwise, and propagation is not
    // disabled unless it does.
    EXPECT_TRUE(target("plain").hittable);
    EXPECT_TRUE(target("plain").solid);
    EXPECT_FALSE(target("plain").blocks);
    EXPECT_FALSE(target("not solid").solid);
    EXPECT_TRUE(target("blocker").blocks);
}


// The size of a text layer in a scene file is the card Wallpaper Engine laid the
// text out in, so it is ground truth for the layout. These are five cards it saved
// for text objects set in Arial: the text, the point size, the padding that
// applied to the layer (none unless it had effects or a colour blend), and the size
// it wrote. Kerned pairs, unhinted whole-pixel advances, the pen-and-ink width of a
// row, the line gap in the height and the padding on both axes all have to agree.
// They are the metrics of the Arial of the machine that ran Wallpaper Engine; a
// build of the font with other metrics shows here as a difference, not a skip.
TEST(TextObjectRuntime, TextMeasuresToTheCardsWallpaperEngineSaved) {
    struct SavedCard {
        const char* text;
        float       point_size;
        float       padding;
        float       width;
        float       height;
    };
    const SavedCard cards[] = {
        { "Text Layer", 32.0f, 0.0f, 615.0f, 153.0f },
        { "Text Layer", 32.0f, 32.0f, 679.0f, 217.0f },
        { ".", 32.0f, 0.0f, 26.0f, 153.0f },
        { "\xE2\x80\x94\xE2\x80\x94\xE2\x80\x94\xE2\x80\x94\xE2\x80\x94", 32.0f, 32.0f, 729.0f, 217.0f },
        { "__________________________", 32.0f, 0.0f, 1929.0f, 153.0f },
    };
    for (const auto& card : cards) {
        TextLayerState state {
            .text                   = card.text,
            .font_key               = "systemfont_arial",
            .resolved_font_kind     = "system",
            .resolved_font_identity = "arial",
            .resolved_font_path     = ResolveSystemFontPath("systemfont_arial"),
            .point_size             = card.point_size,
            .padding                = { card.padding, card.padding },
        };
        if (state.resolved_font_path.empty()) GTEST_SKIP() << "no Arial on this system";
        const auto size = MeasureTextLayerSize(state);
        EXPECT_FLOAT_EQ(size.x(), card.width) << card.text;
        EXPECT_FLOAT_EQ(size.y(), card.height) << card.text;
    }
}

namespace
{
// The runtime texture a text layer's card shows: its size in texels, and the first and
// last columns that hold ink.
struct TextTexture {
    int width { 0 };
    int height { 0 };
    int first_ink_column { -1 };
    int last_ink_column { -1 };
};

TextTexture TextureOfTextLayer(Scene& scene, SceneNode& node) {
    TextTexture out;
    const auto* material = node.Mesh() != nullptr ? node.Mesh()->MaterialForSlot(0) : nullptr;
    if (material == nullptr || material->textures.empty()) return out;
    const auto image = scene.imageParser->Parse(material->textures.front());
    if (image == nullptr || image->slots.empty() || image->slots[0].mipmaps.empty()) return out;
    const auto& mip = image->slots[0].mipmaps[0];
    out.width       = mip.width;
    out.height      = mip.height;
    for (int y = 0; y < mip.height; ++y) {
        for (int x = 0; x < mip.width; ++x) {
            if (mip.data.get()[(static_cast<std::size_t>(y) * mip.width + x) * 4u + 3u] == 0u) continue;
            if (out.first_ink_column < 0) out.first_ink_column = x;
            out.first_ink_column = std::min(out.first_ink_column, x);
            out.last_ink_column  = std::max(out.last_ink_column, x);
        }
    }
    return out;
}

// Where a text layer's card lies in the scene, y up: its quad with the node's translation
// and scale applied.
struct WorldCard {
    float left { 0.0f };
    float right { 0.0f };
    float bottom { 0.0f };
    float top { 0.0f };
};

WorldCard WorldCardOf(SceneNode& node) {
    const auto bounds = MeshLocalBounds(*node.Mesh());
    const auto at     = node.Translate();
    const auto scale  = node.Scale();
    return {
        .left   = at.x() + scale.x() * bounds.min_x,
        .right  = at.x() + scale.x() * bounds.max_x,
        .bottom = at.y() + scale.y() * bounds.min_y,
        .top    = at.y() + scale.y() * bounds.max_y,
    };
}
} // namespace

// The text object's `size` is the box the editor drew. Wallpaper Engine's size function
// writes the laid-out block plus twice the padding every time the text is laid out, so
// the box never sets the card: not at load, and not when the text later grows or shrinks.
TEST(TextObjectRuntime, AuthoredTextObjectSizeDoesNotSetTheCard) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"clock","text":"12:34","font":"Arial","pointsize":20,"size":[320,120],
       "visible":true},
      {"id":2,"name":"bare","text":"12:34","font":"Arial","pointsize":20,"visible":true}
    ])", "text-authored-size");
    ASSERT_NE(fixture.scene, nullptr);
    ASSERT_NE(fixture.scene->runtime, nullptr);
    auto& runtime = *fixture.scene->runtime;
    auto* node    = FindRootChild(*fixture.scene, "clock");
    ASSERT_NE(node, nullptr);
    ASSERT_NE(node->Mesh(), nullptr);

    const auto check = [&](const char* when) {
        SCOPED_TRACE(when);
        const auto card = MeasureTextLayerSize(fixture.State("clock"));
        EXPECT_TRUE(runtime.NodeSize("clock").isApprox(card));
        const auto texture = TextureOfTextLayer(*fixture.scene, *node);
        EXPECT_EQ(texture.width, static_cast<int>(std::ceil(card.x())));
        EXPECT_EQ(texture.height, static_cast<int>(std::ceil(card.y())));
        EXPECT_NEAR(MeshSize(*node->Mesh()).x(), card.x(), 1.0f);
        EXPECT_NEAR(MeshSize(*node->Mesh()).y(), card.y(), 1.0f);
        return card;
    };

    const auto first = check("as parsed");
    // The box is larger than the text on both axes, so a layer that kept it would
    // show it here.
    ASSERT_LT(first.x(), 320.0f);
    ASSERT_LT(first.y(), 120.0f);
    EXPECT_TRUE(runtime.NodeSize("clock").isApprox(runtime.NodeSize("bare")));

    ASSERT_TRUE(runtime.SetNodeText("clock", "12:34:56 PM UTC"));
    PumpTextUntilClean(runtime);
    const auto grown = check("longer text");
    EXPECT_GT(grown.x(), first.x());

    ASSERT_TRUE(runtime.SetNodeText("clock", "1"));
    PumpTextUntilClean(runtime);
    const auto shrunk = check("shorter text");
    EXPECT_LT(shrunk.x(), first.x());
}

// A clock's script writes a shorter string than the text it started with: the card
// follows it down, as it follows a longer one up.
TEST(TextObjectRuntime, ACardShrinksWhenScriptedTextGetsShorter) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"clock","font":"Arial","pointsize":20,"size":[320,120],"visible":true,
       "text":{"value":"12:34:56 PM UTC",
               "script":"export function update(value) { return '1'; }"}}
    ])", "text-scripted-shrink");
    ASSERT_NE(fixture.scene, nullptr);
    ASSERT_NE(fixture.scene->runtime, nullptr);
    auto& runtime = *fixture.scene->runtime;
    auto* node    = FindRootChild(*fixture.scene, "clock");
    ASSERT_NE(node, nullptr);

    const auto wide = runtime.NodeSize("clock");
    runtime.Tick(1.0 / 60.0);
    PumpTextUntilClean(runtime);
    ASSERT_EQ(runtime.NodeText("clock"), "1");

    const auto card = MeasureTextLayerSize(fixture.State("clock"));
    EXPECT_LT(card.x(), wide.x());
    EXPECT_LT(card.x(), 320.0f);
    EXPECT_TRUE(runtime.NodeSize("clock").isApprox(card));
    const auto texture = TextureOfTextLayer(*fixture.scene, *node);
    EXPECT_EQ(texture.width, static_cast<int>(std::ceil(card.x())));
    EXPECT_EQ(texture.height, static_cast<int>(std::ceil(card.y())));
    EXPECT_NEAR(MeshSize(*node->Mesh()).x(), card.x(), 1.0f);
}

// A text layer is measured once as the scene loads, where its card, its texture and its
// runtime state each asked for a measurement of their own.
TEST(TextObjectRuntime, ATextLayerIsMeasuredOnceAsItIsParsed) {
    ResetTextLayerMeasurementCountForTests();
    TextSceneFixture fixture(R"([
      {"id":1,"name":"plain","text":"hello","font":"Arial","pointsize":20,"visible":true},
      {"id":2,"name":"blended","text":"hello","font":"Arial","pointsize":20,"colorBlendMode":12,
       "visible":true}
    ])", "text-measured-once", ColorBlendAssets());
    ASSERT_NE(fixture.scene, nullptr);
    EXPECT_EQ(TextLayerMeasurementCountForTests(), 2u);
}

// Wallpaper Engine builds the buffers of a text card at the card's size with the
// fraction cut off, so a card 175.68 wide is drawn into 175 texels.
TEST(TextObjectRuntime, ATextCardIsBuiltAtItsTruncatedSizeInTexels) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"caption","text":"hello","font":"Arial","pointsize":20,"padding":0,
       "spacing":"-3.58 0","colorBlendMode":12,"visible":true}
    ])", "text-card-truncation", ColorBlendAssets());
    ASSERT_NE(fixture.scene, nullptr);
    auto* node = FindRootChild(*fixture.scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_FALSE(node->Camera().empty());

    const auto card = TextLayerRasterSize(fixture.State("caption"));
    // A fraction of .5 or more: rounding and cutting it off differ.
    ASSERT_NE(std::lround(card.x()), static_cast<long>(card.x())) << card.x();
    const auto* ping_pong = fixture.scene->FindRenderTarget(
        std::string(WE_EFFECT_PPONG_PREFIX_A.data()) + node->Camera());
    ASSERT_NE(ping_pong, nullptr);
    EXPECT_EQ(ping_pong->width, static_cast<int32_t>(card.x()));
    EXPECT_EQ(ping_pong->height, static_cast<int32_t>(card.y()));
}

// Every buffer a card is drawn into takes its size from one rule, at parse and after
// each relayout: the card's width and height with the fraction cut off, 4 at least.
TEST(TextObjectRuntime, ACardsTexelExtentIsItsSizeWithTheFractionCutOff) {
    EXPECT_EQ(TextCardTexelExtent({ 175.68f, 40.99f }), (std::array<int32_t, 2> { 175, 40 }));
    EXPECT_EQ(TextCardTexelExtent({ 628.56f, 20.0f }), (std::array<int32_t, 2> { 628, 20 }));
    EXPECT_EQ(TextCardTexelExtent({ 3.9f, 0.2f }), (std::array<int32_t, 2> { 4, 4 }));
}

// Buffers that hold a card with its fraction cut off hold a card that grows by less
// than the texel they already have: the part past it was never in them, and drawing
// the card into them cuts it as before. Nothing is rebuilt for it.
TEST(TextObjectRuntime, ACardThatGrowsWithinATexelKeepsItsBuffers) {
    const auto layer = [](std::string_view text) {
        return R"([{"id":1,"name":"caption","text":")" + std::string(text) +
               R"(","font":"Arial","pointsize":20,"padding":0,"spacing":"0.4 0",
                  "colorBlendMode":12,"visible":true}])";
    };
    // Spacing adds 0.4 to each glyph, so of two texts whose glyphs advance alike in
    // whole pixels, the one with more glyphs has the wider card by a fraction of a
    // texel and the two share a texel count.
    TextSceneFixture probe(layer("a"), "text-fraction-probe", ColorBlendAssets());
    ASSERT_NE(probe.scene, nullptr);
    auto                    state = probe.State("caption");
    const std::string_view letters = "abcdefghijklmnopqrstuvwxyz";
    const auto              measure = [&](const std::string& text) {
        state.text = text;
        return MeasureTextLayerSize(state);
    };
    const auto pair = [&]() -> std::optional<std::pair<std::string, std::string>> {
        for (const char first : letters) {
            const auto one = measure(std::string(1, first));
            for (const char second : letters) {
                for (const char third : letters) {
                    const std::string two { second, third };
                    const auto        wide = measure(two);
                    if (static_cast<int>(wide.x()) == static_cast<int>(one.x()) &&
                        wide.x() >= one.x() + 0.1f && wide.y() == one.y())
                        return std::pair { std::string(1, first), two };
                }
            }
        }
        return std::nullopt;
    }();
    ASSERT_TRUE(pair.has_value()) << "no two texts share a texel and differ in their fraction";
    const auto& [shorter, longer] = *pair;

    TextSceneFixture fixture(layer(shorter), "text-fraction-growth", ColorBlendAssets());
    ASSERT_NE(fixture.scene, nullptr);
    ASSERT_NE(fixture.scene->runtime, nullptr);
    auto& runtime = *fixture.scene->runtime;
    auto* node    = FindRootChild(*fixture.scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_FALSE(node->Camera().empty());
    const std::string buffer = std::string(WE_EFFECT_PPONG_PREFIX_A.data()) + node->Camera();
    const auto        before = runtime.NodeSize("caption");
    ASSERT_NE(fixture.scene->FindRenderTarget(buffer), nullptr);
    const auto texels = fixture.scene->FindRenderTarget(buffer)->width;
    ASSERT_EQ(texels, static_cast<int32_t>(before.x()));

    auto graph = sceneToRenderGraph(*fixture.scene);
    ASSERT_NE(graph, nullptr);
    runtime.ConsumeSceneGraphMutationFlag();

    ASSERT_TRUE(runtime.SetNodeText("caption", longer));
    PumpTextUntilClean(runtime);
    ASSERT_EQ(runtime.NodeText("caption"), longer);
    EXPECT_GT(runtime.NodeSize("caption").x(), before.x());
    ASSERT_NE(fixture.scene->FindRenderTarget(buffer), nullptr);
    EXPECT_EQ(fixture.scene->FindRenderTarget(buffer)->width, texels);
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag())
        << "a fraction of a texel rebuilt the buffers";
}

// A plain text layer sits on its origin by the edge it is aligned to: the card's left
// edge for `left`, its right edge for `right` and its middle for `center`, along the
// layer's own scale, and its top edge for `top`. Pinned across the changes to how a
// card is placed.
TEST(TextObjectRuntime, PlainAlignedTextKeepsItsCardEdgeOnTheOrigin) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"left","text":"HI","font":"Arial","pointsize":20,"origin":[300,100,0],
       "scale":[2,3,1],"horizontalalign":"left","verticalalign":"top","visible":true},
      {"id":2,"name":"right","text":"HI","font":"Arial","pointsize":20,"origin":[300,100,0],
       "scale":[2,3,1],"horizontalalign":"right","verticalalign":"top","visible":true},
      {"id":3,"name":"centre","text":"HI","font":"Arial","pointsize":20,"origin":[300,100,0],
       "scale":[2,3,1],"horizontalalign":"center","verticalalign":"top","visible":true}
    ])", "text-plain-alignment");
    ASSERT_NE(fixture.scene, nullptr);
    for (const char* name : { "left", "right", "centre" }) {
        ASSERT_NE(FindRootChild(*fixture.scene, name), nullptr) << name;
        ASSERT_NE(FindRootChild(*fixture.scene, name)->Mesh(), nullptr) << name;
    }
    const auto left   = WorldCardOf(*FindRootChild(*fixture.scene, "left"));
    const auto right  = WorldCardOf(*FindRootChild(*fixture.scene, "right"));
    const auto centre = WorldCardOf(*FindRootChild(*fixture.scene, "centre"));
    EXPECT_NEAR(left.left, 300.0f, 1.0e-3f);
    EXPECT_NEAR(right.right, 300.0f, 1.0e-3f);
    EXPECT_NEAR((centre.left + centre.right) * 0.5f, 300.0f, 1.0e-3f);
    for (const auto& card : { left, right, centre }) EXPECT_NEAR(card.top, 100.0f, 1.0e-3f);

    // The ink is in the card at the edge it is aligned to: a left bearing's width
    // from the left edge of `left`, and a texel from the right edge of `right`.
    const auto texture_left  = TextureOfTextLayer(*fixture.scene, *FindRootChild(*fixture.scene, "left"));
    const auto texture_right = TextureOfTextLayer(*fixture.scene, *FindRootChild(*fixture.scene, "right"));
    ASSERT_GE(texture_left.first_ink_column, 0);
    ASSERT_GE(texture_right.last_ink_column, 0);
    const float texel_left  = (left.right - left.left) / static_cast<float>(texture_left.width);
    const float texel_right = (right.right - right.left) / static_cast<float>(texture_right.width);
    const float em_pixels   = 20.0f * 300.0f / 72.0f;
    EXPECT_LE(texture_left.first_ink_column, static_cast<int>(0.15f * em_pixels));
    EXPECT_NEAR(left.left + static_cast<float>(texture_left.first_ink_column) * texel_left, 300.0f,
                0.15f * em_pixels * 2.0f);
    EXPECT_NEAR(right.left + static_cast<float>(texture_right.last_ink_column + 1) * texel_right,
                300.0f, 1.0f * 2.0f + 1.0e-3f);
}

// ---------------------------------------------------------------------------
// Where an aligned text lies about its layer's origin, as Wallpaper Engine places it: the
// layer's alignment offsets the card inside the layer's own draw and nothing else. The
// node stays where the scene put it, the origin sits on the edge of the text's block the
// alignment names (the left, middle or right of it across; down, the ascender line, the
// middle of the rows, or the last row's descender line), and the padding grows the card
// outward from there.
// ---------------------------------------------------------------------------

namespace
{
// A box in a layer's own units from its origin, y up.
struct NodeRect {
    float left { 0.0f };
    float right { 0.0f };
    float bottom { 0.0f };
    float top { 0.0f };
};

// The pixels `first_column..last_column` by `first_row..last_row` (inclusive) of a text's
// raster, where the quad that shows the raster lays them.
NodeRect PixelsFromOrigin(const TextLayerState& state, const Rastered& image, int first_column,
                          int last_column, int first_row, int last_row) {
    const auto bounds = TextLayerRenderBoundsForLayout(state, MeasureTextLayerLayout(state));
    const float texel_width  = (bounds.right - bounds.left) / static_cast<float>(image.width);
    const float texel_height = (bounds.top - bounds.bottom) / static_cast<float>(image.height);
    return {
        .left   = bounds.left + texel_width * static_cast<float>(first_column),
        .right  = bounds.left + texel_width * static_cast<float>(last_column + 1),
        .bottom = bounds.top - texel_height * static_cast<float>(last_row + 1),
        .top    = bounds.top - texel_height * static_cast<float>(first_row),
    };
}

// Each run of raster rows that holds some ink, top to bottom, as (first, last).
std::vector<std::pair<int, int>> InkRowRuns(const Rastered& image) {
    std::vector<std::pair<int, int>> runs;
    for (uint32_t y = 0; y < image.height; ++y) {
        bool inked = false;
        for (uint32_t x = 0; x < image.width && ! inked; ++x) {
            inked = image.rgba[(static_cast<std::size_t>(y) * image.width + x) * 4u + 3u] != 0u;
        }
        if (! inked) continue;
        if (! runs.empty() && runs.back().second == static_cast<int>(y) - 1) {
            runs.back().second = static_cast<int>(y);
        } else {
            runs.emplace_back(static_cast<int>(y), static_cast<int>(y));
        }
    }
    return runs;
}

// The face's numbers as FreeType gives them, read the way Wallpaper Engine reads them: the
// face sized in points at 300 dpi, its size metrics cut to whole pixels.
struct FaceNumbers {
    float ascender { 0.0f };
    float descender { 0.0f };
    float pitch { 0.0f };
};

FaceNumbers FreeTypeFaceNumbers(const std::string& path, float point_size) {
    FaceNumbers numbers;
    FT_Library  library = nullptr;
    if (FT_Init_FreeType(&library) != 0) return numbers;
    FT_Face face = nullptr;
    if (FT_New_Face(library, path.c_str(), 0, &face) == 0) {
        if (FT_Set_Char_Size(face, 0, static_cast<FT_F26Dot6>(point_size * 64.0f), 300, 300) == 0) {
            numbers.ascender  = static_cast<float>(face->size->metrics.ascender >> 6);
            numbers.descender = static_cast<float>(-(face->size->metrics.descender >> 6));
            numbers.pitch     = static_cast<float>(face->size->metrics.height >> 6);
        }
        FT_Done_Face(face);
    }
    FT_Done_FreeType(library);
    return numbers;
}

// Where, down from the first row's baseline, the vertical alignment puts the layer's
// origin: the ascender line, the middle between it and the last baseline, or the last
// row's descender line.
float ReferenceLineOf(std::string_view vertical, const FaceNumbers& face, uint32_t rows,
                      float extra_pitch = 0.0f) {
    const float pitch = face.pitch + extra_pitch;
    const float below = static_cast<float>(rows - 1u) * pitch;
    if (vertical == "top") return face.ascender;
    if (vertical == "bottom") return -face.descender - below;
    return (face.ascender - below) * 0.5f;
}
} // namespace

// The first baseline lies `X` below the origin: the ascender for `top`, half of it for
// `center`, and for `bottom` the last row's descender line is on the origin. The numbers
// are FreeType's, read apart from the layout, and the baseline is found in the pixels.
TEST(TextObjectRuntime, TheReferenceLineOfTheVerticalAlignmentSitsOnTheOrigin) {
    const auto face = FreeTypeFaceNumbers(HelveticaState("H", 32.0f).resolved_font_path, 32.0f);
#ifdef __APPLE__
    ASSERT_GT(face.ascender, 0.0f);
#endif
    for (const std::string_view text : { "H", "H\nH\nH" }) {
        for (const float spacing : { 0.0f, 9.0f }) {
            const uint32_t rows = text.size() == 1 ? 1u : 3u;
            for (const std::string_view vertical : { "top", "center", "bottom" }) {
                SCOPED_TRACE(std::string(text) + " " + std::string(vertical) + " spacing " +
                             std::to_string(spacing));
                auto state            = HelveticaState(std::string(text), 32.0f);
                state.spacing         = { 0.0f, spacing };
                state.vertical_align  = std::string(vertical);
                const auto  image     = Rastered(RasterOf(state));
                const auto  runs      = InkRowRuns(image);
                ASSERT_EQ(runs.size(), static_cast<std::size_t>(rows));
                const float reference = ReferenceLineOf(vertical, face, rows, spacing);
                const float pitch     = face.pitch + spacing;
                for (std::size_t row = 0; row < runs.size(); ++row) {
                    const auto cap = PixelsFromOrigin(state, image, 0,
                                                      static_cast<int>(image.width) - 1,
                                                      runs[row].first, runs[row].second);
                    EXPECT_NEAR(cap.bottom, -reference - static_cast<float>(row) * pitch, 1.5f)
                        << "row " << row;
                }
                const auto layout = MeasureTextLayerLayout(state);
                EXPECT_EQ(layout.rows, rows);
                EXPECT_NEAR(layout.centre.y(),
                            (layout.top + layout.bottom) * 0.5f - reference, 1.0e-3f);
            }
        }
    }
}

// Wallpaper Engine's own numbers for the rule, from its frames of an Arial layer at 32
// points: the card is 153 tall (153 pixels of line, saved by the editor), so a single row
// has the ascender line at the top of it. Aligned to the top that line is the origin, so
// the card hangs 153 below it; to the centre the card's middle is half the line's
// overhang (153 less the ascender) below it; to the bottom, the descender above it.
TEST(TextObjectRuntime, ArialAtThirtyTwoPointsHangsFromTheOriginByTheReferenceLine) {
    TextLayerState state {
        .text                   = "Text Layer",
        .font_key               = "systemfont_arial",
        .resolved_font_kind     = "system",
        .resolved_font_identity = "arial",
        .resolved_font_path     = ResolveSystemFontPath("systemfont_arial"),
        .point_size             = 32.0f,
        .horizontal_align       = "left",
    };
    if (state.resolved_font_path.empty()) GTEST_SKIP() << "no Arial on this system";
    const auto face = FreeTypeFaceNumbers(state.resolved_font_path, 32.0f);
    ASSERT_FLOAT_EQ(face.pitch, 153.0f) << "the card Wallpaper Engine saved for this text";

    state.vertical_align = "top";
    auto layout          = MeasureTextLayerLayout(state);
    EXPECT_NEAR(layout.centre.y(), -153.0f * 0.5f, 1.0e-3f);
    EXPECT_NEAR(layout.centre.x(), 615.0f * 0.5f, 1.0e-3f);
    state.vertical_align = "center";
    layout               = MeasureTextLayerLayout(state);
    EXPECT_NEAR(layout.centre.y(), (face.ascender - 153.0f) * 0.5f, 1.0e-3f);
    state.vertical_align = "bottom";
    layout               = MeasureTextLayerLayout(state);
    EXPECT_NEAR(layout.centre.y(), face.ascender - 153.0f * 0.5f + face.descender, 1.0e-3f);
}

// The card is placed by the layout's offset alone: the block's left, middle or right across
// and the reference line down, with the padding added outward on every side, whichever
// way the text is aligned. The same offsets with the padding gate on or off differ by the
// padding and by nothing else.
TEST(TextObjectRuntime, TheCardHangsFromTheOriginByTheEdgeTheTextIsAlignedTo) {
    for (const Eigen::Vector2f padding : { Eigen::Vector2f(0.0f, 0.0f), Eigen::Vector2f(24.0f, 10.0f) }) {
        for (const std::string_view text : { "Hg", "Hg\nHgHg\nH" }) {
            for (const std::string_view horizontal : { "left", "center", "right" }) {
                for (const std::string_view vertical : { "top", "center", "bottom" }) {
                    SCOPED_TRACE(std::string(horizontal) + " " + std::string(vertical) + " " +
                                 std::string(text) + " padding " + std::to_string(padding.x()));
                    auto state             = HelveticaState(std::string(text), 24.0f);
                    state.padding          = padding;
                    state.horizontal_align = std::string(horizontal);
                    state.vertical_align   = std::string(vertical);
                    const auto layout      = MeasureTextLayerLayout(state);
                    const auto block       = layout.BlockSize();
                    const float reference = ReferenceLineOf(
                        vertical, FaceNumbers { layout.ascender, layout.descender, layout.pitch },
                        layout.rows);
                    const float across = horizontal == "left"    ? block.x() * 0.5f
                                         : horizontal == "right" ? -block.x() * 0.5f
                                                                 : 0.0f;
                    EXPECT_NEAR(layout.centre.x(), across, 1.0e-3f);
                    EXPECT_NEAR(layout.centre.y(), (layout.top + layout.bottom) * 0.5f - reference,
                                1.0e-3f);
                    // The edge the text is aligned to is on the origin, and the padding lies
                    // beyond it.
                    const float card_left  = layout.centre.x() - layout.card.x() * 0.5f;
                    const float card_right = layout.centre.x() + layout.card.x() * 0.5f;
                    const float card_top   = layout.centre.y() + layout.card.y() * 0.5f;
                    const float card_bottom = layout.centre.y() - layout.card.y() * 0.5f;
                    if (horizontal == "left") EXPECT_NEAR(card_left, -padding.x(), 1.0e-3f);
                    if (horizontal == "right") EXPECT_NEAR(card_right, padding.x(), 1.0e-3f);
                    if (horizontal == "center") EXPECT_NEAR(card_left + card_right, 0.0f, 1.0e-3f);
                    if (vertical == "top") EXPECT_NEAR(card_top, padding.y(), 1.0e-3f);
                    if (vertical == "bottom") {
                        EXPECT_NEAR(card_bottom, layout.bottom - reference - padding.y(), 1.0e-3f);
                    }
                    // The card does not depend on the alignment: only where it hangs does.
                    auto other = state;
                    other.horizontal_align = "left";
                    other.vertical_align   = "top";
                    EXPECT_TRUE(MeasureTextLayerLayout(other).card.isApprox(layout.card));
                }
            }
        }
    }
}

// Padding is room around the block, added on the outside of the aligned edges. A text
// that gets padding (a layer that gains an effect) stays where it was: its ink is at
// the same distance from the origin with and without it.
TEST(TextObjectRuntime, PaddingGrowsTheCardOutwardAndLeavesTheTextWhereItWas) {
    for (const std::string_view horizontal : { "left", "center", "right" }) {
        for (const std::string_view vertical : { "top", "center", "bottom" }) {
            SCOPED_TRACE(std::string(horizontal) + " " + std::string(vertical));
            auto plain             = HelveticaState("HIH\nHH", 24.0f);
            plain.horizontal_align = std::string(horizontal);
            plain.vertical_align   = std::string(vertical);
            auto padded            = plain;
            padded.padding         = { 24.0f, 10.0f };
            const auto plain_image  = RasterOf(plain);
            const auto padded_image = RasterOf(padded);
            const auto plain_ink =
                InkBounds(plain_image.rgba, plain_image.width, plain_image.height);
            const auto padded_ink =
                InkBounds(padded_image.rgba, padded_image.width, padded_image.height);
            ASSERT_TRUE(plain_ink.Any());
            ASSERT_TRUE(padded_ink.Any());
            const auto at_plain = PixelsFromOrigin(plain, plain_image, plain_ink.min_x,
                                                   plain_ink.max_x, plain_ink.min_y, plain_ink.max_y);
            const auto at_padded = PixelsFromOrigin(padded, padded_image, padded_ink.min_x,
                                                    padded_ink.max_x, padded_ink.min_y,
                                                    padded_ink.max_y);
            EXPECT_NEAR(at_padded.left, at_plain.left, 1.5f);
            EXPECT_NEAR(at_padded.right, at_plain.right, 1.5f);
            EXPECT_NEAR(at_padded.top, at_plain.top, 1.5f);
            EXPECT_NEAR(at_padded.bottom, at_plain.bottom, 1.5f);
            // The card is larger by the padding on each side.
            EXPECT_NEAR(static_cast<double>(padded_image.width),
                        static_cast<double>(plain_image.width) + 48.0, 1.0);
            EXPECT_NEAR(static_cast<double>(padded_image.height),
                        static_cast<double>(plain_image.height) + 20.0, 1.0);
        }
    }
}

// Alignment never changes what the card holds, only where the card hangs: one row of
// text is the same picture whichever way it is aligned.
TEST(TextObjectRuntime, AlignmentDoesNotChangeThePixelsOfARow) {
    auto state    = HelveticaState("Hg", 24.0f);
    state.padding = { 24.0f, 10.0f };
    const auto reference = RasterOf(state);
    for (const std::string_view horizontal : { "left", "center", "right" }) {
        for (const std::string_view vertical : { "top", "center", "bottom" }) {
            state.horizontal_align = std::string(horizontal);
            state.vertical_align   = std::string(vertical);
            const auto image       = RasterOf(state);
            EXPECT_EQ(image.width, reference.width);
            EXPECT_EQ(image.height, reference.height);
            EXPECT_EQ(image.rgba, reference.rgba) << horizontal << " " << vertical;
        }
    }
}

// The rows of a block are set within the widest row: its left edge for `left`, centred in
// it for `center`, against its right edge for `right`.
TEST(TextObjectRuntime, RowsOfABlockAlignWithinTheWidestRow) {
    const auto row_width = [](const char* text) {
        return MeasureTextLayerLayout(HelveticaState(text, 24.0f)).BlockSize().x();
    };
    const float widest = row_width("HHHHH");
    ASSERT_GT(widest, row_width("HH"));
    ASSERT_GT(row_width("HH"), row_width("H"));
    for (const std::string_view horizontal : { "left", "center", "right" }) {
        SCOPED_TRACE(horizontal);
        auto state             = HelveticaState("HHHHH\nHH\nH", 24.0f);
        state.horizontal_align = std::string(horizontal);
        const auto image       = RasterOf(state);
        const auto runs        = InkRowRuns(image);
        ASSERT_EQ(runs.size(), 3u);
        const char* const row_text[] = { "HHHHH", "HH", "H" };
        std::vector<float> starts;
        for (std::size_t row = 0; row < runs.size(); ++row) {
            const auto box = InkBounds(image.rgba, image.width, image.height,
                                       static_cast<uint32_t>(runs[row].first),
                                       static_cast<uint32_t>(runs[row].second) + 1u);
            ASSERT_TRUE(box.Any());
            starts.push_back(static_cast<float>(box.min_x));
            const float own = row_width(row_text[row]);
            const float offset = horizontal == "left"    ? 0.0f
                                 : horizontal == "center" ? (widest - own) * 0.5f
                                                          : widest - own;
            // The first row is the widest, so its ink starts where every row's offset is 0.
            EXPECT_NEAR(static_cast<float>(box.min_x) - starts.front(), offset, 1.5f)
                << "row " << row;
        }
    }
}

// A row's pen starts at its offset in the widest row and its first glyph then hangs by its
// own bearing, whatever the other rows start with: a row opened by a glyph that overhangs
// to the left is drawn that far left, and a row after it is not moved by it.
TEST(TextObjectRuntime, ARowsFirstGlyphKeepsItsOwnBearingWhateverTheOtherRowsStartWith) {
    const auto state_of = [](std::string text) { return HelveticaState(std::move(text), 32.0f); };
    // A glyph whose ink starts left of its pen: found in the face, since which one does
    // depends on the font.
    const auto face_path = state_of("H").resolved_font_path;
    FT_Library library   = nullptr;
    ASSERT_EQ(FT_Init_FreeType(&library), 0);
    FT_Face face = nullptr;
    ASSERT_EQ(FT_New_Face(library, face_path.c_str(), 0, &face), 0);
    ASSERT_EQ(FT_Set_Char_Size(face, 0, 32 * 64, 300, 300), 0);
    uint32_t overhang         = 0;
    int      overhang_bearing = 0;
    for (uint32_t codepoint = 'A'; codepoint <= 'z' && overhang == 0; ++codepoint) {
        if (FT_Load_Char(face, codepoint, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0) continue;
        if (face->glyph->bitmap_left < -1) {
            overhang         = codepoint;
            overhang_bearing = face->glyph->bitmap_left;
        }
    }
    ASSERT_EQ(FT_Load_Char(face, 'H', FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL), 0);
    const int plain_bearing = face->glyph->bitmap_left;
    FT_Done_Face(face);
    FT_Done_FreeType(library);
    ASSERT_NE(overhang, 0u) << "no glyph of this font starts left of its pen";

    for (const std::string_view horizontal : { "center", "right" }) {
        SCOPED_TRACE(horizontal);
        const std::string over(1, static_cast<char>(overhang));
        auto state             = state_of(over + "HHH\nH");
        state.horizontal_align = std::string(horizontal);
        const auto image       = RasterOf(state);
        const auto runs        = InkRowRuns(image);
        ASSERT_EQ(runs.size(), 2u);
        const auto second = InkBounds(image.rgba, image.width, image.height,
                                      static_cast<uint32_t>(runs[1].first),
                                      static_cast<uint32_t>(runs[1].second) + 1u);
        ASSERT_TRUE(second.Any());
        // The second row is a lone H: set as the row alone would be in the block's widest
        // row, its ink a bearing from where its pen is.
        const float widest = MeasureTextLayerLayout(state_of(over + "HHH")).BlockSize().x();
        const float own    = MeasureTextLayerLayout(state_of("H")).BlockSize().x();
        const float offset = horizontal == "center" ? (widest - own) * 0.5f : widest - own;
        const auto  layout = MeasureTextLayerLayout(state);
        const float pen_origin = -layout.min_x;
        EXPECT_NEAR(static_cast<float>(second.min_x), pen_origin + offset + static_cast<float>(plain_bearing),
                    1.5f);
    }

    // The overhang may be on a row that is not the widest. The rows are set within the widest
    // row's own width, not within the block's, which the overhang of a narrower row stretches
    // to the left: the wide row below starts at its pen, and the narrow one is offset from it
    // by the difference of the two rows' widths alone.
    const std::string over(1, static_cast<char>(overhang));
    const float       narrow = MeasureTextLayerLayout(state_of(over + "H")).BlockSize().x();
    const float       wide   = MeasureTextLayerLayout(state_of("HHHH")).BlockSize().x();
    ASSERT_GT(wide, narrow) << "the row below must be the widest";
    for (const std::string_view horizontal : { "center", "right" }) {
        SCOPED_TRACE(horizontal);
        auto state             = state_of(over + "H\nHHHH");
        state.horizontal_align = std::string(horizontal);
        const auto image       = RasterOf(state);
        const auto runs        = InkRowRuns(image);
        ASSERT_EQ(runs.size(), 2u);
        const auto first = InkBounds(image.rgba, image.width, image.height,
                                     static_cast<uint32_t>(runs[0].first),
                                     static_cast<uint32_t>(runs[0].second) + 1u);
        const auto second = InkBounds(image.rgba, image.width, image.height,
                                      static_cast<uint32_t>(runs[1].first),
                                      static_cast<uint32_t>(runs[1].second) + 1u);
        ASSERT_TRUE(first.Any());
        ASSERT_TRUE(second.Any());
        const float pen_origin = -MeasureTextLayerLayout(state).min_x;
        const float offset     = horizontal == "center" ? (wide - narrow) * 0.5f : wide - narrow;
        EXPECT_NEAR(static_cast<float>(second.min_x), pen_origin + static_cast<float>(plain_bearing), 1.5f);
        EXPECT_NEAR(static_cast<float>(first.min_x), pen_origin + offset + static_cast<float>(overhang_bearing),
                    1.5f);
    }
}

// The baseline is the face's, not the ink's: a glyph that rises above the ascender makes
// the card taller and moves nothing else.
TEST(TextObjectRuntime, TheFirstBaselineDoesNotDependOnInkAboveTheAscender) {
    auto plain = HelveticaState("H", 32.0f);
    auto ringed = HelveticaState("\xC3\x85", 32.0f);
    const auto plain_layout  = MeasureTextLayerLayout(plain);
    const auto ringed_layout = MeasureTextLayerLayout(ringed);
    ASSERT_GT(ringed_layout.top, plain_layout.top)
        << "this font's A with a ring no longer rises above its ascender";
    for (const std::string_view vertical : { "top", "center", "bottom" }) {
        SCOPED_TRACE(vertical);
        plain.vertical_align  = std::string(vertical);
        ringed.vertical_align = std::string(vertical);
        const auto lone   = Rastered(RasterOf(plain));
        const auto rung   = Rastered(RasterOf(ringed));
        const auto lone_ink = InkBounds(lone.rgba, lone.width, lone.height);
        const auto rung_ink = InkBounds(rung.rgba, rung.width, rung.height);
        ASSERT_TRUE(lone_ink.Any());
        ASSERT_TRUE(rung_ink.Any());
        const auto lone_at = PixelsFromOrigin(plain, lone, lone_ink.min_x, lone_ink.max_x,
                                              lone_ink.min_y, lone_ink.max_y);
        const auto rung_at = PixelsFromOrigin(ringed, rung, rung_ink.min_x, rung_ink.max_x,
                                              rung_ink.min_y, rung_ink.max_y);
        // Both sit on the baseline the alignment names.
        EXPECT_NEAR(rung_at.bottom, lone_at.bottom, 1.5f);
        EXPECT_GT(rung_at.top, lone_at.top);
    }
    EXPECT_GT(MeasureTextLayerLayout(ringed).card.y(), MeasureTextLayerLayout(plain).card.y());
}

// What a scene makes of it: the node stays at the layer's authored origin, scale and angle
// whatever the alignment is, the quad hangs from it by the layout's offset, in the layer's
// own axes, and a layer parented to a text sits on that text's origin.
TEST(TextObjectRuntime, AlignmentOffsetsTheQuadAndNeverTheNode) {
    std::string objects = "[";
    int         id      = 1;
    for (const char* horizontal : { "left", "center", "right" }) {
        for (const char* vertical : { "top", "center", "bottom" }) {
            if (id > 1) objects += ",";
            objects += R"({"id":)" + std::to_string(id) + R"(,"name":")" + horizontal + "-" +
                       vertical + R"(","text":"Hg","font":"Arial","pointsize":20,"origin":[300,120,0],)"
                       R"("scale":[2,3,1],"angles":[0,0,25],"horizontalalign":")" +
                       horizontal + R"(","verticalalign":")" + vertical + R"(","visible":true})";
            ++id;
        }
    }
    objects += "]";
    TextSceneFixture fixture(objects, "text-alignment-offsets");
    ASSERT_NE(fixture.scene, nullptr);
    for (const char* horizontal : { "left", "center", "right" }) {
        for (const char* vertical : { "top", "center", "bottom" }) {
            const std::string name = std::string(horizontal) + "-" + vertical;
            SCOPED_TRACE(name);
            auto* node = FindRootChild(*fixture.scene, name);
            ASSERT_NE(node, nullptr);
            ASSERT_NE(node->Mesh(), nullptr);
            EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(300.0f, 120.0f, 0.0f)));
            EXPECT_TRUE(node->Scale().isApprox(Eigen::Vector3f(2.0f, 3.0f, 1.0f)));
            EXPECT_GT(node->Rotation().z(), 0.1f);
            const auto layout = fixture.scene->runtime->NodeTextLayout(name);
            ASSERT_TRUE(layout.has_value());
            const auto bounds = MeshLocalBounds(*node->Mesh());
            const auto expected = TextLayerRenderBoundsForLayout(fixture.State(name), *layout);
            EXPECT_NEAR(bounds.min_x, expected.left, 1.0e-3f);
            EXPECT_NEAR(bounds.max_x, expected.right, 1.0e-3f);
            EXPECT_NEAR(bounds.min_y, expected.bottom, 1.0e-3f);
            EXPECT_NEAR(bounds.max_y, expected.top, 1.0e-3f);
            // The quad's aligned edge passes through the origin along the layer's own axes:
            // the point of the right edge, the left edge or the middle at the quad's height,
            // taken into the scene, lies on the layer's rotated vertical axis.
            node->UpdateTrans();
            const Eigen::Matrix4d model = node->ModelTrans();
            const double edge_x = std::string_view(horizontal) == "left"    ? bounds.min_x
                                  : std::string_view(horizontal) == "right" ? bounds.max_x
                                                                           : (bounds.min_x + bounds.max_x) * 0.5;
            const Eigen::Vector3d origin = model.block<3, 1>(0, 3);
            const Eigen::Vector3d edge =
                (model * Eigen::Vector4d(edge_x, layout->centre.y(), 0.0, 1.0)).head<3>();
            const Eigen::Vector3d across = model.block<3, 1>(0, 0).normalized();
            EXPECT_NEAR((edge - origin).dot(across), 0.0, 1.0e-3);
        }
    }
}

TEST(TextObjectRuntime, ChildrenOfAlignedTextStayOnTheParentsOrigin) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"parent","text":"parent","font":"Arial","pointsize":20,"origin":[400,200,0],
       "scale":[1.5,0.8,1],"angles":[0,0,30],"horizontalalign":"right","verticalalign":"bottom",
       "visible":true},
      {"id":2,"name":"child","parent":1,"text":"child","font":"Arial","pointsize":20,
       "origin":[0,35,0],"horizontalalign":"center","verticalalign":"center","visible":true}
    ])", "text-aligned-parent");
    ASSERT_NE(fixture.scene, nullptr);
    auto* parent = FindRootChild(*fixture.scene, "parent");
    ASSERT_NE(parent, nullptr);
    ASSERT_EQ(parent->GetChildren().size(), 1u);
    auto* child = parent->GetChildren().front().get();
    parent->UpdateTrans();
    child->UpdateTrans();
    // The child's own origin is its place in the parent's space: (0, 35) from the parent's.
    const Eigen::Vector3d expected =
        (parent->ModelTrans() * Eigen::Vector4d(0.0, 35.0, 0.0, 1.0)).head<3>();
    const Eigen::Vector3d actual = child->ModelTrans().block<3, 1>(0, 3);
    EXPECT_NEAR(actual.x(), expected.x(), 1.0e-3);
    EXPECT_NEAR(actual.y(), expected.y(), 1.0e-3);
    // And the parent's origin is where the scene put it.
    EXPECT_NEAR(parent->ModelTrans()(0, 3), 400.0, 1.0e-3);
    EXPECT_NEAR(parent->ModelTrans()(1, 3), 200.0, 1.0e-3);
}

// A script that changes `horizontalalign` changes where the card hangs and nothing about
// its size: the quad is moved by the relayout, the node is not.
TEST(TextObjectRuntime, ChangingTheAlignmentMovesTheQuadWithoutResizingIt) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"caption","text":"aligned","font":"Arial","pointsize":20,
       "origin":[100,50,0],"horizontalalign":"right","verticalalign":"top","visible":true}
    ])", "text-align-flip");
    ASSERT_NE(fixture.scene, nullptr);
    auto& runtime = *fixture.scene->runtime;
    auto* node    = FindRootChild(*fixture.scene, "caption");
    ASSERT_NE(node, nullptr);
    const auto card = runtime.NodeSize("caption");
    auto       bounds = MeshLocalBounds(*node->Mesh());
    EXPECT_NEAR(bounds.max_x, 0.0f, 1.0e-3f);
    EXPECT_NEAR(bounds.min_x, -card.x(), 1.0e-3f);

    ASSERT_TRUE(runtime.SetNodeTextStyle("caption", "horizontalalign", "left"));
    PumpTextUntilClean(runtime);
    EXPECT_TRUE(runtime.NodeSize("caption").isApprox(card));
    bounds = MeshLocalBounds(*node->Mesh());
    EXPECT_NEAR(bounds.min_x, 0.0f, 1.0e-3f);
    EXPECT_NEAR(bounds.max_x, card.x(), 1.0e-3f);
    EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(100.0f, 50.0f, 0.0f)));

    ASSERT_TRUE(runtime.SetNodeTextStyle("caption", "verticalalign", "bottom"));
    PumpTextUntilClean(runtime);
    bounds = MeshLocalBounds(*node->Mesh());
    const auto layout = runtime.NodeTextLayout("caption");
    ASSERT_TRUE(layout.has_value());
    EXPECT_NEAR(bounds.max_y, layout->top + layout->descender, 1.0e-3f);
    EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(100.0f, 50.0f, 0.0f)));
}

// The chain a text layer draws through follows its card when the alignment moves it: the
// card the chain ends in, the target it is drawn from and the camera that frames it
// all hang off the new side of the origin, with the card still inside what the chain
// draws into and no graph rebuilt for a card that did not change size.
TEST(TextObjectRuntime, AnEffectChainFollowsTheCardWhenTheAlignmentMovesIt) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"caption","text":"aligned","font":"Arial","pointsize":20,"padding":0,
       "origin":[100,50,0],"horizontalalign":"right","verticalalign":"center","colorBlendMode":12,
       "visible":true}
    ])", "text-align-flip-effect", ColorBlendAssets());
    ASSERT_NE(fixture.scene, nullptr);
    auto& runtime = *fixture.scene->runtime;
    auto* node    = FindRootChild(*fixture.scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_FALSE(node->Camera().empty());
    auto camera = fixture.scene->cameras.at(node->Camera());
    ASSERT_TRUE(camera->HasImgEffect());
    const auto effect_layer = camera->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);
    const auto card = runtime.NodeSize("caption");

    const auto expect_card_at = [&](float side) {
        const auto layout = runtime.NodeTextLayout("caption");
        ASSERT_TRUE(layout.has_value());
        EXPECT_NEAR(layout->centre.x(), side * card.x() * 0.5f, 1.0e-3f);
        const auto final_box = MeshLocalBounds(effect_layer->FinalMesh());
        EXPECT_NEAR(MeshCenter(effect_layer->FinalMesh()).x(), layout->centre.x(), 1.0e-3f);
        EXPECT_NEAR(MeshCenter(effect_layer->FinalMesh()).y(), layout->centre.y(), 1.0e-3f);
        EXPECT_NEAR(final_box.Size().x(), card.x(), 1.0f);
        // The final card is cut from what the chain drew: its texture coordinates stay in range.
        const auto uv = MeshTexCoordBounds(effect_layer->FinalMesh());
        EXPECT_GE(uv.min_u, -1.0e-4f);
        EXPECT_LE(uv.max_u, 1.0f + 1.0e-4f);
        EXPECT_GE(uv.min_v, -1.0e-4f);
        EXPECT_LE(uv.max_v, 1.0f + 1.0e-4f);
        EXPECT_NEAR(camera->GetPosition().x(), layout->centre.x(), 1.0e-3);
        EXPECT_NEAR(MeshCenter(*node->Mesh()).x(), layout->centre.x(), 1.0e-3f);
    };
    expect_card_at(-1.0f);

    auto graph = sceneToRenderGraph(*fixture.scene);
    ASSERT_NE(graph, nullptr);
    runtime.ConsumeSceneGraphMutationFlag();
    ASSERT_TRUE(runtime.SetNodeTextStyle("caption", "horizontalalign", "left"));
    PumpTextUntilClean(runtime);
    expect_card_at(1.0f);
    EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(100.0f, 50.0f, 0.0f)));
    EXPECT_TRUE(runtime.NodeSize("caption").isApprox(card));
    EXPECT_FALSE(runtime.ConsumeSceneGraphMutationFlag())
        << "moving a card that kept its size rebuilt the graph";
}

// A text layer has no `alignment`: a script that sets one on it changes nothing, where an
// image layer is moved onto the edge it names.
TEST(TextObjectRuntime, ScriptsCannotSetAnAlignmentOnATextLayer) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"caption","text":"aligned","font":"Arial","pointsize":20,
       "origin":[100,50,0],"horizontalalign":"center","verticalalign":"center","visible":true}
    ])", "text-no-alignment-property");
    ASSERT_NE(fixture.scene, nullptr);
    auto& runtime = *fixture.scene->runtime;
    auto* node    = FindRootChild(*fixture.scene, "caption");
    ASSERT_NE(node, nullptr);
    const auto before = MeshLocalBounds(*node->Mesh());
    EXPECT_FALSE(runtime.SetNodeAlignment("caption", "right bottom"));
    runtime.Tick(1.0 / 60.0);
    EXPECT_TRUE(node->Translate().isApprox(Eigen::Vector3f(100.0f, 50.0f, 0.0f)));
    EXPECT_TRUE(runtime.NodeTranslate("caption").isApprox(Eigen::Vector3f(100.0f, 50.0f, 0.0f)));
    const auto after = MeshLocalBounds(*node->Mesh());
    EXPECT_FLOAT_EQ(after.min_x, before.min_x);
    EXPECT_FLOAT_EQ(after.max_y, before.max_y);
}

// The boxes a text is drawn in where no font opens are placed by the same rule as a face's
// glyphs: the same reference line, the same row offsets.
TEST(TextObjectRuntime, TheBoxesOfTheFallbackAreSetByTheRuleTheGlyphsAre) {
    for (const std::string_view horizontal : { "left", "center", "right" }) {
        for (const std::string_view vertical : { "top", "center", "bottom" }) {
            SCOPED_TRACE(std::string(horizontal) + " " + std::string(vertical));
            TextLayerState state {
                .text             = "ab\ncdef\ng",
                .point_size       = 20.0f,
                .spacing          = { 0.0f, 3.0f },
                .horizontal_align = std::string(horizontal),
                .vertical_align   = std::string(vertical),
            };
            const auto layout = TextLayerBoxLayoutForTests(state);
            ASSERT_EQ(layout.rows, 3u);
            const auto size = layout.card + Eigen::Vector2f::Constant(2.0f * TextStyleMargin(state));
            Rastered   image;
            image.width  = static_cast<uint32_t>(std::ceil(size.x()));
            image.height = static_cast<uint32_t>(std::ceil(size.y()));
            image.rgba.assign(static_cast<std::size_t>(image.width) * image.height * 4u, 0u);
            RasterizeTextLayerBoxesForTests(state, image.width, image.height, image.rgba);
            const auto runs = InkRowRuns(image);
            ASSERT_EQ(runs.size(), 3u);
            const float reference = ReferenceLineOf(
                vertical, FaceNumbers { layout.ascender, layout.descender, layout.pitch }, 3u);
            const auto bounds = TextLayerRenderBoundsForLayout(state, layout);
            const float texel_height = (bounds.top - bounds.bottom) / static_cast<float>(image.height);
            const float texel_width  = (bounds.right - bounds.left) / static_cast<float>(image.width);
            for (std::size_t row = 0; row < runs.size(); ++row) {
                const float baseline =
                    bounds.top - texel_height * static_cast<float>(runs[row].second + 1);
                EXPECT_NEAR(baseline, -reference - static_cast<float>(row) * layout.pitch, 1.5f)
                    << "row " << row;
            }
            // Rows of 2, 4 and 1 boxes of one width: each is set within the widest.
            const float box_advance = 0.6f * 20.0f * 300.0f / 72.0f;
            const float widest      = 3.0f * box_advance + 0.45f * 20.0f * 300.0f / 72.0f;
            std::vector<float> starts;
            for (const auto& run : runs) {
                const auto box = InkBounds(image.rgba, image.width, image.height,
                                           static_cast<uint32_t>(run.first),
                                           static_cast<uint32_t>(run.second) + 1u);
                ASSERT_TRUE(box.Any());
                starts.push_back(bounds.left + texel_width * static_cast<float>(box.min_x));
            }
            const float own_widths[] = { box_advance + 0.45f * 20.0f * 300.0f / 72.0f, widest,
                                         0.45f * 20.0f * 300.0f / 72.0f };
            for (std::size_t row = 0; row < runs.size(); ++row) {
                const float offset = horizontal == "left"    ? 0.0f
                                     : horizontal == "center" ? (widest - own_widths[row]) * 0.5f
                                                              : widest - own_widths[row];
                EXPECT_NEAR(starts[row] - starts[1], offset, 2.0f) << "row " << row;
            }
        }
    }
}


// The screen `anchor` shifts where a text layer is drawn, in the scene's own axes, and
// nothing that hangs from the layer: not its children, not what a script reads as its
// origin.

TEST(TextObjectRuntime, ScreenAnchorDoesNotMoveTheChildrenOfTheLayer) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"parent","text":"parent","font":"Arial","pointsize":20,"origin":[600,340,0],
       "anchor":"topright","horizontalalign":"right","verticalalign":"top","visible":true},
      {"id":2,"name":"child","parent":1,"text":"child","font":"Arial","pointsize":20,
       "origin":[0,-30,0],"horizontalalign":"right","verticalalign":"top","visible":true}
    ])", "text-anchor-children");
    ASSERT_NE(fixture.scene, nullptr);
    auto& runtime = *fixture.scene->runtime;
    auto* parent  = FindRootChild(*fixture.scene, "parent");
    ASSERT_NE(parent, nullptr);
    ASSERT_EQ(parent->GetChildren().size(), 1u);
    auto*      child   = parent->GetChildren().front().get();
    const auto parent_at = ModelOrigin(*parent);
    const auto child_at  = ModelOrigin(*child);
    EXPECT_TRUE(DrawnOrigin(*parent).isApprox(parent_at));

    runtime.SetCursorViewport(PannedViewport());
    // The parent is drawn 70 columns to the left, by the right edge of what is shown ...
    EXPECT_TRUE(DrawnOrigin(*parent).isApprox(parent_at + Eigen::Vector3d(-70.0, 0.0, 0.0)));
    // ... and what hangs from it is placed from where the parent is, not from where it is drawn.
    EXPECT_TRUE(ModelOrigin(*parent).isApprox(parent_at));
    EXPECT_TRUE(ModelOrigin(*child).isApprox(child_at));
    // The child is not anchored to anything itself, so it is drawn where it is.
    EXPECT_TRUE(DrawnOrigin(*child).isApprox(child_at));
}

TEST(TextObjectRuntime, ScreenAnchorIsAWorldTranslationWhateverTheLayerScaleAndTurn) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"plain","text":"a","font":"Arial","origin":[320,180,0],
       "anchor":"left","horizontalalign":"center","verticalalign":"center","visible":true},
      {"id":2,"name":"turned","text":"a","font":"Arial","origin":[320,180,0],"scale":[3,0.5,1],
       "angles":[0,0,40],"anchor":"left","horizontalalign":"right","verticalalign":"bottom",
       "visible":true}
    ])", "text-anchor-world");
    ASSERT_NE(fixture.scene, nullptr);
    auto& runtime = *fixture.scene->runtime;
    auto* plain   = FindRootChild(*fixture.scene, "plain");
    auto* turned  = FindRootChild(*fixture.scene, "turned");
    ASSERT_NE(plain, nullptr);
    ASSERT_NE(turned, nullptr);
    ASSERT_GT(turned->Rotation().z(), 0.1f);

    runtime.SetCursorViewport(PannedViewport());
    // 10 columns to the right in the scene, whatever scale and turn the layer has.
    for (auto* node : { plain, turned }) {
        EXPECT_TRUE(DrawnOrigin(*node).isApprox(ModelOrigin(*node) + Eigen::Vector3d(10.0, 0.0, 0.0)))
            << node->Name();
        EXPECT_TRUE(node->DrawOffset().isApprox(Eigen::Vector3f(10.0f, 0.0f, 0.0f))) << node->Name();
    }
    // The matrix that places the node, and so the layer's own axes, is untouched.
    EXPECT_TRUE(turned->Translate().isApprox(Eigen::Vector3f(320.0f, 180.0f, 0.0f)));
    EXPECT_TRUE(turned->Scale().isApprox(Eigen::Vector3f(3.0f, 0.5f, 1.0f)));
    // And the draw matrix keeps the layer's own scale and turn.
    turned->UpdateTrans();
    const Eigen::Matrix3d drawn_axes = turned->RenderTrans().block<3, 3>(0, 0);
    const Eigen::Matrix3d model_axes = turned->ModelTrans().block<3, 3>(0, 0);
    EXPECT_TRUE(drawn_axes.isApprox(model_axes));

    runtime.SetCursorViewport(WholeCanvas());
    for (auto* node : { plain, turned }) {
        EXPECT_TRUE(node->DrawOffset().isZero()) << node->Name();
        EXPECT_TRUE(DrawnOrigin(*node).isApprox(ModelOrigin(*node))) << node->Name();
    }
}

// A script that reads `origin` and writes it back must not walk the layer: the offset is
// not in the value it reads.
TEST(TextObjectRuntime, AScreenAnchoredLayersOriginReadsBackAsTheSceneGaveIt) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"caption","text":"a","font":"Arial","origin":[600,340,0],
       "anchor":"topright","horizontalalign":"right","verticalalign":"top","visible":true}
    ])", "text-anchor-origin");
    ASSERT_NE(fixture.scene, nullptr);
    auto& runtime = *fixture.scene->runtime;
    auto* node    = FindRootChild(*fixture.scene, "caption");
    ASSERT_NE(node, nullptr);
    runtime.SetCursorViewport(PannedViewport());
    const Eigen::Vector3f origin(600.0f, 340.0f, 0.0f);
    EXPECT_TRUE(runtime.NodeTranslate("caption").isApprox(origin));
    EXPECT_TRUE(node->Translate().isApprox(origin));

    // origin.x += 5, twice.
    for (int step = 0; step < 2; ++step) {
        auto value = runtime.NodeTranslate("caption");
        value.x() += 5.0f;
        ASSERT_TRUE(runtime.SetNodeTranslate("caption", value));
    }
    EXPECT_TRUE(runtime.NodeTranslate("caption").isApprox(Eigen::Vector3f(610.0f, 340.0f, 0.0f)));
    EXPECT_TRUE(DrawnOrigin(*node).isApprox(Eigen::Vector3d(610.0 - 70.0, 340.0, 0.0)));
}

// The card another pass of the layer draws, the final card of an effect chain, is drawn
// where the anchor puts the layer, as a plain card is.
TEST(TextObjectRuntime, ScreenAnchorMovesTheFinalCardOfALayerWithAnEffectChain) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"caption","text":"a","font":"Arial","pointsize":20,"origin":[600,340,0],
       "anchor":"topright","horizontalalign":"right","verticalalign":"top","colorBlendMode":12,
       "visible":true}
    ])", "text-anchor-effect", ColorBlendAssets());
    ASSERT_NE(fixture.scene, nullptr);
    auto& runtime = *fixture.scene->runtime;
    auto* node    = FindRootChild(*fixture.scene, "caption");
    ASSERT_NE(node, nullptr);
    ASSERT_FALSE(node->Camera().empty());
    const auto effect_layer = fixture.scene->cameras.at(node->Camera())->GetImgEffect();
    ASSERT_NE(effect_layer, nullptr);

    runtime.Tick(1.0 / 60.0);
    const Eigen::Vector3d resting = DrawnOrigin(effect_layer->FinalNode());
    EXPECT_TRUE(resting.isApprox(Eigen::Vector3d(600.0, 340.0, 0.0)));
    runtime.SetCursorViewport(PannedViewport());
    runtime.Tick(1.0 / 60.0);
    EXPECT_TRUE(DrawnOrigin(effect_layer->FinalNode()).isApprox(resting + Eigen::Vector3d(-70.0, 0.0, 0.0)));
    // The pass that draws into the chain's own buffer is not moved by it.
    EXPECT_TRUE(DrawnOrigin(*node).isApprox(Eigen::Vector3d::Zero()));
}

TEST(TextObjectRuntime, PenAdvancesAreUnhintedWholePixelsKernedWithTheNextGlyph) {
    const auto path = ResolveSystemFontPath("systemfont_arial");
    if (path.empty()) GTEST_SKIP() << "no Arial on this system";
    FT_Library library = nullptr;
    ASSERT_EQ(FT_Init_FreeType(&library), 0);
    FT_Face face = nullptr;
    ASSERT_EQ(FT_New_Face(library, path.c_str(), 0, &face), 0);
    ASSERT_EQ(FT_Set_Char_Size(face, 0, 32 * 64, 300, 300), 0);
    ASSERT_TRUE(FT_HAS_KERNING(face));
    const FT_UInt capital = FT_Get_Char_Index(face, 'T');
    const FT_UInt lower   = FT_Get_Char_Index(face, 'e');
    FT_Fixed advance = 0;
    ASSERT_EQ(FT_Get_Advance(face, capital, FT_LOAD_NO_HINTING, &advance), 0);
    FT_Vector kern {};
    ASSERT_EQ(FT_Get_Kerning(face, capital, lower, FT_KERNING_UNFITTED, &kern), 0);
    FT_Done_Face(face);
    FT_Done_FreeType(library);
    ASSERT_LT(kern.x, -64 * 5) << "the pair should be kerned by several pixels";
    const float pen = std::floor(static_cast<float>(((advance + 512) >> 10) + kern.x) / 64.0f);

    const auto width_of = [&](const char* text) {
        auto state = HelveticaState(text, 32.0f);
        state.font_key               = "systemfont_arial";
        state.resolved_font_identity = "arial";
        state.resolved_font_path     = path;
        return MeasureTextLayerSize(state).x();
    };
    // "Te": the pen steps by the kerned advance, then the 'e' adds its own ink.
    EXPECT_FLOAT_EQ(width_of("Te"), pen + width_of("e"));
}

// ---------------------------------------------------------------------------
// Font faces: a system font is opened from its file, by the name the system gives
// the face, and kept for the next layout; a second face is opened only for a glyph
// the first lacks. A layout runs for every change of every text layer, so none of
// this may cost a file read each time.
// ---------------------------------------------------------------------------

namespace
{
// A layer's layout and raster, which is two measurements and one rasterisation.
void LayOutAndRaster(const TextLayerState& state) {
    (void)MeasureTextLayerSize(state);
    (void)RasterOf(state);
}

std::string FaceKey(std::string_view family) { return "systemfont_" + std::string(family); }

// A state that draws `text` in the installed face `font` names, as the parser fills it.
TextLayerState StateInFace(const SystemFontFace& font, std::string text, float point_size) {
    auto state               = HelveticaState(std::move(text), point_size);
    state.resolved_font_path = font.path;
    state.resolved_font_face = font.postscript_name;
    return state;
}

uint64_t InkMass(const Rastered& raster) {
    uint64_t mass = 0;
    for (std::size_t at = 3; at < raster.rgba.size(); at += 4u) mass += raster.rgba[at];
    return mass;
}
} // namespace

TEST(TextObjectRuntime, AFallbackFaceIsOpenedOnlyWhenAGlyphIsMissing) {
#ifdef __APPLE__
    ResetTextFontCacheForTests();
    const auto latin = HelveticaState("Monday 08:36, September 15", 24.0f);
    ASSERT_FALSE(latin.resolved_font_path.empty());
    LayOutAndRaster(latin);
    EXPECT_EQ(TextFallbackFaceRequestsForTests(), 0u)
        << "text the font can draw asked for a second face";

    // Helvetica has no Han glyphs: the layout that meets one asks for a face for it,
    // once per layout, however many such glyphs it holds.
    const auto han = HelveticaState("08:36 \xE4\xB8\xAD\xE6\x96\x87\xE5\xAD\x97", 24.0f);
    (void)MeasureTextLayerSize(han);
    EXPECT_EQ(TextFallbackFaceRequestsForTests(), 1u);
    (void)MeasureTextLayerSize(han);
    EXPECT_EQ(TextFallbackFaceRequestsForTests(), 2u);
#endif
}

TEST(TextObjectRuntime, ASystemFontIsOpenedOnceAndNotForEveryLayout) {
#ifdef __APPLE__
    ResetTextFontCacheForTests();
    const auto clock = HelveticaState("08:36", 24.0f);
    for (int tick = 0; tick < 10; ++tick) LayOutAndRaster(clock);
    EXPECT_EQ(TextFontFilesOpenedForTests(), 1u) << "the font file was opened again for a layout";
    EXPECT_EQ(TextFontFacesCachedForTests(), 1u);
    // The face reads from its file; the font is not held in memory as a copy of it.
    EXPECT_TRUE(TextFontFacesAreReadFromFilesForTests());

    // The face for a glyph the font lacks is kept the same way.
    const auto mixed = HelveticaState("08:36 \xE4\xB8\xAD", 24.0f);
    for (int tick = 0; tick < 10; ++tick) LayOutAndRaster(mixed);
    EXPECT_EQ(TextFontFilesOpenedForTests(), 2u);
    EXPECT_EQ(TextFontFacesCachedForTests(), 2u);
#endif
}

TEST(TextObjectRuntime, AFontTheWallpaperShipsIsNotOpenedFromAFile) {
#ifdef __APPLE__
    const auto path = ResolveSystemFontPath("systemfont_Helvetica");
    ASSERT_FALSE(path.empty());
    std::ifstream file(path, std::ios::binary);
    const std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(file)), {});
    ASSERT_FALSE(bytes.empty());

    ResetTextFontCacheForTests();
    auto shipped               = HelveticaState("08:36", 24.0f);
    shipped.resolved_font_kind = "asset";
    shipped.resolved_font_path = "/assets/fonts/shipped.ttf";
    shipped.resolved_font_data = bytes;
    for (int tick = 0; tick < 3; ++tick) LayOutAndRaster(shipped);
    EXPECT_EQ(TextFontFilesOpenedForTests(), 0u);
    EXPECT_EQ(TextFontFacesCachedForTests(), 0u);
#endif
}

TEST(TextObjectRuntime, TheFaceCacheKeepsEightFacesAndDropsTheOneUnusedLongest) {
#ifdef __APPLE__
    std::vector<SystemFontFace> fonts;
    for (const char* family : {"Arial", "Courier New", "Georgia", "Impact", "Tahoma", "Trebuchet MS",
                               "Times New Roman", "Verdana", "Comic Sans MS", "Andale Mono",
                               "Arial Black", "Menlo", "Monaco", "Optima", "Futura"}) {
        const auto font = ResolveSystemFont(FaceKey(family));
        const bool seen = std::ranges::any_of(fonts, [&](const SystemFontFace& other) {
            return other.path == font.path && other.postscript_name == font.postscript_name;
        });
        if (! font.path.empty() && ! seen) fonts.push_back(font);
    }
    if (fonts.size() < 10u) GTEST_SKIP() << "fewer than ten of the fonts macOS ships are installed";

    // A space is in every font, so no layout here asks for a second face.
    const auto lay_out = [&](std::size_t font) {
        LayOutAndRaster(StateInFace(fonts[font], " ", 20.0f));
    };
    ResetTextFontCacheForTests();
    for (std::size_t font = 0; font < 10; ++font) lay_out(font);
    EXPECT_EQ(TextFontFilesOpenedForTests(), 10u);
    EXPECT_EQ(TextFontFacesCachedForTests(), 8u);

    lay_out(9);
    EXPECT_EQ(TextFontFilesOpenedForTests(), 10u) << "the face used last was not kept";
    lay_out(8);
    lay_out(2);
    EXPECT_EQ(TextFontFilesOpenedForTests(), 10u) << "a face among the last eight was dropped";
    lay_out(0);
    EXPECT_EQ(TextFontFilesOpenedForTests(), 11u) << "the face unused longest was kept";
    EXPECT_EQ(TextFontFacesCachedForTests(), 8u);
#endif
}

// FreeType reads a face out of a mapping of its file, which faults when the file is cut
// short under it, so a file that has changed is opened again before it is used.
TEST(TextObjectRuntime, AFontFileThatChangedIsOpenedAgainBeforeItsCachedFaceIsUsed) {
#ifdef __APPLE__
    const auto courier = ResolveSystemFont("Courier New");
    const auto arial   = ResolveSystemFont("Arial");
    if (courier.path.empty() || arial.path.empty() || courier.path == arial.path ||
        std::filesystem::path(courier.path).extension() != std::filesystem::path(arial.path).extension()) {
        GTEST_SKIP() << "no two single-face fonts of one kind to stand for the font and its replacement";
    }
    const auto directory = std::filesystem::temp_directory_path() /
                           ("text-face-refresh-" + std::to_string(::getpid()));
    std::filesystem::create_directories(directory);
    const auto installed = directory / ("installed" + std::filesystem::path(courier.path).extension().string());
    std::filesystem::copy_file(courier.path, installed, std::filesystem::copy_options::overwrite_existing);

    SystemFontFace font { .path = installed.string(), .postscript_name = courier.postscript_name };
    const auto     state = StateInFace(font, "08:36", 24.0f);
    ResetTextFontCacheForTests();
    LayOutAndRaster(state);
    LayOutAndRaster(state);
    EXPECT_EQ(TextFontFilesOpenedForTests(), 1u) << "an untouched file was opened again";

    // The file is replaced in place by another font's bytes, as an installer that
    // truncates and rewrites it does.
    {
        std::ifstream replacement(arial.path, std::ios::binary);
        std::ofstream rewritten(installed, std::ios::binary | std::ios::trunc);
        rewritten << replacement.rdbuf();
    }
    LayOutAndRaster(state);
    EXPECT_EQ(TextFontFilesOpenedForTests(), 2u) << "a cached face outlived the file it was opened from";
    EXPECT_EQ(TextFontFacesCachedForTests(), 1u);

    // A file that is gone leaves nothing cached, and the layout still draws (in Arial).
    std::filesystem::remove(installed);
    LayOutAndRaster(state);
    EXPECT_EQ(TextFontFacesCachedForTests(), 1u) << "the face of a deleted file stayed cached";
    std::filesystem::remove_all(directory);
#endif
}

TEST(TextObjectRuntime, AFaceOfACollectionIsChosenByItsPostScriptName) {
#ifdef __APPLE__
    // Songti.ttc holds four weights of one family, and its first face is not the
    // regular one. The weight shows in how much ink a glyph has.
    const auto songti = ResolveSystemFont(FaceKey("Songti SC"));
    ASSERT_FALSE(songti.path.empty());
    ASSERT_EQ(songti.postscript_name, "STSongti-SC-Regular")
        << "the system does not name the regular weight for the family";

    const auto mass_of = [&](std::string_view face) {
        SystemFontFace font = songti;
        font.postscript_name = std::string(face);
        return InkMass(RasterOf(StateInFace(font, "\xE6\xB0\xB8\xE9\xAB\x98", 40.0f)));
    };
    const auto light   = mass_of("STSongti-SC-Light");
    const auto regular = mass_of("STSongti-SC-Regular");
    const auto bold    = mass_of("STSongti-SC-Bold");
    const auto black   = mass_of("STSongti-SC-Black");
    EXPECT_LT(light, regular);
    EXPECT_LT(regular, bold);
    EXPECT_LT(bold, black);

    // The name the system gave is the regular one, not the file's first face.
    EXPECT_EQ(mass_of(songti.postscript_name), regular);
    EXPECT_NE(mass_of(""), regular);

    // A name the file does not have opens the first face, and is not looked up again.
    ResetTextFontCacheForTests();
    const auto first = mass_of("");
    EXPECT_EQ(mass_of("NoSuchFace-Regular"), first);
    const auto opened = TextFontFilesOpenedForTests();
    for (int tick = 0; tick < 5; ++tick) EXPECT_EQ(mass_of("NoSuchFace-Regular"), first);
    EXPECT_EQ(TextFontFilesOpenedForTests(), opened);
    EXPECT_EQ(TextFontFacesCachedForTests(), 1u);
#endif
}

// The fullwidth comma and the ideographic comma and full stop sit on the baseline in
// the Simplified Chinese cut of PingFang, and centred in the line in the Hong Kong
// cut, which is the first face of PingFang.ttc.
TEST(TextObjectRuntime, HanFallbackUsesTheSimplifiedFace) {
#ifdef __APPLE__
    const auto pingfang = ResolveSystemFont(FaceKey("PingFang SC"));
    if (pingfang.postscript_name != "PingFangSC-Regular") GTEST_SKIP() << "no PingFang SC installed";

    constexpr float kPointSize = 40.0f;
    const float     em         = kPointSize * 300.0f / 72.0f;
    // The baseline is the bottom of an H, which Helvetica has.
    const auto reference = RasterOf(HelveticaState("H", kPointSize));
    const auto h_box     = InkBounds(reference.rgba, reference.width, reference.height);
    ASSERT_TRUE(h_box.Any());
    const float baseline = static_cast<float>(h_box.max_y + 1);

    for (const char* mark : {"\xEF\xBC\x8C", "\xE3\x80\x81", "\xE3\x80\x82"}) {
        SCOPED_TRACE(mark);
        const auto raster = RasterOf(HelveticaState(mark, kPointSize));
        const auto box    = InkBounds(raster.rgba, raster.width, raster.height);
        ASSERT_TRUE(box.Any()) << "no face drew the mark";
        const float centre_above_baseline =
            baseline - (static_cast<float>(box.min_y + box.max_y + 1) * 0.5f);
        EXPECT_NEAR(centre_above_baseline / em, 0.0f, 0.05f);
    }
#endif
}

TEST(TextObjectRuntime, TheFaceTheSystemNamesReachesTheLayerFromTheSceneAndFromAScript) {
#ifdef __APPLE__
    TextSceneFixture fixture(R"([
      {"id":1,"name":"system","text":"a","font":"systemfont_Songti SC","visible":true},
      {"id":2,"name":"family","text":"a","font":"Songti SC","visible":true},
      {"id":3,"name":"asset","text":"a","font":"fonts/asset.ttf","visible":true},
      {"id":4,"name":"scripted","text":"a","font":"systemfont_Helvetica","visible":true}
    ])", "text-font-face", { { "/fonts/asset.ttf", "fake-font-bytes" } });
    ASSERT_NE(fixture.scene, nullptr);
    auto& runtime = *fixture.scene->runtime;

    EXPECT_EQ(fixture.State("system").resolved_font_face, "STSongti-SC-Regular");
    EXPECT_EQ(fixture.State("family").resolved_font_face, "STSongti-SC-Regular");
    EXPECT_EQ(fixture.State("system").resolved_font_path, fixture.State("family").resolved_font_path);
    EXPECT_TRUE(fixture.State("asset").resolved_font_face.empty());
    EXPECT_EQ(fixture.State("scripted").resolved_font_face, "Helvetica");

    // A script that sets `font` is resolved the way the scene file's is.
    ASSERT_TRUE(runtime.SetNodeTextStyle("scripted", "font", "systemfont_Songti SC"));
    EXPECT_EQ(fixture.State("scripted").resolved_font_face, "STSongti-SC-Regular");
    EXPECT_EQ(fixture.State("scripted").resolved_font_path, fixture.State("system").resolved_font_path);
    ASSERT_TRUE(runtime.SetNodeTextStyle("scripted", "font", "systemfont_Helvetica"));
    EXPECT_EQ(fixture.State("scripted").resolved_font_face, "Helvetica");
#endif
}

TEST(TextObjectRuntime, ANewFaceOfTheSameFileLaysTheTextOutAgain) {
    TextLayerState state { .text = "a", .font_key = "systemfont_Songti SC",
                           .resolved_font_kind = "system", .resolved_font_identity = "Songti SC",
                           .resolved_font_path = "/fonts/Songti.ttc",
                           .resolved_font_face = "STSongti-SC-Regular" };
    TextLayer layer(state);
    layer.ClearDirty();
    layer.SetFont(state.font_key, state.resolved_font_kind, state.resolved_font_identity,
                  state.resolved_font_path, state.resolved_font_face, state.resolved_font_data);
    EXPECT_FALSE(layer.dirty()) << "the same font was set again";
    layer.SetFont(state.font_key, state.resolved_font_kind, state.resolved_font_identity,
                  state.resolved_font_path, "STSongti-SC-Black", state.resolved_font_data);
    EXPECT_TRUE(layer.dirty());
    EXPECT_TRUE(layer.layoutPending());
}

TEST(TextObjectRuntime, StyledTextKeepsItsMarginWhenItsTextChanges) {
    TextSceneFixture fixture(R"([
      {"id":1,"name":"caption","text":"Hg","font":"Arial","pointsize":20,"visible":true,
       "outline":true,"outlinethickness":4,"dropshadow":true,"dropshadowoffset":"6 6",
       "origin":[100,100,0],"horizontalalign":"left","verticalalign":"top"}
    ])", "text-style-relayout");
    ASSERT_NE(fixture.scene, nullptr);
    auto& runtime = *fixture.scene->runtime;
    const float margin = TextStyleMargin(fixture.State("caption"));
    ASSERT_GT(margin, 6.0f);

    ASSERT_TRUE(runtime.SetNodeText("caption", "Hello, world"));
    PumpTextUntilClean(runtime);
    auto* node = FindRootChild(*fixture.scene, "caption");
    ASSERT_NE(node, nullptr);
    auto* material = node->Mesh()->MaterialForSlot(0);
    ASSERT_NE(material, nullptr);
    auto image = fixture.scene->imageParser->Parse(material->textures.front());
    ASSERT_NE(image, nullptr);
    // The layer's size is the text's; the texture and the card hold the margin too.
    const auto layout = runtime.NodeSize("caption");
    EXPECT_NEAR(image->header.width, layout.x() + 2.0f * margin, 1.0f);
    EXPECT_NEAR(image->header.height, layout.y() + 2.0f * margin, 1.0f);
    const auto card = MeshLocalBounds(*node->Mesh());
    EXPECT_NEAR(card.max_x - card.min_x, layout.x() + 2.0f * margin, 0.5f);
    EXPECT_NEAR(card.max_y - card.min_y, layout.y() + 2.0f * margin, 0.5f);
}

} // namespace wallpaper
