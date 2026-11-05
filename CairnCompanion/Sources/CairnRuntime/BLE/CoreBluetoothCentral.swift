import CairnKit
import CairnProtocol
import CoreBluetooth
import Foundation
import os

/// CoreBluetooth, turned into `LinkEvent`s and driven by `LinkEffect`s.
///
/// This file holds no rules. Every decision — when to scan, how long to wait, what a refused
/// read means, when to stop asking — is in `LinkMachine`, which is why the bench matrix can run
/// in CI. What lives here is the translation, and the translation's one job is to **lose
/// nothing**: every delegate call becomes an event, and every error keeps its domain and its
/// numeric code. The old manager dropped a pairing failure into the same `linkLost` path as a
/// walk out of range, and then could not say which had happened.
@MainActor
public final class CoreBluetoothCentral: NSObject, Central {
    public var onEvent: (@MainActor (LinkEvent) -> Void)?

    private static let log = Logger(subsystem: "app.cairn.companion", category: "ble")
    /// State restoration: iOS can relaunch the app for this central, which is how the
    /// "app killed" bench row is meant to work.
    private static let restoreIdentifier = "app.cairn.companion.central"

    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [CairnGATT.Characteristic: CBCharacteristic] = [:]

    private static let serviceUUID = CBUUID(string: CairnGATT.serviceUUID)

