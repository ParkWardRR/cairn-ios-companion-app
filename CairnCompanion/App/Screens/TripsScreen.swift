import CairnKit
import SwiftUI

/// Every drive the server has published, grouped by day.
///
/// The list is one row per **outing**, not one per published record. A trip's identity moves —
/// `sync/v1` §12 — so the same drive can be published under two ids, and a list keyed on id
/// alone shows it twice with the duplicate claiming a start the car never had. `TripBook` does
/// the reconciling; this just reads it.
struct TripsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var now = Date()

    private var sync: SyncEngine { model.sync }

    var body: some View {
        NavigationStack {
            Group {
                if !model.server.isEnrolled {
                    ContentUnavailableView {
                        Label("No server yet", systemImage: "externaldrive")
                    } description: {
                        Text("Trips come from your own server. Set this phone up with it on the "
                             + "Dongle screen.")
                    }
                } else if sync.trips.isEmpty {
                    ContentUnavailableView {
                        Label("No trips yet", systemImage: "car")
                    } description: {
                        Text(sync.lastFailure.map { "The last sync did not finish: \($0)." }
                             ?? "Drives appear here once the dongle's trips reach the server.")
                    } actions: {
                        Button("Sync Now") { Task { await sync.sync() } }
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Trips")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if sync.isSyncing {
                        ProgressView()
                    } else {
                        Button("Sync", systemImage: "arrow.clockwise") { Task { await sync.sync() } }
                    }
                }
            }
            .refreshable { await sync.sync() }
            .navigationDestination(for: TripSummary.self) { trip in
                TripDetailScreen(trip: trip).environment(model)
            }
        }
    }

    private var list: some View {
        List {
            if let failure = sync.lastFailure {
                Section {
                    // Offline is not empty. What is already here is still true, and saying
                    // when it was last true is more use than hiding it.
                    Text("\(failure). Showing what was last synced"
                         + (sync.lastSyncAt.map { ", \(LinkHealth.ageLabel(now.timeIntervalSince($0))) ago" } ?? "")
                         + ".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            ForEach(sync.days) { day in
                Section {
                    ForEach(day.trips) { trip in
                        NavigationLink(value: trip) { TripRow(trip: trip, book: sync.book) }
                    }
                } header: {
                    HStack {
                        Text(day.id, format: .dateTime.weekday(.wide).day().month(.wide))
                        Spacer()
                        Text(DisplayUnits.forLocale(.current).distanceCaption(metres: day.totalDistanceMetres))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

private struct TripRow: View {
    let trip: TripSummary
    let book: TripBook

    private var units: DisplayUnits { .forLocale(.current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(trip.startedAt, format: .dateTime.hour().minute())
                    .font(.headline)
                if trip.isBench {
                    Text("bench")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text(units.distanceCaption(metres: trip.distanceMetres))
                    .font(.headline.monospacedDigit())
            }
            HStack(spacing: 10) {
                Text(book.vehicleName(trip.vehicleID))
                Text("·")
                Text(LinkHealth.ageLabel(trip.duration))
                if trip.legCount > 1 {
                    Text("·")
                    Text("\(trip.legCount) legs")
                }
                if let speed = trip.averageDrivingSpeedKph {
                    Text("·")
                    Text(units.speedCaption(kph: speed) + " avg")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
