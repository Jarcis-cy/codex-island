//
//  RemoteSessionState.swift
//  CodexIsland
//
//  App-server backed remote thread state used by the UI.
//

import Foundation

nonisolated enum RemoteRPCID: Hashable, Codable, Sendable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }

        let stringValue = try container.decode(String.self)
        self = .string(stringValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

nonisolated enum RemoteApprovalKind: String, Sendable {
    case commandExecution
    case fileChange
    case permissions
}

nonisolated struct RemotePendingApproval: Identifiable, Equatable, Sendable {
    let id: String
    let requestId: RemoteRPCID
    let kind: RemoteApprovalKind
    let itemId: String
    let threadId: String
    let turnId: String
    let title: String
    let detail: String?
    let requestedPermissions: InteractionPermissionProfile
    let availableActions: [PendingApprovalAction]

    var formattedInput: String? {
        switch kind {
        case .permissions:
            return requestedPermissions.summary ?? detail
        case .commandExecution, .fileChange:
            return detail
        }
    }
}

nonisolated struct RemoteThreadTurnContext: Equatable, Sendable {
    var model: String?
    var reasoningEffort: RemoteAppServerReasoningEffort?
    var approvalPolicy: RemoteAppServerApprovalPolicy?
    var approvalsReviewer: RemoteAppServerApprovalsReviewer?
    var sandboxPolicy: RemoteAppServerSandboxPolicy?
    var serviceTier: RemoteAppServerServiceTier?
    var collaborationMode: RemoteAppServerCollaborationMode?

    static let empty = RemoteThreadTurnContext(
        model: nil,
        reasoningEffort: nil,
        approvalPolicy: nil,
        approvalsReviewer: nil,
        sandboxPolicy: nil,
        serviceTier: nil,
        collaborationMode: nil
    )

    var effectiveModel: String? {
        collaborationMode?.settings.model ?? model
    }

    var effectiveReasoningEffort: RemoteAppServerReasoningEffort? {
        collaborationMode?.settings.reasoningEffort ?? reasoningEffort
    }
}

nonisolated struct RemoteThreadState: Identifiable, Equatable, Sendable {
    let hostId: String
    let hostName: String
    var threadId: String
    var logicalSessionId: String

    var preview: String
    var name: String?
    var cwd: String
    var phase: SessionPhase
    var lastActivity: Date
    var createdAt: Date
    var updatedAt: Date
    var lastMessage: String?
    var lastMessageRole: String?
    var lastToolName: String?
    var lastUserMessageDate: Date?
    var history: [ChatHistoryItem]
    var activeTurnId: String?
    var isLoaded: Bool
    var canSteerTurn: Bool
    var pendingApproval: RemotePendingApproval?
    var pendingInteractions: [PendingInteraction]
    var connectionState: RemoteHostConnectionState
    var turnContext: RemoteThreadTurnContext

    var id: String { stableId }

    var stableId: String {
        logicalSessionId
    }

    var rawStableId: String {
        "remote-\(hostId)-\(threadId)"
    }

    var displayTitle: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preview
        }
        return hostName
    }

    var sourceLabel: String {
        "Remote • \(hostName)"
    }

    var sourceDetail: String {
        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty else { return sourceLabel }
        return "\(sourceLabel) • \(trimmedCwd)"
    }

    var currentModel: String? {
        turnContext.effectiveModel
    }

    var currentReasoningEffort: RemoteAppServerReasoningEffort? {
        turnContext.effectiveReasoningEffort
    }

    var canStartTurn: Bool {
        primaryPendingInteraction == nil && (phase == .idle || phase == .waitingForInput)
    }

    var canSendMessage: Bool {
        primaryPendingInteraction == nil && (canStartTurn || canSteerTurn)
    }

    var needsHydration: Bool {
        !isLoaded
    }

    var canInterrupt: Bool {
        phase == .processing || phase == .compacting
    }

    var approvalToolName: String? {
        if case .approval(let interaction) = primaryPendingInteraction {
            return interaction.title
        }
        return pendingApproval?.title
    }

    var pendingToolInput: String? {
        if case .approval(let interaction) = primaryPendingInteraction {
            return interaction.summaryText
        }
        return pendingApproval?.formattedInput
    }

    var primaryPendingInteraction: PendingInteraction? {
        if let pending = pendingInteractions.first {
            return pending
        }
        if let approval = pendingApproval {
            return .approval(PendingApprovalInteraction(
                id: approval.id,
                title: approval.title,
                kind: approval.pendingKind,
                detail: approval.detail,
                requestedPermissions: approval.requestedPermissions,
                availableActions: approval.availableActions,
                transport: .remoteAppServer(requestId: approval.requestId)
            ))
        }
        return nil
    }

    var needsAttention: Bool {
        primaryPendingInteraction != nil || phase.needsAttention
    }
}

extension RemotePendingApproval {
    nonisolated var pendingKind: PendingApprovalKind {
        switch kind {
        case .commandExecution:
            return .commandExecution
        case .fileChange:
            return .fileChange
        case .permissions:
            return .permissions
        }
    }
}
