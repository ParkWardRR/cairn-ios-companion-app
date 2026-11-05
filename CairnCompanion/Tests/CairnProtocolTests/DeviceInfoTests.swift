import CairnProtocol
import Foundation
import Testing

/// Fixture-driven tests for the BLE `DEVICE_INFO` parser against the contract vectors.
///
/// Vectors are at `contracts/ble/v1/vectors/device-info/vectors.json`. For each vector:
/// - A valid one must parse and every field must match the Go decoder's output.
/// - A malformed one must throw a `DeviceInfoParseError` the test can match on.
@Suite("DeviceInfo vectors")
struct DeviceInfoVectorsTests {
    private struct VectorFile: Decodable {
        var device_info: [Vector]
    }
    private struct Vector: Decodable {
        var name: String
        var hex: String
        var decoded: Decoded?
    }
    private struct Decoded: Decodable {
        var Version: UInt8
        var Minor: UInt8
        var Capabilities: UInt32
        var Firmware: Firmware?
        var Identity: Identity?
        var Storage: Storage?
        var Transports: [Transport]?
        var Engines: [Engine]?
        var Boot: Boot?
        var Truncated: Bool
    }
    private struct Firmware: Decodable {
        var Major: UInt8; var Minor: UInt8; var Patch: UInt8
        var Flags: UInt8; var Commit: [UInt8]; var BuildUnix: UInt32
    }
    private struct Identity: Decodable {
        var DeviceID: [UInt8]; var Fingerprint: [UInt8]
        var EnrolState: UInt8; var StorageKeyVersion: UInt32
    }
    private struct Storage: Decodable {
        var State: UInt8; var PendingBundles: UInt16; var FreeMiB: UInt32
    }
    private struct Transport: Decodable { var Kind: UInt8; var State: UInt8; var LastError: UInt16 }
    private struct Engine: Decodable {
        var ProfileVersion: UInt16; var Hash: [UInt8]; var ID: String
    }
    private struct Boot: Decodable {
        var ToBLEms: UInt32; var ToReadyMs: UInt32; var ToFirstFixMs: UInt32; var ResetReason: UInt8
    }

    private func loadVectors() -> [Vector] {
        let raw = Contracts.data("ble/v1/vectors/device-info/vectors.json")
        return try! JSONDecoder().decode(VectorFile.self, from: raw).device_info
    }

