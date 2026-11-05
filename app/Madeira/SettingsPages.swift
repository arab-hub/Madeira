// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

// Settings in pages, as Game details is: the Settings tab lists a few groups of rows,
// and each row opens a page with the sections that were on the one long page. Each
// section is the same view it was there. While the search field holds text, the tab
// shows the one long page filtered, as before, so a match is found wherever it lives.
// env.MADEIRA_SETTINGS_PAGES = 0 keeps the one long page.

enum SettingsPages {
    /// On by default: the Settings tab lists its pages, each opening the sections it holds.
    /// 0: the one long page with every section, as before.
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_SETTINGS_PAGES") }

    enum Page: Hashable, CaseIterable {
        case steam, gog, itch, epic, ea, runtimes, graphics, display, memory, pointer, defaults, experiments, jit, signing, saves,
             storage, drives, appearance, advanced, credits

        var title: String {
            switch self {
            case .steam: return "Steam and Dock"
            case .gog: return "GOG"
            case .itch: return "itch.io"
            case .epic: return "Epic Games"
            case .ea: return "EA app"
            case .runtimes: return "Runtimes"
            case .graphics: return "Graphics"
            case .display: return "Display"
            case .memory: return "Memory and sync"
            case .pointer: return "Pointer and touch"
            case .defaults: return "Defaults for new games"
            case .experiments: return "Performance experiments"
            case .jit: return "JIT"
            case .signing: return "Signing"
            case .saves: return "Saves and backups"
            case .storage: return "Storage"
            case .drives: return "External drives"
            case .appearance: return "Appearance"
            case .advanced: return "Advanced"
            case .credits: return "Credits"
            }
        }

        var symbol: String {
            switch self {
            case .steam: return "shippingbox"
            case .gog: return "bag"
            case .itch: return "arrow.down.app"
            case .epic: return "gamecontroller"
            case .ea: return "arrow.down.circle"
            case .runtimes: return "puzzlepiece.extension"
            case .graphics: return "cpu"
            case .display: return "display"
            case .memory: return "memorychip"
            case .pointer: return "cursorarrow"
            case .defaults: return "slider.horizontal.3"
            case .experiments: return "flask"
            case .jit: return "bolt"
            case .signing: return "signature"
            case .saves: return "externaldrive.badge.timemachine"
            case .storage: return "internaldrive"
            case .drives: return "externaldrive"
            case .appearance: return "paintpalette"
            case .advanced: return "wrench.and.screwdriver"
            case .credits: return "heart"
            }
        }

        // A page shows when the long page would show its sections: the same switches.
        @MainActor var shown: Bool {
            switch self {
            case .steam: return SteamSettingsSection.shown
            case .gog: return GOGLibrary.enabled
            case .itch: return ItchLibrary.enabled
            case .epic: return EpicLibrary.enabled
            case .ea: return EALibrary.enabled
            case .signing: return SigningRefresh.enabled
            case .graphics: return GraphicsSettings.shown
            case .display, .memory, .experiments: return LibraryView.runtimeSettingsShown
            default: return true
            }
        }
    }

    /// The rows of the Settings tab, in groups.
    static let groups: [(String?, [Page])] = [
        ("Getting games", [.steam, .gog, .itch, .epic, .ea, .runtimes]),
        ("Running games", [.graphics, .display, .memory, .pointer, .defaults, .experiments]),
        ("Device", [.jit, .signing, .saves, .storage, .drives]),
        (nil, [.appearance, .advanced, .credits]),
    ]
}

/// The Settings tab's first page: the status, then a row for each page.
struct SettingsPagesList: View {
    var startDock: (DockGame, Bool) -> Void
    @ObservedObject private var jitState = LibraryJITState.shared
    @ObservedObject private var liquidMetal = LiquidMetalSetting.shared

    var body: some View {
        Form {
            Section { LibraryStatus().listRowBackground(Color.clear) }
            ForEach(Array(SettingsPages.groups.enumerated()), id: \.offset) { _, group in
                let pages = group.1.filter(\.shown)
                if !pages.isEmpty {
                    Section {
                        ForEach(pages, id: \.self) { page in
                            NavigationLink { SettingsPageView(page: page, startDock: startDock) } label: { row(page) }
                        }
                    } header: { if let title = group.0 { Text(title) } }
                }
            }
        }
    }

