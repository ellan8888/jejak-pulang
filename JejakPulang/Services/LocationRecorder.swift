import CoreLocation
import Foundation
import RouteCore

/// Perekam GPS. Tetap merekam saat layar terkunci / pindah aplikasi
/// (UIBackgroundModes = location + indikator lokasi biru di status bar).
final class LocationRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable { case idle, recording }

    @Published private(set) var state: State = .idle
    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var startedAt: Date?
    @Published private(set) var distance: Double = 0
    @Published private(set) var lastAccuracy: Double?
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published var errorMessage: String?
    /// Rekaman lama yang belum selesai (mis. aplikasi tertutup paksa saat merekam).
    @Published private(set) var recoverable: InProgressRecording?

    private let manager: CLLocationManager
    private var backgroundSession: CLBackgroundActivitySession?
    private var pendingStart = false
    private var lastPersist = Date.distantPast
    private let store: RouteFileStore?

    /// Titik dengan akurasi lebih buruk dari ini tidak direkam sama sekali.
    private let acceptAccuracy: CLLocationAccuracy = 65

    override init() {
        store = try? RouteFileStore(directory: RouteLibrary.defaultDirectory())
        let m = CLLocationManager()
        manager = m
        authorization = m.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        if let rec = store?.loadInProgress(), !rec.points.isEmpty {
            recoverable = rec
        }
    }

    var elapsed: TimeInterval {
        guard let s = startedAt else { return 0 }
        return Date().timeIntervalSince(s)
    }

    // MARK: - Kontrol

    func start() {
        errorMessage = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingStart = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            errorMessage = "Izin lokasi ditolak. Buka Pengaturan → Jejak Pulang → Lokasi, lalu pilih \"Saat Menggunakan App\" atau \"Selalu\"."
        default:
            begin(resuming: nil)
        }
    }

    /// Lanjutkan rekaman yang tertunda.
    func resumeRecoverable() {
        guard let rec = recoverable else { return }
        recoverable = nil
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            begin(resuming: rec)
        default:
            points = rec.points
            startedAt = rec.startedAt
            start()
        }
    }

    /// Ambil titik rekaman tertunda tanpa melanjutkan (untuk langsung disimpan).
    func takeRecoverable() -> InProgressRecording? {
        let rec = recoverable
        recoverable = nil
        store?.clearInProgress()
        return rec
    }

    func discardRecoverable() {
        recoverable = nil
        store?.clearInProgress()
    }

    private func begin(resuming rec: InProgressRecording?) {
        if let rec {
            points = rec.points
            startedAt = rec.startedAt
        } else if points.isEmpty || startedAt == nil {
            points = []
            startedAt = Date()
        }
        distance = MeasuredPath(points.map(\.coordinate)).length
        state = .recording
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        backgroundSession = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
        persist(force: true)
    }

    /// Hentikan dan kembalikan titik hasil rekaman (file rekaman berjalan dihapus).
    func finish() -> [TrackPoint] {
        let result = points
        stopUpdates()
        store?.clearInProgress()
        reset()
        return result
    }

    func discard() {
        stopUpdates()
        store?.clearInProgress()
        reset()
    }

    private func stopUpdates() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    private func reset() {
        state = .idle
        points = []
        startedAt = nil
        distance = 0
        lastAccuracy = nil
    }

    private func persist(force: Bool = false) {
        guard state == .recording, let startedAt else { return }
        if !force && Date().timeIntervalSince(lastPersist) < 15 { return }
        lastPersist = Date()
        try? store?.saveInProgress(InProgressRecording(startedAt: startedAt, points: points))
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if pendingStart {
                pendingStart = false
                begin(resuming: nil)
            }
        case .denied, .restricted:
            if pendingStart {
                pendingStart = false
                errorMessage = "Izin lokasi ditolak. Buka Pengaturan → Jejak Pulang → Lokasi untuk mengizinkan."
            }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard state == .recording else { return }
        for loc in locations {
            lastAccuracy = loc.horizontalAccuracy
            guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= acceptAccuracy else { continue }
            // abaikan data lokasi basi dari cache
            if abs(loc.timestamp.timeIntervalSinceNow) > 30 { continue }
            let p = TrackPoint(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
                               timestamp: loc.timestamp, horizontalAccuracy: loc.horizontalAccuracy,
                               speed: loc.speed >= 0 ? loc.speed : nil)
            if let last = points.last {
                distance += Geo.distance(last.coordinate, p.coordinate)
            }
            points.append(p)
        }
        persist()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let e = error as? CLError, e.code == .locationUnknown { return } // sementara, akan dicoba lagi
        if let e = error as? CLError, e.code == .denied {
            errorMessage = "Izin lokasi dicabut. Rekaman berhenti menerima titik baru."
            return
        }
        errorMessage = "GPS bermasalah: \(error.localizedDescription)"
    }
}
