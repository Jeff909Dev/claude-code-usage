import Foundation
import Testing
@testable import UsageCore

struct PricingTests {
    let table = PricingTable.builtin

    @Test func builtinMatchesSpecTable() {
        #expect(table.price(for: "claude-fable-5-1") == ModelPrice(prefix: "claude-fable-5-1", input: 10, output: 50, cacheRead: 0.25))
        #expect(table.price(for: "claude-fable-5")?.cacheRead == 1.00)
        #expect(table.price(for: "claude-opus-5-5") == ModelPrice(prefix: "claude-opus-5-5", input: 4, output: 20, cacheRead: 0.20))
        #expect(table.price(for: "claude-opus-5")?.input == 5)
        #expect(table.price(for: "claude-opus-4-8")?.cacheRead == 0.50)
        #expect(table.price(for: "claude-sonnet-5-5")?.output == 10)
        #expect(table.price(for: "claude-sonnet-4-6")?.input == 3)
        #expect(table.price(for: "claude-haiku-4-5")?.cacheRead == 0.10)
    }

    @Test func pricesSuffixedModelIDs() {
        #expect(table.price(for: "claude-opus-5[1m]")?.prefix == "claude-opus-5")
        #expect(table.price(for: "claude-fable-5-1[1m]")?.prefix == "claude-fable-5-1")
        #expect(table.price(for: "claude-haiku-4-5-20251001")?.prefix == "claude-haiku-4-5")
        #expect(table.price(for: "gpt_image_2_5") == nil)
    }

    @Test func costOfRealFableMessage() {
        // usage from a real transcript line: 2 in, 3475 out, 25373 cache read, 35613 cache write (1h)
        let u = TokenUsage(input: 2, output: 3_475, cacheRead: 25_373, cacheWrite1h: 35_613)
        // 2×10 + 3475×50 + 25373×0.25 + 35613×10×2 = 892 373.25 µ$
        #expect(CostCalculator.costMicros(u, modelID: "claude-fable-5-1", table: table) == 892_373)
    }

    @Test func fiveMinuteWritesAndFastMode() {
        let u = TokenUsage(cacheWrite5m: 1_000)
        #expect(CostCalculator.costMicros(u, modelID: "claude-opus-5-5", table: table) == 5_000)   // 1000×4×1.25
        var fast = TokenUsage(output: 1_000)
        fast.isFast = true
        #expect(CostCalculator.costMicros(fast, modelID: "claude-opus-5-5", table: table) == 40_000) // 1000×20×2
    }

    @Test func unknownModelHasNoCost() {
        #expect(CostCalculator.costMicros(TokenUsage(output: 10), modelID: "mystery", table: table) == nil)
    }

    @Test func overrideFileWinsAndBadFileFallsBack() throws {
        let dir = try TempDir()
        let good = dir.file("pricing.json")
        try Data(#"{"models":[{"prefix":"x","input":1,"output":2,"cacheRead":0.1}],"plans":{"Pro":20}}"#.utf8).write(to: good)
        #expect(PricingTable.load(override: good).models.map(\.prefix) == ["x"])
        let bad = dir.file("bad.json")
        try Data("nope".utf8).write(to: bad)
        #expect(PricingTable.load(override: bad) == PricingTable.builtin)
        #expect(PricingTable.load(override: dir.file("missing.json")) == PricingTable.builtin)
    }

    @Test func monthlyTotalSumsKnownPlans() {
        #expect(table.monthlyTotal(for: ["Max 20x", "Max 5x", "Pro", "Unknown"]) == 320)
    }

    @Test func families() {
        #expect(ModelNames.family("claude-fable-5-1") == "Fable")
        #expect(ModelNames.family("claude-opus-5[1m]") == "Opus")
        #expect(ModelNames.family("claude-haiku-4-5-20251001") == "Haiku")
        #expect(ModelNames.family("gpt_image_2_5") == nil)
    }

    @Test func invalidOverridePricesFallBackToBuiltin() throws {
        let dir = try TempDir()
        for (name, price) in [("huge.json", "1e300"), ("neg.json", "-1"), ("over.json", "10001")] {
            let url = dir.file(name)
            try Data(#"{"models":[{"prefix":"x","input":\#(price),"output":2,"cacheRead":0.1}],"plans":{}}"#.utf8).write(to: url)
            #expect(PricingTable.load(override: url) == PricingTable.builtin)
        }
        let badCache = dir.file("cache.json")
        try Data(#"{"models":[{"prefix":"x","input":1,"output":2,"cacheRead":-0.1}],"plans":{}}"#.utf8).write(to: badCache)
        #expect(PricingTable.load(override: badCache) == PricingTable.builtin)
    }

    @Test func validOverrideTakesPrecedenceOverBuiltin() throws {
        let dir = try TempDir()
        let url = dir.file("p.json")
        try Data(#"{"models":[{"prefix":"claude-opus-5","input":1,"output":2,"cacheRead":0.1}],"plans":{}}"#.utf8).write(to: url)
        #expect(PricingTable.load(override: url).price(for: "claude-opus-5")?.input == 1)
    }

    @Test func hugeTokenCountsDoNotTrap() {
        let big = TokenUsage(output: 1_000_000_000_000)
        #expect(CostCalculator.costMicros(big, modelID: "claude-fable-5-1", table: table) == 50_000_000_000_000)
        let overflow = TokenUsage(input: .max, output: .max, cacheWrite1h: .max, isFast: true)
        let cost = CostCalculator.costMicros(overflow, modelID: "claude-fable-5-1", table: table)
        #expect(cost == Int64.max)
    }

    @Test func fastModeAppliesToCacheWrites() {
        let u = TokenUsage(cacheWrite5m: 1_000, cacheWrite1h: 1_000, isFast: true)
        // (1000×4×1.25 + 1000×4×2) × 2 = 26 000
        #expect(CostCalculator.costMicros(u, modelID: "claude-opus-5-5", table: table) == 26_000)
    }

    @Test func zeroTokensCostNothing() {
        #expect(CostCalculator.costMicros(TokenUsage(), modelID: "claude-opus-5-5", table: table) == 0)
    }
}
