import XCTest
@testable import RouteCore

final class NavigationTests: XCTestCase {
    /// Path L: timur 300 m lalu utara 300 m.
    func lPath() -> MeasuredPath {
        MeasuredPath(makeTrack(legs: [(90, 300), (0, 300)]).map(\.coordinate))
    }

    func testWindowedNearestPrefersRange() {
        // Path bolak-balik di garis yang sama: timur 200 lalu barat 200.
        let path = MeasuredPath(makeTrack(legs: [(90, 200), (270, 200)]).map(\.coordinate))
        let probe = path.point(at: 50)!
        let early = path.nearest(to: probe, alongRange: 0...100)!
        let late = path.nearest(to: probe, alongRange: 300...400)!
        XCTAssertEqual(early.along, 50, accuracy: 2)
        XCTAssertEqual(late.along, 350, accuracy: 2)
    }

    func testManeuversIncludeTurnAndArrive() {
        let ms = ManeuverBuilder.build(path: lPath())
        XCTAssertEqual(ms.count, 2)
        XCTAssertEqual(ms[0].kind, .turn)
        XCTAssertEqual(Phrases.label(ms[0]), "Belok kiri")
        XCTAssertEqual(ms[1].kind, .arrive)
        XCTAssertEqual(ms[1].along, 600, accuracy: 1)
    }

    func testPhrases() {
        XCTAssertEqual(Phrases.spokenDistance(47), "50 meter")
        XCTAssertEqual(Phrases.spokenDistance(180), "200 meter")
        XCTAssertEqual(Phrases.spokenDistance(1500), "1,5 kilometer")
        XCTAssertEqual(Phrases.spokenDistance(2000), "2 kilometer")
        XCTAssertEqual(Phrases.compass(10), "utara")
        XCTAssertEqual(Phrases.compass(135), "tenggara")
        XCTAssertEqual(Phrases.compass(-90), "barat")
        let m = Maneuver(id: 0, along: 0, coordinate: Coordinate(latitude: 0, longitude: 0), angle: 95, kind: .turn)
        XCTAssertEqual(Phrases.ahead(m, distance: 150), "Dalam 150 meter, belok kanan.")
        XCTAssertEqual(Phrases.now(m), "Belok kanan sekarang.")
    }

    func testNavigatorDrivesAlongPath() {
        let path = lPath()
        let nav = TrackNavigator(path: path, maneuvers: ManeuverBuilder.build(path: path))
        var spoken: [String] = []
        var s = 0.0
        var last: NavigationUpdate?
        while s <= path.length {
            let u = nav.update(position: path.point(at: s)!, accuracy: 5, speed: 8)!
            spoken += u.announcements
            XCTAssertFalse(u.isOffRoute)
            last = u
            s += 10
        }
        XCTAssertEqual(spoken.first, Phrases.start)
        XCTAssertTrue(spoken.contains { $0.hasPrefix("Dalam") && $0.contains("belok kiri") }, "\(spoken)")
        XCTAssertTrue(spoken.contains("Belok kiri sekarang."), "\(spoken)")
        XCTAssertTrue(spoken.contains(Phrases.arrived))
        XCTAssertTrue(last!.arrived)
        // setiap kalimat belok hanya sekali
        XCTAssertEqual(spoken.filter { $0 == "Belok kiri sekarang." }.count, 1)
    }

    func testNavigatorOffRouteAndBack() {
        let path = lPath()
        let nav = TrackNavigator(path: path, maneuvers: ManeuverBuilder.build(path: path))
        _ = nav.update(position: path.point(at: 0)!)
        _ = nav.update(position: path.point(at: 50)!)
        let off = nav.update(position: Geo.offset(path.point(at: 80)!, meters: 90, bearingDegrees: 180))!
        XCTAssertTrue(off.isOffRoute)
        XCTAssertTrue(off.announcements.contains(Phrases.offRoute))
        let back = nav.update(position: path.point(at: 100)!)!
        XCTAssertFalse(back.isOffRoute)
        XCTAssertTrue(back.announcements.contains(Phrases.backOnRoute))
    }

    func testSpliceDetourAndWarning() {
        let path = MeasuredPath(makeTrack(legs: [(90, 900)]).map(\.coordinate))
        // ganti bagian 300–500 dengan jalan memutar ke utara (kotak)
        let a = path.point(at: 300)!, b = path.point(at: 500)!
        let up1 = Geo.offset(a, meters: 100, bearingDegrees: 0)
        let up2 = Geo.offset(b, meters: 100, bearingDegrees: 0)
        let (newPath, ranges) = PathComposer.splice(path, replacements: [
            PathReplacement(startAlong: 300, endAlong: 500, coordinates: [up1, up2])
        ])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(newPath.length, 1100, accuracy: 3)
        XCTAssertEqual(ranges[0].lowerBound, 300, accuracy: 3)
        XCTAssertEqual(ranges[0].upperBound, 700, accuracy: 3)

        let nav = TrackNavigator(path: newPath, maneuvers: ManeuverBuilder.build(path: newPath, detours: ranges),
                                 detours: ranges)
        var spoken: [String] = []
        var s = 0.0
        while s <= newPath.length {
            spoken += nav.update(position: newPath.point(at: s)!, speed: 8)!.announcements
            s += 10
        }
        XCTAssertTrue(spoken.contains(Phrases.detourAhead), "\(spoken)")
        XCTAssertTrue(spoken.contains(Phrases.detourEnd), "\(spoken)")
    }

    func testBacktrackSpurRemoved() {
        let path = MeasuredPath(makeTrack(legs: [(90, 300), (270, 150), (0, 300)]).map(\.coordinate))
        let spurs = PathComposer.backtrackSpurs(in: path)
        XCTAssertEqual(spurs.count, 1)
        XCTAssertEqual(spurs[0].startAlong, 150, accuracy: 15)
        XCTAssertEqual(spurs[0].endAlong, 450, accuracy: 15)
        let (clean, _) = PathComposer.splice(path, replacements: spurs)
        XCTAssertEqual(clean.length, 450, accuracy: 25)
        XCTAssertTrue(ManeuverBuilder.build(path: clean).allSatisfy { $0.kind != .uTurn })
    }

    func testOneWaySegments() {
        let path = MeasuredPath(makeTrack(legs: [(90, 2000)]).map(\.coordinate))
        let segs = OneWaySegmenter.segments(path: path, turnAlongs: [500, 520, 1500])
        XCTAssertEqual(segs.first!.lowerBound, 0, accuracy: 1e-6)
        XCTAssertEqual(segs.last!.upperBound, path.length, accuracy: 1e-6)
        XCTAssertTrue(segs.allSatisfy { $0.upperBound - $0.lowerBound >= 60 })
        XCTAssertTrue(segs.allSatisfy { $0.upperBound - $0.lowerBound <= 620 })
        let capped = OneWaySegmenter.segments(path: path, turnAlongs: Array(stride(from: 100.0, to: 2000, by: 100)), maxCount: 5)
        XCTAssertEqual(capped.count, 5)
        XCTAssertTrue(OneWaySegmenter.isSuspicious(recorded: 200, routed: 900))
        XCTAssertFalse(OneWaySegmenter.isSuspicious(recorded: 200, routed: 300))
    }
}
