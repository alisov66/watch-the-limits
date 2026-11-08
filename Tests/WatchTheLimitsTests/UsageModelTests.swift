import XCTest
import UsageCore
@testable import WatchTheLimits

private actor ScriptedUsageService: CodexUsageService {
    var fails = false
    var consumesBeforeTimeout = false
    private var consumed = false
    private(set) var calls: [(String, String)] = []
    private(set) var events: [String] = []

    func setFailure(timeoutAfterConsuming: Bool = false) {
        fails = true
        consumesBeforeTimeout = timeoutAfterConsuming
    }

    func readLimits(executablePath: String) async throws -> UsageSnapshot {
        events.append("read")
        let reset = Date().addingTimeInterval(7200).timeIntervalSince1970
        let row = """
        {"id":"second","resetType":"codexRateLimits","status":"available","grantedAt":0}
        """
        let rows = consumed ? row : row.replacingOccurrences(of: "second", with: "first") + "," + row
        return try JSONDecoder().decode(UsageSnapshot.self, from: Data("""
        {"accountId":"synthetic-account","rateLimits":{"limitId":"codex","planType":"plus",
        "primary":{"usedPercent":\(consumed ? 0 : 50),"windowDurationMins":300,"resetsAt":\(reset)},
        "secondary":{"usedPercent":\(consumed ? 0 : 50),"windowDurationMins":10080,"resetsAt":\(reset + 86400)}},
        "rateLimitResetCredits":{"availableCount":\(consumed ? 1 : 2),"credits":[\(rows)]}}
        """.utf8))
    }

    func consumeReset(executablePath: String, creditID: String, idempotencyKey: String) async throws -> ResetOutcome {
        calls.append((creditID, idempotencyKey))
        events.append("consume")
        try await Task.sleep(nanoseconds: 80_000_000)
        if consumesBeforeTimeout { consumed = true; throw CodexError.timeout }
        if fails { throw CodexError.service("Synthetic failure") }
        consumed = true
        return .reset
    }

    func shutdown() {}
}

@MainActor
final class UsageModelTests: XCTestCase {
    private func preferences() -> UserDefaults {
        let suite = "WatchTheLimitsTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set("/usr/bin/true", forKey: "codexPath")
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        return preferences
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Model did not reach the expected state")
    }

    private func loaded(_ service: ScriptedUsageService, preferences: UserDefaults? = nil) async throws -> UsageModel {
        let model = UsageModel(client: service, preferences: preferences ?? self.preferences())
        model.refresh()
        try await waitUntil { model.lastUpdated != nil && !model.isRefreshing }
        model.panelDidOpen()
        model.showAvailableResets = true
        return model
    }

    func testIndependentSectionsStartCollapsedAndPersistAcrossModelRecreation() async {
        let preferences = preferences()
        let service = ScriptedUsageService()
        let first = UsageModel(client: service, preferences: preferences)
        XCTAssertFalse(first.showSettings)
        XCTAssertFalse(first.showAvailableResets)
        first.showSettings = true
        first.showAvailableResets = true
        first.showSettings = false
        let restarted = UsageModel(client: service, preferences: preferences)
        XCTAssertFalse(restarted.showSettings)
        XCTAssertTrue(restarted.showAvailableResets)
        await first.shutdown()
        await restarted.shutdown()
    }

    func testSubmittedResetFinishesAfterPanelClosesAndRefreshesAuthoritativeData() async throws {
        let service = ScriptedUsageService()
        let model = try await loaded(service)
        let credit = try XCTUnwrap(model.resetCredits.first)
        model.activateReset(credit)
        XCTAssertEqual(model.resetInteraction.confirmationID, credit.id)
        let beforeConfirmation = await service.calls
        XCTAssertTrue(beforeConfirmation.isEmpty)
        model.activateReset(credit)
        XCTAssertTrue(model.hasPendingReset)
        XCTAssertFalse(model.canUseReset(model.resetCredits[1]))
        model.panelDidClose()
        model.showAvailableResets = false
        XCTAssertNotNil(model.resetInteraction.processing)
        try await waitUntil { !model.hasPendingReset }
        XCTAssertEqual(model.resetSummary?.count, 1)
        XCTAssertEqual(model.quotas.first?.remainingPercent(at: model.now), 100)
        XCTAssertEqual(model.indicator.quotas.first?.value, "100%")
        XCTAssertNil(model.resetInteraction.errorID)
        let events = await service.events
        XCTAssertEqual(events, ["read", "consume", "read"])
        await model.shutdown()
    }

    func testErrorLifetimeSwitchingConfirmationAndRetryKey() async throws {
        let service = ScriptedUsageService()
        await service.setFailure()
        let model = try await loaded(service)
        let credit = model.resetCredits[0]
        model.activateReset(credit)
        model.activateReset(credit)
        try await waitUntil { !model.hasPendingReset }
        XCTAssertEqual(model.resetInteraction.errorID, credit.id)
        model.activateReset(model.resetCredits[1])
        XCTAssertEqual(model.resetInteraction.confirmationID, "second")
        model.activateReset(credit)
        XCTAssertEqual(model.resetInteraction.confirmationID, credit.id)
        XCTAssertEqual(model.resetInteraction.errorID, credit.id)
        model.activateReset(credit)
        XCTAssertNil(model.resetInteraction.errorID)
        try await waitUntil { !model.hasPendingReset }
        XCTAssertEqual(model.resetInteraction.errorID, credit.id)
        let calls = await service.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].1, calls[1].1)
        model.showAvailableResets = false
        model.showAvailableResets = true
        XCTAssertNil(model.resetInteraction.errorID)
        model.activateReset(credit)
        model.panelDidClose()
        model.panelDidOpen()
        XCTAssertNil(model.resetInteraction.confirmationID)
        XCTAssertNil(model.resetInteraction.errorID)
        await model.shutdown()
    }

    func testTimeoutReconcilesActualServerConsumption() async throws {
        let service = ScriptedUsageService()
        await service.setFailure(timeoutAfterConsuming: true)
        let model = try await loaded(service)
        let credit = model.resetCredits[0]
        model.activateReset(credit)
        model.activateReset(credit)
        try await waitUntil { !model.hasPendingReset }
        XCTAssertEqual(model.resetSummary?.count, 1)
        XCTAssertEqual(model.resetCredits.map(\.id), ["second"])
        XCTAssertEqual(model.quotas.first?.remainingPercent(at: model.now), 100)
        let events = await service.events
        XCTAssertEqual(events, ["read", "consume", "read"])
        await model.shutdown()
    }
}
