// The compatibility backend leaves out a frame that would put back exactly the
// picture already on the surface: no drawable, no submission, no present.
//
// Driven end to end through `SceneWallpaper` -- the real frame clock, draw
// handler, texture cache and swapchain -- on a `CAMetalLayer` that is never
// attached to a window, so no desktop is involved. The renderer counters are
// the evidence: submissions against selected video frames show that every new
// frame still reaches the surface, and the selection and skip counts show the
// playback timeline is the one the unskipped path produces.

#include "Core/RendererCounters.hpp"
#include "Scene/SceneWallpaper.hpp"
#include "Scene/SceneWallpaperSurface.hpp"
#include "VulkanRender/StaticSubgraphCache.hpp"
#include "synthetic_video.hpp"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>

#include <gtest/gtest.h>

#include <array>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

using namespace wallpaper;
using namespace std::chrono_literals;
namespace testing_media = wallpaper::video::testing_media;

namespace
{

using Counters = std::array<uint64_t, OWE_RC_COUNT>;

Counters Delta(const Counters& before, const Counters& after)
{
    Counters delta {};
    for (std::size_t i = 0; i < delta.size(); ++i) delta[i] = after[i] - before[i];
    return delta;
}

/// Counters are read while the render thread runs, so one draw can straddle
/// the edge of a window: counted as executed on one side and as submitted or
/// skipped on the other. Anything more than that one draw is a real mismatch.
void ExpectWithinOneDraw(uint64_t lhs, uint64_t rhs, const char* what)
{
    const uint64_t difference = lhs > rhs ? lhs - rhs : rhs - lhs;
    EXPECT_LE(difference, 1u) << what << ": " << lhs << " vs " << rhs;
}

/// Health and the counters are separate atomics read one after the other while
/// the render thread runs, so a draw can straddle either edge of the window:
/// one draw at the start and one at the end, and no more than that.
void ExpectWithinTwoDraws(uint64_t lhs, uint64_t rhs, const char* what)
{
    const uint64_t difference = lhs > rhs ? lhs - rhs : rhs - lhs;
    EXPECT_LE(difference, 2u) << what << ": " << lhs << " vs " << rhs;
}

void Print(const char* label, const Counters& c)
{
    std::cout << label << " draws_executed=" << c[OWE_RC_DRAWS_EXECUTED]
              << " render_submissions=" << c[OWE_RC_RENDER_SUBMISSIONS]
              << " present_requests=" << c[OWE_RC_PRESENT_REQUESTS]
              << " presents_skipped_unchanged=" << c[OWE_RC_PRESENTS_SKIPPED_UNCHANGED]
              << " render_failures=" << c[OWE_RC_RENDER_FAILURES]
              << " video_frames_selected=" << c[OWE_RC_VIDEO_FRAMES_SELECTED]
              << " video_frames_reused=" << c[OWE_RC_VIDEO_FRAMES_REUSED]
              << " video_frames_skipped=" << c[OWE_RC_VIDEO_FRAMES_SKIPPED] << std::endl;
}

/// Stands in for the host's poster mailbox: one request at a time, taken by
/// the frame that exports it, and asked about without taking it.
struct PosterProbe
{
    std::mutex              mutex;
    std::condition_variable changed;
    bool                    requested { false };
    int                     delivered { 0 };
    std::vector<uint8_t>    pixels;

