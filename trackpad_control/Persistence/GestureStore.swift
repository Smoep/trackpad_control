import Foundation

@Observable
final class GestureStore {
    static let shared = GestureStore()

    private(set) var gestures: [GestureDefinition] = []
    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TrackpadControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("gestures.json")
        load()
    }

    // MARK: - CRUD

    func add(_ gesture: GestureDefinition) {
        gestures.append(gesture)
        save()
    }

    func update(_ gesture: GestureDefinition) {
        if let i = gestures.firstIndex(where: { $0.id == gesture.id }) {
            gestures[i] = gesture
            save()
        }
    }

    func delete(_ gesture: GestureDefinition) {
        gestures.removeAll { $0.id == gesture.id }
        save()
    }

    func toggleEnabled(_ gesture: GestureDefinition) {
        if let i = gestures.firstIndex(where: { $0.id == gesture.id }) {
            gestures[i].isEnabled.toggle()
            save()
        }
    }

    func saveOrAdd(_ gesture: GestureDefinition) {
        if gestures.contains(where: { $0.id == gesture.id }) {
            update(gesture)
        } else {
            add(gesture)
        }
    }

    // MARK: - Import / Export

    func exportURL() -> URL { fileURL }

    func exportData() -> Data? {
        try? JSONEncoder().encode(gestures)
    }

    func importData(_ data: Data) throws {
        let decoded = try JSONDecoder().decode([GestureDefinition].self, from: data)
        gestures = decoded
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(gestures)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[GestureStore] Save failed: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // First launch — seed with mock data
            gestures = GestureDefinition.mockData
            save()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            gestures = try JSONDecoder().decode([GestureDefinition].self, from: data)
        } catch {
            print("[GestureStore] Load failed: \(error)")
            gestures = []
        }
    }
}
