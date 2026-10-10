import Foundation

/// Which release channel a build belongs to.
///
/// The project ships three: `dev` is a working tree with no promise, `beta` is a tagged
/// pre-release carrying every feature including the unproven ones, and `stable` is a tagged
/// release carrying only what has been proven. The rule and the gates are in the front door's
/// `docs/release-process.md`; this type is how a build on the phone says which one it is.
public enum Channel: String, Sendable, CaseIterable, Codable {
    case dev
    case beta
    case stable

    /// Parses the `CairnChannel` value a build stamps into its Info.plist.
    ///
    /// An unrecognised or absent value is `dev` and never `stable`: a build that cannot say
    /// what it is has not earned the word that carries a promise.
    public init(stamp: String?) {
        guard let stamp, let known = Channel(rawValue: stamp.trimmingCharacters(in: .whitespaces).lowercased()) else {
            self = .dev
            return
        }
        self = known
    }

    /// How the channel is written in the interface.
    public var title: String {
        switch self {
        case .dev: "Development"
        case .beta: "Beta"
        case .stable: "Stable"
        }
    }

    /// Whether a build on this channel should say so to the person using it. A stable build is
    /// the unremarkable case and needs no banner; the other two are worth knowing about.
    public var warrantsNotice: Bool { self != .stable }

    /// What to tell someone running this channel.
    public var notice: String? {
        switch self {
        case .dev: "A development build. Features here may be incomplete or wrong, and data it writes may not survive an upgrade."
        case .beta: "A beta build. It carries features that work in testing but have not been confirmed on real hardware."
        case .stable: nil
        }
    }
}

/// What a build can say about itself: its version, its build number, its channel and the commit
/// it came from.
///
/// Every component of Cairn is required to be able to answer this — the server on `/healthz`, the
/// dashboard in its footer, the firmware in its banner and in a bundle's stamp, and the app here.
/// A release process cannot ship what cannot identify itself.
public struct BuildIdentity: Sendable, Equatable {
    public let version: String
    public let build: String
    public let channel: Channel
    /// The short commit hash, or nil when the build was made outside the release script.
    public let commit: String?

    public init(version: String, build: String, channel: Channel, commit: String?) {
        self.version = version
        self.build = build
        self.channel = channel
        self.commit = Self.normalise(commit)
    }

    /// Reads an identity out of an Info.plist dictionary.
    public init(infoDictionary: [String: Any]?) {
        self.init(
            version: infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            build: infoDictionary?["CFBundleVersion"] as? String ?? "0",
            channel: Channel(stamp: infoDictionary?["CairnChannel"] as? String),
            commit: infoDictionary?["CairnCommit"] as? String
        )
    }

    /// `0.1.0 (11)` — the two numbers a tester reads back when reporting something.
    public var shortDescription: String { "\(version) (\(build))" }

    /// `0.1.0 (11) · beta · a1b2c3d` — everything, for a diagnostics report or a bug report.
    public var fullDescription: String {
        var parts = [shortDescription, channel.rawValue]
        if let commit { parts.append(commit) }
        return parts.joined(separator: " · ")
    }

    /// The placeholder values and the empty string are all "no commit"; `CAIRN_COMMIT` defaults
    /// to `unknown` in the build settings so that a build made by hand is distinguishable from a
    /// released one rather than silently claiming a hash.
    private static func normalise(_ commit: String?) -> String? {
        guard let trimmed = commit?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        let placeholders: Set<String> = ["unknown", "$(CAIRN_COMMIT)", "dirty"]
        return placeholders.contains(trimmed) ? nil : trimmed
    }
}
