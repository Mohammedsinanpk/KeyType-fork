import AppCompatibility
import AutocompleteCore
import ConstrainedGeneration
import ModelRuntime
import TokenProfiles
import XCTest

/// Deterministic tests for the M5 multi-branch decoder. They use `TreeScriptedModelRuntime`
/// (path-dependent logits) + `InMemoryAutocompleteProfile`, so they run on any machine without
/// a model or profile present.
final class ConstrainedGenerationEngineTests: XCTestCase {

    // MARK: - Fixtures

    private static let testVocabSize = 4096
    private static let testTarget = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private func record(
        _ id: TokenID,
        _ text: String,
        flags: TokenProfileFlags = [],
        width: Int? = nil,
        bias: Float = 0
    ) -> TokenProfileRecord {
        let bytes = Array(text.utf8)
        return TokenProfileRecord(
            tokenID: id,
            bytes: bytes,
            flags: flags,
            staticBias: bias,
            displayWidth: width ?? bytes.count
        )
    }

    private func record(
        _ id: TokenID,
        rawBytes: [UInt8],
        flags: TokenProfileFlags = [],
        width: Int? = nil
    ) -> TokenProfileRecord {
        TokenProfileRecord(
            tokenID: id,
            bytes: rawBytes,
            flags: flags,
            staticBias: 0,
            displayWidth: width ?? rawBytes.count
        )
    }

    private func profile(_ records: [TokenProfileRecord]) -> InMemoryAutocompleteProfile {
        InMemoryAutocompleteProfile(vocabularySize: Self.testVocabSize, records: records)
    }

    private func runtime(
        _ logitsByPath: [[TokenID]: [TokenLogit]],
        eos: TokenID? = nil,
        perCallDelayNanoseconds: UInt64? = nil
    ) -> TreeScriptedModelRuntime {
        TreeScriptedModelRuntime(
            logitsByPath: logitsByPath,
            metadata: ModelMetadata(
                identifier: "tree",
                family: "stub",
                vocabularySize: Self.testVocabSize,
                contextLength: 4096,
                eosTokenID: eos
            ),
            perCallDelayNanoseconds: perCallDelayNanoseconds
        )
    }

    private func request(
        requiredPrefix: [UInt8] = [],
        maxTokens: Int = 2,
        maxWidth: Int = 80,
        afterCursor: String = "",
        target: AppTarget = ConstrainedGenerationEngineTests.testTarget
    ) -> CompletionRequest {
        CompletionRequest(
            context: TextFieldContext(beforeCursor: "", afterCursor: afterCursor, target: target),
            prompt: "",
            requiredPrefixBytes: requiredPrefix,
            mode: .prose,
            maxCompletionTokens: maxTokens,
            maxDisplayWidth: maxWidth
        )
    }

    private func logit(_ id: TokenID, _ value: Float) -> TokenLogit {
        TokenLogit(tokenID: id, logit: value)
    }

    // MARK: - Multi-branch search

