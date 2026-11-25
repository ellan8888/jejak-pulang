import AVFoundation
import CoreLocation
import UIKit
import RouteCore

/// Sesi navigasi jejak: GPS → TrackNavigator → suara & getar.
final class NavigationSession: NSObject, ObservableObject, CLLocationManagerDelegate, AVSpeechSynthesizerDelegate {
    @Published private(set) var update: NavigationUpdate?
    @Published private(set) var userCoordinate: Coordinate?
    @Published private(set) var speed: Double = 0
    @Published private(set) var gpsAccuracy: Double?
    @Published var muted = false {
        didSet { if muted { speech.stopSpeaking(at: .immediate) } }
    }
    @Published private(set) var lastSpoken: String?
    @Published var errorMessage: String?

    let path: MeasuredPath
    let maneuvers: [Maneuver]
    let detours: [ClosedRange<Double>]
    let travelMode: TravelMode

    private let navigator: TrackNavigator
    private let manager: CLLocationManager
    private let speech = AVSpeechSynthesizer()
    private var backgroundSession: CLBackgroundActivitySession?
    private var running = false
    private var speedSamples: [Double] = []

    init(path: MeasuredPath, maneuvers: [Maneuver], detours: [ClosedRange<Double>], travelMode: TravelMode) {
        self.path = path
        self.maneuvers = maneuvers
        self.detours = detours
        self.travelMode = travelMode
        self.navigator = TrackNavigator(path: path, maneuvers: maneuvers, detours: detours)
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = travelMode == .walking ? .fitness : .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        speech.delegate = self
    }

    // MARK: - Kontrol

    func start() {
        guard !running else { return }
        running = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            errorMessage = "Izin lokasi ditolak. Buka Pengaturan → Jejak Pulang → Lokasi."
            return
        default:
            break
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        backgroundSession = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        speech.stopSpeaking(at: .immediate)
        deactivateAudio()
    }

    /// Ulangi instruksi berikutnya (tombol "ulangi").
    func repeatInstruction() {
        guard let u = update else { return }
        if u.isOffRoute {
            say(Phrases.offRoute, force: true)
        } else if let m = u.nextManeuver, let d = u.distanceToNext {
            say(m.kind == .arrive ? Phrases.ahead(m, distance: d) : Phrases.ahead(m, distance: d), force: true)
        }
    }

    /// Perkiraan sisa waktu (detik).
    var eta: TimeInterval? {
        guard let u = update else { return nil }
        let fallback: Double
        switch travelMode {
        case .walking: fallback = 1.3
        case .bicycling: fallback = 4
        case .driving: fallback = 7
        }
        let avg = speedSamples.isEmpty ? fallback : max(speedSamples.reduce(0, +) / Double(speedSamples.count), fallback * 0.5)
        return u.remaining / avg
    }

    // MARK: - Lokasi

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            errorMessage = "Izin lokasi ditolak. Buka Pengaturan → Jejak Pulang → Lokasi."
        case .authorizedAlways, .authorizedWhenInUse:
            if running {
                manager.allowsBackgroundLocationUpdates = true
                manager.startUpdatingLocation()
            }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard running, let loc = locations.last else { return }
        gpsAccuracy = loc.horizontalAccuracy
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 80,
              abs(loc.timestamp.timeIntervalSinceNow) < 15 else { return }
        let c = loc.coordinate.coordinate
        userCoordinate = c
        if loc.speed >= 0 {
            speed = loc.speed
            if loc.speed > 0.5 {
                speedSamples.append(loc.speed)
                if speedSamples.count > 30 { speedSamples.removeFirst() }
            }
        }
        let wasOff = update?.isOffRoute ?? false
        guard let u = navigator.update(position: c, accuracy: loc.horizontalAccuracy,
                                       speed: loc.speed >= 0 ? loc.speed : nil) else { return }
        update = u
        if u.isOffRoute != wasOff {
            UINotificationFeedbackGenerator().notificationOccurred(u.isOffRoute ? .warning : .success)
        }
        for text in u.announcements { say(text) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let e = error as? CLError, e.code == .locationUnknown { return }
        errorMessage = "GPS bermasalah: \(error.localizedDescription)"
    }

    // MARK: - Suara

    private func say(_ text: String, force: Bool = false) {
        lastSpoken = text
        guard !muted || force else { return }
        activateAudio()
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "id-ID") ?? AVSpeechSynthesisVoice(language: "ms-MY")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.prefersAssistiveTechnologySettings = false
        speech.speak(u)
    }

    private func activateAudio() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .voicePrompt,
                           options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? s.setActive(true)
    }

    private func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking { deactivateAudio() }
    }
}
