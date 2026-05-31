//
//  AppDelegate.swift
//  KeyType
//
//  Created by Codex on 5/29/26.
//

import AppKit
import MacContextCapture
import Personalization
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let onboardingWindowID = "onboarding"
    static let settingsWindowID = "settings"
    private static let hasCompletedOnboardingDefaultsKey = "KeyType.hasCompletedOnboarding"

    let permissions = PermissionsManager()
    let settings: SettingsStore
    // One AX tracker feeds the (debug) context capture, the live completion pipeline, and the
    // writing-history recorder.
    private let tracker: AccessibilityContextTracker
    // Shared, encrypted writing-history store + local telemetry. Built once so the recorder (writes)
    // and the prompt path (reads) use the same database connection. See ADR-023.
    let history: WritingHistoryStoring
    let telemetry: CompletionTelemetryStore
    let contextCapture: ContextCaptureController
    let completion: CompletionController
    let historyRecorder: WritingHistoryRecorder
    private let acceptance = CompletionAcceptanceController()
    private var permissionSyncTimer: Timer?
    /// Set once the user has confirmed quitting and the async model teardown is under way, so the
    /// confirmation alert isn't shown twice and `applicationShouldTerminate` doesn't re-prompt.
    private var isTerminating = false

    override init() {
        let tracker = AccessibilityContextTracker()
        self.tracker = tracker
        let settings = SettingsStore()
        self.settings = settings
        let history = KeyTypeModuleGraph.makeWritingHistory()
        let telemetry = CompletionTelemetryStore()
        self.history = history
        self.telemetry = telemetry
        let compatibilityStore = KeyTypeModuleGraph.makeCompatibilityStore(
            userDisabledBundleIdentifiers: settings.perAppDisabled
        )
        self.contextCapture = ContextCaptureController(tracker: tracker)
        self.completion = CompletionController(
            tracker: tracker,
            settings: settings,
            history: history,
            telemetry: telemetry,
            compatibilityStore: compatibilityStore
        )
        self.historyRecorder = WritingHistoryRecorder(
            tracker: tracker,
            store: history,
            settings: settings,
            compatibilityStore: compatibilityStore
        )
        super.init()
        acceptance.completionController = completion
    }

    /// One-action wipe of all on-device personal data: every stored writing sample and the local
    /// telemetry counters. Backs the Settings "Clear all personal data" control. See ADR-023.
    func clearAllPersonalData() {
        history.clearAll()
        telemetry.clearAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Background / agent app: no dock icon. LSUIElement in Info.plist already suppresses the
        // dock icon; making the activation policy explicit guards against alternate launch paths.
        NSApp.setActivationPolicy(.accessory)

        permissions.startMonitoring()
        syncContextCaptureWithPermission()
        startObservingPermissionChanges()

        if shouldShowOnboardingOnLaunch {
            // The SwiftUI scene observes this and calls `openWindow(id:)` for us.
            requestOpenOnboarding()
        }
    }

    /// Start/stop the context tracker so it only runs when AX is actually granted. We poll the
    /// `PermissionsManager` (which itself polls AX status at 1 Hz) once per second; this is a
    /// background, low-frequency check — the tracker itself reacts to AX notifications.
    private func startObservingPermissionChanges() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncContextCaptureWithPermission()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        permissionSyncTimer = timer
    }

    private func syncContextCaptureWithPermission() {
        if permissions.accessibility.isGranted {
            contextCapture.start()
            completion.start()
            historyRecorder.start()
            acceptance.start()
        } else {
            contextCapture.stop()
            completion.stop()
            historyRecorder.stop()
            acceptance.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running as a menu-bar agent even after the onboarding window is dismissed.
        false
    }

    /// Gate every quit path (menu item, ⌘Q) behind a confirmation, then tear the model down before
    /// exiting. The teardown is mandatory, not just polite: llama.cpp's ggml-metal backend aborts in
    /// its process-exit C++ destructors unless the llama context/model were freed first (the GPU
    /// residency-set assert in the crash report). We free them asynchronously, then let termination
    /// proceed via `reply(toApplicationShouldTerminate:)`. See ADR-021.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateNow }

        // The agent has no dock icon, so bring the alert to the front explicitly.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit KeyType?"
        alert.informativeText = "KeyType will stop suggesting completions until you open it again."
        alert.alertStyle = .warning
        // First button is the default (highlighted, triggered by Return) and sits on the right.
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        isTerminating = true
        Task { @MainActor in
            await completion.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func requestOpenOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .keyTypeShouldOpenOnboarding, object: nil)
    }

    func markOnboardingCompleted() {
        UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingDefaultsKey)
    }

    private var shouldShowOnboardingOnLaunch: Bool {
        let defaults = UserDefaults.standard
        let completed = defaults.bool(forKey: Self.hasCompletedOnboardingDefaultsKey)
        // Always show on first run, or whenever Accessibility hasn't been granted yet.
        return !completed || !permissions.accessibility.isGranted
    }
}

extension Notification.Name {
    static let keyTypeShouldOpenOnboarding = Notification.Name("KeyType.shouldOpenOnboarding")
}
