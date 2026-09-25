// Human-readable sizes and counts.
//
// Binary units, like `du -h` and dust. One decimal below 10, none above:
// enough resolution to compare neighbours without a wall of digits.

import Foundation

private let byteUnits = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]

/// `1.4 GiB`, `523 MiB`, `12 B`.
public func humanBytes(_ bytes: UInt64) -> String {
    format(scale(bytes), gap: " ")
}

/// `1.4GiB`, `523MiB`, `12B`: for tile labels, where columns are scarce.
public func humanBytesShort(_ bytes: UInt64) -> String {
    format(scale(bytes), gap: "")
}

private func scale(_ bytes: UInt64) -> (value: Double, unit: Int) {
    var value = Double(bytes)
    var unit = 0
    while value >= 1024 && unit + 1 < byteUnits.count {
        value /= 1024
        unit += 1
    }
    return (value, unit)
}

private func format(_ scaled: (value: Double, unit: Int), gap: String) -> String
{
    // Whole bytes have no fraction to show: `0 B`, not `0.0 B`. The 9.95
    // boundary is where one decimal would round up to a two-digit number.
    let text =
        if scaled.unit == 0 {
            String(format: "%.0f", scaled.value)
        } else if scaled.value < 9.95 {
            String(format: "%.1f", scaled.value)
        } else {
            String(format: "%.0f", scaled.value)
        }
    return text + gap + byteUnits[scaled.unit]
}

/// `12.0k`, `3.4M`, `812`: file counts, which grow past a million quickly.
public func humanCount(_ count: UInt64) -> String {
    let value = Double(count)
    if count < 10_000 {
        return String(count)
    } else if value < 1_000_000 {
        return String(format: "%.1fk", value / 1_000)
    } else if value < 1_000_000_000 {
        return String(format: "%.1fM", value / 1_000_000)
    } else {
        return String(format: "%.1fG", value / 1_000_000_000)
    }
}

/// Share of `total` as a percentage, saturating instead of dividing by zero.
public func share(_ part: UInt64, of total: UInt64) -> Double {
    total == 0 ? 0 : Double(part) / Double(total) * 100
}

/// Compass width for a share, e.g. `▓▓▓░░`: always exactly `width`
/// characters.
public func shareBar(_ part: UInt64, of total: UInt64, width: Int) -> String {
    let filled =
        total == 0
        ? 0 : Int((Double(part) / Double(total) * Double(width)).rounded())
    let clamped = min(max(filled, 0), width)
    return String(repeating: "▓", count: clamped)
        + String(repeating: "░", count: width - clamped)
}
