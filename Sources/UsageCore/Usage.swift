import Foundation

public struct UsageWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: TimeInterval?

    public var remainingPercent: Int {
        Int(max(0, min(100, 100 - usedPercent)).rounded(.down))
    }

    public var title: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "Usage window" }
        if minutes == 10080 { return "Weekly" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }

    public func hasExpired(at date: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= date.timeIntervalSince1970
    }
}

public struct UsageBucket: Decodable, Equatable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let planType: String?

    public var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }
}

public struct UsageSnapshot: Decodable, Sendable {
    public let accountId: String?
    public let rateLimits: UsageBucket?
    public let rateLimitsByLimitId: [String: UsageBucket]?
    public let rateLimitResetCredits: ResetCreditsSummary?

    private enum CodingKeys: String, CodingKey {
        case accountId, rateLimits, rateLimitsByLimitId, rateLimitResetCredits
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try values.decodeIfPresent(String.self, forKey: .accountId)
        rateLimits = try values.decodeIfPresent(UsageBucket.self, forKey: .rateLimits)
        rateLimitsByLimitId = try values.decodeIfPresent([String: UsageBucket].self, forKey: .rateLimitsByLimitId)
        // Optional reset metadata must not make otherwise valid usage unavailable.
        rateLimitResetCredits = try? values.decodeIfPresent(ResetCreditsSummary.self, forKey: .rateLimitResetCredits)
    }

    public struct Entry: Identifiable, Sendable {
        public let id: String
        public let bucket: UsageBucket
        public var title: String {
            if let name = bucket.limitName, !name.isEmpty { return name }
            return id == "codex" ? "Codex" : id
        }
    }

    public var entries: [Entry] {
        if let buckets = rateLimitsByLimitId, !buckets.isEmpty {
            return buckets.keys.sorted {
                if $0 == "codex" { return true }
                if $1 == "codex" { return false }
                return $0 < $1
            }.map { Entry(id: $0, bucket: buckets[$0]!) }
        }
        guard let rateLimits else { return [] }
        return [Entry(id: rateLimits.limitId ?? "codex", bucket: rateLimits)]
    }

    public var windows: [UsageWindow] { entries.flatMap { $0.bucket.windows } }

    public func remainingPercent(at date: Date = Date()) -> Int? {
        // A reset time passing does not prove that the service reset the quota.
        guard !windows.isEmpty, !windows.contains(where: { $0.hasExpired(at: date) }) else { return nil }
        return windows.map(\.remainingPercent).min()
    }

    public static var demo: UsageSnapshot {
        let reset = Date().addingTimeInterval(7200).timeIntervalSince1970
        let json = """
        {"rateLimits":{"limitId":"codex","planType":"plus",
        "primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":\(reset)},
        "secondary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":\(reset + 345600)}}}
        """
        return try! JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    }

    public static var menuBarPreview: UsageSnapshot {
        let reset = Date().addingTimeInterval(7200).timeIntervalSince1970
        let json = """
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":32,"windowDurationMins":300,"resetsAt":\(reset)},
        "secondary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":\(reset + 345600)}}}
        """
        return try! JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    }
}
