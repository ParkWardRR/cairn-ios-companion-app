import CairnProtocol
import Foundation

/// Append-only event log kept on the phone, so a drive can be reviewed afterwards even though the
/// app spends it locked in a mount. One line per event: local ISO 8601 timestamp, then the message.
/// Two files are kept: the current one and the previous one, swapped when the current one gets large.
/// The default file is `Documents/cairn-drive.log`, visible in the Files app under "On My iPhone > Cairn".
public final class DriveLog: @unchecked Sendable {
    public static let shared = DriveLog(fileURL: defaultFileURL)

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cairn-drive.log")
    }

    public let fileURL: URL
    public var previousFileURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("previous.log")
    }

    private let maxBytes: Int
    private let queue = DispatchQueue(label: "app.cairn.companion.drivelog", qos: .utility)

    public init(fileURL: URL, maxBytes: Int = 1_000_000) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
    }

    /// Non-blocking; the write happens on a background queue. Order of calls is order in the file.
    public func record(_ message: String, at date: Date = Date()) {
        queue.async { [self] in
            append(Self.line(message, at: date))
        }
    }

    /// Blocks until everything recorded so far is on disk. For tests and before sharing the file.
    public func flush() {
        queue.sync {}
    }

    public static func line(_ message: String, at date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // One event per line, so a stray newline in a message must not split it.
        let flat = message.replacingOccurrences(of: "\n", with: " ")
        return "\(formatter.string(from: date)) \(flat)\n"
    }

    private func append(_ text: String) {
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size >= maxBytes {
            try? manager.removeItem(at: previousFileURL)
            try? manager.moveItem(at: fileURL, to: previousFileURL)
        }
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