    public override init() {
        super.init()
        manager = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    // MARK: - Effects

    public func perform(_ effect: LinkEffect) {
        switch effect {
        case .scan:
            // By service UUID only. The advertised name is display-only (`ble/v1/spec.md`).
            manager.scanForPeripherals(withServices: [Self.serviceUUID])

        case .stopScan:
            manager.stopScan()

        case .connect(let ref):
            guard let target = adopt(ref) else {
                // iOS no longer knows this identifier — a restore, a reset, a different phone.
                // Say so as an event rather than sitting in `connecting` until the deadline.
                emit(.failedToConnect(ref, .cairn(20, "iOS no longer knows that dongle")))
                return
            }
            manager.connect(target, options: [
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                // Never set by the old app. The system brings a dropped link back faster and
                // more reliably than any timer here can, and it keeps working while the phone
                // is locked, which is the point of the locked-phone bench row.
                CBConnectPeripheralOptionEnableAutoReconnect: true,
            ])

        case .cancelConnection(let ref):
            guard let target = peripheral, target.identifier.uuidString == ref.id else { return }
            manager.cancelPeripheralConnection(target)

        case .discoverServices:
            peripheral?.discoverServices([Self.serviceUUID])

        case .discoverCharacteristics:
            guard let service = peripheral?.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
            // A `nil` filter, always: a filtered list is what hid `0030` and `0031` from the old
            // app for a month. The machine picks what it needs out of what came back.
            peripheral?.discoverCharacteristics(nil, for: service)

        case .read(let which):
            guard let peripheral, let characteristic = characteristics[which] else { return }
            peripheral.readValue(for: characteristic)

        case .setNotify(let which, let enabled):
            guard let peripheral, let characteristic = characteristics[which] else { return }
            peripheral.setNotifyValue(enabled, for: characteristic)

        case .measureWriteLength:
            guard let peripheral else { return }
            emit(.writeLengthMeasured(peripheral.maximumWriteValueLength(for: .withoutResponse)))

        case .readRSSI:
            peripheral?.readRSSI()

        case .persistIdentifier(let id):
            UserDefaults.standard.set(id, forKey: Self.storedIdentifierKey)

        case .forgetIdentifier:
            UserDefaults.standard.removeObject(forKey: Self.storedIdentifierKey)

        case .askToForgetInSettings:
            // The machine has already put this on the Dongle screen with the code and the
            // instruction. There is nothing an app can do about an iOS bond, so there is nothing
            // to do here but let it be logged.
            break
        }
    }

    public static let storedIdentifierKey = "cairn.link.peripheral"

    /// What the last successful link remembered, for `LinkMachine(storedIdentifier:)`.
    public static var storedIdentifier: String? {
        UserDefaults.standard.string(forKey: storedIdentifierKey)
    }

    @discardableResult
    public func write(_ data: Data, to which: CairnGATT.Characteristic) -> WriteOutcome {
        guard let peripheral, let characteristic = characteristics[which] else { return .notAvailable }
        if characteristic.properties.contains(.writeWithoutResponse) {
            // Flow control says the radio can take it. Only `COMPANION_STATUS` says the firmware
            // did anything with it.
            guard peripheral.canSendWriteWithoutResponse else { return .backpressure }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
        return .sent
    }

    // MARK: - Translation

    private func emit(_ event: LinkEvent) {
        onEvent?(event)
    }

    private func adopt(_ ref: PeripheralRef) -> CBPeripheral? {
        if let peripheral, peripheral.identifier.uuidString == ref.id { return peripheral }
        guard let id = UUID(uuidString: ref.id),
              let found = manager.retrievePeripherals(withIdentifiers: [id]).first else { return nil }
        adopt(found)
        return found
    }

    private func adopt(_ found: CBPeripheral) {
        peripheral = found
        found.delegate = self
        characteristics = [:]
    }

    private func reference(_ peripheral: CBPeripheral) -> PeripheralRef {
        PeripheralRef(id: peripheral.identifier.uuidString, name: peripheral.name)
    }
}

/// Every `NSError` CoreBluetooth hands over, with its domain and its number intact.
extension LinkFailure {
    init(_ error: Error) {
        let ns = error as NSError
        self.init(domain: ns.domain, code: ns.code, message: ns.localizedDescription)
    }

    init?(_ error: Error?) {
        guard let error else { return nil }
        self.init(error)
    }
}

extension CBManagerState {
    var linkState: CentralState {
        switch self {
        case .unknown: .unknown
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized: .unauthorised
        case .poweredOff: .poweredOff
        case .poweredOn: .poweredOn
        @unknown default: .unknown
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothCentral: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(.centralStateChanged(central.state.linkState))
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        adopt(restored)
        // A peripheral that comes back already connected has nothing to connect: the machine
        // takes it straight to discovery, which is what makes the relaunch fast.
        emit(.restored(reference(restored), connected: restored.state == .connected))
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        adopt(peripheral)
        emit(.discovered(reference(peripheral), rssi: RSSI.intValue))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit(.connected(reference(peripheral)))
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        emit(.failedToConnect(reference(peripheral), LinkFailure(error)))
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?
    ) {
        characteristics = [:]
        emit(.disconnected(reference(peripheral), LinkFailure(error), isReconnecting: isReconnecting))
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothCentral: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        emit(.servicesDiscovered(
            (peripheral.services ?? []).map(\.uuid.uuidString), LinkFailure(error)
        ))
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        var known: [CairnGATT.Characteristic] = []
        var unknown: [String] = []
        for characteristic in service.characteristics ?? [] {
            if let which = CairnGATT.characteristic(uuid: characteristic.uuid.uuidString) {
                characteristics[which] = characteristic
                known.append(which)
            } else {
                unknown.append(characteristic.uuid.uuidString)
            }
        }
        if !unknown.isEmpty {
            // Not an error: a newer firmware may expose something this build has no name for.
            // Worth a log line, because it is the first sign of a contract the app has not
            // caught up with.
            Self.log.notice("unrecognised characteristics: \(unknown.joined(separator: " "), privacy: .public)")
        }
        emit(.characteristicsDiscovered(known, LinkFailure(error)))
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard let which = CairnGATT.characteristic(uuid: characteristic.uuid.uuidString) else { return }
        // A read and a notification arrive through the same call. The machine asked for the
        // reads it cares about, so an error on one of those is a read failure; a value on a
        // channel it subscribed to is a notification.
        if let error {
            emit(.valueRead(which, nil, LinkFailure(error)))
            return
        }
        guard let value = characteristic.value else { return }
        if characteristic.isNotifying, !Self.readOnce.contains(which) {
            emit(.notified(which, value))
        } else {
            emit(.valueRead(which, value, nil))
        }
    }

    /// Read once per connection rather than subscribed to, so a value arriving for one of these
    /// is an answer to a read even if the characteristic also supports notifying.
    private static let readOnce: Set<CairnGATT.Characteristic> = [.protocolVersion, .deviceInfo]

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard let which = CairnGATT.characteristic(uuid: characteristic.uuid.uuidString) else { return }
        // The old app never looked at this error. A subscription that silently failed looked
        // exactly like a dongle that had gone quiet.
        emit(.notificationStateChanged(which, enabled: characteristic.isNotifying, LinkFailure(error)))
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        emit(.rssiRead(RSSI.intValue))
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) else { return }
        // The dongle's service changed under us — a reflash, or a firmware that rebuilt its
        // GATT table. Everything cached is stale.
        characteristics = [:]
        emit(.servicesDiscovered([], .cairn(21, "the dongle's Cairn service changed")))
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // The radio cleared after backpressure. Nothing to do: the next 1 Hz write goes through,
        // and a fix held back is a fix the firmware would have rejected at 3 s anyway.
    }
}
