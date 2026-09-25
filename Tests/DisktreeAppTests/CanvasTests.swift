// The mosaic's canvas never paints over an image that is still being shown.
//
// AppKit records a layer-backed view's drawing and renders it a moment
// later, holding the image `draw(_:)` handed over. When the canvas had one
// bitmap, the hover's lift repainted it for the next frame while the last
// was still being shown from it, and the mosaic tore and flickered under the
// pointer. These pin the rule that fixed it: a bitmap is lent to its image
// until the image is let go.

import CoreGraphics
import Foundation
import Testing

@testable import DisktreeApp

/// The first pixel of `image`, as its bytes lie in memory: blue, green,
/// red, alpha, since the canvas is 32-bit little-endian, alpha first.
private func firstPixel(_ image: CGImage) throws -> [UInt8] {
    let data = try #require(image.dataProvider?.data as Data?)
    return Array(data.prefix(4))
}

private func paint(
    _ canvas: MosaicCanvas,
    red: CGFloat,
    blue: CGFloat
) throws -> CGImage {
    let context = try #require(canvas.context(width: 64, height: 32))
    context.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    return try #require(canvas.image())
}

@Test func aFrameNeverPaintsOverAnImageStillShown() throws {
    let canvas = MosaicCanvas()
    let shown = try paint(canvas, red: 1, blue: 0)
    // The next frame, painted while the first image is still held.
    let next = try paint(canvas, red: 0, blue: 1)
    #expect(try firstPixel(shown) == [0, 0, 255, 255], "still red")
    #expect(try firstPixel(next) == [255, 0, 0, 255], "the new frame is blue")
}

@Test func aBitmapLetGoIsPaintedAgain() throws {
    let canvas = MosaicCanvas()
    var memory: UnsafeMutableRawPointer?
    do {
        let image = try paint(canvas, red: 1, blue: 0)
        memory = canvas.lastLent
        _ = image
    }
    // The image is gone, so its bitmap is back: the next frame paints into
    // it rather than into a new one, and nothing grows frame by frame.
    _ = try paint(canvas, red: 0, blue: 1)
    #expect(canvas.lastLent == memory)
}

/// The canvas is made in the colour space it is drawn into, so the copy
/// into a Display P3 or calibrated window converts nothing, frame after
/// frame; the colours it writes are converted into that space once, and
/// read the same as the sRGB palette does there.
@Test func theCanvasIsMadeInTheSpaceItIsDrawnInto() throws {
    let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let into = try #require(
        CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: p3,
            bitmapInfo: MosaicCanvas.bitmapInfo
        )
    )
    #expect(canvasSpace(for: into) == p3)
    let canvas = MosaicCanvas()
    #expect(canvas.context(width: 8, height: 8, space: p3)?.colorSpace == p3)

    let srgb = MosaicColors(theme: .dark)
    #expect(srgb.resolved(for: canvasSRGB).inset.pixel == srgb.inset.pixel)
    let resolved = srgb.resolved(for: p3)
    #expect(resolved.space == p3)
    for ink in [srgb.inset, srgb.selectedBorder, srgb.markedFill, srgb.hatch] {
        // What ColorSync makes of the sRGB colour in Display P3.
        let rgb = ink.hsla.toRGB()
        let color = try #require(
            CGColor(
                colorSpace: canvasSRGB,
                components: [rgb.r, rgb.g, rgb.b, 1]
            )?.converted(to: p3, intent: .defaultIntent, options: nil)
        )
        let expected = try #require(color.components).prefix(3).map {
            Int(($0 * 255).rounded())
        }
        let pixel = resolved.mapped(ink).pixel
        let got = [pixel >> 16, pixel >> 8, pixel].map { Int($0 & 0xFF) }
        #expect(
            zip(got, expected).allSatisfy { abs($0 - $1) <= 1 },
            "\(got) against \(expected)"
        )
        #expect(pixel >> 24 == 0xFF, "opaque")
    }
    // A saturated colour really moves: the conversion was made.
    #expect(resolved.selectedBorder.pixel != srgb.selectedBorder.pixel)
}

extension MosaicColors {
    /// `ink`, a colour of the sRGB set, as this set holds it.
    fileprivate func mapped(_ ink: MosaicInk) -> MosaicInk {
        [inset, selectedBorder, markedFill, hatch].first {
            $0.hsla == ink.hsla
        } ?? ink
    }
}
