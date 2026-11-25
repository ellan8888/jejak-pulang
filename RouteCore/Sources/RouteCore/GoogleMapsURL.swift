import Foundation

/// Pembuat URL Google Maps (format "Maps URLs", api=1).
/// Origin sengaja dikosongkan supaya Google Maps memakai lokasi pengguna saat ini.
public enum GoogleMapsURL {
    public enum Scheme: Sendable {
        /// https://www.google.com/maps/... (universal link; terbuka di aplikasi bila terpasang)
        case web
        /// comgooglemapsurl://www.google.com/maps/... (paksa buka aplikasi Google Maps iOS)
        case appURL
    }

    public static func format(_ c: Coordinate) -> String {
        String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), c.latitude, c.longitude)
    }

    static func prefix(_ scheme: Scheme) -> String {
        switch scheme {
        case .web: return "https://www.google.com/maps/"
        case .appURL: return "comgooglemapsurl://www.google.com/maps/"
        }
    }

    public static func directions(destination: Coordinate, waypoints: [Coordinate],
                                  travelMode: TravelMode, navigate: Bool = false,
                                  scheme: Scheme = .web) -> URL {
        var q = "api=1&destination=\(format(destination))&travelmode=\(travelMode.rawValue)"
        if !waypoints.isEmpty {
            q += "&waypoints=" + waypoints.map(format).joined(separator: "%7C")
        }
        if navigate { q += "&dir_action=navigate" }
        // Semua komponen sudah aman untuk URL (angka, titik, koma, %7C).
        return URL(string: prefix(scheme) + "dir/?" + q)!
    }

    public static func search(_ c: Coordinate, scheme: Scheme = .web) -> URL {
        URL(string: prefix(scheme) + "search/?api=1&query=" + format(c))!
    }
}