    @ViewBuilder private func row(_ page: SettingsPages.Page) -> some View {
        if let value = summary(page) {
            LabeledContent { Text(value).lineLimit(1) } label: { Label(page.title, systemImage: page.symbol) }
        } else {
            Label(page.title, systemImage: page.symbol)
        }
    }

    private func summary(_ page: SettingsPages.Page) -> String? {
        switch page {
        case .jit: return jitState.enabled ? "On" : "Off"
        case .appearance: return liquidMetal.on ? "Liquid metal" : "Liquid Glass"
        default: return nil
        }
    }
}

/// One page. Its sheets hang off its own Form, as the long page's did, never off a
/// page the navigation has covered.
struct SettingsPageView: View {
    let page: SettingsPages.Page
    var startDock: (DockGame, Bool) -> Void
    @State private var sheet: SettingsSheet?
    @State private var refresh = 0
    @ObservedObject private var input = InputSettings.shared
    @ObservedObject private var liquidMetal = LiquidMetalSetting.shared
    @AppStorage(LibraryGridArm.key) private var zoomableGrid = false
    @AppStorage(GridZoomHapticPlayer.key) private var zoomHaptics = true
    @AppStorage(TouchControlStyle.key) private var controlStyle = "glass"
    @State private var developerUI = !FrontendChoice.preferNew
    @State private var restartNotice = false

    var body: some View {
        Form { content }
            .navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
            .alert("Restart Madeira", isPresented: $restartNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Close Madeira from the app switcher and open it again to switch interfaces.")
            }
            .sheet(item: $sheet, onDismiss: { refresh += 1 }) { sheet in
                switch sheet {
                case .allSettings: AllSettingsView()
                case .steamSignIn: SteamSignInView()
                case .gogSignIn: GOGSignInView()
                case .epicSignIn: EpicSignInView()
                case .eaSignIn: EASignInView()
                case .dock: MadeiraDockView(start: startDock)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .steam: SteamSettingsSection(open: { sheet = $0 })
        case .gog: GOGSettingsSection(open: { sheet = $0 })
        case .itch: ItchSettingsSection()
        case .epic: EpicSettingsSection(open: { sheet = $0 })
        case .ea: EASettingsSection(open: { sheet = $0 })
        case .runtimes:
            WineMonoSettingsSection()
            if VCRedistModel.enabled { VCRedistSettingsSection() }
            WineGeckoSettingsSection()
        case .graphics: GraphicsSettings(refresh: refresh)
        case .display: DisplayRateSettings()
        case .memory: RuntimeMemorySyncSettings(open: { sheet = $0 }, refresh: refresh)
        case .pointer: Section("Pointer") { LibraryPointerSettings() }
        case .defaults: NewGameDefaultsSection()
        case .experiments: PerformanceExperimentsSettings()
        case .jit: JITSettingsSection()
        case .signing: SigningSettingsSection()
        case .saves: SavesSection()
        case .storage: StorageSection()
        case .drives: ExternalDrivesSection()
        case .appearance: appearance
        case .advanced:
            Section {
                Toggle("Extended logging", isOn: $input.diagnostics)
                // ClaudeHelp.swift: the fixes guide, logs and madeira.cfg to a chat.
                ClaudeHelpButton(entry: nil)
                ShareLogsButton()
                Text(ShareLogsButton.note).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Diagnostics") } footer: {
                Text("Get Help from Claude shares a guide to known fixes, the last logs and madeira.cfg. For one game's config too, use the button on its Game details page.")
            }
            Section {
                Button("All settings") { sheet = .allSettings }
            } footer: {
                Text("Every option Madeira reads from madeira.cfg, by subsystem.")
            }
        case .credits: SettingsCreditsSection()
        }
    }

    @ViewBuilder private var appearance: some View {
        Section {
            Toggle("Liquid metal", isOn: $liquidMetal.on)
        } footer: {
            Text("Flowing chrome on the bars and the Desktop button. Off, they use the system's Liquid Glass.")
        }
        Section {
            Picker("Touch control buttons", selection: $controlStyle) {
                ForEach(TouchControlStyle.styles, id: \.id) { Text($0.name).tag($0.id) }
            }
        } footer: {
            Text("Glass is the system's Liquid Glass. Solid draws each button as a plain opaque disc; a game's Opacity slider still fades them.")
        }
        Section {
            Toggle("New library grid", isOn: $zoomableGrid)
            if zoomableGrid {
                Toggle("Zoom haptics", isOn: $zoomHaptics)
            }
        } footer: {
            Text("Pinch the library's cards to change how many fit across. Off, the cards use the original grid. Zoom haptics click as the pinch crosses a size.")
        }
        Section {
            Toggle("Use developer interface", isOn: Binding(get: { developerUI }, set: { on in
                developerUI = on; FrontendChoice.choose(new: !on); restartNotice = true
            }))
        } header: { Text("Interface") } footer: {
            Text("The developer interface is Madeira's original diagnostic screen. The change applies after Madeira restarts.")
        }
    }
}

/// Settings › Defaults for new games: what a new library entry starts with
/// (LibraryEntry.NewGame), and the same settings put on the games already there.
struct NewGameDefaultsSection: View {
    @AppStorage(LibraryEntry.NewGame.Field.performance.key) private var performance = false
    @AppStorage(LibraryEntry.NewGame.Field.touchControls.key) private var touchControls = false
    @AppStorage(LibraryEntry.NewGame.Field.liveLogs.key) private var liveLogs = false
    @AppStorage(LibraryEntry.NewGame.Field.fpsMode.key) private var fpsMode = 1
    @AppStorage(LibraryEntry.NewGame.Field.resolution.key) private var resolution = ""
    @State private var chosen = Set<LibraryEntry.NewGame.Field>()
    @State private var confirm = false
    @State private var applied: Int?
    @ObservedObject private var model = LibraryModel.shared

