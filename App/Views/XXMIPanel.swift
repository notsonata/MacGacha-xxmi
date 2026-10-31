// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import ModSupport
import SwiftUI
import UniformTypeIdentifiers

/// Manages the bundled XXMI compatibility package and the user's mod library.
/// Only Global Star Rail is verified; every other selection explains why it is unavailable.
struct XXMIPanel: View {
    @Environment(AppModel.self) private var model
    let gameID: String
    @State private var searchText = ""
    @State private var pendingRemoval: ManagedMod?
    @State private var confirmingRisk = false
    @State private var isDropTargeted = false

    private var game: LauncherGame {
        LauncherGame.all.first { $0.id == gameID } ?? LauncherGame.all[0]
    }

    var body: some View {
        Group {
            if AppModel.supportsModSupport(gameID: gameID) {
                supportedContent
            } else {
                ContentUnavailableView {
                    Label("XXMI is not available for this game", systemImage: "wrench")
                } description: {
                    Text("XXMI mod support is available for Honkai: Star Rail (Global) on the D3DMetal runtime. It is not available for \(game.name), and this game will never be modified.")
                }
            }
        }
        .navigationTitle("XXMI")
        .task {
            guard AppModel.supportsModSupport(gameID: gameID) else { return }
            await model.refreshModSupport()
        }
        .confirmationDialog("Enable mod injection?", isPresented: $confirmingRisk) {
            Button("Enable Mods", role: .destructive) {
                model.setModSupportInjection(true, acknowledgingRisk: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mods inject code into the game. HoYoverse may treat this as cheating and permanently ban the account. Enable only if you accept that risk.")
        }
        .confirmationDialog(removalTitle, isPresented: removalBinding) {
            Button("Remove Mod", role: .destructive) {
                if let mod = pendingRemoval { model.removeModSupport(mod.id) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("The imported copy is deleted. The original folder or ZIP archive is not changed.")
        }
    }

    private var supportedContent: some View {
        Group {
            if model.modSupportSnapshot == nil, model.modSupportViewState == .loading {
                ProgressView("Checking XXMI…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .failed(let message) = model.modSupportViewState, model.modSupportSnapshot == nil {
                ContentUnavailableView {
                    Label("XXMI could not be checked", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.refreshModSupport() } }
                }
            } else {
                Form {
                    packageSection
                    injectionSection
                    folderSection
                    modsSection
                }
                .formStyle(.grouped)
            }
        }
    }

    // MARK: - Package

    private var packageSection: some View {
        Section {
            LabeledContent("Installed") {
                Text(model.modSupportInstalledVersion ?? String(localized: "Not installed"))
                    .foregroundStyle(model.modSupportInstalledVersion == nil ? .secondary : .primary)
                    .monospacedDigit()
            }
            LabeledContent("Available") {
                Text(model.modSupportAvailableVersion ?? String(localized: "Built-in package unavailable"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let activity = model.modSupportActivity {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activityLabel(activity))
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(activityLabel(activity))
            }
            if let error = model.modSupportError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if model.modSupportSnapshot?.isInstalled == true {
                    Button("Repair") { model.repairBundledModSupport() }
                    if model.modSupportAvailableVersion != nil,
                        model.modSupportAvailableVersion != model.modSupportInstalledVersion {
                        Button("Update") { model.updateBundledModSupport() }
                    }
                } else {
                    Button("Install") { model.installBundledModSupport() }
                }
                Button("Import Package…") { choosePackage() }
                Spacer()
            }
            .disabled(model.isModSupportBusy)
        } header: {
            Text("Package")
        } footer: {
            Text("Installing the package does not turn injection on. A package imported from a folder replaces the built-in version only after every file is verified.")
        }
    }

    // MARK: - Injection

    private var injectionSection: some View {
        Section {
            Toggle("Inject XXMI on next launch", isOn: injectionBinding)
                .disabled(model.isModSupportBusy
                    || (model.modSupportSnapshot?.isInstalled != true && model.modSupportSnapshot?.injectionEnabled != true))
                .help("Mod injection applies to the next launch, not a running game")
            if model.modSupportSnapshot?.injectionEnabled == true,
                model.modSupportSnapshot?.isInstalled != true {
                Label("Injection is on, but the package is not installed. The game will not start until XXMI is installed or injection is turned off.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.modSupportNeedsRiskAcknowledgment {
                Text("Turning injection on asks for a ban-risk acknowledgment first. Mods are off until you enable them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Injection")
        } footer: {
            Text("Changes apply to the next launch. A running game keeps the mods it started with.")
        }
    }

    // MARK: - Folder

    private var folderSection: some View {
        Section {
            LabeledContent("Mods Folder") {
                Text(model.modSupportModsDirectory?.path ?? String(localized: "Not available"))
                    .foregroundStyle(model.modSupportModsDirectory == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Move Mods Folder…") { chooseModsFolderDestination() }
                    .disabled(model.isModSupportBusy)
                Spacer()
            }
        } header: {
            Text("Mods Folder")
        } footer: {
            Text("Moving the folder copies your imported mods to the new location and removes the old folder. Existing files are never overwritten.")
        }
    }

    // MARK: - Mods

    private var modsSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search Mods", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search Mods")
            }
            dropZone
            if mods.isEmpty {
                Text(searchText.isEmpty
                    ? String(localized: "No mods are imported yet. Add a folder or ZIP archive to get started.")
                    : String(localized: "No mods match your search."))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(mods) { mod in
                    ModRow(mod: mod, busy: model.isModSupportBusy,
                        onToggle: { model.setModSupportEnabled(mod.id, enabled: $0) },
                        onReveal: { model.revealModSupportMod(mod.id) },
                        onRemove: { pendingRemoval = mod })
                }
            }
        } header: {
            HStack {
                Text("Mods")
                Spacer()
                Button("Show Mods Folder") { model.revealModSupportFolder() }
                    .buttonStyle(.link)
                    .accessibilityLabel("Show Mods Folder in Finder")
                Button("Import…") { chooseMod() }
                    .disabled(model.isModSupportBusy)
            }
        } footer: {
            Text("Enabled mods are copied into each new launch, so editing or removing them never changes a running game. Only mod folders and ZIP archives are accepted.")
        }
    }

    private var mods: [ManagedMod] {
        model.filteredModSupportMods(matching: searchText)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternaryLabelColor).opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            .overlay {
                Label(isDropTargeted ? String(localized: "Drop to import") : String(localized: "Drop a mod folder or ZIP here"),
                    systemImage: isDropTargeted ? "arrow.down.circle.fill" : "square.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            .frame(height: 56)
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isModSupportBusy, urls.count == 1, let url = urls.first else { return false }
                model.importModSupport(from: url)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Import mods")
            .accessibilityHint("Drop a folder or ZIP archive to import a mod")
            .accessibilityValue(isDropTargeted ? String(localized: "Ready to import") : "")
    }

    // MARK: - Actions and labels

    private var injectionBinding: Binding<Bool> {
        Binding(
            get: { model.modSupportSnapshot?.injectionEnabled ?? false },
            set: { enabled in
                guard !model.isModSupportBusy else { return }
                if enabled, model.modSupportNeedsRiskAcknowledgment {
                    confirmingRisk = true
                } else {
                    model.setModSupportInjection(enabled, acknowledgingRisk: false)
                }
            }
        )
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var removalTitle: String {
        guard let mod = pendingRemoval else { return String(localized: "Remove Mod?") }
        return String(localized: "Remove \(mod.name)?", comment: "Mod removal confirmation; the argument is the mod's name")
    }

    private func activityLabel(_ activity: ModSupportActivity) -> String {
        switch activity {
        case .installing: String(localized: "Installing XXMI…")
        case .repairing: String(localized: "Repairing XXMI…")
        case .updating: String(localized: "Updating XXMI…")
        case .importing: String(localized: "Importing mod…")
        case .removing: String(localized: "Removing mod…")
        case .saving: String(localized: "Saving changes…")
        case .moving: String(localized: "Moving mods folder…")
        }
    }

    private func chooseMod() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Mod")
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose a mod folder or ZIP archive.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder] + [UTType(filenameExtension: "zip")].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url { model.importModSupport(from: url) }
    }

    private func chooseModsFolderDestination() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Move Mods Folder")
        panel.prompt = String(localized: "Move Here")
        panel.message = String(localized: "Choose where to create the mods folder. MacGacha-HSR-Mods is added inside it.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let parent = panel.url {
            let destination = parent.appendingPathComponent("MacGacha-HSR-Mods", isDirectory: true)
            model.moveModSupportDirectory(to: destination)
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import XXMI Package")
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder containing manifest.json and hsr-srmi.zip.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importModSupportPackage(from: url) }
    }
}

private struct ModRow: View {
    let mod: ManagedMod
    let busy: Bool
    let onToggle: @MainActor @Sendable (Bool) -> Void
    let onReveal: @MainActor @Sendable () -> Void
    let onRemove: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(mod.name).font(.body)
                Text("\(mod.fileCount) files", comment: "Number of files in an imported mod; the argument is a count")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            Toggle("Enabled", isOn: Binding(get: { mod.enabled }, set: onToggle))
                .labelsHidden()
                .disabled(busy)
                .accessibilityLabel(Text("Enable \(mod.name)", comment: "Mod toggle; the argument is the mod's name"))
            Button(action: onReveal) {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel(Text("Show \(mod.name) in Finder", comment: "Reveal a mod folder; the argument is the mod's name"))
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .help("Remove Mod")
            .accessibilityLabel(Text("Remove \(mod.name)", comment: "Remove a mod; the argument is the mod's name"))
        }
        .padding(.vertical, 2)
    }
}
