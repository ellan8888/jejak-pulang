import Foundation

/// Titik koordinat sederhana (derajat WGS84). Sengaja tidak bergantung pada CoreLocation
/// supaya logika rute bisa dites di mana saja.
public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Geo {
    public static let earthRadius: Double = 6_371_008.8

    @inline(__always) static func rad(_ d: Double) -> Double { d * .pi / 180 }
    @inline(__always) static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Jarak great-circle (haversine) dalam meter.
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let dLat = rad(b.latitude - a.latitude)
        let dLon = rad(b.longitude - a.longitude)
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(a.latitude)) * cos(rad(b.latitude)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Arah dari a ke b dalam derajat, 0 = utara, 90 = timur, rentang [0, 360).
    public static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        let p1 = rad(a.latitude), p2 = rad(b.latitude)
        let dl = rad(b.longitude - a.longitude)
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let t = deg(atan2(y, x))
        let r = (t + 360).truncatingRemainder(dividingBy: 360)
        return r
    }

    /// Selisih arah bertanda dalam (-180, 180]. Positif = belok kanan, negatif = belok kiri.
    public static func turnAngle(from b1: Double, to b2: Double) -> Double {
        var d = (b2 - b1).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Interpolasi linear (cukup akurat untuk ruas pendek).
    public static func interpolate(_ a: Coordinate, _ b: Coordinate, _ t: Double) -> Coordinate {
        Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                   longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Geser koordinat sejauh `meters` ke arah `bearingDegrees` (dipakai untuk tes & utilitas).
    public static func offset(_ c: Coordinate, meters: Double, bearingDegrees: Double) -> Coordinate {
        let d = meters / earthRadius
        let b = rad(bearingDegrees)
        let p1 = rad(c.latitude), l1 = rad(c.longitude)
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(b))
        let l2 = l1 + atan2(sin(b) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        return Coordinate(latitude: deg(p2), longitude: deg(l2))
    }
}

/// Proyeksi lokal equirectangular ke meter (x ke timur, y ke utara) di sekitar titik acuan.
struct LocalProjection {
    let lat0: Double
    let lon0: Double
    let cosLat0: Double

    init(origin: Coordinate) {
        lat0 = origin.latitude
        lon0 = origin.longitude
        cosLat0 = cos(Geo.rad(origin.latitude))
    }

    func project(_ c: Coordinate) -> (x: Double, y: Double) {
        (Geo.rad(c.longitude - lon0) * Geo.earthRadius * cosLat0,
         Geo.rad(c.latitude - lat0) * Geo.earthRadius)
    }
}

/// Polyline dengan jarak kumulatif, untuk mencari titik berdasarkan jarak tempuh.
public struct MeasuredPath: Sendable {
    public let coordinates: [Coordinate]
    /// cumulative[i] = jarak dari titik 0 ke titik i (meter).
    public let cumulative: [Double]

    public init(_ coordinates: [Coordinate]) {
        self.coordinates = coordinates
        var acc: [Double] = []
        acc.reserveCapacity(coordinates.count)
        var total = 0.0
        for (i, c) in coordinates.enumerated() {
            if i > 0 { total += Geo.distance(coordinates[i - 1], c) }
            acc.append(total)
        }
        cumulative = acc
    }

    public var length: Double { cumulative.last ?? 0 }
    public var isEmpty: Bool { coordinates.isEmpty }

    /// Titik pada jarak `s` meter dari awal (dibatasi ke [0, length]).
    public func point(at s: Double) -> Coordinate? {
        guard let first = coordinates.first else { return nil }
        if coordinates.count == 1 || s <= 0 { return first }
        if s >= length { return coordinates[coordinates.count - 1] }
        // binary search ruas
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= s { lo = mid } else { hi = mid }
        }
        let segLen = cumulative[hi] - cumulative[lo]
        let t = segLen > 0 ? (s - cumulative[lo]) / segLen : 0
        return Geo.interpolate(coordinates[lo], coordinates[hi], t)
    }

    /// Proyeksikan koordinat ke titik terdekat pada path. Mengembalikan titik tersebut,
    /// jarak tempuhnya, dan jarak tegak lurusnya dari path.
    public func nearest(to c: Coordinate) -> (point: Coordinate, along: Double, offset: Double)? {
        nearest(to: c, alongRange: nil)
    }

    /// Indeks ruas yang memuat jarak tempuh `s`.
    func segmentIndex(at s: Double) -> Int {
        guard cumulative.count > 1 else { return 0 }
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= s { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Seperti `nearest(to:)`, tapi hanya mencari di ruas yang beririsan dengan `alongRange`.
    public func nearest(to c: Coordinate, alongRange: ClosedRange<Double>?)
        -> (point: Coordinate, along: Double, offset: Double)? {
        guard !coordinates.isEmpty else { return nil }
        if coordinates.count == 1 {
            return (coordinates[0], 0, Geo.distance(coordinates[0], c))
        }
        var first = 0, last = coordinates.count - 2
        if let r = alongRange {
            first = segmentIndex(at: max(0, r.lowerBound))
            last = min(coordinates.count - 2, segmentIndex(at: min(length, r.upperBound)))
            if last < first { last = first }
        }
        let proj = LocalProjection(origin: c)
        var best: (point: Coordinate, along: Double, offset: Double)?
        for i in first...last {
            let a = proj.project(coordinates[i])
            let b = proj.project(coordinates[i + 1])
            // c berada di (0,0) dalam proyeksi ini
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? (-(a.x) * dx + -(a.y) * dy) / len2 : 0
            t = max(0, min(1, t))
            let px = a.x + t * dx, py = a.y + t * dy
            let off = (px * px + py * py).squareRoot()
            if best == nil || off < best!.offset {
                let along = cumulative[i] + t * (cumulative[i + 1] - cumulative[i])
                best = (Geo.interpolate(coordinates[i], coordinates[i + 1], t), along, off)
            }
        }
        return best
    }
}
