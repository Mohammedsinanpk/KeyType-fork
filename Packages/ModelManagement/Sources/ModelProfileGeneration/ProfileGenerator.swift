import Foundation
import LlamaModelRuntime
import ModelManagement
import ModelRuntime
import ProfileBuilderCore
import TokenProfiles
import os

/// Builds the ACPF token profile (`<family>.acpf.bin`) that the constrained decoder needs, by
/// reading the downloaded GGUF's tokenizer in-process.
///
/// This is the in-app equivalent of the `acpf-build` CLI: it loads the model with a tiny context,
/// drives `BuildProfile.run` over a `LlamaVocabIntrospector`, writes the profile next to the GGUF,
/// then frees the llama context/model up front (ggml-metal asserts at process exit if the GPU
/// residency sets were never released — see ADR-021). The work is heavy (it touches every token),
/// so it runs off the main actor.
public enum ProfileGenerator {

    public enum GenerationError: Error, CustomStringConvertible {
        case modelMissing(String)
        public var description: String {
            switch self {
            case let .modelMissing(name):
                return "Model file '\(name)' not found in the Models directory."
            }
        }
    }

    /// Ensures an ACPF profile exists for `filename`'s tokenizer family. Returns the resolved
    /// family. A no-op (returns the family) when the profile is already present.
    @discardableResult
    public static func generateProfileIfNeeded(forModelFilename filename: String) async throws -> String {
        let log = Logger(subsystem: "com.pattonium.KeyType", category: "profile-generation")
        let modelURL = try ModelContainer.modelURL(filename: filename)
        guard ModelContainer.modelExists(at: modelURL) else {
            throw GenerationError.modelMissing(filename)
        }

        // A small context is plenty: the builder only reads tokenizer metadata, it does not decode.
        let runtime = try LlamaModelRuntime(modelURL: modelURL, contextLength: 256, reuseThreshold: 0)
        defer { Task { await runtime.shutdown() } }

        let vocabSize = runtime.metadata.vocabularySize
        let family = ModelFamilyResolver.family(forFilename: filename, vocabSize: vocabSize)
        let outputURL = try ModelContainer.profileURL(family: family, create: true)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            log.info("ACPF profile for family \(family, privacy: .public) already present; skipping build")
            return family
        }

        log.info("Building ACPF profile for \(filename, privacy: .public) (family \(family, privacy: .public))")
        let introspector = runtime.makeIntrospector()
        try BuildProfile.run(
            introspector: introspector,
            family: family,
            output: outputURL,
            reporter: ConsoleReporter(isQuiet: true)
        )
        log.info("ACPF profile written to \(outputURL.path, privacy: .public)")
        return family
    }
}
