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
    case threadError(hostId: String, threadId: String, turnId: String?, message: String, willRetry: Bool)
}

enum RemoteSessionError: LocalizedError {
    case notConnected
    case missingThread
    case invalidConfiguration(String)
    case transport(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Remote host is not connected"
        case .missingThread:
            return "Remote thread not found"
        case .invalidConfiguration(let message), .transport(let message), .timeout(let message):
            return message
        }
    }
}

nonisolated protocol RemoteAppServerConnectionProtocol: Sendable {
    func updateHost(_ host: RemoteHostConfig) async
    func start() async
    func stop() async
    func startThread(defaultCwd: String) async throws -> RemoteAppServerThread
    func resumeThread(threadId: String) async throws -> RemoteAppServerThread
    func sendMessage(threadId: String, text: String, activeTurnId: String?) async throws
    func interrupt(threadId: String, turnId: String) async throws
    func respond(to approval: RemotePendingApproval, allow: Bool) async throws
    func refreshThreads() async throws
}

nonisolated struct RemoteAppServerConnectionDependencies: Sendable {
    let transportFactory: @Sendable (RemoteHostConfig) -> any RemoteAppServerTransport
    let processExecutor: any ProcessExecuting
    let diagnosticsLogger: any RemoteDiagnosticsLogging
    let requestTimeout: Duration
    let initialRefreshDelay: Duration
    let refreshInterval: Duration
    let sleep: @Sendable (Duration) async throws -> Void

    static let live = RemoteAppServerConnectionDependencies(
        transportFactory: { SSHStdioTransport(host: $0) },
        processExecutor: ProcessExecutor.shared,
        diagnosticsLogger: RemoteDiagnosticsLogger.shared,
        requestTimeout: .seconds(10),
        initialRefreshDelay: .seconds(5),
        refreshInterval: .seconds(15),
        sleep: { duration in
            try await Task.sleep(for: duration)
        }
    )
}

actor RemoteRequestSerialGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }

    func withPermit<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }
}

@MainActor
final class RemoteSessionMonitor: ObservableObject {
    static let shared = RemoteSessionMonitor()

    @Published private(set) var hosts: [RemoteHostConfig]
    @Published private(set) var threads: [RemoteThreadState] = []
    @Published private(set) var hostStates: [String: RemoteHostConnectionState] = [:]
    @Published private(set) var hostActionErrors: [String: String] = [:]
    @Published private(set) var hostActionInProgress: Set<String> = []

    private let saveHosts: ([RemoteHostConfig]) -> Void
    private let connectionFactory: (
        RemoteHostConfig,
        @escaping @Sendable (RemoteConnectionEvent) async -> Void
    ) -> any RemoteAppServerConnectionProtocol
    private let diagnosticsLogger: any RemoteDiagnosticsLogging

    private var connections: [String: any RemoteAppServerConnectionProtocol] = [:]
    private var hostActionTasks: [String: Task<Void, Never>] = [:]

    init(
        initialHosts: [RemoteHostConfig]? = nil,
        loadHosts: (() -> [RemoteHostConfig])? = nil,
        saveHosts: (([RemoteHostConfig]) -> Void)? = nil,
        diagnosticsLogger: any RemoteDiagnosticsLogging = RemoteDiagnosticsLogger.shared,
        connectionFactory: @escaping (
            RemoteHostConfig,
            @escaping @Sendable (RemoteConnectionEvent) async -> Void
        ) -> any RemoteAppServerConnectionProtocol = { host, emit in
            RemoteAppServerConnection(host: host, emit: emit)
        }
    ) {
        self.hosts = initialHosts ?? loadHosts?() ?? AppSettings.remoteHosts
        self.saveHosts = saveHosts ?? { AppSettings.remoteHosts = $0 }
        self.diagnosticsLogger = diagnosticsLogger
        self.connectionFactory = connectionFactory
    }

    private func markStateChanged() {
        objectWillChange.send()
    }

    func startMonitoring() {
        syncConnections()
    }

