import XCTest
@testable import UsageCore

final class ResetCreditsTests: XCTestCase {
    private func snapshot(_ resetJSON: String? = nil) throws -> UsageSnapshot {
        let field = resetJSON.map { ",\"rateLimitResetCredits\":\($0)" } ?? ""
        return try JSONDecoder().decode(UsageSnapshot.self, from: Data("{\"rateLimits\":{}\(field)}".utf8))
    }

    func testUnknownEmptyAndCountOnlyAvailabilityAreDistinct() throws {
        XCTAssertNil(try snapshot().rateLimitResetCredits)
        XCTAssertNil(try snapshot("null").rateLimitResetCredits)
        let empty = try XCTUnwrap(snapshot("{\"availableCount\":0,\"credits\":[]}").rateLimitResetCredits)
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.credits, [])
        let countOnly = try XCTUnwrap(snapshot("{\"availableCount\":7,\"credits\":null}").rateLimitResetCredits)
        XCTAssertEqual(countOnly.count, 7)
        XCTAssertNil(countOnly.credits)
    }

    func testCreditEligibilityAndExpiration() throws {
        let credit = try JSONDecoder().decode(ResetCredit.self, from: Data("""
        {"id":"credit-1","resetType":"codexRateLimits","status":"available","grantedAt":0,"expiresAt":2000}
        """.utf8))
        XCTAssertTrue(credit.isUsable(at: Date(timeIntervalSince1970: 1999)))
        XCTAssertFalse(credit.isUsable(at: Date(timeIntervalSince1970: 2000)))
        XCTAssertEqual(credit.displayTitle, "Full reset (Weekly + 5 hr)")
        XCTAssertTrue(credit.expirationText(at: Date(timeIntervalSince1970: 1000), timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US"))!.hasPrefix("Expires "))
        let futureType = try JSONDecoder().decode(ResetCredit.self, from: Data("""
        {"id":"future","resetType":"futureReset","status":"available","grantedAt":0,"title":"Backend title"}
        """.utf8))
        XCTAssertFalse(futureType.isUsable(at: .now))
        XCTAssertEqual(futureType.displayTitle, "Backend title")
        XCTAssertNil(futureType.expirationText(at: .now))
    }

    func testUnsupportedResetMetadataDoesNotDiscardValidUsage() throws {
        let value = try JSONDecoder().decode(UsageSnapshot.self, from: Data("""
        {"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}},
        "rateLimitResetCredits":{"availableCount":"unsupported"}}
        """.utf8))
        XCTAssertEqual(value.remainingPercent(), 75)
        XCTAssertNil(value.rateLimitResetCredits)
        let capped = try snapshot("{\"availableCount\":5,\"credits\":[]}")
        XCTAssertEqual(capped.rateLimitResetCredits?.count, 5)
    }

    func testSelectionMovesAndDoesNotConsumeWithoutConfirmation() {
        var state = ResetInteraction()
        XCTAssertNil(state.begin("first"))
        state.select("first")
        state.select("second")
        XCTAssertEqual(state.confirmationID, "second")
        XCTAssertNil(state.begin("first"))
        XCTAssertNil(state.processing)
        XCTAssertTrue(state.retryKeys.isEmpty)
        state.dismissTransient()
        XCTAssertNil(state.confirmationID)
    }

    func testClosingDoesNotCancelProcessingAndDuplicateSubmissionIsRejected() throws {
        var state = ResetInteraction()
        state.select("first")
        let attempt = try XCTUnwrap(state.begin("first"))
        state.select("second")
        XCTAssertNil(state.confirmationID)
        XCTAssertNil(state.begin("second"))
        state.dismissTransient()
        XCTAssertEqual(state.processing, attempt)
        state.finish(attempt, outcome: .reset, showError: false)
        XCTAssertNil(state.processing)
        XCTAssertNil(state.errorID)
        XCTAssertTrue(state.consumedIDs.contains("first"))
        state.select("first")
        XCTAssertNil(state.begin("first"), "A confirmed consumed credit cannot be spent again from retained data")
    }

    func testErrorPersistsDuringConfirmationAndUnknownRetryReusesKey() throws {
        var state = ResetInteraction()
        state.select("first")
        let first = try XCTUnwrap(state.begin("first"))
        state.finish(first, outcome: nil, showError: true)
        XCTAssertEqual(state.errorID, "first")
        state.select("first")
        XCTAssertEqual(state.errorID, "first")
        let retry = try XCTUnwrap(state.begin("first"))
        XCTAssertNil(state.errorID)
        XCTAssertEqual(retry.idempotencyKey, first.idempotencyKey)
        state.finish(retry, outcome: nil, showError: true)
        XCTAssertEqual(state.errorID, "first")
        state.dismissTransient()
        XCTAssertNil(state.errorID)
        XCTAssertEqual(state.retryKeys["first"], first.idempotencyKey)
    }

    func testRetryKeySurvivesRecreationAndDefiniteRejectionAllowsNewAttempt() throws {
        var firstSession = ResetInteraction()
        firstSession.select("first")
        let first = try XCTUnwrap(firstSession.begin("first"))
        var nextSession = ResetInteraction(retryKeys: firstSession.retryKeys)
        nextSession.select("first")
        let retry = try XCTUnwrap(nextSession.begin("first"))
        XCTAssertEqual(first.idempotencyKey, retry.idempotencyKey)
        nextSession.finish(retry, outcome: .nothingToReset, showError: true)
        nextSession.select("first")
        let newAttempt = try XCTUnwrap(nextSession.begin("first"))
        XCTAssertNotEqual(first.idempotencyKey, newAttempt.idempotencyKey)
    }

    func testBackgroundFailureDoesNotRestoreDismissedError() throws {
        var state = ResetInteraction()
        state.select("first")
        let attempt = try XCTUnwrap(state.begin("first"))
        state.dismissTransient()
        state.finish(attempt, outcome: nil, showError: false)
        XCTAssertNil(state.errorID)
        XCTAssertNotNil(state.retryKeys["first"])
    }

    func testRefreshingDoesNotDismissRowError() throws {
        var state = ResetInteraction()
        state.select("first")
        let attempt = try XCTUnwrap(state.begin("first"))
        state.finish(attempt, outcome: nil, showError: true)
        state.reconcile(try snapshot("{\"availableCount\":2,\"credits\":null}").rateLimitResetCredits)
        XCTAssertEqual(state.errorID, "first")
        XCTAssertTrue(state.consumedIDs.isEmpty)
        XCTAssertTrue(ResetOutcome.alreadyRedeemed.succeeded)
        XCTAssertFalse(ResetOutcome.noCredit.succeeded)
    }
}
