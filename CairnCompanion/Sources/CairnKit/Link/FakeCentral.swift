import CairnProtocol
import Foundation

/// A dongle made of rules, so the bench matrix can be run without one.
///
/// It is not a mock that records calls: it is a small peripheral that behaves the way the real
/// firmware does, including the parts that make pairing fail. The behaviours it can be put in —
/// `justWorks`, `dropsLinkWhilePairing`, `refusesRead` — are taken from
/// `src/ble_companion.cpp`:
///
///   - On a pairing failure the firmware logs it, may clear its own bond, and then **terminates
///     the link itself**. A central sees a plain disconnect with no ATT error, which is why
///     `LinkMachine` treats a disconnect inside `securing` as a pairing failure.
///   - On a disconnect whose reason is `PINKEY_MISSING`, `AUTH_FAIL` or an encryption error, and
///     only then, it drops its half of the bond so the next attempt pairs cleanly. That is the
///     "phone forgot the dongle" row, and it is why one retry is worth trying before asking the
///     owner for anything.
///   - It re-advertises on every disconnect unless its radio is off, which is the Wi-Fi-slot row.
///
/// Events are queued rather than delivered inline: the supervisor is pumping when it calls
/// `perform`, so a synchronous callback would re-enter it. `settle()` drains the queue.
@MainActor
public final class FakeCentral: Central, OffloadLinkProvider {
    public var onEvent: (@MainActor (LinkEvent) -> Void)?

    /// How the dongle answers the `PROTOCOL_VERSION` read, which is where iOS pairs.
    public enum Pairing: Equatable, Sendable {
        /// Pairs, every time. The shipping firmware's Just Works.
        case justWorks
        /// Drops the link this many times before pairing — the firmware's own
        /// "pairing failed, disconnecting", with the reason it disconnects with.
        case dropsLinkWhilePairing(times: Int, reason: LinkFailure?)
        /// The read comes back refused and keeps coming back refused: iOS is offering a key this
        /// dongle no longer holds.
        case refusesRead(LinkFailure)
        /// The connect itself fails to encrypt, so there is no read to refuse.
        ///
        /// This is the shape the radio actually produced on 2026-11-05 once the dongle's half of
        /// the bond was gone: `CBErrorDomain#15`, or `#14`, on `connect` — iOS encrypts a bonded
        /// link before it will hand over the service list, so the failure lands long before
        /// `PROTOCOL_VERSION`. Modelled separately from `refusesRead` because the two arrive down
        /// different paths, and the bench matrix only ever exercised the other one.
        case refusesToEncrypt(LinkFailure)
    }

    public struct Dongle: Sendable {
        public var ref: PeripheralRef
        public var rssi: Int
        /// A dongle in a Wi-Fi slot, or unpowered, advertises nothing.
        public var isAdvertising: Bool
        public var services: [String]
        public var characteristics: Set<CairnGATT.Characteristic>
        public var version: ProtocolVersion
        /// The write lengths the link reports, in order. The last one repeats. More than one
        /// entry is how the "MTU is small for the first half-second" case is tested.
        public var writeLengths: [Int]
        public var deviceInfo: Data?
        public var pairing: Pairing
        /// Subscribes that fail, by characteristic.
        public var subscribeFailures: [CairnGATT.Characteristic: LinkFailure]
        /// What the `PROTOCOL_VERSION` read returns, when it returns. Nil sends a short payload.
        public var versionPayload: Data?

        public init(
            ref: PeripheralRef = PeripheralRef(id: "FAKE0001-0000-0000-0000-000000000001", name: "Cairn"),
            rssi: Int = -58,
            isAdvertising: Bool = true,
            services: [String] = [CairnGATT.serviceUUID],
            characteristics: Set<CairnGATT.Characteristic> = Dongle.shippingCharacteristics,
            version: ProtocolVersion = ProtocolVersion(version: 1, capabilities: [.bundleOffload, .deviceInformation]),
            writeLengths: [Int] = [244],
            deviceInfo: Data? = Dongle.contractDeviceInfo,
            pairing: Pairing = .justWorks,
            subscribeFailures: [CairnGATT.Characteristic: LinkFailure] = [:],
            versionPayload: Data? = nil
        ) {
            self.ref = ref
            self.rssi = rssi
            self.isAdvertising = isAdvertising
            self.services = services
            self.characteristics = characteristics
            self.version = version
            self.writeLengths = writeLengths
            self.deviceInfo = deviceInfo
            self.pairing = pairing
            self.subscribeFailures = subscribeFailures
            self.versionPayload = versionPayload
        }

