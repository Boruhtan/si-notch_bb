import Foundation
import XCTest
@testable import SINotch

final class CodexDesktopScannerTests: XCTestCase {
    private let session = "11111111-1111-4111-8111-111111111111"
    private let turn = "22222222-2222-4222-8222-222222222222"
    private func line(_ marker: String, date: Date, fields: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(formatter.string(from: date)) info \(marker) \(fields)\n"
    }
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-desktop-test-\(UUID())")
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let folder = root.appendingPathComponent(formatter.string(from: Date()))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, folder.appendingPathComponent("codex-desktop-test-t0-i1-0.log"))
    }
    private func working(_ date: Date) -> String {
        line("[electron-message-handler] Reasoning summary item completed", date: date,
             fields: "threadId=\(session) turnId=\(turn) text=PRIVATE_CONTENT")
    }
    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
    func testWorkingBootstrapCompletionAndNoContentLeak() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(); try working(now).write(to: file, atomically: true, encoding: .utf8)
        var scanner = CodexDesktopScanner(logsRoot: root)
        let initial = scanner.poll(now: now)
        XCTAssertEqual(initial.map(\.event.kind), [.working]); XCTAssertTrue(initial[0].isBootstrap)
        XCTAssertNil(initial[0].event.message); XCTAssertNil(initial[0].event.firstPrompt)
        XCTAssertFalse(String(data: try JSONEncoder().encode(initial[0].event), encoding: .utf8)!.contains("PRIVATE_CONTENT"))
        XCTAssertTrue(scanner.poll(now: now).isEmpty)
        let later = now.addingTimeInterval(1)
        try append(line("[electron-message-handler] [desktop-notifications] received turn-completed notification",
                        date: later, fields: "conversationId=\(session) turnId=\(turn)"), to: file)
        XCTAssertEqual(scanner.poll(now: later).map(\.event.kind), [.completed])
    }
    func testDoesNotReplayCompletedOrStaleHistory() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try working(now.addingTimeInterval(-300)).write(to: file, atomically: true, encoding: .utf8)
        var scanner = CodexDesktopScanner(logsRoot: root)
        XCTAssertTrue(scanner.poll(now: now).isEmpty)
        try append(line("[electron-message-handler] [desktop-notifications] received turn-completed notification",
                        date: now, fields: "conversationId=\(session) turnId=\(turn)"), to: file)
        XCTAssertTrue(scanner.poll(now: now).isEmpty)
    }
    func testSilenceGoesIdleAndFreshActivityResumes() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(); try working(now).write(to: file, atomically: true, encoding: .utf8)
        var scanner = CodexDesktopScanner(logsRoot: root)
        XCTAssertEqual(scanner.poll(now: now).count, 1)
        XCTAssertEqual(scanner.poll(now: now.addingTimeInterval(181)).map(\.event.kind), [.sessionStarted])
        XCTAssertTrue(scanner.poll(now: now.addingTimeInterval(182)).isEmpty)
        try append(working(now.addingTimeInterval(183)), to: file)
        XCTAssertEqual(scanner.poll(now: now.addingTimeInterval(183)).map(\.event.kind), [.working])
    }
    func testOnlySuccessfulStartAndKnownMarkersAreAccepted() {
        let now = Date()
        let fields = "conversationId=\(session) errorCode=null method=turn/start requestId=123"
        XCTAssertEqual(CodexDesktopScanner.parse(line("[AppServerConnection] response_routed", date: now, fields: fields))?.kind, .working)
        XCTAssertNil(CodexDesktopScanner.parse(line("[AppServerConnection] response_routed", date: now, fields: fields.replacingOccurrences(of: "errorCode=null", with: "errorCode=-1"))))
        XCTAssertNil(CodexDesktopScanner.parse(line("[untrusted] user text", date: now, fields: fields)))
        XCTAssertNil(CodexDesktopScanner.parse(working(now).replacingOccurrences(of: session, with: "bad-id")))
    }
    func testPartialLinesAndRotation() throws {
        let (root, file) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), text = working(Date())
        try String(text.dropLast()).write(to: file, atomically: true, encoding: .utf8)
        var scanner = CodexDesktopScanner(logsRoot: root)
        XCTAssertTrue(scanner.poll(now: now).isEmpty)
        try append("\n", to: file)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.working])
        try working(now.addingTimeInterval(1)).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(scanner.poll(now: now.addingTimeInterval(1)).map(\.event.kind), [.working])
    }
}
