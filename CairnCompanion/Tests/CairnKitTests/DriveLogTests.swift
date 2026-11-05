import Foundation
import Testing
@testable import CairnKit
@testable import CairnProtocol

private func tempLog(maxBytes: Int = 1_000_000) -> DriveLog {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return DriveLog(fileURL: dir.appendingPathComponent("cairn-drive.log"), maxBytes: maxBytes)
}

private func lines(_ url: URL) -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

@Suite struct DriveLogTests {
    @Test func appendsInOrderOneLinePerEvent() {
        let log = tempLog()
        log.record("first")
        log.record("second")
        log.record("third")
        log.flush()
        let written = lines(log.fileURL)
        #expect(written.count == 3)
        #expect(written[0].hasSuffix(" first"))
        #expect(written[1].hasSuffix(" second"))
        #expect(written[2].hasSuffix(" third"))
    }

    @Test func lineStartsWithParseableTimestamp() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.25)
        let line = DriveLog.line("hello", at: date)
        let stamp = String(try #require(line.split(separator: " ").first))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try #require(formatter.date(from: stamp))
        #expect(abs(parsed.timeIntervalSince(date)) < 0.001)
        #expect(line.hasSuffix(" hello\n"))
    }

    @Test func newlinesInMessagesDoNotSplitEvents() {
        let log = tempLog()
        log.record("a\nb")
        log.flush()
        #expect(lines(log.fileURL).count == 1)
    }

    @Test func rotatesToPreviousFileWhenFull() {
        let log = tempLog(maxBytes: 200)
        for i in 0..<20 { log.record("event \(i) padding padding padding") }
        log.flush()
        #expect(FileManager.default.fileExists(atPath: log.previousFileURL.path))
        // Nothing is lost across the two files except what rotated out twice, and the newest event survives.
        #expect(lines(log.fileURL).last?.hasSuffix("event 19 padding padding padding") == true)
        #expect(lines(log.fileURL).count < 20)
    }

    @Test func survivesAnUnwritableLocation() {
        let log = DriveLog(fileURL: URL(fileURLWithPath: "/nonexistent-dir/cairn-drive.log"))
        log.record("dropped silently")
        log.flush() // must not crash or hang
    }
}

// The reconnect schedule moved into LinkMachine's `backoff` state and is tested there
// (LinkMachineTests), where the failure counter it depends on is also under test. The old
// policy incremented that counter on one path only, which is how the app came to retry
// forever at one second (front door docs/ios-rewrite-plan.md § 1).
