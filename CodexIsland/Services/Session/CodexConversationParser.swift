//
//  CodexConversationParser.swift
//  CodexIsland
//
//  Parses Codex rollout/transcript JSONL files.
//

import Foundation

actor CodexConversationParser {
    static let shared = CodexConversationParser()

    private struct Snapshot {
        let modificationDate: Date
        let messages: [ChatMessage]
        let messageIds: Set<String>
        let completedToolIds: Set<String>
        let toolResults: [String: ConversationParser.ToolResult]
        let structuredResults: [String: ToolResultData]
        let pendingInteractions: [PendingInteraction]
        let transcriptPhase: SessionPhase?
        let conversationInfo: ConversationInfo
    }

    private var snapshots: [String: Snapshot] = [:]

    func parse(sessionId: String, transcriptPath: String?) -> ConversationInfo {
        loadSnapshot(sessionId: sessionId, transcriptPath: transcriptPath)?.conversationInfo
            ?? ConversationInfo(
                summary: nil,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: nil,
                lastUserMessageDate: nil
            )
    }

    func parseFullConversation(sessionId: String, transcriptPath: String?) -> [ChatMessage] {
        loadSnapshot(sessionId: sessionId, transcriptPath: transcriptPath)?.messages ?? []
    }

    func parseIncremental(
        sessionId: String,
        transcriptPath: String?
    ) -> ConversationParser.IncrementalParseResult {
        guard let transcriptPath,
              FileManager.default.fileExists(atPath: transcriptPath),
              let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
              let modDate = attrs[.modificationDate] as? Date else {
            return ConversationParser.IncrementalParseResult(
                newMessages: [],
                allMessages: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                pendingInteractions: [],
                transcriptPhase: nil,
                clearDetected: false
            )
        }

        let key = cacheKey(sessionId: sessionId, transcriptPath: transcriptPath)
        let previous = snapshots[key]
        let snapshot = buildSnapshot(transcriptPath: transcriptPath, modificationDate: modDate)
        snapshots[key] = snapshot

        let newMessages: [ChatMessage]
        if let previous {
            newMessages = snapshot.messages.filter { !previous.messageIds.contains($0.id) }
        } else {
            newMessages = snapshot.messages
        }

        return ConversationParser.IncrementalParseResult(
            newMessages: newMessages,
            allMessages: snapshot.messages,
            completedToolIds: snapshot.completedToolIds,
            toolResults: snapshot.toolResults,
            structuredResults: snapshot.structuredResults,
            pendingInteractions: snapshot.pendingInteractions,
            transcriptPhase: snapshot.transcriptPhase,
            clearDetected: false
        )
    }

    func completedToolIds(sessionId: String, transcriptPath: String?) -> Set<String> {
        loadSnapshot(sessionId: sessionId, transcriptPath: transcriptPath)?.completedToolIds ?? []
    }

    func toolResults(sessionId: String, transcriptPath: String?) -> [String: ConversationParser.ToolResult] {
        loadSnapshot(sessionId: sessionId, transcriptPath: transcriptPath)?.toolResults ?? [:]
    }

    func structuredResults(sessionId: String, transcriptPath: String?) -> [String: ToolResultData] {
        loadSnapshot(sessionId: sessionId, transcriptPath: transcriptPath)?.structuredResults ?? [:]
    }

    func pendingInteractions(sessionId: String, transcriptPath: String?) -> [PendingInteraction] {
        loadSnapshot(sessionId: sessionId, transcriptPath: transcriptPath)?.pendingInteractions ?? []
    }

    func transcriptPhase(sessionId: String, transcriptPath: String?) -> SessionPhase? {
        loadSnapshot(sessionId: sessionId, transcriptPath: transcriptPath)?.transcriptPhase
    }

    private func loadSnapshot(sessionId: String, transcriptPath: String?) -> Snapshot? {
        guard let transcriptPath,
              FileManager.default.fileExists(atPath: transcriptPath),
              let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }

        let key = cacheKey(sessionId: sessionId, transcriptPath: transcriptPath)
        if let cached = snapshots[key], cached.modificationDate == modDate {
            return cached
        }

        let snapshot = buildSnapshot(transcriptPath: transcriptPath, modificationDate: modDate)
        snapshots[key] = snapshot
        return snapshot
    }

    private func cacheKey(sessionId: String, transcriptPath: String) -> String {
        "\(sessionId):\(transcriptPath)"
    }

    private func buildSnapshot(transcriptPath: String, modificationDate: Date) -> Snapshot {
        guard let data = FileManager.default.contents(atPath: transcriptPath),
              let content = String(data: data, encoding: .utf8) else {
            return Snapshot(
                modificationDate: modificationDate,
                messages: [],
                messageIds: [],
                completedToolIds: [],
                toolResults: [:],
                structuredResults: [:],
                pendingInteractions: [],
                transcriptPhase: nil,
                conversationInfo: ConversationInfo(
                    summary: nil,
                    lastMessage: nil,
                    lastMessageRole: nil,
                    lastToolName: nil,
                    firstUserMessage: nil,
                    lastUserMessageDate: nil
                )
            )
        }

        var messages: [ChatMessage] = []
        var completedToolIds: Set<String> = []
        var toolResults: [String: ConversationParser.ToolResult] = [:]
        var pendingInteractionOrder: [String] = []
        var pendingInteractions: [String: PendingInteraction] = [:]
        var transcriptPhase: SessionPhase?

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        for (lineIndex, line) in lines.enumerated() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let lineType = json["type"] as? String else {
                continue
            }

            let timestamp = parseTimestamp(json["timestamp"] as? String)

            switch lineType {
            case "response_item":
                guard let payload = json["payload"] as? [String: Any] else { continue }
                parseResponseItem(
                    payload,
                    lineIndex: lineIndex,
                    timestamp: timestamp,
                    messages: &messages,
                    completedToolIds: &completedToolIds,
                    toolResults: &toolResults,
                    pendingInteractionOrder: &pendingInteractionOrder,
                    pendingInteractions: &pendingInteractions,
                    transcriptPhase: &transcriptPhase
                )
            case "event_msg":
                guard let payload = json["payload"] as? [String: Any],
                      let eventType = payload["type"] as? String,
                      let eventPayload = payload["payload"] as? [String: Any] else {
                    continue
                }
                parseEventMsg(
                    eventType: eventType,
                    payload: eventPayload,
                    completedToolIds: &completedToolIds,
                    toolResults: &toolResults,
                    pendingInteractionOrder: &pendingInteractionOrder,
                    pendingInteractions: &pendingInteractions,
                    transcriptPhase: &transcriptPhase
                )
            default:
                continue
            }
        }

        messages.sort { $0.timestamp < $1.timestamp }
        let orderedPendingInteractions = pendingInteractionOrder.compactMap { pendingInteractions[$0] }
        let conversationInfo = buildConversationInfo(
            messages: messages,
            pendingInteractions: orderedPendingInteractions
        )

        return Snapshot(
            modificationDate: modificationDate,
            messages: messages,
            messageIds: Set(messages.map(\.id)),
            completedToolIds: completedToolIds,
            toolResults: toolResults,
            structuredResults: [:],
            pendingInteractions: orderedPendingInteractions,
            transcriptPhase: finalizeTranscriptPhase(
                transcriptPhase,
                pendingInteractions: orderedPendingInteractions
            ),
            conversationInfo: conversationInfo
        )
    }

    private func parseResponseItem(
        _ payload: [String: Any],
        lineIndex: Int,
        timestamp: Date,
        messages: inout [ChatMessage],
        completedToolIds: inout Set<String>,
        toolResults: inout [String: ConversationParser.ToolResult],
        pendingInteractionOrder: inout [String],
        pendingInteractions: inout [String: PendingInteraction],
        transcriptPhase: inout SessionPhase?
    ) {
        guard let payloadType = payload["type"] as? String else { return }

        switch payloadType {
        case "message":
            let rawRole = payload["role"] as? String
            guard rawRole != "developer", rawRole != "system" else { return }

            let role = rawRole.flatMap(ChatRole.init(rawValue:)) ?? .assistant
            let blocks = parseMessageBlocks(payload["content"] as? [[String: Any]]).filter { block in
                guard case .text(let text) = block else { return true }
                return !isCodexInjectedText(text)
            }
            guard !blocks.isEmpty else { return }
            messages.append(ChatMessage(
                id: "codex-message-\(lineIndex)",
                role: role,
                timestamp: timestamp,
                content: blocks
            ))

        case "reasoning":
            let text = parseReasoningText(payload)
            guard !text.isEmpty else { return }
            messages.append(ChatMessage(
                id: "codex-reasoning-\(lineIndex)",
                role: .assistant,
                timestamp: timestamp,
                content: [.thinking(text)]
            ))

        case "local_shell_call":
            let callId = (payload["call_id"] as? String) ?? "local-shell-\(lineIndex)"
            let command = parseLocalShellCommand(payload)
            transcriptPhase = .processing
            messages.append(ChatMessage(
                id: "codex-tool-\(callId)",
                role: .assistant,
                timestamp: timestamp,
                content: [.toolUse(ToolUseBlock(id: callId, name: "Bash", input: ["command": command]))]
            ))

        case "function_call":
            guard let callId = payload["call_id"] as? String else { return }
            let name = payload["name"] as? String ?? "Tool"
            let arguments = payload["arguments"] as? String
            transcriptPhase = .processing
            messages.append(ChatMessage(
                id: "codex-tool-\(callId)",
                role: .assistant,
                timestamp: timestamp,
                content: [.toolUse(ToolUseBlock(id: callId, name: name, input: parseJSONStringInput(arguments)))]
            ))
            if let interaction = parsePendingInteraction(
                callId: callId,
                toolName: name,
                arguments: arguments
            ) {
                pendingInteractions[interaction.id] = interaction
                if !pendingInteractionOrder.contains(interaction.id) {
                    pendingInteractionOrder.append(interaction.id)
                }
            }

        case "custom_tool_call":
            guard let callId = payload["call_id"] as? String else { return }
            let name = payload["name"] as? String ?? "CustomTool"
            let input = payload["input"] as? String ?? ""
            transcriptPhase = .processing
            messages.append(ChatMessage(
                id: "codex-tool-\(callId)",
                role: .assistant,
                timestamp: timestamp,
                content: [.toolUse(ToolUseBlock(id: callId, name: name, input: ["input": input]))]
            ))

        case "tool_search_call":
            let callId = (payload["call_id"] as? String) ?? "tool-search-\(lineIndex)"
            transcriptPhase = .processing
            messages.append(ChatMessage(
                id: "codex-tool-\(callId)",
                role: .assistant,
                timestamp: timestamp,
                content: [.toolUse(ToolUseBlock(id: callId, name: "ToolSearch", input: parseJSONObjectInput(payload["arguments"] as? [String: Any])))]
            ))

        case "web_search_call":
            let callId = (payload["id"] as? String) ?? "web-search-\(lineIndex)"
            transcriptPhase = .processing
            messages.append(ChatMessage(
                id: "codex-tool-\(callId)",
                role: .assistant,
                timestamp: timestamp,
                content: [.toolUse(ToolUseBlock(id: callId, name: "WebSearch", input: parseWebSearchInput(payload["action"] as? [String: Any])))]
            ))
            if let result = parseWebSearchResult(payload["action"] as? [String: Any]) {
                completedToolIds.insert(callId)
                toolResults[callId] = ConversationParser.ToolResult(
                    content: result,
                    stdout: nil,
                    stderr: nil,
                    isError: false
                )
            }

        case "image_generation_call":
            let callId = (payload["id"] as? String) ?? "image-generation-\(lineIndex)"
            transcriptPhase = .processing
            messages.append(ChatMessage(
                id: "codex-tool-\(callId)",
                role: .assistant,
                timestamp: timestamp,
                content: [.toolUse(ToolUseBlock(id: callId, name: "ImageGeneration", input: [:]))]
            ))
            if let result = payload["revised_prompt"] as? String ?? payload["result"] as? String {
                completedToolIds.insert(callId)
                toolResults[callId] = ConversationParser.ToolResult(
                    content: result,
                    stdout: nil,
                    stderr: nil,
                    isError: false
                )
            }

        case "function_call_output":
            guard let callId = payload["call_id"] as? String else { return }
            let output = parseOutputText(payload["output"])
            completedToolIds.insert(callId)
            toolResults[callId] = ConversationParser.ToolResult(
                content: output,
                stdout: nil,
                stderr: nil,
                isError: false
            )
            pendingInteractions.removeValue(forKey: callId)
            pendingInteractionOrder.removeAll { $0 == callId }

        case "custom_tool_call_output":
            guard let callId = payload["call_id"] as? String else { return }
            let output = parseOutputText(payload["output"])
            completedToolIds.insert(callId)
            toolResults[callId] = ConversationParser.ToolResult(
                content: output,
                stdout: nil,
                stderr: nil,
                isError: false
            )
            pendingInteractions.removeValue(forKey: callId)
            pendingInteractionOrder.removeAll { $0 == callId }

        case "tool_search_output":
            let callId = (payload["call_id"] as? String) ?? "tool-search-output-\(lineIndex)"
            let result = parseToolSearchOutput(payload)
            completedToolIds.insert(callId)
            toolResults[callId] = ConversationParser.ToolResult(
                content: result,
                stdout: nil,
                stderr: nil,
                isError: false
            )

        default:
            break
        }
    }

    private func parseEventMsg(
        eventType: String,
        payload: [String: Any],
        completedToolIds: inout Set<String>,
        toolResults: inout [String: ConversationParser.ToolResult],
        pendingInteractionOrder: inout [String],
        pendingInteractions: inout [String: PendingInteraction],
        transcriptPhase: inout SessionPhase?
    ) {
        switch eventType {
        case "exec_command_end":
            guard let callId = payload["call_id"] as? String else { return }
            let stdout = payload["stdout"] as? String
            let stderr = payload["stderr"] as? String
            let aggregated = payload["aggregated_output"] as? String
            let exitCode = payload["exit_code"] as? Int ?? 0
            completedToolIds.insert(callId)
            toolResults[callId] = ConversationParser.ToolResult(
                content: aggregated,
                stdout: stdout,
                stderr: stderr,
                isError: exitCode != 0
            )

        case "request_permissions":
            if let interaction = parseRequestPermissionsEvent(payload: payload) {
                pendingInteractions[interaction.id] = interaction
                if !pendingInteractionOrder.contains(interaction.id) {
                    pendingInteractionOrder.append(interaction.id)
                }
            }
            transcriptPhase = .waitingForApproval(PermissionContext(
                toolUseId: payload["call_id"] as? String ?? "request_permissions",
                toolName: "Permissions Request",
                toolInput: nil,
                receivedAt: Date()
            ))

        case "exec_approval_request":
            if let interaction = parseExecApprovalEvent(payload: payload) {
                pendingInteractions[interaction.id] = interaction
                if !pendingInteractionOrder.contains(interaction.id) {
                    pendingInteractionOrder.append(interaction.id)
                }
                transcriptPhase = .waitingForApproval(PermissionContext(
                    toolUseId: interaction.id,
                    toolName: "Command Execution",
                    toolInput: nil,
                    receivedAt: Date()
                ))
            }

        case "request_user_input":
            transcriptPhase = .waitingForInput

        case "turn_complete", "task_complete", "turn_aborted":
            pendingInteractions.removeAll()
            pendingInteractionOrder.removeAll()
            transcriptPhase = .waitingForInput

        default:
            break
        }
    }

    private func finalizeTranscriptPhase(
        _ phase: SessionPhase?,
        pendingInteractions: [PendingInteraction]
    ) -> SessionPhase? {
        if let pending = pendingInteractions.last {
            switch pending {
            case .approval(let approval):
                return .waitingForApproval(PermissionContext(
                    toolUseId: approval.id,
                    toolName: approval.title,
                    toolInput: nil,
                    receivedAt: Date()
                ))
            case .userInput:
                return .waitingForInput
            }
        }
        return phase
    }

    private func buildConversationInfo(
        messages: [ChatMessage],
        pendingInteractions: [PendingInteraction]
    ) -> ConversationInfo {
        let firstUser = messages.first(where: { $0.role == .user })?.textContent
        let lastUser = messages.last(where: { $0.role == .user })
        let lastTool = messages
            .flatMap(\.content)
            .reversed()
            .compactMap { block -> ToolUseBlock? in
                if case .toolUse(let tool) = block { return tool }
                return nil
            }
            .first
        let lastAssistantText = messages
            .reversed()
            .compactMap { message -> String? in
                guard message.role == .assistant else { return nil }
                return message.content.compactMap { block in
                    switch block {
                    case .text(let text), .thinking(let text):
                        return text
                    case .toolUse, .interrupted:
                        return nil
                    }
                }.joined(separator: "\n")
            }
            .first

        let (lastMessage, lastRole, lastToolName): (String?, String?, String?)
        if let latestPending = pendingInteractions.last {
            lastMessage = latestPending.summaryText
            lastRole = "assistant"
            lastToolName = latestPending.isApproval ? latestPending.title : nil
        } else if let lastTool {
            lastMessage = truncate(lastTool.preview)
            lastRole = "tool"
            lastToolName = lastTool.name
        } else {
            lastMessage = truncate(lastAssistantText)
            lastRole = lastAssistantText == nil ? nil : "assistant"
            lastToolName = nil
        }

        return ConversationInfo(
            summary: truncate(firstUser, maxLength: 60),
            lastMessage: lastMessage,
            lastMessageRole: lastRole,
            lastToolName: lastToolName,
            firstUserMessage: truncate(firstUser, maxLength: 50),
            lastUserMessageDate: lastUser?.timestamp
        )
    }

    private func parseMessageBlocks(_ content: [[String: Any]]?) -> [MessageBlock] {
        guard let content else { return [] }
        return content.compactMap { item in
            guard let type = item["type"] as? String else { return nil }
            switch type {
            case "input_text", "output_text":
                guard let text = item["text"] as? String, !text.isEmpty else { return nil }
                return .text(text)
            default:
                return nil
            }
        }
    }

    private func isCodexInjectedText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("# AGENTS.md instructions for ") ||
        trimmed.hasPrefix("<environment_context>") ||
        trimmed.hasPrefix("<permissions instructions>") ||
        trimmed.hasPrefix("<collaboration_mode>") ||
        trimmed.hasPrefix("<skills_instructions>") ||
        trimmed.hasPrefix("<plugins_instructions>") ||
        trimmed.hasPrefix("<apps_instructions>") ||
        trimmed.hasPrefix("<user_instructions>")
    }

    private func parseReasoningText(_ payload: [String: Any]) -> String {
        let summaryText = (payload["summary"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }
        let contentText = (payload["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }
        return (summaryText + contentText).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseLocalShellCommand(_ payload: [String: Any]) -> String {
        guard let action = payload["action"] as? [String: Any],
              let command = action["command"] as? [String] else {
            return ""
        }
        return command.joined(separator: " ")
    }

    private func parsePendingInteraction(
        callId: String,
        toolName: String,
        arguments: String?
    ) -> PendingInteraction? {
        switch toolName {
        case "request_user_input":
            guard let json = parseJSONArguments(arguments),
                  let questions = parseInteractionQuestions(json["questions"] as? [[String: Any]]),
                  !questions.isEmpty else {
                return nil
            }
            return .userInput(PendingUserInputInteraction(
                id: callId,
                title: "Codex needs your input",
                questions: questions,
                transport: .codexLocal(callId: callId, turnId: nil)
            ))
        case "request_permissions":
            guard let json = parseJSONArguments(arguments) else { return nil }
            return .approval(PendingApprovalInteraction(
                id: callId,
                title: "Permissions Request",
                kind: .permissions,
                detail: json["reason"] as? String,
                requestedPermissions: parsePermissionProfile(json["permissions"] as? [String: Any]),
                availableActions: [.allow, .allowForSession, .deny],
                transport: .codexLocal(callId: callId, turnId: nil)
            ))
        default:
            return nil
        }
    }

    private func parseRequestPermissionsEvent(payload: [String: Any]) -> PendingInteraction? {
        guard let callId = payload["call_id"] as? String else { return nil }
        return .approval(PendingApprovalInteraction(
            id: callId,
            title: "Permissions Request",
            kind: .permissions,
            detail: payload["reason"] as? String,
            requestedPermissions: parsePermissionProfile(payload["permissions"] as? [String: Any]),
            availableActions: [.allow, .allowForSession, .deny],
            transport: .codexLocal(callId: callId, turnId: payload["turn_id"] as? String)
        ))
    }

    private func parseExecApprovalEvent(payload: [String: Any]) -> PendingInteraction? {
        let callId = payload["approval_id"] as? String ?? payload["call_id"] as? String
        guard let callId else { return nil }
        let command = parseExecApprovalCommand(payload["command"])
        let detail = [command, payload["reason"] as? String]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")
        let availableActions = parseApprovalActions(payload["available_decisions"]) ?? [.allow, .cancel]
        return .approval(PendingApprovalInteraction(
            id: callId,
            title: "Command Execution",
            kind: .commandExecution,
            detail: detail.isEmpty ? nil : detail,
            requestedPermissions: parsePermissionProfile(payload["additional_permissions"] as? [String: Any]),
            availableActions: availableActions,
            transport: .codexLocal(callId: payload["call_id"] as? String, turnId: payload["turn_id"] as? String)
        ))
    }

    private func parseExecApprovalCommand(_ value: Any?) -> String? {
        if let command = value as? String {
            return command
        }
        if let command = value as? [String] {
            return command.joined(separator: " ")
        }
        if let command = value as? [Any] {
            return command.compactMap { $0 as? String }.joined(separator: " ")
        }
        return nil
    }

    private func parseApprovalActions(_ value: Any?) -> [PendingApprovalAction]? {
        guard let rawArray = value as? [Any] else { return nil }
        let actions = rawArray.compactMap { raw -> PendingApprovalAction? in
            if let string = raw as? String {
                switch string {
                case "approved", "accept":
                    return .allow
                case "approved_for_session", "acceptForSession":
                    return .allowForSession
                case "denied", "decline":
                    return .deny
                case "abort", "cancel":
                    return .cancel
                default:
                    return nil
                }
            }
            return nil
        }
        return actions.isEmpty ? nil : actions
    }

    private func parseInteractionQuestions(_ value: [[String: Any]]?) -> [PendingInteractionQuestion]? {
        guard let value else { return nil }
        let questions = value.compactMap { question -> PendingInteractionQuestion? in
            guard let id = question["id"] as? String,
                  let header = question["header"] as? String,
                  let prompt = question["question"] as? String else {
                return nil
            }

            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> PendingInteractionOption? in
                guard let label = option["label"] as? String else { return nil }
                return PendingInteractionOption(
                    label: label,
                    description: option["description"] as? String
                )
            }

            return PendingInteractionQuestion(
                id: id,
                header: header,
                question: prompt,
                options: options,
                isOther: question["isOther"] as? Bool ?? question["is_other"] as? Bool ?? false,
                isSecret: question["isSecret"] as? Bool ?? question["is_secret"] as? Bool ?? false
            )
        }
        return questions.isEmpty ? nil : questions
    }

    private func parsePermissionProfile(_ value: [String: Any]?) -> InteractionPermissionProfile {
        guard let value else { return .none }

        let networkValue = value["network"] as? [String: Any]
        let fileSystemValue = value["fileSystem"] as? [String: Any] ?? value["file_system"] as? [String: Any]

        return InteractionPermissionProfile(
            networkEnabled: networkValue?["enabled"] as? Bool,
            readRoots: fileSystemValue?["read"] as? [String] ?? [],
            writeRoots: fileSystemValue?["write"] as? [String] ?? []
        )
    }

    private func parseJSONArguments(_ arguments: String?) -> [String: Any]? {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func parseJSONStringInput(_ arguments: String?) -> [String: String] {
        guard let json = parseJSONArguments(arguments) else {
            return [:]
        }
        return parseJSONObjectInput(json)
    }

    private func parseJSONObjectInput(_ json: [String: Any]?) -> [String: String] {
        guard let json else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in json {
            if let stringValue = stringify(value) {
                result[key] = stringValue
            }
        }
        return result
    }

    private func parseWebSearchInput(_ action: [String: Any]?) -> [String: String] {
        guard let action,
              let type = action["type"] as? String else {
            return [:]
        }

        switch type {
        case "search":
            if let query = action["query"] as? String {
                return ["query": query]
            }
            if let queries = action["queries"] as? [String] {
                return ["query": queries.joined(separator: ", ")]
            }
        case "open_page":
            if let url = action["url"] as? String {
                return ["url": url]
            }
        case "find_in_page":
            var result: [String: String] = [:]
            if let url = action["url"] as? String {
                result["url"] = url
            }
            if let pattern = action["pattern"] as? String {
                result["pattern"] = pattern
            }
            return result
        default:
            break
        }

        return [:]
    }

    private func parseWebSearchResult(_ action: [String: Any]?) -> String? {
        guard let action else { return nil }
        return parseWebSearchInput(action)
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
    }

    private func parseToolSearchOutput(_ payload: [String: Any]) -> String {
        if let execution = payload["execution"] as? String, !execution.isEmpty {
            return execution
        }
        if let tools = payload["tools"] as? [Any] {
            return "Returned \(tools.count) tools"
        }
        return ""
    }

    private func parseOutputText(_ output: Any?) -> String? {
        if let output = output as? String {
            return output
        }

        if let items = output as? [[String: Any]] {
            let texts = items.compactMap { item -> String? in
                if let text = item["text"] as? String {
                    return text
                }
                if let content = item["content"] as? String {
                    return content
                }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }

        if let output {
            return stringify(output)
        }

        return nil
    }

    private func stringify(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let array as [String]:
            return array.joined(separator: " ")
        case let array as [Any]:
            if JSONSerialization.isValidJSONObject(array),
               let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return nil
        case let dictionary as [String: Any]:
            if JSONSerialization.isValidJSONObject(dictionary),
               let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return nil
        default:
            return nil
        }
    }

    private func parseTimestamp(_ rawValue: String?) -> Date {
        guard let rawValue else { return Date() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: rawValue) ?? Date()
    }

    private func truncate(_ text: String?, maxLength: Int = 80) -> String? {
        guard let text else { return nil }
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(maxLength - 3)) + "..."
    }
}
