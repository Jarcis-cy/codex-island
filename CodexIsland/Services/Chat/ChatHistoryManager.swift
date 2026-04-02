//
//  ChatHistoryManager.swift
//  CodexIsland
//

import Combine
import Foundation

@MainActor
class ChatHistoryManager: ObservableObject {
    private struct LoadingSource: Hashable {
        let logicalSessionId: String
        let sessionId: String
    }

    static let shared = ChatHistoryManager()

    @Published private(set) var histories: [String: [ChatHistoryItem]] = [:]
    @Published private(set) var agentDescriptions: [String: [String: String]] = [:]

    private var loadedSessions: [String: String] = [:]
    private var loadingSessions: Set<LoadingSource> = []
    private var cancellables = Set<AnyCancellable>()

    private init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func history(for logicalSessionId: String) -> [ChatHistoryItem] {
        histories[logicalSessionId] ?? []
    }

    func isLoaded(logicalSessionId: String, sessionId: String) -> Bool {
        loadedSessions[logicalSessionId] == sessionId
    }

    func loadFromFile(logicalSessionId: String, sessionId: String, cwd: String) async {
        let source = LoadingSource(logicalSessionId: logicalSessionId, sessionId: sessionId)
        guard loadedSessions[logicalSessionId] != sessionId,
              !loadingSessions.contains(source) else { return }

        loadingSessions.insert(source)
        defer { loadingSessions.remove(source) }

        await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        guard let session = await SessionStore.shared.session(for: sessionId) else { return }
        guard session.transcriptPath != nil || !session.chatItems.isEmpty else { return }
        loadedSessions[logicalSessionId] = sessionId
    }

    func syncFromFile(sessionId: String, cwd: String) async {
        guard let session = await SessionStore.shared.session(for: sessionId) else { return }
        let messages = await SessionTranscriptParser.shared.parseFullConversation(session: session)
        let completedTools = await SessionTranscriptParser.shared.completedToolIds(session: session)
        let toolResults = await SessionTranscriptParser.shared.toolResults(session: session)
        let structuredResults = await SessionTranscriptParser.shared.structuredResults(session: session)
        let pendingInteractions = await SessionTranscriptParser.shared.pendingInteractions(session: session)
        let transcriptPhase = await SessionTranscriptParser.shared.transcriptPhase(session: session)

        let payload = FileUpdatePayload(
            sessionId: sessionId,
            cwd: cwd,
            messages: messages,
            isIncremental: false,  // Full sync
            completedToolIds: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            pendingInteractions: pendingInteractions,
            transcriptPhase: transcriptPhase
        )

        await SessionStore.shared.process(.fileUpdated(payload))
    }

    func clearHistory(for logicalSessionId: String, sessionId: String?) {
        loadedSessions.removeValue(forKey: logicalSessionId)
        loadingSessions = loadingSessions.filter { $0.logicalSessionId != logicalSessionId }
        histories.removeValue(forKey: logicalSessionId)
        Task {
            if let sessionId {
                await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
            }
        }
    }

    func resetForTesting() {
        histories = [:]
        agentDescriptions = [:]
        loadedSessions = [:]
        loadingSessions = []
    }

    // MARK: - State Updates

    private func updateFromSessions(_ sessions: [SessionState]) {
        var newHistories: [String: [ChatHistoryItem]] = [:]
        var newAgentDescriptions: [String: [String: String]] = [:]
        let activeLogicalIds = Set(sessions.map(\.logicalSessionId))
        loadedSessions = loadedSessions.filter { activeLogicalIds.contains($0.key) }
        loadingSessions = loadingSessions.filter { activeLogicalIds.contains($0.logicalSessionId) }

        for session in sessions {
            let filteredItems = filterOutSubagentTools(session.chatItems)
            newHistories[session.logicalSessionId] = filteredItems
            newAgentDescriptions[session.logicalSessionId] = session.subagentState.agentDescriptions
            if !filteredItems.isEmpty {
                loadedSessions[session.logicalSessionId] = session.sessionId
            }
        }
        histories = newHistories
        agentDescriptions = newAgentDescriptions
    }

    private func filterOutSubagentTools(_ items: [ChatHistoryItem]) -> [ChatHistoryItem] {
        var subagentToolIds = Set<String>()
        for item in items {
            if case .toolCall(let tool) = item.type, tool.name == "Task" {
                for subagentTool in tool.subagentTools {
                    subagentToolIds.insert(subagentTool.id)
                }
            }
        }

        return items.filter { !subagentToolIds.contains($0.id) && !isCodexInjectedItem($0) }
    }

    private func isCodexInjectedItem(_ item: ChatHistoryItem) -> Bool {
        switch item.type {
        case .user(let text), .assistant(let text):
            return isCodexInjectedText(text)
        case .toolCall, .thinking, .interrupted:
            return false
        }
    }