    void Request()
    {
        std::scoped_lock lock(mutex);
        requested = true;
    }
    bool WaitDelivered(int count)
    {
        std::unique_lock lock(mutex);
        return changed.wait_for(lock, 5s, [&] { return delivered >= count; });
    }
};

void WriteText(const std::filesystem::path& path, const std::string& text)
{
    std::filesystem::create_directories(path.parent_path());
    std::ofstream(path) << text;
}

/// One opaque card drawn through its own shaders, with nothing that varies
/// over time: from its second frame every pass is reusable.
std::filesystem::path WriteStaticScene(const std::filesystem::path& root)
{
    WriteText(root / "project.json",
              R"({"title":"Static card","type":"scene","file":"layout.json",)"
              R"("general":{"properties":{}}})");
    WriteText(root / "models/card.json",
              R"({"width":160,"height":96,"material":"materials/card.json"})");
    WriteText(root / "materials/card.json",
              R"({"passes":[{"shader":"card","blending":"translucent","cullmode":"nocull",)"
              R"("depthtest":"disabled","depthwrite":"disabled"}]})");
    WriteText(root / "shaders/card.vert",
              "uniform mat4 g_ModelViewProjectionMatrix;\n"
              "attribute vec3 a_Position;\n"
              "attribute vec2 a_TexCoord;\n"
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);\n"
              "v_TexCoord = a_TexCoord;\n"
              "}\n");
    WriteText(root / "shaders/card.frag",
              "varying vec2 v_TexCoord;\n"
              "void main() {\n"
              "gl_FragColor = vec4(v_TexCoord, 0.4, 1.0);\n"
              "}\n");
    WriteText(root / "layout.json",
              R"({"camera":{"center":[0,0,0],"eye":[0,0,1],"up":[0,1,0]},)"
              R"("general":{"ambientcolor":[0,0,0],"skylightcolor":[0,0,0],)"
              R"("clearcolor":[0.1,0.2,0.3],"cameraparallax":false,)"
              R"("orthogonalprojection":{"width":384,"height":256}},)"
              R"("objects":[{"id":1,"name":"card","image":"models/card.json",)"
              R"("origin":[192,128,0],"scale":[1,1,1],"angles":[0,0,0],"visible":true}]})");
    return root / "project.json";
}

/// A 30 fps clip as a plain video wallpaper.
std::filesystem::path WriteVideoProject(const std::filesystem::path& root)
{
    std::filesystem::create_directories(root);
    EXPECT_TRUE(testing_media::WriteSyntheticVideo(root / "clip.mp4", 4, "unchanged-present"));
    WriteText(root / "project.json", R"({"title":"Clip","type":"video","file":"clip.mp4"})");
    return root / "project.json";
}

/// One video frame the compatibility backend presented.
struct PresentedFrame
{
    uint64_t generation { 0 };
    double   pts { 0.0 };

    bool operator==(const PresentedFrame&) const = default;
};

std::ostream& operator<<(std::ostream& out, const PresentedFrame& frame)
{
    return out << "{gen " << frame.generation << ", pts " << frame.pts << "}";
}

/// Presented frames with consecutive repeats of one generation collapsed: the
/// sequence of distinct pictures that reached the surface.
std::vector<PresentedFrame> DistinctSequence(const std::vector<PresentedFrame>& presented)
{
    std::vector<PresentedFrame> distinct;
    for (const auto& frame : presented) {
        if (distinct.empty() || distinct.back().generation != frame.generation)
            distinct.push_back(frame);
    }
    return distinct;
}

/// A running wallpaper on a layer no window owns.
class RunningWallpaper {
public:
    RunningWallpaper(const std::filesystem::path& project, const std::filesystem::path& scratch)
    {
        m_layer                 = [CAMetalLayer layer];
        m_layer.device          = MTLCreateSystemDefaultDevice();
        m_layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
        m_layer.contentsScale   = 1.0;
        m_layer.frame           = CGRectMake(0, 0, kWidth, kHeight);
        m_layer.drawableSize    = CGSizeMake(kWidth, kHeight);

        EXPECT_TRUE(m_wallpaper.init());
        m_wallpaper.setPropertyObject(PROPERTY_FIRST_FRAME_CALLBACK,
                                      std::make_shared<FirstFrameCallback>([this] {
                                          std::scoped_lock lock(m_mutex);
                                          m_first_frame = true;
                                          m_changed.notify_all();
                                      }));
        m_wallpaper.initVulkan(MakeSurface());

        std::filesystem::create_directories(scratch / "assets");
        SceneWallpaperConfig config;
        config.source     = project.string();
        config.assets     = (scratch / "assets").string();
        config.cache_path = (scratch / "cache").string();
        config.fps        = 60;
        config.paused     = false;
        m_wallpaper.applyConfig(config);
    }

    ~RunningWallpaper() { m_wallpaper.shutdown(); }

    bool WaitForFirstFrame()
    {
        std::unique_lock lock(m_mutex);
        return m_changed.wait_for(lock, 30s, [&] { return m_first_frame; });
    }

    Counters Read() const
    {
        Counters values {};
        m_wallpaper.counters(values.data(), values.size());
        return values;
    }

    SceneWallpaper& wallpaper() { return m_wallpaper; }
    PosterProbe&    poster() { return *m_poster; }

