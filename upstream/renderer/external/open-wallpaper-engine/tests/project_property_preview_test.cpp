// A running scene can be handed a whole property document without being loaded
// again. These tests pin what that document means, with no device, window or
// audio output: it is the project's declared defaults with exactly the given
// values over them, whatever the scene happened to load with, and a scene that
// takes it ends up exactly where a fresh load with the same document would.

#include <gtest/gtest.h>

#include <nlohmann/json.hpp>

#include "Audio/SoundManager.h"
#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"
#include "Fs/VFS.h"
#include "Project/ProjectProperties.hpp"
#include "Runtime/DynamicValue.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Runtime/SceneSettingResolver.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scene/include/Scene/SceneMesh.h"
#include "WPSceneParser.hpp"

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace wallpaper
{
namespace
{

// What the project's `project.json` declares.
const ProjectProperties kAuthored {
    { "a", RuntimeScalarValue::Float(1.0f) },
    { "b", RuntimeScalarValue::Float(2.0f) },
    { "c", RuntimeScalarValue::String("x") },
};

ProjectProperties Loaded(const ProjectProperties& saved_choices) {
    return MergeProjectProperties(kAuthored, saved_choices);
}

void ExpectSameTable(const ProjectProperties& actual, const ProjectProperties& expected) {
    EXPECT_EQ(actual.size(), expected.size());
    for (const auto& [name, want] : expected) {
        const auto found = actual.find(name);
        ASSERT_NE(found, actual.end()) << name << " is missing";
        EXPECT_EQ(found->second.kind, want.kind) << name;
        switch (want.kind) {
        case RuntimeScalarValue::Kind::Bool:
            EXPECT_EQ(found->second.bool_value, want.bool_value) << name;
            break;
        case RuntimeScalarValue::Kind::Float:
            EXPECT_EQ(found->second.float_value, want.float_value) << name;
            break;
        case RuntimeScalarValue::Kind::String:
            EXPECT_EQ(found->second.string_value, want.string_value) << name;
            break;
        }
    }
}

std::vector<std::string> Names(std::initializer_list<const char*> names) {
    return { names.begin(), names.end() };
}

// A saved choice -- a preset, or what the user picked last time -- is loaded
// over the project's defaults. A document sent to the running scene afterwards
// is the whole state, so a value it leaves out has to be the project's own
// default again, not the choice the scene happened to be loaded with.
TEST(ProjectPropertyRuntime, ApplyingAnEmptyDocumentReturnsToTheAuthoredDefaultsNotTheLoadedOverrides) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties          = Loaded({ { "a", RuntimeScalarValue::Float(5.0f) } }),
        .authored_project_properties = kAuthored,
    });
    ASSERT_NE(runtime, nullptr);
    EXPECT_EQ(runtime->projectProperties().at("a").float_value, 5.0f);
    ExpectSameTable(runtime->defaultProjectProperties(), kAuthored);
    ASSERT_NE(runtime->FindPropertyValue("a"), nullptr);
    EXPECT_EQ(runtime->FindPropertyValue("a")->getFloat(), 5.0f);

    // `a` is left out: it returns to what the project declares. `b` is set.
    EXPECT_EQ(runtime->ApplyProjectPropertyOverride({ { "b", RuntimeScalarValue::Float(7.0f) } }),
              Names({ "a", "b" }));
    EXPECT_EQ(runtime->projectProperties().at("a").kind, RuntimeScalarValue::Kind::Float);
    EXPECT_EQ(runtime->projectProperties().at("a").float_value, 1.0f);
    EXPECT_EQ(runtime->projectProperties().at("b").float_value, 7.0f);
    EXPECT_EQ(runtime->FindPropertyValue("a")->getFloat(), 1.0f);
    EXPECT_EQ(runtime->FindPropertyValue("b")->getFloat(), 7.0f);

    // Nothing is left of either the saved choice or the document.
    EXPECT_EQ(runtime->ApplyProjectPropertyOverride({}), Names({ "b" }));
    ExpectSameTable(runtime->projectProperties(), kAuthored);
    EXPECT_EQ(runtime->FindPropertyValue("a")->getFloat(), 1.0f);
    EXPECT_EQ(runtime->FindPropertyValue("b")->getFloat(), 2.0f);
    EXPECT_EQ(runtime->FindPropertyValue("c")->getString(), "x");

    // Applying what is already in effect changes nothing.
    EXPECT_TRUE(runtime->ApplyProjectPropertyOverride({}).empty());
    EXPECT_TRUE(runtime->ResetProjectPropertyOverride().empty());

    // And a reset is the same as applying that empty document.
    EXPECT_EQ(runtime->ApplyProjectPropertyOverride({ { "c", RuntimeScalarValue::String("y") },
                                                       { "a", RuntimeScalarValue::Float(3.0f) } }),
              Names({ "a", "c" }));
    EXPECT_EQ(runtime->ResetProjectPropertyOverride(), Names({ "a", "c" }));
    ExpectSameTable(runtime->projectProperties(), kAuthored);
}

