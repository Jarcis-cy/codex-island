//
//  RemoteSessionState.swift
//  CodexIsland
//
//  App-server backed remote thread state used by the UI.
//

import Foundation

enum RemoteRPCID: Hashable, Codable, Sendable {
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

enum RemoteApprovalKind: String, Sendable {
    case commandExecution
    case fileChange
    case permissions
}

struct RemotePermissionProfile: Equatable, Sendable {
    var networkEnabled: Bool?
    var readRoots: [String]
    var writeRoots: [String]

    static let none = RemotePermissionProfile(
        networkEnabled: nil,
        readRoots: [],
        writeRoots: []
    )

    var isEmpty: Bool {
        networkEnabled == nil && readRoots.isEmpty && writeRoots.isEmpty
    }

    var summary: String? {
        var parts: [String] = []
        if let networkEnabled {
            parts.append(networkEnabled ? "network: enabled" : "network: restricted")
        }
        if !readRoots.isEmpty {
            parts.append("read: \(readRoots.joined(separator: ", "))")
        }
        if !writeRoots.isEmpty {
            parts.append("write: \(writeRoots.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

struct RemotePendingApproval: Identifiable, Equatable, Sendable {
    let id: String
    let requestId: RemoteRPCID
    let kind: RemoteApprovalKind
    let itemId: String
    let threadId: String
    let turnId: String
    let title: String
    let detail: String?
    let requestedPermissions: RemotePermissionProfile

    var formattedInput: String? {
        switch kind {
        case .permissions:
            return requestedPermissions.summary ?? detail
        case .commandExecution, .fileChange:
            return detail
        }
    }
}

struct RemoteThreadState: Identifiable, Equatable, Sendable {
    let hostId: String
    let hostName: String
    let threadId: String

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
    var connectionState: RemoteHostConnectionState

    var id: String { stableId }

    var stableId: String {
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

    var canStartTurn: Bool {
        pendingApproval == nil && (phase == .idle || phase == .waitingForInput)
    }

    var canSendMessage: Bool {
        pendingApproval == nil && (canStartTurn || canSteerTurn)
    }

    var canInterrupt: Bool {
        phase == .processing || phase == .compacting
    }

    var approvalToolName: String? {
        pendingApproval?.title
    }

    var pendingToolInput: String? {
        pendingApproval?.formattedInput
    }

    var needsAttention: Bool {
        phase.needsAttention
    }
}
