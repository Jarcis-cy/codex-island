//
//  RemoteChatView.swift
//  CodexIsland
//
//  Chat surface for app-server managed remote threads.
//

import SwiftUI

enum RemoteChatSubmitAction: Equatable {
    case send(String)
    case command(RemoteSlashCommand, args: String?)
    case rejectSlashCommand(String)
}

enum RemoteSlashCommand: String, CaseIterable, Identifiable {
    case plan = "/plan"
    case model = "/model"
    case permissions = "/permissions"
    case new = "/new"
    case resume = "/resume"

    var id: String { rawValue }

    var title: String { rawValue }

    var bareName: String {
        String(rawValue.dropFirst())
    }

    var description: String {
        switch self {
        case .plan:
            return "切到 Plan mode"
        case .model:
            return "选择模型与 reasoning"
        case .permissions:
            return "选择权限 preset"
        case .new:
            return "新建空白远端会话"
        case .resume:
            return "恢复保存的远端线程"
        }
    }

    var supportsInlineArgs: Bool {
        self == .plan
    }

    var requiresStartableThread: Bool {
        switch self {
        case .plan, .model, .permissions:
            return true
        case .new, .resume:
            return false
        }
    }

    static func matches(for text: String) -> [RemoteSlashCommand] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return [] }
        let token = String(trimmed.dropFirst()).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if token.isEmpty {
            return allCases
        }
        return allCases.filter { $0.bareName.hasPrefix(token.lowercased()) }
    }

    static func submitAction(for text: String) -> RemoteChatSubmitAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            let commandBody = String(trimmed.dropFirst())
            let parts = commandBody.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let first = parts.first else { return nil }
            let name = String(first)
            let args = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if let command = allCases.first(where: { $0.bareName == name }) {
                return .command(command, args: args?.isEmpty == true ? nil : args)
            }
            return .rejectSlashCommand("Unsupported remote command: \(trimmed)")
        }
        return .send(trimmed)
    }
}

private enum RemoteSlashPanel: Equatable {
    case model
    case permissions
    case resume
}

private struct RemoteApprovalPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let description: String
    let approvalPolicy: RemoteAppServerApprovalPolicy
    let sandboxPolicy: RemoteAppServerSandboxPolicy

    static let builtIn: [RemoteApprovalPreset] = [
        RemoteApprovalPreset(
            id: "read-only",
            label: "Read Only",
            description: "Codex can read files in the current workspace. Approval is required to edit files or access the internet.",
            approvalPolicy: .onRequest,
            sandboxPolicy: .readOnly()
        ),
        RemoteApprovalPreset(
            id: "auto",
            label: "Default",
            description: "Codex can read and edit files in the current workspace, and run commands. Approval is required to access the internet or edit other files.",
            approvalPolicy: .onRequest,
            sandboxPolicy: .workspaceWrite()
        ),
        RemoteApprovalPreset(
            id: "full-access",
            label: "Full Access",
            description: "Codex can edit files outside this workspace and access the internet without asking for approval.",
            approvalPolicy: .never,
            sandboxPolicy: .dangerFullAccess
        )
    ]
}

struct RemoteChatView: View {
    let initialThread: RemoteThreadState
    @ObservedObject var remoteSessionMonitor: RemoteSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    @State private var thread: RemoteThreadState
    @State private var inputText: String = ""
    @State private var shouldScrollToBottom: Bool = false
    @State private var isAutoscrollPaused = false
    @State private var newMessageCount = 0
    @State private var previousHistoryCount = 0
    @State private var activeSlashPanel: RemoteSlashPanel?
    @State private var slashFeedbackMessage: String?
    @State private var isSlashPanelLoading = false
    @State private var isExecutingSlashAction = false
    @State private var isOpeningThread = false
    @State private var availableModels: [RemoteAppServerModel] = []
    @State private var selectedModelForEffort: RemoteAppServerModel?
    @State private var resumeCandidates: [RemoteThreadState] = []
    @FocusState private var isInputFocused: Bool

    init(
        initialThread: RemoteThreadState,
        remoteSessionMonitor: RemoteSessionMonitor,
        viewModel: NotchViewModel
    ) {
        self.initialThread = initialThread
        self.remoteSessionMonitor = remoteSessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self._thread = State(initialValue: initialThread)
    }

    private var history: [ChatHistoryItem] {
        thread.history
    }

    private var pendingInteraction: PendingInteraction? {
        thread.primaryPendingInteraction
    }

    private var matchingSlashCommands: [RemoteSlashCommand] {
        guard activeSlashPanel == nil else { return [] }
        return RemoteSlashCommand.matches(for: inputText)
    }

