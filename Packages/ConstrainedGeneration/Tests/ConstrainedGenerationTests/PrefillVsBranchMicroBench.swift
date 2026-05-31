import AutocompleteCore
@testable import ConstrainedGeneration
import LlamaModelRuntime
import ModelRuntime
import Prompting
import TokenProfiles
import XCTest

/// Temporary micro-benchmark (latency investigation). Separates the *one-time prefill* cost from
/// the *per-branch restore+decode* cost so we can attribute the ~87 ms warm completion latency to
/// either (a) processing the prompt once, or (b) the 12 anchored restore/decode calls the beam
/// makes. Run:
///   swift test --package-path Packages/ConstrainedGeneration --filter PrefillVsBranchMicroBench -c release
final class PrefillVsBranchMicroBench: XCTestCase {
    private static let family = "qwen3-v151936"

    private func load() throws -> LlamaModelRuntime {
        try XCTSkipUnless(ModelContainer.defaultModelExists(), "GGUF missing; skipping")
        return try LlamaModelRuntime(modelURL: try ModelContainer.modelURL(), contextLength: 2048, enableKVFork: true)
    }

    private func seconds(_ block: () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now()
        try await block()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    func testPrefillVsBranchCost() async throws {
        let runtime = try load()
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")
        let before = "I am writing to let you know that the meeting scheduled for tomorrow "
        let prompt = PromptBuilder().buildPrompt(
            context: TextFieldContext(beforeCursor: before, afterCursor: "", target: target, detectedLanguage: "en")
        ).prompt
        let anchor = try runtime.tokenizer.tokenize(prompt)

        // A couple of plausible continuation tokens to feed as branch suffixes.
        let t1 = anchor.last ?? 0
        let t2 = anchor.dropLast().last ?? 0

        // Warm: hot kernels + first prefill.
        await runtime.resetKVCache()
        _ = try await runtime.anchoredLogits(anchor: anchor, suffix: [])

        // 1) Cold full prefill (clear, decode the whole anchor, snapshot, read logits).
        var prefill = 0.0
        let prefillRuns = 5
        for _ in 0..<prefillRuns {
            await runtime.resetKVCache()
            prefill += try await seconds { _ = try await runtime.anchoredLogits(anchor: anchor, suffix: []) }
        }
        prefill /= Double(prefillRuns)

        // Ensure the anchor snapshot is resident for the per-branch measurements below.
        _ = try await runtime.anchoredLogits(anchor: anchor, suffix: [])

        // 2) Cached root (empty suffix): no decode, cached anchor-end logits.
        var root = 0.0
        let rootRuns = 20
        for _ in 0..<rootRuns {
            root += try await seconds { _ = try await runtime.anchoredLogits(anchor: anchor, suffix: []) }
        }
        root /= Double(rootRuns)

        // 3) Per-branch: restore anchor snapshot + decode a 1-token suffix + read logits.
        var branch1 = 0.0
        let branchRuns = 20
        for i in 0..<branchRuns {
            let tok = (i % 2 == 0) ? t1 : t2
            branch1 += try await seconds { _ = try await runtime.anchoredLogits(anchor: anchor, suffix: [tok]) }
        }
        branch1 /= Double(branchRuns)

        // 4) Per-branch with a 3-token suffix (deeper beam level): restore + decode 3 tokens.
        var branch3 = 0.0
        for i in 0..<branchRuns {
            let tok = (i % 2 == 0) ? t1 : t2
            branch3 += try await seconds { _ = try await runtime.anchoredLogits(anchor: anchor, suffix: [tok, t2, t1]) }
        }
        branch3 /= Double(branchRuns)

        // Model a depth-4 width-4 beam: 1 prefill + 1 cached root + 4×(1-tok) + 4×(2-tok) + 4×(3-tok).
        // Approximate the 2-tok cost as the midpoint of branch1 and branch3.
        let branch2 = (branch1 + branch3) / 2
        let modeled = prefill + root + 4 * branch1 + 4 * branch2 + 4 * branch3

        print("\n================ prefill vs per-branch micro-bench ================")
        print(String(format: "  anchor tokens                 : %d", anchor.count))
        print(String(format: "  1) cold full prefill          : %7.2f ms", prefill * 1000))
        print(String(format: "  2) cached root (empty suffix) : %7.2f ms", root * 1000))
        print(String(format: "  3) restore + decode 1 token   : %7.2f ms", branch1 * 1000))
        print(String(format: "  4) restore + decode 3 tokens  : %7.2f ms", branch3 * 1000))
        let marginalPerToken: Double = (branch3 - branch1) / 2
        let restoreOverhead: Double = branch1 - marginalPerToken
        let branchShare: Double = 4 * branch1 + 4 * branch2 + 4 * branch3
        print(String(format: "     → marginal cost / token     : %7.2f ms (decode-bound part)", marginalPerToken * 1000))
        print(String(format: "     → restore + fixed overhead  : %7.2f ms (branch1 minus 1 token)", restoreOverhead * 1000))
        print(String(format: "  modeled depth4xwidth4 total   : %7.2f ms", modeled * 1000))
        print(String(format: "     prefill share              : %5.1f%%", prefill / modeled * 100))
        print(String(format: "     12 branch expansions       : %5.1f%%", branchShare / modeled * 100))
        print("==================================================================\n")

        await runtime.shutdown()
    }
}
