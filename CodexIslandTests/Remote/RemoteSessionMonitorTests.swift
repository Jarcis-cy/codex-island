import XCTest
@testable import Codex_Island

@MainActor
final class RemoteSessionMonitorTests: XCTestCase {
    func testStartThreadRecoversNewThreadAfterTimeout() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let recoveredThread = makeThread(id: "thread-new", preview: "Recovered")

        connection.startThreadHandler = { _ in
            throw RemoteSessionError.timeout("Timed out waiting for app-server response to thread/start")
        }
        connection.refreshThreadsHandler = {
            await connection.emit?(.threadUpsert(hostId: host.id, thread: recoveredThread))
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        let recovered = try await monitor.startThread(hostId: host.id)

        XCTAssertEqual(recovered.threadId, "thread-new")
        XCTAssertNil(monitor.hostActionErrors[host.id])
    }

    func testSendMessageAddsOptimisticUserItemOnTimeout() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let baseThread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        connection.startThreadHandler = { _ in makeThreadStartResponse(thread: baseThread) }
        connection.sendMessageHandler = { _, _, _, _ in
            throw RemoteSessionError.timeout("Timed out waiting for app-server response to turn/start")
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadUpsert(hostId: host.id, thread: baseThread))
        let thread = try XCTUnwrap(monitor.threads.first)

