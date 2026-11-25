import Foundation

// MARK: - Manuver

/// Satu instruksi navigasi di sepanjang path.
public struct Maneuver: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case turn, uTurn, arrive
    }

    public var id: Int
    public var along: Double
    public var coordinate: Coordinate
    /// Sudut belok bertanda (+ kanan, − kiri). 0 untuk `.arrive`.
    public var angle: Double
    public var kind: Kind
    /// Berada di bagian jalan memutar (pengganti jalan satu arah).
    public var inDetour: Bool

    public init(id: Int, along: Double, coordinate: Coordinate, angle: Double, kind: Kind, inDetour: Bool = false) {
        self.id = id
        self.along = along
        self.coordinate = coordinate
        self.angle = angle
        self.kind = kind
        self.inDetour = inDetour
    }
}

public enum ManeuverBuilder {
    public static func build(path: MeasuredPath, detours: [ClosedRange<Double>] = [],
                             threshold: Double = 35) -> [Maneuver] {
        let turns = TurnDetector(threshold: threshold).detect(in: path)
        var out: [Maneuver] = []
        for t in turns {
            out.append(Maneuver(id: out.count, along: t.along, coordinate: t.coordinate, angle: t.angle,
                                kind: abs(t.angle) >= 150 ? .uTurn : .turn,
                                inDetour: detours.contains { $0.contains(t.along) }))
        }
        if let end = path.coordinates.last {
            out.append(Maneuver(id: out.count, along: path.length, coordinate: end, angle: 0, kind: .arrive))
        }
        return out
    }
}

// MARK: - Kalimat panduan (bahasa Indonesia)

public enum Phrases {
    public static let start = "Navigasi jejak dimulai. Ikuti garis biru."
    public static let offRoute = "Kamu keluar dari rute. Kembali ke garis biru."
    public static let backOnRoute = "Kembali di rute."
    public static let detourAhead = "Bagian depan kemungkinan jalan satu arah. Ikuti jalan memutar warna ungu."
    public static let detourEnd = "Jalan memutar selesai. Lanjut di jalur rekaman."
    public static let arrived = "Kamu sudah sampai di tujuan."

    /// Frasa aksi tanpa jarak, huruf kecil di depan. Contoh: "belok kiri".
    public static func action(_ m: Maneuver) -> String {
        switch m.kind {
        case .arrive: return "sampai di tujuan"
        case .uTurn: return "putar balik"
        case .turn:
            let side = m.angle > 0 ? "kanan" : "kiri"
            let a = abs(m.angle)
            if a < 50 { return "ambil sedikit ke \(side)" }
            if a >= 120 { return "belok tajam ke \(side)" }
            return "belok \(side)"
        }
    }

    /// Label pendek untuk banner. Contoh: "Belok kiri".
    public static func label(_ m: Maneuver) -> String { capitalizeFirst(action(m)) }

    public static func spokenDistance(_ meters: Double) -> String {
        if meters < 950 {
            let r = meters < 100 ? (meters / 10).rounded() * 10 : (meters / 50).rounded() * 50
            return "\(Int(max(10, r))) meter"
        }
        let km = (meters / 100).rounded() / 10
        if km == km.rounded() { return "\(Int(km)) kilometer" }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), km)
            .replacingOccurrences(of: ".", with: ",") + " kilometer"
    }

    public static func ahead(_ m: Maneuver, distance: Double) -> String {
        if m.kind == .arrive { return "Dalam \(spokenDistance(distance)), kamu sampai di tujuan." }
        return "Dalam \(spokenDistance(distance)), \(action(m))."
    }

    public static func now(_ m: Maneuver, then next: Maneuver? = nil) -> String {
        var s = label(m) + " sekarang"
        if let next, next.kind != .arrive { s += ", lalu " + action(next) }
        return s + "."
    }

    /// Arah mata angin 8 penjuru.
    public static func compass(_ bearing: Double) -> String {
        let names = ["utara", "timur laut", "timur", "tenggara", "selatan", "barat daya", "barat", "barat laut"]
        let b = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((b + 22.5) / 45) % 8]
    }

    static func capitalizeFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}

// MARK: - Navigator

public struct NavigatorConfig: Sendable {
    public var offRouteDistance: Double = 40
    public var backOnRouteDistance: Double = 25
    public var arriveDistance: Double = 25
    public var searchBehind: Double = 60
    public var searchAhead: Double = 400
    public var detourWarnDistance: Double = 250
    public init() {}
}

public struct NavigationUpdate: Sendable {
    public var along: Double
    public var snapped: Coordinate
    public var offset: Double
    public var isOffRoute: Bool
    public var nextManeuver: Maneuver?
    public var distanceToNext: Double?
    public var remaining: Double
    public var arrived: Bool
    public var inDetour: Bool
    /// Kalimat yang perlu diucapkan sekarang (urut).
    public var announcements: [String]
}

