import Foundation

/// Penyimpanan rute sebagai file JSON (satu file per rute) + file rekaman berjalan.
/// Format file dibuat terbuka supaya mudah dicadangkan / dipindah.
public struct RouteFileStore: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    var inProgressURL: URL { directory.appendingPathComponent("_recording.json") }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("route-\(id.uuidString).json")
    }

    public func loadAll() -> [SavedRoute] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("route-") && $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? Self.decoder.decode(SavedRoute.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func save(_ route: SavedRoute) throws {
        let data = try Self.encoder.encode(route)
        try data.write(to: url(for: route.id), options: .atomic)
    }

    public func delete(id: UUID) throws {
        let u = url(for: id)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }

    public func saveInProgress(_ rec: InProgressRecording) throws {
        let data = try Self.encoder.encode(rec)
        try data.write(to: inProgressURL, options: .atomic)
    }

    public func loadInProgress() -> InProgressRecording? {
        guard let data = try? Data(contentsOf: inProgressURL) else { return nil }
        return try? Self.decoder.decode(InProgressRecording.self, from: data)
    }

    public func clearInProgress() {
        try? FileManager.default.removeItem(at: inProgressURL)
    }
}
