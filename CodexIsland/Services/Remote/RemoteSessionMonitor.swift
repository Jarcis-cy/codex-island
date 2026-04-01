//
//  RemoteSessionMonitor.swift
//  CodexIsland
//
//  SSH-managed app-server client for remote thread listing and interaction.
//

import Combine
import Foundation

enum RemoteConnectionEvent: Sendable {
    case connectionState(hostId: String, state: RemoteHostConnectionState)
    case threadList(hostId: String, threads: [RemoteAppServerThread])
    case threadUpsert(hostId: String, thread: RemoteAppServerThread)
    case threadStatusChanged(hostId: String, threadId: String, status: RemoteAppServerThreadStatus)
    case turnStarted(hostId: String, threadId: String, turn: RemoteAppServerTurn)
    case turnCompleted(hostId: String, threadId: String, turn: RemoteAppServerTurn)
    case itemStarted(hostId: String, threadId: String, turnId: String, item: RemoteAppServerThreadItem)
    case itemCompleted(hostId: String, threadId: String, turnId: String, item: RemoteAppServerThreadItem)
    case agentMessageDelta(hostId: String, threadId: String, turnId: String, itemId: String, delta: String)
    case approval(hostId: String, threadId: String, approval: RemotePendingApproval)
}

enum RemoteSessionError: LocalizedError {
    case notConnected
    case missingThread
    case invalidConfiguration(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Remote host is not connected"
        case .missingThread:
            return "Remote thread not found"
        case .invalidConfiguration(let message), .transport(let message):
            return message
        }
    }
}

@MainActor
final class RemoteSessionMonitor: ObservableObject {
    static let shared = RemoteSessionMonitor()

    @Published private(set) var hosts: [RemoteHostConfig]
    @Published private(set) var threads: [RemoteThreadState] = []
    @Published private(set) var hostStates: [String: RemoteHostConnectionState] = [:]
    @Published private(set) var hostActionErrors: [String: String] = [:]

    private var connections: [String: RemoteAppServerConnection] = [:]

    private init() {
        self.hosts = AppSettings.remoteHosts
    }

    func startMonitoring() {
        syncConnections()
    }

    func addHost() {
        hosts.append(RemoteHostConfig())
        persistHosts()
    }

    func updateHost(_ host: RemoteHostConfig) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let previous = hosts[index]
        hosts[index] = host
        AppSettings.remoteHosts = hosts