    private var gameCount: Int { model.entries.filter { $0.desktop != true && $0.bigPicture != true }.count }
    private func title(_ field: LibraryEntry.NewGame.Field) -> String {
        switch field {
        case .performance: return "Performance overlay"
        case .touchControls: return "Touch controls"
        case .liveLogs: return "Live logs"
        case .fpsMode: return "FPS limit"
        case .resolution: return "Resolution"
        }
    }

    var body: some View {
        Section {
            Toggle("Performance overlay", isOn: $performance)
            Toggle("Touch controls", isOn: $touchControls)
            Toggle("Live logs", isOn: $liveLogs)
            FPSChoice(mode: $fpsMode)
            Picker("Resolution", selection: $resolution) {
                Text("Automatic").tag("")
                ForEach(ResolutionChoices.groups(), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.choices, id: \.value) { Text($0.label).tag($0.value) }
                    }
                }
            }
        } header: { Text("Defaults for new games") } footer: {
            Text("Used when a game is added to the library. Madeira's recommended settings for a game apply on top. Automatic is this screen's shape.")
        }
        Section {
            ForEach(LibraryEntry.NewGame.Field.allCases, id: \.self) { field in
                Toggle(title(field), isOn: Binding(get: { chosen.contains(field) }, set: { on in
                    if on { chosen.insert(field) } else { chosen.remove(field) }
                    applied = nil
                }))
            }
            Button("Apply to all games") { confirm = true }
                .disabled(chosen.isEmpty || gameCount == 0)
                .confirmationDialog("Apply \(chosen.count) setting(s) to \(gameCount) game(s)?", isPresented: $confirm, titleVisibility: .visible) {
                    Button("Apply", role: .destructive) { applied = model.applyNewGameDefaults(chosen) }
                } message: {
                    Text("Each game's value for the settings ticked here is replaced by the default above. Everything else about a game stays.")
                }
            if let applied { Text("Applied to \(applied) game(s).").font(.caption).foregroundStyle(.secondary) }
        } header: { Text("Apply to all games") } footer: {
            Text("Tick what to change. Only those settings change, on every game in the library but the Desktop.")
        }
    }
}

