import Foundation

public struct ModelPrice: Codable, Sendable, Equatable {
    public var prefix: String
    public var input: Double
    public var output: Double
    public var cacheRead: Double
}

public struct PricingTable: Codable, Sendable, Equatable {
    public static let cacheWrite5mMultiplier = 1.25
    public static let cacheWrite1hMultiplier = 2.0
    public static let fastModeMultiplier = 2.0

    public var models: [ModelPrice]
    public var plans: [String: Double]

    public static let builtin: PricingTable = {
        do { return try JSONDecoder().decode(PricingTable.self, from: Data(builtinPricingJSON.utf8)) }
        catch { fatalError("builtin pricing JSON is invalid: \(error)") }
    }()

    /// Highest plausible price in $/MTok; an override beyond this is treated as corrupt.
    static let maxPlausiblePrice = 10_000.0

    var hasValidPrices: Bool {
        models.allSatisfy { m in
            [m.input, m.output, m.cacheRead].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= Self.maxPlausiblePrice }
        }
    }

    /// The override file when it exists, decodes and has sane prices, the bundled table otherwise.
    public static func load(override url: URL?) -> PricingTable {
        guard let url, let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(PricingTable.self, from: data),
              table.hasValidPrices else { return builtin }
        return table
    }

    public func price(for modelID: String) -> ModelPrice? {
        models.filter { modelID.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }
    }

    public func monthlyTotal(for plans: [String]) -> Double {
        plans.compactMap { self.plans[$0] }.reduce(0, +)
    }
}

public struct TokenUsage: Sendable, Equatable {
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite5m: Int64
    public var cacheWrite1h: Int64
    public var isFast: Bool

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite5m: Int64 = 0,
                cacheWrite1h: Int64 = 0, isFast: Bool = false) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.isFast = isFast
    }

    public var totalTokens: Int64 { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
}

public enum CostCalculator {
    /// Cost in micro-dollars (prices are $/MTok, so tokens × price = µ$). Nil when the model is unknown.
    public static func costMicros(_ usage: TokenUsage, modelID: String, table: PricingTable) -> Int64? {
        guard let p = table.price(for: modelID) else { return nil }
        var micros = Double(usage.input) * p.input
            + Double(usage.output) * p.output
            + Double(usage.cacheRead) * p.cacheRead
            + Double(usage.cacheWrite5m) * p.input * PricingTable.cacheWrite5mMultiplier
            + Double(usage.cacheWrite1h) * p.input * PricingTable.cacheWrite1hMultiplier
        if usage.isFast { micros *= PricingTable.fastModeMultiplier }
        guard micros.isFinite else { return 0 }
        // Double(Int64.max) rounds up to 2^63, which Int64(_:) would trap on.
        if micros >= Double(Int64.max) { return .max }
        return Int64(micros.rounded())
    }
}

public enum ModelNames {
    public static func family(_ modelID: String) -> String? {
        let id = modelID.lowercased()
        for family in ["fable", "mythos", "opus", "sonnet", "haiku"] where id.contains(family) {
            return family.prefix(1).uppercased() + family.dropFirst()
        }
        return nil
    }
}
