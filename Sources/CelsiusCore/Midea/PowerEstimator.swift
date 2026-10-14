import Foundation

/// How much power the unit is drawing, worked out from its lifetime energy counter.
public struct PowerReading: Sendable, Equatable {
    /// Why the current measurement began. Eco and mode changes start it over, so the figure shows
    /// what the unit draws in the new setting instead of an average blended with the old one.
    public enum Restart: Sendable, Equatable {
        case started, ecoOn, ecoOff, modeChanged
    }

    /// `nil` while there is nothing to go on yet.
    public var watts: Double?
    /// False while the figure leans on earlier sessions or on too few counter steps.
    public var isMeasured: Bool
    /// Energy counted since the measurement began, in kWh.
    public var energy: Double
    public var since: Date
    public var restart: Restart

    public init(watts: Double?, isMeasured: Bool, energy: Double, since: Date, restart: Restart) {
        self.watts = watts
        self.isMeasured = isMeasured
        self.energy = energy
        self.since = since
        self.restart = restart
    }
}

/// Turns samples of the 0.01 kWh energy counter into a power figure.
///
/// The counter only says that another 10 Wh went by, so power comes from the time between steps:
/// each step is placed halfway between the sample before it and the sample that saw it, and the
/// figure is the energy over the last few steps divided by the time they took. Two more rules keep it
/// responsive: right after a restart it shows the last measured figure for the same setting
/// (marked as not measured yet), and a long wait without a step caps the figure, because fewer than
/// 10 Wh went by in that time.
struct PowerEstimator {
    struct Condition: Equatable {
        var eco: Bool
        var mode: UInt8

        var key: String { "\(mode)-\(eco ? "eco" : "normal")" }
    }

    /// One step of the counter, in kWh.
    static let step = 0.01
    /// Steps used for the figure; older ones are dropped so it follows the compressor as it slows down.
    static let window = 8
    /// Steps needed before the figure counts as measured (two full intervals between them).
    static let stepsToMeasure = 3
    /// With no figure at all, the cap from a quiet counter is shown once it has been quiet this long.
    static let quietBeforeCap: TimeInterval = 10 * 60

    private struct Edge {
        var date: Date
        var counter: Double
    }

    private struct Segment {
        var condition: Condition
        var restart: PowerReading.Restart
        var start: Date
        var startCounter: Double
        var lastCounter: Double
        var lastSample: Date
        var edges: [Edge] = []
    }

    private var segment: Segment?
    /// Last measured watts per setting, shown right after a restart.
    private(set) var history: [String: Double]

    init(history: [String: Double] = [:]) {
        self.history = history
    }

    mutating func record(at date: Date, counter: Double, isOn: Bool, condition: Condition) -> PowerReading? {
        guard isOn else {
            segment = nil
            return nil
        }
        if var current = segment, current.condition == condition, counter >= current.lastCounter {
            if counter > current.lastCounter {
                let midpoint = current.lastSample.addingTimeInterval(date.timeIntervalSince(current.lastSample) / 2)
                current.edges.append(Edge(date: midpoint, counter: counter))
                if current.edges.count > Self.window { current.edges.removeFirst() }
            }
            current.lastCounter = counter
            current.lastSample = date
            segment = current
        } else {
            segment = Segment(
                condition: condition, restart: restart(from: segment?.condition, to: condition),
                start: date, startCounter: counter, lastCounter: counter, lastSample: date
            )
        }
        return reading(at: date)
    }

    private func restart(from old: Condition?, to new: Condition) -> PowerReading.Restart {
        guard let old else { return .started }
        if old.eco != new.eco { return new.eco ? .ecoOn : .ecoOff }
        return old.mode != new.mode ? .modeChanged : .started
    }

    private mutating func reading(at date: Date) -> PowerReading? {
        guard let segment else { return nil }
        var watts: Double?
        var measured = false
        if let first = segment.edges.first, let last = segment.edges.last, segment.edges.count >= 2 {
            let hours = last.date.timeIntervalSince(first.date) / 3600
            if hours > 0 {
                watts = (last.counter - first.counter) * 1000 / hours
                measured = segment.edges.count >= Self.stepsToMeasure
            }
        }
        if measured, let watts {
            history[segment.condition.key] = watts
        } else if watts == nil {
            watts = history[segment.condition.key]
        }

        // Fewer than 10 Wh went by since the last step (or the start), which caps the draw.
        let quiet = date.timeIntervalSince(segment.edges.last?.date ?? segment.start)
        if quiet > 0 {
            let cap = Self.step * 1000 / (quiet / 3600)
            if let current = watts, current > cap {
                watts = cap
            } else if watts == nil, quiet >= Self.quietBeforeCap {
                watts = cap
            }
        }

        let energy = ((segment.lastCounter - segment.startCounter) * 100).rounded() / 100
        return PowerReading(
            watts: watts, isMeasured: measured, energy: energy, since: segment.start, restart: segment.restart
        )
    }
}