    private func isCodexInjectedText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("# AGENTS.md instructions for ") ||
        trimmed.hasPrefix("<environment_context>") ||
        trimmed.hasPrefix("<permissions instructions>") ||
        trimmed.hasPrefix("<collaboration_mode>") ||
        trimmed.hasPrefix("<turn_aborted>") ||
        trimmed.hasPrefix("<skills_instructions>") ||
        trimmed.hasPrefix("<plugins_instructions>") ||
        trimmed.hasPrefix("<apps_instructions>") ||
        trimmed.hasPrefix("<user_instructions>")
    }
}

// MARK: - Models

nonisolated struct ChatHistoryItem: Identifiable, Equatable, Sendable {
    let id: String
    let type: ChatHistoryItemType
    let timestamp: Date

    static func == (lhs: ChatHistoryItem, rhs: ChatHistoryItem) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type
    }
}

nonisolated enum ChatHistoryItemType: Equatable, Sendable {
    case user(String)
    case assistant(String)
    case toolCall(ToolCallItem)
    case thinking(String)
    case interrupted
}

nonisolated struct ToolCallItem: Equatable, Sendable {
    let name: String
    let input: [String: String]
    var status: ToolStatus
    var result: String?
    var structuredResult: ToolResultData?

    /// For Task tools: nested subagent tool calls
    var subagentTools: [SubagentToolCall]

    /// Preview text for the tool (input-based)
    var inputPreview: String {
        if let filePath = input["file_path"] ?? input["path"] {
            return URL(fileURLWithPath: filePath).lastPathComponent
        }
        if let command = input["command"] {
            let firstLine = command.components(separatedBy: "\n").first ?? command
            return String(firstLine.prefix(60))
        }
        if let pattern = input["pattern"] {
            return pattern
        }
        if let query = input["query"] {
            return query
        }
        if let url = input["url"] {
            return url
        }
        if let agentId = input["agentId"] {
            let blocking = input["block"] == "true"
            return blocking ? "Waiting..." : "Checking \(agentId.prefix(8))..."
        }
        return input.values.first.map { String($0.prefix(60)) } ?? ""
    }

    /// Status display text for the tool
    var statusDisplay: ToolStatusDisplay {
        if status == .running {
            return ToolStatusDisplay.running(for: name, input: input)
        }
        if status == .waitingForApproval {
            return ToolStatusDisplay(text: "Waiting for approval...", isRunning: true)
        }
        if status == .interrupted {
            return ToolStatusDisplay(text: "Interrupted", isRunning: false)
        }
        return ToolStatusDisplay.completed(for: name, result: structuredResult)
    }

    // Custom Equatable implementation to handle structuredResult
    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.name == rhs.name &&
        lhs.input == rhs.input &&
        lhs.status == rhs.status &&
        lhs.result == rhs.result &&
        lhs.structuredResult == rhs.structuredResult &&
        lhs.subagentTools == rhs.subagentTools
    }
}

nonisolated enum ToolStatus: Sendable, CustomStringConvertible {
    case running
    case waitingForApproval
    case success
    case error
    case interrupted

    nonisolated var description: String {
        switch self {
        case .running: return "running"
        case .waitingForApproval: return "waitingForApproval"
        case .success: return "success"
        case .error: return "error"
        case .interrupted: return "interrupted"
        }
    }
}

// Explicit nonisolated Equatable conformance to avoid actor isolation issues
extension ToolStatus: Equatable {
    nonisolated static func == (lhs: ToolStatus, rhs: ToolStatus) -> Bool {
        switch (lhs, rhs) {
        case (.running, .running): return true
        case (.waitingForApproval, .waitingForApproval): return true
        case (.success, .success): return true
        case (.error, .error): return true
        case (.interrupted, .interrupted): return true
        default: return false
        }
    }
}

extension ToolStatus: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .running:
            hasher.combine(0)
        case .waitingForApproval:
            hasher.combine(1)
        case .success:
            hasher.combine(2)
        case .error:
            hasher.combine(3)
        case .interrupted:
            hasher.combine(4)
        }
    }
}

// MARK: - Subagent Tool Call

/// Represents a tool call made by a subagent (Task tool)
nonisolated struct SubagentToolCall: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let input: [String: String]
    var status: ToolStatus
    let timestamp: Date

    /// Short description for display
    var displayText: String {
        switch name {
        case "Read":
            if let path = input["file_path"] {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return "Reading..."
        case "Grep":
            if let pattern = input["pattern"] {
                return "grep: \(pattern)"
            }
            return "Searching..."
        case "Glob":
            if let pattern = input["pattern"] {
                return "glob: \(pattern)"
            }
            return "Finding files..."
        case "Bash":
            if let desc = input["description"] {
                return desc
            }
            if let cmd = input["command"] {
                let firstLine = cmd.components(separatedBy: "\n").first ?? cmd
                return String(firstLine.prefix(40))
            }
            return "Running command..."
        case "Edit":
            if let path = input["file_path"] {
                return "Edit: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Editing..."
        case "Write":
            if let path = input["file_path"] {
                return "Write: \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Writing..."
        case "WebFetch":
            if let url = input["url"] {
                return "Fetching: \(url.prefix(30))..."
            }
            return "Fetching..."
        case "WebSearch":
            if let query = input["query"] {
                return "Search: \(query.prefix(30))"
            }
            return "Searching web..."
        default:
            return name
        }
    }
}
