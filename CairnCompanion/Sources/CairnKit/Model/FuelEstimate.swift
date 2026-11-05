import CairnProtocol
import Foundation

/// One moment the dongle caught both the engine's airflow and the car's speed. MAF is only polled on
/// some rounds of the OBD chain, so a trip has a few dozen of these, not a continuous series.
public struct FuelSample: Codable, Sendable, Equatable {
    public let speedKph: Double
    /// Mass airflow in centigrams per second, as the ECU reports it.
    public let mafCgps: Double
    /// Air-fuel equivalence ratio (1.0 is stoichiometric).
    public let lambda: Double

    public init(speedKph: Double, mafCgps: Double, lambda: Double) {
        self.speedKph = speedKph
        self.mafCgps = mafCgps
        self.lambda = lambda
    }
}

/// Fuel economy estimated from MAF airflow and lambda: the ECU's own fuel rate is not read, so this is an
/// estimate and says how many samples it rests on. The same maths as the web dashboard's trip page
/// (`useFuelMath.ts`), so a trip reads the same in both places.
public struct FuelEstimate: Sendable, Equatable {
    /// Total speed over total fuel flow, idle samples included.
    public let tripMpg: Double
    /// Samples above 5 km/h only; nil when none.
    public let cruiseMpg: Double?
    public let sampleCount: Int
    public let ethanolPercent: Int

    public static let defaultEthanolPercent = 37
    /// Where the app keeps the owner's blend (UserDefaults).
    public static let ethanolKey = "cairn.ethanolBlend"
    /// Fewer than this and nothing is worth showing.
    public static let minimumSamples = 3

    // MARK: Fuel properties for an ethanol blend

    static func stoich(_ eth: Double) -> Double { 14.7 - (eth / 100) * 5.7 }
    static func densityGramsPerGallon(_ eth: Double) -> Double { 2834 + (eth / 100) * 154 }

    /// Gallons per hour from MAF (centigrams per second) and lambda.
    static func gallonsPerHour(mafCgps: Double, lambda: Double, ethanol: Double) -> Double {
        let gramsPerSecond = (mafCgps / 100) / (stoich(ethanol) * lambda)
        return gramsPerSecond / densityGramsPerGallon(ethanol) * 3600
    }

    public init?(samples: [FuelSample], ethanolPercent: Int = FuelEstimate.defaultEthanolPercent) {
        guard samples.count >= Self.minimumSamples else { return nil }
        let eth = Double(min(85, max(0, ethanolPercent)))
        // a lambda outside this range is a sensor that has not settled, and a flow outside it is not an engine
        let rows = samples
            .filter { $0.lambda > 0.7 && $0.lambda < 1.3 }
            .map { (mph: $0.speedKph / 1.60934, gph: Self.gallonsPerHour(mafCgps: $0.mafCgps, lambda: $0.lambda, ethanol: eth), kph: $0.speedKph) }
            .filter { $0.gph > 0 && $0.gph < 40 }
        guard rows.count >= Self.minimumSamples else { return nil }

        let totalGph = rows.reduce(0) { $0 + $1.gph }
        self.tripMpg = rows.reduce(0) { $0 + $1.mph } / totalGph
        let moving = rows.filter { $0.kph > 5 }
        self.cruiseMpg = moving.isEmpty ? nil : moving.reduce(0) { $0 + $1.mph } / moving.reduce(0) { $0 + $1.gph }
        self.sampleCount = rows.count
        self.ethanolPercent = Int(eth)
    }

    /// Gallons burned over `meters`, at the estimated economy.
    public func gallons(overMeters meters: Double) -> Double? {
        tripMpg > 0 ? (meters / 1609.34) / tripMpg : nil
    }
}
