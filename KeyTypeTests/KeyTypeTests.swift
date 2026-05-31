//
//  KeyTypeTests.swift
//  KeyTypeTests
//
//  Created by John Bean on 5/29/26.
//

import Testing
@testable import KeyType

struct KeyTypeTests {

    @Test func adaptiveDebounceUsesFastPathAfterResponsiveGeneration() {
        #expect(CompletionController.adaptiveDebounceNanoseconds(lastGenerationLatencyMs: 35) == 35_000_000)
    }

    @Test func adaptiveDebounceKeepsConservativeDelayAfterSlowGeneration() {
        #expect(CompletionController.adaptiveDebounceNanoseconds(lastGenerationLatencyMs: 180) == 90_000_000)
    }

    @Test func adaptiveDebounceStartsAtModerateDelayBeforeTelemetry() {
        #expect(CompletionController.adaptiveDebounceNanoseconds(lastGenerationLatencyMs: nil) == 50_000_000)
    }

}
