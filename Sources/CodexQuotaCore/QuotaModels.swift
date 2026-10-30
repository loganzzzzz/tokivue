import Foundation

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let fetchedAt: Date
    public let buckets: [QuotaBucket]
    public let resetCreditsAvailable: Int?

    public init(
        fetchedAt: Date,
        buckets: [QuotaBucket],
        resetCreditsAvailable: Int?
    ) {
        self.fetchedAt = fetchedAt
        self.buckets = buckets
        self.resetCreditsAvailable = resetCreditsAvailable
    }

    public var mainBucket: QuotaBucket? {
        buckets.first(where: { $0.id == "codex" }) ?? buckets.first
    }

    public var statusBarRemainingPercent: Double? {
        if let mainBucket {
            if mainBucket.isBlocked { return 0 }
            let mainValues = mainBucket.windows.map(\.remainingPercent)
                + [mainBucket.individualLimit?.clampedRemainingPercent].compactMap { $0 }
            return mainValues.min()
        }

        if buckets.contains(where: \.isBlocked) { return 0 }
        let allValues = buckets.flatMap { bucket in
            bucket.windows.map(\.remainingPercent)
                + [bucket.individualLimit?.clampedRemainingPercent].compactMap { $0 }
        }
        return allValues.min()
    }
}

public struct QuotaBucket: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let windows: [QuotaWindow]
    public let planType: String?
    public let credits: CreditBalance?
    public let individualLimit: SpendControlLimit?
    public let rateLimitReachedType: String?
    public let spendControlReached: Bool?

    public init(
        id: String,
        name: String?,
        windows: [QuotaWindow],
        planType: String?,
        credits: CreditBalance?,
        individualLimit: SpendControlLimit?,
        rateLimitReachedType: String?,
        spendControlReached: Bool?
    ) {
        self.id = id
        self.name = name
        self.windows = windows
        self.planType = planType
        self.credits = credits
        self.individualLimit = individualLimit
        self.rateLimitReachedType = rateLimitReachedType
        self.spendControlReached = spendControlReached
    }

    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return id == "codex" ? "Codex" : id
    }

    public var isBlocked: Bool {
        rateLimitReachedType != nil || spendControlReached == true
    }

    public func window(durationMinutes: Int) -> QuotaWindow? {
        windows.first(where: { $0.durationMinutes == durationMinutes })
    }
}

public struct SpendControlLimit: Codable, Equatable, Sendable {
    public let limit: String?
    public let used: String?
    public let remainingPercent: Double
    public let resetsAt: Date?

    public init(
        limit: String?,
        used: String?,
        remainingPercent: Double,
        resetsAt: Date?
    ) {
        self.limit = limit
        self.used = used
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }

    public var clampedRemainingPercent: Double {
        min(100, max(0, remainingPercent))
    }
}

public struct QuotaWindow: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case primary
        case secondary
    }

    public let kind: Kind
    public let usedPercent: Double
    public let durationMinutes: Int?
    public let resetsAt: Date?

    public init(
        kind: Kind,
        usedPercent: Double,
        durationMinutes: Int?,
        resetsAt: Date?
    ) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

public struct CreditBalance: Codable, Equatable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: String?

    public init(hasCredits: Bool?, unlimited: Bool?, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public enum QuotaFormatting {
    public static func durationLabel(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "未标明时长" }
        switch minutes {
        case 300:
            return "5 小时"
        case 10_080:
            return "7 天"
        default:
            if minutes > 0, minutes.isMultiple(of: 1_440) {
                return "\(minutes / 1_440) 天"
            }
            if minutes > 0, minutes.isMultiple(of: 60) {
                return "\(minutes / 60) 小时"
            }
            return "\(minutes) 分钟"
        }
    }

    public static func percent(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", value)
    }
}
