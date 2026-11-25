import SwiftUI
import UniformTypeIdentifiers
import RouteCore

struct HomeView: View {
    @EnvironmentObject private var library: RouteLibrary
    @EnvironmentObject private var recorder: LocationRecorder

    @State private var showImporter = false
    @State private var path = NavigationPath()
    @State private var recoveredName = ""
    @State private var askRecoveredName = false
    @State private var recoveredPoints: [TrackPoint] = []

    private var isRecording: Binding<Bool> {
        Binding(get: { recorder.state == .recording }, set: { _ in })
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    startCard
                }

                if let rec = recorder.recoverable {
                    Section("Rekaman belum selesai") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Ada rekaman \(Fmt.distance(MeasuredPath(rec.points.map(\.coordinate)).length)) dari \(Fmt.date(rec.startedAt)) yang terhenti.")
                                .font(.subheadline)
                            HStack {
                                Button("Lanjutkan") { recorder.resumeRecoverable() }
                                    .buttonStyle(.borderedProminent)
                                Button("Simpan") {
                                    recoveredPoints = recorder.takeRecoverable()?.points ?? []
                                    recoveredName = ""
                                    askRecoveredName = true
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                                Button("Buang", role: .destructive) { recorder.discardRecoverable() }
                                    .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    if library.routes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Belum ada rute").font(.headline)
                            Text("Tekan \"Mulai Rekam\" sebelum berangkat ke lokasi yang tidak ada di Google Maps. Saat mau pulang, buka rutenya di sini.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    } else {
                        ForEach(library.routes) { route in
                            NavigationLink(value: route.id) {
                                RouteRow(route: route)
                            }
                        }
                        .onDelete { idx in
                            for i in idx { library.delete(id: library.routes[i].id) }
                        }
                    }
                } header: {
                    Text("Rute tersimpan")
                }
            }
            .navigationTitle("Jejak Pulang")
            .navigationDestination(for: UUID.self) { id in
                RouteDetailView(routeID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Impor file GPX", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [UTType(importedAs: "com.topografix.gpx"), .xml],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    library.importGPX(from: url)
                }
            }
            .fullScreenCover(isPresented: isRecording) {
                RecordingView()
                    .environmentObject(library)
                    .environmentObject(recorder)
            }
            .alert("Simpan rekaman", isPresented: $askRecoveredName) {
                TextField("Nama lokasi", text: $recoveredName)
                Button("Simpan") {
                    library.add(name: recoveredName, points: recoveredPoints)
                    recoveredPoints = []
                }
                Button("Simpan tanpa nama", role: .cancel) {
                    library.add(name: "", points: recoveredPoints)
                    recoveredPoints = []
                }
            } message: {
                Text("Beri nama supaya mudah dicari.")
            }
            .alert("Ada masalah", isPresented: Binding(
                get: { library.lastError != nil || (recorder.errorMessage != nil && recorder.state == .idle) },
                set: { if !$0 { library.lastError = nil; recorder.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.lastError ?? recorder.errorMessage ?? "")
            }
        }
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Mau ke lokasi yang belum ada di Maps?", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.headline)
            Text("Rekam jalan perginya. Pulangnya, aplikasi membuatkan rute Google Maps lewat jalan yang sama.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                recorder.start()
            } label: {
                Label("Mulai Rekam", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(recorder.recoverable != nil)
        }
        .padding(.vertical, 6)
    }
}

struct RouteRow: View {
    let route: SavedRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(route.name).font(.headline)
            HStack(spacing: 8) {
                Text(Fmt.date(route.createdAt))
                Text("·")
                Text(Fmt.distance(route.distanceMeters))
                if let d = route.duration {
                    Text("·")
                    Text(Fmt.duration(d))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