    std::vector<PresentedFrame> Presented() const
    {
        std::scoped_lock lock(m_presented->mutex);
        return m_presented->frames;
    }

    /// Rebuilds the surface and swapchain at a new size, the way the host
    /// does when the display it covers changes resolution.
    bool Resize(uint16_t width, uint16_t height)
    {
        if (! m_wallpaper.beginSurfaceReconfigure()) return false;
        m_layer.frame        = CGRectMake(0, 0, width, height);
        m_layer.drawableSize = CGSizeMake(width, height);
        return m_wallpaper.finishSurfaceReconfigure(MakeSurface(width, height));
    }

private:
    static constexpr uint16_t kWidth  = 1280;
    static constexpr uint16_t kHeight = 720;

    struct PresentedLog
    {
        mutable std::mutex          mutex;
        std::vector<PresentedFrame> frames;
    };

    RenderInitInfo MakeSurface(uint16_t width = kWidth, uint16_t height = kHeight)
    {
        RenderInitInfo info;
        void*          handle = (__bridge void*)m_layer;
        info.metal_layer      = handle;
        info.width            = width;
        info.height           = height;
        info.render_width     = width;
        info.render_height    = height;
        auto presented        = m_presented;
        info.video_frame_presented = [presented](uint64_t generation, double pts) {
            std::scoped_lock lock(presented->mutex);
            presented->frames.push_back({ generation, pts });
        };
        info.surface_info.instanceExts = {
            VK_KHR_SURFACE_EXTENSION_NAME,
            VK_EXT_METAL_SURFACE_EXTENSION_NAME,
        };
        info.surface_info.createSurfaceOp = [handle](VkInstance instance, VkSurfaceKHR* surface) {
            auto* create = reinterpret_cast<PFN_vkCreateMetalSurfaceEXT>(
                vkGetInstanceProcAddr(instance, "vkCreateMetalSurfaceEXT"));
            if (create == nullptr) return VK_ERROR_EXTENSION_NOT_PRESENT;
            const VkMetalSurfaceCreateInfoEXT create_info {
                .sType  = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
                .pNext  = nullptr,
                .flags  = 0,
                .pLayer = (__bridge CAMetalLayer*)handle,
            };
            return create(instance, &create_info, nullptr, surface);
        };
        auto poster       = m_poster;
        info.wants_poster = [poster] {
            std::scoped_lock lock(poster->mutex);
            const bool wanted = poster->requested;
            poster->requested = false;
            return wanted;
        };
        info.poster_pending = [poster] {
            std::scoped_lock lock(poster->mutex);
            return poster->requested;
        };
        info.poster_ready = [poster](std::span<const uint8_t> pixels, uint32_t, uint32_t, bool) {
            std::scoped_lock lock(poster->mutex);
            poster->pixels.assign(pixels.begin(), pixels.end());
            ++poster->delivered;
            poster->changed.notify_all();
        };
        return info;
    }

    CAMetalLayer*                m_layer { nil };
    std::shared_ptr<PosterProbe> m_poster { std::make_shared<PosterProbe>() };
    std::shared_ptr<PresentedLog> m_presented { std::make_shared<PresentedLog>() };
    SceneWallpaper               m_wallpaper;
    std::mutex                   m_mutex;
    std::condition_variable      m_changed;
    bool                         m_first_frame { false };
};

class UnchangedPresent : public ::testing::Test {
protected:
    void SetUp() override
    {
        if (MTLCreateSystemDefaultDevice() == nil) {
            GTEST_SKIP() << "no Metal device on this machine; no swapchain could be created";
        }
        static int serial = 0;
        root_ = std::filesystem::temp_directory_path() /
                ("owe-unchanged-present-" + std::to_string(::getpid()) + "-" +
                 std::to_string(serial++));
        std::filesystem::remove_all(root_);
        std::filesystem::create_directories(root_);
        RendererCounters::SetEnabled(true);
    }

    void TearDown() override
    {
        vulkan::SetSceneOptimizationEnabled(true);
        RendererCounters::SetEnabled(false);
        std::error_code ignored;
        std::filesystem::remove_all(root_, ignored);
    }

    std::filesystem::path root_;
};

} // namespace