        /// What the firmware on the dongle actually exposes today: GNSS, the clock, the barometer,
        /// the engine declaration, offload and device info. No `OBD_LIVE`, no `DEVICE_STATUS` —
        /// the old app gated its whole background location session on notifications from those
        /// two, which is why the live store held zero phone positions.
        /// The `DEVICE_INFO` payload from the contract's own vector
        /// (`ble/v1/vectors/device-info/vectors.json`, the "full" case), so the fake dongle
        /// reports what the contract says a dongle reports rather than something invented here.
        /// Nil when the contracts have not been fetched, which only a non-vector test would hit.
        public static let contractDeviceInfo: Data? = {
            guard let root = try? ContractVectors.json("ble/v1/vectors/device-info/vectors.json"),
                  let cases = root["device_info"] as? [[String: Any]],
                  let full = cases.first(where: { ($0["name"] as? String)?.hasPrefix("full") == true }),
                  let hex = full["hex"] as? String
            else { return nil }
            return Data(hexString: hex)
        }()

        public static let shippingCharacteristics: Set<CairnGATT.Characteristic> = [
            .gnssFix, .gnssQuality, .companionStatus, .protocolVersion,
            .baroAlt, .utcSync, .engineDeclaration,
            .offloadControl, .offloadData, .deviceInfo,
        ]
    }

    public var dongle: Dongle
    /// How long each operation takes. The real radio is not instant and a deadline that only
    /// ever sees instant answers is a deadline that was never tested.
    public var latency: TimeInterval = 0

    // What the fake was told to do, for assertions.
    public private(set) var effects: [LinkEffect] = []
    public private(set) var writes: [(CairnGATT.Characteristic, Data)] = []
    public private(set) var persistedIdentifier: String?
    public private(set) var askedToForget: [LinkFailure] = []
    public private(set) var isScanning = false
    public private(set) var isConnected = false

    private var queue: [LinkEvent] = []
    private var pairingDropsLeft = 0
    private var writeLengthIndex = 0
    private var connectedRef: PeripheralRef?

    public init(dongle: Dongle = Dongle()) {
        self.dongle = dongle
        if case .dropsLinkWhilePairing(let times, _) = dongle.pairing { pairingDropsLeft = times }
    }

    // MARK: - Central

    public func perform(_ effect: LinkEffect) {
        effects.append(effect)
        switch effect {
        case .scan:
            isScanning = true
            if dongle.isAdvertising { queue.append(.discovered(dongle.ref, rssi: dongle.rssi)) }

        case .stopScan:
            isScanning = false

        case .connect(let ref):
            // A dongle that is not advertising never answers, and the connect has no timeout of
            // its own — which is the whole reason LinkMachine carries a 15 s deadline.
            guard dongle.isAdvertising else { return }
            // iOS encrypts a bonded link before it hands anything over, so a bond the dongle no
            // longer holds fails here rather than at the version read.
            if case .refusesToEncrypt(let failure) = dongle.pairing {
                queue.append(.failedToConnect(ref.id == dongle.ref.id ? dongle.ref : ref, failure))
                return
            }
            isConnected = true
            connectedRef = ref.id == dongle.ref.id ? dongle.ref : ref
            queue.append(.connected(connectedRef!))

        case .cancelConnection(let ref):
            guard isConnected else { return }
            isConnected = false
            connectedRef = nil
            // CoreBluetooth does deliver a disconnect for a cancellation. The machine should
            // ignore it, having already moved on.
            queue.append(.disconnected(ref, nil, isReconnecting: false))

        case .discoverServices:
            queue.append(.servicesDiscovered(dongle.services, nil))

        case .discoverCharacteristics:
            queue.append(.characteristicsDiscovered(Array(dongle.characteristics), nil))

        case .read(let characteristic):
            read(characteristic)

        case .setNotify(let characteristic, let enabled):
            queue.append(.notificationStateChanged(
                characteristic, enabled: enabled, dongle.subscribeFailures[characteristic]
            ))

        case .measureWriteLength:
            let length = dongle.writeLengths[min(writeLengthIndex, dongle.writeLengths.count - 1)]
            writeLengthIndex += 1
            queue.append(.writeLengthMeasured(length))

        case .readRSSI:
            queue.append(.rssiRead(dongle.rssi))

        case .persistIdentifier(let id):
            persistedIdentifier = id

        case .forgetIdentifier:
            persistedIdentifier = nil

        case .askToForgetInSettings(let failure):
            askedToForget.append(failure)
        }
    }