// Every caller before this one handed over a single table, and what a scene
// that gets no authored table does is what it always did.
TEST(ProjectPropertyRuntime, ARequestWithoutAnAuthoredTableBehavesAsBefore) {
    const auto loaded = Loaded({ { "a", RuntimeScalarValue::Float(5.0f) } });
    auto       runtime =
        CreateSceneRuntimeContext(SceneRuntimeBootstrap { .project_properties = loaded });
    ASSERT_NE(runtime, nullptr);
    ExpectSameTable(runtime->defaultProjectProperties(), loaded);

    EXPECT_EQ(runtime->ApplyProjectPropertyOverride({ { "b", RuntimeScalarValue::Float(7.0f) } }),
              Names({ "b" }));
    EXPECT_EQ(runtime->projectProperties().at("a").float_value, 5.0f);
    EXPECT_EQ(runtime->ResetProjectPropertyOverride(), Names({ "b" }));
    ExpectSameTable(runtime->projectProperties(), loaded);
}

// A document that changes only the kind of a value still changes it.
TEST(ProjectPropertyRuntime, ADocumentThatOnlyChangesAValuesKindReportsTheChange) {
    auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
        .project_properties = { { "level", RuntimeScalarValue::Float(0.0f) },
                                { "flag", RuntimeScalarValue::Bool(false) } },
    });
    ASSERT_NE(runtime, nullptr);
    EXPECT_EQ(runtime->ApplyProjectPropertyOverride({ { "flag", RuntimeScalarValue::Bool(true) },
                                                       { "level", RuntimeScalarValue::Float(0.0f) } }),
              Names({ "flag" }));
}

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

// One layer per way a property reaches a scene: a flag and a choice decide
// whether a layer shows, a slider and a colour decide how it is drawn, and a
// text decides what a text layer says.
constexpr std::string_view kStillLayers = R"([
  {"id":1,"name":"gate","image":"image.json","visible":{"user":"show","value":true}},
  {"id":2,"name":"pick","image":"image.json",
   "visible":{"user":{"name":"style","condition":"1"},"value":true}},
  {"id":3,"name":"fader","image":"image.json",
   "alpha":{"user":"opacity","value":1.0},"color":{"user":"tint","value":"1 1 1"}}
])";
constexpr std::string_view kTextLayer = R"({"id":4,"name":"caption",
  "text":{"user":"words","value":"authored"},"font":"Arial","pointsize":10,
  "origin":[32,16,0],"visible":true})";

// What the project declares for those layers.
const ProjectProperties kLayerAuthored {
    { "show", RuntimeScalarValue::Bool(true) },
    { "style", RuntimeScalarValue::String("0") },
    { "opacity", RuntimeScalarValue::Float(1.0f) },
    { "tint", RuntimeScalarValue::String("1 1 1") },
    { "words", RuntimeScalarValue::String("authored") },
};

// What a user's saved choices make of them, which is not what the project says.
const ProjectProperties kLayerSaved {
    { "show", RuntimeScalarValue::Bool(false) },
    { "style", RuntimeScalarValue::String("1") },
    { "opacity", RuntimeScalarValue::Float(0.25f) },
    { "tint", RuntimeScalarValue::String("0.2 0.4 0.6") },
    { "words", RuntimeScalarValue::String("loaded") },
};

// Neither of those, for every property that can be anything.
const ProjectProperties kLayerDocument {
    { "show", RuntimeScalarValue::Bool(false) },
    { "style", RuntimeScalarValue::String("1") },
    { "opacity", RuntimeScalarValue::Float(0.5f) },
    { "tint", RuntimeScalarValue::String("0.9 0.8 0.7") },
    { "words", RuntimeScalarValue::String("a longer preview") },
};

