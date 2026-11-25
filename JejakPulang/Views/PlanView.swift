import MapKit
import SwiftUI
import RouteCore

/// Layar "Pulang" / "Pergi lagi": menyiapkan titik singgah lalu membuka Google Maps.
struct PlanView: View {
    let route: SavedRoute
    let direction: RouteDirection

    private let planner = RoutePlanner()

    @State private var plan: NavigationPlan?
    @State private var sensitivity: TurnSensitivity = .normal
    @State private var linkMode: LinkMode = .complete
    @AppStorage("travelMode") private var travelModeRaw = TravelMode.driving.rawValue
    @State private var addMode = false
    @State private var opened: Set<Int> = []
    @State private var hint: String?
    @StateObject private var oneWay = OneWayChecker()
    /// Path dasar navigasi jejak (putar-balik karena salah jalan sudah dibuang).
    @State private var navBase: MeasuredPath?
    @State private var navTarget: NavTarget?

    struct NavTarget: Identifiable {
        let id = UUID()
        let path: MeasuredPath
        let maneuvers: [Maneuver]
        let detours: [ClosedRange<Double>]
    }

    private var travelMode: TravelMode { TravelMode(rawValue: travelModeRaw) ?? .driving }

    private var links: [MapsLink] {
        guard let plan else { return [] }
        return planner.links(for: plan, mode: linkMode, travelMode: travelMode)
    }

    private var displayed: [PlannedWaypoint] {
        guard let plan else { return [] }
        return linkMode == .single ? planner.selectForSingleLink(plan) : plan.orderedEnabled
    }

    private var destinationName: String {
        direction == .returnTrip ? "titik awal (rumah)" : "lokasi tujuan"
    }