        try await monitor.sendMessage(thread: thread, text: "hi")

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(updated.history.last?.type, .user("hi"))
        XCTAssertEqual(updated.phase, .processing)
    }

    func testSendMessageMergesOptimisticUserItemWhenServerUserMessageArrives() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let baseThread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        connection.startThreadHandler = { _ in makeThreadStartResponse(thread: baseThread) }
        connection.sendMessageHandler = { _, _, _, _ in }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadUpsert(hostId: host.id, thread: baseThread))
        let thread = try XCTUnwrap(monitor.threads.first)

        try await monitor.sendMessage(thread: thread, text: "hi")
        monitor.apply(event: .itemStarted(
            hostId: host.id,
            threadId: "thread-1",
            turnId: "turn-1",
            item: .userMessage(id: "server-user-1", content: [.text("hi")])
        ))

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(updated.history.count, 1)
        XCTAssertEqual(updated.history.first?.id, "server-user-1")
        XCTAssertEqual(updated.history.first?.type, .user("hi"))
    }

    func testSendMessageRemovesOptimisticUserItemOnFailure() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let baseThread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        connection.sendMessageHandler = { _, _, _, _ in
            throw RemoteSessionError.transport("boom")
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadUpsert(hostId: host.id, thread: baseThread))
        let thread = try XCTUnwrap(monitor.threads.first)

        do {
            try await monitor.sendMessage(thread: thread, text: "hi")
            XCTFail("Expected sendMessage to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "boom")
        }

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertTrue(updated.history.isEmpty)
    }

    func testTurnPlanUpdatedAddsTodoWriteHistoryItem() throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let thread = makeThread(id: "thread-1", preview: "Preview", status: .idle)

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.apply(event: .threadUpsert(hostId: host.id, thread: thread))
        monitor.apply(event: .turnPlanUpdated(
            hostId: host.id,
            threadId: "thread-1",
            turnId: "turn-1",
            explanation: "Syncing plan",
            plan: [
                RemoteAppServerPlanStep(step: "Inspect remote state", status: "completed"),
                RemoteAppServerPlanStep(step: "Patch UI", status: "in_progress")
            ]
        ))

        let updated = try XCTUnwrap(monitor.threads.first)
        guard case .toolCall(let tool)? = updated.history.last?.type else {
            return XCTFail("Expected plan update tool call")
        }

        XCTAssertEqual(tool.name, "TodoWrite")
        XCTAssertEqual(tool.result, "Syncing plan\n- [completed] Inspect remote state\n- [in_progress] Patch UI")
        XCTAssertEqual(
            tool.structuredResult,
            .todoWrite(TodoWriteResult(
                oldTodos: [],
                newTodos: [
                    TodoItem(content: "Inspect remote state", status: "completed", activeForm: nil),
                    TodoItem(content: "Patch UI", status: "in_progress", activeForm: nil)
                ]
            ))
        )
    }

    func testApprovalEventSetsPendingApprovalState() throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let thread = makeThread(id: "thread-1", preview: "Preview", status: .idle)
        let approval = RemotePendingApproval(
            id: "approval-1",
            requestId: .int(1),
            kind: .commandExecution,
            itemId: "item-1",
            threadId: "thread-1",
            turnId: "turn-1",
            title: "Command Execution",
            detail: "pwd",
            requestedPermissions: .none,
            availableActions: [.allow, .cancel]
        )

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.apply(event: .threadUpsert(hostId: host.id, thread: thread))
        monitor.apply(event: .approval(hostId: host.id, threadId: "thread-1", approval: approval))

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(updated.pendingApproval?.id, "approval-1")
        XCTAssertEqual(updated.phase.approvalToolName, "Command Execution")
        XCTAssertEqual(updated.pendingToolInput, "pwd")
    }

    func testUserInputRequestSetsPendingInteractionState() throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let thread = makeThread(id: "thread-1", preview: "Preview", status: .idle)
        let interaction = PendingUserInputInteraction(
            id: "item-1",
            title: "Codex needs your input",
            questions: [
                PendingInteractionQuestion(
                    id: "scope",
                    header: "Scope",
                    question: "Choose one",
                    options: [PendingInteractionOption(label: "One", description: nil)],
                    isOther: false,
                    isSecret: false
                )
            ],
            transport: .remoteAppServer(requestId: .int(7))
        )

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.apply(event: .threadUpsert(hostId: host.id, thread: thread))
        monitor.apply(event: .userInputRequest(hostId: host.id, threadId: "thread-1", interaction: interaction))

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertEqual(updated.pendingInteractions.count, 1)
        XCTAssertEqual(updated.primaryPendingInteraction?.id, "item-1")
        XCTAssertTrue(updated.needsAttention)
    }

    func testServerRequestResolvedClearsPendingInteractionState() throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let thread = makeThread(id: "thread-1", preview: "Preview", status: .idle)
        let interaction = PendingUserInputInteraction(
            id: "item-1",
            title: "Codex needs your input",
            questions: [
                PendingInteractionQuestion(
                    id: "scope",
                    header: "Scope",
                    question: "Choose one",
                    options: [PendingInteractionOption(label: "One", description: nil)],
                    isOther: false,
                    isSecret: false
                )
            ],
            transport: .remoteAppServer(requestId: .int(7))
        )

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.apply(event: .threadUpsert(hostId: host.id, thread: thread))
        monitor.apply(event: .userInputRequest(hostId: host.id, threadId: "thread-1", interaction: interaction))
        monitor.apply(event: .serverRequestResolved(hostId: host.id, threadId: "thread-1", requestId: .int(7)))

        let updated = try XCTUnwrap(monitor.threads.first)
        XCTAssertTrue(updated.pendingInteractions.isEmpty)
    }

    func testThreadListCollapsesSameSSHAndCwdToLatestThread() {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let olderThread = makeThread(id: "thread-1", preview: "Older", cwd: "/repo")
        let newerThread = RemoteAppServerThread(
            id: "thread-2",
            preview: "Newer",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_200,
            updatedAt: 1_700_000_300,
            status: .idle,
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: []
        )

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.apply(event: .threadList(hostId: host.id, threads: [olderThread, newerThread]))

        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-2")
        XCTAssertEqual(monitor.threads.first?.logicalSessionId, "remote|ssh-target|/repo")
    }

    func testThreadListFiltersThreadsToConfiguredDefaultCwd() {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let matchingThread = makeThread(id: "thread-1", preview: "Repo", cwd: "/repo")
        let otherThread = makeThread(id: "thread-2", preview: "Other", cwd: "/other")

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadList(hostId: host.id, threads: [matchingThread, otherThread]))

        XCTAssertEqual(monitor.threads.count, 1)
        XCTAssertEqual(monitor.threads.first?.threadId, "thread-1")
        XCTAssertEqual(monitor.threads.first?.cwd, "/repo")
    }

    func testThreadListKeepsAllThreadsWhenDefaultCwdIsEmpty() {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "", isEnabled: true)
        let firstThread = makeThread(id: "thread-1", preview: "Repo", cwd: "/repo")
        let secondThread = makeThread(id: "thread-2", preview: "Other", cwd: "/other")

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadList(hostId: host.id, threads: [firstThread, secondThread]))

        XCTAssertEqual(monitor.threads.count, 2)
        XCTAssertEqual(Set(monitor.threads.map(\.threadId)), Set(["thread-1", "thread-2"]))
    }

    func testStartThreadReturnsExistingLogicalSessionForSameCwd() async throws {
        final class CallTracker: @unchecked Sendable {
            var didCallStart = false
        }

        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let existingThread = makeThread(id: "thread-existing", preview: "Existing", cwd: "/repo")
        let tracker = CallTracker()

        connection.startThreadHandler = { _ in
            tracker.didCallStart = true
            return makeThreadStartResponse(thread: makeThread(id: "thread-new", preview: "New", cwd: "/repo"))
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadUpsert(hostId: host.id, thread: existingThread))

        let opened = try await monitor.startThread(hostId: host.id)

        XCTAssertFalse(tracker.didCallStart)
        XCTAssertEqual(opened.threadId, "thread-existing")
        XCTAssertEqual(monitor.threads.count, 1)
    }

    func testCreateThreadOpensExistingLogicalSessionBeforeCallback() async throws {
        let logger = TestDiagnosticsLogger()
        let connection = FakeRemoteConnection()
        let host = RemoteHostConfig(id: "host-1", name: "Remote", sshTarget: "ssh-target", defaultCwd: "/repo", isEnabled: true)
        let existingThread = makeThread(id: "thread-existing", preview: "Existing", cwd: "/repo")
        let resumedThread = RemoteAppServerThread(
            id: "thread-existing",
            preview: "Existing",
            ephemeral: false,
            modelProvider: "openai",
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_100,
            status: .idle,
            path: nil,
            cwd: "/repo",
            cliVersion: "1.0.0",
            name: nil,
            turns: [
                RemoteAppServerTurn(
                    id: "turn-1",
                    items: [.userMessage(id: "user-1", content: [.text("hello")])],
                    status: .completed,
                    error: nil
                )
            ]
        )

        connection.resumeThreadHandler = { _, _ in
            makeThreadResumeResponse(thread: resumedThread)
        }

        let monitor = RemoteSessionMonitor(
            initialHosts: [host],
            loadHosts: { [host] in [host] },
            saveHosts: { _ in },
            diagnosticsLogger: logger,
            connectionFactory: { _, emit in
                connection.emit = emit
                return connection
            }
        )
        TestObjectRetainer.retain(monitor)

        monitor.startMonitoring()
        monitor.apply(event: .threadUpsert(hostId: host.id, thread: existingThread))

        let callbackThread = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteThreadState, Error>) in
            monitor.createThread(hostId: host.id) { thread in
                continuation.resume(returning: thread)
            }
        }

        XCTAssertEqual(callbackThread.threadId, "thread-existing")
        XCTAssertEqual(callbackThread.history.count, 1)
        XCTAssertEqual(callbackThread.history.first?.type, .user("hello"))
    }

}
