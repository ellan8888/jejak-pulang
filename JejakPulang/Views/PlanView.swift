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
        .onAppear { if plan == nil { rebuild() } }
        .onChange(of: sensitivity) { rebuild() }
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
            Text("Navigasi")
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
    }
}
