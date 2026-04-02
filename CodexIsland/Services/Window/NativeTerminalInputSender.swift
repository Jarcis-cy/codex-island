//
//  NativeTerminalInputSender.swift
//  CodexIsland
//
//  Sends lightweight interactive input back into supported local terminals.
//

import Foundation

nonisolated enum TerminalInputStep: Equatable, Sendable {
    case text(String)
    case key(String)
    case enter
    case escape
}

actor NativeTerminalInputSender {
    static let shared = NativeTerminalInputSender()

    private init() {}

    nonisolated func canSend(to session: SessionState) -> Bool {
        if session.isInTmux, session.tty != nil {
            return true
        }

        let bundleId = session.terminalBundleId
        let terminalName = session.terminalName?.lowercased()

        if bundleId == "com.mitchellh.ghostty" || terminalName == "ghostty" {
            return session.terminalSurfaceId != nil || session.terminalTabId != nil || session.terminalWindowId != nil
        }

        if bundleId == "com.apple.Terminal" || terminalName == "apple_terminal" || terminalName == "terminal" {
            return session.tty != nil
        }

        if bundleId == "com.googlecode.iterm2" || terminalName?.contains("iterm") == true {
            return session.tty != nil
        }

        return false
    }

    func send(steps: [TerminalInputStep], to session: SessionState) async -> Bool {
        guard !steps.isEmpty else { return false }

        if session.isInTmux, let tty = session.tty,
           let target = await TmuxController.shared.findTmuxTarget(forTTY: tty) {
            return await sendToTmux(steps: steps, target: target)
        }

        let bundleId = session.terminalBundleId
        let terminalName = session.terminalName?.lowercased()

        if bundleId == "com.mitchellh.ghostty" || terminalName == "ghostty" {
            if await sendToGhostty(steps: steps, session: session) {
                return true
            }
            return await focusAndSendKeystrokes(steps: steps, session: session)
        }

        if bundleId == "com.googlecode.iterm2" || terminalName?.contains("iterm") == true {
            if await sendToITerm(steps: steps, tty: session.tty) {
                return true
            }
            return await focusAndSendKeystrokes(steps: steps, session: session)
        }

        if bundleId == "com.apple.Terminal" || terminalName == "apple_terminal" || terminalName == "terminal" {
            return await focusAndSendKeystrokes(steps: steps, session: session)
        }

        return false
    }

    private func sendToTmux(steps: [TerminalInputStep], target: TmuxTarget) async -> Bool {
        for step in steps {
            let success: Bool
            switch step {
            case .text(let text):
                success = await ToolApprovalHandler.shared.sendText(text, to: target, pressEnter: false)
            case .key(let key):
                success = await ToolApprovalHandler.shared.sendKey(key, to: target)
            case .enter:
                success = await ToolApprovalHandler.shared.sendKey("Enter", to: target)
            case .escape:
                success = await ToolApprovalHandler.shared.sendKey("Escape", to: target)
            }

            guard success else { return false }
            try? await Task.sleep(for: .milliseconds(40))
        }

        return true
    }

    private func sendToGhostty(steps: [TerminalInputStep], session: SessionState) async -> Bool {
        guard let target = ghosttyTargetSpecifier(session: session) else { return false }

        for step in steps {
            let script: String
            switch step {
            case .text(let text):
                script = """
                tell application "Ghostty"
                    focus \(target)
                    input text "\(appleScriptEscaped(text))" to \(target)
                end tell
                return "ok"
                """
            case .key(let key):
                script = """
                tell application "Ghostty"
                    focus \(target)
                    send key "\(appleScriptEscaped(key))" to \(target)
                end tell
                return "ok"
                """
            case .enter:
                script = """
                tell application "Ghostty"
                    focus \(target)
                    send key "enter" to \(target)
                end tell
                return "ok"
                """
            case .escape:
                script = """
                tell application "Ghostty"
                    focus \(target)
                    send key "escape" to \(target)
                end tell
                return "ok"
                """
            }

            guard await run(script: script) == "ok" else { return false }
            try? await Task.sleep(for: .milliseconds(40))
        }

        return true
    }

    private func sendToITerm(steps: [TerminalInputStep], tty: String?) async -> Bool {
        guard let tty else { return false }
        let shortTTY = appleScriptEscaped(tty.replacingOccurrences(of: "/dev/", with: ""))
        let fullTTY = appleScriptEscaped(tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)")

        for step in steps {
            let command: String
            switch step {
            case .text(let text):
                command = #"write text "\#(appleScriptEscaped(text))" newline no"#
            case .key(let key):
                command = #"write text "\#(appleScriptEscaped(key))" newline no"#
            case .enter:
                command = #"write text "" newline yes"#
            case .escape:
                return false
            }

            let script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            set sessionTTY to (tty of s as text)
                            if sessionTTY is "\(shortTTY)" or sessionTTY is "\(fullTTY)" then
                                tell s
                                    \(command)
                                end tell
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "miss"
            """

            guard await run(script: script) == "ok" else { return false }
            try? await Task.sleep(for: .milliseconds(40))
        }

        return true
    }

    private func focusAndSendKeystrokes(steps: [TerminalInputStep], session: SessionState) async -> Bool {
        guard await NativeTerminalScriptFocuser.shared.focus(session: session) else { return false }

        var commands: [String] = []
        for step in steps {
            switch step {
            case .text(let text):
                commands.append(#"keystroke "\#(appleScriptEscaped(text))""#)
            case .key(let key):
                commands.append(#"keystroke "\#(appleScriptEscaped(key))""#)
            case .enter:
                commands.append("key code 36")
            case .escape:
                commands.append("key code 53")
            }
        }

        let script = """
        tell application "System Events"
            \(commands.joined(separator: "\n    "))
        end tell
        return "ok"
        """

        return await run(script: script) == "ok"
    }

    private func ghosttyTargetSpecifier(session: SessionState) -> String? {
        if let surfaceId = session.terminalSurfaceId {
            return #"terminal id "\#(appleScriptEscaped(surfaceId))""#
        }
        return nil
    }

    private func run(script: String) async -> String? {
        guard let output = await ProcessExecutor.shared.runOrNil("/usr/bin/osascript", arguments: ["-e", script]) else {
            return nil
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
