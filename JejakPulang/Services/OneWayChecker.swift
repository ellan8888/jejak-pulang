import MapKit
import RouteCore

/// Mengecek tiap potongan rute ke Apple Maps (MKDirections). Potongan yang rutenya jauh
/// lebih panjang dari rekaman kemungkinan jalan satu arah / tak bisa dilewati ke arah ini,
/// lalu disiapkan jalan memutarnya.
@MainActor
final class OneWayChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking(done: Int, total: Int)
        case finished
        case failed(String)
        case skipped(String)
    }

    struct Segment: Identifiable, Hashable {
        let id: Int
        let range: ClosedRange<Double>
        let recordedLength: Double
        var routedLength: Double?
        var flagged: Bool
        var detour: [Coordinate]
        var useDetour: Bool
        let midpoint: Coordinate
    }

    @Published private(set) var status: Status = .idle
    @Published var segments: [Segment] = []

    private var task: Task<Void, Never>?
    /// Kunci path yang terakhir dicek, supaya tidak mengulang tanpa perlu.
    private var checkedKey: String?

    var flagged: [Segment] { segments.filter(\.flagged) }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func run(path: MeasuredPath, travelMode: TravelMode) {
        guard travelMode != .walking else {
            cancel()
            segments = []
            checkedKey = nil
            status = .skipped("Pejalan kaki boleh lewat dua arah, jadi tidak perlu dicek.")
            return
        }
        let key = "\(path.coordinates.count)-\(Int(path.length))-\(travelMode.rawValue)"
        if key == checkedKey, status == .finished { return }
        cancel()
        checkedKey = key
        segments = []
        let turns = TurnDetector(threshold: 35).detect(in: path).map(\.along)
        let ranges = OneWaySegmenter.segments(path: path, turnAlongs: turns)
        status = .checking(done: 0, total: ranges.count)

        task = Task { [weak self] in
            var results: [Segment] = []
            var failures = 0
            for (i, r) in ranges.enumerated() {
                if Task.isCancelled { return }
                let res = await Self.check(path: path, range: r, index: i)
                if res == nil { failures += 1 }
                results.append(res ?? Self.unchecked(path: path, range: r, index: i))
                await MainActor.run { self?.status = .checking(done: i + 1, total: ranges.count) }
                try? await Task.sleep(nanoseconds: 350_000_000) // jangan membanjiri Apple Maps
            }
            await MainActor.run {
                guard let self else { return }
                self.segments = results
                if failures == ranges.count && !ranges.isEmpty {
                    self.status = .failed("Tidak bisa menghubungi Apple Maps (cek internet). Navigasi tetap bisa, tanpa cek satu arah.")
                } else {
                    self.status = .finished
                }
            }
        }
    }

    /// Path final untuk navigasi: path asli dengan potongan bermasalah diganti jalan memutar.
    func composedPath(from path: MeasuredPath) -> (path: MeasuredPath, detours: [ClosedRange<Double>]) {
        let reps = segments.filter { $0.flagged && $0.useDetour && $0.detour.count >= 2 }.map {
            PathReplacement(startAlong: $0.range.lowerBound, endAlong: $0.range.upperBound, coordinates: $0.detour)
        }
        let r = PathComposer.splice(path, replacements: reps)
        return (r.path, r.replaced)
    }

    // MARK: - MKDirections

    private static func unchecked(path: MeasuredPath, range: ClosedRange<Double>, index: Int) -> Segment {
        Segment(id: index, range: range, recordedLength: range.upperBound - range.lowerBound,
                routedLength: nil, flagged: false, detour: [], useDetour: false,
                midpoint: path.point(at: (range.lowerBound + range.upperBound) / 2) ?? path.coordinates[0])
    }

    private static func check(path: MeasuredPath, range: ClosedRange<Double>, index: Int) async -> Segment? {
        let len = range.upperBound - range.lowerBound
        // sedikit masuk dari ujung supaya tidak jatuh tepat di persimpangan
        let inset = len > 80 ? 15.0 : 0
        guard let a = path.point(at: range.lowerBound + inset),
              let b = path.point(at: range.upperBound - inset) else { return nil }

        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: a.cl))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.cl))
        req.transportType = .automobile
        req.requestsAlternateRoutes = false

        var response: MKDirections.Response?
        for attempt in 0..<2 {
            do {
                response = try await MKDirections(request: req).calculate()
                break
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                return nil
            }
        }
        guard let route = response?.routes.first else { return nil }

        let n = route.polyline.pointCount
        var pts = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
        route.polyline.getCoordinates(&pts, range: NSRange(location: 0, length: n))
        let detour = pts.map(\.coordinate)

        var seg = unchecked(path: path, range: range, index: index)
        seg.routedLength = route.distance

        // Jalan rekaman tidak ada di Apple Maps (gang kecil): Apple menyambung ke jalan lain
        // yang jauh. Jangan ditandai — tidak bisa dinilai.
        if let f = detour.first, let l = detour.last,
           Geo.distance(f, a) > 40 || Geo.distance(l, b) > 40 {
            return seg
        }

        let recorded = len - inset * 2
        if OneWaySegmenter.isSuspicious(recorded: recorded, routed: route.distance) {
            seg.flagged = true
            seg.detour = detour
            seg.useDetour = true
        }
        return seg
    }
}
