import Foundation
import RouteCore

/// Daftar rute tersimpan untuk UI.
final class RouteLibrary: ObservableObject {
    @Published private(set) var routes: [SavedRoute] = []
    @Published var lastError: String?

    let store: RouteFileStore

    static func defaultDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Routes", isDirectory: true)
    }

    init() {
        // Folder Documents selalu bisa dibuat; bila gagal, pakai folder sementara agar app tetap jalan.
        if let s = try? RouteFileStore(directory: Self.defaultDirectory()) {
            store = s
        } else {
            store = try! RouteFileStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("Routes", isDirectory: true))
        }
        reload()
    }

    func reload() {
        routes = store.loadAll()
    }

    func route(id: UUID) -> SavedRoute? {
        routes.first { $0.id == id }
    }

    @discardableResult
    func add(name: String, points: [TrackPoint]) -> SavedRoute? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = SavedRoute(name: trimmed.isEmpty ? "Rute \(Fmt.date(Date()))" : trimmed,
                               createdAt: points.first?.timestamp ?? Date(), points: points)
        do {
            try store.save(route)
            reload()
            return route
        } catch {
            lastError = "Gagal menyimpan rute: \(error.localizedDescription)"
            return nil
        }
    }

    func update(_ route: SavedRoute) {
        do {
            try store.save(route)
            reload()
        } catch {
            lastError = "Gagal menyimpan perubahan: \(error.localizedDescription)"
        }
    }

    func delete(id: UUID) {
        do {
            try store.delete(id: id)
            reload()
        } catch {
            lastError = "Gagal menghapus: \(error.localizedDescription)"
        }
    }

    func importGPX(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try GPX.parse(data)
            let name = parsed.name ?? url.deletingPathExtension().lastPathComponent
            let created = parsed.points.first(where: { $0.timestamp != .distantPast })?.timestamp ?? Date()
            let route = SavedRoute(name: name, createdAt: created, points: parsed.points)
            try store.save(route)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Tulis GPX ke folder sementara untuk dibagikan.
    func exportGPXFile(for route: SavedRoute) -> URL? {
        let safe = route.name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent((safe.isEmpty ? "rute" : safe) + ".gpx")
        do {
            try GPX.export(route).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            lastError = "Gagal membuat file GPX: \(error.localizedDescription)"
            return nil
        }
    }
}
