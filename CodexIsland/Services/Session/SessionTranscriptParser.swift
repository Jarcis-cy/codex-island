//
//  SessionTranscriptParser.swift
//  CodexIsland
//
//  Provider-aware transcript parsing facade.
//

import Foundation

actor SessionTranscriptParser {
    static let shared = SessionTranscriptParser()

    func parse(session: SessionState) async -> ConversationInfo {
        switch session.provider {
        case .claude:
            return await ConversationParser.shared.parse(sessionId: session.sessionId, cwd: session.cwd)
        case .codex:
            return await CodexConversationParser.shared.parse(
                sessionId: session.sessionId,
                transcriptPath: session.transcriptPath
            )
        }
    }

    func parseFullConversation(session: SessionState) async -> [ChatMessage] {
        switch session.provider {
        case .claude:
            return await ConversationParser.shared.parseFullConversation(
                sessionId: session.sessionId,
                cwd: session.cwd
            )
        case .codex:
            return await CodexConversationParser.shared.parseFullConversation(
                sessionId: session.sessionId,
                transcriptPath: session.transcriptPath
            )
        }
    }

    func parseIncremental(session: SessionState) async -> ConversationParser.IncrementalParseResult {
        switch session.provider {
        case .claude:
            return await ConversationParser.shared.parseIncremental(
                sessionId: session.sessionId,
                cwd: session.cwd
            )
        case .codex:
            return await CodexConversationParser.shared.parseIncremental(
                sessionId: session.sessionId,
                transcriptPath: session.transcriptPath
            )
        }
    }

    func completedToolIds(session: SessionState) async -> Set<String> {
        switch session.provider {
        case .claude:
            return await ConversationParser.shared.completedToolIds(for: session.sessionId)
        case .codex:
            return await CodexConversationParser.shared.completedToolIds(
                sessionId: session.sessionId,
                transcriptPath: session.transcriptPath
            )
        }
    }

    func toolResults(session: SessionState) async -> [String: ConversationParser.ToolResult] {
        switch session.provider {
        case .claude:
            return await ConversationParser.shared.toolResults(for: session.sessionId)
        case .codex:
            return await CodexConversationParser.shared.toolResults(
                sessionId: session.sessionId,
                transcriptPath: session.transcriptPath
            )
        }
    }

    func structuredResults(session: SessionState) async -> [String: ToolResultData] {
        switch session.provider {
        case .claude:
            return await ConversationParser.shared.structuredResults(for: session.sessionId)
        case .codex:
            return await CodexConversationParser.shared.structuredResults(
                sessionId: session.sessionId,
                transcriptPath: session.transcriptPath
            )
        }
    }

    func pendingInteractions(session: SessionState) async -> [PendingInteraction] {
        switch session.provider {
        case .claude:
            return await ConversationParser.shared.pendingInteractions(for: session.sessionId)
        case .codex:
            return await CodexConversationParser.shared.pendingInteractions(
                sessionId: session.sessionId,
                transcriptPath: session.transcriptPath
            )
        }
    }

    func transcriptPhase(session: SessionState) async -> SessionPhase? {
        switch session.provider {
        case .claude:
            return nil
        case .codex:
            return await CodexConversationParser.shared.transcriptPhase(
                sessionId: session.sessionId,
                transcriptPath: session.transcriptPath
            )
        }
    }
}