TEST_F(UnchangedPresent, PinnedTargetAccountingReturnsToBaselineWhenScenesClose)
{
    vulkan::SetSceneOptimizationEnabled(true);
    const auto baseline = vulkan::CurrentSceneOptimizationTotals().pinned_bytes;
    const auto project = WriteStaticScene(root_ / "static");
    for (int load = 0; load < 2; ++load) {
        {
            RunningWallpaper running(project, root_ / ("load-" + std::to_string(load)));
            ASSERT_TRUE(running.WaitForFirstFrame());
            EXPECT_GT(vulkan::CurrentSceneOptimizationTotals().pinned_bytes, baseline);
        }
        EXPECT_EQ(vulkan::CurrentSceneOptimizationTotals().pinned_bytes, baseline);
    }
}

TEST_F(UnchangedPresent, APlainVideoPresentsEveryNewFrameAndNothingElse)
{
    ASSERT_FALSE(testing_media::SharedGop().packets.empty())
        << "VideoToolbox H.264 encoding is unavailable, so no synthetic media can be made";
    const auto project = WriteVideoProject(root_ / "video");

    constexpr auto kWindow = 2000ms;
    Counters       baseline {};
    Counters       skipping {};
    for (const bool optimise : { false, true }) {
        vulkan::SetSceneOptimizationEnabled(optimise);
        RunningWallpaper running(project, root_ / (optimise ? "on" : "off"));
        ASSERT_TRUE(running.WaitForFirstFrame()) << "the video never reached the surface";
        std::this_thread::sleep_for(500ms);
        const auto before = running.Read();
        std::this_thread::sleep_for(kWindow);
        (optimise ? skipping : baseline) = Delta(before, running.Read());
    }
    Print("baseline (optimisation off):", baseline);
    Print("unchanged-present skip on:  ", skipping);

    // The baseline draws, submits and presents on every tick.
    EXPECT_EQ(baseline[OWE_RC_PRESENTS_SKIPPED_UNCHANGED], 0u);
    ExpectWithinOneDraw(baseline[OWE_RC_RENDER_SUBMISSIONS], baseline[OWE_RC_DRAWS_EXECUTED],
                        "baseline submissions against draws");
    EXPECT_EQ(baseline[OWE_RC_RENDER_FAILURES], 0u);
    ASSERT_GT(baseline[OWE_RC_VIDEO_FRAMES_REUSED], 0u)
        << "the clock never outran the clip, so this run proves nothing about repeats";

    // With the skip, a tick either presents or is counted as skipped -- never
    // both, never lost -- and repeats are the only ticks skipped.
    EXPECT_GT(skipping[OWE_RC_PRESENTS_SKIPPED_UNCHANGED], 0u);
    ExpectWithinOneDraw(
        skipping[OWE_RC_RENDER_SUBMISSIONS] + skipping[OWE_RC_PRESENTS_SKIPPED_UNCHANGED],
        skipping[OWE_RC_DRAWS_EXECUTED], "every draw either presented or counted as a repeat");
    ExpectWithinOneDraw(skipping[OWE_RC_RENDER_SUBMISSIONS], skipping[OWE_RC_PRESENT_REQUESTS],
                        "submissions against present requests");
    EXPECT_EQ(skipping[OWE_RC_RENDER_FAILURES], 0u);
    EXPECT_LE(skipping[OWE_RC_PRESENTS_SKIPPED_UNCHANGED], skipping[OWE_RC_VIDEO_FRAMES_REUSED] + 1)
        << "a tick that selected a new frame was skipped";
    // Every newly selected frame was presented on the tick that selected it.
    // One either way covers a window edge that splits a draw.
    EXPECT_GE(skipping[OWE_RC_RENDER_SUBMISSIONS] + 1, skipping[OWE_RC_VIDEO_FRAMES_SELECTED]);
    EXPECT_LE(skipping[OWE_RC_RENDER_SUBMISSIONS], skipping[OWE_RC_VIDEO_FRAMES_SELECTED] + 1);

    // The playback timeline is the baseline's: no decoded frame went unshown
    // in either run, and both selected the clip's own rate.
    EXPECT_EQ(baseline[OWE_RC_VIDEO_FRAMES_SKIPPED], 0u);
    EXPECT_EQ(skipping[OWE_RC_VIDEO_FRAMES_SKIPPED], 0u);
    const double seconds = std::chrono::duration<double>(kWindow).count();
    const double baseline_rate =
        static_cast<double>(baseline[OWE_RC_VIDEO_FRAMES_SELECTED]) / seconds;
    const double skipping_rate =
        static_cast<double>(skipping[OWE_RC_VIDEO_FRAMES_SELECTED]) / seconds;
    EXPECT_NEAR(baseline_rate, 30.0, 3.0);
    EXPECT_NEAR(skipping_rate, 30.0, 3.0);
}

