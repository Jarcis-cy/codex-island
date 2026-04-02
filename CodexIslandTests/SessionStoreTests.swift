import XCTest
@testable import Codex_Island

actor SessionStoreTestHelper {
    static let shared = SessionStoreTestHelper()

    func cleanup() async {
        let sessions = await SessionStore.shared.allSessions()
        for session in sessions {
            await SessionStore.shared.process(.sessionEnded(sessionId: session.sessionId))
        }
    }
}

final class SessionStoreTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await SessionStoreTestHelper.shared.cleanup()
    }

    override func tearDown() async throws {
        await SessionStoreTestHelper.shared.cleanup()
        try await super.tearDown()
    }

    func testSameTTYRebindsToLatestSession() async {
        let first = makeHookEvent(sessionId: "session-1", tty: "/dev/ttys001")
        let second = makeHookEvent(sessionId: "session-2", tty: "/dev/ttys001")

        await SessionStore.shared.process(.hookReceived(first))
        let firstLogicalId = await SessionStore.shared.allSessions().first?.logicalSessionId

        await SessionStore.shared.process(.hookReceived(second))
        let sessions = await SessionStore.shared.allSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, "session-2")
        XCTAssertEqual(sessions.first?.logicalSessionId, firstLogicalId)
    }

    func testDifferentTTYsRemainSeparateSessions() async {
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-1", tty: "/dev/ttys001")))
        await SessionStore.shared.process(.hookReceived(makeHookEvent(sessionId: "session-2", tty: "/dev/ttys002")))

        let sessions = await SessionStore.shared.allSessions()

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.sessionId)), ["session-1", "session-2"])
        XCTAssertEqual(Set(sessions.map(\.logicalSessionId)).count, 2)
    }

    func testDifferentPIDsRemainSeparateWhenTTYMissing() async {
        await SessionStore.shared.process(.hookReceived(
            makeHookEvent(sessionId: "session-1", tty: nil, pid: 101)
        ))
        await SessionStore.shared.process(.hookReceived(
            makeHookEvent(sessionId: "session-2", tty: nil, pid: 202)
        ))

        let sessions = await SessionStore.shared.allSessions()

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.sessionId)), ["session-1", "session-2"])
        XCTAssertEqual(Set(sessions.map(\.logicalSessionId)).count, 2)
    }

    func testGhosttyMetadataCollisionFallsBackToTTY() async {
        await SessionStore.shared.process(.hookReceived(
            makeHookEvent(
                sessionId: "session-1",
                tty: "/dev/ttys001",
                pid: 101,
                cwd: "/tmp/project-a",
                terminalName: "ghostty",
                terminalWindowId: "tab-group-1",
                terminalTabId: "tab-1",
                terminalSurfaceId: "surface-1"
            )
        ))
        await SessionStore.shared.process(.hookReceived(
            makeHookEvent(
                sessionId: "session-2",
                tty: "/dev/ttys002",
                pid: 202,
                cwd: "/tmp/project-b",
                terminalName: "ghostty",
                terminalWindowId: "tab-group-1",
                terminalTabId: "tab-1",
                terminalSurfaceId: "surface-1"
            )
        ))

        let sessions = await SessionStore.shared.allSessions()

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.sessionId)), ["session-1", "session-2"])
        XCTAssertEqual(
            Set(sessions.map(\.logicalSessionId)),
            ["local|ghostty|surface|surface-1", "local|ghostty|tty|ttys002"]
        )
    }

    func testGhosttyMissingContextClearsStaleSurfaceIdentifiers() async {
        await SessionStore.shared.process(.hookReceived(
            makeHookEvent(
                sessionId: "session-1",
                tty: "/dev/ttys001",
                pid: 101,
                cwd: "/tmp/project-a",
                terminalName: "ghostty",
                terminalWindowId: "tab-group-1",
                terminalTabId: "tab-1",
                terminalSurfaceId: "surface-1"
            )
        ))
        await SessionStore.shared.process(.hookReceived(
            makeHookEvent(
                sessionId: "session-1",
                tty: "/dev/ttys001",
                pid: 101,
                cwd: "/tmp/project-a",
                terminalName: "ghostty",
                terminalWindowId: nil,
                terminalTabId: nil,
                terminalSurfaceId: nil
            )
        ))

        let session = await SessionStore.shared.allSessions().first

        XCTAssertEqual(session?.logicalSessionId, "local|ghostty|tty|ttys001")
        XCTAssertNil(session?.terminalWindowId)
        XCTAssertNil(session?.terminalTabId)
        XCTAssertNil(session?.terminalSurfaceId)
    }

    private func makeHookEvent(
        sessionId: String,
        tty: String?,
        pid: Int? = nil,
        cwd: String = "/tmp/project",
        terminalName: String = "Apple_Terminal",
        terminalWindowId: String? = nil,
        terminalTabId: String? = nil,
        terminalSurfaceId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: cwd,
            transcriptPath: nil,
            event: "SessionStart",
            status: "waiting_for_input",
            pid: pid,
            tty: tty,
            terminalName: terminalName,
            terminalWindowId: terminalWindowId,
            terminalTabId: terminalTabId,
            terminalSurfaceId: terminalSurfaceId,
            turnId: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )
    }
}
