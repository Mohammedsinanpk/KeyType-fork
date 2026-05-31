//
//  ScreenTextOCR.swift
//  MacContextCapture
//
//  Vision text recognition over a captured window image, plus a pure post-processor that turns the
//  recognised lines into a compact, length-capped block suitable for the prompt's `[Screen context]`
//  section. The post-processor is ScreenCaptureKit/Vision-free so it can be unit-tested directly.
//

import CoreGraphics
import Foundation
import Vision

public enum ScreenTextOCR {
    /// Recognise text in `image`, returning the recognised lines in natural reading order
    /// (top-to-bottom, then left-to-right). Uses `.fast` recognition with language correction off
    /// for latency — this feeds an LLM prompt, not a transcription, so perfect accuracy isn't needed.
    public static func recognizeLines(in image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .sorted { lhs, rhs in
                        // Vision bounding boxes are normalised with a bottom-left origin (y up), so
                        // higher y is nearer the top of the window. Group roughly by line, then by x.
                        if abs(lhs.boundingBox.origin.y - rhs.boundingBox.origin.y) > 0.01 {
                            return lhs.boundingBox.origin.y > rhs.boundingBox.origin.y
                        }
                        return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
                    }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Collapse recognised lines into a trimmed, de-blanked block capped to `maxLines` lines and
    /// `maxChars` characters. The prompt builder's section budget trims further; this just keeps the
    /// raw payload bounded so a busy screen never balloons the prompt.
    public static func cleanedText(fromLines lines: [String], maxLines: Int, maxChars: Int) -> String {
        var kept: [String] = []
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            kept.append(trimmed)
            if kept.count >= maxLines { break }
        }
        let joined = kept.joined(separator: "\n")
        guard joined.count > maxChars else { return joined }
        return String(joined.prefix(maxChars))
    }
}
