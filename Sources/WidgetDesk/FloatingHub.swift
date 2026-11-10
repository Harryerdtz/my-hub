import AppKit
import Carbon.HIToolbox
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    var onWheel: ((NSEvent) -> Bool)?
    var onKeyDown: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, onWheel?(event) == true { return }
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}

final class FloatingContentView: NSHostingView<WheelView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum WheelLevel: Equatable { case favorites, categories, apps(String) }
enum WheelEdge: Equatable { case left, right, top, bottom }

private struct GlassAnnulus: Shape {
    let innerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        path.closeSubpath()
        path.move(to: CGPoint(x: center.x + innerRadius, y: center.y))
        path.addArc(center: center, radius: innerRadius, startAngle: .zero, endAngle: .degrees(360), clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct CenterReveal: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        return Path(ellipseIn: CGRect(x: rect.midX - radius, y: rect.midY - radius,
                                      width: radius * 2, height: radius * 2))
    }
}

@MainActor final class FloatingHub: ObservableObject {
    @Published var enabled = UserDefaults.standard.object(forKey: "MyHub.floatingEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "MyHub.floatingEnabled")
            if enabled { panel?.orderFrontRegardless() }
            else {
                if expanded { isClosing = true; finishClose() }
                panel?.orderOut(nil)
            }
        }
    }
    @Published private(set) var expanded = false
    @Published private(set) var isClosing = false
    @Published var level: WheelLevel = .favorites {
        didSet {
            cancelSnap()
            cancelExit()
            if oldValue == .favorites { favoriteRotation = rotation }
            if oldValue == .categories { categoryRotation = rotation }
            switch level {
            case .favorites: rotation = favoriteRotation
            case .categories: rotation = categoryRotation
            case .apps: rotation = 0
            }
            lastHapticStep = Int(rotation.rounded())
            hoveredID = nil
            if level != .favorites { editingFavorites = false }
            resizeForLevel()
        }
    }
    @Published private(set) var panelSide: CGFloat = 310
    @Published var edge: WheelEdge?
    @Published var hoveredID: String?
    @Published var editingFavorites = false
    @Published var draggingFavorite = false
    @Published var rotation: Double = 0
    private(set) var favoriteRotation: Double = 0
    private(set) var categoryRotation: Double = 0
    @Published var dragging = false

    private var panel: FloatingPanel?
    private var restingOrigin: NSPoint?
    private var wheelCenter: NSPoint?
    private var dragOrigin: NSPoint?
    private var pointerOrigin: NSPoint?
    private var lastHapticStep = 0
    private var snapTimer: Timer?
    private var exitTimer: Timer?
    private var closeTimer: Timer?
    private var lastHapticTime: TimeInterval = 0
    private var scrollingUntil: TimeInterval = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    let launcherSide: CGFloat = 60
    private var small: CGFloat { launcherSide }
    private let smallWheel: CGFloat = 310
    private var closeDuration: TimeInterval { min(0.30, max(0.10, UserDefaults.standard.object(forKey: "MyHub.animationDuration") as? Double ?? 0.16)) }
    private var wheelScale: CGFloat { CGFloat(min(1.15, max(0.85, UserDefaults.standard.object(forKey: "MyHub.wheelScale") as? Double ?? 1))) }

    func install(library: Library) {
        guard panel == nil else { return }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let saved = UserDefaults.standard.array(forKey: "MyHub.wheelOrigin") as? [Double]
        let origin = saved?.count == 2 ? NSPoint(x: saved![0], y: saved![1]) : NSPoint(x: screen.maxX - small - 12, y: screen.midY - small / 2)
        let window = FloatingPanel(contentRect: NSRect(origin: origin, size: NSSize(width: small, height: small)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.contentView = FloatingContentView(rootView: WheelView(hub: self, library: library))
        window.onWheel = { [weak self, weak library] event in
            guard let self, let library else { return false }
            return self.rotate(event, library: library)
        }
        window.onKeyDown = { [weak self, weak library] event in
            guard let self, let library else { return false }
            return self.handleKey(event, library: library)
        }
        panel = window
        installHotKey()
        clampCollapsedPosition()
        if enabled { window.orderFrontRegardless() }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.expanded, let panel = self.panel else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) { self.close() }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak window] event in
            if let self, self.expanded, event.window !== window { self.close() }
            return event
        }
    }

    private func installHotKey() {
        let shortcutID = EventHotKeyID(signature: 0x4D594855, id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), shortcutID,
                                             GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hub = Unmanaged<FloatingHub>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                if hub.expanded { hub.close() } else { hub.open() }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    private func rotate(_ event: NSEvent, library: Library) -> Bool {
        guard expanded else { return false }
        let total = availableCount(in: library)
        guard total > activeCapacity else { return false }
        let delta = Double(event.scrollingDeltaY)
        guard delta != 0 else { scheduleSnap(); return true }
        scrollingUntil = ProcessInfo.processInfo.systemUptime + 0.18
        if hoveredID != nil { hoveredID = nil }
        if event.hasPreciseScrollingDeltas {
            let momentumFactor = event.momentumPhase == [] ? 1.0 : 0.7
            let speed = max(0.6, min(1.8, UserDefaults.standard.object(forKey: "MyHub.wheelSpeed") as? Double ?? 1.0))
            rotation -= min(3.5, max(-3.5, delta / 32 * speed * momentumFactor))
            scheduleSnap(after: event.momentumPhase == [] ? 0.11 : 0.14)
        } else {
            let steps = min(3, max(1, Int(abs(delta / 3).rounded())))
            let target = rotation.rounded() - (delta > 0 ? Double(steps) : -Double(steps))
            withAnimation(.easeOut(duration: 0.10)) { rotation = target }
        }
        let step = Int(rotation.rounded())
        if step != lastHapticStep {
            lastHapticStep = step
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastHapticTime > 0.055 {
                lastHapticTime = now
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        return true
    }

    private func handleKey(_ event: NSEvent, library: Library) -> Bool {
        guard expanded, !isClosing else { return false }
        switch event.keyCode {
        case 53: back()
        case 126: back()
        case 125:
            if level == .favorites { level = .categories }
            else if case .categories = level {
                let options = wheelOptions(in: library)
                guard !options.isEmpty else { return true }
                let index = ((Int(rotation.rounded()) % options.count) + options.count) % options.count
                if case .category(let name) = options[index] { level = .apps(name) }
            }
        case 123, 124:
            let options = wheelOptions(in: library)
            guard !options.isEmpty else { return true }
            let direction = event.keyCode == 124 ? 1.0 : -1.0
            withAnimation(.easeOut(duration: 0.12)) { rotation += direction }
            let index = ((Int(rotation.rounded()) % options.count) + options.count) % options.count
            hoveredID = options[index].id
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case 36, 76:
            let options = wheelOptions(in: library)
            guard !options.isEmpty else { return true }
            let index = ((Int(rotation.rounded()) % options.count) + options.count) % options.count
            switch options[index] {
            case .entry(let entry): library.launch(entry); close()
            case .category(let name): level = .apps(name)
            case .categories: level = .categories
            case .addCategory: promptCategory(library: library)
            }
        default: return false
        }
        return true
    }

    private func wheelOptions(in library: Library) -> [WheelOption] {
        switch level {
        case .favorites:
            return library.orderedFavorites().map(WheelOption.entry)
                + (edge == nil ? [.categories] : [])
        case .categories:
            return library.categories.filter { !["Alle", "Favoriten"].contains($0) }.map(WheelOption.category) + [.addCategory]
        case .apps(let name):
            return library.entries.filter { $0.category == name }.map(WheelOption.entry)
        }
    }

    func reorderFavorite(_ path: String, library: Library) {
        defer { draggingFavorite = false }
        guard editingFavorites, level == .favorites, let panel else { return }
        let favorites = library.orderedFavorites()
        let count = favorites.count + (edge == nil ? 1 : 0)
        let slots = max(1, min(edge == nil ? 6 : 3, count))
        let radius = (edge == nil ? 100.0 : 90.0) * wheelScale
        let pointer = NSEvent.mouseLocation
        var nearest: (index: Int, distance: CGFloat)?
        for index in favorites.indices {
            var phase = Double(index)
            if count > slots {
                phase = (Double(index) - rotation).truncatingRemainder(dividingBy: Double(count))
                if phase < -0.5 { phase += Double(count) }
                if phase > Double(count) - 0.5 { phase -= Double(count) }
            }
            guard phase >= -0.5, phase <= Double(slots) - 0.5 else { continue }
            let step = phase * 2.2 / Double(max(slots - 1, 1))
            let angle: Double
            switch edge {
            case .left: angle = -1.1 + step
            case .right: angle = .pi - 1.1 + step
            case .top: angle = .pi / 2 - 1.1 + step
            case .bottom: angle = 3 * .pi / 2 - 1.1 + step
            case nil: angle = -.pi / 2 + phase * 2 * .pi / Double(slots)
            }
            let x = panel.frame.midX + radius * cos(angle)
            let y = panel.frame.midY - radius * sin(angle)
            let distance = hypot(pointer.x - x, pointer.y - y)
            if nearest == nil || distance < nearest!.distance { nearest = (index, distance) }
        }
        if let nearest, nearest.distance <= 60 * wheelScale {
            library.moveFavorite(path, to: nearest.index)
        }
    }

    func promptCategory(library: Library, renaming oldName: String? = nil) {
        close()
        panel?.orderOut(nil)
        let waitMilliseconds = Int((closeDuration + 0.06) * 1000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(waitMilliseconds))
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = oldName == nil ? "Kategorie hinzufügen" : "Kategorie umbenennen"
            alert.informativeText = "Name mit höchstens 24 Zeichen"
            alert.addButton(withTitle: "Speichern")
            alert.addButton(withTitle: "Abbrechen")
            let field = NSTextField(string: oldName ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            NSApp.activate(ignoringOtherApps: true)
            var saved = false
            while alert.runModal() == .alertFirstButtonReturn {
                saved = oldName.map { library.renameCategory($0, to: field.stringValue) }
                    ?? library.addCategory(field.stringValue)
                if saved { break }
                alert.informativeText = "Bitte einen neuen Namen mit höchstens 24 Zeichen eingeben."
                NSSound.beep()
            }
            if self.enabled { self.panel?.orderFrontRegardless() }
            if saved { self.open(); self.level = .categories }
        }
    }

    func refreshSize() { resizeForLevel() }

    func startFavoriteEditing() {
        guard enabled else { return }
        if !expanded { open() }
        level = .favorites
        rotation = rotation.rounded()
        editingFavorites = true
    }

    private func scheduleSnap(after delay: TimeInterval = 0.11) {
        if let snapTimer {
            snapTimer.fireDate = Date().addingTimeInterval(delay)
            return
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.snapTimer = nil
                self?.snapRotation()
            }
        }
        snapTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelSnap() {
        snapTimer?.invalidate()
        snapTimer = nil
    }

    func pointerMoved(_ location: CGPoint?, in side: CGFloat) {
        guard expanded, !isClosing, !draggingFavorite else { cancelExit(); return }
        if let location, hypot(location.x - side / 2, location.y - side / 2) <= side / 2 - 2 {
            cancelExit()
        } else {
            scheduleExit()
        }
    }

    private func scheduleExit() {
        guard exitTimer == nil else { return }
        let delay = min(0.60, max(0.10, UserDefaults.standard.object(forKey: "MyHub.closeDelay") as? Double ?? 0.22))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.exitTimer = nil
                guard self.expanded, let panel = self.panel else { return }
                let pointer = NSEvent.mouseLocation
                if hypot(pointer.x - panel.frame.midX, pointer.y - panel.frame.midY) > self.panelSide / 2 - 2 {
                    self.close()
                }
            }
        }
        exitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelExit() {
        exitTimer?.invalidate()
        exitTimer = nil
    }

    private func snapRotation() {
        let target = rotation.rounded()
        guard abs(target - rotation) > 0.001 else { return }
        withAnimation(.spring(response: 0.29, dampingFraction: 1)) { rotation = target }
    }

    private func availableCount(in library: Library) -> Int {
        switch level {
        case .favorites: return library.orderedFavorites().count + (edge == nil ? 1 : 0)
        case .categories: return library.categories.filter { !["Alle", "Favoriten"].contains($0) }.count + 1
        case .apps(let name): return library.entries.filter { $0.category == name }.count
        }
    }

    private var activeCapacity: Int {
        switch level {
        case .favorites: edge == nil ? 6 : 3
        case .categories: edge == nil ? 8 : 4
        case .apps: edge == nil ? 10 : 5
        }
    }

    private func resizeForLevel() {
        guard expanded, let panel else { return }
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let desired: CGFloat
        switch level {
        case .favorites: desired = edge == nil ? smallWheel : 290
        case .categories: desired = edge == nil ? 490 : 470
        case .apps: desired = edge == nil ? 690 : 660
        }
        let side = min(desired * wheelScale, screen.height - 20)
        let center = wheelCenter ?? NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panelSide = side
        let frame = NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        panel.setFrame(frame, display: true)
        panel.setFrameOrigin(frame.origin)
    }

    func open() {
        guard enabled, let panel, !expanded else { return }
        closeTimer?.invalidate()
        closeTimer = nil
        isClosing = false
        cancelExit()
        restingOrigin = panel.frame.origin
        favoriteRotation = 0
        categoryRotation = 0
        rotation = 0
        level = .favorites
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let distances: [(WheelEdge, CGFloat)] = [(.left, center.x - screen.minX), (.right, screen.maxX - center.x), (.bottom, center.y - screen.minY), (.top, screen.maxY - center.y)]
        edge = distances.min { $0.1 < $1.1 }.flatMap { $0.1 < 112 ? $0.0 : nil }
        wheelCenter = center
        let side = (edge == nil ? smallWheel : 290) * wheelScale
        panelSide = side
        let frame = NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        panel.setFrame(frame, display: true)
        panel.setFrameOrigin(frame.origin)
        expanded = true
        panel.makeKeyAndOrderFront(nil)
    }
    func close() {
        guard expanded, !isClosing else { return }
        isClosing = true
        cancelSnap()
        cancelExit()
        hoveredID = nil
        editingFavorites = false
        draggingFavorite = false
        lastHapticStep = 0
        let timer = Timer(timeInterval: closeDuration + 0.02, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishClose() }
        }
        closeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishClose() {
        guard let panel, isClosing else { return }
        closeTimer?.invalidate()
        closeTimer = nil
        expanded = false
        isClosing = false
        panelSide = smallWheel
        let origin = restingOrigin ?? panel.frame.origin
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: small, height: small)), display: true)
        wheelCenter = nil
        clampCollapsedPosition()
    }
    func back() {
        switch level { case .favorites: close(); case .categories: level = .favorites; case .apps: level = .categories }
    }
    func hover(_ id: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now > scrollingUntil else { return }
        guard hoveredID != id else { return }
        hoveredID = id
        if id != nil && now - lastHapticTime > 0.055 {
            lastHapticTime = now
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
    func beginDrag() {
        guard !dragging, let panel else { return }
        dragging = true
        dragOrigin = panel.frame.origin
        pointerOrigin = NSEvent.mouseLocation
    }
    func updateDrag() {
        guard dragging, let panel, let dragOrigin, let pointerOrigin else { return }
        let pointer = NSEvent.mouseLocation
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let x = min(max(dragOrigin.x + pointer.x - pointerOrigin.x, screen.minX), screen.maxX - small)
        let y = min(max(dragOrigin.y + pointer.y - pointerOrigin.y, screen.minY), screen.maxY - small)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    func endDrag() {
        guard dragging else { return }
        dragging = false
        dragOrigin = nil
        pointerOrigin = nil
        clampCollapsedPosition()
    }
    private func clampCollapsedPosition() {
        guard let panel else { return }
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let frame = panel.frame
        let candidates: [(WheelEdge, CGFloat)] = [(.left, frame.minX - screen.minX), (.right, screen.maxX - frame.maxX), (.bottom, frame.minY - screen.minY), (.top, screen.maxY - frame.maxY)]
        let closest = candidates.min { $0.1 < $1.1 }
        edge = (closest?.1 ?? 100) < 34 ? closest?.0 : nil
        let x = min(max(edge == .left ? screen.minX + 5 : edge == .right ? screen.maxX - small - 5 : frame.minX, screen.minX), screen.maxX - small)
        let y = min(max(edge == .bottom ? screen.minY + 5 : edge == .top ? screen.maxY - small - 5 : frame.minY, screen.minY), screen.maxY - small)
        let target = NSPoint(x: x, y: y)
        if dragging { panel.setFrameOrigin(target) }
        else { NSAnimationContext.runAnimationGroup { context in context.duration = 0.22; context.timingFunction = CAMediaTimingFunction(name: .easeOut); panel.animator().setFrameOrigin(target) } }
        UserDefaults.standard.set([Double(x), Double(y)], forKey: "MyHub.wheelOrigin")
    }
}

private enum WheelOption: Identifiable {
    case entry(Entry), category(String), categories, addCategory
    var id: String {
        switch self { case .entry(let entry): return entry.id.uuidString; case .category(let name): return "category:\(name)"; case .categories: return "all-categories"; case .addCategory: return "add-category" }
    }
    var title: String {
        switch self { case .entry(let entry): return entry.name; case .category(let name): return name; case .categories: return "Kategorien"; case .addCategory: return "Hinzufügen" }
    }
}

@MainActor enum WheelIcons {
    static var cache: [String: NSImage] = [:]
    static func image(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

@MainActor private struct WheelMotion: AnimatableModifier {
    var rotation: Double
    let index: Int
    let count: Int
    let capacity: Int
    let edge: WheelEdge?
    let radius: CGFloat

    nonisolated var animatableData: Double {
        get { rotation }
        set { rotation = newValue }
    }

    func body(content: Content) -> some View {
        let slots = max(1, min(capacity, count))
        var phase = Double(index)
        if count > slots {
            phase = (Double(index) - rotation).truncatingRemainder(dividingBy: Double(count))
            if phase < -0.5 { phase += Double(count) }
            if phase > Double(count) - 0.5 { phase -= Double(count) }
        }
        let angle: Double
        switch edge {
        case .left: angle = -1.1 + phase * 2.2 / Double(max(slots - 1, 1))
        case .right: angle = .pi - 1.1 + phase * 2.2 / Double(max(slots - 1, 1))
        case .top: angle = .pi / 2 - 1.1 + phase * 2.2 / Double(max(slots - 1, 1))
        case .bottom: angle = 3 * .pi / 2 - 1.1 + phase * 2.2 / Double(max(slots - 1, 1))
        case nil: angle = -.pi / 2 + phase * 2 * .pi / Double(slots)
        }
        let visibility: Double
        if count <= slots { visibility = 1 }
        else { visibility = min(1, max(0, (phase + 0.5) * 2), max(0, (Double(slots) - 0.5 - phase) * 2)) }
        return content
            .offset(x: radius * cos(angle), y: radius * sin(angle))
            .opacity(visibility)
            .allowsHitTesting(visibility > 0.75)
    }
}

struct WheelView: View {
    @ObservedObject var hub: FloatingHub
    @ObservedObject var library: Library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("MyHub.animations") private var animations = true
    @AppStorage("MyHub.wheelScale") private var wheelScale = 1.0
    @AppStorage("MyHub.animationDuration") private var animationDuration = 0.16
    @State private var revealRadius: CGFloat = 21
    @State private var launcherOpacity: CGFloat = 1
    @State private var dragMoved = false
    @State private var draggedFavorite: String?
    @State private var favoriteDragOffset: CGSize = .zero
    private var side: CGFloat { hub.panelSide }
    private var motion: Animation? { animations && !reduceMotion ? .easeOut(duration: animationDuration * 1.3) : nil }
    private var favoriteOptions: [WheelOption] {
        library.orderedFavorites().map(WheelOption.entry) + (hub.edge == nil ? [.categories] : [])
    }
    private var categoryOptions: [WheelOption] {
        library.categories.filter { !["Alle", "Favoriten"].contains($0) }.map(WheelOption.category) + [.addCategory]
    }
    private var appOptions: [WheelOption] {
        guard case .apps(let name) = hub.level else { return [] }
        return library.entries.filter { $0.category == name }.map(WheelOption.entry)
    }
    private var centerOffset: CGSize {
        switch hub.edge {
        case .left: CGSize(width: 24, height: 0)
        case .right: CGSize(width: -24, height: 0)
        case .top: CGSize(width: 0, height: 24)
        case .bottom: CGSize(width: 0, height: -24)
        case nil: .zero
        }
    }
    private var title: String {
        switch hub.level { case .favorites: return "Favoriten"; case .categories: return "Kategorien"; case .apps(let name): return name }
    }
    private var innerDiameter: CGFloat { hub.edge == nil ? 286 : 270 }
    private var categoryInnerRadius: CGFloat { hub.edge == nil ? 151 : 143 }
    private var categoryOuterRadius: CGFloat { categoryInnerRadius + (hub.edge == nil ? 88 : 84) }
    private var appInnerRadius: CGFloat { categoryOuterRadius + 8 }
    private var appOuterRadius: CGFloat { appInnerRadius + (hub.edge == nil ? 88 : 84) }
    private var categoryRadius: CGFloat { (categoryInnerRadius + categoryOuterRadius) / 2 }
    private var appRadius: CGFloat { (appInnerRadius + appOuterRadius) / 2 }
    private var fullRevealDiameter: CGFloat {
        switch hub.level {
        case .favorites: hub.edge == nil ? 310 : 290
        case .categories: hub.edge == nil ? 490 : 470
        case .apps: hub.edge == nil ? 690 : 660
        }
    }
    var body: some View {
        ZStack {
            if hub.expanded {
                Color.clear.contentShape(Rectangle()).onTapGesture { hub.close() }
                menuContent
                    .frame(width: 710, height: 710)
                    .mask { CenterReveal(radius: revealRadius) }
                    .allowsHitTesting(revealRadius >= fullRevealDiameter / 2 - 2 && !hub.isClosing)
            } else {
                Button { if !dragMoved { hub.open() }; dragMoved = false } label: {
                    launcherFace.frame(width: 56, height: 56).contentShape(Circle())
                }.buttonStyle(.plain).opacity(launcherOpacity)
                    .simultaneousGesture(DragGesture(minimumDistance: 9).onChanged { _ in
                        if !hub.dragging { hub.beginDrag() }
                        dragMoved = true
                        hub.updateDrag()
                    }.onEnded { _ in hub.endDrag(); DispatchQueue.main.async { dragMoved = false } })
                    .accessibilityLabel("MyHub Schnellmenü öffnen")
            }
        }.scaleEffect(hub.expanded ? wheelScale : 1)
            .frame(width: hub.expanded ? side : hub.launcherSide, height: hub.expanded ? side : hub.launcherSide)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hub.pointerMoved(location, in: hub.expanded ? side : hub.launcherSide)
                case .ended: hub.pointerMoved(nil, in: hub.expanded ? side : hub.launcherSide)
                }
            }
            .onChange(of: hub.expanded) { _, isOpen in
                if isOpen {
                    launcherOpacity = 0
                    revealRadius = 21 / wheelScale
                    withAnimation(animations && !reduceMotion ? .easeOut(duration: animationDuration) : nil) {
                        revealRadius = fullRevealDiameter / 2
                    }
                } else {
                    launcherOpacity = 0
                    withAnimation(animations && !reduceMotion ? .easeOut(duration: 0.10) : nil) {
                        launcherOpacity = 1
                    }
                }
            }
            .onChange(of: hub.level) { _, _ in
                guard hub.expanded, !hub.isClosing else { return }
                withAnimation(motion) { revealRadius = fullRevealDiameter / 2 }
            }
            .onChange(of: hub.isClosing) { _, closing in
                if closing {
                    withAnimation(animations && !reduceMotion ? .easeOut(duration: animationDuration) : nil) {
                        revealRadius = 21 / wheelScale
                    }
                }
            }
    }
    private var menuContent: some View {
        ZStack {
            glassSurfaces
            menuItems
        }
    }
    @ViewBuilder private var glassSurfaces: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 0) { glassLayers }
        } else {
            glassLayers
        }
    }
    private var glassLayers: some View {
        ZStack {
            glassDisk
            if hub.level != .favorites {
                glassAnnulus(inner: categoryInnerRadius, outer: categoryOuterRadius)
                    .transition(.identity)
            }
            if case .apps = hub.level {
                glassAnnulus(inner: appInnerRadius, outer: appOuterRadius)
                    .transition(.identity)
            }
        }.allowsHitTesting(false)
    }
    private var menuItems: some View {
        ZStack {
            ring(options: favoriteOptions, radius: hub.edge == nil ? 100 : 90, capacity: hub.edge == nil ? 6 : 3,
                 rotation: hub.level == .favorites ? hub.rotation : hub.favoriteRotation)
            if hub.level != .favorites {
                ring(options: categoryOptions, radius: categoryRadius, capacity: hub.edge == nil ? 8 : 4,
                     rotation: hub.level == .categories ? hub.rotation : hub.categoryRotation)
                    .transition(.identity)
            }
            if case .apps = hub.level {
                ring(options: appOptions, radius: appRadius, capacity: hub.edge == nil ? 10 : 5, rotation: hub.rotation)
                    .transition(.identity)
            }
            VStack(spacing: 5) {
                Button { withAnimation(motion) {
                    if hub.editingFavorites { hub.editingFavorites = false }
                    else if hub.edge != nil && hub.level == .favorites { hub.level = .categories }
                    else { hub.back() }
                } } label: {
                    Image(systemName: hub.editingFavorites ? "checkmark" : hub.level == .favorites ? (hub.edge == nil ? "xmark" : "square.grid.2x2") : "chevron.left")
                        .font(.system(size: hub.edge != nil && hub.level == .favorites ? 14 : 16, weight: .medium))
                        .frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(hub.editingFavorites ? "Anordnung fertig" : hub.level == .favorites ? (hub.edge == nil ? "Menü schließen" : "Kategorien") : "Zurück")
                    .contextMenu {
                        if hub.level == .favorites { Button("Favoriten anordnen") { hub.editingFavorites = true; hub.rotation = hub.rotation.rounded() } }
                        if hub.level == .categories { Button("Kategorie hinzufügen") { hub.promptCategory(library: library) } }
                    }
                Text(hub.editingFavorites ? "Anordnen" : hub.edge != nil && hub.level == .favorites ? "Kategorien" : title)
                    .font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center).frame(width: 106)
            }.foregroundStyle(.white).offset(centerOffset)
        }.frame(width: 710, height: 710)
    }
    @ViewBuilder private var glassDisk: some View {
        if #available(macOS 26, *) {
            Circle().fill(.clear).frame(width: innerDiameter, height: innerDiameter)
                .glassEffect(.regular, in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                .allowsHitTesting(false)
        } else {
            Circle().fill(.regularMaterial).frame(width: innerDiameter, height: innerDiameter)
                .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                .allowsHitTesting(false)
        }
    }
    @ViewBuilder private func glassAnnulus(inner: CGFloat, outer: CGFloat) -> some View {
        if #available(macOS 26, *) {
            GlassAnnulus(innerRadius: inner).fill(.clear)
                .frame(width: outer * 2, height: outer * 2)
                .glassEffect(.regular, in: GlassAnnulus(innerRadius: inner))
                .overlay { ringOutlines(inner: inner, outer: outer) }
                .allowsHitTesting(false)
        } else {
            GlassAnnulus(innerRadius: inner).fill(.regularMaterial)
                .frame(width: outer * 2, height: outer * 2)
                .overlay { ringOutlines(inner: inner, outer: outer) }
                .allowsHitTesting(false)
        }
    }
    private func ringOutlines(inner: CGFloat, outer: CGFloat) -> some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.20), lineWidth: 1).frame(width: outer * 2, height: outer * 2)
            Circle().strokeBorder(.white.opacity(0.20), lineWidth: 1).frame(width: inner * 2, height: inner * 2)
        }
    }
    @ViewBuilder private var launcherFace: some View {
        if #available(macOS 26, *) {
            LauncherMark()
                .scaleEffect(0.76)
                .foregroundStyle(.primary)
                .frame(width: 42, height: 42)
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            LauncherMark()
                .scaleEffect(0.76)
                .foregroundStyle(.primary)
                .frame(width: 42, height: 42)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
        }
    }
    private func ring(options: [WheelOption], radius: CGFloat, capacity: Int, rotation: Double) -> some View {
        ZStack {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                optionView(option)
                    .geometryGroup()
                    .modifier(WheelMotion(rotation: rotation, index: index, count: options.count, capacity: capacity, edge: hub.edge, radius: radius))
            }
        }
        .frame(width: radius * 2, height: radius * 2)
    }
    private func optionView(_ option: WheelOption) -> some View {
        let isCategory: Bool = {
            if case .category = option { return true }
            return false
        }()
        let isOuterApp: Bool = {
            if case .apps = hub.level { return !isCategory }
            return false
        }()
        let isEdgeFavorite = hub.edge != nil && hub.level == .favorites
        let compactItem = isCategory || isOuterApp || isEdgeFavorite
        let selected: Bool = {
            if case .apps(let name) = hub.level, case .category(let item) = option, item == name { return true }
            return hub.hoveredID == option.id
        }()
        return Button {
            withAnimation(motion) {
                switch option {
                case .entry(let entry):
                    guard !hub.editingFavorites else { return }
                    library.activate(entry); hub.close()
                case .category(let name): hub.level = .apps(name)
                case .categories: hub.level = .categories
                case .addCategory: hub.promptCategory(library: library)
                }
            }
        } label: {
            VStack(spacing: compactItem ? 2 : 3) {
                Group {
                    switch option {
                    case .entry(let entry): Image(nsImage: WheelIcons.image(for: entry.path)).resizable().interpolation(.high).scaledToFit().frame(width: 40, height: 40)
                    case .category(let name): Image(systemName: symbol(for: name)).font(.system(size: 21, weight: .medium))
                    case .categories: Image(systemName: "square.grid.2x2").font(.system(size: 22, weight: .medium))
                    case .addCategory: Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                    }
                }.frame(width: compactItem ? 52 : 55, height: compactItem ? 52 : 55)
                    .background(selected ? Color.white.opacity(0.28) : Color.white.opacity(0.10), in: Circle())
                    .animation(.easeOut(duration: 0.08), value: selected)
                    .overlay(alignment: .bottomTrailing) {
                        if case .entry(let entry) = option, library.isRunning(entry) {
                            Circle().fill(.green).frame(width: 9, height: 9)
                                .overlay { Circle().strokeBorder(.black.opacity(0.7), lineWidth: 1) }
                                .offset(x: -2, y: -2)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if hub.editingFavorites, hub.level == .favorites, case .entry = option {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 9, weight: .bold))
                                .padding(4).background(.thinMaterial, in: Circle())
                                .offset(x: 2, y: -2)
                        }
                    }
                Text(displayTitle(option.title)).font(.system(size: 10, weight: .medium))
                    .lineLimit(2).minimumScaleFactor(isCategory ? 0.88 : 0.9)
                    .multilineTextAlignment(.center)
                    .frame(width: compactItem ? 84 : 88, height: compactItem ? 28 : 30, alignment: .top)
            }.foregroundStyle(.white)
                .frame(width: isCategory || isEdgeFavorite ? 86 : isOuterApp ? 88 : 100,
                       height: compactItem ? 86 : 90)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .offset(draggedFavorite == option.id ? favoriteDragOffset : .zero)
            .zIndex(draggedFavorite == option.id ? 10 : 0)
            .simultaneousGesture(DragGesture(minimumDistance: 6)
                .onChanged { value in
                    guard hub.editingFavorites, hub.level == .favorites,
                          case .entry = option else { return }
                    draggedFavorite = option.id
                    favoriteDragOffset = value.translation
                    hub.draggingFavorite = true
                }
                .onEnded { _ in
                    guard draggedFavorite == option.id, case .entry(let entry) = option else { return }
                    hub.reorderFavorite(entry.path, library: library)
                    draggedFavorite = nil
                    favoriteDragOffset = .zero
                })
            .contextMenu {
                switch option {
                case .entry(let entry):
                    Button(library.isRunning(entry) ? "In den Vordergrund" : "Öffnen") {
                        library.activate(entry); hub.close()
                    }
                    if library.isRunning(entry) { Button("App schließen") { library.close(entry); hub.close() } }
                    Button(library.favorites.contains(entry.path) ? "Favorit entfernen" : "Als Favorit markieren") {
                        if !library.favorites.insert(entry.path).inserted { library.favorites.remove(entry.path) }
                    }
                    if hub.level == .favorites { Button("Favoriten anordnen") { hub.editingFavorites = true; hub.rotation = hub.rotation.rounded() } }
                case .category(let name):
                    if library.customCategories.contains(name) {
                        Button("Umbenennen") { hub.promptCategory(library: library, renaming: name) }
                        Button("Kategorie löschen", role: .destructive) { library.removeCategory(name); hub.level = .categories }
                    }
                case .categories: Button("Kategorie hinzufügen") { hub.promptCategory(library: library) }
                case .addCategory: EmptyView()
                }
            }
            .onHover { hovering in hub.hover(hovering ? option.id : nil) }
            .accessibilityLabel(option.title)
    }
    private func symbol(for name: String) -> String {
        ["Coding":"chevron.left.forwardslash.chevron.right", "Kreativ":"paintbrush", "Medien":"play.rectangle", "Kommunikation":"bubble.left.and.bubble.right", "Spiele":"gamecontroller", "Werkzeuge":"wrench", "Ordner":"folder", "Shortcuts":"bolt"][name] ?? "circle.grid.2x2"
    }
    private func displayTitle(_ title: String) -> String {
        guard title.count > 14, let breakPoint = title.lastIndex(of: " ") else { return title }
        var result = title
        result.replaceSubrange(breakPoint...breakPoint, with: "\n")
        return result
    }
}

struct LauncherMark: View {
    var body: some View {
        VStack(spacing: 2.5) {
            HStack(spacing: 2.5) { tile; tile }
            HStack(spacing: 2.5) { tile; tile }
        }
    }
    private var tile: some View { RoundedRectangle(cornerRadius: 2).frame(width: 8, height: 8) }
}