/// Mesin navigasi mengikuti satu path tetap. Diberi posisi GPS berulang kali,
/// mengembalikan status dan kalimat panduan. Tidak bergantung pada CoreLocation.
public final class TrackNavigator {
    public let path: MeasuredPath
    public let maneuvers: [Maneuver]
    public let detours: [ClosedRange<Double>]
    public var config: NavigatorConfig

    public private(set) var along: Double = 0
    public private(set) var isOffRoute = false
    public private(set) var hasArrived = false
    private var initialized = false
    private var spoken = Set<String>()

    public init(path: MeasuredPath, maneuvers: [Maneuver], detours: [ClosedRange<Double>] = [],
                config: NavigatorConfig = NavigatorConfig()) {
        self.path = path
        self.maneuvers = maneuvers.sorted { $0.along < $1.along }
        self.detours = detours
        self.config = config
    }

    public func update(position: Coordinate, accuracy: Double = 10, speed: Double? = nil) -> NavigationUpdate? {
        var ann: [String] = []
        let snap: (point: Coordinate, along: Double, offset: Double)

        if !initialized {
            guard let g = path.nearest(to: position) else { return nil }
            snap = g
            initialized = true
            ann.append(Phrases.start)
        } else {
            let lo = max(0, along - config.searchBehind)
            let hi = min(path.length, along + config.searchAhead)
            guard var s = path.nearest(to: position, alongRange: lo...hi) ?? path.nearest(to: position) else { return nil }
            // Bergabung lagi di tempat lain (mis. potong jalan): pakai hasil global bila jauh lebih dekat.
            if s.offset > config.offRouteDistance, let g = path.nearest(to: position), g.offset + 15 < s.offset {
                s = g
            }
            snap = s
        }
        along = snap.along

        let threshold = config.offRouteDistance + min(max(accuracy, 0), 30) * 0.5
        if !isOffRoute && snap.offset > threshold {
            isOffRoute = true
            ann.append(Phrases.offRoute)
        } else if isOffRoute && snap.offset < config.backOnRouteDistance {
            isOffRoute = false
            ann.append(Phrases.backOnRoute)
        }

        let remaining = max(0, path.length - along)
        let next = maneuvers.first { $0.along > along + 3 }
        let dNext = next.map { $0.along - along }

        if !isOffRoute, !hasArrived, let m = next, let d = dNext {
            let v = max(speed ?? 0, 0)
            let far = min(max(v * 15, 120), 300)
            let near = min(max(v * 5, 25), 70)
            if m.kind == .arrive {
                if d <= far, d > config.arriveDistance * 2, spoken.insert("far-\(m.id)").inserted {
                    ann.append(Phrases.ahead(m, distance: d))
                }
            } else if d <= near {
                if spoken.insert("near-\(m.id)").inserted {
                    spoken.insert("far-\(m.id)")
                    let after = maneuvers.first { $0.along > m.along + 3 }
                    let chained = (after.map { $0.along - m.along <= 60 } ?? false) ? after : nil
                    ann.append(Phrases.now(m, then: chained))
                }
            } else if d <= far, d > near * 1.5, spoken.insert("far-\(m.id)").inserted {
                ann.append(Phrases.ahead(m, distance: d))
            }
        }

        for (k, r) in detours.enumerated() {
            let ahead = r.lowerBound - along
            if !isOffRoute, ahead > 0, ahead <= config.detourWarnDistance,
               spoken.insert("detour-\(k)").inserted {
                ann.append(Phrases.detourAhead)
            }
            if along > r.upperBound + 10, along - r.upperBound < 150,
               spoken.contains("detour-\(k)"), spoken.insert("detour-end-\(k)").inserted {
                ann.append(Phrases.detourEnd)
            }
        }

        if remaining <= config.arriveDistance, !hasArrived {
            hasArrived = true
            ann.append(Phrases.arrived)
        }

        return NavigationUpdate(
            along: along, snapped: snap.point, offset: snap.offset, isOffRoute: isOffRoute,
            nextManeuver: next, distanceToNext: dNext, remaining: remaining, arrived: hasArrived,
            inDetour: detours.contains { $0.contains(along) }, announcements: ann)
    }
}

// MARK: - Menyusun path (jalan memutar, buang putar-balik)

public struct PathReplacement: Hashable, Sendable {
    public var startAlong: Double
    public var endAlong: Double
    /// Koordinat pengganti. Kosong = bagian itu dibuang saja.
    public var coordinates: [Coordinate]

    public init(startAlong: Double, endAlong: Double, coordinates: [Coordinate]) {
        self.startAlong = startAlong
        self.endAlong = endAlong
        self.coordinates = coordinates
    }
}