    var body: some View {
        List {
            Section {
                mapSection
                    .frame(height: 320)
                    .listRowInsets(EdgeInsets())
            } footer: {
                if addMode {
                    Text("Ketuk garis rute di peta untuk menambah titik singgah di belokan yang membingungkan.")
                }
            }

            Section {
                Picker("Kendaraan", selection: $travelModeRaw) {
                    ForEach(TravelMode.allCases, id: \.rawValue) { m in
                        Text(Fmt.travelModeLabel(m)).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            trackNavigationSection

            linksSection

            Section {
                Picker("Jumlah link", selection: $linkMode) {
                    Text("Lengkap").tag(LinkMode.complete)
                    Text("1 link saja").tag(LinkMode.single)
                }
                .pickerStyle(.segmented)
                Picker("Kepekaan belokan", selection: $sensitivity) {
                    ForEach(TurnSensitivity.allCases, id: \.self) { s in
                        Text(Fmt.sensitivityLabel(s)).tag(s)
                    }
                }
            } header: {
                Text("Pengaturan")
            } footer: {
                Text(linkMode == .complete
                     ? "Lengkap: semua belokan dipakai, dipecah per \(planner.maxWaypointsPerLink) titik (batas Google Maps)."
                     : "1 link saja: hanya \(planner.maxWaypointsPerLink) belokan terpenting. Di luar titik itu Google Maps memilih jalan sendiri.")
            }

            waypointSection
        }
        .navigationTitle(direction == .returnTrip ? "Pulang" : "Pergi lagi")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if plan == nil { rebuild() }
            runOneWayCheck()
        }
        .onDisappear { oneWay.cancel() }
        .onChange(of: sensitivity) { rebuild() }
        .onChange(of: travelModeRaw) { runOneWayCheck() }
        .fullScreenCover(item: $navTarget) { t in
            TrackNavigationView(path: t.path, maneuvers: t.maneuvers, detours: t.detours,
                                travelMode: travelMode,
                                destinationName: direction == .returnTrip ? "Awal/Rumah" : route.name)
        }
    }

    // MARK: - Peta

    private var mapSection: some View {
        MapReader { proxy in
            Map(initialPosition: .automatic) {
                if let plan {
                    MapPolyline(coordinates: plan.path.map(\.cl))
                        .stroke(.blue.opacity(0.75), lineWidth: 5)
                    if let s = plan.path.first {
                        Annotation("Mulai", coordinate: s.cl) {
                            Image(systemName: "figure.walk.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white, .blue)
                        }
                    }
                    Marker(direction == .returnTrip ? "Awal/Rumah" : "Tujuan",
                           systemImage: direction == .returnTrip ? "house.fill" : "flag.fill",
                           coordinate: plan.destination.cl)
                        .tint(.green)
                    ForEach(oneWay.flagged.filter(\.useDetour)) { seg in
                        MapPolyline(coordinates: seg.detour.map(\.cl))
                            .stroke(.purple, lineWidth: 4)
                    }
                    ForEach(oneWay.flagged) { seg in
                        Annotation("", coordinate: seg.midpoint.cl) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow, .black)
                                .font(.title3)
                        }
                    }
                    ForEach(plan.waypoints.filter { !$0.isEnabled }) { w in
                        Annotation("", coordinate: w.coordinate.cl) {
                            Circle().fill(.gray).frame(width: 9, height: 9)
                        }
                    }
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { idx, w in
                        Annotation("", coordinate: w.coordinate.cl) {
                            Text("\(idx + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(w.kind == .manual ? Color.purple : Color.orange))
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        }
                    }
                }
            }
            .onTapGesture { location in
                guard addMode, let plan, let c = proxy.convert(location, from: .local) else { return }
                if let w = planner.manualWaypoint(near: c.coordinate, in: plan) {
                    self.plan?.waypoints.append(w)
                    self.plan?.waypoints.sort { $0.along < $1.along }
                    hint = nil
                } else {
                    hint = "Ketuk lebih dekat ke garis rute."
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    addMode.toggle()
                    hint = nil
                } label: {
                    Label(addMode ? "Selesai" : "Tambah titik",
                          systemImage: addMode ? "checkmark" : "plus")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(addMode ? Color.purple : Color.gray.opacity(0.8))
                .padding(10)
            }
            .overlay(alignment: .bottom) {
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
            }
        }
    }

    // MARK: - Link Google Maps

    private var linksSection: some View {
        Section {
            if plan == nil {
                Text("Rute terlalu pendek untuk dibuat navigasinya.")
                    .foregroundStyle(.secondary)
            }
            ForEach(links) { link in
                Button {
                    GoogleMapsOpener.open(link)
                    opened.insert(link.index)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: opened.contains(link.index) ? "checkmark.circle.fill" : "arrow.triangle.turn.up.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(opened.contains(link.index) ? Color.green : Color.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.total == 1 ? "Buka di Google Maps" : "Bagian \(link.index + 1) dari \(link.total)")
                                .font(.headline)
                            Text(subtitle(for: link))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.url = link.url
                    } label: {
                        Label("Salin link", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: link.url) {
                        Label("Bagikan link", systemImage: "square.and.arrow.up")
                    }
                }
            }
        } header: {
            Text("Atau lewat Google Maps")
        } footer: {
            if links.count > 1 {
                Text("Mulai dari Bagian 1. Setelah sampai di akhir bagian itu, kembali ke aplikasi ini dan buka bagian berikutnya. Tekan lama untuk menyalin link.")
            } else {
                Text("Google Maps akan memandu lewat titik-titik bernomor di peta. Tekan lama untuk menyalin link.")
            }
        }
    }

    private func subtitle(for link: MapsLink) -> String {
        let stops = link.waypoints.isEmpty ? "Tanpa titik singgah" : "\(link.waypoints.count) titik singgah"
        let end = link.index == link.total - 1 ? "sampai \(destinationName)" : "berhenti di titik berikutnya"
        return "\(stops) · \(end)"
    }

    // MARK: - Daftar titik

    private var waypointSection: some View {
        Section {
            if let plan, plan.waypoints.isEmpty {
                Text("Tidak ada belokan terdeteksi. Rute lurus — Google Maps langsung diarahkan ke \(destinationName).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(plan?.waypoints ?? []) { w in
                Toggle(isOn: enabledBinding(w.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.turn(w))
                        Text("\(Fmt.distance(w.along)) dari titik mulai")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    if w.kind == .manual {
                        Button(role: .destructive) {
                            plan?.waypoints.removeAll { $0.id == w.id }
                        } label: {
                            Label("Hapus", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Titik belokan (\(plan?.orderedEnabled.count ?? 0) aktif)")
        } footer: {
            Text("Matikan titik yang tidak perlu. Titik ditaruh sedikit setelah belokan supaya Google Maps pasti lewat jalan itu.")
        }
    }

    private func enabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { plan?.waypoints.first { $0.id == id }?.isEnabled ?? false },
            set: { v in
                if let i = plan?.waypoints.firstIndex(where: { $0.id == id }) {
                    plan?.waypoints[i].isEnabled = v
                }
            })
    }

    private func rebuild() {
        let manual = plan?.waypoints.filter { $0.kind == .manual } ?? []
        plan = planner.makePlan(route: route, direction: direction,
                                sensitivity: sensitivity, keepingManual: manual)
        opened = []
        if navBase == nil, let plan {
            let raw = MeasuredPath(plan.path)
            let spurs = PathComposer.backtrackSpurs(in: raw)
            navBase = spurs.isEmpty ? raw : PathComposer.splice(raw, replacements: spurs).path
        }
    }

    // MARK: - Navigasi jejak

    private func runOneWayCheck() {
        guard let navBase else { return }
        oneWay.run(path: navBase, travelMode: travelMode)
    }

    private func startNavigation() {
        guard let navBase else { return }
        let composed = oneWay.composedPath(from: navBase)
        let maneuvers = ManeuverBuilder.build(path: composed.path, detours: composed.detours,
                                              threshold: min(sensitivity.threshold, 40))
        navTarget = NavTarget(path: composed.path, maneuvers: maneuvers, detours: composed.detours)
    }

    private var trackNavigationSection: some View {
        Section {
            Button {
                startNavigation()
            } label: {
                Label("Mulai Navigasi Jejak", systemImage: "location.north.line.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(navBase == nil)

            oneWayStatus

            ForEach(oneWay.flagged) { seg in
                Toggle(isOn: detourBinding(seg.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pakai jalan memutar di \(Fmt.distance(seg.range.lowerBound)) dari mulai")
                        Text("Rekaman \(Fmt.distance(seg.recordedLength)) · Apple Maps \(Fmt.distance(seg.routedLength ?? 0))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Navigasi jejak (persis)")
        } footer: {
            Text("Dipandu suara di jalur rekaman yang sama persis, langsung di aplikasi ini. Bagian yang kemungkinan jalan satu arah diganti jalan memutar (ungu). Matikan sakelarnya kalau kamu yakin jalan itu dua arah.")
        }
    }

    @ViewBuilder private var oneWayStatus: some View {
        switch oneWay.status {
        case .idle:
            EmptyView()
        case .checking(let done, let total):
            HStack(spacing: 10) {
                ProgressView()
                Text("Mengecek jalan satu arah ke Apple Maps… \(done)/\(total)")
                    .font(.subheadline)
            }
        case .finished:
            if oneWay.flagged.isEmpty {
                Label("Tidak ada jalan satu arah terdeteksi", systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else {
                Label("\(oneWay.flagged.count) bagian kemungkinan jalan satu arah — jalan memutar disiapkan",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        case .failed(let msg), .skipped(let msg):
            Label(msg, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func detourBinding(_ id: Int) -> Binding<Bool> {
        Binding(
            get: { oneWay.segments.first { $0.id == id }?.useDetour ?? false },
            set: { v in
                if let i = oneWay.segments.firstIndex(where: { $0.id == id }) {
                    oneWay.segments[i].useDetour = v
                }
            })
    }
}
