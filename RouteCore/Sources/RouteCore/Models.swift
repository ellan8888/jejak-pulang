import Foundation

/// Satu titik hasil rekaman GPS.
public struct TrackPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var timestamp: Date
    /// Akurasi horizontal dalam meter. 0 = tidak diketahui (mis. hasil impor GPX).
    public var horizontalAccuracy: Double
    public var speed: Double?

    public init(latitude: Double, longitude: Double, timestamp: Date,
                horizontalAccuracy: Double = 0, speed: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

/// Rute tersimpan. `schemaVersion` disiapkan supaya format file bisa berkembang tanpa
/// merusak rute lama.
public struct SavedRoute: Codable, Identifiable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var points: [TrackPoint]
    public var note: String?

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(),
                points: [TrackPoint], note: String? = nil) {
        self.schemaVersion = SavedRoute.currentSchemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.points = points
        self.note = note
    }

    public var coordinates: [Coordinate] { points.map(\.coordinate) }
    public var start: Coordinate? { points.first?.coordinate }
    public var end: Coordinate? { points.last?.coordinate }

    public var distanceMeters: Double { MeasuredPath(coordinates).length }

    /// Durasi rekaman (nil bila waktu tidak tersedia, mis. GPX tanpa timestamp).
    public var duration: TimeInterval? {
        guard let f = points.first?.timestamp, let l = points.last?.timestamp,
              f != .distantPast, l > f else { return nil }
        return l.timeIntervalSince(f)
    }

    /// Celah rekaman: ruas yang lompat jauh (sinyal hilang / rekaman terhenti).
    public func gaps(minDistance: Double = 150, minSeconds: TimeInterval = 45) -> [Gap] {
        guard points.count > 1 else { return [] }
        var out: [Gap] = []
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let d = Geo.distance(a.coordinate, b.coordinate)
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            if d >= minDistance && (dt >= minSeconds || a.timestamp == .distantPast) {
                out.append(Gap(from: a.coordinate, to: b.coordinate, meters: d, seconds: max(0, dt)))
            }
        }
        return out
    }

    public struct Gap: Hashable, Sendable {
        public var from: Coordinate
        public var to: Coordinate
        public var meters: Double
        public var seconds: TimeInterval
    }
}

/// Rekaman yang sedang berjalan, disimpan berkala supaya tidak hilang kalau aplikasi tertutup.
public struct InProgressRecording: Codable, Hashable, Sendable {
    public var startedAt: Date
    public var points: [TrackPoint]

    public init(startedAt: Date, points: [TrackPoint]) {
        self.startedAt = startedAt
        self.points = points
    }
}