/// Settings › Performance experiments: plain switches for keys that are off by default.
/// All of them are read when a game starts: env lines by WineProcessBridge.m at each launch
/// (MADEIRA_SRV_DIRECT is cleared again when the session ends), ring-share and pso-lazy-libs
/// once per program by madeira-d3d12, DXMT_SMALL_RINGS when a program starts.
/// The keys are named by constants so the catalog keeps these options' engine sources.
struct PerformanceExperimentsSettings: View {
    private static let directKey = "env.MADEIRA_SRV_DIRECT"
    private static let ringKey = "ring-share"
    private static let lazyKey = "pso-lazy-libs"
    private static let smallRingsKey = "env.DXMT_SMALL_RINGS"
    private static func isOn(_ key: String) -> Bool {
        let value = MadeiraConfig.get(key) ?? ""
        return !value.isEmpty && value != "0"
    }
    @State private var direct = Self.isOn(Self.directKey)
    @State private var memory = Self.isOn(Self.ringKey) && Self.isOn(Self.lazyKey)
    @State private var smallRings = MadeiraConfig.get(Self.smallRingsKey) == "1"

    private func label(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { direct }, set: { on in
                direct = on
                MadeiraConfig.set(Self.directKey, on ? "1" : nil)
                LogStore.shared.log("[runtime-settings] srv-direct=\(on ? 1 : 0)")
            })) {
                label("Direct server requests", "Simple Wine server requests (files, handles, registry, events) run on the game's own thread, without a trip to the server thread.")
            }
            Toggle(isOn: Binding(get: { memory }, set: { on in
                memory = on
                MadeiraConfig.set(Self.ringKey, on ? "1" : nil)
                MadeiraConfig.set(Self.lazyKey, on ? "1" : nil)
                LogStore.shared.log("[runtime-settings] d3d12-lower-memory=\(on ? 1 : 0)")
            })) {
                label("Lower Direct3D 12 memory", "Command lists share their argument buffers, and pipelines let go of their shader libraries until their first draw. Needs the shader cache, which is on by default.")
            }
            Toggle(isOn: Binding(get: { smallRings }, set: { on in
                smallRings = on
                MadeiraConfig.set(Self.smallRingsKey, on ? "1" : nil)
                LogStore.shared.log("[runtime-settings] dxmt-small-rings=\(on ? 1 : 0)")
            })) {
                label("Smaller Direct3D 9, 10 and 11 buffers", "DXMT's staging buffers use 4 MB blocks instead of 32 MB in every program. Larger uploads still get a block of their own.")
            }
        } header: { Text("Performance experiments") } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("These may hang or break games. If a game stops starting, turn them off.").foregroundStyle(.orange)
                Text("Off by default. Each applies the next time a game starts; a game's own config line for the same key wins.")
            }
        }
    }
}

/// Also delete game files (Game details › Library details): the folder a library entry's program
/// is in, when that is safe to delete, else nil. Never drive_c or its shared folders, nothing
/// through a link (an external drive), nothing under C:\\users or C:\\windows, no folder a store
/// looks after, and no folder that holds, or lies inside the folder of, another entry.
enum GameFolderRemoval {
    private static let neverInside = ["windows", "users", "programdata", "external", "madeira-games", "gog games", "itch",
                                      "program files/epic games", "program files/ea games", "program files/steam",
                                      "program files/steam big picture", "program files (x86)/steam"]
    private static let containers = ["games", "program files", "program files (x86)"]

    private static func inside(_ path: String, _ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }

