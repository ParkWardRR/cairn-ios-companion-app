import Foundation

// Every Cairn wire format is little-endian, from the 28-byte `GNSS_FIX` write to the offload
// frame headers. These two are the only place that byte order is expressed, so a payload struct
// reads as a list of fields and nothing else.

extension Data {
    public mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// `self` must be zero-indexed; callers re-base first (`Data(slice)`).
    public func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value |= T(truncatingIfNeeded: self[offset + i]) << (8 * i)
        }
        return value
    }

    /// Lowercase hex, for a log line that has to be comparable with the firmware's serial output.
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// Parses lowercase or uppercase hex; nil on an odd length or a non-hex digit, so a vector
    /// file with a typo fails as a test rather than as a wrong byte on the wire.
    public init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
