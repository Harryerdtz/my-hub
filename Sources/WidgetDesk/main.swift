import SwiftUI
import AppKit

struct Entry: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var category: String
    var type: String = "app"
    var targets: [String] = []
}

@MainActor final class Library: ObservableObject {
    @Published var entries: [Entry] = [] { didSet { save() } }
    @Published var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "MyHub.favorites") ?? []) { didSet { UserDefaults.standard.set(Array(favorites), forKey: "MyHub.favorites") } }
    @Published private(set) var favoriteOrder: [String] = UserDefaults.standard.stringArray(forKey: "MyHub.favoriteOrder") ?? [] {
        didSet { UserDefaults.standard.set(favoriteOrder, forKey: "MyHub.favoriteOrder") }
    }
    @Published private(set) var runningPaths = Set<String>()
    private var workspaceObservers: [NSObjectProtocol] = []
    @Published var customCategories: [String] = UserDefaults.standard.stringArray(forKey: "MyHub.customCategories") ?? [] {
        didSet { UserDefaults.standard.set(customCategories, forKey: "MyHub.customCategories") }
    }
    let builtInCategories = ["Coding", "Kreativ", "Medien", "Kommunikation", "Spiele", "Werkzeuge", "Ordner", "Shortcuts"]
    var categories: [String] { ["Alle", "Favoriten"] + builtInCategories + customCategories }
    private let key = "MyHub.entries.v2"
    init() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([Entry].self, from: data) { entries = saved }
        else { discover() }
        if UserDefaults.standard.object(forKey: "MyHub.favorites") == nil {
            favorites = Set(entries.filter { ["Visual Studio Code", "Xcode", "Spotify", "Steam"].contains($0.name) }.map(\.path))
        }
        refreshRunningApps()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshRunningApps() }
            }
            workspaceObservers.append(observer)
        }
    }
    func orderedFavorites() -> [Entry] {
        var positions: [String: Int] = [:]
        for (index, path) in favoriteOrder.enumerated() where positions[path] == nil { positions[path] = index }
        return entries.enumerated().filter { favorites.contains($0.element.path) }
            .sorted { left, right in
                let a = positions[left.element.path] ?? Int.max
                let b = positions[right.element.path] ?? Int.max
                return a == b ? left.offset < right.offset : a < b
            }.map(\.element)
    }
    func moveFavorite(_ path: String, to index: Int) {
        var paths = orderedFavorites().map(\.path)
        guard let current = paths.firstIndex(of: path) else { return }
        paths.remove(at: current)
        paths.insert(path, at: min(max(index, 0), paths.count))
        favoriteOrder = paths
    }
    private func refreshRunningApps() {
        let current = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        if current != runningPaths { runningPaths = current }
    }
    func isRunning(_ entry: Entry) -> Bool {
        entry.type == "app" && runningPaths.contains(URL(fileURLWithPath: entry.path).standardizedFileURL.path)
    }
    func activate(_ entry: Entry) {
        if let running = runningApplication(for: entry) { running.activate() }
        else { launch(entry) }
    }
    func save() { if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) } }
    func discover() {
        let groups: [(String, [String])] = [
            ("Coding", ["Visual Studio Code", "Code", "Xcode", "iTerm", "Terminal", "ChatGPT", "Claude", "Obsidian", "Miyo", "Prompt Master"]),
            ("Kreativ", ["Draw Things", "Pixelmator Pro", "Affinity Photo", "Photomator", "Keynote", "Fotos", "Vorschau"]),
            ("Medien", ["Spotify", "Musik", "Podcasts", "QuickTime Player", "Simple Comic", "JDownloader2", "Hot Tub"]),
            ("Kommunikation", ["WhatsApp", "Discord", "Nachrichten", "Mail", "Kontakte"]),
            ("Spiele", ["Steam", "Whisky", "PlayCover", "Unturned", "ROUNDS"]),
            ("Werkzeuge", ["Finder", "Systemeinstellungen", "App Store", "Rechner", "Kalender", "Passwörter", "AppCleaner", "DaisyDisk", "ProtonVPN"])
        ]
        var seen = Set<String>()
        var discovered: [Entry] = []
        for (category, names) in groups {
            for name in names {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(name)) ?? findApp(name), seen.insert(url.path).inserted else { continue }
                discovered.append(Entry(name: url.deletingPathExtension().lastPathComponent, path: url.path, category: category))
            }
        }
        entries = discovered
    }
    private func bundleID(_ name: String) -> String { ["Code":"com.microsoft.VSCode", "Xcode":"com.apple.dt.Xcode", "Spotify":"com.spotify.client", "Steam":"com.valvesoftware.steam", "Finder":"com.apple.finder", "Obsidian":"md.obsidian"][name] ?? "" }
    private func findApp(_ name: String) -> URL? {
        for root in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
            let url = URL(fileURLWithPath: root).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
    func add() {
        let panel = NSOpenPanel()
        panel.title = "Apps oder Ordner hinzufügen"
        panel.message = "Wähle eine .app oder einen Ordner aus. Programme findest du unter Programme."
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let selected = url.standardizedFileURL
            guard !entries.contains(where: { $0.path == selected.path }) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            entries.append(Entry(name: selected.deletingPathExtension().lastPathComponent, path: selected.path, category: selected.pathExtension.lowercased() == "app" ? "Werkzeuge" : "Ordner", type: selected.pathExtension.lowercased() == "app" ? "app" : "folder"))
        }
    }
    func launch(_ entry: Entry) {
        if entry.type == "shortcut" { for path in entry.targets { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) }
    }
    func runningApplication(for entry: Entry) -> NSRunningApplication? {
        guard entry.type == "app" else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: entry.path).standardizedFileURL.path }
    }
    func close(_ entry: Entry) { _ = runningApplication(for: entry)?.terminate() }
    func addCategory(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 24, !categories.contains(where: { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return false }
        customCategories.append(name)
        return true
    }
    func renameCategory(_ old: String, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard customCategories.contains(old), !name.isEmpty, name.count <= 24,
              !categories.contains(where: { $0 != old && $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return false }
        if let index = customCategories.firstIndex(of: old) { customCategories[index] = name }
        var updated = entries
        for index in updated.indices where updated[index].category == old { updated[index].category = name }
        if updated != entries { entries = updated }
        return true
    }
    func removeCategory(_ name: String) {
        customCategories.removeAll { $0 == name }
        var updated = entries
        for index in updated.indices where updated[index].category == name { updated[index].category = "Werkzeuge" }
        if updated != entries { entries = updated }
    }
}

@main struct MyHubApp: App {
    @StateObject private var library = Library()
    @StateObject private var floating = FloatingHub()
    init() {
        if let iconURL = Bundle.main.url(forResource: "MyHub", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    var body: some Scene { WindowGroup("MyHub") { HubView().environmentObject(library).environmentObject(floating).task { floating.install(library: library) } }.windowResizability(.contentSize) }
}

struct HubView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var floating: FloatingHub
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("MyHub.compact") private var compact = false
    @AppStorage("MyHub.animations") private var animations = true
    @AppStorage("MyHub.wheelSpeed") private var wheelSpeed = 1.0
    @AppStorage("MyHub.wheelScale") private var wheelScale = 1.0
    @AppStorage("MyHub.closeDelay") private var closeDelay = 0.22
    @AppStorage("MyHub.animationDuration") private var animationDuration = 0.16
    @State private var category = "Alle"
    @State private var showingCategoryEditor = false
    @State private var editingCategory: String?
    @State private var categoryDraft = ""
    @State private var categoryError = false
    @State private var search = ""
    @State private var showingShortcut = false
    @State private var shortcutName = ""
    @State private var shortcutTargets = Set<String>()
    private var transition: Animation? { animations && !reduceMotion ? .easeOut(duration: 0.18) : nil }
    var filtered: [Entry] { library.entries.filter { entry in (category == "Alle" || (category == "Favoriten" ? library.favorites.contains(entry.path) : entry.category == category)) && (search.isEmpty || entry.name.localizedCaseInsensitiveContains(search)) } }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) { Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.mint); Text("MyHub").font(.title2.weight(.semibold)) }
                categorySidebar
                Button("Kategorie hinzufügen", systemImage: "plus.circle") { editingCategory = nil; categoryDraft = ""; categoryError = false; showingCategoryEditor = true }.buttonStyle(.plain)
                Spacer()
                Button("App hinzufügen", systemImage: "plus") { library.add() }.buttonStyle(.borderedProminent)
                Button("Shortcut erstellen", systemImage: "bolt") { showingShortcut = true }.buttonStyle(.plain)
            }.padding(18).frame(minWidth: 205)
        } detail: {
            VStack(alignment: .leading, spacing: 22) {
                HStack { VStack(alignment: .leading, spacing: 4) { Text(category).font(.largeTitle.weight(.semibold)); Text("Deine Programme und Abläufe an einem Ort").foregroundStyle(.secondary) }; Spacer(); TextField("App suchen", text: $search).textFieldStyle(.roundedBorder).frame(width: 220) }
                if category == "Einstellungen" { ScrollView { settings.frame(maxWidth: .infinity, alignment: .topLeading) } }
                else if filtered.isEmpty { VStack(alignment: .leading, spacing: 12) { Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary); Text("Hier ist noch nichts").font(.title2.weight(.semibold)); Text(search.isEmpty ? "Füge eine App hinzu, um sie hier zu sehen." : "Versuche einen anderen Suchbegriff.").foregroundStyle(.secondary); Button("App hinzufügen", systemImage: "plus") { library.add() }.buttonStyle(.borderedProminent) }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center) }
                else { ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 180 : 230), spacing: 12)], spacing: 12) { ForEach(filtered) { entry in
                    Button { library.launch(entry) } label: { HStack(spacing: 13) { icon(entry).frame(width: 40, height: 40); VStack(alignment: .leading, spacing: 3) { Text(entry.name).font(.headline).lineLimit(1); Text(entry.category).font(.caption).foregroundStyle(.secondary) }; Spacer() }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 13)) }.buttonStyle(.plain).contextMenu { Button(library.favorites.contains(entry.path) ? "Favorit entfernen" : "Als Favorit markieren") { if !library.favorites.insert(entry.path).inserted { library.favorites.remove(entry.path) } }; if library.runningApplication(for: entry) != nil { Button("App schließen") { library.close(entry) } }; Menu("Kategorie") { ForEach(library.categories.filter { !["Alle", "Favoriten"].contains($0) }, id: \.self) { name in Button(name) { if let index = library.entries.firstIndex(where: { $0.id == entry.id }) { library.entries[index].category = name } } } }; Button("Aus MyHub entfernen", role: .destructive) { library.entries.removeAll { $0.id == entry.id } } } } } } }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).frame(minWidth: 720, minHeight: 560)
        }
        .sheet(isPresented: $showingShortcut) { VStack(alignment: .leading, spacing: 14) { Text("Neuer Shortcut").font(.title2.bold()); TextField("Name", text: $shortcutName); Text("Apps auswählen").font(.headline); ScrollView { ForEach(library.entries.filter { $0.type == "app" }) { entry in Toggle(entry.name, isOn: Binding(get: { shortcutTargets.contains(entry.path) }, set: { if $0 { shortcutTargets.insert(entry.path) } else { shortcutTargets.remove(entry.path) } })) } }.frame(height: 240); HStack { Spacer(); Button("Abbrechen") { showingShortcut = false }; Button("Erstellen") { library.entries.append(Entry(name: shortcutName, path: UUID().uuidString, category: "Shortcuts", type: "shortcut", targets: Array(shortcutTargets))); shortcutName = ""; shortcutTargets = []; showingShortcut = false }.disabled(shortcutName.isEmpty || shortcutTargets.isEmpty).buttonStyle(.borderedProminent) } }.padding(24).frame(width: 420) }
        .sheet(isPresented: $showingCategoryEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text(editingCategory == nil ? "Kategorie hinzufügen" : "Kategorie umbenennen").font(.title2.weight(.semibold))
                TextField("Name der Kategorie", text: $categoryDraft).textFieldStyle(.roundedBorder)
                if categoryError { Text("Wähle einen anderen Namen mit höchstens 24 Zeichen.").font(.caption).foregroundStyle(.red) }
                HStack { Spacer(); Button("Abbrechen") { showingCategoryEditor = false }; Button("Speichern") {
                    let saved = editingCategory.map { library.renameCategory($0, to: categoryDraft) } ?? library.addCategory(categoryDraft)
                    if saved { if category == editingCategory { category = categoryDraft.trimmingCharacters(in: .whitespacesAndNewlines) }; showingCategoryEditor = false }
                    else { categoryError = true }
                }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 380)
        }
        .onChange(of: wheelScale) { _, _ in floating.refreshSize() }
    }
    private var categorySidebar: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(library.categories + ["Einstellungen"], id: \.self) { item in
                    Button { withAnimation(transition) { category = item } } label: {
                        Label(item, systemImage: symbol(item)).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.horizontal, 10)
                        .background(category == item ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contextMenu {
                            if library.customCategories.contains(item) {
                                Button("Umbenennen") { editingCategory = item; categoryDraft = item; categoryError = false; showingCategoryEditor = true }
                                Button("Kategorie löschen", role: .destructive) { library.removeCategory(item); if category == item { category = "Alle" } }
                            }
                        }
                }
            }
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Darstellung").font(.title2.weight(.semibold))
            Toggle("Kompakte Kacheln", isOn: $compact)
            Toggle("Animationen", isOn: $animations)
            Divider()
            Text("Schwebendes Menü").font(.title2.weight(.semibold))
            Toggle("Über anderen Fenstern anzeigen", isOn: $floating.enabled)
            settingSlider("Kreisgröße", value: $wheelScale, range: 0.85...1.15, format: "%.0f %%", multiplier: 100)
            settingSlider("Scrolltempo", value: $wheelSpeed, range: 0.6...1.8, format: "%.1f ×")
            settingSlider("Schließverzögerung", value: $closeDelay, range: 0.10...0.60, format: "%.2f s")
            settingSlider("Animationstempo", value: $animationDuration, range: 0.10...0.30, format: "%.2f s")
            Button("Favoriten im Kreis anordnen") { floating.startFavoriteEditing() }
                .buttonStyle(.bordered)
            Text("⌘ ⇧ Leertaste öffnet den Kreis. Pfeiltasten wählen, Return startet, Esc geht zurück.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Favoriten legst du per Rechtsklick auf eine App fest. Den Kreis kannst du verschieben.")
                .foregroundStyle(.secondary)
            Divider()
            Text("Bibliothek").font(.title2.weight(.semibold))
            Text("Entfernte Apps kannst du jederzeit wieder hinzufügen.").foregroundStyle(.secondary)
            Button("Weitere Apps hinzufügen", systemImage: "plus") { library.add() }.buttonStyle(.bordered)
        }.frame(maxWidth: 480, alignment: .leading)
    }

    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, multiplier: Double = 1) -> some View {
        HStack {
            Text(title).frame(width: 140, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue * multiplier))
                .monospacedDigit().frame(width: 65, alignment: .trailing)
        }
    }
    func icon(_ entry: Entry) -> some View { Group { if entry.type == "shortcut" { Image(systemName: "bolt.fill").font(.title).foregroundStyle(.orange) } else { Image(nsImage: WheelIcons.image(for: entry.path)).resizable().interpolation(.high).scaledToFit() } } }
    func symbol(_ name: String) -> String { ["Alle":"square.grid.2x2", "Favoriten":"star", "Coding":"chevron.left.forwardslash.chevron.right", "Kreativ":"paintbrush", "Medien":"play.rectangle", "Kommunikation":"bubble.left", "Spiele":"gamecontroller", "Werkzeuge":"wrench", "Ordner":"folder", "Shortcuts":"bolt", "Einstellungen":"gearshape" ][name] ?? "circle" }
}
