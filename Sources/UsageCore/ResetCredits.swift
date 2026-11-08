import Foundation

/// Optional service data: a missing summary is different from a known zero balance.
public struct ResetCreditsSummary: Decodable, Equatable, Sendable {
    public let availableCount: Int
    public let credits: [ResetCredit]?

    public var count: Int { max(0, availableCount) }
}

public struct ResetCredit: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: TimeInterval
    public let expiresAt: TimeInterval?
    public let title: String?
    public let description: String?

    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return resetType == "codexRateLimits" ? "Full reset (Weekly + 5 hr)" : "Usage reset"
    }

    public func isUsable(at date: Date) -> Bool {
        !id.isEmpty && resetType == "codexRateLimits" && status == "available"
            && (expiresAt.map { $0 > date.timeIntervalSince1970 } ?? true)
    }

    public func expirationText(at date: Date, timeZone: TimeZone = .autoupdatingCurrent,
                               locale: Locale = .autoupdatingCurrent) -> String? {
        guard let expiresAt else { return nil }
        let expiration = Date(timeIntervalSince1970: expiresAt)
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.component(.year, from: expiration) == calendar.component(.year, from: date)
                ? "MMMdjm" : "yMMMdjm")
        return "Expires " + formatter.string(from: expiration) + " "
            + (timeZone.abbreviation(for: expiration) ?? timeZone.identifier)
    }
}

public enum ResetOutcome: String, Decodable, Sendable {
    case reset, alreadyRedeemed, nothingToReset, noCredit

    public var succeeded: Bool { self == .reset || self == .alreadyRedeemed }
}

public struct ResetResponse: Decodable, Sendable {
    public let outcome: ResetOutcome
}

public protocol CodexUsageService: Sendable {
    func readLimits(executablePath: String) async throws -> UsageSnapshot
    func consumeReset(executablePath: String, creditID: String, idempotencyKey: String) async throws -> ResetOutcome
    func shutdown() async
}

/// Transient presentation is separate from the idempotency keys retained for retries.
public struct ResetInteraction: Sendable {
    public struct Attempt: Equatable, Sendable {
        public let creditID: String
        public let idempotencyKey: String
    }

    public private(set) var confirmationID: String?
    public private(set) var processing: Attempt?
    public private(set) var errorID: String?
    public private(set) var retryKeys: [String: String]
    public private(set) var consumedIDs: Set<String> = []

    public init(retryKeys: [String: String] = [:]) { self.retryKeys = retryKeys }

    public mutating func select(_ id: String) {
        guard processing == nil else { return }
        confirmationID = id
    }

    public mutating func begin(_ id: String) -> Attempt? {
        guard processing == nil, confirmationID == id, !consumedIDs.contains(id) else { return nil }
        let attempt = Attempt(creditID: id, idempotencyKey: retryKeys[id] ?? UUID().uuidString)
        retryKeys[id] = attempt.idempotencyKey
        confirmationID = nil
        errorID = nil
        processing = attempt
        return attempt
    }

    public mutating func finish(_ attempt: Attempt, outcome: ResetOutcome?, showError: Bool) {
        guard processing == attempt else { return }
        processing = nil
        if outcome?.succeeded == true {
            consumedIDs.insert(attempt.creditID)
        } else {
            errorID = showError ? attempt.creditID : nil
            // A definite rejection consumed nothing. Unknown outcomes retain the SAME key.
            if outcome != nil { retryKeys.removeValue(forKey: attempt.creditID) }
        }
    }

    public mutating func dismissTransient() {
        confirmationID = nil
        errorID = nil
        // A submitted request and its retry key survive closing/collapsing.
    }

    public mutating func reconcile(_ summary: ResetCreditsSummary?) {
        guard let summary else { return }
        // A zero count is authoritative; a capped/absent detail list is not a full inventory.
        if summary.count == 0 {
            confirmationID = nil
        } else if let id = confirmationID,
                  summary.credits?.contains(where: { $0.id == id && $0.status == "available" }) == false {
            confirmationID = nil
        }
    }
}
