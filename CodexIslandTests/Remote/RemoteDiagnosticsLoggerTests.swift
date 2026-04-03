import XCTest
@testable import Codex_Island

final class RemoteDiagnosticsLoggerTests: XCTestCase {
    func testLoggerWritesJSONLines() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logger = RemoteDiagnosticsLogger(
            directoryURL: directory,
            maxFileSizeBytes: 1024,
            maxRotatedFiles: 3,
            isEnabled: { true }
        )

        await logger.log(
            RemoteDiagnosticsRecord(
                level: .info,
                category: "remote.test",
                hostId: "host-1",
                message: "hello"
            )
        )

        let fileURL = directory.appendingPathComponent("remote-app-server.jsonl")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("\"category\":\"remote.test\""))
        XCTAssertTrue(contents.contains("\"message\":\"hello\""))
    }

    func testLoggerRotatesFilesWhenThresholdExceeded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logger = RemoteDiagnosticsLogger(
            directoryURL: directory,
            maxFileSizeBytes: 180,
            maxRotatedFiles: 3,
            isEnabled: { true }
        )

        for index in 0..<6 {
            await logger.log(
                RemoteDiagnosticsRecord(
                    level: .info,
                    category: "remote.rotation",
                    message: String(repeating: "record-\(index)-", count: 6)
                )
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("remote-app-server.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("remote-app-server.1.jsonl").path))
    }

    func testLoggerSkipsWritesWhenDisabled() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logger = RemoteDiagnosticsLogger(
            directoryURL: directory,
            maxFileSizeBytes: 1024,
            maxRotatedFiles: 3,
            isEnabled: { false }
        )

        await logger.log(
            RemoteDiagnosticsRecord(
                level: .info,
                category: "remote.test",
                message: "disabled"
            )
        )

        let fileURL = directory.appendingPathComponent("remote-app-server.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
