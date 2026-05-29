import AutocompleteCore
import Foundation
import ModelRuntime
import TokenProfiles

/// A single admissible next-token candidate after masking, biasing, temperature, and
/// top-k / top-p shaping. `probability` is the softmax probability over the admissible
/// (post-bias, post-temperature) distribution; `logProbability` is its natural log and is
/// what the engine accumulates into a branch's cumulative score.
struct RankedToken: Equatable {
    var tokenID: TokenID
    var probability: Float
    var logProbability: Float
}

/// Pure transformation from raw next-token logits to a ranked, admissible candidate pool.
///
/// Order of operations: drop excluded + inadmissible tokens, add the profile's static/mode
/// bias, divide by temperature, softmax over the surviving set, then top-k, top-p (nucleus),
/// and finally a `minBranchProbability` floor. Deterministic — no RNG (see ADR-010).
enum TokenSampler {
    static func rank(
        logits: [TokenLogit],
        mode: CompletionMode,
        profile: AutocompleteProfile,
        configuration: DecodingConfiguration,
        isAdmissible: (TokenID) -> Bool
    ) -> [RankedToken] {
        guard !logits.isEmpty else { return [] }
        let temperature = max(configuration.temperature, 1e-3)

        // 1. Mask + bias + temperature-scale the admissible tokens.
        var scaled: [(tokenID: TokenID, value: Float)] = []
        scaled.reserveCapacity(min(logits.count, configuration.topK * 4))
        for logit in logits {
            let id = logit.tokenID
            if profile.isExcluded(id, mode: mode) { continue }
            if !isAdmissible(id) { continue }
            let biased = logit.logit + profile.bias(for: id, mode: mode)
            scaled.append((id, biased / temperature))
        }
        guard !scaled.isEmpty else { return [] }

        // 2. Softmax over the admissible set (max-shift for numerical stability).
        let maxValue = scaled.reduce(scaled[0].value) { Swift.max($0, $1.value) }
        var expSum: Float = 0
        var exps = [Float](repeating: 0, count: scaled.count)
        for i in scaled.indices {
            let e = Foundation.exp(scaled[i].value - maxValue)
            exps[i] = e
            expSum += e
        }
        guard expSum > 0 else { return [] }

        var ranked: [RankedToken] = scaled.indices.map { i in
            let p = exps[i] / expSum
            return RankedToken(tokenID: scaled[i].tokenID, probability: p, logProbability: Foundation.log(p))
        }

        // 3. Highest probability first (tie-break by token id for determinism).
        ranked.sort { lhs, rhs in
            lhs.probability != rhs.probability
                ? lhs.probability > rhs.probability
                : lhs.tokenID < rhs.tokenID
        }

        // 4. top-k.
        if configuration.topK > 0 && ranked.count > configuration.topK {
            ranked.removeLast(ranked.count - configuration.topK)
        }

        // 5. top-p (nucleus) — always keep at least the single best.
        if configuration.topP < 1 {
            var cumulative: Float = 0
            var cutoff = ranked.count
            for (i, token) in ranked.enumerated() {
                cumulative += token.probability
                if cumulative >= configuration.topP {
                    cutoff = i + 1
                    break
                }
            }
            if cutoff < ranked.count {
                ranked.removeLast(ranked.count - cutoff)
            }
        }

        // 6. minBranchProbability floor (keep at least the best so a sharp distribution
        //    still yields a candidate).
        if configuration.minBranchProbability > 0 && ranked.count > 1 {
            let kept = ranked.prefix { $0.probability >= configuration.minBranchProbability }
            ranked = kept.isEmpty ? Array(ranked.prefix(1)) : Array(kept)
        }

        return ranked
    }
}
