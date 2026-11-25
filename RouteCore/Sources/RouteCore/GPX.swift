import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum GPX {
    public enum ParseError: Error, LocalizedError {
        case invalidXML(String)
        case noPoints

        public var errorDescription: String? {
            switch self {
            case .invalidXML(let m): return "File GPX tidak valid: \(m)"
            case .noPoints: return "File GPX tidak berisi titik rute."
            }
        }
    }

    public struct Parsed {
        public var name: String?
        public var points: [TrackPoint]
    }

    static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func export(_ route: SavedRoute) -> String {
        let iso = isoFormatter()
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Jejak Pulang" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(escape(route.name))</name><time>\(iso.string(from: route.createdAt))</time></metadata>
          <trk>
            <name>\(escape(route.name))</name>
            <trkseg>

        """
        for p in route.points {
            s += "      <trkpt lat=\"\(String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), p.latitude))\" lon=\"\(String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), p.longitude))\">"
            if p.timestamp != .distantPast {
                s += "<time>\(iso.string(from: p.timestamp))</time>"
            }
            if p.horizontalAccuracy > 0 {
                s += "<hdop>\(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), p.horizontalAccuracy / 5))</hdop>"
            }
            s += "</trkpt>\n"
        }
        s += """
            </trkseg>
          </trk>
        </gpx>

        """
        return s
    }

    /// Membaca trkpt (track), atau rtept/wpt bila tidak ada track.
    public static func parse(_ data: Data) throws -> Parsed {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.invalidXML(parser.parserError?.localizedDescription ?? "tidak diketahui")
        }
        let pts = !delegate.trackPoints.isEmpty ? delegate.trackPoints
            : (!delegate.routePoints.isEmpty ? delegate.routePoints : delegate.wayPoints)
        guard !pts.isEmpty else { throw ParseError.noPoints }
        return Parsed(name: delegate.name, points: pts)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var trackPoints: [TrackPoint] = []
        var routePoints: [TrackPoint] = []
        var wayPoints: [TrackPoint] = []
        var name: String?

        private var current: (kind: String, lat: Double, lon: Double, time: Date?)?
        private var text = ""
        private let iso = GPX.isoFormatter()
        private let isoNoFraction: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            let el = local(elementName)
            text = ""
            if el == "trkpt" || el == "rtept" || el == "wpt",
               let la = attributes["lat"].flatMap(Double.init),
               let lo = attributes["lon"].flatMap(Double.init) {
                current = (el, la, lo, nil)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let el = local(elementName)
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch el {
            case "time":
                if current != nil {
                    current?.time = iso.date(from: value) ?? isoNoFraction.date(from: value)
                }
            case "name":
                if current == nil, name == nil, !value.isEmpty { name = value }
            case "trkpt", "rtept", "wpt":
                if let c = current {
                    let p = TrackPoint(latitude: c.lat, longitude: c.lon,
                                       timestamp: c.time ?? .distantPast, horizontalAccuracy: 0)
                    switch c.kind {
                    case "trkpt": trackPoints.append(p)
                    case "rtept": routePoints.append(p)
                    default: wayPoints.append(p)
                    }
                }
                current = nil
            default:
                break
            }
            text = ""
        }

        private func local(_ name: String) -> String {
            if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
            return name
        }
    }
}