// P02 standard for R1/R4: the skip changes how often a picture is presented,
// never which pictures are presented. The distinct generations that reached
// the surface, and their PTS, are the same sequence with the skip on and off.
TEST_F(UnchangedPresent, TheSkipPresentsTheSameVideoFramesInTheSameOrder)
{
    ASSERT_FALSE(testing_media::SharedGop().packets.empty())
        << "VideoToolbox H.264 encoding is unavailable, so no synthetic media can be made";
    const auto project = WriteVideoProject(root_ / "video");

    std::array<std::vector<PresentedFrame>, 2> presented;
    for (const bool optimise : { false, true }) {
        vulkan::SetSceneOptimizationEnabled(optimise);
        RunningWallpaper running(project, root_ / (optimise ? "on" : "off"));
        ASSERT_TRUE(running.WaitForFirstFrame()) << "the video never reached the surface";
        // Well inside the four-second clip, so no loop restarts the timeline.
        std::this_thread::sleep_for(2500ms);
        presented[optimise ? 1 : 0] = running.Presented();
    }
    const auto& baseline = presented[0];
    const auto& skipping = presented[1];
    const auto  baseline_distinct = DistinctSequence(baseline);
    const auto  skipping_distinct = DistinctSequence(skipping);
    std::cout << "presents: baseline=" << baseline.size() << " (" << baseline_distinct.size()
              << " distinct), skip on=" << skipping.size() << " (" << skipping_distinct.size()
              << " distinct)" << std::endl;

    ASSERT_GT(baseline.size(), baseline_distinct.size())
        << "the clock never outran the clip, so the baseline repeated nothing";
    // Only the start may present the first generation twice (observed: the
    // frame after the first is still drawn in full). From then on no
    // generation is presented twice.
    std::size_t repeats_after_start = 0;
    for (std::size_t i = 2; i < skipping.size(); ++i) {
        if (skipping[i].generation == skipping[i - 1].generation) ++repeats_after_start;
    }
    EXPECT_EQ(repeats_after_start, 0u)
        << "with the skip on, a generation already on the surface was presented again";

    // Both runs are compared over the frames both reached; the wall-clock
    // window ends a frame or two apart.
    const std::size_t common = std::min(baseline_distinct.size(), skipping_distinct.size());
    ASSERT_GE(common, 60u) << "too short a run to compare";
    EXPECT_LE(std::max(baseline_distinct.size(), skipping_distinct.size()) - common, 3u);
    const std::vector<PresentedFrame> baseline_prefix(baseline_distinct.begin(),
                                                      baseline_distinct.begin() + common);
    const std::vector<PresentedFrame> skipping_prefix(skipping_distinct.begin(),
                                                      skipping_distinct.begin() + common);
    EXPECT_EQ(baseline_prefix, skipping_prefix)
        << "the skip changed which video frames reached the surface";

    // And that sequence is the clip itself: every frame, in PTS order, none
    // left out -- so equality above is not two runs dropping alike.
    for (std::size_t i = 1; i < common; ++i) {
        EXPECT_EQ(skipping_prefix[i].generation, skipping_prefix[i - 1].generation + 1) << i;
        EXPECT_NEAR(skipping_prefix[i].pts - skipping_prefix[i - 1].pts, 1.0 / 30.0, 1e-3) << i;
    }
}

