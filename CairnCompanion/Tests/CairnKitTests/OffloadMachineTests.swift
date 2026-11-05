import CairnKit
import CairnProtocol
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func row(
    _ stage: BundleStage, chunksDone: Int = 0, chunksTotal: Int = 0,
    receipt: Data? = nil, stop: String? = nil
) -> BundleRow {
    BundleRow(
        bundleID: "aa", stage: stage, chunksDone: chunksDone, chunksTotal: chunksTotal,
        receipt: receipt, stopCode: stop, firstSeenAt: t0, updatedAt: t0
    )
}

@Suite("OffloadMachine: what to do next")
struct OffloadMachineNextTests {
    let machine = OffloadMachine()

    @Test("each stage leads to the next")
    func theWalk() {
        #expect(machine.next(for: row(.listed)) == .readManifest)
        #expect(machine.next(for: row(.manifest)) == .offerToServer)
        #expect(machine.next(for: row(.offered)) == .uploadChunks)
        #expect(machine.next(for: row(.chunking, chunksDone: 2, chunksTotal: 5)) == .uploadChunks)
        #expect(machine.next(for: row(.chunking, chunksDone: 5, chunksTotal: 5)) == .commit)
        #expect(machine.next(for: row(.delivered)) == .done)
    }

    @Test("a phone that died holding a receipt resumes at the handback, not at the upload")
    func resumeAtDelivery() {
        // This is the one the stage exists for. Between the server committing and the dongle
        // verifying, the trip is in two places and owned by neither: the server has the bytes
        // and will not say so again unasked, and the dongle still has them and will not free
        // the space. Re-uploading would be a whole trip's worth of radio for nothing.
        let receipt = Data("RECEIPT".utf8)
        #expect(machine.next(for: row(.receiptHeld, receipt: receipt)) == .deliverReceipt(receipt))
        #expect(machine.next(for: row(.committed, receipt: receipt)) == .deliverReceipt(receipt))
    }

    @Test("committed with no receipt bytes goes back for them rather than guessing")
    func committedWithoutReceipt() {
        #expect(machine.next(for: row(.committed)) == .commit)
    }

    @Test("a bundle that was refused stays refused")
    func stoppedStaysStopped() {
        #expect(machine.next(for: row(.offered, stop: "quarantined")) == .stopped("quarantined"))
        // Even one that looks finished: the stop is the last word.
        #expect(machine.next(for: row(.listed, stop: "scope")) == .stopped("scope"))
    }

    @Test("the stages are ordered, so progress can be compared")
    func stagesAreOrdered() {
        #expect(BundleStage.listed < BundleStage.manifest)
        #expect(BundleStage.committed < BundleStage.receiptHeld)
        #expect(BundleStage.receiptHeld < BundleStage.delivered)
        #expect(BundleStage.allCases.count == 7)
    }

    @Test("a row knows whether it is still owed work")
    func pending() {
        #expect(row(.offered).isPending)
        #expect(!row(.delivered).isPending)
        #expect(!row(.offered, stop: "scope").isPending)
    }
}

@Suite("OffloadMachine: when to run, and when to leave")
struct OffloadMachineTimingTests {
    let machine = OffloadMachine()

    @Test("it runs only with a link, no trip in progress, and an enrolled phone")
    func shouldRun() {
        #expect(machine.shouldRun(linkReady: true, tripActive: false, enrolled: true))
        #expect(!machine.shouldRun(linkReady: false, tripActive: false, enrolled: true))
        #expect(!machine.shouldRun(linkReady: true, tripActive: true, enrolled: true),
                "the dongle serves nothing during a drive, and that is correct")
        #expect(!machine.shouldRun(linkReady: true, tripActive: false, enrolled: false))
    }

    @Test("it leaves at fourteen minutes of the dongle's fifteen-minute standby cap")
    func leavesPolitely() {
        #expect(!machine.shouldLeave(connectedFor: 13 * 60))
        #expect(machine.shouldLeave(connectedFor: OffloadMachine.leaveAt))
        #expect(OffloadMachine.leaveAt < OffloadMachine.sessionCap,
                "leaving has to happen before being cut off, or there is no point to it")
    }

    @Test("a full LIST page means there may be more behind it")
    func listPaging() {
        // The dongle answers at most sixteen entries. A drive that was never offloaded leaves
        // more than that, and a loop that asks once gets sixteen trips and forgets the rest.
        #expect(machine.needsAnotherList(received: 16, newSealedSeen: true))
        #expect(!machine.needsAnotherList(received: 16, newSealedSeen: false),
                "a full page that added nothing new is the end")
        #expect(!machine.needsAnotherList(received: 3, newSealedSeen: true))
        #expect(OffloadMachine.listPageSize == 16)
    }
}

@Suite("OffloadMachine: every error by name")
struct OffloadMachineErrorTests {
    let machine = OffloadMachine()

