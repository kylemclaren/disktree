// The mosaic's tiles, written straight into a bitmap.
//
// A treemap is made of rows. Every tile is an axis-aligned rectangle, so its
// fill is a run of one pixel value per row; its cushion is one colour per
// row; the hatch is one pixel in seven per row; a rounded corner is a few
// pixels of coverage at either end of a few rows. CoreGraphics rasterises
// general paths and charges for the generality: a frame of 1,700 tiles, half
// of them hatched, took 21 ms at 2x through CG, most of it in the hatch's
// stripes, and rounding every tile's corners with paths would have cost
// another 4 ms. Written here row by row, a frame of 2,700 tiles, a third of
// them hatched, paints in about 5 ms with its corners, cushions, glow and
// labels, and the copy into the view
// (`aFrameOfThousandsOfTilesPaintsInsideTheBudget` measures it).
//
// What is not rows — the rings, the badges, the labels — is still drawn by
// CoreGraphics and CoreText, into the same bitmap, after this pass
// (Invariant 6: one paint, no views).

import CoreGraphics
import Foundation
import Synchronization

/// A pixel as the canvas stores it: 32 bits, little-endian, alpha first and
/// premultiplied, which reads `0xAARRGGBB` in a register. Everything the
/// raster writes is opaque.
typealias MosaicPixel = UInt32

extension HSLA {
    /// The colour as an opaque canvas pixel, its alpha ignored: the raster
    /// blends translucent colours itself, with `rasterAlpha`.
    var pixel: MosaicPixel {
        let rgb = toRGB()
        let channel = { (value: Double) in
            MosaicPixel((min(max(value, 0), 1) * 255).rounded())
        }
        return 0xFF00_0000 | channel(rgb.r) << 16 | channel(rgb.g) << 8
            | channel(rgb.b)
    }

    /// The colour's alpha as the raster's blend weight, out of 256.
    var rasterAlpha: MosaicPixel {
        MosaicPixel((min(max(a, 0), 1) * 256).rounded())
    }
}

/// `source` over `ground`, `alpha` of 256 of the way: one channel pair at a
/// time, red and blue together, rounded to the nearest level.
@inline(__always)
func blendPixel(
    _ ground: MosaicPixel,
    _ source: MosaicPixel,
    _ alpha: MosaicPixel
) -> MosaicPixel {
    let alpha = min(alpha, 256)
    let rest = 256 - alpha
    let redBlue =
        ((source & 0xFF_00FF) &* alpha &+ (ground & 0xFF_00FF) &* rest
            &+ 0x80_0080) >> 8 & 0xFF_00FF
    let green =
        ((source & 0x00_FF00) &* alpha &+ (ground & 0x00_FF00) &* rest
            &+ 0x00_8000) >> 8 & 0x00_FF00
    return 0xFF00_0000 | redBlue | green
}

// MARK: - Corners

/// How much of each pixel in a rounded corner the tile covers, for a
/// radius of `radius` pixels: rows from the tile's edge inward, columns
/// from its side inward. Measured once per radius, 8 by 8 samples a pixel,
/// which is finer than any eye tells apart at a two or three point corner.
struct CornerMask: Sendable {
    /// Whole pixels the corner reaches into the tile, each way.
    let size: Int
    /// `size * size` coverages, row by row, `0` outside, `1` inside.
    let coverage: [Float]
    /// Per row, the first column that is covered completely: from there to
    /// the matching column on the far side, the row is a plain run.
    let solidFrom: [Int]

    init(radius: Double) {
        let size = max(Int(radius.rounded(.up)), 0)
        var coverage = [Float](repeating: 1, count: size * size)
        var solidFrom = [Int](repeating: 0, count: size)
        let samples = 8
        for row in 0..<size {
            var solid = size
            for column in (0..<size).reversed() {
                var inside = 0
                for sampleY in 0..<samples {
                    for sampleX in 0..<samples {
                        // The arc's centre is `radius` in from both edges.
                        let dx =
                            radius - Double(column)
                            - (Double(sampleX) + 0.5) / Double(samples)
                        let dy =
                            radius - Double(row)
                            - (Double(sampleY) + 0.5) / Double(samples)
                        if dx <= 0 || dy <= 0
                            || dx * dx + dy * dy <= radius * radius
                        {
                            inside += 1
                        }
                    }
                }
                let share = Float(inside) / Float(samples * samples)
                coverage[row * size + column] = share
                if share >= 1, solid == column + 1 {
                    solid = column
                }
            }
            solidFrom[row] = solid
        }
        self.size = size
        self.coverage = coverage
        self.solidFrom = solidFrom
    }
}

