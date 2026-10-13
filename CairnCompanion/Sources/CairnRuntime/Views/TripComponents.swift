import CairnCore
import MapKit
import SwiftUI

// MARK: - Formatting

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds).rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
}

/// The duration as a trip card reads it: no seconds once it is minutes long.
func formatTripDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds).rounded())
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(max(1, (s + 30) / 60)) min" }
    return "\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60)) m"
}

/// Miles or kilometres, following the phone's locale, as CarPlay already did.
let tripUnits = DisplayUnits.forLocale(.current)

func formatDistance(_ meters: Double) -> String {
    tripUnits.distanceText(metres: meters)
}

// MARK: - Route sketch

/// The route drawn from its own points, with no map tiles, so a long list stays cheap to scroll.
struct RouteSketchShape: Shape {
    let points: [TripSummary.SketchPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func map(_ p: TripSummary.SketchPoint) -> CGPoint {
            CGPoint(x: origin.x + p.x * side, y: origin.y + (1 - p.y) * side)
        }
        path.move(to: map(points[0]))
        for p in points.dropFirst() { path.addLine(to: map(p)) }
        return path
    }
}

struct RouteSketch: View {
    let summary: TripSummary
    var side: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.tileSurface)
            if summary.routeSketch.count >= 2 {
                RouteSketchShape(points: summary.routeSketch)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .padding(10)
            } else {
                Image(systemName: summary.isBench ? "wrench.and.screwdriver" : "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

// MARK: - Trip card

/// One trip in the list as an overview: a small map of where it went, and the numbers beside it.
struct TripCard: View {
    let summary: TripSummary
    let entry: HistoryEntry
    let annotations: [CairnCore.Annotation]

    private var isFavorite: Bool { annotations.contains { $0.kind == .favorite } }
    private var firstNote: String? { annotations.first { $0.kind == .note }?.text }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TripMapThumbnail(summary: summary)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(summary.startedAt, style: .time).font(.headline)
                    if isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    Spacer(minLength: 4)
                    badges
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        stat(summary.distanceMeters.map(formatDistance), "Distance")
                        stat(formatTripDuration(summary.durationSeconds), "Duration")
                    }
                    GridRow {
                        stat(summary.fuel.map { tripUnits.economyText(mpgUS: $0.tripMpg) }, "Economy")
                        stat(
                            summary.averageSpeedKph.map { tripUnits.speedText(kph: Double($0)) }
                                ?? summary.maxSpeedKph.map { "\(tripUnits.speedText(kph: Double($0))) top" },
                            summary.averageSpeedKph == nil ? "Speed" : "Average"
                        )
                    }
                }
                if let sync = entry.syncLabel {
                    Text(sync).font(.caption).foregroundStyle(.orange)
                }
                if let firstNote {
                    Text(firstNote).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(summary.isBench ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    /// A figure over its label; a dash when there is no figure to give.
    private func stat(_ value: String?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value ?? "\u{2014}")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var badges: some View {
        if summary.isLive {
            BadgePill(text: "LIVE", color: .green)
        } else if summary.isBench {
            BadgePill(text: "BENCH", color: .secondary)
        } else if entry.isOnPhoneOnly {
            Image(systemName: "iphone").font(.caption).foregroundStyle(.secondary)
        } else if entry.isOnServerOnly {
            Image(systemName: "cloud.fill").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The heading above a day's trips: the day, and what it added up to.
struct TripDayHeader: View {
    let day: TripDay

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day.id) { return "Today" }
        if calendar.isDateInYesterday(day.id) { return "Yesterday" }
        return day.id.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text(totals).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .textCase(nil)
    }

    private var totals: String {
        var parts = ["\(day.trips.count) \(day.trips.count == 1 ? "trip" : "trips")"]
        if day.totalDistanceMeters > 0 { parts.append(formatDistance(day.totalDistanceMeters)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Route map

/// The route on a real map with its start and end marked.
struct TripRouteMap: View {
    let runs: [[RoutePoint]]

    var body: some View {
        let coordinates = runs.map { run in run.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }
        if let first = coordinates.first?.first, let last = coordinates.last?.last {
            Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
                ForEach(Array(coordinates.enumerated()), id: \.offset) { _, run in
                    MapPolyline(coordinates: run)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                Marker("Start", systemImage: "flag.fill", coordinate: first).tint(.green)
                Marker("End", systemImage: "flag.checkered", coordinate: last).tint(.red)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
