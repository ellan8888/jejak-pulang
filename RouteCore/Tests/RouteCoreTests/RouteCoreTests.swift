import XCTest
@testable import RouteCore

/// Bangun jejak sintetis: daftar (arah, jarak) dari titik awal, titik tiap `step` meter.
func makeTrack(start: Coordinate = Coordinate(latitude: 3.5952, longitude: 98.6722),
               legs: [(bearing: Double, meters: Double)], step: Double = 5,
               startTime: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> [TrackPoint] {
    var pts: [TrackPoint] = [TrackPoint(latitude: start.latitude, longitude: start.longitude,
                                        timestamp: startTime, horizontalAccuracy: 5)]
    var cur = start
    var t = startTime
    for leg in legs {
        var done = 0.0
        while done < leg.meters - 1e-6 {
            let d = min(step, leg.meters - done)
            cur = Geo.offset(cur, meters: d, bearingDegrees: leg.bearing)
            t = t.addingTimeInterval(d / 8) // ~8 m/s
            pts.append(TrackPoint(latitude: cur.latitude, longitude: cur.longitude,
                                  timestamp: t, horizontalAccuracy: 5))
            done += d
        }
    }
    return pts
}

final class GeoTests: XCTestCase {
    func testDistanceAndBearing() {
        let a = Coordinate(latitude: 3.6, longitude: 98.67)
        let b = Geo.offset(a, meters: 1000, bearingDegrees: 90)
        XCTAssertEqual(Geo.distance(a, b), 1000, accuracy: 0.5)
        XCTAssertEqual(Geo.bearing(a, b), 90, accuracy: 0.1)
        XCTAssertEqual(Geo.turnAngle(from: 90, to: 0), -90, accuracy: 1e-9)
        XCTAssertEqual(Geo.turnAngle(from: 350, to: 10), 20, accuracy: 1e-9)
    }

    func testMeasuredPathPointAndNearest() {
        let pts = makeTrack(legs: [(90, 200), (0, 100)]).map(\.coordinate)
        let path = MeasuredPath(pts)
        XCTAssertEqual(path.length, 300, accuracy: 1)
        let mid = path.point(at: 100)!
        XCTAssertEqual(Geo.distance(pts[0], mid), 100, accuracy: 1)
        let off = Geo.offset(mid, meters: 20, bearingDegrees: 0)
        let n = path.nearest(to: off)!
        XCTAssertEqual(n.along, 100, accuracy: 1.5)
        XCTAssertEqual(n.offset, 20, accuracy: 1.5)
    }
}

final class ProcessingTests: XCTestCase {
    func testCleanerDropsBadPoints() {
        var pts = makeTrack(legs: [(90, 100)])
        var bad = pts[5]; bad.horizontalAccuracy = 200
        pts.insert(bad, at: 6)
        var jump = pts[10]; jump.latitude += 0.05 // ~5 km dalam < 1 detik
        jump.timestamp = pts[10].timestamp.addingTimeInterval(0.1)
        pts.insert(jump, at: 11)
        let cleaned = TrackCleaner().clean(pts)
        XCTAssertFalse(cleaned.contains(bad))
        XCTAssertFalse(cleaned.contains(jump))
    }

    func testSimplifierKeepsCorner() {
        let coords = makeTrack(legs: [(90, 300), (0, 300)]).map(\.coordinate)
        let kept = Simplifier.simplify(coords, tolerance: 5)
        XCTAssertEqual(kept.count, 3)
    }

    func testTurnDetectionLShape() {
        let path = MeasuredPath(makeTrack(legs: [(90, 300), (0, 300)]).map(\.coordinate))
        let turns = TurnDetector().detect(in: path)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].angle, -90, accuracy: 5)  // timur -> utara = kiri
        XCTAssertEqual(turns[0].along, 300, accuracy: 10)
    }

    func testCurvedCornerMergedIntoOneTurn() {
        // tikungan lengkung 90° dipecah jadi 3 x 30°
        let path = MeasuredPath(makeTrack(legs: [(90, 300), (120, 10), (150, 10), (180, 300)]).map(\.coordinate))
        let turns = TurnDetector().detect(in: path)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].angle, 90, accuracy: 12)
    }

    func testStraightRoadHasNoTurns() {
        let path = MeasuredPath(makeTrack(legs: [(45, 1500)]).map(\.coordinate))
        XCTAssertTrue(TurnDetector().detect(in: path).isEmpty)
    }
}

final class PlannerTests: XCTestCase {
    func zigzagRoute(turns: Int) -> SavedRoute {
        var legs: [(bearing: Double, meters: Double)] = []
        for i in 0...turns { legs.append((i % 2 == 0 ? 90 : 0, 150)) }
        return SavedRoute(name: "Zigzag", points: makeTrack(legs: legs))
    }

    func testReturnPlanEndsAtStart() {
        let route = SavedRoute(name: "L", points: makeTrack(legs: [(90, 300), (0, 300)]))
        let plan = RoutePlanner().makePlan(route: route, direction: .returnTrip)!
        XCTAssertEqual(Geo.distance(plan.destination, route.start!), 0, accuracy: 0.5)
        XCTAssertEqual(plan.waypoints.count, 1)
        // Pulang: selatan lalu belok kanan ke barat. Titik singgah ada di ruas barat.
        let w = plan.waypoints[0]
        XCTAssertEqual(w.angle!, 90, accuracy: 5)
        XCTAssertGreaterThan(w.along, 300)
        XCTAssertEqual(Geo.distance(w.coordinate, route.start!), 265, accuracy: 15)
    }

    func testSameDirectionPlanEndsAtEnd() {
        let route = SavedRoute(name: "L", points: makeTrack(legs: [(90, 300), (0, 300)]))
        let plan = RoutePlanner().makePlan(route: route, direction: .sameDirection)!
        XCTAssertEqual(Geo.distance(plan.destination, route.end!), 0, accuracy: 0.5)
    }

