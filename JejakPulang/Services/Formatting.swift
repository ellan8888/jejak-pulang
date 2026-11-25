import CoreLocation
import Foundation
import RouteCore

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

extension CLLocationCoordinate2D {
    var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

enum Fmt {
    static func distance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        let km = meters / 1000
        let s = String(format: km < 10 ? "%.1f" : "%.0f", km)
        return s.replacingOccurrences(of: ".", with: ",") + " km"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d j %02d mnt", h, m) }
        return String(format: "%d:%02d", m, s)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "id_ID")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func date(_ d: Date) -> String { dateFormatter.string(from: d) }

    static func turn(_ w: PlannedWaypoint) -> String {
        switch w.kind {
        case .manual: return "Titik tambahan"
        case .uTurn: return "Putar balik (mungkin salah jalan)"
        case .turn:
            let a = w.angle ?? 0
            let side = a > 0 ? "kanan" : "kiri"
            let sharp = abs(a) >= 120 ? "tajam " : (abs(a) < 55 ? "sedikit " : "")
            return "Belok \(sharp)\(side)"
        }
    }

    static func travelModeLabel(_ m: TravelMode) -> String {
        switch m {
        case .driving: return "Motor/Mobil"
        case .walking: return "Jalan kaki"
        case .bicycling: return "Sepeda"
        }
    }

    static func sensitivityLabel(_ s: TurnSensitivity) -> String {
        switch s {
        case .fewer: return "Sedikit"
        case .normal: return "Normal"
        case .more: return "Banyak"
        }
    }
}
