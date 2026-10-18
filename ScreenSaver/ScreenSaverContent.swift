import AVFoundation
import AppKit
import Metal
import QuartzCore

struct ScreenSaverFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One native scene renderer owned by a screen saver view.
///
/// The saver host loads this bundle into its own process, so the renderer is set up
/// exactly as the in-app preview does it: a CAMetalLayer plus the C surface API. The
/// renderer runs its own thread and keeps drawing until `stop()` tears the swapchain down.
final class ScreenSaverSceneContent {
    private let wallpaper: ScreenSaverWallpaper
    private let cacheURL: URL
    private let metal = CAMetalLayer()
    private var renderer: OpaquePointer?
    private var size: CGSize = .zero
    private var scale: CGFloat = 1
    private var stopped = false

    init(wallpaper: ScreenSaverWallpaper, cacheURL: URL) {
        self.wallpaper = wallpaper
        self.cacheURL = cacheURL
    }

    func attach(to view: NSView, scale: CGFloat) throws {
        guard let host = view.layer else {
            throw ScreenSaverFailure(message: "The screen saver view has no layer.")
        }
        owe_set_scene_renderer_preference(wallpaper.nativeMetalPreferred ? 1 : 0)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ScreenSaverFailure(message: "Metal rendering is unavailable.")
        }
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        let pixelSize = Self.pixelSize(bounds: view.bounds, scale: scale)
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.backgroundColor = NSColor.black.cgColor
        metal.isOpaque = true
        metal.framebufferOnly = true
        metal.frame = view.bounds
        metal.contentsScale = scale
        metal.drawableSize = pixelSize
        host.addSublayer(metal)
        size = pixelSize
        self.scale = scale

        do {
            try check(owe_scene_wallpaper_new(&renderer))
            try check(owe_scene_wallpaper_init(renderer))
            try check(
                owe_scene_wallpaper_init_metal_vulkan(
                    renderer, Unmanaged.passUnretained(metal).toOpaque(),
                    UInt32(pixelSize.width), UInt32(pixelSize.height), 0, 0, Double(scale)))
            installFirstFrameSignal()
            // A screen saver is unattended: no audio, no media session, no input.
            try check(owe_scene_wallpaper_set_audio_muted(renderer, true))
            try check(
                owe_scene_wallpaper_set_property_bool(
                    renderer, owe_property_audio_response_enabled(), false))
            try check(
                owe_scene_wallpaper_apply_config(
                    renderer,
                    wallpaper.projectDirectory.appendingPathComponent("project.json").path,
                    wallpaper.assetsDirectory?.path ?? "",
                    cacheURL.path, wallpaper.fps, false, false,
                    wallpaper.propertiesJSON))
            try check(
                owe_scene_wallpaper_set_property_bool(
                    renderer, owe_property_media_integration_enabled(), false))
            try check(
                owe_scene_wallpaper_set_property_int32(
                    renderer, owe_property_scaling_mode(), 3))
            try check(
                owe_scene_wallpaper_set_property_float(
                    renderer, owe_property_scaling_factor(), 1))
        } catch {
            stop()
            throw error
        }
    }

    func layout(in bounds: NSRect, scale: CGFloat) {
        guard !stopped, let renderer else { return }
        let next = Self.pixelSize(bounds: bounds, scale: scale)
        guard next != size || scale != self.scale else { return }
        do {
            try check(owe_scene_wallpaper_begin_surface_reconfigure(renderer))
            metal.frame = bounds
            metal.contentsScale = scale
            metal.drawableSize = next
            try check(
                owe_scene_wallpaper_finish_surface_reconfigure(
                    renderer, Unmanaged.passUnretained(metal).toOpaque(),
                    UInt32(next.width), UInt32(next.height), 0, 0, Double(scale)))
            size = next
            self.scale = scale
        } catch {
            NSLog("WallpaperMachine screen saver: resize failed: %@", error.localizedDescription)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let renderer {
            // The renderer releases its swapchain before its CAMetalLayer disappears.
            _ = owe_scene_wallpaper_begin_surface_reconfigure(renderer)
            _ = owe_scene_wallpaper_shutdown(renderer)
            _ = owe_scene_wallpaper_delete(renderer)
        }
        renderer = nil
        metal.removeFromSuperlayer()
    }

    private func check(_ result: Int32) throws {
        guard result != 0 else { return }
        let message = owe_last_error().map { String(cString: $0) }
            ?? "Native rendering failed (\(result))."
        throw ScreenSaverFailure(message: message)
    }

    /// Logs once when the renderer presents its first frame, which is the only
    /// signal the saver host leaves in the system log for an unattended run.
    private func installFirstFrameSignal() {
        final class Signal {}
        let box = Unmanaged.passRetained(Signal()).toOpaque()
        let result = owe_scene_wallpaper_set_first_frame_callback(
            renderer,
            { _ in NSLog("WallpaperMachine screen saver: first frame ready") },
            box,
            { pointer in
                if let pointer { Unmanaged<Signal>.fromOpaque(pointer).release() }
            })
        if result != 0 { Unmanaged<Signal>.fromOpaque(box).release() }
    }

    private static func pixelSize(bounds: CGRect, scale: CGFloat) -> CGSize {
        CGSize(
            width: max(1, min(8192, (bounds.width * scale).rounded())),
            height: max(1, min(8192, (bounds.height * scale).rounded())))
    }

}

/// A plain video wallpaper played by AVFoundation inside the saver process.
final class ScreenSaverVideoContent {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    init(wallpaper: ScreenSaverWallpaper) throws {
        let file = wallpaper.projectDirectory.appendingPathComponent(wallpaper.entryFile)
        guard !wallpaper.entryFile.isEmpty,
              FileManager.default.isReadableFile(atPath: file.path)
        else {
            throw ScreenSaverFailure(message: "The video file is missing.")
        }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: file))
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        self.player = player
        player.play()
        NSLog("WallpaperMachine screen saver: playing video %@", file.lastPathComponent)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak player] in
            guard let item = player?.currentItem else { return }
            if item.status == .failed {
                NSLog(
                    "WallpaperMachine screen saver: video failed: %@",
                    item.error?.localizedDescription ?? "unknown")
            } else {
                NSLog("WallpaperMachine screen saver: video status %d", item.status.rawValue)
            }
        }
    }

    func attach(to view: NSView) {
        playerLayer.frame = view.bounds
        view.layer?.addSublayer(playerLayer)
    }

    func layout(in bounds: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func stop() {
        player?.pause()
        playerLayer.player = nil
        playerLayer.removeFromSuperlayer()
        self.player = nil
        looper = nil
    }
}