    static func folder(for entry: LibraryEntry, among entries: [LibraryEntry]) -> URL? {
        guard entry.desktop != true, entry.bigPicture != true, entry.steamAppID == nil, entry.gogProductID == nil,
              entry.itchGameID == nil, entry.epicAppName == nil, entry.eaOfferID == nil else { return nil }
        let parts = entry.relativePath.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let folderParts = parts.dropLast()
        let lower = folderParts.joined(separator: "/").lowercased()
        guard !containers.contains(lower), !neverInside.contains(where: { inside(lower, $0) || inside($0, lower) }) else { return nil }
        // Another entry: its program or folder in this one, or this one in its program's folder.
        for other in entries where other.id != entry.id {
            let path = other.relativePath.split(separator: "/").joined(separator: "/").lowercased()
            if inside(path, lower) { return nil }
            let home = path.split(separator: "/").dropLast().joined(separator: "/")
            if !home.isEmpty, inside(lower, home) { return nil }
            if let working = other.workingDirectory, working.count >= 3, working.prefix(3).uppercased() == "C:\\" {
                let place = working.dropFirst(3).split(separator: "\\").joined(separator: "/").lowercased()
                if !place.isEmpty, inside(place, lower) || inside(lower, place) { return nil }
            }
        }
        // This entry's own working folder elsewhere does not matter; a link on the way does.
        let drive = LibraryModel.drive.standardizedFileURL
        let target = folderParts.reduce(drive) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == target.path, resolved.path.hasPrefix(drive.path + "/") else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        return target
    }
}

/// What Settings › Storage can clear, each read for what it is: logs are only ever read when
/// shared, the covers come back from their sources, the temporary folders are copies made for a
/// share sheet, and the Direct3D 12 shader cache is converted again as a game needs it. Temporary
/// files something may still use (a Visual C++ download kept for a retry, a runtime being
/// unpacked), Library/Caches beyond the covers, and this run's log are left alone.
enum StorageClearing: String, CaseIterable, Identifiable {
    case logs, covers, temporary, shaders
    var id: String { rawValue }
    var title: String {
        switch self {
        case .logs: return "Old logs"
        case .covers: return "Cover cache"
        case .temporary: return "Temporary share files"
        case .shaders: return "Direct3D 12 shader cache"
        }
    }
    var question: String {
        switch self {
        case .logs: return "Delete the logs of earlier runs? This run's log stays."
        case .covers: return "Clear the cover cache? Covers load again when they are next shown."
        case .temporary: return "Delete the copies made for sharing?"
        case .shaders: return "Clear the Direct3D 12 shader cache? The next start of each game converts its shaders again, which can take minutes."
        }
    }

    /// What is removed: `remove` goes whole; of `children`, the contents, as the folder stays.
    private var places: (remove: [URL], children: [URL]) {
        let fm = FileManager.default
        let documents = LibraryModel.documents
        switch self {
        case .logs:
            let dir = documents.appendingPathComponent("logs", isDirectory: true)
            let runs = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".txt") }.map { dir.appendingPathComponent($0) }
            return (runs + [documents.appendingPathComponent("madeira-log.prev.txt"), documents.appendingPathComponent(LogSummary.gameLogName)], [])
        case .covers:
            return ([], [LibraryCoverCache.folder])
        case .temporary:
            let temporary = fm.temporaryDirectory
            let saves = ((try? fm.contentsOfDirectory(atPath: temporary.path)) ?? []).filter { $0.hasPrefix("Madeira-saves-") }.map { temporary.appendingPathComponent($0) }
            return (saves + [temporary.appendingPathComponent("ClaudeHelp", isDirectory: true), temporary.appendingPathComponent("setups", isDirectory: true)], [])
        case .shaders:
            let users = LibraryModel.drive.appendingPathComponent("users", isDirectory: true)
            var seen = Set<String>()
            var out: [URL] = []
            for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
                let cache = users.appendingPathComponent(user).appendingPathComponent("AppData/Local/Madeira/ShaderCache", isDirectory: true)
                let resolved = cache.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(LibraryModel.drive.standardizedFileURL.path + "/"), seen.insert(resolved.path).inserted else { continue }
                out.append(resolved)
            }
            return (out, [])
        }
    }

    private static func bytes(in url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return 0 }
        guard isFolder.boolValue else { return Int64((try? url.resourceValues(forKeys: keys))?.fileSize ?? 0) }
        var total: Int64 = 0
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Reads the disk: off the main thread.
    var bytes: Int64 {
        let places = self.places
        return (places.remove + places.children).reduce(0) { $0 + Self.bytes(in: $1) }
    }

    /// Writes the disk: off the main thread.
    func clear() {
        let fm = FileManager.default
        let places = self.places
        for url in places.remove { try? fm.removeItem(at: url) }
        for folder in places.children {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        LogStore.shared.log("[storage] cleared \(rawValue)")
    }
}