TEST_F(UnchangedPresent, ARepeatedVideoFramePresentsAgainOnlyWhenSomethingChanges)
{
    ASSERT_FALSE(testing_media::SharedGop().packets.empty())
        << "VideoToolbox H.264 encoding is unavailable, so no synthetic media can be made";
    const auto project = WriteVideoProject(root_ / "video");
    vulkan::SetSceneOptimizationEnabled(true);
    RunningWallpaper running(project, root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame());

    // Speed zero holds the clip on one frame while the clock keeps ticking.
    running.wallpaper().setPropertyFloat(PROPERTY_SPEED, 0.0f);
    std::this_thread::sleep_for(500ms);
    const auto held_start = running.Read();
    std::this_thread::sleep_for(700ms);
    const auto held = running.Read();
    const auto quiet = Delta(held_start, held);
    Print("held frame:", quiet);
    EXPECT_EQ(quiet[OWE_RC_RENDER_SUBMISSIONS], 0u) << "a held frame was submitted again";
    EXPECT_EQ(quiet[OWE_RC_PRESENT_REQUESTS], 0u);
    EXPECT_GE(quiet[OWE_RC_PRESENTS_SKIPPED_UNCHANGED], 10u);
    ExpectWithinOneDraw(quiet[OWE_RC_PRESENTS_SKIPPED_UNCHANGED], quiet[OWE_RC_DRAWS_EXECUTED],
                        "every held tick counted as a repeat");

    // A layout change moves the picture without a new video frame.
    running.wallpaper().setPropertyBool(PROPERTY_HORIZONTAL_FLIP, true);
    std::this_thread::sleep_for(400ms);
    const auto flipped = running.Read();
    EXPECT_EQ(Delta(held, flipped)[OWE_RC_RENDER_SUBMISSIONS], 1u)
        << "a flip must present exactly once and then repeat again";

    // A poster can only be exported from a presented frame, so a pending
    // request is answered by drawing, once.
    running.poster().Request();
    ASSERT_TRUE(running.poster().WaitDelivered(1)) << "a poster requested during a held frame "
                                                      "was never exported";
    std::this_thread::sleep_for(300ms);
    const auto postered = running.Read();
    EXPECT_EQ(Delta(flipped, postered)[OWE_RC_RENDER_SUBMISSIONS], 1u);
    {
        std::scoped_lock lock(running.poster().mutex);
        EXPECT_EQ(running.poster().delivered, 1);
        EXPECT_FALSE(running.poster().pixels.empty());
    }

    // The first frame after a resume presents: something else may have been
    // on the surface while the wallpaper was stopped.
    running.wallpaper().pause();
    std::this_thread::sleep_for(300ms);
    running.wallpaper().play();
    std::this_thread::sleep_for(400ms);
    const auto resumed = running.Read();
    EXPECT_EQ(Delta(postered, resumed)[OWE_RC_RENDER_SUBMISSIONS], 1u);
}

TEST_F(UnchangedPresent, AStaticSceneStopsPresentingOnceEveryPassIsReused)
{
    const auto project = WriteStaticScene(root_ / "scene");

    std::array<std::vector<uint8_t>, 2> pictures;
    for (const bool optimise : { false, true }) {
        vulkan::SetSceneOptimizationEnabled(optimise);
        RunningWallpaper running(project, root_ / (optimise ? "on" : "off"));
        ASSERT_TRUE(running.WaitForFirstFrame()) << "the scene never reached the surface";
        std::this_thread::sleep_for(600ms);
        const auto before        = running.Read();
        const auto health_before = running.wallpaper().surfaceHealth();
        std::this_thread::sleep_for(1000ms);
        const auto after        = running.Read();
        const auto health_after = running.wallpaper().surfaceHealth();
        const auto delta        = Delta(before, after);
        Print(optimise ? "static scene, skip on: " : "static scene, baseline:", delta);
        ASSERT_GT(delta[OWE_RC_DRAWS_EXECUTED], 10u);
        EXPECT_EQ(delta[OWE_RC_RENDER_FAILURES], 0u);

        // The always-on health reading, with counting on here only because the
        // test reads the counters too. A skipped frame is a completed frame
        // that was not presented, so completion tracks the draws that ran
        // while presents may stand still; a liveness check built on presents
        // would call this healthy scene stalled.
        const uint64_t completed = health_after.frames_completed - health_before.frames_completed;
        const uint64_t presented = health_after.frames_presented - health_before.frames_presented;
        ExpectWithinTwoDraws(completed, delta[OWE_RC_DRAWS_EXECUTED],
                             "frames completed against draws executed");
        EXPECT_EQ(health_after.stop_reason, SurfaceStopReason::Running);
        EXPECT_EQ(health_after.failed_frames, 0u);
        if (optimise) {
            EXPECT_EQ(presented, 0u)
                << "frames that repeat the picture complete without presenting";
        } else {
            ExpectWithinTwoDraws(presented, delta[OWE_RC_DRAWS_EXECUTED],
                                 "baseline presents against draws executed");
        }
        if (optimise) {
            EXPECT_EQ(delta[OWE_RC_RENDER_SUBMISSIONS], 0u)
                << "a scene with every pass reused was still submitted";
            ExpectWithinOneDraw(delta[OWE_RC_PRESENTS_SKIPPED_UNCHANGED],
                                delta[OWE_RC_DRAWS_EXECUTED], "every reused tick skipped");
        } else {
            ExpectWithinOneDraw(delta[OWE_RC_RENDER_SUBMISSIONS], delta[OWE_RC_DRAWS_EXECUTED],
                                "baseline submissions against draws");
            EXPECT_EQ(delta[OWE_RC_PRESENTS_SKIPPED_UNCHANGED], 0u);
        }

        // The presented picture, read back through the poster path: with the
        // skip on it is the frame the reused passes produced.
        running.poster().Request();
        ASSERT_TRUE(running.poster().WaitDelivered(1));
        {
            std::scoped_lock lock(running.poster().mutex);
            pictures[optimise ? 1 : 0] = running.poster().pixels;
        }

        if (optimise) {
            // Scaling moves the picture while every pass stays reused.
            running.wallpaper().setPropertyInt32(PROPERTY_SCALINGMODE, 2);
            std::this_thread::sleep_for(400ms);
            const auto rescaled = Delta(after, running.Read());
            // One for the poster, one for the scaling change.
            EXPECT_EQ(rescaled[OWE_RC_RENDER_SUBMISSIONS], 2u);
        }
    }
    ASSERT_FALSE(pictures[0].empty());
    EXPECT_EQ(pictures[0], pictures[1])
        << "the picture presented with the skip on differs from the baseline";
}

