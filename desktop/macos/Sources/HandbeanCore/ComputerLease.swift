import CoreGraphics
import Foundation

/// One native host owns the desktop lane across all BEAM conversations.
/// Receipts are producer-local, monotonic, one-use and exact-window bound.
public struct ComputerLease {
    public enum Refusal: Error { case busy, stale, invalidPoint }
    public struct Observation {
        public let rect: CGRect
        public let pixels: CGSize
        let id: String
        public let createdAt: TimeInterval

        public func point(x: Double, y: Double) throws -> CGPoint {
            guard x.isFinite, y.isFinite, x >= 0, y >= 0,
                  x < pixels.width, y < pixels.height else { throw Refusal.invalidPoint }
            return CGPoint(x: rect.minX + x * rect.width / pixels.width,
                           y: rect.minY + y * rect.height / pixels.height)
        }
    }
    public private(set) var session: String?
    public private(set) var generation: UInt64 = 0
    private var observation: Observation?
    public init() {}

    public mutating func claim(session: String) throws {
        guard self.session == nil || self.session == session else { throw Refusal.busy }
        if self.session == nil { generation &+= 1; self.session = session }
    }
    public mutating func stop(session: String? = nil) {
        guard session == nil || self.session == session else { return }
        self.session = nil
        observation = nil
        generation &+= 1
    }
    public func valid(session: String, generation: UInt64) -> Bool {
        self.session == session && self.generation == generation
    }
    public mutating func observe(rect: CGRect, pixels: CGSize, now: TimeInterval) -> String {
        let id = UUID().uuidString
        observation = Observation(rect: rect, pixels: pixels, id: id, createdAt: now)
        return id
    }
    public mutating func consume(receipt: String, rect: CGRect, now: TimeInterval) throws -> Observation {
        let value = observation
        observation = nil
        guard let value, value.id == receipt, value.rect == rect,
              now >= value.createdAt, now - value.createdAt < 30 else { throw Refusal.stale }
        return value
    }
}
