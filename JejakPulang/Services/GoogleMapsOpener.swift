import UIKit
import RouteCore

enum GoogleMapsOpener {
    static var isGoogleMapsInstalled: Bool {
        guard let u = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(u)
    }

    /// Buka link di aplikasi Google Maps.
    /// Urutan: universal link → skema comgooglemapsurl:// → Safari.
    static func open(web: URL, app: URL) {
        UIApplication.shared.open(web, options: [.universalLinksOnly: true]) { opened in
            if opened { return }
            if isGoogleMapsInstalled {
                UIApplication.shared.open(app)
            } else {
                UIApplication.shared.open(web)
            }
        }
    }

    static func open(_ link: MapsLink) {
        open(web: link.url, app: link.appURL)
    }

    static func openPlace(_ c: Coordinate) {
        open(web: GoogleMapsURL.search(c), app: GoogleMapsURL.search(c, scheme: .appURL))
    }
}