    @Test func everyValidVectorMatchesTheReference() throws {
        for v in loadVectors() where v.decoded != nil {
            let bytes = Data(hex: v.hex)
            let got = try parseDeviceInfo(bytes)
            let want = v.decoded!

            #expect(got.majorVersion == want.Version, "Version mismatch for \(v.name)")
            #expect(got.minorVersion == want.Minor, "Minor mismatch for \(v.name)")
            #expect(got.capabilities == want.Capabilities, "Capabilities mismatch for \(v.name)")
            #expect(got.truncated == want.Truncated, "Truncated mismatch for \(v.name)")

            if let f = want.Firmware, let gf = got.firmware {
                #expect(gf.major == f.Major && gf.minor == f.Minor && gf.patch == f.Patch, "fw version \(v.name)")
                #expect(gf.flags == f.Flags, "fw flags \(v.name)")
                #expect(Array(gf.commit) == f.Commit, "fw commit \(v.name)")
                #expect(gf.buildUnix == f.BuildUnix, "fw buildUnix \(v.name)")
            } else {
                #expect(want.Firmware == nil && got.firmware == nil, "fw presence \(v.name)")
            }

            if let id = want.Identity, let gi = got.identity {
                #expect(Array(gi.deviceID) == id.DeviceID, "identity device id \(v.name)")
                #expect(Array(gi.fingerprint) == id.Fingerprint, "identity fingerprint \(v.name)")
                #expect(gi.enrolState.rawValue == id.EnrolState, "identity enrol state \(v.name)")
                #expect(gi.storageKeyVersion == id.StorageKeyVersion, "identity storage key version \(v.name)")
            }

            if let s = want.Storage, let gs = got.storage {
                #expect(gs.state.rawValue == s.State, "storage state \(v.name)")
                #expect(gs.pendingBundles == s.PendingBundles, "storage pending \(v.name)")
                #expect((gs.freeMiB ?? UInt32.max) == s.FreeMiB, "storage freeMiB \(v.name)")
            }

            let wantTransports = want.Transports ?? []
            #expect(got.transports.count == wantTransports.count, "transports count \(v.name)")
            for (a, b) in zip(got.transports, wantTransports) {
                #expect(a.kind.rawValue == b.Kind && a.state == b.State && a.lastError == b.LastError,
                        "transport \(v.name)")
            }

            let wantEngines = want.Engines ?? []
            #expect(got.engines.count == wantEngines.count, "engines count \(v.name)")
            for (a, b) in zip(got.engines, wantEngines) {
                #expect(a.profileVersion == b.ProfileVersion, "engine profile version \(v.name)")
                #expect(Array(a.hash) == b.Hash, "engine hash \(v.name)")
                #expect(a.engineID == b.ID, "engine id \(v.name)")
            }

            if let bt = want.Boot, let gb = got.bootTiming {
                #expect(gb.bootToBLEms == bt.ToBLEms, "boot ble \(v.name)")
                #expect(gb.bootToReadyMs == bt.ToReadyMs, "boot ready \(v.name)")
                #expect((gb.bootToFirstFixMs ?? UInt32.max) == bt.ToFirstFixMs, "boot fix \(v.name)")
                #expect(gb.resetReason == bt.ResetReason, "boot reset \(v.name)")
            }
        }
    }

    @Test func everyMalformedVectorIsRejected() throws {
        for v in loadVectors() where v.decoded == nil {
            let bytes = Data(hex: v.hex)
            do {
                _ = try parseDeviceInfo(bytes)
                Issue.record("expected a parse error for \(v.name)")
            } catch is DeviceInfoParseError {
                // ok
            } catch {
                Issue.record("expected DeviceInfoParseError for \(v.name), got \(error)")
            }
        }
    }
}

/// Properties the vector set does not cover.
@Suite("DeviceInfo additional checks")
struct DeviceInfoExtraTests {
    /// `total_len` greater than the real byte count must throw `lengthMismatch`.
    @Test func lengthMismatchDetected() {
        var hdr: [UInt8] = [1, 0, 0xFF, 0x01, 0, 0, 0, 0]  // claims 0x01FF = 511 bytes
        for _ in 0..<16 { hdr.append(0) }
        #expect(throws: DeviceInfoParseError.self) {
            try parseDeviceInfo(Data(hdr))
        }
    }

    /// A record whose declared length walks past the end is malformed.
    @Test func recordLengthOverflowRejected() {
        let bytes: [UInt8] = [1, 0, 11, 0, 0, 0, 0, 0,       // header, total_len=11
                              0x01, 0xFF, 0x00]              // firmware record claims 255 B, 1 B supplied
        #expect(throws: DeviceInfoParseError.self) {
            try parseDeviceInfo(Data(bytes))
        }
    }

    /// Vehicle fit: when the vehicle's engine is in the installed set, the match is returned.
    @Test func fitMatchesInstalledEngine() throws {
        let header: [UInt8] = [1, 0, 28, 0, 0, 0, 0, 0]  // 8 B header + 20 B record (2 + 18)
        // one engine record for bmw-n20: type=0x05 len=18 (= 11 + id_len 7)
        var rec: [UInt8] = [0x05, 18, 0x01, 0x00]            // profile version 1
        rec += Array(repeating: 0, count: 8)                 // hash
        rec += [7]                                           // id_len = 7
        rec += Array("bmw-n20".utf8)
        let bytes = Data(header + rec)
        let info = try parseDeviceInfo(bytes)
        #expect(info.installedEngine(forProfileID: "bmw-n20")?.engineID == "bmw-n20")
        #expect(info.installedEngine(forProfileID: "bmw-b58") == nil)
        #expect(info.installedEngine(forProfileID: nil) == nil)
    }
}
