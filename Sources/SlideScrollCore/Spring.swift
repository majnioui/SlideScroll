import Foundation

/// A critically damped spring for one coordinate. Retargeting mid-flight keeps
/// the current velocity, so rapid key presses and swipe releases chain smoothly.
public struct Spring: Equatable {
    public var value: Double
    public var velocity: Double
    public var target: Double
    /// Higher is snappier. Settling time is roughly `6 / sqrt(stiffness)` seconds.
    public var stiffness: Double

    public init(_ value: Double) {
        self.value = value
        velocity = 0
        target = value
        stiffness = layoutStiffness
    }

    /// Close enough to snap to the target. Windows move in whole points, so
    /// the last point of a critically damped ease-out would otherwise creep
    /// in over several frames, which looks like a stutter.
    public var isSettled: Bool {
        abs(value - target) < 1.0 && abs(velocity) < 20.0
    }

    public mutating func step(_ dt: Double) {
        if isSettled {
            value = target
            velocity = 0
            return
        }
        let damping = 2.0 * stiffness.squareRoot()
        let n = max((dt / maxSubstep).rounded(.up), 1)
        let h = dt / n
        for _ in 0..<Int(n) {
            let accel = stiffness * (target - value) - damping * velocity
            velocity += accel * h
            value += velocity * h
        }
    }
}

/// Layout changes (focus, close, reorder): ~0.35s with a soft ease-out.
public let layoutStiffness = 300.0
/// Following the fingers during a swipe: smooths uneven input, ~30ms behind.
public let followStiffness = 3000.0

/// Largest integration step; stiff springs go unstable with bigger ones.
private let maxSubstep = 1.0 / 480.0