        let connectionState = hostStates[host.id] ?? .disconnected
        let shouldSync = previous.isEnabled != host.isEnabled || !connectionState.isConnected
        if shouldSync {
            syncConnections()
        }
    }

    func removeHost(id: String) {
        hosts.removeAll { $0.id == id }
        hostStates.removeValue(forKey: id)
        threads.removeAll { $0.hostId == id }
        if let connection = connections.removeValue(forKey: id) {
            Task { await connection.stop() }
        }
        persistHosts()
    }

    func connectHost(id: String) {
        guard let host = hosts.first(where: { $0.id == id }) else { return }
        hostActionErrors.removeValue(forKey: id)
        if !host.isEnabled {
            var updated = host
            updated.isEnabled = true
            updateHost(updated)
            return
        }
        syncConnections()
    }

    func disconnectHost(id: String) {
        hostStates[id] = .disconnected
        hostActionErrors.removeValue(forKey: id)
        if let connection = connections.removeValue(forKey: id) {
            Task { await connection.stop() }
        }
    }

    func startThread(hostId: String) async throws -> RemoteThreadState {
        guard let host = hosts.first(where: { $0.id == hostId }) else {
            throw RemoteSessionError.invalidConfiguration("Remote host no longer exists")
        }
        guard let connection = connections[hostId] else {
            throw RemoteSessionError.notConnected
        }

        do {
            let thread = try await connection.startThread(defaultCwd: host.defaultCwd)
            hostActionErrors.removeValue(forKey: hostId)
            apply(event: .threadUpsert(hostId: hostId, thread: thread))
            guard let state = threads.first(where: { $0.hostId == hostId && $0.threadId == thread.id }) else {
                throw RemoteSessionError.missingThread
            }
            return state
        } catch {
            hostActionErrors[hostId] = error.localizedDescription
            throw error
        }
    }

    func openThread(hostId: String, threadId: String) async throws -> RemoteThreadState {
        guard let connection = connections[hostId] else {
            throw RemoteSessionError.notConnected
        }

        do {
            let thread = try await connection.resumeThread(threadId: threadId)
            hostActionErrors.removeValue(forKey: hostId)
            apply(event: .threadUpsert(hostId: hostId, thread: thread))
            guard let state = threads.first(where: { $0.hostId == hostId && $0.threadId == thread.id }) else {
                throw RemoteSessionError.missingThread
            }
            return state
        } catch {
            hostActionErrors[hostId] = error.localizedDescription
            throw error
        }
    }

    func sendMessage(thread: RemoteThreadState, text: String) async throws {
        guard let connection = connections[thread.hostId] else {
            throw RemoteSessionError.notConnected
        }
        try await connection.sendMessage(
            threadId: thread.threadId,
            text: text,
            activeTurnId: thread.canSteerTurn ? thread.activeTurnId : nil
        )
    }

    func interrupt(thread: RemoteThreadState) async throws {
        guard let connection = connections[thread.hostId] else {
            throw RemoteSessionError.notConnected
        }
        guard let activeTurnId = thread.activeTurnId else {
            return
        }
        try await connection.interrupt(threadId: thread.threadId, turnId: activeTurnId)
    }

    func approve(thread: RemoteThreadState) async throws {
        guard let approval = thread.pendingApproval else { return }
        guard let connection = connections[thread.hostId] else {
            throw RemoteSessionError.notConnected
        }

        try await connection.respond(to: approval, allow: true)
        clearPendingApproval(hostId: thread.hostId, threadId: thread.threadId, itemId: approval.itemId)
    }

    func deny(thread: RemoteThreadState) async throws {
        guard let approval = thread.pendingApproval else { return }
        guard let connection = connections[thread.hostId] else {
            throw RemoteSessionError.notConnected
        }

        try await connection.respond(to: approval, allow: false)
        clearPendingApproval(hostId: thread.hostId, threadId: thread.threadId, itemId: approval.itemId)
    }

    private func persistHosts() {
        AppSettings.remoteHosts = hosts
        syncConnections()
    }

    private func syncConnections() {
        let enabledHosts = Dictionary(
            uniqueKeysWithValues: hosts.filter(\.isEnabled).map { ($0.id, $0) }
        )

        for (id, connection) in connections where enabledHosts[id] == nil {
            Task { await connection.stop() }
            connections.removeValue(forKey: id)
            hostStates[id] = .disconnected
        }

        for (id, host) in enabledHosts {
            if let connection = connections[id] {
                Task { await connection.updateHost(host) }
            } else {
                let connection = RemoteAppServerConnection(host: host) { event in
                    await MainActor.run {
                        RemoteSessionMonitor.shared.apply(event: event)
                    }
                }
                connections[id] = connection
                Task { await connection.start() }
            }
        }
    }

    private func apply(event: RemoteConnectionEvent) {
        switch event {
        case .connectionState(let hostId, let state):
            hostStates[hostId] = state
            for index in threads.indices where threads[index].hostId == hostId {
                threads[index].connectionState = state
            }

        case .threadList(let hostId, let remoteThreads):
            let ids = Set(remoteThreads.map(\.id))
            threads.removeAll { $0.hostId == hostId && !ids.contains($0.threadId) }
            for thread in remoteThreads {
                upsertThread(hostId: hostId, thread: thread, replaceHistory: false)
            }

        case .threadUpsert(let hostId, let thread):
            upsertThread(hostId: hostId, thread: thread, replaceHistory: !thread.turns.isEmpty)

        case .threadStatusChanged(let hostId, let threadId, let status):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            threads[index].phase = phase(
                from: status,
                pendingApproval: threads[index].pendingApproval,
                activeTurnId: threads[index].activeTurnId
            )
            threads[index].isLoaded = status != .notLoaded
            threads[index].updatedAt = Date()
            threads[index].lastActivity = Date()

        case .turnStarted(let hostId, let threadId, let turn):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            threads[index].activeTurnId = turn.id
            threads[index].canSteerTurn = true
            threads[index].phase = .processing
            threads[index].updatedAt = Date()
            threads[index].lastActivity = Date()

        case .turnCompleted(let hostId, let threadId, let turn):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            threads[index].activeTurnId = nil
            threads[index].canSteerTurn = false
            threads[index].pendingApproval = nil
            threads[index].phase = phase(from: turn.status)
            threads[index].updatedAt = Date()
            threads[index].lastActivity = Date()

        case .itemStarted(let hostId, let threadId, _, let item):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            upsertHistoryItem(item, threadIndex: index, isCompletion: false)

        case .itemCompleted(let hostId, let threadId, _, let item):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            upsertHistoryItem(item, threadIndex: index, isCompletion: true)
            clearPendingApproval(hostId: hostId, threadId: threadId, itemId: item.id)

        case .agentMessageDelta(let hostId, let threadId, _, let itemId, let delta):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            appendAssistantDelta(threadIndex: index, itemId: itemId, delta: delta)

        case .approval(let hostId, let threadId, let approval):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            threads[index].pendingApproval = approval
            let toolInput = approval.formattedInput.map { ["detail": AnyCodable($0)] }
            threads[index].phase = .waitingForApproval(PermissionContext(
                toolUseId: approval.itemId,
                toolName: approval.title,
                toolInput: toolInput,
                receivedAt: Date()
            ))
            threads[index].updatedAt = Date()
            threads[index].lastActivity = Date()
        }
    }

    private func upsertThread(hostId: String, thread: RemoteAppServerThread, replaceHistory: Bool) {
        let hostName = hosts.first(where: { $0.id == hostId })?.displayName ?? "Remote Host"
        let connectionState = hostStates[hostId] ?? .disconnected
        let computedHistory = replaceHistory ? historyItems(from: thread.turns) : nil
        let computedTurn = thread.turns.last(where: { $0.status == .inProgress })

        if let index = threadIndex(hostId: hostId, threadId: thread.id) {
            threads[index].preview = thread.preview
            threads[index].name = thread.name
            threads[index].cwd = thread.cwd
            threads[index].updatedAt = remoteDate(thread.updatedAt)
            threads[index].createdAt = remoteDate(thread.createdAt)
            threads[index].isLoaded = thread.status != .notLoaded
            threads[index].connectionState = connectionState

            if let computedHistory {
                threads[index].history = computedHistory
                threads[index].activeTurnId = computedTurn?.id
                threads[index].canSteerTurn = computedTurn != nil
            }

            updateDerivedFields(at: index)
            threads[index].phase = phase(
                from: thread.status,
                pendingApproval: threads[index].pendingApproval,
                activeTurnId: threads[index].activeTurnId
            )
            return
        }

        let state = RemoteThreadState(
            hostId: hostId,
            hostName: hostName,
            threadId: thread.id,
            preview: thread.preview,
            name: thread.name,
            cwd: thread.cwd,
            phase: phase(from: thread.status, pendingApproval: nil, activeTurnId: computedTurn?.id),
            lastActivity: remoteDate(thread.updatedAt),
            createdAt: remoteDate(thread.createdAt),
            updatedAt: remoteDate(thread.updatedAt),
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            lastUserMessageDate: nil,
            history: computedHistory ?? [],
            activeTurnId: computedTurn?.id,
            isLoaded: thread.status != .notLoaded,
            canSteerTurn: computedTurn != nil,
            pendingApproval: nil,
            connectionState: connectionState
        )

        threads.append(state)
        if let index = threadIndex(hostId: hostId, threadId: thread.id) {
            updateDerivedFields(at: index)
        }
    }

    private func updateDerivedFields(at index: Int) {
        let history = threads[index].history
        threads[index].lastMessage = nil
        threads[index].lastMessageRole = nil
        threads[index].lastToolName = nil
        threads[index].lastUserMessageDate = nil

        for item in history.reversed() {
            switch item.type {
            case .assistant(let text):
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = text
                    threads[index].lastMessageRole = "assistant"
                }
            case .user(let text):
                if threads[index].lastUserMessageDate == nil {
                    threads[index].lastUserMessageDate = item.timestamp
                }
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = text
                    threads[index].lastMessageRole = "user"
                }
            case .toolCall(let tool):
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = tool.inputPreview
                    threads[index].lastMessageRole = "tool"
                    threads[index].lastToolName = tool.name
                }
            case .thinking(let text):
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = text
                    threads[index].lastMessageRole = "assistant"
                }
            case .interrupted:
                if threads[index].lastMessage == nil {
                    threads[index].lastMessage = "Interrupted"
                    threads[index].lastMessageRole = "assistant"
                }
            }
        }
    }

    private func clearPendingApproval(hostId: String, threadId: String, itemId: String) {
        guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
        guard threads[index].pendingApproval?.itemId == itemId else { return }
        threads[index].pendingApproval = nil
        if threads[index].activeTurnId != nil {
            threads[index].phase = .processing
        } else {
            threads[index].phase = .waitingForInput
        }
    }

    private func upsertHistoryItem(_ item: RemoteAppServerThreadItem, threadIndex: Int, isCompletion: Bool) {
        guard let chatItem = chatHistoryItem(from: item) else { return }
        if let existing = threads[threadIndex].history.firstIndex(where: { $0.id == chatItem.id }) {
            threads[threadIndex].history[existing] = ChatHistoryItem(
                id: chatItem.id,
                type: chatItem.type,
                timestamp: threads[threadIndex].history[existing].timestamp
            )
        } else {
            threads[threadIndex].history.append(chatItem)
        }

        if isCompletion {
            threads[threadIndex].lastActivity = Date()
            threads[threadIndex].updatedAt = Date()
        }
        updateDerivedFields(at: threadIndex)
    }

    private func appendAssistantDelta(threadIndex: Int, itemId: String, delta: String) {
        if let existing = threads[threadIndex].history.firstIndex(where: { $0.id == itemId }),
           case .assistant(let text) = threads[threadIndex].history[existing].type {
            threads[threadIndex].history[existing] = ChatHistoryItem(
                id: itemId,
                type: .assistant(text + delta),
                timestamp: threads[threadIndex].history[existing].timestamp
            )
        } else {
            threads[threadIndex].history.append(ChatHistoryItem(
                id: itemId,
                type: .assistant(delta),
                timestamp: Date()
            ))
        }

        threads[threadIndex].lastActivity = Date()
        threads[threadIndex].updatedAt = Date()
        updateDerivedFields(at: threadIndex)
    }

    private func historyItems(from turns: [RemoteAppServerTurn]) -> [ChatHistoryItem] {
        var items: [ChatHistoryItem] = []
        let baseDate = Date()

        for (turnIndex, turn) in turns.enumerated() {
            for (itemIndex, item) in turn.items.enumerated() {
                guard let chatItem = chatHistoryItem(from: item) else { continue }
                let offset = TimeInterval(turnIndex * 100 + itemIndex)
                items.append(ChatHistoryItem(
                    id: chatItem.id,
                    type: chatItem.type,
                    timestamp: baseDate.addingTimeInterval(offset)
                ))
            }
        }

        return items
    }

    private func chatHistoryItem(from item: RemoteAppServerThreadItem) -> ChatHistoryItem? {
        let timestamp = Date()
        switch item {
        case .userMessage(let id, let content):
            let text = content.compactMap(\.displayText).joined(separator: "\n")
            return ChatHistoryItem(id: id, type: .user(text), timestamp: timestamp)
        case .agentMessage(let id, let text):
            return ChatHistoryItem(id: id, type: .assistant(text), timestamp: timestamp)
        case .reasoning(let id, let summary, let content):
            let text = (summary + content).joined(separator: "\n")
            return ChatHistoryItem(id: id, type: .thinking(text), timestamp: timestamp)
        case .plan(let id, let text):
            return ChatHistoryItem(id: id, type: .thinking(text), timestamp: timestamp)
        case .commandExecution(let id, let command, _, let status, let aggregatedOutput):
            return ChatHistoryItem(
                id: id,
                type: .toolCall(ToolCallItem(
                    name: "Command",
                    input: ["command": command],
                    status: toolStatus(from: status),
                    result: aggregatedOutput,
                    structuredResult: nil,
                    subagentTools: []
                )),
                timestamp: timestamp
            )
        case .fileChange(let id, let changes, let status):
            let pathSummary = changes.map(\.path).joined(separator: ", ")
            return ChatHistoryItem(
                id: id,
                type: .toolCall(ToolCallItem(
                    name: "Edit",
                    input: ["path": pathSummary],
                    status: toolStatus(from: status),
                    result: changes.first?.diff,
                    structuredResult: nil,
                    subagentTools: []
                )),
                timestamp: timestamp
            )
        case .enteredReviewMode(let id, let review), .exitedReviewMode(let id, let review):
            return ChatHistoryItem(id: id, type: .assistant(review), timestamp: timestamp)
        case .contextCompaction(let id):
            return ChatHistoryItem(
                id: id,
                type: .toolCall(ToolCallItem(
                    name: "Compact",
                    input: [:],
                    status: .success,
                    result: nil,
                    structuredResult: nil,
                    subagentTools: []
                )),
                timestamp: timestamp
            )
        case .unsupported:
            return nil
        }
    }

    private func phase(
        from status: RemoteAppServerThreadStatus,
        pendingApproval: RemotePendingApproval?,
        activeTurnId: String?
    ) -> SessionPhase {
        if let pendingApproval {
            let toolInput = pendingApproval.formattedInput.map { ["detail": AnyCodable($0)] }
            return .waitingForApproval(PermissionContext(
                toolUseId: pendingApproval.itemId,
                toolName: pendingApproval.title,
                toolInput: toolInput,
                receivedAt: Date()
            ))
        }

        switch status {
        case .notLoaded, .idle:
            return activeTurnId == nil ? .idle : .processing
        case .systemError:
            return .ended
        case .active(let activeFlags):
            if activeFlags.contains(.waitingOnApproval) {
                return .processing
            }
            if activeFlags.contains(.waitingOnUserInput) {
                return .waitingForInput
            }
            return .processing
        }
    }

    private func phase(from turnStatus: RemoteAppServerTurnStatus) -> SessionPhase {
        switch turnStatus {
        case .inProgress:
            return .processing
        case .completed, .interrupted:
            return .waitingForInput
        case .failed:
            return .idle
        }
    }

    private func toolStatus(from status: RemoteAppServerCommandExecutionStatus) -> ToolStatus {
        switch status {
        case .inProgress:
            return .running
        case .completed:
            return .success
        case .failed, .declined:
            return .error
        }
    }

    private func toolStatus(from status: RemoteAppServerPatchApplyStatus) -> ToolStatus {
        switch status {
        case .inProgress:
            return .running
        case .completed:
            return .success
        case .failed, .declined:
            return .error
        }
    }

    private func remoteDate(_ timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private func threadIndex(hostId: String, threadId: String) -> Int? {
        threads.firstIndex(where: { $0.hostId == hostId && $0.threadId == threadId })
    }
}

