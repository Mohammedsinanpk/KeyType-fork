import Foundation

/// Why a generated completion was not shown. Mirrors the controller's suppression taxonomy as a
/// stable string so telemetry stays decoupled from `AutocompleteCore.SuppressionReason`.
public typealias TelemetrySuppressionReason = String

/// A read-only rollup of local completion telemetry. All counts are device-local; nothing here ever
/// leaves the machine. See ADR-023.
public struct TelemetrySnapshot: Codable, Equatable, Sendable {
    /// Completions that finished generation and were considered for display (`shown + suppressed`).
    public var generatedCount: Int
    /// Completions actually shown as ghost text.
    public var shownCount: Int
    /// Completions suppressed (filtered out or no candidate).
    public var suppressedCount: Int
    /// Shown completions the user accepted (word or full).
    public var acceptedCount: Int
    public var latencyMillisP50: Double
    public var latencyMillisP95: Double
    /// Number of latency samples behind the percentiles.
    public var latencySampleCount: Int

    public init(
        generatedCount: Int = 0,
        shownCount: Int = 0,
        suppressedCount: Int = 0,
        acceptedCount: Int = 0,
        latencyMillisP50: Double = 0,
        latencyMillisP95: Double = 0,
        latencySampleCount: Int = 0
    ) {
        self.generatedCount = generatedCount
        self.shownCount = shownCount
        self.suppressedCount = suppressedCount
        self.acceptedCount = acceptedCount
        self.latencyMillisP50 = latencyMillisP50
        self.latencyMillisP95 = latencyMillisP95
        self.latencySampleCount = latencySampleCount
    }

    /// Accepted / shown. 0 when nothing has been shown yet.
    public var acceptanceRate: Double {
        shownCount > 0 ? Double(acceptedCount) / Double(shownCount) : 0
    }

    /// Suppressed / generated. 0 when nothing has been generated yet. High is expected and fine —
    /// KeyType prefers suppression to a wrong suggestion.
    public var suppressionRate: Double {
        generatedCount > 0 ? Double(suppressedCount) / Double(generatedCount) : 0
    }
}

/// Local-only telemetry for completion acceptance, suppression, and latency.
///
/// Aggregates are persisted as plain JSON in Application Support (they are non-PII counters and a
/// bounded reservoir of latency samples — no captured text). The app feeds the snapshot into
/// `ThresholdTuner` to nudge the decoder, and surfaces it read-only in Settings. Cleared in one
/// action by `clearAll()`.
public final class CompletionTelemetryStore: @unchecked Sendable {
    private struct State: Codable {
        var generatedCount = 0
        var shownCount = 0
        var suppressedCount = 0
        var acceptedCount = 0
        var suppressionReasons: [String: Int] = [:]
        var latenciesMillis: [Double] = []
    }

    private let url: URL?
    private let lock = NSLock()
    private var state: State
    /// Bounded reservoir so the file (and percentile cost) stays small over a long session.
    private let maxLatencySamples = 500

    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("KeyType/Telemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("telemetry.json", isDirectory: false)
    }

    /// Loads persisted telemetry from `url` (defaulting to the standard location). A `nil` URL keeps
    /// telemetry purely in memory (used by tests and as a fallback when the path can't be resolved).
    public init(url: URL? = (try? CompletionTelemetryStore.defaultURL())) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            self.state = decoded
        } else {
            self.state = State()
        }
    }

    // MARK: - Recording

    public func recordShown() {
        mutate {
            $0.generatedCount += 1
            $0.shownCount += 1
        }
    }

    public func recordSuppressed(reason: TelemetrySuppressionReason) {
        mutate {
            $0.generatedCount += 1
            $0.suppressedCount += 1
            $0.suppressionReasons[reason, default: 0] += 1
        }
    }

    public func recordAccepted() {
        mutate { $0.acceptedCount += 1 }
    }

    public func recordLatency(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        mutate {
            $0.latenciesMillis.append(milliseconds)
            if $0.latenciesMillis.count > maxLatencySamples {
                $0.latenciesMillis.removeFirst($0.latenciesMillis.count - maxLatencySamples)
            }
        }
    }

    // MARK: - Reading

    public func snapshot() -> TelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        let latencies = state.latenciesMillis
        return TelemetrySnapshot(
            generatedCount: state.generatedCount,
            shownCount: state.shownCount,
            suppressedCount: state.suppressedCount,
            acceptedCount: state.acceptedCount,
            latencyMillisP50: Self.percentile(latencies, 0.5),
            latencyMillisP95: Self.percentile(latencies, 0.95),
            latencySampleCount: latencies.count
        )
    }

    /// Suppression-reason histogram (for diagnostics / Settings detail).
    public func suppressionReasons() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return state.suppressionReasons
    }

    // MARK: - Clearing

    public func clearAll() {
        lock.lock()
        state = State()
        lock.unlock()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Helpers

    private func mutate(_ body: (inout State) -> Void) {
        lock.lock()
        body(&state)
        let snapshot = state
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ state: State) {
        guard let url else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        let weight = rank - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