    @Test("429 too_many_offers is a sequencing instruction, not a failure")
    func tooManyOffers() {
        // The data is fine. Backing off as though the server were overloaded would make a full
        // queue take a whole extra drive to clear.
        #expect(machine.interpret(.tooManyOffers) == .commitOutstandingFirst)
        #expect(machine.interpret(.rateLimited(retryAfter: 30)) == .backOff(30),
                "the other 429 really does mean slow down")
        #expect(OffloadStopReason.tooManyOffers.isRetryable)
        #expect(!OffloadStopReason.tooManyOffers.needsAttention)
    }

    @Test("507 quota_exceeded stops and says so")
    func quotaExceeded() {
        #expect(machine.interpret(.quotaExceeded) == .stopRun(.quotaExceeded))
        #expect(!OffloadStopReason.quotaExceeded.isRetryable)
        #expect(OffloadStopReason.quotaExceeded.needsAttention)
    }

    @Test("the three 403s the plan names stop the run with their own code")
    func forbidden() {
        for reason in [ForbiddenReason.scope, .assignmentRefused, .noStorageKey] {
            #expect(machine.interpret(.forbidden(reason)) == .stopRun(.refused(reason.code)),
                    "\(reason.code)")
        }
    }

    @Test("422 quarantined is about one bundle, not about the phone")
    func quarantined() {
        #expect(machine.interpret(.quarantined) == .stopBundle("quarantined"))
        // So are the other per-bundle refusals: the rest of the run can still go.
        #expect(machine.interpret(.badManifestSignature) == .stopBundle("bad_manifest_signature"))
        #expect(machine.interpret(.conflict(code: "chunk_mismatch")) == .stopBundle("chunk_mismatch"))
    }

    @Test("a sign-in the server will not take stops the run and says which kind of problem it is")
    func signIn() {
        for error in [CairnServerError.unauthenticated, .signatureRequired,
                      .clockSkew(phoneAheadBySeconds: 300), .signingFailed] {
            guard case .stopRun(.serverUnavailable(let why)) = machine.interpret(error) else {
                Issue.record("\(error) should stop the run"); continue
            }
            #expect(why.contains("sign-in"))
        }
    }

    @Test("a server that is not there is a stop with nothing lost")
    func unreachable() {
        guard case .stopRun(let reason) = machine.interpret(.transport(.offline)) else {
            Issue.record("should stop"); return
        }
        #expect(reason.needsAttention)
        #expect(reason.isRetryable, "the dongle keeps everything; the next drive tries again")
        #expect(reason.sentence.contains("Nothing was lost"))
    }

    @Test("receipt outcome 2 and 3 stop and are never retried blindly")
    func receiptRejected() {
        for outcome in [PutReceiptOutcome.rejectedSignature, .rejectedContentRoot] {
            guard case .stopRun(let reason) = machine.interpret(receipt: outcome) else {
                Issue.record("\(outcome) should stop the run"); continue
            }
            #expect(!reason.isRetryable, "the keys disagree; sending it again changes nothing")
            #expect(reason.needsAttention)
            #expect(reason.sentence.contains("pinned key"))
        }
        // An outcome this build does not know is treated the same way, which is the safe side.
        guard case .stopRun = machine.interpret(receipt: .unknown(9)) else {
            Issue.record("an unknown outcome should stop"); return
        }
    }

    @Test("a dongle with no receipt key is a stop the owner has to act on")
    func noReceiptKey() {
        #expect(machine.interpret(receipt: .noPinnedKey) == .stopRun(.dongleHasNoReceiptKey))
        #expect(!OffloadStopReason.dongleHasNoReceiptKey.isRetryable)
        #expect(OffloadStopReason.dongleHasNoReceiptKey.sentence.contains("safe on the server"))
    }

    @Test("both good receipt outcomes are done")
    func receiptAccepted() {
        #expect(machine.interpret(receipt: .verifiedAndPruned) == .delivered)
        #expect(machine.interpret(receipt: .verifiedPruneIncomplete) == .delivered,
                "the dongle finishes the delete at boot; the trip is carried either way")
    }

    @Test("a trip in progress is not a problem and does not say it is")
    func tripActive() {
        #expect(!OffloadStopReason.tripActive.needsAttention)
        #expect(OffloadStopReason.tripActive.isRetryable)
        #expect(OffloadStopReason.tripActive.sentence.contains("after the drive"))
        #expect(OffloadStopReason.dongleBusy.sentence.contains("Trying again"))
    }

    @Test("every stop has a code, a sentence and an opinion about attention")
    func everyStopIsSayable() {
        let all: [OffloadStopReason] = [
            .tripActive, .dongleBusy, .nothingWaiting, .linkLost("x"), .serverUnavailable("y"),
            .tooManyOffers, .quotaExceeded, .refused("scope"), .receiptRejected(2),
            .dongleHasNoReceiptKey, .sessionCapReached,
        ]
        for reason in all {
            #expect(!reason.code.isEmpty, "\(reason)")
            #expect(reason.sentence.count > 20, "\(reason): \(reason.sentence)")
        }
    }
}

@Suite("OffloadSummary")
struct OffloadSummaryTests {
    @Test("the headline is the sentence the Dongle screen shows")
    func headline() {
        var summary = OffloadSummary()
        #expect(summary.headline == "Nothing waiting")
        summary.waiting = 3
        #expect(summary.headline == "3 trips waiting on the dongle")
        summary.waiting = 1
        #expect(summary.headline == "1 trip waiting on the dongle")
        summary.uploading = (2, 5)
        #expect(summary.headline == "Uploading 2 of 5")
        summary.uploading = nil
        summary.waiting = 0
        summary.delivered = 4
        #expect(summary.headline == "All synced")
    }
}
