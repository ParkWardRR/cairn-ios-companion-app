import Foundation
import Testing
@testable import CairnKit
@testable import CairnProtocol

// Worked by hand for E37: stoich 14.7 - 0.37 x 5.7 = 12.591, density 2834 + 0.37 x 154 = 2890.98 g/gal.
// 15 g/s of air at lambda 1.0 burns 15 / 12.591 = 1.1913 g/s = 1.4835 gal/h; at 100 km/h (62.137 mph) that is 41.89 mpg.
private func samples(_ n: Int, kph: Double = 100, maf: Double = 1500, lambda: Double = 1.0) -> [FuelSample] {
    Array(repeating: FuelSample(speedKph: kph, mafCgps: maf, lambda: lambda), count: n)
}

@Suite struct FuelEstimateTests {
    @Test func matchesTheHandWorkedFigureAtE37() throws {
        let e = try #require(FuelEstimate(samples: samples(5)))
        #expect(abs(e.tripMpg - 41.89) < 0.05)
        #expect(e.ethanolPercent == 37)
        #expect(e.sampleCount == 5)
    }

    @Test func gasolineGoesFartherThanE37() throws {
        // E0: stoich 14.7, density 2834: 1.2962 gal/h, so 47.94 mpg
        let e0 = try #require(FuelEstimate(samples: samples(5), ethanolPercent: 0))
        #expect(abs(e0.tripMpg - 47.94) < 0.1)
        let e37 = try #require(FuelEstimate(samples: samples(5)))
        #expect(e0.tripMpg > e37.tripMpg)
    }

    @Test func needsAFewSamplesBeforeItSaysAnything() {
        #expect(FuelEstimate(samples: samples(2)) == nil)
        #expect(FuelEstimate(samples: []) == nil)
    }

    @Test func leavesOutSensorsThatHaveNotSettledAndFlowsThatAreNotAnEngine() throws {
        // two good, one lean spike, one rich spike: only two usable, so too few
        #expect(FuelEstimate(samples: samples(2) + samples(1, lambda: 1.6) + samples(1, lambda: 0.4)) == nil)
        // an absurd airflow (a stuck reading) is dropped too
        #expect(FuelEstimate(samples: samples(3) + samples(1, maf: 60000)) != nil)
        let e = try #require(FuelEstimate(samples: samples(3) + samples(1, maf: 60000)))
        #expect(e.sampleCount == 3)
    }

    @Test func idleCountsAgainstTheTripButNotTheCruise() throws {
        let idle = samples(3, kph: 0, maf: 300)
        let e = try #require(FuelEstimate(samples: samples(3) + idle))
        let cruise = try #require(e.cruiseMpg)
        #expect(abs(cruise - 41.89) < 0.05)
        #expect(e.tripMpg < cruise)
    }

    @Test func aTripThatNeverMovedHasNoCruiseFigure() throws {
        let e = try #require(FuelEstimate(samples: samples(4, kph: 0, maf: 300)))
        #expect(e.cruiseMpg == nil)
        #expect(e.tripMpg == 0)
    }

    @Test func gallonsFollowFromTheDistance() throws {
        let e = try #require(FuelEstimate(samples: samples(5)))
        #expect(abs(try #require(e.gallons(overMeters: 1609.34)) - 1 / 41.89) < 0.001)
        #expect(e.gallons(overMeters: 0) == 0)
    }

    @Test func clampsAnEthanolSettingToWhatAFuelCanBe() throws {
        #expect(try #require(FuelEstimate(samples: samples(5), ethanolPercent: 400)).ethanolPercent == 85)
        #expect(try #require(FuelEstimate(samples: samples(5), ethanolPercent: -5)).ethanolPercent == 0)
    }
}
