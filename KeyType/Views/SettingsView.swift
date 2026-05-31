//
//  SettingsView.swift
//  KeyType
//
//  The KeyType Settings window. Laid out like Cotypist: a category sidebar on the left and the
//  matching settings pane on the right. Categories cover model selection, completion length,
//  acceptance keybinds, the privacy switches that gate sensitive context, per-app toggles, the
//  read-only local stats, and a "run setup again" shortcut back into onboarding.
//
//  History/clipboard/OCR are off by default and a single "Clear all personal data" action wipes the
//  encrypted history store + local telemetry. See ADR-023.
//

import AppKit
import ModelManagement
import ModelRuntime
import Personalization
import SwiftUI

struct SettingsView: View {
    let settings: SettingsStore
    let telemetry: CompletionTelemetryStore
    let modelSetup: ModelSetupCoordinator
    let clearPersonalData: () -> Void
    let runSetupAgain: () -> Void
    /// Tear down and reload the completion engine from the currently selected model. Invoked when the
    /// user picks a different installed model so the change takes effect immediately (see ADR-021).
    let reloadModel: () -> Void
    /// Present the GGUF import open panel. Owned by `AppDelegate` because it must quiesce the AX
    /// pipeline around the panel to avoid a main-thread deadlock (see `presentModelImportPanel`).
    let importModel: () -> Void