/// Settings › Storage: each game's size as the library measured it, the free space, and what can be cleared.
struct StorageSection: View {
    @ObservedObject private var model = LibraryModel.shared
    @State private var free: Int64?
    @State private var sizes: [StorageClearing: Int64] = [:]
    @State private var measured = false
    @State private var busy = false
    @State private var pending: StorageClearing?

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private var games: [LibraryEntry] {
        model.entries.filter { $0.desktop != true && $0.listedInLibrary }
            .sorted { ($0.folderBytes ?? -1) > ($1.folderBytes ?? -1) }
    }

    private func measure() {
        DispatchQueue.global(qos: .utility).async {
            let found = Dictionary(uniqueKeysWithValues: StorageClearing.allCases.map { ($0, $0.bytes) })
            let space = ItchLibrary.freeSpace(at: LibraryModel.documents)
            DispatchQueue.main.async {
                sizes = found
                free = space
                measured = true
                busy = false
            }
        }
    }

    var body: some View {
        Section {
            LabeledContent("Free space", value: free.map(size) ?? "…")
        } header: { Text("Storage") }
        .onAppear { measure() }
        Section {
            ForEach(games) { game in
                LabeledContent(game.title, value: game.folderBytes.map(size) ?? "Not measured yet")
            }
            if games.isEmpty { Text("No games in the library yet.").foregroundStyle(.secondary) }
        } header: { Text("Games") } footer: {
            Text("Sizes are the library's last measurement of each game's folder.")
        }
        Section {
            ForEach(StorageClearing.allCases) { item in
                Button { pending = item } label: {
                    LabeledContent(item.title, value: sizes[item].map(size) ?? "…")
                }
                .disabled(busy || !measured || (sizes[item] ?? 0) == 0)
            }
        } header: { Text("Logs and caches") } footer: {
            Text("Saves, games and settings are not touched. Tap a row to clear it.")
        }
        .confirmationDialog(pending?.question ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                guard let item = pending else { return }
                pending = nil
                busy = true
                DispatchQueue.global(qos: .utility).async {
                    item.clear()
                    DispatchQueue.main.async { measure() }
                }
            }
        }
    }
}

/// The credits, on their own page and last on the long one.
struct SettingsCreditsSection: View {
    var body: some View {
        Section {
            MadeiraCredit(name: "Will Faust", handle: "willfaust", role: "Created Madeira")
            MadeiraCredit(name: "Nick", handle: "125hz", role: "32-bit game support, the game library and Madeira Dock")
            MadeiraCredit(name: "Jfishin", handle: "Jfishin", role: "The original native Steam sign-in, library and downloads")
            MadeiraCredit(name: "Jesse", handle: "JesseLovelace", role: "Steam Cloud saves, faster game launches, and fixes that let more games run")
            MadeiraCredit(name: "Dan Perks", handle: "danperks", role: "In-app JIT without StikDebug, and pairing without a computer")
            MadeiraCredit(name: "bahacan16", handle: "bahacan16", role: "Direct3D 12 and DXMT fixes, game launcher windows, per-game settings, PlayStation controllers, and save backups")
            MadeiraCredit(name: "spitefulowl", handle: "spitefulowl", role: "Wine and FEX runtime fixes, DXMT texture and memory fixes, audio, the swap tier, and library launch options")
            MadeiraCredit(name: "meshoklv", handle: "meshoklv", role: "Controller fixes for games that ship their own XInput or need focus, touch taps that stay off the mouse, and a crash-guard fix")
            MadeiraCredit(name: "TheHadesc", handle: "TheHadesc", role: "Madeira Dock starts for games whose Steam launch entries do not start at zero, and a touch gamepad that survives the in-game keyboard")
        } header: { Text("Credits") } footer: {
            Text("Madeira is built on Wine, FEX-Emu, DXMT by Feifan He (3Shain) with the Direct3D 9 frontend by David Acevedo (dacevedo12), rpmalloc by Mattias Jansson, StikDebug, StikJIT and idevice. Thank you to everyone who contributes to these projects.")
        }
    }
}
