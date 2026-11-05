import Foundation

/// The parsed value of the `DEVICE_INFO` characteristic (BLE suffix `0040`),
/// per `contracts/ble/v1/device-info.md`.
///
/// Format: 8-byte header (`version | minor | total_len | capabilities`),
/// then records of `u8 type | u8 len | value[len]` in ascending type order.
/// Unknown types are skipped by `len`; a known type with the wrong length makes
/// the whole value malformed. The parser refuses majors it does not know.
public struct DeviceInfo: Sendable, Equatable {
    public static let supportedMajorVersion: UInt8 = 1

    public var majorVersion: UInt8
    public var minorVersion: UInt8
    public var capabilities: UInt32
    public var firmware: Firmware?
    public var identity: Identity?
    public var storage: Storage?
    public var transports: [Transport]
    public var engines: [Engine]
    public var bootTiming: BootTiming?
    /// True when the dongle appended the `0x7F` record, meaning the list did not fit.
    public var truncated: Bool

    public init(
        majorVersion: UInt8,
        minorVersion: UInt8,
        capabilities: UInt32,
        firmware: Firmware? = nil,
        identity: Identity? = nil,
        storage: Storage? = nil,
        transports: [Transport] = [],
        engines: [Engine] = [],
        bootTiming: BootTiming? = nil,
        truncated: Bool = false
    ) {
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.capabilities = capabilities
        self.firmware = firmware
        self.identity = identity
        self.storage = storage
        self.transports = transports
        self.engines = engines
        self.bootTiming = bootTiming
        self.truncated = truncated
    }

    public enum Capability: UInt32, CaseIterable, Sendable {
        case phoneGNSSCompanion = 0x0001  // bit 0
        case liveOBD            = 0x0002  // bit 1
        case bundleOffload      = 0x0004  // bit 2
        case deviceInformation  = 0x0008  // bit 3
        case uplinkEvents       = 0x0010  // bit 4
        case instructions       = 0x0020  // bit 5
        case homeTrigger        = 0x0040  // bit 6
        case wiFiUplink         = 0x0080  // bit 7
        case lteUplink          = 0x0100  // bit 8
        case digest             = 0x0200  // bit 9
        case configuration      = 0x0400  // bit 10
    }

    public func supports(_ cap: Capability) -> Bool {
        (capabilities & cap.rawValue) != 0
    }

    public struct Firmware: Sendable, Equatable {
        public var major: UInt8
        public var minor: UInt8
        public var patch: UInt8
        public var flags: UInt8
        public var commit: Data  // 8 bytes
        public var buildUnix: UInt32

        public var isDirtyBuild: Bool { (flags & 0x01) != 0 }
        public var isReleaseBuild: Bool { (flags & 0x02) != 0 }
        public var secureBootOn: Bool { (flags & 0x04) != 0 }
        public var flashEncryptionOn: Bool { (flags & 0x08) != 0 }

        public init(major: UInt8, minor: UInt8, patch: UInt8, flags: UInt8, commit: Data, buildUnix: UInt32) {
            self.major = major; self.minor = minor; self.patch = patch
            self.flags = flags; self.commit = commit; self.buildUnix = buildUnix
        }
    }

    public struct Identity: Sendable, Equatable {
        public enum EnrolState: UInt8, Sendable { case notEnrolled = 0, enrolled = 1, assigned = 2 }
        public var deviceID: Data           // 16 bytes
        public var fingerprint: Data        // 4 bytes
        public var enrolState: EnrolState
        public var storageKeyVersion: UInt32

        public init(deviceID: Data, fingerprint: Data, enrolState: EnrolState, storageKeyVersion: UInt32) {
            self.deviceID = deviceID; self.fingerprint = fingerprint
            self.enrolState = enrolState; self.storageKeyVersion = storageKeyVersion
        }
    }

    public struct Storage: Sendable, Equatable {
        public enum State: UInt8, Sendable { case noCard = 0, ok = 1, readOnly = 2, error = 3 }
        public var state: State
        public var pendingBundles: UInt16
        /// `nil` when the dongle reports `0xFFFFFFFF`.
        public var freeMiB: UInt32?

        public init(state: State, pendingBundles: UInt16, freeMiB: UInt32?) {
            self.state = state; self.pendingBundles = pendingBundles; self.freeMiB = freeMiB
        }
    }

