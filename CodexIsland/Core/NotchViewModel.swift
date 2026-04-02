//
//  NotchViewModel.swift
//  CodexIsland
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason: Equatable {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(String)
    case remoteHosts
    case remoteChat(RemoteThreadState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .chat(let logicalSessionId): return "chat-\(logicalSessionId)"
        case .remoteHosts: return "remote-hosts"
        case .remoteChat(let thread): return "remote-chat-\(thread.stableId)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        switch contentType {
        case .chat:
            // Large size for chat view
            return CGSize(
                width: min(screenRect.width * 0.5, 600),
                height: 580
            )
        case .remoteChat:
            return CGSize(
                width: min(screenRect.width * 0.56, 680),
                height: 580
            )
        case .menu:
            // Compact size for settings menu
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 560 + screenSelector.expandedPickerHeight + soundSelector.expandedPickerHeight
            )
        case .remoteHosts:
            return CGSize(
                width: min(screenRect.width * 0.48, 560),
                height: 500
            )
        case .instances:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 320
            )
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared
    private let hoverCloseDelay: TimeInterval
    private var hoverCloseWorkItem: DispatchWorkItem?

    // MARK: - Initialization

    init(
        deviceNotchRect: CGRect,
        screenRect: CGRect,
        windowHeight: CGFloat,
        hasPhysicalNotch: Bool,
        hoverCloseDelay: TimeInterval = 2.0,
        monitorEvents: Bool = true
    ) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        self.hoverCloseDelay = hoverCloseDelay
        if monitorEvents {
            setupEventHandlers()
        }
        observeSelectors()
    }

    private func observeSelectors() {
        screenSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        soundSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        if case .remoteChat = contentType { return true }
        return false
    }

    /// The chat session we're viewing (persists across close/open)
    private var currentChatLogicalSessionId: String?
    private var currentRemoteChatThread: RemoteThreadState?

    private func handleMouseMove(_ location: CGPoint) {
        let inNotch = geometry.isPointInNotch(location)
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)
        setHovering(inNotch || inOpened)
    }

    func setHovering(_ hovering: Bool) {
        // Only update if changed to prevent unnecessary re-renders
        guard hovering != isHovering else { return }

        isHovering = hovering

        if hovering {
            cancelScheduledHoverClose()
            if status == .closed || status == .popping {
                notchOpen(reason: .hover)
            }
            return
        }

        scheduleHoverCloseIfNeeded()
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation
        cancelScheduledHoverClose()

        switch status {
        case .opened:
            if geometry.isPointOutsidePanel(location, size: openedSize) {
                notchClose()
            } else if geometry.notchScreenRect.contains(location) {
                // Clicking notch while opened - only close if NOT in chat mode
                if !isInChatMode {
                    notchClose()
                }
            }
        case .closed, .popping:
            if geometry.isPointInNotch(location) {
                notchOpen(reason: .click)
            }
        }
    }

    private func scheduleHoverCloseIfNeeded() {
        guard status == .opened, openReason == .hover else { return }

        cancelScheduledHoverClose()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.status == .opened, self.openReason == .hover, !self.isHovering else { return }
            self.notchClose()
        }
        hoverCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverCloseDelay, execute: workItem)
    }

    private func cancelScheduledHoverClose() {
        hoverCloseWorkItem?.cancel()
        hoverCloseWorkItem = nil
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        cancelScheduledHoverClose()
        openReason = reason
        status = .opened

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatLogicalSessionId = nil
            return
        }

        // Restore chat session if we had one open before
        if let logicalSessionId = currentChatLogicalSessionId {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current == logicalSessionId {
                return
            }
            contentType = .chat(logicalSessionId)
            return
        }

        if let remoteThread = currentRemoteChatThread {
            if case .remoteChat(let current) = contentType,
               current.stableId == remoteThread.stableId,
               current.threadId == remoteThread.threadId {
                return
            }
            contentType = .remoteChat(remoteThread)
        }
    }

    func notchClose() {
        cancelScheduledHoverClose()
        // Save chat session before closing if in chat mode
        if case .chat(let logicalSessionId) = contentType {
            currentChatLogicalSessionId = logicalSessionId
        } else if case .remoteChat(let thread) = contentType {
            currentRemoteChatThread = thread
        }
        status = .closed
        contentType = .instances
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        contentType = contentType == .menu ? .instances : .menu
    }

    func showChat(for session: SessionState) {
        // Avoid unnecessary updates if already showing this chat
        if case .chat(let current) = contentType, current == session.logicalSessionId {
            return
        }
        currentRemoteChatThread = nil
        contentType = .chat(session.logicalSessionId)
    }

    func showRemoteHosts() {
        currentChatLogicalSessionId = nil
        currentRemoteChatThread = nil
        contentType = .remoteHosts
    }

    func showRemoteChat(for thread: RemoteThreadState) {
        if case .remoteChat(let current) = contentType,
           current.stableId == thread.stableId,
           current.threadId == thread.threadId {
            return
        }
        currentChatLogicalSessionId = nil
        currentRemoteChatThread = thread
        contentType = .remoteChat(thread)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatLogicalSessionId = nil
        currentRemoteChatThread = nil
        contentType = .instances
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
}
