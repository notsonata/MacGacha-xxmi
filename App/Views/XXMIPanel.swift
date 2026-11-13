// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import AppKit
import ModSupport
import SwiftUI
import UniformTypeIdentifiers

/// Manages the bundled XXMI compatibility package and the user's mod library.
/// Every supported game has its own package, settings and mod library; other
/// selections explain why they are unavailable.
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
                    Text("XXMI mod support is available for Global Honkai: Star Rail and Zenless Zone Zero on the D3DMetal runtime. It is not available for \(game.name), and this game will never be modified.")
                }
            }
        }
        .navigationTitle("XXMI")
        .task {
            guard AppModel.supportsModSupport(gameID: gameID) else { return }
            await model.refreshModSupport(gameID: gameID)
        }
        .task(id: model.launchState(for: gameID)) {
            await model.refreshModLiveApplyEligibility(gameID: gameID)
        }
        .confirmationDialog("Enable mod injection?", isPresented: $confirmingRisk) {
            Button("Enable Mods", role: .destructive) {
                model.setModSupportInjection(true, acknowledgingRisk: true, gameID: gameID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Mods inject code into the game. HoYoverse may treat this as cheating and permanently ban the account. Enable only if you accept that risk.")
        }
        .confirmationDialog(removalTitle, isPresented: removalBinding) {
            Button("Remove Mod", role: .destructive) {
                if let mod = pendingRemoval { model.removeModSupport(mod.id, gameID: gameID) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("The imported copy is deleted. The original folder or ZIP archive is not changed.")
        }
    }

    private var supportedContent: some View {
        Group {
            if model.modSupportSnapshot(for: gameID) == nil,
                model.modSupportViewState(for: gameID) == .loading {
                ProgressView("Checking XXMI…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .failed(let message) = model.modSupportViewState(for: gameID),
                model.modSupportSnapshot(for: gameID) == nil {
                ContentUnavailableView {
                    Label("XXMI could not be checked", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.refreshModSupport(gameID: gameID) } }
                }
            } else {
                Form {
                    packageSection
                    injectionSection
                    if model.canApplyModsToRunningGame(gameID: gameID) {
                        runningGameSection
                    }
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
                Text(model.modSupportInstalledVersion(for: gameID) ?? String(localized: "Not installed"))
                    .foregroundStyle(model.modSupportInstalledVersion(for: gameID) == nil ? .secondary : .primary)
                    .monospacedDigit()
            }
            LabeledContent("Available") {
                Text(model.modSupportAvailableVersion(for: gameID) ?? String(localized: "Built-in package unavailable"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let activity = model.modSupportActivity(for: gameID) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activityLabel(activity))
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(activityLabel(activity))
            }
            if let error = model.modSupportError(for: gameID) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if model.modSupportSnapshot(for: gameID)?.isInstalled == true {
                    Button("Repair") { model.repairBundledModSupport(gameID: gameID) }
                    if model.modSupportAvailableVersion(for: gameID) != nil,
                        model.modSupportAvailableVersion(for: gameID) != model.modSupportInstalledVersion(for: gameID) {
                        Button("Update") { model.updateBundledModSupport(gameID: gameID) }
                    }
                } else {
                    Button("Install") { model.installBundledModSupport(gameID: gameID) }
                }
                Button("Import Package…") { choosePackage() }
                Spacer()
            }
            .disabled(model.isModSupportBusy(for: gameID))
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
                .disabled(model.isModSupportBusy(for: gameID)
                    || (model.modSupportSnapshot(for: gameID)?.isInstalled != true
                        && model.modSupportSnapshot(for: gameID)?.injectionEnabled != true))
                .help("Mod injection applies to the next launch, not a running game")
            if model.modSupportSnapshot(for: gameID)?.injectionEnabled == true,
                model.modSupportSnapshot(for: gameID)?.isInstalled != true {
                Label("Injection is on, but the package is not installed. The game will not start until XXMI is installed or injection is turned off.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.modSupportSnapshot(for: gameID)?.injectionEnabled == true,
                model.modSupportRuntimeIneligible(for: gameID) {
                Label("Mods work only with D3DMetal on Wine 11.20 with D3DMetal 4.0b3. Newer recommended Wine versions are not verified for mods, so the game will not start with injection on. Choose that version in Dependencies, or turn injection off.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.modSupportNeedsRiskAcknowledgment(for: gameID) {
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

    // MARK: - Running game

    /// Offered only while a session launched with injection is running. The
    /// update is a manual action; nothing watches the library or sends keys.
    private var runningGameSection: some View {
        Section {
            HStack(spacing: 8) {
                Button("Apply Mods to Running Game") { model.applyModsToRunningGame(gameID: gameID) }
                    .disabled(model.isModSupportBusy(for: gameID))
                Spacer()
            }
            if model.showsModLiveApplyPrompt(gameID: gameID) {
                HStack(alignment: .top, spacing: 8) {
                    Label("Mods were copied to the running game. Switch to the game and press F10 (fn+F10 on a Mac keyboard) to reload them.",
                        systemImage: "keyboard")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Dismiss") { model.dismissModLiveApplyPrompt(gameID: gameID) }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Running Game")
        } footer: {
            Text("Copies your enabled mods into the running game. Nothing changes in game until you reload mods there; don't press F10 while MacGacha is applying. Editing the library alone only affects the next launch.")
        }
    }

    // MARK: - Folder

    private var folderSection: some View {
        Section {
            LabeledContent("Mods Folder") {
                Text(model.modSupportModsDirectory(for: gameID)?.path ?? String(localized: "Not available"))
                    .foregroundStyle(model.modSupportModsDirectory(for: gameID) == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Move Mods Folder…") { chooseModsFolderDestination() }
                    .disabled(model.isModSupportBusy(for: gameID))
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
                    ModRow(mod: mod, busy: model.isModSupportBusy(for: gameID),
                        onToggle: { model.setModSupportEnabled(mod.id, enabled: $0, gameID: gameID) },
                        onReveal: { model.revealModSupportMod(mod.id, gameID: gameID) },
                        onRemove: { pendingRemoval = mod })
                }
            }
        } header: {
            HStack {
                Text("Mods")
                Spacer()
                Button("Show Mods Folder") { model.revealModSupportFolder(gameID: gameID) }
                    .buttonStyle(.link)
                    .accessibilityLabel("Show Mods Folder in Finder")
                Button("Refresh") { model.rescanModSupportLibrary(gameID: gameID) }
                    .disabled(model.isModSupportBusy(for: gameID))
                Button("Import…") { chooseMod() }
                    .disabled(model.isModSupportBusy(for: gameID))
            }
        } footer: {
            Text("Enabled mods are copied into each new launch, so editing or removing them never changes a running game. Only mod folders and ZIP archives are accepted.")
        }
    }

    private var mods: [ManagedMod] {
        model.filteredModSupportMods(matching: searchText, gameID: gameID)
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
                guard !model.isModSupportBusy(for: gameID), urls.count == 1,
                    let url = urls.first else { return false }
                model.importModSupport(from: url, gameID: gameID)
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
            get: { model.modSupportSnapshot(for: gameID)?.injectionEnabled ?? false },
            set: { enabled in
                guard !model.isModSupportBusy(for: gameID) else { return }
                if enabled, model.modSupportNeedsRiskAcknowledgment(for: gameID) {
                    confirmingRisk = true
                } else {
                    model.setModSupportInjection(enabled, acknowledgingRisk: false, gameID: gameID)
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
        case .refreshing: String(localized: "Refreshing Mods…")
        case .applyingLive: String(localized: "Applying mods to the running game…")
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
        if panel.runModal() == .OK, let url = panel.url { model.importModSupport(from: url, gameID: gameID) }
    }

    private func chooseModsFolderDestination() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Move Mods Folder")
        panel.prompt = String(localized: "Move Here")
        let folderName = ModSupportProfile.find(gameID: gameID)?.suggestedLibraryFolderName
            ?? "MacGacha-Mods"
        panel.message = String(localized: "Choose where to create the mods folder. \(folderName) is added inside it.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let parent = panel.url {
            let destination = parent.appendingPathComponent(folderName, isDirectory: true)
            model.moveModSupportDirectory(to: destination, gameID: gameID)
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import XXMI Package")
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder containing the XXMI package manifest and ZIP archive.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.importModSupportPackage(from: url, gameID: gameID)
        }
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
