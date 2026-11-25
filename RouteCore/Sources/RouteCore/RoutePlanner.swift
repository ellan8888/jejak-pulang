import Foundation

public enum RouteDirection: String, Codable, Sendable, CaseIterable {
    /// Dari lokasi tujuan kembali ke titik awal rekaman (rute dibalik).
    case returnTrip
    /// Mengulang rute ke arah yang sama (dari titik awal ke lokasi tujuan).
    case sameDirection
}

public enum TurnSensitivity: String, Codable, Sendable, CaseIterable {
    case fewer, normal, more

    public var threshold: Double {
        switch self {
        case .fewer: return 55
        case .normal: return 40
        case .more: return 28
        }
    }
}

public struct PlannedWaypoint: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case turn, uTurn, manual
    }

    public var id: UUID
    public var coordinate: Coordinate
    /// Jarak tempuh dari awal path (sesuai arah perjalanan).
    public var along: Double
    /// Sudut belok bertanda (+ kanan, − kiri). nil untuk titik manual.
    public var angle: Double?
    public var kind: Kind
    public var isEnabled: Bool

    public init(id: UUID = UUID(), coordinate: Coordinate, along: Double,
                angle: Double?, kind: Kind, isEnabled: Bool = true) {
        self.id = id
        self.coordinate = coordinate
        self.along = along
        self.angle = angle
        self.kind = kind
        self.isEnabled = isEnabled
    }

    /// Bobot kepentingan untuk mode "1 link saja".
    public var importance: Double {
        switch kind {
        case .manual: return 1_000
        case .uTurn: return 0
        case .turn: return abs(angle ?? 0)
        }
    }
}

public struct NavigationPlan: Hashable, Sendable {
    public var direction: RouteDirection
    /// Path sesuai arah perjalanan.
    public var path: [Coordinate]
    public var length: Double
    public var destination: Coordinate
    public var waypoints: [PlannedWaypoint]

    public var orderedEnabled: [PlannedWaypoint] {
        waypoints.filter(\.isEnabled).sorted { $0.along < $1.along }
    }
}

public enum LinkMode: String, Codable, Sendable, CaseIterable {
    /// Semua titik dipakai, dipecah jadi beberapa link berurutan.
    case complete
    /// Hanya 1 link, berisi belokan terpenting.
    case single
}

public enum TravelMode: String, Codable, Sendable, CaseIterable {
    case driving, walking, bicycling
}

public struct MapsLink: Hashable, Sendable, Identifiable {
    public var index: Int          // 0-based
    public var total: Int
    public var waypoints: [Coordinate]
    public var destination: Coordinate
    public var url: URL
    public var appURL: URL
    public var id: Int { index }
}

public struct RoutePlanner: Sendable {
    /// Batas titik singgah Google Maps (aplikasi). Tujuan tidak termasuk.
    public var maxWaypointsPerLink: Int
    /// Titik singgah ditaruh sejauh ini sesudah belokan (di badan jalan, bukan di simpang).
    public var placementOffset: Double
    /// Belokan terlalu dekat ujung path diabaikan.
    public var endpointMargin: Double

    public init(maxWaypointsPerLink: Int = 9, placementOffset: Double = 35, endpointMargin: Double = 25) {
        self.maxWaypointsPerLink = max(1, maxWaypointsPerLink)
        self.placementOffset = placementOffset
        self.endpointMargin = endpointMargin
    }

    /// Siapkan path terarah dari rekaman.
    public func orientedPath(for route: SavedRoute, direction: RouteDirection,
                             cleaner: TrackCleaner = TrackCleaner()) -> MeasuredPath {
        var cleaned = cleaner.clean(route.points)
        if cleaned.count < 2 { cleaned = route.points } // jangan sampai kosong karena filter
        var coords = cleaned.map(\.coordinate)
        if direction == .returnTrip { coords.reverse() }
        return MeasuredPath(coords)
    }

