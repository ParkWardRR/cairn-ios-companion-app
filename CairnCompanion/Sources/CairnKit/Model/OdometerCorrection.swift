import Foundation

public struct OdometerCorrection: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public var vehicleID: String
    public var odometerKm: Int
    public var recordedAt: Date
    public var revision: Int

    public init(
        id: String = UUID().uuidString,
        vehicleID: String,
        odometerKm: Int,
        recordedAt: Date = Date(),
        revision: Int = 1
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.odometerKm = odometerKm
        self.recordedAt = recordedAt
        self.revision = revision
    }

    public var odometerMiles: Int {
        Int(Double(odometerKm) * 0.621371)
    }

    public func formatted(useMiles: Bool = false) -> String {
        if useMiles {
            return "\(odometerMiles.formatted()) mi"
        }
        return "\(odometerKm.formatted()) km"
    }
}
