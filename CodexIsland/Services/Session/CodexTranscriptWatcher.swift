//
//  CodexTranscriptWatcher.swift
//  CodexIsland
//
//  Watches local Codex rollout transcripts for pending interactions and content updates.
//

import Foundation
import os.log

private let codexTranscriptLogger = Logger(subsystem: "com.codexisland", category: "CodexTranscriptWatcher")

protocol CodexTranscriptWatcherDelegate: AnyObject {
    func didUpdateCodexTranscript(sessionId: String)
}

final class CodexTranscriptWatcher {
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private let sessionId: String
    private let transcriptPath: String
    private let queue = DispatchQueue(label: "com.codexisland.codextranscriptwatcher", qos: .userInitiated)

    weak var delegate: CodexTranscriptWatcherDelegate?

    init(sessionId: String, transcriptPath: String) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
    }

    func start() {
        queue.async { [weak self] in
            self?.startWatching()
        }
    }

    private func startWatching() {
        stopInternal()

        guard FileManager.default.fileExists(atPath: transcriptPath),
              let handle = FileHandle(forReadingAtPath: transcriptPath) else {
            codexTranscriptLogger.warning("Failed to open transcript: \(self.transcriptPath, privacy: .public)")
            return
        }

        fileHandle = handle
        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.delegate?.didUpdateCodexTranscript(sessionId: self.sessionId)
            }
        }

        newSource.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }

        source = newSource
        newSource.resume()
        codexTranscriptLogger.debug("Started transcript watcher for \(self.sessionId.prefix(8), privacy: .public)")
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func stopInternal() {
        if source != nil {
            codexTranscriptLogger.debug("Stopped transcript watcher for \(self.sessionId.prefix(8), privacy: .public)")
        }
        source?.cancel()
        source = nil
    }

    deinit {
        source?.cancel()
    }
}

@MainActor
final class CodexTranscriptWatcherManager {
    static let shared = CodexTranscriptWatcherManager()

    private var watchers: [String: CodexTranscriptWatcher] = [:]
    private var watchedPaths: [String: String] = [:]
    weak var delegate: CodexTranscriptWatcherDelegate?

    private init() {}

    func startWatching(sessionId: String, transcriptPath: String) {
        if watchedPaths[sessionId] == transcriptPath, watchers[sessionId] != nil {
            return
        }

        stopWatching(sessionId: sessionId)

        let watcher = CodexTranscriptWatcher(sessionId: sessionId, transcriptPath: transcriptPath)
        watcher.delegate = delegate
        watcher.start()
        watchers[sessionId] = watcher
        watchedPaths[sessionId] = transcriptPath
    }

    func stopWatching(sessionId: String) {
        watchers[sessionId]?.stop()
        watchers.removeValue(forKey: sessionId)
        watchedPaths.removeValue(forKey: sessionId)
    }

    func stopAll() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
        watchedPaths.removeAll()
    }
}
