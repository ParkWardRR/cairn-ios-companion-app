#if canImport(UIKit)
import UIKit
#endif
import Foundation

@MainActor
public final class PowerStateMonitor: ObservableObject {
    @Published public private(set) var isCharging = false

    public init() {
        #if canImport(UIKit) && os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: UIDevice.batteryStateDidChangeNotification, object: nil)
        #endif
    }

    #if canImport(UIKit) && os(iOS)
    @objc private func refresh() {
        let state = UIDevice.current.batteryState
        isCharging = (state == .charging || state == .full)
    }
    #endif
}