struct LoadedScene {
    fs::VFS             vfs;
    audio::SoundManager sound { audio::SoundManager::OutputBackend::Null };
    WPSceneParser       parser;
    std::shared_ptr<Scene> scene;

    SceneRuntimeContext& runtime() { return *scene->runtime; }
};

// Loads the scene as the engine does: the values it loads with, and the
// project's own beside them when those carry saved choices.
std::unique_ptr<LoadedScene> Load(std::string_view objects, const ProjectProperties& loaded,
                                  const ProjectProperties* authored) {
    auto loaded_scene = std::make_unique<LoadedScene>();
    const std::map<std::string, std::string> files {
        { "/image.json", R"({"width":64,"height":32,"material":"mat.json"})" },
        { "/mat.json",
          R"({"passes":[{"blending":"translucent","cullmode":"nocull","depthtest":"disabled","depthwrite":"disabled","shader":"genericimage","textures":["solid"]}]})" },
        { "/shaders/genericimage.vert", std::string(kVert) },
        { "/shaders/genericimage.frag", std::string(kFrag) },
        { "/materials/solid.tex", "" },
    };
    if (! loaded_scene->vfs.Mount("/assets", std::make_unique<MemoryFs>(files))) return nullptr;
    loaded_scene->scene = loaded_scene->parser.Parse(
        SceneParseRequest {
            .scene_id                    = "property-preview",
            .project_properties          = &loaded,
            .authored_project_properties = authored,
        },
        SceneJson(objects),
        loaded_scene->vfs,
        loaded_scene->sound);
    if (loaded_scene->scene == nullptr || loaded_scene->scene->runtime == nullptr) return nullptr;
    return loaded_scene;
}

SceneNode* FindNode(SceneNode& node, std::string_view name) {
    if (node.Name() == name) return &node;
    for (const auto& child : node.GetChildren()) {
        if (child == nullptr) continue;
        if (auto* found = FindNode(*child, name)) return found;
    }
    return nullptr;
}

struct LayerState {
    bool                                     visible { false };
    std::map<std::string, std::vector<float>> constants;

    bool operator==(const LayerState&) const = default;
};

struct SceneState {
    std::map<std::string, LayerState> layers;
    std::string                       text;

    bool operator==(const SceneState&) const = default;
};

// Everything the properties decide about the scene, after the tick that applies
// them: whether each layer shows, every constant its material holds, the text.
SceneState Capture(LoadedScene& loaded, bool with_text) {
    SceneState state;
    for (const char* name : { "gate", "pick", "fader" }) {
        auto* node = FindNode(*loaded.scene->sceneGraph, name);
        EXPECT_NE(node, nullptr) << name;
        if (node == nullptr) continue;
        LayerState layer;
        layer.visible = loaded.runtime().NodeVisible(name);
        if (auto* mesh = node->Mesh(); mesh != nullptr && mesh->Material() != nullptr) {
            for (const auto& [constant, value] : mesh->Material()->customShader.constValues) {
                auto& floats = layer.constants[constant];
                for (std::size_t index = 0; index < value.size(); ++index) {
                    floats.push_back(value[index]);
                }
            }
        }
        state.layers.emplace(name, std::move(layer));
    }
    if (with_text) state.text = loaded.runtime().NodeText("caption");
    return state;
}

std::string Objects(bool with_text) {
    if (! with_text) return std::string(kStillLayers);
    std::string objects(kStillLayers);
    objects.insert(objects.rfind(']'), "," + std::string(kTextLayer));
    return objects;
}

void ExpectSameState(const SceneState& actual, const SceneState& expected, const char* what) {
    EXPECT_EQ(actual.text, expected.text) << what;
    ASSERT_EQ(actual.layers.size(), expected.layers.size()) << what;
    for (const auto& [name, want] : expected.layers) {
        const auto found = actual.layers.find(name);
        ASSERT_NE(found, actual.layers.end()) << what << ": " << name;
        EXPECT_EQ(found->second.visible, want.visible) << what << ": " << name << " visibility";
        EXPECT_EQ(found->second.constants, want.constants) << what << ": " << name << " constants";
    }
}