    func testCompleteModeSplitsIntoParts() {
        let route = zigzagRoute(turns: 25)
        let planner = RoutePlanner()
        let plan = planner.makePlan(route: route, direction: .returnTrip)!
        XCTAssertEqual(plan.orderedEnabled.count, 25)
        let links = planner.links(for: plan, mode: .complete, travelMode: .driving)
        XCTAssertEqual(links.count, 3) // 25 titik + 1 tujuan = 26 -> 10, 10, 6
        XCTAssertEqual(links[0].waypoints.count, 9)
        XCTAssertEqual(links[2].waypoints.count, 5)
        XCTAssertEqual(links.last!.destination, plan.destination)
        // tujuan bagian 1 = titik ke-10 yang dilewati
        XCTAssertEqual(links[0].destination, plan.orderedEnabled[9].coordinate)
    }

    func testSingleModeLimitsWaypointsAndKeepsOrder() {
        let route = zigzagRoute(turns: 25)
        let planner = RoutePlanner()
        let plan = planner.makePlan(route: route, direction: .returnTrip)!
        let links = planner.links(for: plan, mode: .single, travelMode: .driving)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].waypoints.count, 9)
        let chosen = planner.selectForSingleLink(plan)
        XCTAssertEqual(chosen.map(\.along), chosen.map(\.along).sorted())
    }

    func testManualWaypointKeptAcrossReplan() {
        let route = zigzagRoute(turns: 3)
        let planner = RoutePlanner()
        var plan = planner.makePlan(route: route, direction: .returnTrip)!
        let tap = Geo.offset(MeasuredPath(plan.path).point(at: 75)!, meters: 15, bearingDegrees: 0)
        let manual = planner.manualWaypoint(near: tap, in: plan)!
        plan.waypoints.append(manual)
        let replanned = planner.makePlan(route: route, direction: .returnTrip,
                                         sensitivity: .more, keepingManual: plan.waypoints)!
        XCTAssertTrue(replanned.waypoints.contains { $0.id == manual.id && $0.kind == .manual })
        XCTAssertNil(planner.manualWaypoint(near: Geo.offset(tap, meters: 2000, bearingDegrees: 180), in: plan))
    }

    func testUTurnDisabledByDefault() {
        let route = SavedRoute(name: "U", points: makeTrack(legs: [(90, 300), (270, 150), (0, 300)]))
        let plan = RoutePlanner().makePlan(route: route, direction: .sameDirection)!
        let u = plan.waypoints.filter { $0.kind == .uTurn }
        XCTAssertFalse(u.isEmpty)
        XCTAssertTrue(u.allSatisfy { !$0.isEnabled })
    }
}

final class URLAndGPXTests: XCTestCase {
    func testDirectionsURL() {
        let url = GoogleMapsURL.directions(
            destination: Coordinate(latitude: 3.5, longitude: 98.6),
            waypoints: [Coordinate(latitude: 3.51, longitude: 98.61), Coordinate(latitude: 3.52, longitude: 98.62)],
            travelMode: .driving)
        XCTAssertEqual(url.absoluteString,
                       "https://www.google.com/maps/dir/?api=1&destination=3.500000,98.600000&travelmode=driving&waypoints=3.510000,98.610000%7C3.520000,98.620000")
        let app = GoogleMapsURL.directions(destination: Coordinate(latitude: 3.5, longitude: 98.6),
                                           waypoints: [], travelMode: .walking, scheme: .appURL)
        XCTAssertTrue(app.absoluteString.hasPrefix("comgooglemapsurl://www.google.com/maps/dir/?api=1"))
    }

    func testGPXRoundTrip() throws {
        let route = SavedRoute(name: "Ke <Lokasi> & balik", points: makeTrack(legs: [(90, 50)]))
        let xml = GPX.export(route)
        let parsed = try GPX.parse(Data(xml.utf8))
        XCTAssertEqual(parsed.name, "Ke <Lokasi> & balik")
        XCTAssertEqual(parsed.points.count, route.points.count)
        XCTAssertEqual(parsed.points[3].latitude, route.points[3].latitude, accuracy: 1e-6)
        XCTAssertEqual(parsed.points[3].timestamp.timeIntervalSince1970,
                       route.points[3].timestamp.timeIntervalSince1970, accuracy: 0.01)
    }

    func testGPXWithoutTime() throws {
        let xml = """
        <gpx><trk><trkseg>
        <trkpt lat="3.6" lon="98.6"></trkpt><trkpt lat="3.601" lon="98.6"></trkpt>
        </trkseg></trk></gpx>
        """
        let parsed = try GPX.parse(Data(xml.utf8))
        XCTAssertEqual(parsed.points.count, 2)
        XCTAssertEqual(parsed.points[0].timestamp, .distantPast)
        let cleaned = TrackCleaner().clean(parsed.points)
        XCTAssertEqual(cleaned.count, 2)
    }

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try RouteFileStore(directory: dir)
        let r = SavedRoute(name: "A", points: makeTrack(legs: [(90, 20)]))
        try store.save(r)
        XCTAssertEqual(store.loadAll().first?.id, r.id)
        try store.saveInProgress(InProgressRecording(startedAt: Date(), points: r.points))
        XCTAssertEqual(store.loadInProgress()?.points.count, r.points.count)
        XCTAssertEqual(store.loadAll().count, 1) // file rekaman berjalan tidak ikut terbaca
        store.clearInProgress()
        XCTAssertNil(store.loadInProgress())
        try store.delete(id: r.id)
        XCTAssertTrue(store.loadAll().isEmpty)
    }
}
