import CairnKit
import MapKit
import SwiftUI

/// One drive: where it went, and what the numbers were.
///
/// The route comes from the server's track endpoint rather than from a Parquet snapshot the
/// phone would have to carry a database to read (decision D4). Offline, the summary is still
/// shown with "last synced" rather than an error: everything but the map is already here, and a
/// screen that refuses to open because a map could not load is a screen that hides what it has.
struct TripDetailScreen: View {
    let trip: TripSummary
    @Environment(AppModel.self) private var model

    @State private var track: TripTrack?
    @State private var loading = false
    @State private var failure: String?

    private var units: DisplayUnits { .forLocale(.current) }

    var body: some View {
        List {
            mapSection
            statSection
            detailSection
        }
        .navigationTitle(trip.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTrack() }
    }

    // MARK: - The route

    @ViewBuilder
    private var mapSection: some View {
        Section {
            if let track, !track.isEmpty {
                RouteMap(track: track)
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
                if track.thinned == true {
                    Text("The route is drawn from a reduced set of points: the shape is right, "
                         + "the spacing is not.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !track.gaps.isEmpty {
                    Text("\(track.gaps.count == 1 ? "One gap" : "\(track.gaps.count) gaps") in "
                         + "the track, \(LinkHealth.ageLabel(track.totalGap)) in total. The line "
                         + "stops at each one rather than guessing across it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else if loading {
                HStack { ProgressView(); Text("Fetching the route…").foregroundStyle(.secondary) }
            } else if let failure {
                Text(failure).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("This drive has no trusted positions, so there is no route to draw. "
                     + "The numbers below are still the dongle's.")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - The numbers

    private var statSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 16) {
                Stat(units.distanceParts(metres: trip.distanceMetres), "Distance")
                Stat((LinkHealth.ageLabel(trip.duration), ""), "Duration")
                Stat((LinkHealth.ageLabel(trip.driving), ""), "Moving")
                if let top = trip.topSpeedKph {
                    Stat(units.speedParts(kph: top), "Top")
                }
                if let average = trip.averageDrivingSpeedKph {
                    Stat(units.speedParts(kph: average), "Average")
                }
                if let rpm = trip.maxRPM {
                    Stat(("\(rpm)", "rpm"), "Peak")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var detailSection: some View {
        Group {
            Section {
                LabeledContent("Car", value: model.sync.book.vehicleName(trip.vehicleID))
                LabeledContent("Started", value: trip.startedAt.formatted(date: .omitted, time: .standard))
                LabeledContent("Ended", value: trip.endedAt.formatted(date: .omitted, time: .standard))
                if trip.legCount > 1 {
                    LabeledContent("Legs", value: "\(trip.legCount)")
                }
                if trip.gapCount > 0 {
                    LabeledContent("Recording gaps",
                                   value: "\(trip.gapCount) · \(LinkHealth.ageLabel(trip.gapDuration))")
                }
            } header: {
                Text("This drive")
            } footer: {
                if trip.legCount > 1 {
                    Text("An outing is consecutive drives merged across short stops, so the "
                         + "duration includes the stops and \"moving\" does not.")
                }
            }

            Section("What it was measured from") {
                LabeledContent("GNSS samples", value: "\(trip.gnssSamples)")
                LabeledContent("OBD samples", value: "\(trip.obdSamples)")
                if trip.boostSamples > 0 {
                    LabeledContent("Boost samples", value: "\(trip.boostSamples)")
                }
                LabeledContent("Bundles", value: "\(trip.bundleCount)")
                LabeledContent("Decoder", value: "v\(trip.decoderVersion)")
                LabeledContent("Trip id", value: trip.id)
                    .font(.caption.monospaced())
            }
        }
    }

    // MARK: - Loading

    private func loadTrack() async {
        guard track == nil, !loading else { return }
        loading = true
        defer { loading = false }
        guard let client = await model.server.client() else {
            failure = "The server can't be reached, so there is no route yet. Everything else "
                + "here was already synced."
            return
        }
        do {
            track = try await client.track(
                tripID: trip.id,
                endedMS: Int64(trip.endedAt.timeIntervalSince1970 * 1000)
            )
        } catch CairnServerError.notFound {
            failure = "This server keeps no positions, so it has no route for this drive."
        } catch {
            failure = "The route could not be fetched. Everything else here was already synced."
        }
    }
}

private struct Stat: View {
    let value: String
    let unit: String
    let label: String

    init(_ parts: (value: String, unit: String), _ label: String) {
        self.value = parts.value
        self.unit = parts.unit
        self.label = label
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.monospacedDigit().weight(.semibold))
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The route, one line per run.
///
/// Per run, never one line through everything: a gap is a gap in knowledge, not a straight
/// road, and a single polyline across a dropout draws a car going through buildings.
private struct RouteMap: View {
    let track: TripTrack

    var body: some View {
        Map(initialPosition: .region(region)) {
            ForEach(Array(track.decodedRuns.enumerated()), id: \.offset) { _, run in
                MapPolyline(coordinates: run.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                })
                .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let start = track.decodedRuns.first?.first {
                Marker("Start", systemImage: "flag", coordinate:
                        CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude))
                .tint(.green)
            }
            if let end = track.decodedRuns.last?.last {
                Marker("End", systemImage: "flag.checkered", coordinate:
                        CLLocationCoordinate2D(latitude: end.latitude, longitude: end.longitude))
                .tint(.red)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private var region: MKCoordinateRegion {
        guard let bounds = track.bounds else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
            )
        }
        let centre = CLLocationCoordinate2D(
            latitude: (bounds.southWest.latitude + bounds.northEast.latitude) / 2,
            longitude: (bounds.southWest.longitude + bounds.northEast.longitude) / 2
        )
        // A fifth of padding, and a floor so a drive round one block is not a map of one street.
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.004, (bounds.northEast.latitude - bounds.southWest.latitude) * 1.2),
            longitudeDelta: max(0.004, (bounds.northEast.longitude - bounds.southWest.longitude) * 1.2)
        )
        return MKCoordinateRegion(center: centre, span: span)
    }
}
