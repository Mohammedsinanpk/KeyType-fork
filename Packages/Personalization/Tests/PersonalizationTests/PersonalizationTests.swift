import Prompting
import XCTest
@testable import Personalization

final class PersonalizationTests: XCTestCase {

    // MARK: - Encrypted store

    private func makeTempStore() throws -> (PersistentWritingHistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-history-\(UUID().uuidString).sqlcipher")
        let store = try PersistentWritingHistoryStore(databaseURL: url, passphrase: "test-passphrase-abcdef")
        return (store, url)
    }

    func testPersistentStoreRecordsQueriesAndClears() throws {
        let (store, url) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.record(WritingHistorySample(
            text: "The quarterly report is due on Friday afternoon.",
            appBundleIdentifier: "com.app.mail"
        ))
        store.record(WritingHistorySample(text: "short", appBundleIdentifier: "com.app.mail"))
        store.record(WritingHistorySample(
            text: "Remember to water the plants every morning.",
            appBundleIdentifier: "com.app.notes"
        ))

        XCTAssertEqual(store.count(), 3)

        let mail = store.samples(for: WritingHistoryQuery(
            bundleIdentifier: "com.app.mail",
            minimumCharacters: 12
        ))
        XCTAssertTrue(mail.contains("The quarterly report is due on Friday afternoon."))
        XCTAssertFalse(mail.contains("short"), "below minimumCharacters should be excluded")

        store.clearAll()
        XCTAssertEqual(store.count(), 0)
        XCTAssertTrue(store.samples(for: WritingHistoryQuery(bundleIdentifier: "com.app.mail")).isEmpty)
    }

    func testPersistentStoreDedupesIdenticalSample() throws {
        let (store, url) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let sample = WritingHistorySample(
            text: "Thanks so much for the thoughtful feedback.",
            appBundleIdentifier: "com.app.mail"
        )
        store.record(sample)
        store.record(sample)
        XCTAssertEqual(store.count(), 1, "identical text in the same app should not duplicate")
    }

    func testEncryptedFileIsNotReadableAsPlainText() throws {
        let (store, url) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.record(WritingHistorySample(
            text: "SECRET-MARKER-1234567890 confidential note",
            appBundleIdentifier: "com.app.notes"
        ))
        let data = try Data(contentsOf: url)
        XCTAssertFalse(
            data.range(of: Data("SECRET-MARKER".utf8)) != nil,
            "stored text must not appear in plaintext on disk"
        )
    }

    // MARK: - Selection / budget

    func testSelectionRespectsTokenBudget() {
        let entries = (0..<10).map { i in
            WritingHistorySample(
                text: "Sample number \(i): " + String(repeating: "x", count: 90),
                appBundleIdentifier: "com.app",
                updatedAt: Date().addingTimeInterval(Double(i))
            )
        }
        // Each text is ~100 chars (~26 tokens); a 30-token budget fits only one.
        let query = WritingHistoryQuery(
            bundleIdentifier: "com.app",
            minimumCharacters: 1,
            longestCount: 0,
            mostRecentCount: 10,
            crossAppRecentCount: 0,
            tokenBudget: 30
        )
        let result = WritingHistorySelection.select(from: entries, query: query)
        XCTAssertEqual(result.count, 1, "token budget should cap the number of samples")
    }

    func testSelectionPrefersSameAppRecent() {
        let now = Date()
        let entries = [
            WritingHistorySample(text: "Older note from this same app here.", appBundleIdentifier: "com.app", updatedAt: now.addingTimeInterval(-100)),
            WritingHistorySample(text: "Newer note from this same app here.", appBundleIdentifier: "com.app", updatedAt: now),
            WritingHistorySample(text: "A note from a different app entirely.", appBundleIdentifier: "com.other", updatedAt: now)
        ]
        let result = WritingHistorySelection.select(from: entries, query: WritingHistoryQuery(
            bundleIdentifier: "com.app",
            minimumCharacters: 1,
            longestCount: 0,
            mostRecentCount: 1,
            crossAppRecentCount: 0
        ))
        XCTAssertEqual(result, ["Newer note from this same app here."])
    }

    // MARK: - Telemetry