    public struct Transport: Sendable, Equatable {
        public enum Kind: UInt8, Sendable { case ble = 1, wifi = 2, lte = 3 }
        public var kind: Kind
        public var state: UInt8          // b0 hw b1 compiled b2 configured b3 enabled b4 available
        public var lastError: UInt16     // 0 none

        public var hardwarePresent: Bool { (state & 0x01) != 0 }
        public var compiledIn: Bool      { (state & 0x02) != 0 }
        public var configured: Bool      { (state & 0x04) != 0 }
        public var enabled: Bool         { (state & 0x08) != 0 }
        public var availableNow: Bool    { (state & 0x10) != 0 }

        public init(kind: Kind, state: UInt8, lastError: UInt16) {
            self.kind = kind; self.state = state; self.lastError = lastError
        }
    }

    public struct Engine: Sendable, Equatable {
        public var profileVersion: UInt16
        public var hash: Data            // 8 bytes
        public var engineID: String      // ASCII, 1..32

        public init(profileVersion: UInt16, hash: Data, engineID: String) {
            self.profileVersion = profileVersion; self.hash = hash; self.engineID = engineID
        }
    }

    public struct BootTiming: Sendable, Equatable {
        public var bootToBLEms: UInt32
        public var bootToReadyMs: UInt32
        /// `nil` when the dongle reports `0xFFFFFFFF` (no fix yet).
        public var bootToFirstFixMs: UInt32?
        public var resetReason: UInt8

        public init(bootToBLEms: UInt32, bootToReadyMs: UInt32, bootToFirstFixMs: UInt32?, resetReason: UInt8) {
            self.bootToBLEms = bootToBLEms; self.bootToReadyMs = bootToReadyMs
            self.bootToFirstFixMs = bootToFirstFixMs; self.resetReason = resetReason
        }
    }
}

/// What the parser refuses, with a reason the test can match on.
public enum DeviceInfoParseError: Error, Equatable, Sendable {
    case truncated                        // fewer bytes than header or declared total_len
    case lengthMismatch                   // `total_len` does not equal the bytes supplied
    case tooLarge                         // > 512 B
    case unsupportedMajorVersion(UInt8)
    case malformedRecord(type: UInt8, len: UInt8)  // known type with wrong len, or a record walking off the end
    case malformedString(type: UInt8)     // engine_id with impossible id_len
}

