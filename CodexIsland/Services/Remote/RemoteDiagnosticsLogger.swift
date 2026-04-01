//
//  RemoteDiagnosticsLogger.swift
//  CodexIsland
//
//  Persistent JSONL diagnostics logging for remote app-server traffic.
//

import Foundation

nonisolated protocol RemoteDiagnosticsLogging: Sendable {
    func log(_ record: RemoteDiagnosticsRecord) async
}

nonisolated struct RemoteDiagnosticsRecord: Codable, Sendable {
    nonisolated enum Level: String, Codable, Sendable {
        case debug
        case info
        case warning
        case error
    }

    let timestamp: Date
    let level: Level
    let category: String
    let hostId: String?
    let hostName: String?
    let sshTarget: String?
    let connectionId: String?
    let requestId: String?
    let method: String?
    let threadId: String?
    let turnId: String?
    let itemId: String?
    let message: String
    let payload: String?
    let exitCode: Int32?
    let stderr: String?
    let willRetry: Bool?

    init(
        timestamp: Date = Date(),
        level: Level,
        category: String,
        hostId: String? = nil,
        hostName: String? = nil,
        sshTarget: String? = nil,
        connectionId: String? = nil,
        requestId: String? = nil,
        method: String? = nil,
        threadId: String? = nil,
        turnId: String? = nil,
        itemId: String? = nil,
        message: String,
        payload: String? = nil,
        exitCode: Int32? = nil,
        stderr: String? = nil,
        willRetry: Bool? = nil
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.hostId = hostId
        self.hostName = hostName
        self.sshTarget = sshTarget
        self.connectionId = connectionId
        self.requestId = requestId
        self.method = method
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.message = message
        self.payload = payload
        self.exitCode = exitCode
        self.stderr = stderr
        self.willRetry = willRetry
    }
}

actor RemoteDiagnosticsLogger: RemoteDiagnosticsLogging {
    static let shared = RemoteDiagnosticsLogger()

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let directoryURL: URL
    private let fileURL: URL
    private let maxFileSizeBytes: Int
    private let maxRotatedFiles: Int

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        maxFileSizeBytes: Int = 10 * 1024 * 1024,
        maxRotatedFiles: Int = 5
    ) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        let resolvedDirectory = directoryURL ?? Self.defaultLogsDirectory(fileManager: fileManager)
        self.directoryURL = resolvedDirectory
        self.fileURL = resolvedDirectory.appendingPathComponent("remote-app-server.jsonl")
        self.maxFileSizeBytes = maxFileSizeBytes
        self.maxRotatedFiles = max(1, maxRotatedFiles)
    }

    func log(_ record: RemoteDiagnosticsRecord) async {
        do {
            try ensureDirectoryExists()
            let data = try encoder.encode(record)
            try rotateIfNeeded(incomingByteCount: data.count + 1)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            return
        }
    }

    private func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func rotateIfNeeded(incomingByteCount: Int) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let currentSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize + incomingByteCount > maxFileSizeBytes else { return }

        let oldestURL = rotatedFileURL(index: maxRotatedFiles - 1)
        if fileManager.fileExists(atPath: oldestURL.path) {
            try fileManager.removeItem(at: oldestURL)
        }

        if maxRotatedFiles > 1 {
            for index in stride(from: maxRotatedFiles - 2, through: 1, by: -1) {
                let sourceURL = rotatedFileURL(index: index)
                let destinationURL = rotatedFileURL(index: index + 1)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            }

            let firstRotatedURL = rotatedFileURL(index: 1)
            if fileManager.fileExists(atPath: firstRotatedURL.path) {
                try fileManager.removeItem(at: firstRotatedURL)
            }
            try fileManager.moveItem(at: fileURL, to: firstRotatedURL)
        } else {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func rotatedFileURL(index: Int) -> URL {
        directoryURL.appendingPathComponent("remote-app-server.\(index).jsonl")
    }

    nonisolated private static func defaultLogsDirectory(fileManager: FileManager) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return baseDirectory
            .appendingPathComponent("Codex Island", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }
}