    func testTelemetryRatesAndPercentiles() {
        let telemetry = CompletionTelemetryStore(url: nil)
        (0..<4).forEach { _ in telemetry.recordShown() }
        telemetry.recordSuppressed(reason: "displayWidthExceeded")
        telemetry.recordSuppressed(reason: "noCandidate")
        telemetry.recordAccepted()
        telemetry.recordAccepted()
        for ms in stride(from: 10.0, through: 100.0, by: 10.0) {
            telemetry.recordLatency(milliseconds: ms)
        }

        let s = telemetry.snapshot()
        XCTAssertEqual(s.generatedCount, 6)
        XCTAssertEqual(s.shownCount, 4)
        XCTAssertEqual(s.suppressedCount, 2)
        XCTAssertEqual(s.acceptedCount, 2)
        XCTAssertEqual(s.acceptanceRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s.suppressionRate, 2.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(s.latencySampleCount, 10)
        XCTAssertGreaterThan(s.latencyMillisP95, s.latencyMillisP50)
    }

    func testTelemetryClearResets() {
        let telemetry = CompletionTelemetryStore(url: nil)
        telemetry.recordShown()
        telemetry.recordAccepted()
        telemetry.clearAll()
        let s = telemetry.snapshot()
        XCTAssertEqual(s.generatedCount, 0)
        XCTAssertEqual(s.shownCount, 0)
        XCTAssertEqual(s.acceptedCount, 0)
    }

    func testTelemetryPersistsAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keytype-telemetry-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = CompletionTelemetryStore(url: url)
        first.recordShown()
        first.recordAccepted()

        let second = CompletionTelemetryStore(url: url)
        let s = second.snapshot()
        XCTAssertEqual(s.shownCount, 1)
        XCTAssertEqual(s.acceptedCount, 1)
    }

    // MARK: - Threshold tuner

    func testTunerNeutralBelowMinimumSamples() {
        let snapshot = TelemetrySnapshot(generatedCount: 5, shownCount: 1, suppressedCount: 4, acceptedCount: 0)
        XCTAssertEqual(ThresholdTuner.adjustments(for: snapshot), .neutral)
    }

    func testTunerRelaxesWhenSuppressionHighAcceptanceLow() {
        let snapshot = TelemetrySnapshot(generatedCount: 100, shownCount: 10, suppressedCount: 90, acceptedCount: 1)
        let a = ThresholdTuner.adjustments(for: snapshot)
        XCTAssertGreaterThan(a.relativeCutoffDelta, 0, "should widen the search")
        XCTAssertLessThan(a.minBranchProbabilityScale, 1, "should lower the probability floor")
    }

    func testTunerTightensWhenAcceptanceHigh() {
        let snapshot = TelemetrySnapshot(generatedCount: 100, shownCount: 80, suppressedCount: 20, acceptedCount: 64)
        let a = ThresholdTuner.adjustments(for: snapshot)
        XCTAssertLessThan(a.relativeCutoffDelta, 0)
        XCTAssertGreaterThan(a.minBranchProbabilityScale, 1)
    }

    func testTunerClampsWithinBounds() {
        let snapshot = TelemetrySnapshot(generatedCount: 1000, shownCount: 10, suppressedCount: 990, acceptedCount: 0)
        let a = ThresholdTuner.adjustments(for: snapshot)
        XCTAssertLessThanOrEqual(abs(a.relativeCutoffDelta), ThresholdTuner.maxCutoffDelta)
        XCTAssertGreaterThanOrEqual(a.minBranchProbabilityScale, ThresholdTuner.minProbabilityScale)
        XCTAssertLessThanOrEqual(a.minBranchProbabilityScale, ThresholdTuner.maxProbabilityScale)
    }

    // MARK: - Keychain

    func testKeychainPassphraseRoundTripIfAvailable() throws {
        let service = "com.pattonium.KeyType.tests.\(UUID().uuidString)"
        let account = "test"
        do {
            let first = try KeychainPassphrase.loadOrCreate(service: service, account: account)
            let second = try KeychainPassphrase.loadOrCreate(service: service, account: account)
            XCTAssertEqual(first, second, "passphrase must be stable across calls")
            XCTAssertEqual(first.count, 64, "32 random bytes hex-encoded")
            try KeychainPassphrase.delete(service: service, account: account)
            XCTAssertNil(try KeychainPassphrase.load(service: service, account: account))
        } catch {
            throw XCTSkip("Keychain unavailable in this environment: \(error)")
        }
    }
}