    func createThread(
        hostId: String,
        onSuccess: @escaping @MainActor (RemoteThreadState) -> Void
    ) {
        markStateChanged()
        hostActionErrors.removeValue(forKey: hostId)
        hostActionInProgress.insert(hostId)
        hostActionTasks[hostId]?.cancel()

        hostActionTasks[hostId] = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.markStateChanged()
                    self.hostActionInProgress.remove(hostId)
                    self.hostActionTasks.removeValue(forKey: hostId)
                }
            }

            do {
                let thread = try await self.startThread(hostId: hostId)
                await onSuccess(thread)
            } catch {
                await MainActor.run {
                    self.markStateChanged()
                    if let state = self.hostStates[hostId],
                       case .failed(let message) = state,
                       !message.isEmpty {
                        self.hostActionErrors[hostId] = message
                    } else if error is CancellationError {
                        self.hostActionErrors[hostId] = "Remote request was canceled. Reconnect and retry."
                    } else {
                        self.hostActionErrors[hostId] = error.localizedDescription
                    }
                }
                return
            }
        }
    }

    func refreshHost(id: String) {
        guard let connection = connections[id] else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await connection.refreshThreads()
                self.hostActionErrors.removeValue(forKey: id)
            } catch {
                self.hostActionErrors[id] = error.localizedDescription
                await self.logMonitorEvent(
                    level: .warning,
                    hostId: id,
                    method: "thread/list",
                    message: "Manual refresh failed",
                    payload: error.localizedDescription
                )
            }
        }
    }

    func addHost() {
        hosts.append(RemoteHostConfig())
        persistHosts()
    }

    func updateHost(_ host: RemoteHostConfig) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let previous = hosts[index]
        hosts[index] = host
        saveHosts(hosts)

        let connectionState = hostStates[host.id] ?? .disconnected
        let shouldSync = previous.isEnabled != host.isEnabled || !connectionState.isConnected
        if shouldSync {
            syncConnections()
        }
    }

    func removeHost(id: String) {
        markStateChanged()
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
        markStateChanged()
        if case .connecting = hostStates[id] {
            return
        }
        hostActionErrors.removeValue(forKey: id)
        if !host.isEnabled {
            var updated = host
            updated.isEnabled = true
            updateHost(updated)
            return
        }
        if let connection = connections.removeValue(forKey: id) {
            Task { await connection.stop() }
        }
        hostStates[id] = .connecting
        syncConnections()
    }

    func disconnectHost(id: String) {
        markStateChanged()
        hostStates[id] = .disconnected
        hostActionErrors.removeValue(forKey: id)
        hostActionInProgress.remove(id)
        hostActionTasks[id]?.cancel()
        hostActionTasks.removeValue(forKey: id)
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
        let existingThreadIds = Set(
            threads
                .filter { $0.hostId == hostId }
                .map(\.threadId)
        )

        do {
            let thread = try await connection.startThread(defaultCwd: host.defaultCwd)
            markStateChanged()
            hostActionErrors.removeValue(forKey: hostId)
            apply(event: .threadUpsert(hostId: hostId, thread: thread))
            await logMonitorEvent(
                level: .info,
                hostId: hostId,
                method: "thread/start",
                threadId: thread.id,
                message: "Started remote thread"
            )
            Task {
                try? await connection.refreshThreads()
            }
            guard let state = threads.first(where: { $0.hostId == hostId && $0.threadId == thread.id }) else {
                throw RemoteSessionError.missingThread
            }
            return state
        } catch {
            markStateChanged()
            if case .timeout = (error as? RemoteSessionError) {
                try? await connection.refreshThreads()
                if let recovered = recoverNewThread(hostId: hostId, excluding: existingThreadIds) {
                    hostActionErrors.removeValue(forKey: hostId)
                    await logMonitorEvent(
                        level: .warning,
                        hostId: hostId,
                        method: "thread/start",
                        threadId: recovered.threadId,
                        message: "Recovered remote thread after timeout fallback"
                    )
                    return recovered
                }
            }
            hostActionErrors[hostId] = error.localizedDescription
            await logMonitorEvent(
                level: .error,
                hostId: hostId,
                method: "thread/start",
                message: "Failed to start remote thread",
                payload: error.localizedDescription
            )
            throw error
        }
    }

    func openThread(hostId: String, threadId: String) async throws -> RemoteThreadState {
        guard let connection = connections[hostId] else {
            throw RemoteSessionError.notConnected
        }

        do {
            let thread = try await connection.resumeThread(threadId: threadId)
            markStateChanged()
            hostActionErrors.removeValue(forKey: hostId)
            apply(event: .threadUpsert(hostId: hostId, thread: thread))
            await logMonitorEvent(
                level: .info,
                hostId: hostId,
                method: "thread/resume",
                threadId: thread.id,
                message: "Opened remote thread"
            )
            Task {
                try? await connection.refreshThreads()
            }
            guard let state = threads.first(where: { $0.hostId == hostId && $0.threadId == thread.id }) else {
                throw RemoteSessionError.missingThread
            }
            return state
        } catch {
            markStateChanged()
            hostActionErrors[hostId] = error.localizedDescription
            await logMonitorEvent(
                level: .error,
                hostId: hostId,
                method: "thread/resume",
                threadId: threadId,
                message: "Failed to open remote thread",
                payload: error.localizedDescription
            )
            throw error
        }
    }

    func sendMessage(thread: RemoteThreadState, text: String) async throws {
        guard let connection = connections[thread.hostId] else {
            throw RemoteSessionError.notConnected
        }
        appendOptimisticUserMessage(thread: thread, text: text)
        defer {
            refreshHost(id: thread.hostId)
        }
        do {
            try await connection.sendMessage(
                threadId: thread.threadId,
                text: text,
                activeTurnId: thread.canSteerTurn ? thread.activeTurnId : nil
            )
            await logMonitorEvent(
                level: .info,
                hostId: thread.hostId,
                method: thread.canSteerTurn ? "turn/steer" : "turn/start",
                threadId: thread.threadId,
                turnId: thread.activeTurnId,
                message: "Sent remote user message",
                payload: text
            )
        } catch {
            if case .timeout = (error as? RemoteSessionError) {
                await logMonitorEvent(
                    level: .warning,
                    hostId: thread.hostId,
                    method: thread.canSteerTurn ? "turn/steer" : "turn/start",
                    threadId: thread.threadId,
                    turnId: thread.activeTurnId,
                    message: "Remote message send timed out; awaiting async events",
                    payload: text
                )
                return
            }
            await logMonitorEvent(
                level: .error,
                hostId: thread.hostId,
                method: thread.canSteerTurn ? "turn/steer" : "turn/start",
                threadId: thread.threadId,
                turnId: thread.activeTurnId,
                message: "Remote message send failed",
                payload: error.localizedDescription
            )
            throw error
        }
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
        saveHosts(hosts)
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
                let weakSelf = self
                let connection = connectionFactory(host) { event in
                    await MainActor.run {
                        weakSelf.apply(event: event)
                    }
                }
                connections[id] = connection
                Task { await connection.start() }
            }
        }
    }

    func apply(event: RemoteConnectionEvent) {
        markStateChanged()
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
            threads[index].phase = .waitingForApproval(PermissionContext(
                toolUseId: approval.itemId,
                toolName: approval.title,
                toolInput: nil,
                receivedAt: Date()
            ))
            threads[index].updatedAt = Date()
            threads[index].lastActivity = Date()

        case .threadError(let hostId, let threadId, let turnId, let message, let willRetry):
            guard let index = threadIndex(hostId: hostId, threadId: threadId) else { return }
            threads[index].history.append(ChatHistoryItem(
                id: "remote-error-\(turnId ?? UUID().uuidString)-\(Date().timeIntervalSince1970)",
                type: .assistant(message),
                timestamp: Date()
            ))
            threads[index].lastActivity = Date()
            threads[index].updatedAt = Date()
            if !willRetry {
                threads[index].activeTurnId = nil
                threads[index].canSteerTurn = false
                threads[index].pendingApproval = nil
                threads[index].phase = .idle
            }
            updateDerivedFields(at: index)
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

    func appendOptimisticUserMessage(thread: RemoteThreadState, text: String) {
        guard let index = threadIndex(hostId: thread.hostId, threadId: thread.threadId) else { return }
        let item = ChatHistoryItem(
            id: "optimistic-user-\(UUID().uuidString)",
            type: .user(text),
            timestamp: Date()
        )
        threads[index].history.append(item)
        threads[index].lastActivity = Date()
        threads[index].updatedAt = Date()
        if threads[index].phase == .idle || threads[index].phase == .waitingForInput {
            threads[index].phase = .processing
        }
        updateDerivedFields(at: index)
    }

    func recoverNewThread(hostId: String, excluding existingIds: Set<String>) -> RemoteThreadState? {
        let newThreads = threads
            .filter { $0.hostId == hostId && !existingIds.contains($0.threadId) }
            .sorted { $0.updatedAt > $1.updatedAt }
        return newThreads.first
    }

    private func logMonitorEvent(
        level: RemoteDiagnosticsRecord.Level,
        hostId: String,
        method: String? = nil,
        threadId: String? = nil,
        turnId: String? = nil,
        itemId: String? = nil,
        message: String,
        payload: String? = nil
    ) async {
        let host = hosts.first(where: { $0.id == hostId })
        await diagnosticsLogger.log(
            RemoteDiagnosticsRecord(
                level: level,
                category: "remote.monitor",
                hostId: hostId,
                hostName: host?.displayName,
                sshTarget: host?.sshTarget,
                requestId: nil,
                method: method,
                threadId: threadId,
                turnId: turnId,
                itemId: itemId,
                message: message,
                payload: payload
            )
        )
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
            return .waitingForApproval(PermissionContext(
                toolUseId: pendingApproval.itemId,
                toolName: pendingApproval.title,
                toolInput: nil,
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

actor RemoteAppServerConnection: RemoteAppServerConnectionProtocol {
    private struct PendingRequestMetadata: Sendable {
        let method: String
        let threadId: String?
        let turnId: String?
        let itemId: String?
    }

    private var host: RemoteHostConfig
    private let emit: @Sendable (RemoteConnectionEvent) async -> Void
    private let dependencies: RemoteAppServerConnectionDependencies
    private let connectionId = UUID().uuidString

    private var transport: (any RemoteAppServerTransport)?
    private var refreshTask: Task<Void, Never>?
    private var remoteHomeDirectory: String?
    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<AnyCodable?, Error>] = [:]
    private var pendingRequestMetadata: [Int: PendingRequestMetadata] = [:]
    private var latestStderr: String = ""
    private var isStopping = false
    private let requestGate = RemoteRequestSerialGate()

    init(
        host: RemoteHostConfig,
        emit: @escaping @Sendable (RemoteConnectionEvent) async -> Void,
        dependencies: RemoteAppServerConnectionDependencies = .live
    ) {
        self.host = host
        self.emit = emit
        self.dependencies = dependencies
    }

    func updateHost(_ host: RemoteHostConfig) async {
        let shouldRestart = self.host != host
        self.host = host
        if shouldRestart {
            remoteHomeDirectory = nil
            await log(
                level: .info,
                category: "remote.connection.lifecycle",
                message: "Remote host config changed; restarting connection"
            )
            await stop()
            await start()
        }
    }

    func start() async {
        guard transport == nil else { return }
        isStopping = false
        guard host.isValid else {
            await emit(.connectionState(hostId: host.id, state: .failed("SSH target required")))
            await log(
                level: .error,
                category: "remote.connection.lifecycle",
                message: "Remote host start aborted: missing SSH target"
            )
            return
        }

        await emit(.connectionState(hostId: host.id, state: .connecting))
        await log(
            level: .info,
            category: "remote.connection.lifecycle",
            message: "Starting SSH stdio transport"
        )

        let transport = dependencies.transportFactory(host)
        self.transport = transport

        do {
            try await transport.start(
                onStdoutLine: { [weak self] line in
                    await self?.handleLine(line)
                },
                onStderrLine: { [weak self] line in
                    await self?.handleStderr(line)
                },
                onTermination: { [weak self] exitCode in
                    await self?.handleTermination(exitCode: exitCode)
                }
            )
            await log(
                level: .info,
                category: "remote.connection.lifecycle",
                message: "SSH stdio transport started"
            )

            try await initialize()
            await emit(.connectionState(hostId: host.id, state: .connected))
            await log(
                level: .info,
                category: "remote.connection.lifecycle",
                message: "Remote app-server initialized"
            )
        } catch {
            self.transport = nil
            await emit(.connectionState(hostId: host.id, state: .failed(error.localizedDescription)))
            await log(
                level: .error,
                category: "remote.connection.lifecycle",
                message: "Remote connection start failed",
                payload: error.localizedDescription
            )
            await stop()
        }
    }

    func stop() async {
        guard !isStopping || transport != nil || !pendingRequests.isEmpty else { return }
        isStopping = true
        refreshTask?.cancel()
        refreshTask = nil

        await log(
            level: .info,
            category: "remote.connection.lifecycle",
            message: "Stopping remote connection"
        )

        if let transport {
            await transport.stop()
            self.transport = nil
        }

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: RemoteSessionError.transport("Remote connection closed"))
        }
        pendingRequests.removeAll()
        pendingRequestMetadata.removeAll()
        latestStderr = ""
    }

    func startThread(defaultCwd: String) async throws -> RemoteAppServerThread {
        let normalizedCwd = try await normalizeRemoteCwd(defaultCwd)
        let params: [String: Any] = normalizedCwd?.isEmpty != false ? [:] : ["cwd": normalizedCwd!]
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
        case .commandExecution, .fileChange:
            result = ["decision": allow ? "accept" : "decline"]
        case .permissions:
            let permissions = allow ? permissionGrantPayload(from: approval.requestedPermissions) : [:]
            result = ["scope": "turn", "permissions": permissions]
        }

        try await sendResponse(id: approval.requestId, result: result)
    }

    func refreshThreads() async throws {
        let result = try await request(method: "thread/list", params: ["limit": 100])
        let response = try remoteDecodeValue(result ?? AnyCodable([:]), as: RemoteAppServerThreadListResponse.self)
        await emit(.threadList(hostId: host.id, threads: response.data))
    }

    private func initialize() async throws {
        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_island",
                    "title": "Codex Island",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                ]
            ]
        )
        try await sendNotification(method: "initialized", params: nil)
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                try await self.dependencies.sleep(self.dependencies.initialRefreshDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self.refreshThreadsInBackground(reason: "initial")
            while !Task.isCancelled {
                do {
                    try await self.dependencies.sleep(self.dependencies.refreshInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.refreshThreadsInBackground(reason: "periodic")
            }
        }
    }

    func refreshThreadsInBackground(reason: String) async {
        do {
            try await refreshThreads()
            await log(
                level: .debug,
                category: "remote.connection.refresh",
                method: "thread/list",
                message: "Background thread refresh succeeded",
                payload: reason
            )
        } catch {
            await log(
                level: .warning,
                category: "remote.connection.refresh",
                method: "thread/list",
                message: "Background thread refresh failed",
                payload: "\(reason): \(error.localizedDescription)"
            )
        }
    }

    func installTransportForTesting(_ transport: any RemoteAppServerTransport) async throws {
        self.transport = transport
        try await transport.start(
            onStdoutLine: { [weak self] line in
                await self?.handleLine(line)
            },
            onStderrLine: { [weak self] line in
                await self?.handleStderr(line)
            },
            onTermination: { [weak self] exitCode in
                await self?.handleTermination(exitCode: exitCode)
            }
        )
    }

    private func handleLine(_ line: String) async {
        await log(
            level: .debug,
            category: "remote.rpc.inbound",
            message: "Received app-server line",
            payload: line
        )

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

            if case .int(let id)? = message.id,
               let continuation = pendingRequests.removeValue(forKey: id) {
                let metadata = pendingRequestMetadata.removeValue(forKey: id)
                if let error = message.error {
                    await log(
                        level: .error,
                        category: "remote.rpc.response",
                        requestId: String(id),
                        method: metadata?.method,
                        threadId: metadata?.threadId,
                        turnId: metadata?.turnId,
                        itemId: metadata?.itemId,
                        message: "Received RPC error response",
                        payload: error.message
                    )
                    continuation.resume(throwing: error)
                } else {
                    await log(
                        level: .debug,
                        category: "remote.rpc.response",
                        requestId: String(id),
                        method: metadata?.method,
                        threadId: metadata?.threadId,
                        turnId: metadata?.turnId,
                        itemId: metadata?.itemId,
                        message: "Received RPC response",
                        payload: payloadString(from: message.result)
                    )
                    continuation.resume(returning: message.result)
                }
            }
        } catch {
            await log(
                level: .error,
                category: "remote.rpc.decode",
                message: "Failed to decode app-server message",
                payload: line
            )
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
            case "error":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerErrorNotification.self)
                let message = payload.error.additionalDetails.map { "\(payload.error.message)\n\($0)" } ?? payload.error.message
                await log(
                    level: .error,
                    category: "remote.rpc.notification",
                    method: method,
                    threadId: payload.threadId,
                    turnId: payload.turnId,
                    message: "Received thread error notification",
                    payload: message,
                    willRetry: payload.willRetry
                )
                await emit(.threadError(
                    hostId: host.id,
                    threadId: payload.threadId,
                    turnId: payload.turnId,
                    message: message,
                    willRetry: payload.willRetry
                ))
            case "codex/event/error":
                let payload = try remoteDecodeValue(params, as: RemoteAppServerCodexEventErrorNotification.self)
                let message = payload.msg.additionalDetails.map { "\(payload.msg.message)\n\($0)" } ?? payload.msg.message
                await log(
                    level: .error,
                    category: "remote.rpc.notification",
                    method: method,
                    threadId: payload.conversationId,
                    turnId: payload.id.isEmpty ? nil : payload.id,
                    message: "Received codex event error notification",
                    payload: message
                )
                await emit(.threadError(
                    hostId: host.id,
                    threadId: payload.conversationId,
                    turnId: payload.id.isEmpty ? nil : payload.id,
                    message: message,
                    willRetry: false
                ))
            default:
                break
            }
        } catch {
            await log(
                level: .warning,
                category: "remote.rpc.notification",
                method: method,
                message: "Failed to decode notification",
                payload: payloadString(from: params)
            )
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
            await log(
                level: .warning,
                category: "remote.rpc.server_request",
                requestId: rpcIDString(id),
                method: method,
                message: "Failed to handle server request",
                payload: error.localizedDescription
            )
        }
    }

    private func handleStderr(_ line: String) async {
        latestStderr = line.trimmingCharacters(in: .whitespacesAndNewlines)
        await log(
            level: .warning,
            category: "remote.connection.stderr",
            message: "Received stderr from SSH/app-server",
            stderr: latestStderr
        )
    }

    private func handleTermination(exitCode: Int32) async {
        if isStopping {
            await log(
                level: .info,
                category: "remote.connection.lifecycle",
                message: "Remote process terminated after local stop",
                exitCode: exitCode,
                stderr: latestStderr
            )
            return
        }

        let message: String
        if latestStderr.isEmpty {
            message = exitCode == 0 ? "Disconnected" : "SSH exited with code \(exitCode)"
        } else {
            message = latestStderr
        }

        await log(
            level: exitCode == 0 ? .warning : .error,
            category: "remote.connection.lifecycle",
            message: "Remote transport terminated unexpectedly",
            exitCode: exitCode,
            stderr: latestStderr
        )
        await emit(.connectionState(hostId: host.id, state: .failed(message)))
        await stop()
    }

    private func request(method: String, params: [String: Any]) async throws -> AnyCodable? {
        try await requestGate.withPermit {
            let id = nextRequestId
            nextRequestId += 1

            let envelope = RemoteAppServerEnvelope(
                method: method,
                id: .int(id),
                params: AnyCodable(params),
                result: nil,
                error: nil
            )
            let metadata = PendingRequestMetadata(
                method: method,
                threadId: stringValue(forKey: "threadId", in: params),
                turnId: stringValue(forKey: "turnId", in: params) ?? stringValue(forKey: "expectedTurnId", in: params),
                itemId: stringValue(forKey: "itemId", in: params)
            )

            let payload = try await sendEnvelope(envelope)
            await log(
                level: .debug,
                category: "remote.rpc.request",
                requestId: String(id),
                method: method,
                threadId: metadata.threadId,
                turnId: metadata.turnId,
                itemId: metadata.itemId,
                message: "Sent RPC request",
                payload: payload
            )

            return try await withCheckedThrowingContinuation { continuation in
                pendingRequests[id] = continuation
                pendingRequestMetadata[id] = metadata

                Task {
                    do {
                        try await self.dependencies.sleep(self.dependencies.requestTimeout)
                    } catch {
                        return
                    }
                    await self.failPendingRequest(
                        id: id,
                        error: RemoteSessionError.timeout("Timed out waiting for app-server response to \(method)")
                    )
                }
            }
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
        let payload = try await sendEnvelope(envelope)
        await log(
            level: .debug,
            category: "remote.rpc.notification",
            method: method,
            message: "Sent RPC notification",
            payload: payload
        )
    }

    private func sendResponse(id: RemoteRPCID, result: [String: Any]) async throws {
        let envelope = RemoteAppServerEnvelope(
            method: nil,
            id: id,
            params: nil,
            result: AnyCodable(result),
            error: nil
        )
        let payload = try await sendEnvelope(envelope)
        await log(
            level: .debug,
            category: "remote.rpc.response",
            requestId: rpcIDString(id),
            message: "Sent RPC response",
            payload: payload
        )
    }

    private func sendEnvelope(_ envelope: RemoteAppServerEnvelope) async throws -> String {
        guard let transport else {
            throw RemoteSessionError.notConnected
        }
        let data = try JSONEncoder().encode(envelope)
        guard let line = String(data: data, encoding: .utf8) else {
            throw RemoteSessionError.transport("Failed to encode app-server message")
        }
        try await transport.send(line: line)
        return line
    }

    private func failPendingRequest(id: Int, error: Error) async {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        let metadata = pendingRequestMetadata.removeValue(forKey: id)
        let level: RemoteDiagnosticsRecord.Level = error is RemoteSessionError ? .warning : .error
        await log(
            level: level,
            category: "remote.rpc.request",
            requestId: String(id),
            method: metadata?.method,
            threadId: metadata?.threadId,
            turnId: metadata?.turnId,
            itemId: metadata?.itemId,
            message: "Request finished with error",
            payload: error.localizedDescription
        )
        continuation.resume(throwing: error)
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
            await log(
                level: .debug,
                category: "remote.connection.cwd",
                message: "Default CWD '~' resolved to nil payload"
            )
            return nil
        }

        if trimmed.hasPrefix("~/") {
            guard let home = try await resolveRemoteHomeDirectory(), !home.isEmpty else {
                throw RemoteSessionError.invalidConfiguration("Could not resolve remote home directory for `~`")
            }
            let suffix = String(trimmed.dropFirst(2))
            let resolved = URL(fileURLWithPath: home).appendingPathComponent(suffix).path
            await log(
                level: .debug,
                category: "remote.connection.cwd",
                message: "Resolved remote home directory",
                payload: "\(trimmed) -> \(resolved)"
            )
            return resolved
        }

        return trimmed
    }

    private func resolveRemoteHomeDirectory() async throws -> String? {
        if let remoteHomeDirectory, !remoteHomeDirectory.isEmpty {
            return remoteHomeDirectory
        }

        do {
            let output = try await dependencies.processExecutor.run("/usr/bin/ssh", arguments: [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                host.sshTarget,
                "printf '%s' \"$HOME\""
            ])
            let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
            remoteHomeDirectory = home.isEmpty ? nil : home
            await log(
                level: .debug,
                category: "remote.connection.cwd",
                message: "Resolved remote $HOME",
                payload: remoteHomeDirectory
            )
            return remoteHomeDirectory
        } catch {
            await log(
                level: .error,
                category: "remote.connection.cwd",
                message: "Failed to resolve remote $HOME",
                payload: error.localizedDescription
            )
            throw error
        }
    }

    private func stringValue(forKey key: String, in params: [String: Any]) -> String? {
        params[key] as? String
    }

    private func payloadString(from value: AnyCodable?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else {
            return String(describing: value.value)
        }
        return String(data: data, encoding: .utf8)
    }

    private func rpcIDString(_ id: RemoteRPCID) -> String {
        switch id {
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }

    private func log(
        level: RemoteDiagnosticsRecord.Level,
        category: String,
        requestId: String? = nil,
        method: String? = nil,
        threadId: String? = nil,
        turnId: String? = nil,
        itemId: String? = nil,
        message: String,
        payload: String? = nil,
        exitCode: Int32? = nil,
        stderr: String? = nil,
        willRetry: Bool? = nil
    ) async {
        await dependencies.diagnosticsLogger.log(
            RemoteDiagnosticsRecord(
                level: level,
                category: category,
                hostId: host.id,
                hostName: host.displayName,
                sshTarget: host.sshTarget,
                connectionId: connectionId,
                requestId: requestId,
                method: method,
                threadId: threadId,
                turnId: turnId,
                itemId: itemId,
                message: message,
                payload: payload,
                exitCode: exitCode,
                stderr: stderr,
                willRetry: willRetry
            )
        )
    }
}