public enum PathComposer {
    /// Ganti rentang-rentang path dengan koordinat lain. Mengembalikan path baru
    /// dan rentang (pada path baru) yang berasal dari pengganti tak-kosong.
    public static func splice(_ path: MeasuredPath, replacements: [PathReplacement])
        -> (path: MeasuredPath, replaced: [ClosedRange<Double>]) {
        let coords = path.coordinates
        guard coords.count >= 2 else { return (path, []) }
        // urutkan & buang yang tumpang tindih / tidak valid
        var reps: [PathReplacement] = []
        for r in replacements.sorted(by: { $0.startAlong < $1.startAlong }) {
            guard r.endAlong > r.startAlong, r.startAlong >= 0, r.endAlong <= path.length + 1e-6 else { continue }
            if let last = reps.last, r.startAlong < last.endAlong { continue }
            reps.append(r)
        }
        guard !reps.isEmpty else { return (path, []) }

        var out: [Coordinate] = []
        var marks: [(start: Int, end: Int)] = []
        var i = 0
        func appendDistinct(_ c: Coordinate) {
            if let l = out.last, Geo.distance(l, c) < 0.5 { return }
            out.append(c)
        }
        for r in reps {
            while i < coords.count && path.cumulative[i] < r.startAlong {
                appendDistinct(coords[i]); i += 1
            }
            if let p = path.point(at: r.startAlong) { appendDistinct(p) }
            let startIdx = max(0, out.count - 1)
            for c in r.coordinates { appendDistinct(c) }
            if let p = path.point(at: r.endAlong) { appendDistinct(p) }
            let endIdx = max(0, out.count - 1)
            if !r.coordinates.isEmpty { marks.append((startIdx, endIdx)) }
            while i < coords.count && path.cumulative[i] <= r.endAlong { i += 1 }
        }
        while i < coords.count { appendDistinct(coords[i]); i += 1 }

        let newPath = MeasuredPath(out)
        let ranges = marks.map { newPath.cumulative[$0.start]...newPath.cumulative[$0.end] }
        return (newPath, ranges)
    }

    /// Cari bagian "bolak-balik" (putar balik karena salah jalan) dan kembalikan
    /// rentang yang bisa dibuang supaya navigasi tidak menyuruh putar balik.
    public static func backtrackSpurs(in path: MeasuredPath, tolerance: Double = 25,
                                      step: Double = 10, maxReach: Double = 2_000) -> [PathReplacement] {
        let turns = TurnDetector(threshold: 40).detect(in: path).filter { abs($0.angle) >= 150 }
        var out: [PathReplacement] = []
        for t in turns {
            var reach = 0.0
            var x = step
            while x <= maxReach, t.along - x >= 0, t.along + x <= path.length {
                guard let a = path.point(at: t.along - x), let b = path.point(at: t.along + x) else { break }
                if Geo.distance(a, b) > tolerance { break }
                reach = x
                x += step
            }
            if reach >= step * 2 {
                out.append(PathReplacement(startAlong: t.along - reach, endAlong: t.along + reach, coordinates: []))
            }
        }
        return out
    }
}

// MARK: - Pengecekan jalan satu arah (bagian murni)

public enum OneWaySegmenter {
    /// Bagi path jadi potongan per ruas jalan (di antara belokan) untuk dicek ke layanan rute.
    public static func segments(path: MeasuredPath, turnAlongs: [Double], maxLength: Double = 600,
                                minLength: Double = 60, maxCount: Int = 40) -> [ClosedRange<Double>] {
        let L = path.length
        guard L > minLength else { return L > 0 ? [0...L] : [] }
        var bounds = [0.0] + turnAlongs.filter { $0 > 0 && $0 < L }.sorted() + [L]
        // pecah ruas yang terlalu panjang
        var expanded: [Double] = [bounds[0]]
        for k in 1..<bounds.count {
            let a = bounds[k - 1], b = bounds[k]
            let n = Int(((b - a) / maxLength).rounded(.up))
            if n > 1 {
                for j in 1..<n { expanded.append(a + (b - a) * Double(j) / Double(n)) }
            }
            expanded.append(b)
        }
        bounds = expanded
        var segs: [ClosedRange<Double>] = []
        for k in 1..<bounds.count where bounds[k] > bounds[k - 1] {
            segs.append(bounds[k - 1]...bounds[k])
        }
        // gabungkan yang terlalu pendek ke tetangganya
        var merged: [ClosedRange<Double>] = []
        for s in segs {
            if let last = merged.last, (s.upperBound - s.lowerBound) < minLength || (last.upperBound - last.lowerBound) < minLength {
                merged[merged.count - 1] = last.lowerBound...s.upperBound
            } else {
                merged.append(s)
            }
        }
        // batasi jumlah: gabungkan pasangan bersebelahan terpendek
        while merged.count > max(1, maxCount) {
            var best = 0
            var bestLen = Double.infinity
            for k in 0..<(merged.count - 1) {
                let len = merged[k + 1].upperBound - merged[k].lowerBound
                if len < bestLen { bestLen = len; best = k }
            }
            merged[best] = merged[best].lowerBound...merged[best + 1].upperBound
            merged.remove(at: best + 1)
        }
        return merged
    }

    /// Rute layanan peta jauh lebih panjang dari rekaman → kemungkinan tidak bisa dilewati ke arah ini.
    public static func isSuspicious(recorded: Double, routed: Double) -> Bool {
        routed > recorded * 1.6 + 200
    }
}
