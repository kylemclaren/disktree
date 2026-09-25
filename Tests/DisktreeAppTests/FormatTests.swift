import DisktreeCore
import Testing

@testable import DisktreeApp

@Test func agesReadInTheUnitAPersonWouldUse() {
    let now: Int64 = 1_800_000_000
    #expect(ago(now: now, then: now - 5) == "just now")
    #expect(ago(now: now, then: now - 120) == "2 minutes ago")
    #expect(ago(now: now, then: now - 3_600) == "1 hour ago")
    #expect(ago(now: now, then: now - 19 * 86_400) == "19 days ago")
    #expect(ago(now: now, then: now - 90 * 86_400) == "3 months ago")
    #expect(ago(now: now, then: now - 800 * 86_400) == "2 years ago")
    #expect(ago(now: now, then: 0) == "unknown")
}

@Test func agesChangeUnitAtTheirBoundaries() {
    let now: Int64 = 1_800_000_000
    #expect(ago(now: now, then: now - 59) == "just now")
    #expect(ago(now: now, then: now - 60) == "1 minute ago")
    #expect(ago(now: now, then: now - 59 * 86_400) == "59 days ago")
    #expect(ago(now: now, then: now - 60 * 86_400) == "2 months ago")
    #expect(ago(now: now, then: now - 730 * 86_400) == "2 years ago")
    // A clock set wrong puts a write in the future: it is recent, not
    // negative.
    #expect(ago(now: now, then: now + 3_600) == "just now")
    #expect(ago(now: now, then: -1) == "unknown")
}

@Test func sizesSplitIntoNumberAndUnit() {
    #expect(splitSize("90.1 GiB") == ("90.1", "GiB"))
    #expect(splitSize("0") == ("0", ""))
    // Only the first space splits: a unit phrase stays whole.
    #expect(splitSize("3 GiB free") == ("3", "GiB free"))
}

@Test func percentagesKeepADecimalBelowTen() {
    #expect(percent(1, of: 1_000) == "0.1%")
    #expect(percent(99, of: 1_000) == "9.9%")
    // 9.95 would read as "10.0%" with a decimal; it drops the decimal.
    #expect(percent(996, of: 10_000) == "10%")
    #expect(percent(1, of: 1) == "100%")
    #expect(percent(5, of: 0) == "0.0%")
}

@Test func shortValuesFollowTheMetric() {
    var node = Node.entry("big", kind: .file, bytes: 1536)
    node.files = 12_000
    // A thin space between the number and the unit.
    #expect(shortValue(node, metric: .bytes) == "1.5\u{2009}KiB")
    #expect(shortValue(node, metric: .files) == "12.0k")
}
