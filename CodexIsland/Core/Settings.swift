//
//  Settings.swift
//  CodexIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let remoteHosts = "remoteHosts"
        static let remoteDiagnosticsLoggingEnabled = "remoteDiagnosticsLoggingEnabled"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Remote Hosts

    static var remoteHosts: [RemoteHostConfig] {
        get {
            guard let data = defaults.data(forKey: Keys.remoteHosts) else {
                return []
            }

            do {
                return try JSONDecoder().decode([RemoteHostConfig].self, from: data)
            } catch {
                return []
            }
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                defaults.set(data, forKey: Keys.remoteHosts)
            } catch {
                defaults.removeObject(forKey: Keys.remoteHosts)
            }
        }
    }

    // MARK: - Remote Diagnostics Logging

    static var remoteDiagnosticsLoggingEnabled: Bool {
        get {
            defaults.bool(forKey: Keys.remoteDiagnosticsLoggingEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.remoteDiagnosticsLoggingEnabled)
        }
    }
}
