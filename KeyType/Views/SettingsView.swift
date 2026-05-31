//
//  SettingsView.swift
//  KeyType
//
//  The KeyType Settings window: model selection, completion length, per-app toggles, and the
//  privacy switches that gate sensitive context. History/clipboard/OCR are off by default and a
//  single "Clear all personal data" action wipes the encrypted history store + local telemetry.
//  Read-only stats surface the local acceptance/suppression/latency telemetry. See ADR-023.
//

import AppKit
import ModelRuntime
import Personalization
import SwiftUI

struct SettingsView: View {
    let settings: SettingsStore
    let telemetry: CompletionTelemetryStore
    let clearPersonalData: () -> Void

    @State private var snapshot: TelemetrySnapshot = TelemetrySnapshot()
    @State private var availableModels: [String] = []
    @State private var runningApps: [RunningApp] = []
    @State private var showClearConfirmation = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            modelSection(settings: $settings)
            lengthSection(settings: $settings)
            privacySection(settings: $settings)
            perAppSection(settings: $settings)
            statsSection
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .task { refresh() }
    }

    // MARK: - Sections

    @ViewBuilder
    private func modelSection(settings: Bindable<SettingsStore>) -> some View {
        Section("Model") {
            if availableModels.isEmpty {
                Text("No models found in Application Support/KeyType/Models.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Completion model", selection: settings.selectedModelFilename) {
                    Text("Default (\(ModelContainer.defaultModelFilename))").tag(String?.none)
                    ForEach(availableModels, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                Text("Changes take effect the next time the model loads.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func lengthSection(settings: Bindable<SettingsStore>) -> some View {
        Section("Completion length") {
            Picker("Length", selection: settings.completionLength) {
                ForEach(CompletionLength.allCases) { length in
                    Text(length.title).tag(length)
                }
            }
            .pickerStyle(.segmented)
            Text("Shorter completions are more conservative; longer ones suggest more at once.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func privacySection(settings: Bindable<SettingsStore>) -> some View {
        Section("Privacy") {
            Toggle(isOn: settings.historyEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Personalize from my writing history")
                    Text("Stores recent typing locally (encrypted) to improve suggestions. Off by default.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: settings.clipboardEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use clipboard as context")
                    Text("Includes clipboard text in the prompt. Off by default.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: settings.ocrEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use on-screen text (OCR) as context")
                    Text("Reads nearby visible text when Screen Recording is granted. Off by default.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Text("Clear all personal data…")
            }
            .confirmationDialog(
                "Clear all personal data?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear everything", role: .destructive) {
                    clearPersonalData()
                    refresh()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes all stored writing history and local telemetry from this device. This cannot be undone.")
            }
        }
    }

    @ViewBuilder
    private func perAppSection(settings: Bindable<SettingsStore>) -> some View {
        Section("Per-app completions") {
            if runningApps.isEmpty {
                Text("No apps detected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(runningApps) { app in
                Toggle(app.name, isOn: Binding(
                    get: { settings.wrappedValue.isAppEnabled(app.bundleIdentifier) },
                    set: { settings.wrappedValue.setApp(app.bundleIdentifier, enabled: $0) }
                ))
            }
            Button("Refresh app list") { refresh() }
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var statsSection: some View {
        Section("Local stats") {
            statRow("Acceptance rate", percent(snapshot.acceptanceRate),
                    detail: "\(snapshot.acceptedCount) accepted / \(snapshot.shownCount) shown")
            statRow("Suppression rate", percent(snapshot.suppressionRate),
                    detail: "\(snapshot.suppressedCount) of \(snapshot.generatedCount) generated")
            statRow("Latency (p50 / p95)",
                    "\(Int(snapshot.latencyMillisP50)) / \(Int(snapshot.latencyMillisP95)) ms",
                    detail: "\(snapshot.latencySampleCount) samples")
            Button("Refresh stats") { refresh() }
                .font(.footnote)
            Text("All metrics are computed and stored only on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func statRow(_ title: String, _ value: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).font(.body.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Data

    private func refresh() {
        snapshot = telemetry.snapshot()
        availableModels = Self.loadModels()
        runningApps = Self.loadRunningApps()
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static func loadModels() -> [String] {
        guard let dir = try? ModelContainer.modelsDirectoryURL(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names.filter { $0.lowercased().hasSuffix(".gguf") }.sorted()
    }

    private static func loadRunningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { (app: NSRunningApplication) -> RunningApp? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return RunningApp(bundleIdentifier: bundleID, name: app.localizedName ?? bundleID)
            }
            .reduce(into: [RunningApp]()) { acc, app in
                if !acc.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                    acc.append(app)
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    struct RunningApp: Identifiable {
        let bundleIdentifier: String
        let name: String
        var id: String { bundleIdentifier }
    }
}
