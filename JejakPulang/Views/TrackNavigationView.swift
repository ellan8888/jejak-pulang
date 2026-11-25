import MapKit
import SwiftUI
import RouteCore

/// Layar navigasi jejak: mengikuti garis rekaman persis, dengan panduan suara.
struct TrackNavigationView: View {
    @StateObject private var session: NavigationSession
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var confirmStop = false

    let destinationName: String

    init(path: MeasuredPath, maneuvers: [Maneuver], detours: [ClosedRange<Double>],
         travelMode: TravelMode, destinationName: String) {
        _session = StateObject(wrappedValue: NavigationSession(path: path, maneuvers: maneuvers,
                                                               detours: detours, travelMode: travelMode))
        self.destinationName = destinationName
    }

    var body: some View {
        ZStack {
            map
            VStack(spacing: 0) {
                banner
                Spacer()
                bottomBar
            }
        }
        .onAppear {
            session.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            session.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .confirmationDialog("Akhiri navigasi?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Akhiri", role: .destructive) { dismiss() }
            Button("Lanjut navigasi", role: .cancel) {}
        }
    }

    // MARK: - Peta

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            MapPolyline(coordinates: session.path.coordinates.map(\.cl))
                .stroke(.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            ForEach(Array(session.detours.enumerated()), id: \.offset) { _, r in
                MapPolyline(coordinates: detourCoordinates(r).map(\.cl))
                    .stroke(.purple, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }
            if let u = session.update, u.along > 5 {
                MapPolyline(coordinates: traveledCoordinates(until: u.along).map(\.cl))
                    .stroke(.gray.opacity(0.7), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }
            if let u = session.update, u.isOffRoute, let me = session.userCoordinate {
                MapPolyline(coordinates: [me.cl, u.snapped.cl])
                    .stroke(.red, style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
            }
            if let end = session.path.coordinates.last {
                Marker(destinationName, systemImage: "flag.checkered", coordinate: end.cl)
                    .tint(.green)
            }
        }
        .mapControls {
            MapCompass()
            MapUserLocationButton()
        }
        .ignoresSafeArea()
    }

    private func detourCoordinates(_ r: ClosedRange<Double>) -> [Coordinate] {
        let p = session.path
        var out: [Coordinate] = []
        if let a = p.point(at: r.lowerBound) { out.append(a) }
        for (i, c) in p.coordinates.enumerated() where p.cumulative[i] > r.lowerBound && p.cumulative[i] < r.upperBound {
            out.append(c)
        }
        if let b = p.point(at: r.upperBound) { out.append(b) }
        return out
    }

    private func traveledCoordinates(until along: Double) -> [Coordinate] {
        let p = session.path
        var out: [Coordinate] = []
        for (i, c) in p.coordinates.enumerated() where p.cumulative[i] < along { out.append(c) }
        if let x = p.point(at: along) { out.append(x) }
        return out
    }

    // MARK: - Banner instruksi

    @ViewBuilder private var banner: some View {
        Group {
            if let u = session.update {
                if u.arrived {
                    instruction(icon: "flag.checkered", title: "Sudah sampai", subtitle: destinationName, color: .green)
                } else if u.isOffRoute, let me = session.userCoordinate {
                    instruction(icon: "exclamationmark.triangle.fill",
                                title: "Keluar dari rute · \(Fmt.distance(u.offset))",
                                subtitle: "Kembali ke garis biru, arah \(Phrases.compass(Geo.bearing(me, u.snapped)))",
                                color: .red)
                } else if let m = u.nextManeuver, let d = u.distanceToNext {
                    instruction(icon: Self.icon(for: m),
                                title: Fmt.distance(d),
                                subtitle: m.kind == .arrive ? "Tujuan: \(destinationName)"
                                    : Phrases.label(m) + (m.inDetour || u.inDetour ? " · jalan memutar" : ""),
                                color: u.inDetour ? .purple : .blue)
                }
            } else {
                instruction(icon: "location.magnifyingglass", title: "Mencari GPS…",
                            subtitle: "Pastikan izin lokasi aktif", color: .gray)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func instruction(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .bold))
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title.bold()).lineLimit(1).minimumScaleFactor(0.6)
                Text(subtitle).font(.headline).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding()
        .background(color.gradient, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 6)
    }

    static func icon(for m: Maneuver) -> String {
        switch m.kind {
        case .arrive: return "flag.checkered"
        case .uTurn: return m.angle > 0 ? "arrow.uturn.right" : "arrow.uturn.left"
        case .turn:
            let a = abs(m.angle)
            if a < 50 { return m.angle > 0 ? "arrow.up.right" : "arrow.up.left" }
            return m.angle > 0 ? "arrow.turn.up.right" : "arrow.turn.up.left"
        }
    }

    // MARK: - Bar bawah

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let err = session.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    if let u = session.update {
                        Text("\(Fmt.distance(u.remaining)) lagi")
                            .font(.title3.bold())
                        if let eta = session.eta {
                            Text("± \(Fmt.minutes(eta)) · tiba \(Fmt.clock(Date().addingTimeInterval(eta)))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Menyiapkan…").font(.title3.bold())
                    }
                }
                Spacer()
                Button {
                    session.repeatInstruction()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                Button {
                    session.muted.toggle()
                } label: {
                    Image(systemName: session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                Button {
                    if session.update?.arrived == true { dismiss() } else { confirmStop = true }
                } label: {
                    Text(session.update?.arrived == true ? "Selesai" : "Akhiri")
                        .font(.headline)
                        .frame(height: 44)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(session.update?.arrived == true ? .green : .red)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }
}