/// Parse a `DEVICE_INFO` value. Unknown record types are skipped by `len`; a
/// known type with the wrong length discards the whole value. See the contract.
public func parseDeviceInfo(_ data: Data) throws -> DeviceInfo {
    guard data.count >= 8 else { throw DeviceInfoParseError.truncated }
    guard data.count <= 512 else { throw DeviceInfoParseError.tooLarge }

    let b = Array(data)
    let major = b[0]
    guard major == DeviceInfo.supportedMajorVersion else {
        throw DeviceInfoParseError.unsupportedMajorVersion(major)
    }
    let minor = b[1]
    let totalLen = UInt16(b[2]) | (UInt16(b[3]) << 8)
    let caps = UInt32(b[4]) | (UInt32(b[5]) << 8) | (UInt32(b[6]) << 16) | (UInt32(b[7]) << 24)
    guard Int(totalLen) == data.count else { throw DeviceInfoParseError.lengthMismatch }

    var out = DeviceInfo(majorVersion: major, minorVersion: minor, capabilities: caps)
    var i = 8
    while i < b.count {
        guard i + 2 <= b.count else { throw DeviceInfoParseError.malformedRecord(type: 0, len: 0) }
        let type = b[i]; let len = b[i + 1]
        let valueStart = i + 2
        let valueEnd = valueStart + Int(len)
        guard valueEnd <= b.count else { throw DeviceInfoParseError.malformedRecord(type: type, len: len) }
        let v = data.subdata(in: valueStart..<valueEnd)

        switch type {
        case 0x01:
            guard len == 16 else { throw DeviceInfoParseError.malformedRecord(type: type, len: len) }
            out.firmware = .init(
                major: v[v.startIndex], minor: v[v.startIndex + 1], patch: v[v.startIndex + 2],
                flags: v[v.startIndex + 3],
                commit: v.subdata(in: (v.startIndex + 4)..<(v.startIndex + 12)),
                buildUnix: readU32(v, at: 12))
        case 0x02:
            guard len == 25 else { throw DeviceInfoParseError.malformedRecord(type: type, len: len) }
            let did = v.subdata(in: v.startIndex..<(v.startIndex + 16))
            let fp = v.subdata(in: (v.startIndex + 16)..<(v.startIndex + 20))
            let stRaw = v[v.startIndex + 20]
            guard let st = DeviceInfo.Identity.EnrolState(rawValue: stRaw) else {
                throw DeviceInfoParseError.malformedRecord(type: type, len: len)
            }
            out.identity = .init(deviceID: did, fingerprint: fp, enrolState: st, storageKeyVersion: readU32(v, at: 21))
        case 0x03:
            guard len == 8 else { throw DeviceInfoParseError.malformedRecord(type: type, len: len) }
            guard let st = DeviceInfo.Storage.State(rawValue: v[v.startIndex]) else {
                throw DeviceInfoParseError.malformedRecord(type: type, len: len)
            }
            let pending = readU16(v, at: 2)
            let freeMiBRaw = readU32(v, at: 4)
            out.storage = .init(state: st, pendingBundles: pending,
                                freeMiB: freeMiBRaw == UInt32.max ? nil : freeMiBRaw)
        case 0x04:
            guard len == 4 else { throw DeviceInfoParseError.malformedRecord(type: type, len: len) }
            guard let kind = DeviceInfo.Transport.Kind(rawValue: v[v.startIndex]) else {
                throw DeviceInfoParseError.malformedRecord(type: type, len: len)
            }
            out.transports.append(.init(kind: kind, state: v[v.startIndex + 1], lastError: readU16(v, at: 2)))
        case 0x05:
            // `11 + id_len`, id_len 1..32, so a value under 12 B is malformed.
            guard len >= 12, len <= 11 + 32 else {
                throw DeviceInfoParseError.malformedRecord(type: type, len: len)
            }
            let profVer = readU16(v, at: 0)
            let hash = v.subdata(in: (v.startIndex + 2)..<(v.startIndex + 10))
            let idLen = v[v.startIndex + 10]
            guard idLen >= 1, idLen <= 32, Int(idLen) == Int(len) - 11 else {
                throw DeviceInfoParseError.malformedString(type: type)
            }
            let idBytes = v.subdata(in: (v.startIndex + 11)..<(v.startIndex + 11 + Int(idLen)))
            guard let id = String(data: idBytes, encoding: .ascii) else {
                throw DeviceInfoParseError.malformedString(type: type)
            }
            out.engines.append(.init(profileVersion: profVer, hash: hash, engineID: id))
        case 0x06:
            guard len == 16 else { throw DeviceInfoParseError.malformedRecord(type: type, len: len) }
            let bble = readU32(v, at: 0)
            let bready = readU32(v, at: 4)
            let bfixRaw = readU32(v, at: 8)
            let rst = v[v.startIndex + 12]
            out.bootTiming = .init(bootToBLEms: bble, bootToReadyMs: bready,
                                   bootToFirstFixMs: bfixRaw == UInt32.max ? nil : bfixRaw,
                                   resetReason: rst)
        case 0x7F:
            // Length is 0 per contract; still accept it if the dongle sets it to anything.
            out.truncated = true
        default:
            break   // unknown type: skip
        }
        i = valueEnd
    }
    return out
}

// MARK: - Vehicle fit

extension DeviceInfo {
    /// Returns the installed engine profile that matches `profileID`, or `nil` if the
    /// vehicle's engine is not compiled into this dongle (i.e. the warn case).
    /// Pass `Vehicle.firmwareEngineProfileID` as `profileID`.
    public func installedEngine(forProfileID profileID: String?) -> Engine? {
        guard let id = profileID, !id.isEmpty else { return nil }
        return engines.first { $0.engineID == id }
    }
}

// MARK: - helpers

private func readU16(_ d: Data, at off: Int) -> UInt16 {
    let i = d.startIndex + off
    return UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
}

private func readU32(_ d: Data, at off: Int) -> UInt32 {
    let i = d.startIndex + off
    return UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
}
