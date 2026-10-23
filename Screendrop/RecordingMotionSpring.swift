//
//  RecordingMotionSpring.swift
//  Screendrop
//
//  One physically integrated spring, shared by the viewport and pointer
//  timelines so both settle with the same semi-implicit Euler step instead of
//  maintaining two parallel integrators.
//

import Foundation

nonisolated struct SpringConstant: Sendable {
    var tension: Double
    var friction: Double
    var inertia: Double
    var clampsOvershoot: Bool = false
}

nonisolated struct DampedSpring: Sendable {
    var position: Double
    var velocity: Double = 0

    mutating func snap(to value: Double) {
        position = value
        velocity = 0
    }

    mutating func step(toward target: Double, using constant: SpringConstant, dt: Double) {
        guard constant.inertia > 0 else {
            position = target
            velocity = 0
            return
        }
        var remaining = dt
        while remaining > 0 {
            let step = constant.clampsOvershoot ? min(remaining, 0.001) : remaining
            let distance = target - position
            var friction = constant.friction
            if constant.clampsOvershoot, velocity * distance > 0,
               abs(velocity) > abs(distance) * sqrt(constant.tension / constant.inertia) {
                friction = max(friction, 2 * sqrt(constant.inertia * constant.tension))
            }
            let acceleration = (constant.tension * distance - friction * velocity) / constant.inertia
            velocity += acceleration * step
            position += velocity * step
            remaining -= step
        }
    }
}