    public func makePlan(route: SavedRoute, direction: RouteDirection,
                         sensitivity: TurnSensitivity = .normal,
                         keepingManual manual: [PlannedWaypoint] = []) -> NavigationPlan? {
        let path = orientedPath(for: route, direction: direction)
        guard let destination = path.coordinates.last else { return nil }

        let detector = TurnDetector(threshold: sensitivity.threshold)
        let turns = detector.detect(in: path)

        var waypoints: [PlannedWaypoint] = []
        for (k, turn) in turns.enumerated() {
            if turn.along < endpointMargin || turn.along > path.length - endpointMargin { continue }
            let nextAlong = k + 1 < turns.count ? turns[k + 1].along : path.length
            let room = nextAlong - turn.along
            let offset = max(8, min(placementOffset, room * 0.5))
            let s = min(turn.along + offset, path.length - endpointMargin * 0.5)
            guard let pos = path.point(at: s) else { continue }
            let isUTurn = abs(turn.angle) >= 150
            waypoints.append(PlannedWaypoint(coordinate: pos, along: s, angle: turn.angle,
                                             kind: isUTurn ? .uTurn : .turn,
                                             isEnabled: !isUTurn))
        }

        // Titik manual dipertahankan, posisinya diproyeksikan ulang ke path ini.
        for m in manual where m.kind == .manual {
            if let snapped = path.nearest(to: m.coordinate) {
                var copy = m
                copy.coordinate = snapped.point
                copy.along = snapped.along
                waypoints.append(copy)
            }
        }

        waypoints.sort { $0.along < $1.along }
        return NavigationPlan(direction: direction, path: path.coordinates, length: path.length,
                              destination: destination, waypoints: waypoints)
    }

    /// Tambahkan titik manual di posisi terdekat pada path.
    /// Mengembalikan nil jika titik yang diketuk terlalu jauh dari jalur.
    public func manualWaypoint(near c: Coordinate, in plan: NavigationPlan,
                               maxOffset: Double = 120) -> PlannedWaypoint? {
        let path = MeasuredPath(plan.path)
        guard let snapped = path.nearest(to: c), snapped.offset <= maxOffset else { return nil }
        return PlannedWaypoint(coordinate: snapped.point, along: snapped.along, angle: nil,
                               kind: .manual, isEnabled: true)
    }

    /// Pilih titik untuk mode 1 link: manual diutamakan, lalu belokan paling tajam,
    /// dengan jarak antar titik dijaga supaya tersebar sepanjang rute.
    public func selectForSingleLink(_ plan: NavigationPlan) -> [PlannedWaypoint] {
        let enabled = plan.orderedEnabled
        let limit = maxWaypointsPerLink
        if enabled.count <= limit { return enabled }

        let ranked = enabled.sorted { $0.importance > $1.importance }
        let minSpacing = plan.length / Double(limit * 3)
        var chosen: [PlannedWaypoint] = []
        for w in ranked where chosen.count < limit {
            if w.kind == .manual || chosen.allSatisfy({ abs($0.along - w.along) >= minSpacing }) {
                chosen.append(w)
            }
        }
        if chosen.count < limit {
            let ids = Set(chosen.map(\.id))
            for w in ranked where chosen.count < limit && !ids.contains(w.id) {
                chosen.append(w)
            }
        }
        return chosen.sorted { $0.along < $1.along }
    }

    public func links(for plan: NavigationPlan, mode: LinkMode, travelMode: TravelMode,
                      navigate: Bool = false) -> [MapsLink] {
        let points: [Coordinate]
        switch mode {
        case .single: points = selectForSingleLink(plan).map(\.coordinate)
        case .complete: points = plan.orderedEnabled.map(\.coordinate)
        }

        // Rangkaian: titik singgah... + tujuan akhir. Tiap link = maks N titik singgah + 1 tujuan.
        let sequence = points + [plan.destination]
        let chunkSize = maxWaypointsPerLink + 1
        var chunks: [[Coordinate]] = []
        var i = 0
        while i < sequence.count {
            chunks.append(Array(sequence[i..<min(i + chunkSize, sequence.count)]))
            i += chunkSize
        }

        return chunks.enumerated().map { idx, chunk in
            let dest = chunk[chunk.count - 1]
            let wps = Array(chunk.dropLast())
            return MapsLink(
                index: idx, total: chunks.count, waypoints: wps, destination: dest,
                url: GoogleMapsURL.directions(destination: dest, waypoints: wps,
                                              travelMode: travelMode, navigate: navigate),
                appURL: GoogleMapsURL.directions(destination: dest, waypoints: wps,
                                                 travelMode: travelMode, navigate: navigate,
                                                 scheme: .appURL))
        }
    }
}
