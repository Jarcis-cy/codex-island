//
//  RemoteAppServerTransport.swift
//  CodexIsland
//
//  SSH stdio transport abstraction for remote app-server connections.
//

import Foundation

nonisolated protocol RemoteAppServerTransport: Sendable {
    func start(
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void,
        onTermination: @escaping @Sendable (Int32) async -> Void
    ) async throws
    func send(line: String) async throws
    func stop() async
}

final class SSHStdioTransport: RemoteAppServerTransport, @unchecked Sendable {
    private let host: RemoteHostConfig
    private let ioQueue = DispatchQueue(label: "com.codexisland.remote-transport", qos: .userInitiated)
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    init(host: RemoteHostConfig) {
        self.host = host
    }

    func start(
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void,
        onTermination: @escaping @Sendable (Int32) async -> Void
    ) async throws {
        guard process == nil else { return }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            host.sshTarget,
            "codex", "app-server", "--listen", "stdio://"
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { terminatedProcess in
            Task {
                await onTermination(terminatedProcess.terminationStatus)
            }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        startReaders(
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading,
            onStdoutLine: onStdoutLine,
            onStderrLine: onStderrLine
        )
    }

    func send(line: String) async throws {
        guard let stdinHandle else {
            throw RemoteSessionError.notConnected
        }
        guard let data = line.data(using: .utf8) else {
            throw RemoteSessionError.transport("Failed to encode app-server message")
        }
        try stdinHandle.write(contentsOf: data)
        try stdinHandle.write(contentsOf: Data([0x0A]))
    }

    func stop() async {
        stdoutSource?.cancel()
        stderrSource?.cancel()
        stdoutSource = nil
        stderrSource = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)

        try? stdinHandle?.close()
        stdinHandle = nil

        if let process {
            if process.isRunning {
                process.terminate()
            }
            self.process = nil
        }
    }

    private func startReaders(
        stdout: FileHandle,
        stderr: FileHandle,
        onStdoutLine: @escaping @Sendable (String) async -> Void,
        onStderrLine: @escaping @Sendable (String) async -> Void
    ) {
        let stdoutSource = DispatchSource.makeReadSource(fileDescriptor: stdout.fileDescriptor, queue: ioQueue)
        stdoutSource.setEventHandler { [weak self] in
            self?.drainStdout(handle: stdout, forward: onStdoutLine)
        }
        stdoutSource.setCancelHandler {
            try? stdout.close()
        }
        stdoutSource.resume()
        self.stdoutSource = stdoutSource

        let stderrSource = DispatchSource.makeReadSource(fileDescriptor: stderr.fileDescriptor, queue: ioQueue)
        stderrSource.setEventHandler { [weak self] in
            self?.drainStderr(handle: stderr, forward: onStderrLine)
        }
        stderrSource.setCancelHandler {
            try? stderr.close()
        }
        stderrSource.resume()
        self.stderrSource = stderrSource
    }

    private func drainStdout(
        handle: FileHandle,
        forward: @escaping @Sendable (String) async -> Void
    ) {
        drain(handle: handle, buffer: &stdoutBuffer, forward: forward)
    }

    private func drainStderr(
        handle: FileHandle,
        forward: @escaping @Sendable (String) async -> Void
    ) {
        drain(handle: handle, buffer: &stderrBuffer, forward: forward)
    }

    private func drain(
        handle: FileHandle,
        buffer: inout Data,
        forward: @escaping @Sendable (String) async -> Void
    ) {
        let data = handle.availableData
        guard !data.isEmpty else { return }

        buffer.append(data)
        let newline = Data([0x0A])

        while let range = buffer.range(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            Task {
                await forward(line)
            }
        }
    }
}