// MARK: - The canvas

/// The bitmap a mosaic is painted into before it is shown, and what the
/// raster measures once and keeps: the view holds one from frame to frame,
/// so a frame rarely allocates a bitmap and never measures a corner again.
///
/// The image a frame hands the view is made straight over the bitmap's
/// memory, without a copy: `CGContext.makeImage` copies the bitmap, or marks
/// its pages copy-on-write so that the next frame's first write to each page
/// faults and copies it, which at 2x costs more than rasterising every tile.
///
/// So each frame paints into a bitmap nobody is reading. AppKit does not
/// draw a layer-backed view's image when `draw(_:)` hands it over: it
/// records the drawing and renders it a moment later, still holding the
/// image. A single bitmap, repainted for the next frame of the hover's lift
/// while the last one was still being shown from it, came out torn and
/// flickering. A bitmap goes back to the pool only when CoreGraphics lets go
/// of the image made over it; until then the next frame takes another.
final class MosaicCanvas {
    /// The context of the bitmap the frame being painted owns.
    private(set) var context: CGContext?
    /// That bitmap, until its image is made.
    private var current: CanvasBuffer?
    /// Bitmaps whose images have been let go, ready to paint again.
    private let pool = CanvasPool()
    /// The bitmap the last image was made over: what a test watches to see
    /// a bitmap come back once its image is let go.
    private(set) var lastLent: UnsafeMutableRawPointer?
    /// Corner masks by radius, in quarter pixels.
    private var masks: [Int: CornerMask] = [:]

    init() {}

    /// The layout the canvas and its images share.
    static let bitmapInfo =
        CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    /// A bitmap of `width` by `height` pixels in `space` that nothing else
    /// is reading: the last frame's, if its image has been let go, or
    /// another.
    func context(
        width: Int,
        height: Int,
        space: CGColorSpace = canvasSRGB
    ) -> CGContext? {
        guard width > 0, height > 0 else {
            context = nil
            return nil
        }
        if let current, let context = current.context(width, height, space) {
            self.context = context
            return context
        }
        let buffer = pool.take(bytes: width * height * 4)
        current = buffer
        context = buffer.context(width, height, space)
        return context
    }