actor RemoteAppServerConnection {
    private var host: RemoteHostConfig
    private let emit: @Sendable (RemoteConnectionEvent) async -> Void

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var remoteHomeDirectory: String?
    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<AnyCodable?, Error>] = [:]
    private var latestStderr: String = ""

    init(
        host: RemoteHostConfig,
        emit: @escaping @Sendable (RemoteConnectionEvent) async -> Void
    ) {
        self.host = host
        self.emit = emit
    }

    func updateHost(_ host: RemoteHostConfig) async {
        let shouldRestart = self.host != host
        self.host = host
        if shouldRestart {
            remoteHomeDirectory = nil
        }
        if shouldRestart {
            await stop()
            await start()
        }
    }

    func start() async {
        guard process == nil else { return }
        guard host.isValid else {
            await emit(.connectionState(hostId: host.id, state: .failed("SSH target required")))
            return
        }

        await emit(.connectionState(hostId: host.id, state: .connecting))

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            host.sshTarget,
            "codex", "app-server", "--listen", "stdio://"
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak process] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task {
                await self.handleTermination(exitCode: status)
            }
            _ = process
        }

        do {
            try process.run()
        } catch {
            await emit(.connectionState(hostId: host.id, state: .failed(error.localizedDescription)))
            return
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        startReaders(stdout: stdoutPipe.fileHandleForReading, stderr: stderrPipe.fileHandleForReading)

        do {
            try await initialize()
            await emit(.connectionState(hostId: host.id, state: .connected))
            try await refreshThreads()
            startRefreshLoop()
        } catch {
            await emit(.connectionState(hostId: host.id, state: .failed(error.localizedDescription)))
            await stop()
        }
    }

    func stop() async {
        refreshTask?.cancel()
        stdoutTask?.cancel()
        stderrTask?.cancel()
        refreshTask = nil
        stdoutTask = nil
        stderrTask = nil

        stdinHandle?.closeFile()
        stdinHandle = nil

        if let process {
            if process.isRunning {
                process.terminate()
            }
            self.process = nil
        }

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: RemoteSessionError.transport("Remote connection closed"))
        }
        pendingRequests.removeAll()
    }

    func startThread(defaultCwd: String) async throws -> RemoteAppServerThread {
        let normalizedCwd = try await normalizeRemoteCwd(defaultCwd)
        let params: [String: Any] = normalizedCwd?.isEmpty != false
            ? [:]
            : ["cwd": normalizedCwd!]

        let result = try await request(method: "thread/start", params: params)
        let response = try remoteDecodeValue(result ?? AnyCodable([:]), as: RemoteAppServerThreadStartResponse.self)
        return response.thread
    }

    func resumeThread(threadId: String) async throws -> RemoteAppServerThread {
        let result = try await request(method: "thread/resume", params: ["threadId": threadId])
        let response = try remoteDecodeValue(result ?? AnyCodable([:]), as: RemoteAppServerThreadResumeResponse.self)
        return response.thread
    }

    func sendMessage(threadId: String, text: String, activeTurnId: String?) async throws {
        if let activeTurnId {
            _ = try await request(
                method: "turn/steer",
                params: [
                    "threadId": threadId,
                    "expectedTurnId": activeTurnId,
                    "input": [["type": "text", "text": text]]
                ]
            )
            return
        }

        _ = try await request(
            method: "turn/start",
            params: [
                "threadId": threadId,
                "input": [["type": "text", "text": text]]
            ]
        )
    }

    func interrupt(threadId: String, turnId: String) async throws {
        _ = try await request(
            method: "turn/interrupt",
            params: ["threadId": threadId, "turnId": turnId]
        )
    }

    func respond(to approval: RemotePendingApproval, allow: Bool) async throws {
        let result: [String: Any]
        switch approval.kind {
        case .commandExecution:
            result = ["decision": allow ? "accept" : "decline"]
        case .fileChange:
            result = ["decision": allow ? "accept" : "decline"]
        case .permissions:
            let permissions = allow ? permissionGrantPayload(from: approval.requestedPermissions) : [:]
            result = ["scope": "turn", "permissions": permissions]
        }

        try await sendResponse(id: approval.requestId, result: result)
    }

    private func initialize() async throws {
        let result = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_island",
                    "title": "Codex Island",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                ]
            ]
        )

        _ = result
        try await sendNotification(method: "initialized", params: nil)
    }

    private func refreshThreads() async throws {
        let result = try await request(method: "thread/list", params: ["limit": 100])
        let response = try remoteDecodeValue(result ?? AnyCodable([:]), as: RemoteAppServerThreadListResponse.self)
        await emit(.threadList(hostId: host.id, threads: response.data))
    }

    private func startReaders(stdout: FileHandle, stderr: FileHandle) {
        stdoutTask = Task {
            do {
                for try await line in stdout.bytes.lines {
                    await self.handleLine(String(line))
                }
            } catch {
                await self.emit(.connectionState(hostId: self.host.id, state: .failed(error.localizedDescription)))
            }
        }

        stderrTask = Task {
            do {
                for try await line in stderr.bytes.lines {
                    await self.handleStderr(String(line))
                }
            } catch {
                return
            }
        }
    }

    private func startRefreshLoop() {
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                try? await self.refreshThreads()
            }
        }
    }

    private func handleLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else { return }
        let decoder = JSONDecoder()

        do {
            let message = try decoder.decode(RemoteAppServerEnvelope.self, from: data)
            if let method = message.method {
                if let id = message.id {
                    await handleServerRequest(method: method, id: id, params: message.params)
                } else {
                    await handleNotification(method: method, params: message.params)
                }
                return
            }

            if case .int(let id)? = message.id, let continuation = pendingRequests.removeValue(forKey: id) {
                if let error = message.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: message.result)
                }
            }
        } catch {
            await emit(.connectionState(hostId: host.id, state: .failed("Failed to decode app-server message")))
        }
    }

    private func handleNotification(method: String, params: AnyCodable?) async {
        guard let params else { return }

        do {
            switch method {
            case "thread/started":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerThreadStartedNotification.self)
                await emit(.threadUpsert(hostId: host.id, thread: payload.thread))
            case "thread/status/changed":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerThreadStatusChangedNotification.self)
                await emit(.threadStatusChanged(hostId: host.id, threadId: payload.threadId, status: payload.status))
            case "turn/started":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerTurnStartedNotification.self)
                await emit(.turnStarted(hostId: host.id, threadId: payload.threadId, turn: payload.turn))
            case "turn/completed":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerTurnCompletedNotification.self)
                await emit(.turnCompleted(hostId: host.id, threadId: payload.threadId, turn: payload.turn))
            case "item/started":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerItemStartedNotification.self)
                await emit(.itemStarted(hostId: host.id, threadId: payload.threadId, turnId: payload.turnId, item: payload.item))
            case "item/completed":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerItemCompletedNotification.self)
                await emit(.itemCompleted(hostId: host.id, threadId: payload.threadId, turnId: payload.turnId, item: payload.item))
            case "item/agentMessage/delta":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerAgentMessageDeltaNotification.self)
                await emit(.agentMessageDelta(
                    hostId: host.id,
                    threadId: payload.threadId,
                    turnId: payload.turnId,
                    itemId: payload.itemId,
                    delta: payload.delta
                ))
            default:
                break
            }
        } catch {
            return
        }
    }

    private func handleServerRequest(method: String, id: RemoteRPCID, params: AnyCodable?) async {
        guard let params else { return }

        do {
            switch method {
            case "item/commandExecution/requestApproval":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerCommandApprovalRequest.self)
                let approval = RemotePendingApproval(
                    id: "approval-\(host.id)-\(payload.itemId)",
                    requestId: id,
                    kind: .commandExecution,
                    itemId: payload.itemId,
                    threadId: payload.threadId,
                    turnId: payload.turnId,
                    title: "Command Execution",
                    detail: payload.command ?? payload.reason,
                    requestedPermissions: .none
                )
                await emit(.approval(hostId: host.id, threadId: payload.threadId, approval: approval))
            case "item/fileChange/requestApproval":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerFileChangeApprovalRequest.self)
                let approval = RemotePendingApproval(
                    id: "approval-\(host.id)-\(payload.itemId)",
                    requestId: id,
                    kind: .fileChange,
                    itemId: payload.itemId,
                    threadId: payload.threadId,
                    turnId: payload.turnId,
                    title: "File Change",
                    detail: payload.reason,
                    requestedPermissions: .none
                )
                await emit(.approval(hostId: host.id, threadId: payload.threadId, approval: approval))
            case "item/permissions/requestApproval":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerPermissionsApprovalRequest.self)
                let permissions = RemotePermissionProfile(
                    networkEnabled: payload.permissions.network?.enabled,
                    readRoots: payload.permissions.fileSystem?.read ?? [],
                    writeRoots: payload.permissions.fileSystem?.write ?? []
                )
                let approval = RemotePendingApproval(
                    id: "approval-\(host.id)-\(payload.itemId)",
                    requestId: id,
                    kind: .permissions,
                    itemId: payload.itemId,
                    threadId: payload.threadId,
                    turnId: payload.turnId,
                    title: "Permissions Request",
                    detail: payload.reason,
                    requestedPermissions: permissions
                )
                await emit(.approval(hostId: host.id, threadId: payload.threadId, approval: approval))
            default:
                try await sendResponse(id: id, result: [:])
            }
        } catch {
            return
        }
    }

    private func handleStderr(_ line: String) async {
        latestStderr = line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleTermination(exitCode: Int32) async {
        let message: String
        if latestStderr.isEmpty {
            message = exitCode == 0 ? "Disconnected" : "SSH exited with code \(exitCode)"
        } else {
            message = latestStderr
        }

        await emit(.connectionState(hostId: host.id, state: .failed(message)))
        await stop()
    }

    private func request(method: String, params: [String: Any]) async throws -> AnyCodable? {
        let id = nextRequestId
        nextRequestId += 1
        let envelope = RemoteAppServerEnvelope(
            method: method,
            id: .int(id),
            params: AnyCodable(params),
            result: nil,
            error: nil
        )

        try await sendEnvelope(envelope)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
    }

    private func sendNotification(method: String, params: [String: Any]?) async throws {
        let envelope = RemoteAppServerEnvelope(
            method: method,
            id: nil,
            params: params.map(AnyCodable.init),
            result: nil,
            error: nil
        )
        try await sendEnvelope(envelope)
    }

    private func sendResponse(id: RemoteRPCID, result: [String: Any]) async throws {
        let envelope = RemoteAppServerEnvelope(
            method: nil,
            id: id,
            params: nil,
            result: AnyCodable(result),
            error: nil
        )
        try await sendEnvelope(envelope)
    }

    private func sendEnvelope(_ envelope: RemoteAppServerEnvelope) async throws {
        guard let stdinHandle else {
            throw RemoteSessionError.notConnected
        }

        let data = try JSONEncoder().encode(envelope)
        stdinHandle.write(data)
        stdinHandle.write(Data([0x0A]))
    }

    private func permissionGrantPayload(from profile: RemotePermissionProfile) -> [String: Any] {
        var payload: [String: Any] = [:]
        if let networkEnabled = profile.networkEnabled {
            payload["network"] = ["enabled": networkEnabled]
        }
        var fileSystem: [String: Any] = [:]
        if !profile.readRoots.isEmpty {
            fileSystem["read"] = profile.readRoots
        }
        if !profile.writeRoots.isEmpty {
            fileSystem["write"] = profile.writeRoots
        }
        if !fileSystem.isEmpty {
            payload["fileSystem"] = fileSystem
        }
        return payload
    }

    private func normalizeRemoteCwd(_ cwd: String) async throws -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "~" {
            return try await resolveRemoteHomeDirectory() ?? nil
        }

        if trimmed.hasPrefix("~/") {
            guard let home = try await resolveRemoteHomeDirectory(), !home.isEmpty else {
                throw RemoteSessionError.invalidConfiguration("Could not resolve remote home directory for `~`")
            }
            let suffix = String(trimmed.dropFirst(2))
            return URL(fileURLWithPath: home).appendingPathComponent(suffix).path
        }

        return trimmed
    }

    private func resolveRemoteHomeDirectory() async throws -> String? {
        if let remoteHomeDirectory, !remoteHomeDirectory.isEmpty {
            return remoteHomeDirectory
        }

        let output = try await ProcessExecutor.shared.run("/usr/bin/ssh", arguments: [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            host.sshTarget,
            "printf '%s' \"$HOME\""
        ])
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteHomeDirectory = home.isEmpty ? nil : home
        return remoteHomeDirectory
    }
}
