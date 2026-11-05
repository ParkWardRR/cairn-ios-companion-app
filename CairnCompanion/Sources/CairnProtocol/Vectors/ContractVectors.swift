import Foundation

/// Reads the pinned contract vectors off disk.
///
/// It lives in `CairnProtocol` rather than in a test file because the vectors are part of what
/// this target *is*: the bytes and the cases that pin them. Both test targets read them through
/// here, nothing is vendored, so there is no second copy to drift from `contracts.lock`.
///
/// Where it looks, in order:
///   1. `$CAIRN_CONTRACTS`, so a contract and this app can change together on a laptop
///   2. `.contracts/contracts` at the repository root, as `scripts/fetch-contracts.sh` leaves it
public enum ContractVectors {
    public enum Failure: Error, CustomStringConvertible {
        case notFetched
        case missing(String, URL)
        case malformed(String)

        public var description: String {
            switch self {
            case .notFetched:
                "no fetched contracts: run scripts/fetch-contracts.sh (or set CAIRN_CONTRACTS)"
            case .missing(let path, let root):
                "\(path) is not in the contracts at \(root.path); check contracts.lock"
            case .malformed(let path):
                "\(path) is not the JSON shape this test expects"
            }
        }
    }

    /// The contract root, or nil when nothing has been fetched. Nil rather than a crash so a
    /// caller outside the repository can simply offer no vectors.
    public static let root: URL? = {
        if let override = ProcessInfo.processInfo.environment["CAIRN_CONTRACTS"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("ble").path)
                ? url : url.appendingPathComponent("contracts")
        }
        // Walk up from this file to the repository root rather than counting directories: the
        // count was wrong the moment this file moved target, and a wrong count reads as a
        // missing vector file, which is a confusing way to learn you have restructured.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(".contracts/contracts")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }()

    public static var isFetched: Bool { root != nil }

    public static func data(_ path: String) throws -> Data {
        guard let root else { throw Failure.notFetched }
        let url = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { throw Failure.missing(path, root) }
        return data
    }

    public static func json(_ path: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data(path)) as? [String: Any] else {
            throw Failure.malformed(path)
        }
        return object
    }

    public static func jsonArray(_ path: String) throws -> [[String: Any]] {
        guard let array = try JSONSerialization.jsonObject(with: data(path)) as? [[String: Any]] else {
            throw Failure.malformed(path)
        }
        return array
    }

    /// The text of a spec file, so a test can assert that a documented constant and the constant
    /// in the code are the same number.
    public static func text(_ path: String) throws -> String {
        String(decoding: try data(path), as: UTF8.self)
    }
}
