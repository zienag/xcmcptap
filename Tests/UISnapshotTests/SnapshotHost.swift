import AppKit
import SnapshotTesting
import SwiftUI
import Testing

/// The library's `.image(size:)` inherits both the point-to-pixel scale and
/// the colorspace from the current screen, so PNG bytes recorded on a
/// retina P3 dev machine don't match a headless CI runner (1x, Generic RGB).
/// This overload pins both: render at an explicit scale into an sRGB
/// bitmap rep, then color-manage into a P3 CGImage so every host produces
/// identical bytes.
@MainActor
func assertSnapshot(
  of controller: NSViewController,
  size: CGSize,
  scale: CGFloat = 2,
  fileID: StaticString = #fileID,
  file: StaticString = #filePath,
  testName: String = #function,
  line: UInt = #line,
  column: UInt = #column,
) {
  let view = controller.view
  view.frame = CGRect(origin: .zero, size: size)
  view.layoutSubtreeIfNeeded()

  let pixelsWide = Int(size.width * scale)
  let pixelsHigh = Int(size.height * scale)

  guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelsWide,
    pixelsHigh: pixelsHigh,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0,
  ) else {
    Issue.record("could not allocate bitmap rep for snapshot")
    return
  }
  rep.size = size
  view.cacheDisplay(in: view.bounds, to: rep)

  // CGContext.draw color-manages through the destination's colorspace;
  // that's the only hook that produces byte-stable P3 output regardless
  // of the rep's or screen's native colorspace. copy(colorSpace:) would
  // just retag the existing bytes.
  guard
    let source = rep.cgImage,
    let p3 = CGColorSpace(name: CGColorSpace.displayP3),
    let context = CGContext(
      data: nil,
      width: pixelsWide,
      height: pixelsHigh,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: p3,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    )
  else {
    Issue.record("could not build P3 CGContext for snapshot")
    return
  }
  context.draw(source, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
  guard let p3Image = context.makeImage() else {
    Issue.record("could not extract P3 CGImage from context")
    return
  }

  let image = NSImage(cgImage: p3Image, size: size)

  assertSnapshot(
    of: image,
    as: .image,
    fileID: fileID,
    file: file,
    testName: testName,
    line: line,
    column: column,
  )
}
