import Foundation

/// One day of usage for a single deployment, parsed from Azure Monitor
/// dimension-filtered metrics.
public struct FoundryDailyBucket: Sendable, Codable, Equatable {
    public let date: Date
    public let deployment: String
    public let inputTokens: Double
    public let outputTokens: Double
    public let modelRequests: Double

    public init(date: Date, deployment: String, inputTokens: Double, outputTokens: Double, modelRequests: Double) {
        self.date = date
        self.deployment = deployment
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.modelRequests = modelRequests
    }

    public var totalTokens: Double { self.inputTokens + self.outputTokens }
}

/// Totals over a window for the Foundry card.
public struct FoundryWindowTotals: Sendable, Codable, Equatable {
    public let inputTokens: Double
    public let outputTokens: Double
    public let modelRequests: Double

    public init(inputTokens: Double = 0, outputTokens: Double = 0, modelRequests: Double = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.modelRequests = modelRequests
    }

    public var totalTokens: Double { self.inputTokens + self.outputTokens }

    public static let zero = FoundryWindowTotals()

    public static func + (lhs: FoundryWindowTotals, rhs: FoundryWindowTotals) -> FoundryWindowTotals {
        FoundryWindowTotals(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            modelRequests: lhs.modelRequests + rhs.modelRequests)
    }
}

/// Aggregated view across today / week / month + per-deployment MTD totals.
public struct FoundryUsageRollup: Sendable, Codable, Equatable {
    public let today: FoundryWindowTotals
    public let week: FoundryWindowTotals
    public let month: FoundryWindowTotals
    public let perDeploymentMTD: [String: FoundryWindowTotals]
    public let monthResetAt: Date
    public let updatedAt: Date

    public init(
        today: FoundryWindowTotals,
        week: FoundryWindowTotals,
        month: FoundryWindowTotals,
        perDeploymentMTD: [String: FoundryWindowTotals],
        monthResetAt: Date,
        updatedAt: Date)
    {
        self.today = today
        self.week = week
        self.month = month
        self.perDeploymentMTD = perDeploymentMTD
        self.monthResetAt = monthResetAt
        self.updatedAt = updatedAt
    }

    /// Builds a rollup from raw daily buckets.
    public static func from(
        buckets: [FoundryDailyBucket],
        now: Date,
        monthResetAt: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)) -> FoundryUsageRollup
    {
        var cal = calendar
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let startOfToday = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startOfToday

        var today = FoundryWindowTotals.zero
        var week = FoundryWindowTotals.zero
        var month = FoundryWindowTotals.zero
        var perDeployment: [String: FoundryWindowTotals] = [:]

        for bucket in buckets {
            let totals = FoundryWindowTotals(
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                modelRequests: bucket.modelRequests)
            if bucket.date >= startOfToday {
                today = today + totals
            }
            if bucket.date >= weekStart {
                week = week + totals
            }
            if bucket.date >= monthStart {
                month = month + totals
                let existing = perDeployment[bucket.deployment] ?? .zero
                perDeployment[bucket.deployment] = existing + totals
            }
        }

        return FoundryUsageRollup(
            today: today,
            week: week,
            month: month,
            perDeploymentMTD: perDeployment,
            monthResetAt: monthResetAt,
            updatedAt: now)
    }
}
