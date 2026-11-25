import MapKit
import SwiftUI
import RouteCore

struct RecordingView: View {
    @EnvironmentObject private var library: RouteLibrary
    @EnvironmentObject private var recorder: LocationRecorder

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var askName = false
    @State private var name = ""
    @State private var confirmDiscard = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                UserAnnotation()
                if recorder.points.count > 1 {
                    MapPolyline(coordinates: recorder.points.map { $0.coordinate.cl })
                        .stroke(.red, lineWidth: 5)
                }
                if let first = recorder.points.first {
                    Marker("Awal", systemImage: "house.fill", coordinate: first.coordinate.cl)
                        .tint(.green)
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .ignoresSafeArea()

            panel
        }
        .alert("Simpan rute", isPresented: $askName) {
            TextField("Nama lokasi (mis. Rumah teman)", text: $name)
            Button("Simpan") {
                let pts = recorder.finish()
                library.add(name: name, points: pts)
            }
            Button("Lanjut merekam", role: .cancel) {}
        } message: {
            Text("Rekaman berhenti dan disimpan. Nanti buka rute ini saat mau pulang.")
        }
        .confirmationDialog("Buang rekaman ini?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Buang rekaman", role: .destructive) { recorder.discard() }
            Button("Batal", role: .cancel) {}
        }
    }

    private var panel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text("Merekam").font(.headline)
                Spacer()
                accuracyBadge
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    stat("Waktu", Fmt.duration(recorder.elapsed))
                    Divider().frame(height: 32)
                    stat("Jarak", Fmt.distance(recorder.distance))
                    Divider().frame(height: 32)
                    stat("Titik", "\(recorder.points.count)")
                }
            }

            if let err = recorder.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text("Boleh kunci layar atau buka aplikasi lain — rekaman tetap jalan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(role: .destructive) {
                    confirmDiscard = true
                } label: {
                    Image(systemName: "trash")
                        .padding(.vertical, 8)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)

                Button {
                    name = ""
                    askName = true
                } label: {
                    Label("Sampai — Selesai & Simpan", systemImage: "flag.checkered")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.points.count < 2)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.monospacedDigit().bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var accuracyBadge: some View {
        if let acc = recorder.lastAccuracy, acc >= 0 {
            let good = acc <= 20
            let ok = acc <= 65
            Label(good ? "GPS bagus" : (ok ? "GPS cukup" : "GPS lemah"),
                  systemImage: "location.fill")
                .font(.caption.bold())
                .foregroundStyle(good ? Color.green : (ok ? Color.orange : Color.red))
        } else {
            Label("Mencari GPS…", systemImage: "location.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