// The saved choices differ from the project's defaults in every kind, so a scene
// that kept any of them when it was told to return would show.
TEST(ProjectPropertyRoundTrip, EachKindReturnsToTheAuthoredValueExactly) {
    for (const bool with_text : { false, true }) {
        SCOPED_TRACE(with_text ? "with a text layer" : "images only");

        const auto fresh_authored = Load(Objects(with_text), kLayerAuthored, nullptr);
        ASSERT_NE(fresh_authored, nullptr);
        fresh_authored->runtime().Tick(1.0 / 60.0);
        const auto authored = Capture(*fresh_authored, with_text);

        const auto loaded_values = MergeProjectProperties(kLayerAuthored, kLayerSaved);
        const auto fresh_saved = Load(Objects(with_text), loaded_values, &kLayerAuthored);
        ASSERT_NE(fresh_saved, nullptr);
        fresh_saved->runtime().Tick(1.0 / 60.0);
        const auto saved = Capture(*fresh_saved, with_text);

        // The fixture tells the two apart on every layer it has, so a return
        // that stopped short of any one of them could not pass unnoticed.
        EXPECT_NE(authored.layers.at("gate").visible, saved.layers.at("gate").visible);
        EXPECT_NE(authored.layers.at("pick").visible, saved.layers.at("pick").visible);
        EXPECT_NE(authored.layers.at("fader").constants, saved.layers.at("fader").constants);
        if (with_text) EXPECT_NE(authored.text, saved.text);

        // Load with the saved choices, take a document, then return.
        fresh_saved->runtime().ApplyProjectPropertyOverride(kLayerDocument);
        fresh_saved->runtime().Tick(1.0 / 60.0);
        const auto previewing = Capture(*fresh_saved, with_text);
        EXPECT_NE(previewing.layers.at("fader").constants, saved.layers.at("fader").constants);
        if (with_text) EXPECT_EQ(previewing.text, "a longer preview");

        fresh_saved->runtime().ApplyProjectPropertyOverride({});
        fresh_saved->runtime().Tick(1.0 / 60.0);
        ExpectSameState(Capture(*fresh_saved, with_text), authored,
                        "after applying the empty document");

        // The same, for a reset.
        fresh_saved->runtime().ApplyProjectPropertyOverride(kLayerDocument);
        fresh_saved->runtime().Tick(1.0 / 60.0);
        fresh_saved->runtime().ResetProjectPropertyOverride();
        fresh_saved->runtime().Tick(1.0 / 60.0);
        ExpectSameState(Capture(*fresh_saved, with_text), authored, "after a reset");
    }
}

// Showing a document on a running scene and loading the scene with it are the
// same thing to everything these properties reach.
TEST(ProjectPropertyRoundTrip, ApplyingADocumentEqualsLoadingWithIt) {
    for (const bool with_text : { false, true }) {
        SCOPED_TRACE(with_text ? "with a text layer" : "images only");
        const auto loaded_values = MergeProjectProperties(kLayerAuthored, kLayerSaved);
        const auto hot           = Load(Objects(with_text), loaded_values, &kLayerAuthored);
        ASSERT_NE(hot, nullptr);
        hot->runtime().Tick(1.0 / 60.0);
        hot->runtime().ApplyProjectPropertyOverride(kLayerDocument);
        hot->runtime().Tick(1.0 / 60.0);

        const auto fresh = Load(Objects(with_text),
                                MergeProjectProperties(kLayerAuthored, kLayerDocument),
                                &kLayerAuthored);
        ASSERT_NE(fresh, nullptr);
        fresh->runtime().Tick(1.0 / 60.0);
        ExpectSameState(Capture(*hot, with_text), Capture(*fresh, with_text),
                        "hot against a fresh load");

        // A document that mentions a subset is the defaults plus that subset.
        const ProjectProperties subset { { "opacity", RuntimeScalarValue::Float(0.75f) } };
        hot->runtime().ApplyProjectPropertyOverride(subset);
        hot->runtime().Tick(1.0 / 60.0);
        const auto fresh_subset =
            Load(Objects(with_text), MergeProjectProperties(kLayerAuthored, subset),
                 &kLayerAuthored);
        ASSERT_NE(fresh_subset, nullptr);
        fresh_subset->runtime().Tick(1.0 / 60.0);
        ExpectSameState(Capture(*hot, with_text), Capture(*fresh_subset, with_text),
                        "a subset against a fresh load");
    }
}

