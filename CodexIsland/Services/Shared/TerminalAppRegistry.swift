//
//  TerminalAppRegistry.swift
//  CodexIsland
//
//  Centralized registry of known terminal applications
//

import AppKit
import Foundation

/// Registry of known terminal application names and bundle identifiers
nonisolated struct TerminalAppRegistry: Sendable {
    /// Terminal app names for process matching
    nonisolated static let appNames: Set<String> = [
        "Terminal",
        "iTerm2",
        "iTerm",
        "Ghostty",
        "Alacritty",
        "kitty",
        "Hyper",
        "Warp",
        "WezTerm",
        "Tabby",
        "Rio",
        "Contour",
        "foot",
        "st",
        "urxvt",
        "xterm",
        "Code",           // VS Code
        "Code - Insiders",
        "Cursor",
        "Windsurf",
        "zed"
    ]

    /// Bundle identifiers for terminal apps (for window enumeration)
    nonisolated static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed"
    ]

    /// Check if an app name or command path is a known terminal
    nonisolated static func isTerminal(_ appNameOrCommand: String) -> Bool {
        let lower = appNameOrCommand.lowercased()

        // Check if any known app name is contained in the command (case-insensitive)
        for name in appNames {
            if lower.contains(name.lowercased()) {
                return true
            }
        }

        // Additional checks for common patterns
        return lower.contains("terminal") || lower.contains("iterm")
    }

    /// Check if a bundle identifier is a known terminal
    nonisolated static func isTerminalBundle(_ bundleId: String) -> Bool {
        bundleIdentifiers.contains(bundleId)
    }

    /// Infer likely terminal bundle IDs from TERM_PROGRAM / terminal app hints.
    nonisolated static func candidateBundleIdentifiers(for hint: String?) -> [String] {
        guard let hint else { return [] }

        let normalized = hint.lowercased()
        if normalized.contains("apple_terminal") || normalized == "terminal" {
            return ["com.apple.Terminal"]
        }
        if normalized.contains("iterm") {
            return ["com.googlecode.iterm2"]
        }
        if normalized.contains("ghostty") {
            return ["com.mitchellh.ghostty"]
        }
        if normalized.contains("wezterm") {
            return ["com.github.wez.wezterm"]
        }
        if normalized.contains("warp") {
            return ["dev.warp.Warp-Stable"]
        }
        if normalized.contains("kitty") {
            return ["net.kovidgoyal.kitty"]
        }
        if normalized.contains("alacritty") {
            return ["io.alacritty", "org.alacritty"]
        }
        if normalized.contains("hyper") {
            return ["co.zeit.hyper"]
        }
        if normalized.contains("cursor") {
            return ["com.todesktop.230313mzl4w4u92"]
        }
        if normalized.contains("windsurf") {
            return ["com.exafunction.windsurf"]
        }
        if normalized.contains("zed") {
            return ["dev.zed.Zed"]
        }
        if normalized.contains("code") {
            return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        }

        return []
    }

    nonisolated static func runningApplication(bundleId: String?, hint: String?) -> NSRunningApplication? {
        let runningApps = NSWorkspace.shared.runningApplications

        if let bundleId,
           let app = runningApps.first(where: { $0.bundleIdentifier == bundleId }) {
            return app
        }

        for candidate in candidateBundleIdentifiers(for: hint) {
            if let app = runningApps.first(where: { $0.bundleIdentifier == candidate }) {
                return app
            }
        }

        return runningApps.first { app in
            guard let bundleId = app.bundleIdentifier else { return false }
            return isTerminalBundle(bundleId)
        }
    }
}
