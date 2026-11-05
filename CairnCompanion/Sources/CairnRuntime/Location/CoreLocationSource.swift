import CairnKit
import CairnProtocol
import CoreLocation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

public extension PhoneGNSSFix {
    /// Core Location's own values, unchanged. Negative accuracy, speed and course keep their
    /// meaning here and are mapped to sentinels by `PayloadEncoder`, not before — an invalid
    /// reading that becomes a plausible number somewhere in the middle is the hardest kind of
    /// wrong to find later.
    init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            ellipsoidalAltitude: location.ellipsoidalAltitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            course: location.course,
            timestamp: location.timestamp
        )
    }
}

/// Core Location behind `LocationSource`.
///
/// Two things here are the point of R2.
///
/// **The session is tied to the link.** `start()` is called when the link becomes ready and at
/// no other time. The old app created its background session only on an `OBD_LIVE` or
/// `DEVICE_STATUS` notification, and the shipping firmware exposes neither, so the session was
/// never created, streaming almost certainly stopped at the lock screen, and the live store
/// holds zero phone positions.
///
/// **It uses `CLBackgroundActivitySession`.** That is what keeps updates arriving with the
/// screen off and puts the blue indicator up honestly while it does. `CLLocationUpdate
/// .liveUpdates` is the modern stream and needs iOS 17; the floor here is 18.
@MainActor
public final class CoreLocationSource: NSObject, LocationSource {
    public private(set) var lastFix: PhoneGNSSFix?
    public var onFix: (@MainActor (PhoneGNSSFix) -> Void)?
    public var onAuthorisationChanged: (@MainActor (LocationAuthorisation) -> Void)?

    private let manager = CLLocationManager()
    private var updates: Task<Void, Never>?
    #if os(iOS)
    private var session: CLBackgroundActivitySession?
    #endif

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        // Whatever the last fix was, however old. This is what a hint is made of, and asking
        // for it costs nothing: it is a value Core Location is already holding.
        lastFix = manager.location.map(PhoneGNSSFix.init)
    }

    public var authorisation: LocationAuthorisation {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorizedWhenInUse: .whenInUse
        case .authorizedAlways: .always
        @unknown default: .notDetermined
        }
    }

    public var isCharging: Bool {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #else
        return false
        #endif
    }

    public func requestAuthorisation() {
        // `WhenInUse` first, which is what Apple requires before `Always` can be asked for. A
        // background activity session then keeps updates coming with the screen off, so
        // `WhenInUse` plus the session is enough for a drive.
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    public func start() {
        #if os(iOS)
        guard updates == nil else { return }
        if session == nil { session = CLBackgroundActivitySession() }
        updates = Task { @MainActor [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                    guard !Task.isCancelled else { return }
                    guard let location = update.location else { continue }
                    let fix = PhoneGNSSFix(location)
                    self?.lastFix = fix
                    self?.onFix?(fix)
                }
            } catch {
                // The stream ends when authorisation goes away or the session is invalidated.
                // Both are states the screen already shows; there is nothing to retry here.
            }
        }
        #else
        // macOS, so that the package builds and `swift test` runs. There is no background
        // activity session and no dongle on a Mac either; what runs here is the compiler.
        manager.startUpdatingLocation()
        #endif
    }

    public func stop() {
        updates?.cancel()
        updates = nil
        #if os(iOS)
        session?.invalidate()
        session = nil
        #else
        manager.stopUpdatingLocation()
        #endif
    }
}

extension CoreLocationSource: @preconcurrency CLLocationManagerDelegate {
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorisationChanged?(authorisation)
    }

    #if !os(iOS)
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let fix = PhoneGNSSFix(location)
        lastFix = fix
        onFix?(fix)
    }
    #endif
}
