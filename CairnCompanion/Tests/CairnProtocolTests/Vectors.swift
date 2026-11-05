import CairnProtocol
import Foundation

/// Short names for the pinned vectors inside the suite. A missing vector traps here with
/// `ContractVectors.Failure`'s message, which names the file and tells you to run
/// `scripts/fetch-contracts.sh`: a vector test that cannot find its vectors must fail loudly,
/// never quietly pass.
enum Contracts {
    static func data(_ path: String) -> Data {
        do { return try ContractVectors.data(path) } catch { fatalError("\(error)") }
    }

    static func json(_ path: String) -> [String: Any] {
        do { return try ContractVectors.json(path) } catch { fatalError("\(error)") }
    }
}

extension Data {
    init(hex: String) {
        guard let parsed = Data(hexString: hex) else { fatalError("not hex: \(hex)") }
        self = parsed
    }
}
