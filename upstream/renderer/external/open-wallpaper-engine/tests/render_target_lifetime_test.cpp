#include "RenderGraph/RenderGraph.hpp"
#include "RenderGraph/Pass.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "SpecTexs.hpp"
#include "VulkanRender/PrePass.hpp"
#include "VulkanRender/CustomShaderPass.hpp"
#include "VulkanRender/SceneToRenderGraph.hpp"
#include "VulkanRender/PassCommon.hpp"
#include <gtest/gtest.h>

namespace wallpaper {
namespace {
struct TestPass : rg::Pass {
    struct Desc {};
    TestPass(const Desc&) {}
};

TEST(RenderTargetLifetime, AlphaCoverageUsesBlendingOnlyWithoutMultisampling) {
    VkPipelineColorBlendAttachmentState state {};
    vulkan::SetBlend(BlendMode::AlphaToCoverage, state, VK_SAMPLE_COUNT_1_BIT);
    EXPECT_TRUE(state.blendEnable);
    EXPECT_EQ(state.srcColorBlendFactor, VK_BLEND_FACTOR_SRC_ALPHA);
    EXPECT_EQ(state.dstColorBlendFactor, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
    EXPECT_EQ(state.srcAlphaBlendFactor, VK_BLEND_FACTOR_ONE);
    EXPECT_EQ(state.dstAlphaBlendFactor, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
    vulkan::SetBlend(BlendMode::AlphaToCoverage, state, VK_SAMPLE_COUNT_4_BIT);
    EXPECT_FALSE(state.blendEnable);
}

TEST(RenderTargetLifetime, ReleasesOnceAfterAllVersionsAndBlendOnlyWrites) {
    rg::RenderGraph graph;
    rg::TexNode* first = nullptr;
    rg::TexNode* second = nullptr;
    rg::TexNode::Desc target { .name = "_rt_ping", .key = "_rt_ping", .type = rg::TexNode::TexType::Temp };
    graph.addPass<TestPass>("first write", rg::PassNode::Type::CustomShader,
        [&](auto& b, auto&) { first = b.createTexNode(target, true); b.write(first); });
    graph.addPass<TestPass>("first read", rg::PassNode::Type::CustomShader,
        [&](auto& b, auto&) { b.read(first); });
    graph.addPass<TestPass>("second write", rg::PassNode::Type::CustomShader,
        [&](auto& b, auto&) { second = b.createTexNode(target, true); b.write(second); });
    graph.addPass<TestPass>("second read", rg::PassNode::Type::CustomShader,
        [&](auto& b, auto&) { b.read(second); });
    auto* last = graph.addPass<TestPass>("blend only", rg::PassNode::Type::CustomShader,
        [&](auto& b, auto&) { b.write(b.createTexNode(target, true)); });
    const auto order = graph.topologicalOrder();
    const auto releases = graph.getLastReadTexs(order);
    int count = 0;
    for (std::size_t i = 0; i < releases.size(); ++i) {
        for (const auto* tex : releases[i]) {
            if (tex->key() != "_rt_ping") continue;
            ++count;
            EXPECT_EQ(order[i], last->ID());
        }
    }
    EXPECT_EQ(count, 1);
}

std::shared_ptr<SceneNode> Node(std::string name, std::vector<std::string> textures = {}) {
    auto node = std::make_shared<SceneNode>();
    node->SetName(name);
    node->ID() = 1;
    auto mesh = std::make_shared<SceneMesh>();
    SceneMaterial mat;
    mat.name = name;
    mat.textures = std::move(textures);
    mesh->AddMaterial(std::move(mat));
    node->AddMesh(mesh);
    return node;
}

TEST(RenderTargetLifetime, NoBackgroundEffectGetsRealTransparentWriterBeforeSampling) {
    Scene scene;
    scene.renderTargets[std::string(SpecTex_Default)] = { .width = 64, .height = 64 };
    const std::string input = std::string(WE_EFFECT_PPONG_PREFIX_A) + "probe";
    scene.renderTargets[input] = { .width = 16, .height = 16, .allowReuse = true };
    auto owner = Node("empty compose");
    owner->SetSkipRenderPass(true);
    owner->SetCamera("local");
    auto camera = std::make_shared<SceneCamera>(16, 16, -1, 1);
    auto layer = std::make_shared<SceneImageEffectLayer>(owner.get(), 16, 16, input, "_rt_ping_b");
    layer->SetFinalBlend(BlendMode::Translucent);
    auto effect = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back({ std::string(SpecTex_Default), Node("scroll", {input}) });
    layer->AddEffect(effect);
    camera->AttatchImgEffect(layer);
    scene.cameras["local"] = camera;
    scene.sceneGraph->AppendChild(owner);
    auto graph = sceneToRenderGraph(scene);
    const auto order = graph->topologicalOrder();
    ASSERT_EQ(order.size(), 2u);
    auto* clear = dynamic_cast<vulkan::PrePass*>(graph->getPass(order[0]));
    ASSERT_NE(clear, nullptr);
    EXPECT_EQ(clear->desc().result, input);
    EXPECT_TRUE(clear->desc().transparent);
    auto* draw = dynamic_cast<vulkan::CustomShaderPass*>(graph->getPass(order[1]));
    ASSERT_NE(draw, nullptr);
    EXPECT_EQ(draw->desc().textures[0], input);
    EXPECT_EQ(graph->getLastReadTexs(order)[1][0]->key(), input);
}

// Motion blur blends each frame into the one before: its accumulation reads a
// history target that nothing this frame has written yet, and a copy stores the
// blend there for the next frame. Pooled, the history's image went to whatever
// target came next, so the next frame blended in that target's pixels -- a
// faint copy of some other layer jumping about. Only such a target keeps its
// own image; the effect's other targets and the scene output stay as they were.
TEST(RenderTargetLifetime, OnlyTargetsReadBeforeTheFrameWritesThemKeepTheirOwnImage) {
    Scene scene;
    scene.renderTargets[std::string(SpecTex_Default)] = { .width = 64, .height = 64 };
    const std::string input   = std::string(WE_EFFECT_PPONG_PREFIX_A) + "trail";
    const std::string output  = std::string(WE_EFFECT_PPONG_PREFIX_B) + "trail";
    const std::string history = "_rt_trail_history";
    const std::string blend   = "_rt_trail_blend";
    for (const auto& name : { input, output, history, blend }) {
        scene.renderTargets[name] = { .width = 16, .height = 16, .allowReuse = true };
    }
    auto owner = Node("trailing layer");
    owner->SetCamera("local");
    auto camera = std::make_shared<SceneCamera>(16, 16, -1, 1);
    auto layer  = std::make_shared<SceneImageEffectLayer>(owner.get(), 16, 16, input, output);
    layer->SetFinalBlend(BlendMode::Translucent);
    auto effect = std::make_shared<SceneImageEffect>();
    effect->nodes.push_back({ blend, Node("accumulate", { input, history }) });
    effect->commands.push_back({ .dst = history, .src = blend, .afterpos = 1 });
    effect->nodes.push_back({ std::string(SpecTex_Default), Node("combine", { blend }) });
    layer->AddEffect(effect);
    camera->AttatchImgEffect(layer);
    scene.cameras["local"]  = camera;
    scene.cameras["effect"] = std::make_shared<SceneCamera>(16, 16, -1, 1);
    scene.sceneGraph->AppendChild(owner);

    const auto graph = sceneToRenderGraph(scene);
    ASSERT_NE(graph, nullptr);

    EXPECT_TRUE(scene.renderTargets.at(history).carriesPreviousFrame);
    EXPECT_FALSE(scene.renderTargets.at(history).allowReuse);
    for (const auto& name : { input, blend }) {
        SCOPED_TRACE(name);
        EXPECT_FALSE(scene.renderTargets.at(name).carriesPreviousFrame);
        EXPECT_TRUE(scene.renderTargets.at(name).allowReuse);
    }
    EXPECT_FALSE(scene.renderTargets.at(std::string(SpecTex_Default)).carriesPreviousFrame);
}

TEST(RenderTargetLifetime, CarriedOverKeysAreTheOnesReadBeforeTheirFirstWrite) {
    for (int seed = 1; seed <= 32; ++seed) {
        SCOPED_TRACE(seed);
        rg::RenderGraph graph;
        std::map<rg::NodeID, std::pair<std::string, std::string>> accesses;
        for (int i = 0; i < 40; ++i) {
            const auto read  = "_rt_" + std::to_string((i * seed + 3) % 9);
            const auto write = "_rt_" + std::to_string((i + seed) % 7);
            auto* pass = graph.addPass<TestPass>("generated", rg::PassNode::Type::CustomShader,
                [&](auto& b, auto&) {
                    b.read(b.createTexNode({.name = read, .key = read, .type = rg::TexNode::TexType::Temp}));
                    b.write(b.createTexNode({.name = write, .key = write, .type = rg::TexNode::TexType::Temp}, true));
                });
            accesses[pass->ID()] = { read, write };
        }
        const auto order = graph.topologicalOrder();
        std::set<std::string> accessed, read_first, written;
        for (const auto id : order) {
            const auto& [read, write] = accesses.at(id);
            if (accessed.insert(read).second) read_first.insert(read);
            accessed.insert(write);
            written.insert(write);
        }
        std::set<std::string> expected;
        for (const auto& key : read_first)
            if (written.contains(key)) expected.insert(key);
        const auto carried = graph.getCarriedOverKeys(order);
        EXPECT_EQ(std::set<std::string>(carried.begin(), carried.end()), expected);
        EXPECT_EQ(carried.size(), expected.size());
    }
}
// Exercise the rule with different names, dimensions, nesting and visibility;
// nothing here depends on a workshop ID, shader name or clock layer.
TEST(RenderTargetLifetime, NestedCompositesClearBeforeChildrenWithoutErasingThem) {
    for (bool copy_background : {false, true}) {
        for (bool visible : {false, true}) {
            for (int dimension : {16, 127, 512}) {
                SCOPED_TRACE(::testing::Message() << copy_background << ',' << visible << ',' << dimension);
                Scene scene;
                scene.renderTargets[std::string(SpecTex_Default)] = { .width = 800, .height = 600 };
                scene.cameras["global"] = std::make_shared<SceneCamera>(800, 600, -1, 1);
                scene.activeCamera = scene.cameras["global"].get();
                auto outer = Node("outer");
                auto inner = Node("inner");
                auto child = Node("child");
                auto sibling = Node("sibling");
                outer->ID() = 101; inner->ID() = 202; child->ID() = 303; sibling->ID() = 404;
                outer->SetVisible(visible);
                outer->AppendChild(inner); inner->AppendChild(child); inner->AppendChild(sibling);
                scene.sceneGraph->AppendChild(outer);
                for (auto owner : {outer, inner}) {
                    const auto name = owner->Name();
                    const auto input = std::string(WE_EFFECT_PPONG_PREFIX_A) + name;
                    const auto ping_b = std::string(WE_EFFECT_PPONG_PREFIX_B) + name;
                    scene.renderTargets[input] = { .width = dimension, .height = dimension + 1, .allowReuse = true };
                    scene.renderTargets[ping_b] = scene.renderTargets[input];
                    // Multisampled, so a draw after the transfer clear visibly
                    // keeps the single-sample path it had while it loaded.
                    scene.renderTargets[input].sample_count = 4;
                    // Test aliases as well as logical versions of the same key.
                    const auto alias = "_alias_" + name;
                    scene.renderTargetAliases[alias] = input;
                    auto layer = std::make_shared<SceneImageEffectLayer>(owner.get(), dimension, dimension + 1, alias, ping_b);
                    layer->SetFinalBlend(BlendMode::Translucent);
                    auto effect = std::make_shared<SceneImageEffect>();
                    effect->nodes.push_back({std::string(SpecTex_Default), Node(name + " result", {input})});
                    layer->AddEffect(effect);
                    auto camera = std::make_shared<SceneCamera>(dimension, dimension + 1, -1, 1);
                    camera->SetComposeLayer(true);
                    camera->AttatchNode(owner);
                    camera->AttatchImgEffect(layer);
                    scene.cameras[name] = camera;
                    owner->SetCamera(name);
                    owner->SetSkipRenderPass(!copy_background);
                }
                auto graph = sceneToRenderGraph(scene);
                const auto order = graph->topologicalOrder();
                std::map<std::string, std::size_t> index;
                int clears = 0;
                for (std::size_t i = 0; i < order.size(); ++i) {
                    if (auto* clear = dynamic_cast<vulkan::PrePass*>(graph->getPass(order[i]))) {
                        ++clears;
                        EXPECT_TRUE(clear->desc().transparent);
                        index[clear->desc().result] = i;
                    }
                    if (auto* draw = dynamic_cast<vulkan::CustomShaderPass*>(graph->getPass(order[i]))) {
                        index[draw->desc().node->Name()] = i;
                        const auto& name = draw->desc().node->Name();
                        // The first draw into a composite cleared to transparent
                        // opens with that clear (same value, so the separate one is
                        // redundant); one over a copied background loads it. Every
                        // draw after the first loads, so nothing drawn is erased.
                        if (name == "child" || name == "inner result") {
                            EXPECT_EQ(draw->desc().clear_on_first_use, ! copy_background) << name;
                            EXPECT_EQ(draw->desc().preserve_target_contents, copy_background) << name;
                        }
                        if (name == "sibling") {
                            EXPECT_FALSE(draw->desc().clear_on_first_use);
                            EXPECT_TRUE(draw->desc().preserve_target_contents);
                        }
                        if (! copy_background &&
                            (name == "child" || name == "sibling" || name == "inner result")) {
                            EXPECT_EQ(draw->desc().sample_count, VK_SAMPLE_COUNT_1_BIT) << name;
                        }
                    }
                }
                EXPECT_EQ(clears, copy_background ? 0 : 2);
                const auto outer_start = copy_background ? "outer" : std::string(WE_EFFECT_PPONG_PREFIX_A) + "outer";
                const auto inner_start = copy_background ? "inner" : std::string(WE_EFFECT_PPONG_PREFIX_A) + "inner";
                ASSERT_TRUE(index.contains(outer_start)); ASSERT_TRUE(index.contains(inner_start));
                // Independent offscreen subtrees may execute in either order.
                // Only a write into the parent's target must follow its clear.
                EXPECT_LT(index[outer_start], index["inner result"]);
                EXPECT_LT(index[inner_start], index["child"]);
                EXPECT_LT(index["child"], index["sibling"]);
                EXPECT_LT(index["sibling"], index["inner result"]);
                EXPECT_LT(index["inner result"], index["outer result"]);
            }
        }
    }
}

TEST(RenderTargetLifetime, ReleasePlanMatchesLastAccessForGeneratedMultiVersionGraphs) {
    for (int seed = 1; seed <= 32; ++seed) {
        SCOPED_TRACE(seed);
        rg::RenderGraph graph;
        std::map<rg::NodeID, std::set<std::string>> accesses;
        for (int i = 0; i < 60; ++i) {
            const auto read = "_rt_" + std::to_string((i * seed + 3) % 7);
            const auto write = "_rt_" + std::to_string((i + seed) % 7);
            auto* pass = graph.addPass<TestPass>("generated", rg::PassNode::Type::CustomShader,
                [&](auto& b, auto&) {
                    b.read(b.createTexNode({.name = read, .key = read, .type = rg::TexNode::TexType::Temp}));
                    b.write(b.createTexNode({.name = write, .key = write, .type = rg::TexNode::TexType::Temp}, true));
                });
            accesses[pass->ID()] = {read, write};
        }
        const auto order = graph.topologicalOrder();
        ASSERT_EQ(order.size(), 60u);
        std::map<std::string, std::size_t> last_access;
        for (std::size_t i = 0; i < order.size(); ++i)
            for (const auto& key : accesses[order[i]]) last_access[key] = i;
        const auto releases = graph.getLastReadTexs(order);
        std::set<std::string> released;
        for (std::size_t i = 0; i < releases.size(); ++i) {
            for (const auto* tex : releases[i]) {
                const std::string key(tex->key());
                EXPECT_TRUE(released.insert(key).second);
                EXPECT_EQ(last_access.at(key), i);
            }
        }
        EXPECT_EQ(released.size(), last_access.size());
    }
}
} // namespace
} // namespace wallpaper
