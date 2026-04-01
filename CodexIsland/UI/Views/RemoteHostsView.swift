//
//  RemoteHostsView.swift
//  CodexIsland
//
//  Remote host configuration and app-server connection management.
//

import SwiftUI

struct RemoteHostsView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var remoteSessionMonitor = RemoteSessionMonitor.shared

    var body: some View {
        VStack(spacing: 8) {
            MenuRow(
                icon: "chevron.left",
                label: "Back"
            ) {
                viewModel.toggleMenu()
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    if remoteSessionMonitor.hosts.isEmpty {
                        emptyState
                    } else {
                        ForEach(remoteSessionMonitor.hosts) { host in
                            RemoteHostCard(
                                host: host,
                                state: remoteSessionMonitor.hostStates[host.id] ?? .disconnected,
                                onChange: { remoteSessionMonitor.updateHost($0) },
                                onRemove: { remoteSessionMonitor.removeHost(id: host.id) },
                                onConnect: { remoteSessionMonitor.connectHost(id: host.id) },
                                onDisconnect: { remoteSessionMonitor.disconnectHost(id: host.id) },
                                onStartThread: {
                                    Task {
                                        if let thread = try? await remoteSessionMonitor.startThread(hostId: host.id) {
                                            await MainActor.run {
                                                viewModel.showRemoteChat(for: thread)
                                            }
                                        }
                                    }
                                }
                            )
                        }
                    }

                    Button {
                        remoteSessionMonitor.addHost()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 12, weight: .medium))
                            Text("Add Remote Host")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                        }
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.08))
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No remote hosts")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.45))

            Text("Add an SSH target to manage remote app-server threads")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

private struct RemoteHostCard: View {
    let host: RemoteHostConfig
    let state: RemoteHostConnectionState
    let onChange: (RemoteHostConfig) -> Void
    let onRemove: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onStartThread: () -> Void

    @State private var draft: RemoteHostConfig

    init(
        host: RemoteHostConfig,
        state: RemoteHostConnectionState,
        onChange: @escaping (RemoteHostConfig) -> Void,
        onRemove: @escaping () -> Void,
        onConnect: @escaping () -> Void,
        onDisconnect: @escaping () -> Void,
        onStartThread: @escaping () -> Void
    ) {
        self.host = host
        self.state = state
        self.onChange = onChange
        self.onRemove = onRemove
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
        self.onStartThread = onStartThread
        _draft = State(initialValue: host)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(draft.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Text(state.statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(statusColor)
                    .lineLimit(1)
            }

            hostField("Name", text: binding(\.name))
            hostField("SSH Target", text: binding(\.sshTarget))
            hostField("Default CWD", text: binding(\.defaultCwd), placeholder: "/path/on/remote")

            Toggle(isOn: binding(\.isEnabled)) {
                Text("Auto-connect")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
            }
            .toggleStyle(.switch)
            .tint(TerminalColors.green)

            HStack(spacing: 8) {
                Button(state.isConnected ? "Disconnect" : "Connect") {
                    state.isConnected ? onDisconnect() : onConnect()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.9))
                .clipShape(Capsule())
                .disabled(!draft.isValid)

                if state.isConnected {
                    Button("New Thread") {
                        onStartThread()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                }

                Spacer()

                Button("Remove") {
                    onRemove()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
        )
        .onChange(of: host) { _, newHost in
            draft = newHost
        }
    }

    private var statusColor: Color {
        switch state {
        case .connected:
            return TerminalColors.green
        case .connecting:
            return TerminalColors.amber
        case .failed:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        case .disconnected:
            return .white.opacity(0.4)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<RemoteHostConfig, String>) -> Binding<String> {
        Binding {
            draft[keyPath: keyPath]
        } set: { newValue in
            draft[keyPath: keyPath] = newValue
            onChange(draft)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<RemoteHostConfig, Bool>) -> Binding<Bool> {
        Binding {
            draft[keyPath: keyPath]
        } set: { newValue in
            draft[keyPath: keyPath] = newValue
            onChange(draft)
        }
    }

    private func hostField(_ label: String, text: Binding<String>, placeholder: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
            TextField(placeholder ?? label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
        }
    }
}
