import XCTest
@testable import UsageCore

final class CodexClientTests: XCTestCase {
    private func executable(body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ("#!/usr/bin/python3\nimport sys, json\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testHandshakeFragmentedRepliesAndRepeatedReads() async throws {
        let fake = try executable(body: """
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            if request['method'] == 'initialize':
                result = {'userAgent': 'test'}
            elif request['method'] == 'account/rateLimits/read':
                result = {'rateLimits': {'primary': {'usedPercent': 28, 'windowDurationMins': 300}}}
            else:
                sys.exit(1)
            response = json.dumps({'id': request['id'], 'result': result}) + '\\n'
            sys.stdout.write(response[:8]); sys.stdout.flush()
            sys.stdout.write(response[8:]); sys.stdout.flush()
        """)
        let client = CodexClient()
        let first = try await client.readLimits(executablePath: fake.path)
        let second = try await client.readLimits(executablePath: fake.path)
        XCTAssertEqual(first.remainingPercent(), 72)
        XCTAssertEqual(second.remainingPercent(), 72)
        await client.shutdown()
    }

    func testServiceErrorReachesCaller() async throws {
        let fake = try executable(body: """
        for line in sys.stdin:
            r = json.loads(line)
            if 'id' not in r: continue
            response = {'id': r['id'], 'result': {}} if r['method'] == 'initialize' else {'id': r['id'], 'error': {'code': -1, 'message': 'Sign in with ChatGPT'}}
            print(json.dumps(response), flush=True)
        """)
        let client = CodexClient()
        do {
            _ = try await client.readLimits(executablePath: fake.path)
            XCTFail("Expected a service error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Sign in with ChatGPT")
        }
        await client.shutdown()
    }

    func testUnexpectedExitFailsPendingRequest() async throws {
        let fake = try executable(body: "sys.exit(0)\n")
        let client = CodexClient()
        do {
            _ = try await client.readLimits(executablePath: fake.path)
            XCTFail("Expected a disconnected error")
        } catch {
            XCTAssertTrue(error is CodexError)
        }
        await client.shutdown()
    }

    func testResetUsesSelectedCreditAndIdempotencyKeyWithoutOtherMethods() async throws {
        let fake = try executable(body: """
        keys = set()
        for line in sys.stdin:
            r = json.loads(line)
            if 'id' not in r: continue
            if r['method'] == 'initialize': result = {}
            elif r['method'] == 'account/rateLimitResetCredit/consume':
                p = r['params']
                assert p['creditId'] == 'selected-credit'
                assert p['idempotencyKey'] == 'same-logical-attempt'
                result = {'outcome': 'alreadyRedeemed' if p['idempotencyKey'] in keys else 'reset'}
                keys.add(p['idempotencyKey'])
            elif r['method'] == 'account/rateLimits/read':
                result = {'rateLimits': {}, 'rateLimitResetCredits': {'availableCount': 0, 'credits': []}}
            else: sys.exit(1)
            print(json.dumps({'id': r['id'], 'result': result}), flush=True)
        """)
        let client = CodexClient()
        let first = try await client.consumeReset(executablePath: fake.path, creditID: "selected-credit", idempotencyKey: "same-logical-attempt")
        let retry = try await client.consumeReset(executablePath: fake.path, creditID: "selected-credit", idempotencyKey: "same-logical-attempt")
        XCTAssertEqual(first, .reset)
        XCTAssertEqual(retry, .alreadyRedeemed)
        let refreshed = try await client.readLimits(executablePath: fake.path)
        XCTAssertEqual(refreshed.rateLimitResetCredits?.count, 0)
        await client.shutdown()
    }
}
