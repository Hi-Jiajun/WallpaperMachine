import AppKit
import ScreenSaver

/// Legacy screen saver for macOS releases that do not host third-party wallpaper
/// extensions (macOS 15). The system loads this bundle into its own process and calls
/// `startAnimation` when the saver is shown, so everything here is per-session state.
final class WallpaperMachineSaverView: ScreenSaverView {
    private var scene: ScreenSaverSceneContent?
    private var video: ScreenSaverVideoContent?
    private var message: String?
    private var started = false

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        prepare()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepare()
    }

    override var isFlipped: Bool { true }

    private func prepare() {
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspectFill
    }

    override func startAnimation() {
        super.startAnimation()
        guard !started else { return }
        started = true
        load()
    }

    override func stopAnimation() {
        teardown()
        super.stopAnimation()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 1
        scene?.layout(in: bounds, scale: scale)
        video?.layout(in: bounds)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 1
        scene?.layout(in: bounds, scale: scale)
    }

    override func animateOneFrame() {
        // The scene renderer and the video player produce their own frames.
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let message else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(13, bounds.height * 0.025)),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = message as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }

    private func load() {
        guard let wallpaper = ScreenSaverWallpaper.current() else {
            show(message: "没有找到已安装的壁纸，请先在 WallpaperMachine 里选择一个壁纸。")
            return
        }
        do {
            switch wallpaper.kind {
            case .scene:
                let cache = ScreenSaverWallpaper.supportRoot
                    .appendingPathComponent("shader-cache/\(wallpaper.id)", isDirectory: true)
                let content = ScreenSaverSceneContent(wallpaper: wallpaper, cacheURL: cache)
                try content.attach(to: self, scale: window?.backingScaleFactor ?? 1)
                scene = content
            case .video:
                let content = try ScreenSaverVideoContent(wallpaper: wallpaper)
                content.attach(to: self)
                video = content
            case .web:
                // A web wallpaper needs WebKit in this process; the still is the safe
                // first version and still matches what the wallpaper looks like.
                if !showPreview(wallpaper) {
                    show(message: "这个网页壁纸没有可显示的预览图。")
                }
            }
        } catch {
            NSLog("WallpaperMachine screen saver: %@", error.localizedDescription)
            if !showPreview(wallpaper) {
                show(message: error.localizedDescription)
            }
        }
    }

    private func teardown() {
        scene?.stop()
        scene = nil
        video?.stop()
        video = nil
        started = false
    }

    @discardableResult
    private func showPreview(_ wallpaper: ScreenSaverWallpaper) -> Bool {
        guard let url = wallpaper.previewURL,
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return false }
        message = nil
        layer?.contentsGravity = .resizeAspectFill
        layer?.contents = cgImage
        NSLog("WallpaperMachine screen saver: showing still %@", url.lastPathComponent)
        return true
    }

    private func show(message: String) {
        self.message = message
        layer?.contents = nil
        needsDisplay = true
    }
}