    @State private var selection: SettingsCategory = .general
    @State private var snapshot: TelemetrySnapshot = TelemetrySnapshot()
    @State private var availableModels: [String] = []
    @State private var runningApps: [RunningApp] = []
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                NavigationLink(value: category) {
                    SidebarRow(category: category)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
            .listStyle(.sidebar)
        } detail: {
            detail
                .frame(minWidth: 480, idealWidth: 520)
                .navigationTitle(selection.title)
        }
        .frame(width: 760, height: 600)
        .task { refresh() }
        // A download/profile finishing changes a model's setup state but not `availableModels`,
        // which is loaded from disk. Reading every model's state here establishes the observation
        // dependency, so this fires (and re-reads the installed GGUFs) the moment one lands —
        // making freshly downloaded models selectable without a restart.
        .onChange(of: modelSetupSignature) { refresh() }
        // An import lands a brand-new file in the Models directory that isn't in the catalog, so it
        // won't move `modelSetupSignature`. Re-read the installed GGUFs when the import state settles
        // so the freshly imported model appears in (and can be shown selected by) the picker.
        .onChange(of: modelSetup.importState) { refresh() }
    }

    /// Changes whenever any catalog model's combined setup state changes. Evaluated on every render
    /// in the always-present split view, so the picker stays in sync regardless of the open pane.
    private var modelSetupSignature: String {
        modelSetup.catalog
            .map { "\($0.filename):\(String(describing: modelSetup.state(for: $0)))" }
            .joined(separator: "|")
    }

    @ViewBuilder
    private var detail: some View {
        @Bindable var settings = settings

        Form {
            switch selection {
            case .general: lengthSection(settings: $settings)
            case .model: modelSection(settings: $settings)
            case .shortcuts: keybindsSection(settings: $settings)
            case .privacy: privacySection(settings: $settings)
            case .apps: perAppSection(settings: $settings)
            case .statistics: statsSection
            case .setup: setupSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    @ViewBuilder
    private func modelSection(settings: Bindable<SettingsStore>) -> some View {
        Section("Model") {
            Picker("Completion model", selection: settings.selectedModelFilename) {
                Text("Default (\(ModelContainer.defaultModelFilename))").tag(String?.none)
                ForEach(availableModels, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            // Honor the "takes effect immediately" promise: a new selection flushes the resident
            // model + KV cache and reloads from the chosen GGUF without a relaunch (see ADR-021).
            .onChange(of: settings.wrappedValue.selectedModelFilename) { reloadModel() }
        }

        Section("Available models") {
            ForEach(modelSetup.catalog) { model in
                SettingsModelRow(
                    model: model,
                    state: modelSetup.state(for: model),
                    isInstalled: modelSetup.downloads.isInstalled(filename: model.filename),
                    onSetup: { modelSetup.beginSetup(for: model) },
                    onCancel: { modelSetup.cancel(model) },
                    onPause: { modelSetup.pause(model) },
                    onResume: { modelSetup.resume(model) },
                    onDelete: {
                        modelSetup.downloads.deleteModel(filename: model.filename)
                        modelSetup.refresh()
                        refresh()
                    }
                )
            }
        }
        
        Section {
            Button("Import a GGUF…", action: importModel)
                .disabled(isImporting)
            importStatusLine
        } header: {
            Text("Use your own base model")
        } footer: {
            Text("KeyType is tuned for the models above; other models may produce unexpected or low-quality completions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        
    }

    private var isImporting: Bool {
        if case .preparing = modelSetup.importState { return true }
        return false
    }

    @ViewBuilder
    private var importStatusLine: some View {
        switch modelSetup.importState {
        case .idle:
            EmptyView()
        case .preparing(let filename):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing \(filename)…").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func keybindsSection(settings: Bindable<SettingsStore>) -> some View {
        Section("Acceptance keys") {
            KeyRecorderView(
                title: "Accept word",
                subtitle: "Inserts the next word of the suggestion.",
                shortcut: settings.wrappedValue.acceptWordShortcut,
                onChange: { settings.wrappedValue.acceptWordShortcut = $0 },
                onReset: settings.wrappedValue.acceptWordShortcut != .defaultAcceptWord
                    ? { settings.wrappedValue.acceptWordShortcut = .defaultAcceptWord } : nil
            )
            KeyRecorderView(
                title: "Accept entire suggestion",
                subtitle: "Inserts the whole suggestion at once.",
                shortcut: settings.wrappedValue.acceptFullShortcut,
                onChange: { settings.wrappedValue.acceptFullShortcut = $0 },
                onReset: settings.wrappedValue.acceptFullShortcut != .defaultAcceptFull
                    ? { settings.wrappedValue.acceptFullShortcut = .defaultAcceptFull } : nil
            )
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
        }

        Section {
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
        } footer: {
            Text("Everything KeyType stores stays on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        Section("Setup") {
            Button("Run setup again…") { runSetupAgain() }
            Text("Re-opens the onboarding wizard (permissions, model, keybinds, and macOS predictions).")
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

// MARK: - Sidebar

/// The Settings categories shown in the left-hand sidebar, Cotypist-style. Each carries a title and
/// a tinted SF Symbol for the sidebar row.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case model
    case shortcuts
    case privacy
    case apps
    case statistics
    case setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .model: return "Model"
        case .shortcuts: return "Shortcuts"
        case .privacy: return "Privacy"
        case .apps: return "Apps"
        case .statistics: return "Statistics"
        case .setup: return "Setup"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .model: return "cpu.fill"
        case .shortcuts: return "command"
        case .privacy: return "lock.shield.fill"
        case .apps: return "square.grid.2x2.fill"
        case .statistics: return "chart.bar.fill"
        case .setup: return "wand.and.stars"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .model: return .purple
        case .shortcuts: return .indigo
        case .privacy: return .green
        case .apps: return .orange
        case .statistics: return .teal
        case .setup: return .blue
        }
    }
}

/// A sidebar row with a tinted, rounded-square icon — matching the Cotypist settings layout.
private struct SidebarRow: View {
    let category: SettingsCategory

    var body: some View {
        Label {
            Text(category.title)
        } icon: {
            Image(systemName: category.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(category.tint.gradient)
                )
        }
        .padding(.vertical, 2)
    }
}

/// One catalog model row in Settings: name, size, live setup state, and the contextual action
/// (Set up / Cancel / Delete).
private struct SettingsModelRow: View {
    let model: DownloadableRuntimeModel
    let state: ModelSetupCoordinator.SetupState
    let isInstalled: Bool
    let onSetup: () -> Void
    let onCancel: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                    Text(model.approximateSizeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                action
            }
            statusLine
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .ready:
            Button("Delete", role: .destructive, action: onDelete)
                .font(.callout)
        case .downloading:
            HStack(spacing: 8) {
                Button("Pause", action: onPause)
                Button("Cancel", action: onCancel)
            }
            .font(.callout)
        case .paused:
            HStack(spacing: 8) {
                Button("Resume", action: onResume)
                Button("Cancel", action: onCancel)
            }
            .font(.callout)
        case .preparingProfile:
            Button("Cancel", action: onCancel)
                .font(.callout)
        case .idle, .failed:
            if isInstalled {
                HStack(spacing: 8) {
                    Button("Prepare", action: onSetup)
                    Button("Delete", role: .destructive, action: onDelete)
                }
                .font(.callout)
            } else {
                Button("Set up", action: onSetup)
                    .font(.callout)
                    .disabled(!model.isDownloadable)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .idle:
            if let reason = model.unavailableReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress)
                Text("Downloading \(Int((progress * 100).rounded()))%")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        case .paused(let progress):
            ProgressView(value: progress ?? 0)
            Text(progress != nil ? "Paused at \(Int((progress! * 100).rounded()))%" : "Paused")
                .font(.footnote).foregroundStyle(.secondary)
        case .preparingProfile:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing model…").font(.footnote).foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.medium)).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
