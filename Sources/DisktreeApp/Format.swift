// Numbers and times as the screens say them.
//
// The byte and count formats themselves live in DisktreeCore (Size.swift),
// beside the tests that pin them; these are the few phrasings only the
// screens need.

import DisktreeCore
import Foundation

/// The value to show for a node under the active metric: the short form, as
/// a tile label or a list lane has little room. Its number and unit are
/// kept apart by a thin space: close enough to read as one figure in a
/// small tile, apart enough to read as "1.1 GiB", as every other size on
/// screen is written.
public func shortValue(_ node: Node, metric: Metric) -> String {
    switch metric {
    case .bytes: humanBytes(node.bytes).replacing(" ", with: "\u{2009}")
    case .files: humanCount(node.files)
    }
}

/// A percentage with one decimal below ten percent. The 9.95 boundary is
/// where one decimal would round up to a two-digit number.
public func percent(_ part: UInt64, of total: UInt64) -> String {
    let value = share(part, of: total)
    return value < 9.95
        ? String(format: "%.1f%%", value)
        : String(format: "%.0f%%", value)
}

/// A size split into number and unit, so the number can be set large:
/// `90.1 GiB` is `("90.1", "GiB")`. Text without a space is all number.
public func splitSize(_ text: String) -> (number: String, unit: String) {
    guard let space = text.firstIndex(of: " ") else {
        return (text, "")
    }
    return (
        String(text[..<space]),
        String(text[text.index(after: space)...])
    )
}

/// How long ago a Unix time was, in the unit a person would use.
///
/// A time of zero or before is what the scanner records when it could not
/// read one, so it is "unknown" rather than fifty-odd years. A time in the
/// future (a clock set wrong) reads as "just now".
public func ago(now: Int64, then: Int64) -> String {
    if then <= 0 {
        return "unknown"
    }
    let seconds = max(now - then, 0)
    let plural = { (count: Int64, unit: String) in
        count == 1 ? "1 \(unit) ago" : "\(count) \(unit)s ago"
    }
    // Days run to sixty before months take over, and months to two years
    // before years do: "45 days" and "18 months" are what people say.
    return switch seconds {
    case ..<60: "just now"
    case ..<3_600: plural(seconds / 60, "minute")
    case ..<86_400: plural(seconds / 3_600, "hour")
    case ..<5_184_000: plural(seconds / 86_400, "day")
    case ..<63_072_000: plural(seconds / 2_592_000, "month")
    default: plural(seconds / 31_536_000, "year")
    }
}