    /// The canvas as an image, over its own pixels. The bitmap is lent to
    /// the image for as long as it lives; the next frame paints another.
    func image() -> CGImage? {
        guard let buffer = current, let context,
            let space = context.colorSpace,
            let provider = buffer.provider(
                size: context.bytesPerRow * context.height,
                returningTo: pool
            )
        else { return nil }
        current = nil
        self.context = nil
        lastLent = buffer.memory
        return CGImage(
            width: context.width,
            height: context.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: context.bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// The mask for a corner of `radius` pixels, to the nearest quarter.
    func mask(radius: Double) -> CornerMask {
        let key = Int((radius * 4).rounded())
        if let known = masks[key] {
            return known
        }
        // A tile's corners come in a handful of radii; zoom and a
        // transition's shrinking tiles add a few more. Bounded all the same.
        if masks.count > 256 {
            masks.removeAll(keepingCapacity: true)
        }
        let mask = CornerMask(radius: Double(key) / 4)
        masks[key] = mask
        return mask
    }
}

// MARK: - The raster

/// A tile's box in device pixels: half-open, `right` and `bottom` just
/// outside it.
struct PixelBox: Hashable {
    var left: Int
    var top: Int
    var right: Int
    var bottom: Int

    var width: Int { right - left }
    var height: Int { bottom - top }
}

/// Writes rows of pixels into a canvas's bitmap. The bitmap's first row in
/// memory is the top of the picture, so rows run down, as the layout does.
struct MosaicRaster {
    let pixels: UnsafeMutablePointer<MosaicPixel>
    let width: Int
    let height: Int
    /// Pixels from one row to the next: a context may pad its rows.
    let stride: Int

    init?(_ context: CGContext) {
        guard let data = context.data, context.bitsPerPixel == 32 else {
            return nil
        }
        pixels = data.bindMemory(
            to: MosaicPixel.self,
            capacity: context.bytesPerRow / 4 * context.height
        )
        width = context.width
        height = context.height
        stride = context.bytesPerRow / 4
    }

    /// Every pixel `color`.
    func clear(_ color: MosaicPixel) {
        for y in 0..<height {
            run(y: y, from: 0, to: width, color)
        }
    }

    /// Pixels `from` up to `to` of row `y` set to `color`, already clipped.
    @inline(__always)
    func run(y: Int, from: Int, to: Int, _ color: MosaicPixel) {
        guard to > from else { return }
        var pattern = color
        memset_pattern4(pixels + y * stride + from, &pattern, (to - from) * 4)
    }

    /// Blend `color` over the pixel at `x`, `y`, `alpha` of 256.
    @inline(__always)
    func blend(x: Int, y: Int, _ color: MosaicPixel, _ alpha: MosaicPixel) {
        let at = pixels + y * stride + x
        at.pointee = blendPixel(at.pointee, color, alpha)
    }

    /// Visit `box` as a rounded rectangle, row by row, clipped to the
    /// bitmap: `solid` gets each row's run of wholly covered pixels, and
    /// `edge` each partly covered corner pixel with how much of it the tile
    /// covers. A `nil` mask is a square box.
    @inline(__always)
    func walk(
        _ box: PixelBox,
        mask: CornerMask?,
        solid: (_ y: Int, _ from: Int, _ to: Int) -> Void,
        edge: (_ x: Int, _ y: Int, _ coverage: Float) -> Void
    ) {
        // A box wholly above or below the bitmap — the band of a directory
        // scrolled up out of a magnified view — has no rows to visit.
        let first = max(box.top, 0)
        let last = min(box.bottom, height)
        guard first < last, box.right > 0, box.left < width else { return }
        let rows = first..<last
        let size = mask?.size ?? 0
        for y in rows {
            let fromTop = y - box.top
            let fromBottom = box.bottom - 1 - y
            let corner =
                fromTop < size ? fromTop : fromBottom < size ? fromBottom : -1
            var inset = 0
            if corner >= 0, let mask {
                inset = mask.solidFrom[corner]
                for column in 0..<inset {
                    let coverage = mask.coverage[corner * size + column]
                    guard coverage > 0 else { continue }
                    let near = box.left + column
                    let far = box.right - 1 - column
                    if near >= 0, near < width {
                        edge(near, y, coverage)
                    }
                    if far >= 0, far < width, far != near {
                        edge(far, y, coverage)
                    }
                }
            }
            solid(
                y,
                max(box.left + inset, 0),
                min(box.right - inset, width)
            )
        }
    }

    /// Fill `box`, its corners rounded by `mask`, with `color(y)` on row
    /// `y`: one colour for a flat tile, a ramp for a cushion.
    @inline(__always)
    func fill(
        _ box: PixelBox,
        mask: CornerMask?,
        color: (_ y: Int) -> MosaicPixel
    ) {
        walk(
            box,
            mask: mask,
            solid: { y, from, to in run(y: y, from: from, to: to, color(y)) },
            edge: { x, y, coverage in
                blend(
                    x: x,
                    y: y,
                    color(y),
                    MosaicPixel((coverage * 256).rounded())
                )
            }
        )
    }

    /// Wash `box`, rounded by `mask`, with `color` at `alpha` of 256: the
    /// hover's lift.
    func wash(
        _ box: PixelBox,
        mask: CornerMask?,
        color: MosaicPixel,
        alpha: MosaicPixel
    ) {
        guard alpha > 0 else { return }
        wash(box, mask: mask, color: color) { _ in alpha }
    }

    /// Wash `box`, rounded by `mask`, with `color` at `alpha(y)` of 256 on
    /// row `y`: a lift that keeps off the rows a name is set in.
    func wash(
        _ box: PixelBox,
        mask: CornerMask?,
        color: MosaicPixel,
        alpha: (_ y: Int) -> MosaicPixel
    ) {
        walk(
            box,
            mask: mask,
            solid: { y, from, to in
                let strength = alpha(y)
                guard strength > 0 else { return }
                let row = pixels + y * stride
                for x in from..<max(to, from) {
                    row[x] = blendPixel(row[x], color, strength)
                }
            },
            edge: { x, y, coverage in
                let strength = alpha(y)
                guard strength > 0 else { return }
                blend(
                    x: x,
                    y: y,
                    color,
                    MosaicPixel((Float(strength) * coverage).rounded())
                )
            }
        )
    }

    /// The reclaimable hatch over `box`, from its row `skip` down: slash
    /// stripes `width` pixels wide along a row and `period` pixels apart,
    /// in `color` at `alpha` of 256.
    ///
    /// The stripes `Hatch` draws: centred on the diagonals through the box's
    /// top-left corner plus whole periods, so every tile starts in the same
    /// phase. At 45° a stripe one pixel wide is one pixel per row, a
    /// diagonal as crisp as a pixel grid draws one, carrying the stripe's
    /// whole area; CoreGraphics' antialiased polygon spread the same ink
    /// over three pixels, three times the work for a softer line. Corner
    /// pixels are left alone: at two points, no stripe there reads.
    func hatch(
        _ box: PixelBox,
        mask: CornerMask?,
        skip: Int,
        width: Int,
        period: Int,
        color: MosaicPixel,
        alpha: MosaicPixel
    ) {
        guard width > 0, period > width, alpha > 0 else { return }
        walk(
            box,
            mask: mask,
            solid: { y, from, to in
                let down = y - box.top
                guard down >= skip, to > from else { return }
                let row = pixels + y * stride
                // A stripe starts where `x - left + down + 1` is a whole
                // number of periods (`+ 1`: a pixel's centre is half a
                // pixel in, both ways). The first one looked at may start
                // left of the run and still reach into it.
                let first = from - width + 1
                let offset = (first - box.left + down + 1) % period
                var x = first + (period - (offset + period) % period) % period
                while x < to {
                    for pixel in max(x, from)..<min(x + width, to) {
                        row[pixel] = blendPixel(row[pixel], color, alpha)
                    }
                    x += period
                }
            },
            edge: { _, _, _ in }
        )
    }

    /// A soft glow of `color` around `box`, outside it only: `alpha(d)`
    /// for a pixel `d` pixels from the rounded edge, `extent` pixels at
    /// most.
    func glow(
        _ box: PixelBox,
        radius: Double,
        extent: Int,
        color: MosaicPixel,
        alpha: (Double) -> MosaicPixel
    ) {
        guard extent > 0, box.width > 0, box.height > 0 else { return }
        let centreX = Double(box.left + box.right) / 2
        let centreY = Double(box.top + box.bottom) / 2
        let halfWidth = Double(box.width) / 2 - radius
        let halfHeight = Double(box.height) / 2 - radius
        // How far a pixel's centre is outside the rounded rectangle: the
        // signed distance, negative inside.
        let distance = { (x: Int, y: Int) -> Double in
            let qx = abs(Double(x) + 0.5 - centreX) - halfWidth
            let qy = abs(Double(y) + 0.5 - centreY) - halfHeight
            let outside = hypot(max(qx, 0), max(qy, 0))
            return outside + min(max(qx, qy), 0) - radius
        }
        let reach = Int(radius.rounded(.up)) + 1
        let rows = max(box.top - extent, 0)..<min(box.bottom + extent, height)
        let columns = max(box.left - extent, 0)..<min(box.right + extent, width)
        guard !rows.isEmpty, !columns.isEmpty else { return }
        func shade(
            _ row: UnsafeMutablePointer<MosaicPixel>, y: Int,
            from: Int, to: Int
        ) {
            for x in from..<max(to, from) {
                let d = distance(x, y)
                guard d > -0.5 else { continue }
                // Half a pixel into the edge the glow fades in with the
                // edge's own coverage, so it meets the ring cleanly.
                let fade = MosaicPixel((min(d + 0.5, 1) * 64).rounded())
                let weight = alpha(max(d, 0)) * fade / 64
                if weight > 0 {
                    row[x] = blendPixel(row[x], color, weight)
                }
            }
        }
        for y in rows {
            let row = pixels + y * stride
            // Beside the box's straight sides only the bands either side
            // can glow; the rest of the row is inside.
            if y >= box.top + reach, y < box.bottom - reach {
                shade(
                    row,
                    y: y,
                    from: columns.lowerBound,
                    to: min(box.left, columns.upperBound)
                )
                shade(
                    row,
                    y: y,
                    from: max(box.right, columns.lowerBound),
                    to: columns.upperBound
                )
            } else {
                shade(
                    row,
                    y: y,
                    from: columns.lowerBound,
                    to: columns.upperBound
                )
            }
        }
    }
}

// MARK: - The canvas's bitmaps

/// One bitmap, and the context last made over it.
///
/// `@unchecked Sendable` because an image's provider hands it back to the
/// pool from whichever thread CoreGraphics lets the image go on. It is never
/// touched from two places at once: the main actor paints it while it is
/// the canvas's `current`, CoreGraphics only reads it while an image holds
/// it, and the pool's mutex passes it from one to the other.
final class CanvasBuffer: @unchecked Sendable {
    let memory: UnsafeMutableRawPointer
    let capacity: Int
    private var made:
        (width: Int, height: Int, space: CGColorSpace, context: CGContext)?

    init(bytes: Int) {
        memory = UnsafeMutableRawPointer.allocate(
            byteCount: bytes,
            alignment: 64
        )
        capacity = bytes
    }

    deinit {
        memory.deallocate()
    }

    /// A context of `width` by `height` in `space` over this bitmap, or
    /// `nil` when it is too small for that.
    func context(
        _ width: Int,
        _ height: Int,
        _ space: CGColorSpace
    ) -> CGContext? {
        guard width * height * 4 <= capacity else { return nil }
        if let made, made.width == width, made.height == height,
            made.space == space
        {
            return made.context
        }
        guard
            let context = CGContext(
                data: memory,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: MosaicCanvas.bitmapInfo
            )
        else { return nil }
        made = (width, height, space, context)
        return context
    }

    /// A provider over the bitmap that gives it back to `pool` when the
    /// image made over it is let go.
    func provider(size: Int, returningTo pool: CanvasPool) -> CGDataProvider? {
        let loan = CanvasLoan(buffer: self, pool: pool)
        let provider = CGDataProvider(
            dataInfo: Unmanaged.passRetained(loan).toOpaque(),
            data: memory,
            size: size,
            releaseData: { info, _, _ in
                guard let info else { return }
                Unmanaged<CanvasLoan>.fromOpaque(info).takeRetainedValue()
                    .settle()
            }
        )
        if provider == nil {
            // Never lent after all: the release will not come.
            loan.settle()
        }
        return provider
    }
}

/// A bitmap out on loan to an image, and where it goes back.
final class CanvasLoan: Sendable {
    let buffer: CanvasBuffer
    let pool: CanvasPool

    init(buffer: CanvasBuffer, pool: CanvasPool) {
        self.buffer = buffer
        self.pool = pool
    }

    func settle() {
        pool.giveBack(buffer)
    }
}

/// The bitmaps no image is holding.
final class CanvasPool: Sendable {
    /// A handful at most: the system holds a frame or two, and a live
    /// resize lets the smaller ones go.
    private static let kept = 4
    private let free = Mutex<[CanvasBuffer]>([])

    /// A free bitmap of at least `bytes`, or a new one. Grown, never
    /// shrunk: a live resize asks for a new size every frame, and memory
    /// already mapped is cheaper than memory mapped again.
    func take(bytes: Int) -> CanvasBuffer {
        free.withLock { free in
            if let index = free.firstIndex(where: { $0.capacity >= bytes }) {
                return free.remove(at: index)
            }
            return CanvasBuffer(bytes: bytes)
        }
    }

    func giveBack(_ buffer: CanvasBuffer) {
        free.withLock { free in
            free.append(buffer)
            if free.count > Self.kept {
                free.sort { $0.capacity > $1.capacity }
                free.removeLast(free.count - Self.kept)
            }
        }
    }
}
