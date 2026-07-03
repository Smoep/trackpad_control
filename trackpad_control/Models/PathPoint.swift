import Foundation

struct PathPoint: Codable, Identifiable, Sendable {
    var id = UUID()
    var x: Double
    var y: Double
    var timestamp: TimeInterval

    init(x: Double, y: Double, timestamp: TimeInterval = 0) {
        self.x = x
        self.y = y
        self.timestamp = timestamp
    }
}
