import AppKit
import ImageIO
import QuartzCore
import SwiftUI

/// The frames of an animated GIF, APNG or WebP, decoded one at a time.
///
/// Only the current frame is held, decoded at the size it is drawn, so an animation costs the
/// memory of one frame however long it is. Nothing is ever read back from the screen.
struct AnimatedFrames: @unchecked Sendable {
  private let source: CGImageSource
  let count: Int
  /// How long each frame stays, in seconds; the delays a browser would use: none below 20 ms.
  let delays: [TimeInterval]

  /// Nil unless `data` is an image with more than one frame.
  init?(data: Data) {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 1
    else { return nil }
    self.source = source
    count = CGImageSourceGetCount(source)
    delays = (0..<count).map { Self.delay(of: source, at: $0) }
  }

  /// Frame `index` decoded to at most `maxPixelSize` on its long side.
  func image(at index: Int, maxPixelSize: Int) -> CGImage? {
    guard (0..<count).contains(index) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source, index,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixelSize),
        kCGImageSourceShouldCache: false,
      ] as CFDictionary)
  }

  /// A frame's delay, from whichever dictionary its format uses. Delays under 20 ms (including
  /// the 0 and 10 ms authors write to mean "as fast as possible") become 100 ms, as in browsers.
  nonisolated static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
    else { return 0.1 }
    let candidates: [(CFString, CFString, CFString)] = [
      (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
      (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
      (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
    ]
    for (dictionary, unclamped, clamped) in candidates {
      guard let values = properties[dictionary] as? [CFString: Any] else { continue }
      let seconds =
        (values[unclamped] as? NSNumber)?.doubleValue ?? (values[clamped] as? NSNumber)?.doubleValue
      if let seconds { return seconds >= 0.02 ? seconds : 0.1 }
    }
    return 0.1
  }
}

/// Plays an animated image in place, only while `isPlaying`.
///
/// The still image that fills the same tile stays under it: when `isPlaying` is false, the
/// animation is torn down (timer stopped, frame released) and the view draws nothing. It also
/// stops when the window is not visible and shows only its first frame under Reduce Motion, so an
/// animation never runs where nobody can see it or where the user asked for none.
/// `data` is what `PanelImagePipeline.animation(for:)` returned, already held to its budget.
struct AnimatedPreview: NSViewRepresentable {
  let data: Data?
  let isPlaying: Bool
  var contentMode: ContentMode = .fill

  func makeNSView(context: Context) -> AnimatedPreviewView { AnimatedPreviewView() }

  func updateNSView(_ view: AnimatedPreviewView, context: Context) {
    view.contentMode = contentMode
    view.set(data: data)
    view.setPlaying(isPlaying)
  }

  static func dismantleNSView(_ view: AnimatedPreviewView, coordinator: ()) {
    view.setPlaying(false)
    view.set(data: nil)
  }
}

@MainActor
final class AnimatedPreviewView: NSView {
  var contentMode: ContentMode = .fill {
    didSet { if contentMode != oldValue { needsLayout = true } }
  }
  private var frames: AnimatedFrames?
  private var loadedData: Data?
  private var index = 0
  private var timer: Timer?
  private var isPlaying = false
  private var occlusionObserver: NSObjectProtocol?
  private let content = CALayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    content.contentsGravity = .resizeAspectFill
    layer?.addSublayer(content)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    timer?.invalidate()
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
  }

  override var isFlipped: Bool { true }

  func set(data: Data?) {
    guard data != loadedData else { return }
    loadedData = data
    stop()
    frames = data.flatMap(AnimatedFrames.init(data:))
    index = 0
    content.contents = nil
  }

  func setPlaying(_ playing: Bool) {
    guard playing != isPlaying else { return }
    isPlaying = playing
    if playing { start() } else { stop() }
  }

  /// The frame currently drawn, for tests.
  var currentFrameIndex: Int { index }
  var isAnimating: Bool { timer != nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    content.frame = bounds
    content.contentsGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    occlusionObserver = nil
    guard let window else {
      stop()
      return
    }
    occlusionObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.visibilityChanged() }
    }
    if isPlaying { start() }
  }

  private var canAnimate: Bool {
    isPlaying && frames != nil && window?.occlusionState.contains(.visible) == true
  }

  private func visibilityChanged() {
    if canAnimate, timer == nil { start() } else if !canAnimate { stopTimer() }
  }

  private func start() {
    guard let frames, canAnimate else { return }
    draw(index)
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    schedule(after: frames.delays[index])
  }

  private func stop() {
    stopTimer()
    index = 0
    content.contents = nil
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func schedule(after delay: TimeInterval) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.advance() }
    }
  }

  private func advance() {
    guard let frames, canAnimate else { return stopTimer() }
    index = (index + 1) % frames.count
    draw(index)
    schedule(after: frames.delays[index])
  }

  private func draw(_ index: Int) {
    guard let frames else { return }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let pixels = Int((max(bounds.width, bounds.height, 64) * scale).rounded(.up))
    content.contents = frames.image(at: index, maxPixelSize: pixels)
  }
}