    private var isPlanModeActive: Bool {
        thread.turnContext.collaborationMode?.mode == .plan
    }

    private var shouldLoadThreadDetails: Bool {
        !thread.isLoaded || thread.history.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if isOpeningThread {
                loadingState
            } else if history.isEmpty {
                emptyState
            } else {
                messageList
            }

            if let pendingInteraction {
                PendingInteractionBar(
                    interaction: pendingInteraction,
                    canRespondInline: true,
                    canOpenTerminal: false,
                    onApprovalAction: { action in
                        respondToApproval(action)
                    },
                    onSubmitAnswers: { answers in
                        await respondToQuestions(answers)
                    },
                    onOpenTerminal: {}
                )
                .id(pendingInteraction.id)
            } else {
                composer
            }
        }
        .task {
            remoteSessionMonitor.refreshHost(id: initialThread.hostId)
            await openThreadIfNeeded()
        }
        .onReceive(remoteSessionMonitor.$threads) { threads in
            if let updated = threads.first(where: { $0.stableId == thread.stableId }) {
                let countChanged = updated.history.count != thread.history.count
                let previousThreadId = thread.threadId
                let previousHistoryWasEmpty = thread.history.isEmpty
                if isAutoscrollPaused && updated.history.count > previousHistoryCount {
                    newMessageCount += updated.history.count - previousHistoryCount
                    previousHistoryCount = updated.history.count
                }
                thread = updated
                if countChanged && !isAutoscrollPaused {
                    shouldScrollToBottom = true
                }

                if (previousThreadId != updated.threadId || previousHistoryWasEmpty) && (!updated.isLoaded || updated.history.isEmpty) {
                    Task {
                        await openThreadIfNeeded()
                    }
                }
            }
        }
        .onChange(of: thread.canSendMessage) { _, canSend in
            if canSend && !isInputFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if thread.canSendMessage {
                    isInputFocused = true
                }
            }
        }
        .onChange(of: inputText) { _, newValue in
            if activeSlashPanel == nil,
               !newValue.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
                slashFeedbackMessage = nil
            }
        }
    }

    @State private var isHeaderHovered = false

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.exitChat()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(isHeaderHovered ? 1.0 : 0.6))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(thread.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)

                    if isPlanModeActive {
                        Text("PLAN MODE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.black.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(TerminalColors.amber.opacity(0.95))
                            .clipShape(Capsule())
                    }
                }

                Text(thread.sourceDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)
            }

            Spacer()

            if thread.canInterrupt {
                Button {
                    interrupt()
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
        .onHover { isHeaderHovered = $0 }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.2))
            Text("No thread history yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.4)))
                .scaleEffect(0.8)
            Text("Opening remote session...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private let fadeColor = Color.black

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    ForEach(history.reversed()) { item in
                        MessageItemView(item: item, sessionId: thread.logicalSessionId)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
            }
            .scaleEffect(x: 1, y: -1)
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                if shouldScroll {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    shouldScrollToBottom = false
                    resumeAutoscroll()
                }
            }
            .overlay(alignment: .bottom) {
                if isAutoscrollPaused && newMessageCount > 0 {
                    NewMessagesIndicator(count: newMessageCount) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        resumeAutoscroll()
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if isPlanModeActive {
                planModeBanner
            }

            if let activeSlashPanel {
                slashPanel(activeSlashPanel)
            } else if !matchingSlashCommands.isEmpty {
                slashSuggestionsPanel
            }

            if let slashFeedbackMessage, !slashFeedbackMessage.isEmpty {
                slashFeedbackBanner(message: slashFeedbackMessage)
            }

            inputBar
        }
    }

    private var planModeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(TerminalColors.amber)

            Text("Plan Mode active. `/plan` again will switch back to Default mode.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.72))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(inputPrompt, text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(thread.canSendMessage ? .white : .white.opacity(0.4))
                .focused($isInputFocused)
                .disabled(!thread.canSendMessage)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(thread.canSendMessage ? 0.08 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .onSubmit {
                    handleSubmit()
                }

            Button {
                handleSubmit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(!thread.canSendMessage || inputText.isEmpty ? .white.opacity(0.2) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(!thread.canSendMessage || inputText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24)
            .allowsHitTesting(false)
        }
    }

    private var slashSuggestionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote commands")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            ForEach(matchingSlashCommands) { command in
                Button {
                    handleSlashCommand(command, args: nil)
                } label: {
                    HStack(spacing: 10) {
                        Text(command.title)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                        Text(command.description)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.45))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func slashFeedbackBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundColor(TerminalColors.amber)

            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func slashPanel(_ panel: RemoteSlashPanel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title(for: panel))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                Text(subtitle(for: panel))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Button {
                    dismissSlashPanel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }

            if isSlashPanelLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.vertical, 8)
            } else {
                switch panel {
                case .model:
                    modelPanelContent
                case .permissions:
                    permissionsPanelContent
                case .resume:
                    resumePanelContent
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var modelPanelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selectedModelForEffort {
                Text("Choose reasoning effort for \(selectedModelForEffort.displayName)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))

                ForEach(selectedModelForEffort.supportedReasoningEfforts, id: \.reasoningEffort) { option in
                    slashActionButton(
                        option.reasoningEffort.rawValue,
                        note: option.description
                    ) {
                        await applyModelSelection(
                            model: selectedModelForEffort,
                            effort: option.reasoningEffort
                        )
                    }
                }

                slashActionButton("Use default", note: selectedModelForEffort.defaultReasoningEffort.rawValue) {
                    await applyModelSelection(
                        model: selectedModelForEffort,
                        effort: selectedModelForEffort.defaultReasoningEffort
                    )
                }

                Button("Back") {
                    self.selectedModelForEffort = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .padding(.top, 4)
            } else if availableModels.isEmpty {
                Text("No models available")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                ForEach(availableModels, id: \.id) { model in
                    let isCurrent = model.model == (thread.currentModel ?? thread.turnContext.model)
                    Button {
                        if model.supportedReasoningEfforts.count <= 1 {
                            Task {
                                await applyModelSelection(
                                    model: model,
                                    effort: model.defaultReasoningEffort
                                )
                            }
                        } else {
                            selectedModelForEffort = model
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(model.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.88))
                                if isCurrent {
                                    Text("Current")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.85))
                                        .clipShape(Capsule())
                                }
                                Spacer()
                                Text(model.defaultReasoningEffort.rawValue)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                            Text(model.description)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isExecutingSlashAction)
                }
            }
        }
    }

    private var permissionsPanelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(RemoteApprovalPreset.builtIn) { preset in
                let isCurrent = thread.turnContext.approvalPolicy == preset.approvalPolicy &&
                    thread.turnContext.sandboxPolicy == preset.sandboxPolicy
                Button {
                    Task {
                        await applyPermissionPreset(preset)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(preset.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.88))
                            if isCurrent {
                                Text("Current")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.85))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                        }
                        Text(preset.description)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(3)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isExecutingSlashAction)
            }
        }
    }

    private var resumePanelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if resumeCandidates.isEmpty {
                Text("No other remote threads available on this host")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                ForEach(resumeCandidates) { candidate in
                    Button {
                        Task {
                            await resumeRemoteThread(candidate)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(candidate.displayTitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.88))
                                    .lineLimit(1)
                                Spacer()
                                Text(candidate.updatedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                            Text(candidate.sourceDetail)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isExecutingSlashAction)
                }
            }
        }
    }

    private func title(for panel: RemoteSlashPanel) -> String {
        switch panel {
        case .model:
            return "/model"
        case .permissions:
            return "/permissions"
        case .resume:
            return "/resume"
        }
    }

    private func subtitle(for panel: RemoteSlashPanel) -> String {
        switch panel {
        case .model:
            return "Choose what model and reasoning effort to use."
        case .permissions:
            return "Choose what Codex is allowed to do."
        case .resume:
            return "Resume a saved chat."
        }
    }

    private func slashActionButton(
        _ title: String,
        note: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task {
                await action()
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .disabled(isExecutingSlashAction)
    }

    private var inputPrompt: String {
        if thread.canSteerTurn {
            return "Steer active turn..."
        }
        if thread.canStartTurn {
            if isPlanModeActive {
                return "Message remote Codex in Plan Mode..."
            }
            return "Message remote Codex..."
        }
        return "Remote thread is busy"
    }

    private func pauseAutoscroll() {
        isAutoscrollPaused = true
        previousHistoryCount = history.count
    }

    private func resumeAutoscroll() {
        isAutoscrollPaused = false
        newMessageCount = 0
        previousHistoryCount = history.count
    }

    private func handleSubmit() {
        guard let action = RemoteSlashCommand.submitAction(for: inputText) else { return }

        switch action {
        case .send(let text):
            submitPlainText(text)

        case .command(let command, let args):
            handleSlashCommand(command, args: args)

        case .rejectSlashCommand(let message):
            slashFeedbackMessage = message
        }
    }

    private func handleSlashCommand(_ command: RemoteSlashCommand, args: String?) {
        guard !command.requiresStartableThread || thread.canStartTurn else {
            slashFeedbackMessage = "'/\(command.bareName)' is disabled while a task is in progress."
            return
        }

        if args != nil && !command.supportsInlineArgs {
            slashFeedbackMessage = "Usage: \(command.rawValue)"
            return
        }

        inputText = ""
        resumeAutoscroll()
        slashFeedbackMessage = nil

        switch command {
        case .plan:
            Task {
                await activatePlanMode(andSubmit: args)
            }
        case .model:
            activeSlashPanel = .model
            selectedModelForEffort = nil
            Task {
                await loadModels()
            }
        case .permissions:
            activeSlashPanel = .permissions
        case .new:
            Task {
                await startNewRemoteThread()
            }
        case .resume:
            activeSlashPanel = .resume
            Task {
                await loadResumeCandidates()
            }
        }
    }

    private func dismissSlashPanel() {
        activeSlashPanel = nil
        selectedModelForEffort = nil
        isSlashPanelLoading = false
    }

    private func submitPlainText(_ text: String) {
        slashFeedbackMessage = nil
        resumeAutoscroll()
        shouldScrollToBottom = true

        Task {
            do {
                try await remoteSessionMonitor.sendMessage(thread: thread, text: text)
                await MainActor.run {
                    inputText = ""
                }
            } catch {
                await MainActor.run {
                    slashFeedbackMessage = error.localizedDescription
                }
            }
        }
    }

    private func openThreadIfNeeded() async {
        guard shouldLoadThreadDetails else { return }

        await MainActor.run {
            isOpeningThread = true
        }
        defer {
            Task { @MainActor in
                isOpeningThread = false
            }
        }

        do {
            let updated = try await remoteSessionMonitor.openThread(
                hostId: thread.hostId,
                threadId: thread.threadId
            )
            await MainActor.run {
                thread = updated
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func loadModels() async {
        await MainActor.run {
            isSlashPanelLoading = true
            availableModels = []
            selectedModelForEffort = nil
        }
        do {
            let models = try await remoteSessionMonitor.listModels(hostId: thread.hostId)
            await MainActor.run {
                availableModels = models.filter { !$0.hidden }
                isSlashPanelLoading = false
            }
        } catch {
            await MainActor.run {
                isSlashPanelLoading = false
                activeSlashPanel = nil
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func loadResumeCandidates() async {
        await MainActor.run {
            isSlashPanelLoading = true
            resumeCandidates = []
        }
        do {
            try await remoteSessionMonitor.refreshHostNow(id: thread.hostId)
            let candidates = remoteSessionMonitor.availableThreads(
                hostId: thread.hostId,
                excluding: thread.threadId
            )
            await MainActor.run {
                resumeCandidates = candidates
                isSlashPanelLoading = false
            }
        } catch {
            await MainActor.run {
                isSlashPanelLoading = false
                activeSlashPanel = nil
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func activatePlanMode(andSubmit args: String?) async {
        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            let modes = try await remoteSessionMonitor.listCollaborationModes(hostId: thread.hostId)
            let planMask = modes.first(where: { $0.mode == .plan })
            let defaultMask = modes.first(where: { $0.mode == .default })
            let currentContext = thread.turnContext
            let togglingOff = args == nil && isPlanModeActive

            if togglingOff {
                let effectiveModel = currentContext.effectiveModel ?? currentContext.model
                guard let effectiveModel else {
                    await MainActor.run {
                        slashFeedbackMessage = "Default mode is unavailable right now."
                    }
                    return
                }

                let effectiveEffort = currentContext.effectiveReasoningEffort ?? currentContext.reasoningEffort
                var updatedContext = currentContext
                updatedContext.model = defaultMask?.model ?? effectiveModel
                updatedContext.reasoningEffort = defaultMask?.reasoningEffort ?? effectiveEffort
                updatedContext.collaborationMode = RemoteAppServerCollaborationMode(
                    mode: .default,
                    settings: RemoteAppServerCollaborationSettings(
                        developerInstructions: nil,
                        model: updatedContext.model ?? effectiveModel,
                        reasoningEffort: updatedContext.reasoningEffort
                    )
                )

                let updatedThread = try await remoteSessionMonitor.setTurnContext(
                    thread: thread,
                    turnContext: updatedContext,
                    synchronizeThread: false
                )

                await MainActor.run {
                    thread = updatedThread
                    slashFeedbackMessage = "Plan mode disabled. Default mode will be used for the next turn."
                }
                return
            }

            let planModel = planMask?.model ?? currentContext.effectiveModel ?? currentContext.model
            let planEffort = planMask?.reasoningEffort ?? currentContext.effectiveReasoningEffort ?? currentContext.reasoningEffort

            guard let planModel else {
                await MainActor.run {
                    slashFeedbackMessage = "Plan mode is unavailable right now."
                }
                return
            }

            var updatedContext = currentContext
            updatedContext.model = planModel
            updatedContext.reasoningEffort = planEffort
            updatedContext.collaborationMode = RemoteAppServerCollaborationMode(
                mode: .plan,
                settings: RemoteAppServerCollaborationSettings(
                    developerInstructions: nil,
                    model: planModel,
                    reasoningEffort: planEffort
                )
            )

            let updatedThread = try await remoteSessionMonitor.setTurnContext(
                thread: thread,
                turnContext: updatedContext,
                synchronizeThread: false
            )

            await MainActor.run {
                thread = updatedThread
                slashFeedbackMessage = args == nil
                    ? "Plan mode enabled."
                    : nil
            }

            if let args, !args.isEmpty {
                try await remoteSessionMonitor.sendMessage(thread: updatedThread, text: args)
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func applyModelSelection(
        model: RemoteAppServerModel,
        effort: RemoteAppServerReasoningEffort
    ) async {
        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            var updatedContext = thread.turnContext
            updatedContext.model = model.model
            updatedContext.reasoningEffort = effort
            if let collaborationMode = updatedContext.collaborationMode {
                updatedContext.collaborationMode = RemoteAppServerCollaborationMode(
                    mode: collaborationMode.mode,
                    settings: RemoteAppServerCollaborationSettings(
                        developerInstructions: collaborationMode.settings.developerInstructions,
                        model: model.model,
                        reasoningEffort: effort
                    )
                )
            }

            let updatedThread = try await remoteSessionMonitor.setTurnContext(
                thread: thread,
                turnContext: updatedContext,
                synchronizeThread: true
            )

            await MainActor.run {
                thread = updatedThread
                dismissSlashPanel()
                slashFeedbackMessage = nil
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func applyPermissionPreset(_ preset: RemoteApprovalPreset) async {
        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            var updatedContext = thread.turnContext
            updatedContext.approvalPolicy = preset.approvalPolicy
            updatedContext.approvalsReviewer = .user
            updatedContext.sandboxPolicy = preset.sandboxPolicy

            let updatedThread = try await remoteSessionMonitor.setTurnContext(
                thread: thread,
                turnContext: updatedContext,
                synchronizeThread: true
            )
            remoteSessionMonitor.appendLocalInfoMessage(
                thread: updatedThread,
                message: "Permissions updated to \(preset.label)"
            )

            await MainActor.run {
                thread = updatedThread
                dismissSlashPanel()
                slashFeedbackMessage = nil
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func startNewRemoteThread() async {
        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            let opened = try await remoteSessionMonitor.startFreshThread(hostId: thread.hostId)
            await MainActor.run {
                activeSlashPanel = nil
                slashFeedbackMessage = nil
                thread = opened
                viewModel.showRemoteChat(for: opened)
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func resumeRemoteThread(_ candidate: RemoteThreadState) async {
        await MainActor.run {
            isExecutingSlashAction = true
        }
        defer {
            Task { @MainActor in
                isExecutingSlashAction = false
            }
        }

        do {
            let opened = try await remoteSessionMonitor.openThread(
                hostId: candidate.hostId,
                threadId: candidate.threadId
            )
            await MainActor.run {
                activeSlashPanel = nil
                slashFeedbackMessage = nil
                thread = opened
                viewModel.showRemoteChat(for: opened)
            }
        } catch {
            await MainActor.run {
                slashFeedbackMessage = error.localizedDescription
            }
        }
    }

    private func interrupt() {
        Task {
            try? await remoteSessionMonitor.interrupt(thread: thread)
        }
    }

    private func approve() {
        Task {
            try? await remoteSessionMonitor.approve(thread: thread)
        }
    }

    private func deny() {
        Task {
            try? await remoteSessionMonitor.deny(thread: thread)
        }
    }

    private func respondToApproval(_ action: PendingApprovalAction) {
        Task {
            try? await remoteSessionMonitor.respond(thread: thread, action: action)
        }
    }

    private func respondToQuestions(_ answers: PendingInteractionAnswerPayload) async -> Bool {
        guard case .userInput(let interaction)? = pendingInteraction else { return false }
        do {
            try await remoteSessionMonitor.respond(thread: thread, interaction: interaction, answers: answers)
            return true
        } catch {
            return false
        }
    }
}
