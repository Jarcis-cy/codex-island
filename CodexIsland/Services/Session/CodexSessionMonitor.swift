//
//  CodexSessionMonitor.swift
//  CodexIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class CodexSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()
    private var codexLivenessTask: Task<Void, Never>?

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
        CodexTranscriptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.provider == .claude && event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.provider == .claude && event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.provider == .codex,
                   let transcriptPath = event.transcriptPath,
                   !transcriptPath.isEmpty {
                    Task { @MainActor in
                        CodexTranscriptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            transcriptPath: transcriptPath
                        )
                    }
                }

                if event.provider == .codex && event.status == "ended" {
                    Task { @MainActor in
                        CodexTranscriptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )

        codexLivenessTask?.cancel()
        codexLivenessTask = Task { [weak self] in
            await self?.monitorCodexProcessLiveness()
        }
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
        CodexTranscriptWatcherManager.shared.stopAll()
        codexLivenessTask?.cancel()
        codexLivenessTask = nil
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "deny",
                reason: reason
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    func respond(sessionId: String, action: PendingApprovalAction) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let interaction = session.primaryPendingInteraction else {
                return
            }

            switch interaction {
            case .approval(let approval):
                switch approval.transport {
                case .hookPermission(let toolUseId):
                    let decision = action == .allow ? "allow" : "deny"
                    HookSocketServer.shared.respondToPermission(toolUseId: toolUseId, decision: decision)
                    if action == .allow {
                        await SessionStore.shared.process(
                            .permissionApproved(sessionId: sessionId, toolUseId: toolUseId)
                        )
                    } else {
                        await SessionStore.shared.process(
                            .permissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: nil)
                        )
                    }
                case .codexLocal:
                    guard let steps = localApprovalSteps(for: approval, action: action),
                          await NativeTerminalInputSender.shared.send(steps: steps, to: session) else {
                        return
                    }
                    await refreshSessionAfterInteraction(session)
                case .remoteAppServer:
                    break
                }
            case .userInput:
                break
            }
        }
    }

    func respond(sessionId: String, answers: PendingInteractionAnswerPayload) async -> Bool {
        guard let session = await SessionStore.shared.session(for: sessionId),
              case .userInput(let interaction)? = session.primaryPendingInteraction,
              interaction.transport.isLocalCodex,
              interaction.supportsInlineResponse,
              let steps = localUserInputSteps(for: interaction, answers: answers),
              await NativeTerminalInputSender.shared.send(steps: steps, to: session) else {
            return false
        }

        let isTerminalAnswer = answers.answers.keys.count == interaction.questions.count
        if isTerminalAnswer {
            await refreshSessionAfterInteraction(session)
        }
        return true
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        let previousSessionIds = Set(instances.map(\.sessionId))
        let currentSessionIds = Set(sessions.map(\.sessionId))
        let removedSessionIds = previousSessionIds.subtracting(currentSessionIds)
        for sessionId in removedSessionIds {
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
            CodexTranscriptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }

        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }

    private func refreshSessionAfterInteraction(_ session: SessionState) async {
        try? await Task.sleep(for: .milliseconds(250))
        await SessionStore.shared.process(.loadHistory(sessionId: session.sessionId, cwd: session.cwd))
    }

    private func monitorCodexProcessLiveness() async {
        while !Task.isCancelled {
            let sessions = await SessionStore.shared.allSessions()
            for session in sessions where session.provider == .codex && (session.phase.isActive || session.needsAttention) {
                guard let pid = session.pid else { continue }
                if !processExists(pid: pid) {
                    await ChatHistoryManager.shared.syncFromFile(sessionId: session.sessionId, cwd: session.cwd)
                    await SessionStore.shared.process(.codexProcessExited(sessionId: session.sessionId))
                }
            }

            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    private nonisolated func processExists(pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    private func localApprovalSteps(
        for interaction: PendingApprovalInteraction,
        action: PendingApprovalAction
    ) -> [TerminalInputStep]? {
        switch interaction.kind {
        case .permissions:
            switch action {
            case .allow:
                return [.key("y")]
            case .allowForSession:
                return [.key("a")]
            case .deny:
                return [.key("n")]
            case .cancel:
                return nil
            }
        case .commandExecution, .fileChange, .generic:
            switch action {
            case .allow:
                return [.key("y")]
            case .allowForSession:
                return interaction.availableActions.contains(.allowForSession) ? [.key("a")] : nil
            case .deny:
                if interaction.availableActions.contains(.deny) {
                    return [.key("d")]
                }
                return nil
            case .cancel:
                if interaction.availableActions.contains(.cancel) {
                    return [.key("n")]
                }
                return nil
            }
        }
    }

    private func localUserInputSteps(
        for interaction: PendingUserInputInteraction,
        answers: PendingInteractionAnswerPayload
    ) -> [TerminalInputStep]? {
        var steps: [TerminalInputStep] = []

        for question in interaction.questions {
            guard let questionAnswers = answers.answers[question.id] else { continue }

            if question.isChoiceQuestion {
                guard let selectedLabel = questionAnswers.first,
                      let optionIndex = question.options.firstIndex(where: { $0.label == selectedLabel }) else {
                    return nil
                }
                steps.append(.key(String(optionIndex + 1)))
                continue
            }

            let text = questionAnswers.first ?? ""
            if !text.isEmpty {
                steps.append(.text(text))
            }
            steps.append(.enter)
        }

        return steps.isEmpty ? nil : steps
    }
}

// MARK: - Interrupt Watcher Delegate

extension CodexSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}

extension CodexSessionMonitor: CodexTranscriptWatcherDelegate {
    nonisolated func didUpdateCodexTranscript(sessionId: String) {
        Task { @MainActor in
            guard let session = await SessionStore.shared.session(for: sessionId) else { return }
            await ChatHistoryManager.shared.syncFromFile(sessionId: sessionId, cwd: session.cwd)
        }
    }
}
