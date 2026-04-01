import XCTest
@testable import Codex_Island

final class RemoteAppServerConnectionTests: XCTestCase {
    func testBackgroundThreadListTimeoutDoesNotEmitFailedState() async throws {
        let transport = TestTransport()
        let logger = TestDiagnosticsLogger()
        let recorder = RemoteEventRecorder()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)

        let connection = RemoteAppServerConnection(
            host: host,
            emit: { event in await recorder.append(event) },
            dependencies: RemoteAppServerConnectionDependencies(
                transportFactory: { _ in transport },
                processExecutor: TestProcessExecutor(),
                diagnosticsLogger: logger,
                requestTimeout: .milliseconds(50),
                initialRefreshDelay: .seconds(60),
                refreshInterval: .seconds(60),
                sleep: { duration in
                    try await Task.sleep(for: duration)
                }
            )
        )

        try await connection.installTransportForTesting(transport)
        await connection.refreshThreadsInBackground(reason: "test")

        let states = await recorder.connectionStates()
        XCTAssertFalse(states.contains { if case .failed = $0 { return true } else { return false } })
        await connection.stop()
    }

    func testQueuedThreadRequestsStillMatchResponsesByID() async throws {
        let transport = TestTransport()
        let logger = TestDiagnosticsLogger()
        let recorder = RemoteEventRecorder()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)

        let connection = RemoteAppServerConnection(
            host: host,
            emit: { event in await recorder.append(event) },
            dependencies: RemoteAppServerConnectionDependencies(
                transportFactory: { _ in transport },
                processExecutor: TestProcessExecutor(),
                diagnosticsLogger: logger,
                requestTimeout: .seconds(1),
                initialRefreshDelay: .seconds(60),
                refreshInterval: .seconds(60),
                sleep: { duration in
                    try await Task.sleep(for: duration)
                }
            )
        )

        try await connection.installTransportForTesting(transport)

        async let startedThread: RemoteAppServerThread = connection.startThread(defaultCwd: "/tmp")
        async let resumedThread: RemoteAppServerThread = connection.resumeThread(threadId: "thread-existing")

        try await waitUntil {
            let lines = await transport.sentLines
            return lines.count == 1 && ((try? Self.method(in: lines[0])) == "thread/start")
        }

        let initialLines = await transport.sentLines
        let startLine = try XCTUnwrap(initialLines.first)
        let startID = try extractID(from: startLine)

        try await transport.emitStdout(
            makeEnvelopeJSON(
                id: startID,
                result: ["thread": threadPayload(id: "thread-new", preview: "New")]
            )
        )

        try await waitUntil {
            let lines = await transport.sentLines
            return lines.count == 2 && ((try? Self.method(in: lines[1])) == "thread/resume")
        }

        let sentLines = await transport.sentLines
        let resumeLine = try XCTUnwrap(sentLines.last)
        let resumeID = try extractID(from: resumeLine)
        try await transport.emitStdout(
            makeEnvelopeJSON(
                id: resumeID,
                result: ["thread": threadPayload(id: "thread-existing", preview: "Existing")]
            )
        )

        let started = try await startedThread
        let resumed = try await resumedThread

        XCTAssertEqual(started.id, "thread-new")
        XCTAssertEqual(resumed.id, "thread-existing")

        await connection.stop()
    }

    func testStopDoesNotEmitFailedState() async throws {
        let transport = TestTransport()
        let logger = TestDiagnosticsLogger()
        let recorder = RemoteEventRecorder()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)

        let connection = RemoteAppServerConnection(
            host: host,
            emit: { event in await recorder.append(event) },
            dependencies: RemoteAppServerConnectionDependencies(
                transportFactory: { _ in transport },
                processExecutor: TestProcessExecutor(),
                diagnosticsLogger: logger,
                requestTimeout: .seconds(1),
                initialRefreshDelay: .seconds(60),
                refreshInterval: .seconds(60),
                sleep: { duration in
                    try await Task.sleep(for: duration)
                }
            )
        )

        try await connection.installTransportForTesting(transport)
        await connection.stop()
        let states = await recorder.connectionStates()
        XCTAssertFalse(states.contains { if case .failed = $0 { return true } else { return false } })
        let stopCount = await transport.stopCount
        XCTAssertEqual(stopCount, 1)
    }

    func testQueuedRequestsWaitForPreviousResponse() async throws {
        let transport = TestTransport()
        let logger = TestDiagnosticsLogger()
        let recorder = RemoteEventRecorder()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)

        let connection = RemoteAppServerConnection(
            host: host,
            emit: { event in await recorder.append(event) },
            dependencies: RemoteAppServerConnectionDependencies(
                transportFactory: { _ in transport },
                processExecutor: TestProcessExecutor(),
                diagnosticsLogger: logger,
                requestTimeout: .seconds(1),
                initialRefreshDelay: .seconds(60),
                refreshInterval: .seconds(60),
                sleep: { duration in
                    try await Task.sleep(for: duration)
                }
            )
        )

        try await connection.installTransportForTesting(transport)

        async let listTask: Void = {
            try await connection.refreshThreads()
        }()
        async let startTask: RemoteAppServerThread = connection.startThread(defaultCwd: "/tmp")

        try await waitUntil {
            let lines = await transport.sentLines
            return lines.count == 1
        }

        let firstSentLines = await transport.sentLines
        let firstLine = try XCTUnwrap(firstSentLines.first)
        XCTAssertEqual(try Self.method(in: firstLine), "thread/list")
        try await transport.emitStdout(
            makeEnvelopeJSON(
                id: try extractID(from: firstLine),
                result: ["data": [], "nextCursor": NSNull()]
            )
        )

        try await waitUntil {
            let lines = await transport.sentLines
            return lines.count == 2
        }

        let secondSentLines = await transport.sentLines
        let secondLine = try XCTUnwrap(secondSentLines.last)
        XCTAssertEqual(try Self.method(in: secondLine), "thread/start")
        try await transport.emitStdout(
            makeEnvelopeJSON(
                id: try extractID(from: secondLine),
                result: ["thread": threadPayload(id: "thread-new", preview: "New")]
            )
        )

        _ = try await listTask
        let started = try await startTask
        XCTAssertEqual(started.id, "thread-new")
        await connection.stop()
    }

    private func extractID(from line: String) throws -> Int {
        let data = Data(line.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["id"] as? Int)
    }

    nonisolated private static func method(in line: String) throws -> String? {
        let data = Data(line.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object["method"] as? String
    }

    private func threadPayload(id: String, preview: String) -> [String: Any] {
        [
            "id": id,
            "preview": preview,
            "ephemeral": false,
            "modelProvider": "openai",
            "createdAt": 1_700_000_000,
            "updatedAt": 1_700_000_100,
            "status": ["type": "idle"],
            "path": NSNull(),
            "cwd": "/tmp",
            "cliVersion": "1.0.0",
            "name": NSNull(),
            "turns": []
        ]
    }
}