    func testMultiBranchReturnsRankedCandidateSet() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(11, "od"), record(21, "st")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0), logit(2, 1.0)],
            [1]: [logit(11, 1.0)],
            [2]: [logit(21, 1.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertEqual(candidates.map(\.text), ["good", "best"])
        XCTAssertGreaterThan(candidates[0].logProbability, candidates[1].logProbability)
        XCTAssertEqual(candidates[0].tokenIDs, [1, 11])
    }

    func testBranchWidthLimitsBeam() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(11, "od"), record(21, "st")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0), logit(2, 1.0)],
            [1]: [logit(11, 1.0)],
            [2]: [logit(21, 1.0)]
        ])
        let config = DecodingConfiguration(branchWidth: 1)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertEqual(candidates.map(\.text), ["good"])
    }

    func testRelativeCutoffPrunesWeakBranch() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(11, "od"), record(21, "st")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0), logit(2, 1.0)],
            [1]: [logit(11, 1.0)],
            [2]: [logit(21, 1.0)]
        ])
        let config = DecodingConfiguration(relativeCutoff: 0.5)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertEqual(candidates.map(\.text), ["good"])
    }

    func testMinBranchProbabilityFloorDropsLowProbabilityToken() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(11, "od"), record(21, "st")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0), logit(2, 1.0)],
            [1]: [logit(11, 1.0)],
            [2]: [logit(21, 1.0)]
        ])
        let config = DecodingConfiguration(minBranchProbability: 0.5)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, configuration: config)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertEqual(candidates.map(\.text), ["good"])
    }

    // MARK: - Required prefix

    func testRequiredPrefixSingleTokenKeepsOnlyMatchingCandidates() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(11, "od"), record(21, "st")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0), logit(2, 1.0)],
            [1]: [logit(11, 1.0)],
            [2]: [logit(21, 1.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(
            for: request(requiredPrefix: Array("b".utf8), maxTokens: 2)
        )

        XCTAssertEqual(candidates.map(\.text), ["best"])
        XCTAssertTrue(candidates.allSatisfy { $0.text.hasPrefix("b") })
    }

    func testRequiredPrefixSpanningMultipleTokens() async throws {
        let profile = profile([
            record(1, "go"), record(2, "be"), record(21, "st"), record(22, "xy")
        ])
        let runtime = runtime([
            []: [logit(1, 1.0), logit(2, 1.0)],
            [2]: [logit(21, 2.0), logit(22, 1.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(
            for: request(requiredPrefix: Array("best".utf8), maxTokens: 2)
        )

        XCTAssertEqual(candidates.map(\.text), ["best"])
    }

    func testUnsatisfiableRequiredPrefixYieldsNothing() async throws {
        let profile = profile([record(1, "go"), record(2, "be")])
        let runtime = runtime([[]: [logit(1, 1.0), logit(2, 1.0)]])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(
            for: request(requiredPrefix: Array("z".utf8), maxTokens: 2)
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Validity / width

    func testInvalidUTF8BranchIsDropped() async throws {
        let profile = profile([
            record(1, "ok"),
            record(2, rawBytes: [0xFF]) // illegal lead byte, never completable
        ])
        let runtime = runtime([[]: [logit(1, 1.0), logit(2, 2.0)]])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 1))

        XCTAssertEqual(candidates.map(\.text), ["ok"])
    }

    func testOverWidthBranchIsDropped() async throws {
        let profile = profile([
            record(1, "ok", width: 2),
            record(2, "abcdefgh", width: 8)
        ])
        let runtime = runtime([[]: [logit(1, 1.0), logit(2, 2.0)]])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 1, maxWidth: 4))

        XCTAssertEqual(candidates.map(\.text), ["ok"])
    }

    // MARK: - Stop conditions

    func testStopsOnEOSAndKeepsPriorText() async throws {
        let profile = profile([record(1, "hello"), record(99, "x")])
        let runtime = runtime(
            [
                []: [logit(1, 2.0)],
                [1]: [logit(900, 5.0), logit(99, 1.0)]
            ],
            eos: 900
        )
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 3))

        XCTAssertEqual(candidates.map(\.text), ["hello"])
        XCTAssertEqual(candidates[0].tokenIDs, [1])
    }

    func testStopAndSuppressFlagTerminatesBranch() async throws {
        let profile = profile([
            record(1, "hello"),
            record(500, "STOP", flags: .stop),
            record(99, "x")
        ])
        let runtime = runtime([
            []: [logit(1, 2.0)],
            [1]: [logit(500, 5.0), logit(99, 1.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 3))

        XCTAssertEqual(candidates.map(\.text), ["hello"])
    }

    func testSentenceBoundaryStopAndDisplayEmitsThenStops() async throws {
        let profile = profile([
            record(1, "Hi"),
            record(3, ".", flags: .sentenceEnd)
        ])
        let runtime = runtime([
            []: [logit(1, 2.0)],
            [1]: [logit(3, 2.0)]
        ])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let candidates = try await engine.completions(for: request(maxTokens: 4))

        XCTAssertEqual(candidates.map(\.text), ["Hi."])
        // Stopped at the sentence end well before maxCompletionTokens.
        XCTAssertEqual(candidates[0].tokenIDs, [1, 3])
    }

    // MARK: - Cancellation

    func testGenerationCancelsPromptlyOnNewRequest() async throws {
        let profile = profile([record(1, "x")])
        // 200 ms per runtime call; we cancel ~30 ms in, so the first `prepare` is interrupted.
        let runtime = runtime([[]: [logit(1, 1.0)]], perCallDelayNanoseconds: 200_000_000)
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile)

        let task = Task { try await engine.completions(for: request(maxTokens: 8)) }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected generation to be cancelled")
        } catch is CancellationError {
            // expected
        }
    }

    // MARK: - Policy gates

    func testCompletionsDisabledSuppresses() async throws {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.testTarget.bundleIdentifier, completionsDisabled: true)
        ])
        let profile = profile([record(1, "x")])
        let runtime = runtime([[]: [logit(1, 1.0)]])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, compatibilityStore: store)

        let candidates = try await engine.completions(for: request(maxTokens: 2))

        XCTAssertTrue(candidates.isEmpty)
    }

    func testMidLineDisabledSuppressesWhenTextFollowsCursor() async throws {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.testTarget.bundleIdentifier, midLineCompletionsDisabled: true)
        ])
        let profile = profile([record(1, "x")])
        let runtime = runtime([[]: [logit(1, 1.0)]])
        let engine = ConstrainedGenerationEngine(runtime: runtime, profile: profile, compatibilityStore: store)

        let candidates = try await engine.completions(for: request(maxTokens: 2, afterCursor: "tail"))

        XCTAssertTrue(candidates.isEmpty)
    }
}