// The triggers ARepeatedVideoFramePresentsAgainOnlyWhenSomethingChanges does
// not cover: each changes the presented picture without a new video frame, so
// each must present once -- the held frame, again -- and then repeat again.
TEST_F(UnchangedPresent, OutputChangesOnAHeldVideoFramePresentOnceEach)
{
    ASSERT_FALSE(testing_media::SharedGop().packets.empty())
        << "VideoToolbox H.264 encoding is unavailable, so no synthetic media can be made";
    const auto project = WriteVideoProject(root_ / "video");
    vulkan::SetSceneOptimizationEnabled(true);
    RunningWallpaper running(project, root_ / "run");
    ASSERT_TRUE(running.WaitForFirstFrame());

    running.wallpaper().setPropertyFloat(PROPERTY_SPEED, 0.0f);
    std::this_thread::sleep_for(500ms);

    const auto expect_one_present = [&](const char* what, const auto& change) {
        const auto before       = running.Read();
        const auto presented_at = running.Presented().size();
        change();
        std::this_thread::sleep_for(400ms);
        const auto delta     = Delta(before, running.Read());
        const auto presented = running.Presented();
        EXPECT_EQ(delta[OWE_RC_RENDER_SUBMISSIONS], 1u) << what << " must present exactly once";
        EXPECT_GE(delta[OWE_RC_PRESENTS_SKIPPED_UNCHANGED], 5u)
            << what << ": the held frame did not go back to repeating";
        ASSERT_EQ(presented.size(), presented_at + 1) << what;
        ASSERT_GT(presented_at, 0u);
        EXPECT_EQ(presented.back(), presented[presented_at - 1])
            << what << " presented a different video frame, not the held one";
    };

    // Crop and fill: the user's zoom, and the fill mode.
    expect_one_present("a scaling-factor (crop) change", [&] {
        running.wallpaper().setPropertyFloat(PROPERTY_SCALINGFACTOR, 1.5f);
    });
    expect_one_present("a render-scale change", [&] {
        running.wallpaper().setPropertyFloat(PROPERTY_RENDER_SCALE, 0.5f);
    });
    // 4:3, so fitting and stretching the 16:9 clip differ afterwards.
    expect_one_present("a surface resize", [&] { ASSERT_TRUE(running.Resize(1024, 768)); });
    expect_one_present("a fill-mode change", [&] {
        running.wallpaper().setPropertyInt32(PROPERTY_FILLMODE,
                                             static_cast<int32_t>(FillMode::STRETCH));
    });
}
