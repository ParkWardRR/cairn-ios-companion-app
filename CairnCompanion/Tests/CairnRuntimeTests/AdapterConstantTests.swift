import CairnKit
import CairnProtocol
@testable import CairnRuntime
import CoreBluetooth
import Foundation
import Testing

/// `CairnKit` imports no Apple framework, so it spells out the error domains and codes it
/// reasons about by hand. That is the right trade — the link machine is testable on any
/// platform — but it leaves one way for an adapter to be silently wrong: a constant that drifts.
/// A wrong ATT code would mean a refused read read as an ordinary failure and retried forever,
/// which is exactly the class of bug the rewrite exists to end. So the numbers are asserted
/// against CoreBluetooth itself.
@Suite("Adapter constants match CoreBluetooth")
struct AdapterConstantTests {
    @Test("the error domains are the ones iOS uses")
    func domains() {
        #expect(LinkFailure.attDomain == CBATTErrorDomain)
        #expect(LinkFailure.cbDomain == CBErrorDomain)
    }

    @Test("the ATT codes are the ones iOS uses")
    func attCodes() {
        #expect(LinkFailure.ATT.insufficientAuthentication.rawValue == CBATTError.insufficientAuthentication.rawValue)
        #expect(LinkFailure.ATT.insufficientEncryption.rawValue == CBATTError.insufficientEncryption.rawValue)
        #expect(LinkFailure.ATT.insufficientEncryptionKeySize.rawValue == CBATTError.insufficientEncryptionKeySize.rawValue)
    }

    @Test("the CBError codes are the ones iOS uses")
    func cbCodes() {
        #expect(LinkFailure.CB.connectionTimeout.rawValue == CBError.connectionTimeout.rawValue)
        #expect(LinkFailure.CB.peripheralDisconnected.rawValue == CBError.peripheralDisconnected.rawValue)
        #expect(LinkFailure.CB.connectionFailed.rawValue == CBError.connectionFailed.rawValue)
        #expect(LinkFailure.CB.peerRemovedPairingInformation.rawValue == CBError.peerRemovedPairingInformation.rawValue)
        #expect(LinkFailure.CB.encryptionTimedOut.rawValue == CBError.encryptionTimedOut.rawValue)
    }

    @Test("an NSError keeps its domain, its number and its sentence")
    func failureFromNSError() {
        let error = NSError(
            domain: CBATTErrorDomain,
            code: CBATTError.insufficientAuthentication.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Authentication is insufficient."]
        )
        let failure = LinkFailure(error)
        #expect(failure.domain == CBATTErrorDomain)
        #expect(failure.code == 5)
        #expect(failure.message == "Authentication is insufficient.")
        #expect(failure.isAuthentication)
        #expect(failure.shortCode == "ATT 5")
    }

    @Test("iOS saying the peer forgot us is recognised as exactly that")
    func peerRemovedPairing() {
        let error = NSError(domain: CBErrorDomain, code: CBError.peerRemovedPairingInformation.rawValue)
        #expect(LinkFailure(error).isPeerRemovedPairing)
        #expect(!LinkFailure(error).isAuthentication)
    }

    @Test("every GATT UUID in the contract round-trips through CBUUID")
    func uuidsAreValid() {
        // A typo in the table would read as a characteristic that is simply never there, which
        // is indistinguishable from a firmware that does not have it.
        for characteristic in CairnGATT.Characteristic.allCases {
            let uuid = CBUUID(string: characteristic.uuid)
            #expect(CairnGATT.characteristic(uuid: uuid.uuidString) == characteristic,
                    "\(characteristic.title) did not come back as itself")
        }
        #expect(CBUUID(string: CairnGATT.serviceUUID).uuidString.count == 36)
    }

    @Test("the radio's states map one to one")
    func managerStates() {
        #expect(CBManagerState.unknown.linkState == .unknown)
        #expect(CBManagerState.resetting.linkState == .resetting)
        #expect(CBManagerState.unsupported.linkState == .unsupported)
        #expect(CBManagerState.unauthorized.linkState == .unauthorised)
        #expect(CBManagerState.poweredOff.linkState == .poweredOff)
        #expect(CBManagerState.poweredOn.linkState == .poweredOn)
    }
}
