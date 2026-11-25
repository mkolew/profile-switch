import AppKit
import ApplicationServices

/// One colour per profile, by its position in the menu; the list repeats when there are more profiles than colours.
private let tagColours: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal]

/// Reads one accessibility attribute of an element, or nil when it is missing or of another type.
private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

/// An app's icon in the Dock.
private struct DockIcon {
    /// In screen coordinates with the origin at the top left of the main screen.
    let frame: CGRect
    let isRunning: Bool
}

/// The Dock icons that belong to an app, running or not, in Dock order.
/// - Parameter appURL: where the app is installed; the Dock gives each icon the URL of what it opens.
private func dockIcons(for appURL: URL) -> [DockIcon] {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
    let lists: [AXUIElement] = attribute(AXUIElementCreateApplication(dock.processIdentifier), kAXChildrenAttribute) ?? []
    let items: [AXUIElement] = lists.first.flatMap { attribute($0, kAXChildrenAttribute) } ?? []
    let target = appURL.standardizedFileURL.path
    let icons = items.compactMap { item -> DockIcon? in
        guard let url: URL = attribute(item, kAXURLAttribute), url.standardizedFileURL.path == target,
              let position: AXValue = attribute(item, kAXPositionAttribute),
              let size: AXValue = attribute(item, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        let isRunning: Bool = attribute(item, "AXIsApplicationRunning") ?? false
        return DockIcon(frame: CGRect(origin: origin, size: extent), isRunning: isRunning)
    }
    // Left to right for a Dock at the bottom, top to bottom for one at the side.
    return icons.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
}

/// Whether an app is kept in the Dock, read from the Dock's own settings.
private func isPinned(_ app: SupportedApp) -> Bool {
    let pinned = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
    return pinned.contains { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String == app.bundleID }
}

/// Draws a profile's name on a coloured tag across the top of a Dock icon.
private final class TagView: NSView {
    private let colour: NSColor
    private let name: String

    init(colour: NSColor, name: String) {
        self.colour = colour
        self.name = name
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let label = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        let width = min(bounds.width, size.width + 8)
        let tag = NSRect(x: bounds.midX - width / 2, y: bounds.maxY - size.height - 2, width: width, height: size.height + 2)
        colour.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 5, yRadius: 5).fill()
        // A name wider than the icon is cut off at the tag's edge rather than spilling onto the next icon.
        NSBezierPath(rect: tag.insetBy(dx: 3, dy: 0)).addClip()
        label.draw(at: NSPoint(x: max(tag.minX + 4, bounds.midX - size.width / 2), y: tag.minY + 1))
    }
}

/// Puts a name tag on the Dock icon of every running profile, so identical icons can be told apart.
///
/// Needs the Accessibility permission, which is how one app may read where another app's items are.
final class DockTags {
    private var tags: [pid_t: NSWindow] = [:]
    private var bindings: [String: DockBinding] = [:]
    /// The profile behind each running main process, looked up when apps start and quit rather than on every tick.
    private var owners: [pid_t: (name: String, colour: NSColor)] = [:]
    private var timer: Timer?
    private var lastLogged = ""

    /// Starts or stops showing tags.
    func setOn(_ isOn: Bool) {
        timer?.invalidate()
        timer = nil
        guard isOn else { return clear() }
        refreshOwners()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        // Common modes, so the tags keep following while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Works out again which process belongs to which profile.
    func refreshOwners() {
        owners = [:]
        for app in supportedApps {
            let processes = mainProcesses(of: app)
            for (index, profile) in discover(app: app, home: home).enumerated() {
                guard let pid = runningPid(app: app, profile: profile, home: home, processes: processes) else { continue }
                owners[pid] = (profile.capitalized, tagColours[index % tagColours.count])
            }
        }
    }

    /// Moves every tag onto its Dock icon, adds tags for new instances and drops those whose instance is gone.
    private func tick() {
        guard AXIsProcessTrusted() else { return clear() }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        var placed = Set<pid_t>()
        var log: [String] = []
        for app in supportedApps {
            guard let appURL = installedURL(of: app) else { continue }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
                .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
                .map(\.processIdentifier)
            let icons = dockIcons(for: appURL)
            let pinnedIconRunning = isPinned(app) && icons.first?.isRunning == true
            var binding = bindings[app.bundleID] ?? DockBinding()
            binding.update(running: running, pinnedIconRunning: pinnedIconRunning)
            bindings[app.bundleID] = binding
            let runningIcons = icons.filter(\.isRunning)
            log.append("\(app.name): icons=\(icons.map { "\(Int($0.frame.minX))\($0.isRunning ? "*" : "")" }) pinnedRunning=\(pinnedIconRunning) order=\(binding.order.map { owners[$0]?.name ?? String($0) })")
            // A wrong tag is worse than none: without one icon per instance, nothing is shown.
            guard runningIcons.count == binding.order.count else { continue }
            for (pid, icon) in zip(binding.order, runningIcons) {
                guard let owner = owners[pid] else { continue }
                placed.insert(pid)
                let tag = tags[pid] ?? makeTag(name: owner.name, colour: owner.colour)
                tags[pid] = tag
                let frame = NSRect(x: icon.frame.minX, y: screenHeight - icon.frame.maxY, width: icon.frame.width, height: icon.frame.height)
                if tag.frame != frame { tag.setFrame(frame, display: true) }
                if !tag.isVisible { tag.orderFrontRegardless() }
            }
        }
        for (pid, tag) in tags where !placed.contains(pid) {
            tag.orderOut(nil)
            tags[pid] = nil
        }
        writeLog(log.joined(separator: "; "))
    }

    /// With `--debug-dock`, records each change in what the Dock shows and how it was matched.
    private func writeLog(_ line: String) {
        guard CommandLine.arguments.contains("--debug-dock"), line != lastLogged else { return }
        lastLogged = line
        let file = home.appendingPathComponent("Library/Logs/ProfileSwitch-dock.log")
        let entry = Data("\(Date()) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? entry.write(to: file)
        }
    }

    private func makeTag(name: String, colour: NSColor) -> NSWindow {
        let tag = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        tag.isOpaque = false
        tag.backgroundColor = .clear
        tag.hasShadow = false
        tag.ignoresMouseEvents = true
        tag.isReleasedWhenClosed = false
        // One level above the Dock, on every desktop, and out of Mission Control and ⌘`.
        tag.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        tag.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        tag.contentView = TagView(colour: colour, name: name)
        return tag
    }

    private func clear() {
        tags.values.forEach { $0.orderOut(nil) }
        tags = [:]
    }
}
