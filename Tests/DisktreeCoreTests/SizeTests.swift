import Testing

@testable import DisktreeCore

@Test func bytesUseBinaryUnitsWithOneDecimalBelowTen() {
    #expect(humanBytes(0) == "0 B")
    #expect(humanBytes(7) == "7 B")
    #expect(humanBytes(12) == "12 B")
    #expect(humanBytes(1024) == "1.0 KiB")
    #expect(humanBytes(1536) == "1.5 KiB")
    #expect(humanBytes(1024 * 1024 * 1024 + 400 * 1024 * 1024) == "1.4 GiB")
    #expect(humanBytes(512 * 1024 * 1024) == "512 MiB")
}

@Test func shortFormDropsTheSpace() {
    #expect(humanBytesShort(1536) == "1.5KiB")
    #expect(humanBytesShort(512 * 1024) == "512KiB")
}

@Test func countsSwitchToMetricSuffixes() {
    #expect(humanCount(0) == "0")
    #expect(humanCount(9_999) == "9999")
    #expect(humanCount(12_000) == "12.0k")
    #expect(humanCount(2_500_000) == "2.5M")
}

@Test func shareSurvivesAZeroTotal() {
    #expect(share(5, of: 0) == 0)
    #expect(share(1, of: 4) == 25)
}

@Test func shareBarIsAlwaysTheRequestedWidth() {
    #expect(shareBar(1, of: 4, width: 4).count == 4)
    #expect(shareBar(4, of: 4, width: 4) == "▓▓▓▓")
    #expect(shareBar(0, of: 4, width: 4) == "░░░░")
    #expect(shareBar(1, of: 0, width: 3).count == 3)
}