    private func read(_ characteristic: CairnGATT.Characteristic) {
        guard isConnected, let ref = connectedRef else { return }
        switch characteristic {
        case .protocolVersion:
            switch dongle.pairing {
            case .justWorks:
                queue.append(.valueRead(.protocolVersion, dongle.versionPayload ?? dongle.version.data, nil))
            case .refusesRead(let failure):
                queue.append(.valueRead(.protocolVersion, nil, failure))
            case .refusesToEncrypt:
                // Unreachable: the connect never completed, so there is nothing to read from.
                break
            case .dropsLinkWhilePairing(_, let reason):
                guard pairingDropsLeft > 0 else {
                    queue.append(.valueRead(.protocolVersion, dongle.versionPayload ?? dongle.version.data, nil))
                    return
                }
                pairingDropsLeft -= 1
                isConnected = false
                connectedRef = nil
                // The firmware drops its own half of the bond on exactly these reasons, so the
                // next attempt is a clean pairing and it starts advertising again at once.
                queue.append(.disconnected(ref, reason, isReconnecting: false))
            }
        case .deviceInfo:
            guard let info = dongle.deviceInfo else {
                queue.append(.valueRead(.deviceInfo, nil, .cairn(99, "the dongle has no device info")))
                return
            }
            queue.append(.valueRead(.deviceInfo, info, nil))
        default:
            queue.append(.valueRead(characteristic, nil, .cairn(98, "\(characteristic.title) is not readable")))
        }
    }

    @discardableResult
    public func write(_ data: Data, to characteristic: CairnGATT.Characteristic) -> WriteOutcome {
        guard isConnected, dongle.characteristics.contains(characteristic) else { return .notAvailable }
        writes.append((characteristic, data))
        return .sent
    }

    // MARK: - Driving it from a test

    /// Deliver everything queued, and everything that queues as a result, until it goes quiet.
    public func settle(limit: Int = 200) {
        var rounds = 0
        while !queue.isEmpty {
            rounds += 1
            precondition(rounds < limit, "the fake central and the machine will not settle")
            let batch = queue
            queue.removeAll()
            for event in batch { onEvent?(event) }
        }
    }

    /// The dongle rebooted: the link drops and it comes back advertising.
    public func reboot(reason: LinkFailure? = nil) {
        if let ref = connectedRef {
            isConnected = false
            connectedRef = nil
            queue.append(.disconnected(ref, reason, isReconnecting: false))
        }
        dongle.isAdvertising = true
        if case .dropsLinkWhilePairing(let times, _) = dongle.pairing { pairingDropsLeft = times }
    }

    /// The dongle took its radio away — a Wi-Fi slot, or the ignition going off.
    public func stopAdvertising() {
        dongle.isAdvertising = false
        if let ref = connectedRef {
            isConnected = false
            connectedRef = nil
            queue.append(.disconnected(ref, nil, isReconnecting: false))
        }
    }

    public func startAdvertising() { dongle.isAdvertising = true }

    /// The dongle cleared its bonds — `CLEAR bonds` on the provisioning console, or a reflash
    /// whose security fingerprint changed. From then on it refuses the phone's key.
    public func clearBonds() {
        dongle.pairing = .refusesRead(LinkFailure(
            domain: LinkFailure.attDomain,
            code: LinkFailure.ATT.insufficientAuthentication.rawValue,
            message: "Authentication is insufficient."
        ))
    }

    /// Always nil. The offload conversation has its own fake — a dongle that answers `LIST`,
    /// `GET_MANIFEST`, `READ` and `PUT_RECEIPT` with real framing — and `OffloadRunnerTests`
    /// drives `OffloadClient` against it directly, which is the same surface with none of this
    /// one's scaffolding in the way.
    public func openOffloadLink() -> (any OffloadLink)? { nil }
    public func closeOffloadLink() {}

    public func effect(matching predicate: (LinkEffect) -> Bool) -> LinkEffect? {
        effects.first(where: predicate)
    }

    public var didAskToForget: Bool { !askedToForget.isEmpty }
}
