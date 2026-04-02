import XCTest
@testable import Codex_Island

final class RemoteAppServerProtocolTests: XCTestCase {
    func testDecodeTurnPlanUpdatedNotification() throws {
        let data = #"""
        {
          "threadId": "thread-1",
          "turnId": "turn-1",
          "explanation": "Syncing plan",
          "plan": [
            { "step": "Inspect remote state", "status": "completed" },
            { "step": "Patch UI", "status": "in_progress" }
          ]
        }
        """#.data(using: .utf8)!
        let payload = try JSONDecoder().decode(RemoteAppServerTurnPlanUpdatedNotification.self, from: data)

        XCTAssertEqual(payload.threadId, "thread-1")
        XCTAssertEqual(payload.turnId, "turn-1")
        XCTAssertEqual(payload.explanation, "Syncing plan")
        XCTAssertEqual(payload.plan.count, 2)
        XCTAssertEqual(payload.plan[1], RemoteAppServerPlanStep(step: "Patch UI", status: "in_progress"))
    }

    func testDecodeLegacyThreadStartResponseWithoutConfigSnapshotFields() throws {
        let data = #"""
        {
          "thread": {
            "id": "thread-1",
            "preview": "Preview",
            "ephemeral": false,
            "modelProvider": "openai",
            "createdAt": 1700000000,
            "updatedAt": 1700000100,
            "status": { "type": "idle" },
            "path": null,
            "cwd": "/tmp",
            "cliVersion": "1.0.0",
            "name": null,
            "turns": []
          }
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(RemoteAppServerThreadStartResponse.self, from: data)

        XCTAssertEqual(response.thread.id, "thread-1")
        XCTAssertNil(response.model)
        XCTAssertNil(response.approvalPolicy)
        XCTAssertNil(response.sandbox)
    }

    func testRemoteSlashSubmitActionRecognizesSupportedCommand() {
        let action = RemoteSlashCommand.submitAction(for: " /plan ")

        XCTAssertEqual(action, .command(.plan, args: nil))
    }

    func testRemoteSlashSubmitActionParsesPlanInlineArgs() {
        let action = RemoteSlashCommand.submitAction(for: "/plan build the plan")

        XCTAssertEqual(action, .command(.plan, args: "build the plan"))
    }

    func testRemoteSlashSubmitActionRejectsUnknownSlashCommand() {
        let action = RemoteSlashCommand.submitAction(for: "/unknown")

        XCTAssertEqual(action, .rejectSlashCommand("Unsupported remote command: /unknown"))
    }

    func testRemoteSlashSubmitActionRecognizesNewCommand() {
        let action = RemoteSlashCommand.submitAction(for: "/new")

        XCTAssertEqual(action, .command(.new, args: nil))
    }

    func testChoiceQuestionWithOtherStillSupportsInlineResponse() {
        let question = PendingInteractionQuestion(
            id: "mode",
            header: "Mode",
            question: "Choose a demo",
            options: [
                PendingInteractionOption(label: "A", description: nil),
                PendingInteractionOption(label: "B", description: nil)
            ],
            isOther: true,
            isSecret: false
        )

        XCTAssertTrue(question.supportsInlineResponse)
    }

    func testDecodeActiveThreadStatus() throws {
        let data = #"{"type":"active","activeFlags":["waitingOnUserInput"]}"#.data(using: .utf8)!
        let status = try JSONDecoder().decode(RemoteAppServerThreadStatus.self, from: data)

        XCTAssertEqual(status, .active(activeFlags: [.waitingOnUserInput]))
    }

    func testDecodeUnknownUserInputFallsBackToUnsupported() throws {
        let data = #"{"type":"audio","url":"https://example.com"}"#.data(using: .utf8)!
        let input = try JSONDecoder().decode(RemoteAppServerUserInput.self, from: data)

        XCTAssertEqual(input, .unsupported)
        XCTAssertNil(input.displayText)
    }

    func testDecodeCommandExecutionItem() throws {
        let data = #"""
        {
          "type":"commandExecution",
          "id":"cmd-1",
          "command":"pwd",
          "cwd":"/tmp",
          "status":"completed",
          "aggregatedOutput":"/tmp"
        }
        """#.data(using: .utf8)!
        let item = try JSONDecoder().decode(RemoteAppServerThreadItem.self, from: data)

        XCTAssertEqual(
            item,
            .commandExecution(
                id: "cmd-1",
                command: "pwd",
                cwd: "/tmp",
                status: .completed,
                aggregatedOutput: "/tmp"
            )
        )
    }

    func testDecodeErrorNotificationAdditionalDetails() throws {
        let data = #"""
        {
          "error": {
            "message": "403 Forbidden",
            "additionalDetails": "Usage not included in your plan"
          },
          "willRetry": false,
          "threadId": "thread-1",
          "turnId": "turn-1"
        }
        """#.data(using: .utf8)!
        let notification = try JSONDecoder().decode(RemoteAppServerErrorNotification.self, from: data)

        XCTAssertEqual(notification.threadId, "thread-1")
        XCTAssertEqual(notification.turnId, "turn-1")
        XCTAssertEqual(notification.error.additionalDetails, "Usage not included in your plan")
        XCTAssertFalse(notification.willRetry)
    }
}
