import AutocompleteCore
import CoreGraphics
import XCTest
@testable import AppCompatibility

final class AppCompatibilityTests: XCTestCase {
    func testDomainOverrideMatchesSubdomainAndAppliesGoogleDocsWorkarounds() {
        let target = AppTarget(
            bundleIdentifier: "com.microsoft.edgemac",
            appName: "Edge",
            domain: "www.docs.google.com"
        )
        let context = TextFieldContext(
            beforeCursor: "hello",
            geometry: TextFieldGeometry(cursorRect: .zero, cursorRectQuality: .exact),
            target: target,
            traits: TextFieldTraits(isWebField: true)
        )

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.allowsTabAcceptance)
        XCTAssertTrue(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertTrue(policy.insertionRequiresBackspaceAfterPaste)
        XCTAssertEqual(policy.overlayPreference, .textMirror)
        XCTAssertEqual(policy.fontSizeAdjustmentFactor, 0.96, accuracy: 0.001)
        XCTAssertFalse(policy.customInstructions.isEmpty)
    }

    func testTerminalPolicySuppressesTabAcceptanceAndUsesTerminalMode() {
        let target = AppTarget(bundleIdentifier: "com.googlecode.iterm2", appName: "iTerm2")
        let context = TextFieldContext(
            beforeCursor: "git sta",
            target: target,
            traits: TextFieldTraits(isTerminalLike: true)
        )

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertFalse(policy.allowsMidLineCompletion)
        XCTAssertFalse(policy.allowsTabAcceptance)
        XCTAssertFalse(policy.allowsTrainingDataCollection)
        XCTAssertFalse(policy.includesEnvironmentContext)
        XCTAssertEqual(policy.completionMode, .terminal)
    }

    func testCursorUsesCodeEditorPolicy() {
        let target = AppTarget(bundleIdentifier: "com.todesktop.230313mzl4w4u92", appName: "Cursor")
        let context = TextFieldContext(beforeCursor: "let value = cur", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.allowsTabAcceptance)
        XCTAssertFalse(policy.includesEnvironmentContext)
        XCTAssertEqual(policy.overlayPreference, .inline)
        XCTAssertEqual(policy.completionMode, .prose)
    }

    func testWeChatUsesChatSurfacePolicy() {
        let target = AppTarget(bundleIdentifier: "com.tencent.xinWeChat", appName: "WeChat")
        let context = TextFieldContext(beforeCursor: "sounds good, I can", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.isCompletionEnabled)
        XCTAssertTrue(policy.allowsTabAcceptance)
        XCTAssertEqual(policy.stringInjectionChunkSize, 8)
        XCTAssertFalse(policy.insertionRequiresPasteAndMatchStyle)
        XCTAssertEqual(policy.overlayPreference, .inline)
        XCTAssertEqual(policy.completionMode, .prose)
        XCTAssertEqual(policy.customInstructions, [
            "Continue the current WeChat message only. Keep it short and conversational."
        ])
    }

    func testPasswordManagerBundleIsSecureExcluded() {
        let target = AppTarget(bundleIdentifier: "com.1password.1password", appName: "1Password")
        let context = TextFieldContext(beforeCursor: "sec", target: target)

        let policy = AppCompatibilityStore().policy(for: context)

        XCTAssertTrue(policy.excludesSecureField)
        XCTAssertFalse(policy.isCompletionEnabled)
        XCTAssertFalse(policy.allowsTabAcceptance)
        XCTAssertEqual(policy.overlayPreference, .hidden)
    }

    func testPasswordFieldHintsAreSecureExcludedInAnyApp() {
        let target = AppTarget(bundleIdentifier: "com.google.Chrome", appName: "Chrome")
        let context = TextFieldContext(
            beforeCursor: "hunter",
            target: target,
            placeholder: "Password",
            labels: ["Account password"]
        )

        let policy = AppCompatibilityStore(overrides: []).policy(for: context)

        XCTAssertTrue(policy.excludesSecureField)
        XCTAssertFalse(policy.isCompletionEnabled)
        XCTAssertFalse(policy.allowsTabAcceptance)
        XCTAssertFalse(policy.allowsTrainingDataCollection)
    }

    func testUserPerAppDisableOverridesDefaultEnabledPolicy() {
        let target = AppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
        let context = TextFieldContext(beforeCursor: "hello there", target: target)

        // By default TextEdit allows completions.
        XCTAssertTrue(AppCompatibilityStore().policy(for: context).isCompletionEnabled)

        // A user-chosen per-app disable (from Settings) must turn it off.
        let store = AppCompatibilityStore(
            userDisabledBundleIdentifiers: ["com.apple.TextEdit"]
        )
        let policy = store.policy(for: context)
        XCTAssertFalse(policy.isCompletionEnabled)
        XCTAssertFalse(policy.allowsTabAcceptance)
        XCTAssertFalse(policy.allowsTrainingDataCollection)
    }

    func testUserPerAppDisableLeavesOtherAppsUnaffected() {
        let store = AppCompatibilityStore(
            userDisabledBundleIdentifiers: ["com.apple.TextEdit"]
        )
        let other = AppTarget(bundleIdentifier: "com.apple.Notes", appName: "Notes")
        let context = TextFieldContext(beforeCursor: "hello there", target: other)
        XCTAssertTrue(store.policy(for: context).isCompletionEnabled)
    }

    func testEstimatedWebCaretKeepsInlineOverlayPreference() {
        let target = AppTarget(bundleIdentifier: "com.google.Chrome", appName: "Chrome", domain: "example.com")
        let context = TextFieldContext(
            beforeCursor: "hello",
            geometry: TextFieldGeometry(cursorRect: .zero, cursorRectQuality: .estimated),
            target: target,
            traits: TextFieldTraits(isWebField: true)
        )

        let policy = AppCompatibilityStore(overrides: []).policy(for: context)

        XCTAssertEqual(policy.overlayPreference, .inline)
    }
}
