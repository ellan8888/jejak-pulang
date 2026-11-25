import MapKit
import SwiftUI
import RouteCore

struct RouteDetailView: View {
    let routeID: UUID

    @EnvironmentObject private var library: RouteLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var gpxURL: URL?

    var body: some View {
        if let route = library.route(id: routeID) {
            content(route)
        } else {
            ContentUnavailableView("Rute tidak ditemukan", systemImage: "map")
        }
    }

    private func content(_ route: SavedRoute) -> some View {
        List {
            Section {
                RouteMapPreview(route: route)
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                NavigationLink {
                    PlanView(route: route, direction: .returnTrip)
                } label: {
                    Label("Pulang lewat rute ini", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.headline)
                        .padding(.vertical, 4)
                }
                NavigationLink {
                    PlanView(route: route, direction: .sameDirection)
                } label: {
                    Label("Pergi lagi ke lokasi ini", systemImage: "arrow.forward.circle")
                }
            }

            Section("Info") {
                LabeledContent("Jarak", value: Fmt.distance(route.distanceMeters))
                if let d = route.duration {
                    LabeledContent("Lama perjalanan", value: Fmt.duration(d))
                }
                LabeledContent("Direkam", value: Fmt.date(route.createdAt))
                LabeledContent("Jumlah titik", value: "\(route.points.count)")
                let gaps = route.gaps()
                if !gaps.isEmpty {
                    Label("\(gaps.count) bagian rekaman terputus (sinyal GPS hilang). Google Maps akan mengisi celahnya sendiri.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if let end = route.end {
                    Button {
                        GoogleMapsOpener.openPlace(end)
                    } label: {
                        Label("Buka lokasi tujuan di Google Maps", systemImage: "mappin.and.ellipse")
                    }
                }
                if let gpxURL {
                    ShareLink(item: gpxURL) {
                        Label("Bagikan file GPX", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    newName = route.name
                    renaming = true
                } label: {
                    Label("Ganti nama", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Hapus rute", systemImage: "trash")
                }
            } footer: {
                Text("Tips: di Google Maps, simpan lokasi tujuan (Simpan → Berbintang) supaya lain kali bisa langsung dicari.")
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { gpxURL = library.exportGPXFile(for: route) }
        .alert("Ganti nama", isPresented: $renaming) {
            TextField("Nama", text: $newName)
            Button("Simpan") {
                var r = route
                let t = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    r.name = t
                    library.update(r)
                    gpxURL = library.exportGPXFile(for: r)
                }
            }
            Button("Batal", role: .cancel) {}
        }
        .confirmationDialog("Hapus rute \"\(route.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Hapus", role: .destructive) {
                library.delete(id: route.id)
                dismiss()
            }
            Button("Batal", role: .cancel) {}
        }
    }
}

struct RouteMapPreview: View {
    let route: SavedRoute

    var body: some View {
        Map(initialPosition: .automatic) {
            MapPolyline(coordinates: route.points.map { $0.coordinate.cl })
                .stroke(.blue, lineWidth: 4)
            if let s = route.start {
                Marker("Awal", systemImage: "house.fill", coordinate: s.cl)
                    .tint(.green)
            }
            if let e = route.end {
                Marker("Tujuan", systemImage: "flag.fill", coordinate: e.cl)
                    .tint(.red)
            }
        }
    }
}
