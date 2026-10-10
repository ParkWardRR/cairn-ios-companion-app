import CairnCore
import Foundation
import Testing

@Suite("Build identity and channel")
struct BuildIdentityTests {
    @Test func aStampedChannelIsReadBack() {
        #expect(Channel(stamp: "stable") == .stable)
        #expect(Channel(stamp: "beta") == .beta)
        #expect(Channel(stamp: "dev") == .dev)
    }

    @Test func caseAndSurroundingSpaceDoNotMatter() {
        // Build settings arrive through xcconfig and Info.plist expansion, which is not a place
        // to be strict about whitespace.
        #expect(Channel(stamp: "  Stable ") == .stable)
        #expect(Channel(stamp: "BETA") == .beta)
    }

    @Test func anUnknownOrMissingChannelIsDevAndNeverStable() {
        // A build that cannot say what it is must not claim the word that carries a promise.
        #expect(Channel(stamp: nil) == .dev)
        #expect(Channel(stamp: "") == .dev)
        #expect(Channel(stamp: "production") == .dev)
        #expect(Channel(stamp: "$(CAIRN_CHANNEL)") == .dev)
    }

    @Test func onlyStableIsSilentAboutItself() {
        #expect(Channel.stable.warrantsNotice == false)
        #expect(Channel.stable.notice == nil)
        for channel in [Channel.dev, .beta] {
            #expect(channel.warrantsNotice)
            #expect(channel.notice != nil)
        }
    }

    @Test func anIdentityIsReadOutOfAnInfoDictionary() {
        let id = BuildIdentity(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "11",
            "CairnChannel": "stable",
            "CairnCommit": "a1b2c3d",
        ])
        #expect(id.version == "0.1.0")
        #expect(id.build == "11")
        #expect(id.channel == .stable)
        #expect(id.commit == "a1b2c3d")
        #expect(id.shortDescription == "0.1.0 (11)")
        #expect(id.fullDescription == "0.1.0 (11) · stable · a1b2c3d")
    }

    @Test func anUnexpandedOrPlaceholderCommitIsNoCommit() {
        // CAIRN_COMMIT defaults to "unknown", so a build made by hand is distinguishable from a
        // released one instead of silently claiming a hash.
        for stamp in ["unknown", "", "   ", "$(CAIRN_COMMIT)"] {
            let id = BuildIdentity(version: "0.1.0", build: "11", channel: .dev, commit: stamp)
            #expect(id.commit == nil, "\(stamp) should not read as a commit")
            #expect(id.fullDescription == "0.1.0 (11) · dev")
        }
    }

    @Test func anEmptyInfoDictionaryStillProducesAnIdentity() {
        // Rather than crashing a diagnostics screen in the one build where something is wrong.
        let id = BuildIdentity(infoDictionary: nil)
        #expect(id.version == "0")
        #expect(id.build == "0")
        #expect(id.channel == .dev)
        #expect(id.commit == nil)
    }
}
