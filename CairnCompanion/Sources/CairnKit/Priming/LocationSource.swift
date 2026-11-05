import CairnProtocol
import Foundation

/// Where the phone's position comes from.
///
/// Behind a protocol for the usual reason — `PrimingPolicy` is tested against fakes — and for
/// one specific one: the old app created its background location session only when an
/// `OBD_LIVE` or `DEVICE_STATUS` notification arrived, and the shipping firmware exposes
/// neither, so the session was never created and streaming almost certainly stopped the moment
/// the phone locked. The live store holds zero phone positions. Here the session is tied to one
/// thing and one thing only: the link being ready.
@MainActor
public protocol LocationSource: AnyObject {
    /// The most recent fix, however old. This is what a hint is made from, so "however old"
    /// is the point.
    var lastFix: PhoneGNSSFix? { get }
    /// Whether the phone is on power, for `companion_flags` bit 0.
    var isCharging: Bool { get }
    /// Called for each new fix, on the main actor.
    var onFix: (@MainActor (PhoneGNSSFix) -> Void)? { get set }
    /// Called when the owner's answer to the location prompt changes.
    var onAuthorisationChanged: (@MainActor (LocationAuthorisation) -> Void)? { get set }

    var authorisation: LocationAuthorisation { get }

    /// Start a background-capable session. Called at link-ready, and never on a notification
    /// from a characteristic that may not exist.
    func start()
    func stop()
    /// Ask for permission, if it has not been asked for.
    func requestAuthorisation()
}

public enum LocationAuthorisation: Equatable, Sendable {
    case notDetermined
    /// Only while the app is on screen. Enough for a demonstration, not enough for a drive:
    /// the phone spends a drive locked in a mount.
    case whenInUse
    case always
    case denied
    case restricted

    /// Whether a drive's worth of streaming will survive the screen going off.
    public var survivesALockedPhone: Bool { self == .always || self == .whenInUse }

    public var title: String {
        switch self {
        case .notDetermined: "Not asked yet"
        case .whenInUse: "While using the app"
        case .always: "Always"
        case .denied: "Denied"
        case .restricted: "Not allowed on this phone"
        }
    }
}

/// A location source a test drives by hand.
@MainActor
public final class FakeLocationSource: LocationSource {
    public var lastFix: PhoneGNSSFix?
    public var isCharging = false
    public var onFix: (@MainActor (PhoneGNSSFix) -> Void)?
    public var onAuthorisationChanged: (@MainActor (LocationAuthorisation) -> Void)?
    public var authorisation: LocationAuthorisation = .always
    public private(set) var isRunning = false
    public private(set) var starts = 0
    public private(set) var stops = 0
    public private(set) var authorisationRequests = 0

    public init(lastFix: PhoneGNSSFix? = nil) {
        self.lastFix = lastFix
    }

    public func start() {
        isRunning = true
        starts += 1
    }

    public func stop() {
        isRunning = false
        stops += 1
    }

    public func requestAuthorisation() { authorisationRequests += 1 }

    /// Deliver a fix the way Core Location would.
    public func deliver(_ fix: PhoneGNSSFix) {
        lastFix = fix
        onFix?(fix)
    }
}
