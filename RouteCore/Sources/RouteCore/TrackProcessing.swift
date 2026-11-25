import Foundation

/// Membersihkan titik GPS mentah: buang yang akurasinya buruk, yang terlalu rapat,
/// dan lompatan yang mustahil (kecepatan tidak masuk akal).
public struct TrackCleaner: Sendable {
    public var maxAccuracy: Double
    public var minSpacing: Double
    public var maxSpeed: Double

    public init(maxAccuracy: Double = 50, minSpacing: Double = 3, maxSpeed: Double = 70) {
        self.maxAccuracy = maxAccuracy
        self.minSpacing = minSpacing
        self.maxSpeed = maxSpeed
    }

    public func clean(_ points: [TrackPoint]) -> [TrackPoint] {
        var out: [TrackPoint] = []
        out.reserveCapacity(points.count)
        for p in points {
            if p.horizontalAccuracy < 0 || p.horizontalAccuracy > maxAccuracy { continue }
            guard let last = out.last else { out.append(p); continue }
            let d = Geo.distance(last.coordinate, p.coordinate)
            if d < minSpacing { continue }
            let dt = p.timestamp.timeIntervalSince(last.timestamp)
            if dt > 0, d / dt > maxSpeed { continue }
            out.append(p)
        }
        return out
    }
}

/// Penyederhanaan Douglas–Peucker (iteratif, aman untuk rute sangat panjang).
public enum Simplifier {
    /// Mengembalikan indeks titik yang dipertahankan (selalu termasuk awal & akhir).
    public static func simplify(_ coords: [Coordinate], tolerance: Double) -> [Int] {
        let n = coords.count
        guard n > 2 else { return Array(0..<n) }
        let proj = LocalProjection(origin: coords[0])
        let xy = coords.map { proj.project($0) }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true
        keep[n - 1] = true
        var stack: [(Int, Int)] = [(0, n - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            let a = xy[s], b = xy[e]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var maxD = -1.0
            var idx = s
            for i in (s + 1)..<e {
                let p = xy[i]
                let d: Double
                if len2 == 0 {
                    d = ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot()
                } else {
                    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
                    t = max(0, min(1, t))
                    let qx = a.x + t * dx - p.x, qy = a.y + t * dy - p.y
                    d = (qx * qx + qy * qy).squareRoot()
                }
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return (0..<n).filter { keep[$0] }
    }
}

/// Satu belokan yang terdeteksi pada path.
public struct DetectedTurn: Hashable, Sendable {
    /// Posisi belokan (titik sudut).
    public var coordinate: Coordinate
    /// Jarak tempuh dari awal path ke belokan.
    public var along: Double
    /// Sudut belok bertanda (+ kanan, − kiri), derajat.
    public var angle: Double
}

public struct TurnDetector: Sendable {
    /// Sudut minimum agar dianggap belokan.
    public var threshold: Double
    /// Panjang lengan untuk mengukur arah masuk/keluar (meredam noise GPS).
    public var armLength: Double
    /// Belokan yang berdekatan (mis. tikungan lengkung) digabung jadi satu.
    public var mergeDistance: Double
    /// Toleransi penyederhanaan.
    public var simplifyTolerance: Double

    public init(threshold: Double = 40, armLength: Double = 20,
                mergeDistance: Double = 30, simplifyTolerance: Double = 6) {
        self.threshold = threshold
        self.armLength = armLength
        self.mergeDistance = mergeDistance
        self.simplifyTolerance = simplifyTolerance
    }

    public func detect(in path: MeasuredPath) -> [DetectedTurn] {
        let coords = path.coordinates
        guard coords.count >= 3, path.length > armLength * 2 else { return [] }
        let kept = Simplifier.simplify(coords, tolerance: simplifyTolerance)
        guard kept.count >= 3 else { return [] }

        // Kandidat: tiap titik sudut hasil penyederhanaan.
        struct Candidate { var index: Int; var along: Double; var angle: Double }
        var candidates: [Candidate] = []
        for k in 1..<(kept.count - 1) {
            let i = kept[k]
            let s = path.cumulative[i]
            if s < armLength || s > path.length - armLength { continue }
            guard let before = path.point(at: s - armLength),
                  let after = path.point(at: s + armLength) else { continue }
            let v = coords[i]
            let angle = Geo.turnAngle(from: Geo.bearing(before, v), to: Geo.bearing(v, after))
            if abs(angle) >= threshold * 0.6 { // ambang longgar, disaring setelah digabung
                candidates.append(Candidate(index: i, along: s, angle: angle))
            }
        }

        // Gabungkan kandidat berdekatan dengan arah belok yang sama.
        var clusters: [[Candidate]] = []
        for c in candidates {
            if var last = clusters.last, let tail = last.last,
               c.along - tail.along <= mergeDistance, (c.angle > 0) == (tail.angle > 0) {
                last.append(c)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([c])
            }
        }

        var turns: [DetectedTurn] = []
        for cluster in clusters {
            guard let first = cluster.first, let last = cluster.last,
                  let peak = cluster.max(by: { abs($0.angle) < abs($1.angle) }) else { continue }
            let angle: Double
            if cluster.count == 1 {
                angle = first.angle
            } else {
                let s0 = max(0, first.along - armLength)
                let s1 = min(path.length, last.along + armLength)
                guard let a = path.point(at: s0), let b = path.point(at: first.along),
                      let c = path.point(at: last.along), let d = path.point(at: s1) else { continue }
                let inBearing = Geo.bearing(a, b)
                let outBearing = Geo.bearing(c, d)
                angle = Geo.turnAngle(from: inBearing, to: outBearing)
            }
            if abs(angle) >= threshold {
                turns.append(DetectedTurn(coordinate: coords[peak.index], along: peak.along, angle: angle))
            }
        }
        return turns
    }
}
