//
//  RemoteChatView.swift
//  CodexIsland
//
//  Chat surface for app-server managed remote threads.
//

import SwiftUI

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

    private var approvalTool: String? {
        thread.approvalToolName
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if history.isEmpty {
                emptyState
            } else {
                messageList
            }

            if let tool = approvalTool {
                ChatApprovalBar(
                    tool: tool,
                    toolInput: thread.pendingToolInput,
                    onApprove: { approve() },
                    onDeny: { deny() }
                )
            } else {
                inputBar
            }
        }
        .task {
            if let updated = try? await remoteSessionMonitor.openThread(
                hostId: initialThread.hostId,
                threadId: initialThread.threadId
            ) {
                thread = updated
            }
        }
        .onReceive(remoteSessionMonitor.$threads) { threads in
            if let updated = threads.first(where: { $0.stableId == thread.stableId }) {
                let countChanged = updated.history.count != thread.history.count
                if isAutoscrollPaused && updated.history.count > previousHistoryCount {
                    newMessageCount += updated.history.count - previousHistoryCount
                    previousHistoryCount = updated.history.count
                }
                thread = updated
                if countChanged && !isAutoscrollPaused {
                    shouldScrollToBottom = true
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
                Text(thread.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                Text(thread.sourceLabel)
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

    private let fadeColor = Color.black

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    ForEach(history.reversed()) { item in
                        MessageItemView(item: item, sessionId: thread.threadId)
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
                    sendMessage()
                }

            Button {
                sendMessage()
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

    private var inputPrompt: String {
        if thread.canSteerTurn {
            return "Steer active turn..."
        }
        if thread.canStartTurn {
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

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        resumeAutoscroll()
        shouldScrollToBottom = true

        Task {
            try? await remoteSessionMonitor.sendMessage(thread: thread, text: text)
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
}