// A shader constant a property drives is read from the property each frame, so
// it follows a document and returns with it like any other binding.
TEST(ProjectPropertyRoundTrip, AMaterialConstantReturnsToItsAuthoredValue) {
    const ProjectProperties authored {
        { "amount", RuntimeScalarValue::Float(0.5f) },
        { "tint", RuntimeScalarValue::String("1 1 1") },
    };
    const auto make = [&](const ProjectProperties& loaded, const ProjectProperties* declared,
                          std::shared_ptr<SceneMaterial>& material) {
        auto runtime = CreateSceneRuntimeContext(SceneRuntimeBootstrap {
            .project_properties          = loaded,
            .authored_project_properties = declared != nullptr
                                               ? std::optional<ProjectProperties>(*declared)
                                               : std::nullopt,
        });
        material = std::make_shared<SceneMaterial>();
        runtime->RegisterMaterialConstant(
            material, "g_Amount",
            ResolveFloatSetting(*runtime, { { "user", "amount" }, { "value", 0.5f } }));
        runtime->RegisterMaterialConstant(
            material, "g_Tint",
            ResolveVec3Setting(*runtime, { { "user", "tint" }, { "value", { 1.0f, 1.0f, 1.0f } } }));
        runtime->Tick(1.0 / 60.0);
        return runtime;
    };
    const auto constants = [](const std::shared_ptr<SceneMaterial>& material) {
        std::map<std::string, std::vector<float>> values;
        for (const auto& [name, value] : material->customShader.constValues) {
            for (std::size_t index = 0; index < value.size(); ++index) {
                values[name].push_back(value[index]);
            }
        }
        return values;
    };

    std::shared_ptr<SceneMaterial> fresh_material;
    auto                           fresh = make(authored, nullptr, fresh_material);
    const auto                     authored_constants = constants(fresh_material);
    ASSERT_EQ(authored_constants.at("g_Amount"), std::vector<float>({ 0.5f }));

    const auto saved = MergeProjectProperties(
        authored, { { "amount", RuntimeScalarValue::Float(3.0f) },
                    { "tint", RuntimeScalarValue::String("0.2 0.4 0.6") } });
    std::shared_ptr<SceneMaterial> material;
    auto                           runtime = make(saved, &authored, material);
    EXPECT_EQ(constants(material).at("g_Amount"), std::vector<float>({ 3.0f }));

    runtime->ApplyProjectPropertyOverride({ { "amount", RuntimeScalarValue::Float(0.75f) } });
    runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(constants(material).at("g_Amount"), std::vector<float>({ 0.75f }));
    // The colour is left out, so it is the project's and not the saved one.
    EXPECT_EQ(constants(material).at("g_Tint"), authored_constants.at("g_Tint"));

    runtime->ApplyProjectPropertyOverride({});
    runtime->Tick(1.0 / 60.0);
    EXPECT_EQ(constants(material), authored_constants);
}

// Taking a document must not make a still scene tick: the renderer stops
// drawing a scene that has nothing moving by itself, and a property that
// arrives wakes it for exactly the frame it changes.
TEST(ProjectPropertyRuntime, ApplyingPropertiesAddsNoTimeAdvancingWork) {
    const auto loaded_values = MergeProjectProperties(kLayerAuthored, kLayerSaved);
    const auto loaded        = Load(Objects(false), loaded_values, &kLayerAuthored);
    ASSERT_NE(loaded, nullptr);
    loaded->runtime().Tick(1.0 / 60.0);
    const auto before = loaded->runtime().DescribeTimeAdvancingWork();
    EXPECT_EQ(before, 0u) << "the fixture is a still scene";

    loaded->runtime().ApplyProjectPropertyOverride(kLayerDocument);
    loaded->runtime().Tick(1.0 / 60.0);
    EXPECT_EQ(loaded->runtime().DescribeTimeAdvancingWork(), before);

    loaded->runtime().ApplyProjectPropertyOverride({});
    loaded->runtime().Tick(1.0 / 60.0);
    EXPECT_EQ(loaded->runtime().DescribeTimeAdvancingWork(), before);
}

} // namespace
} // namespace wallpaper
