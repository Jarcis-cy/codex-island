//
//  RemoteHostConfig.swift
//  CodexIsland
//
//  User-configured SSH targets for remote app-server sessions.
//

import Foundation

struct RemoteHostConfig: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var sshTarget: String
    var defaultCwd: String
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String = "",
        sshTarget: String = "",
        defaultCwd: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.sshTarget = sshTarget
        self.defaultCwd = defaultCwd
        self.isEnabled = isEnabled
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        let target = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? "Remote Host" : target
    }

    var isValid: Bool {
        !sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum RemoteHostConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }

    var statusText: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .failed(let message):
            return message.isEmpty ? "Failed" : message
        }
    }
}
