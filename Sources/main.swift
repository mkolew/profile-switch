import AppKit
import ServiceManagement

let home = FileManager.default.homeDirectoryForCurrentUser

/// Where an app is installed, or nil when it isn't.
func installedURL(of app: SupportedApp) -> URL? {
    // "--no-apps" pretends nothing is installed, to see that state without uninstalling anything.
    if CommandLine.arguments.contains("--no-apps") { return nil }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
}

/// The full command line of a process, as `ps` prints it.
func commandLine(of pid: Int32) -> String {
    let ps = Process()
    let output = Pipe()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-o", "args=", "-p", String(pid)]
    ps.standardOutput = output
    guard (try? ps.run()) != nil else { return "" }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The running main processes of an app (its helpers carry other bundle ids), each with its command line.
func mainProcesses(of app: SupportedApp) -> [(pid: Int32, commandLine: String)] {
    NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).map {
        ($0.processIdentifier, commandLine(of: $0.processIdentifier))
    }
}

/// Brings one running instance to the front.
func focus(pid: Int32) {
    guard let target = NSRunningApplication(processIdentifier: pid) else { return }
    // macOS only lets the active app hand focus over; all instances share a bundle id, so it goes by PID.
    NSApp.yieldActivation(to: target)
    // The plain request as well: the cooperative one above is refused when this app isn't the active one.
    if !target.activate(from: .current, options: [.activateAllWindows]) || !target.isActive {
        target.activate(options: [.activateAllWindows])
    }
    // The Dock's "reopen" event: brings back a window that was closed while the app kept running.
    let reopen = NSAppleEventDescriptor(
        eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
        targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    _ = try? reopen.sendEvent(options: [.noReply], timeout: 5)
}

/// Brings a profile's instance to the front, or starts it.
/// - Parameter done: called with nil on success, or with what went wrong.
func open(app: SupportedApp, profile: String, done: @escaping (String?) -> Void) {
    guard let url = installedURL(of: app) else { return done("\(app.name) isn't installed.") }
    if let pid = runningPid(app: app, profile: profile, home: home, processes: mainProcesses(of: app)) {
        focus(pid: pid)
        return done(nil)
    }
    let plan = launchPlan(app: app, profile: profile, home: home)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.arguments = plan.arguments
    configuration.environment = plan.environment
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        done(error?.localizedDescription)
    }
}

/// A profile of one app, carried by its menu item.
final class Choice: NSObject {
    let app: SupportedApp
    let profile: String
    init(app: SupportedApp, profile: String) {
        self.app = app
        self.profile = profile
    }
}

/// The menu bar item and its menu, rebuilt each time it opens.
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let dockTags = DockTags()

    func applicationDidFinishLaunching(_ notification: Notification) {
        dockTags.setOn(UserDefaults.standard.bool(forKey: "showDockTags"))
        // A profile's process is only known once it runs, so the tags look again when any app starts or quits.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [dockTags] _ in
                dockTags.refreshOwners()
            }
        }
        // Starting at login is on by default: turned on once, on the first launch, and then left to the setting.
        if !UserDefaults.standard.bool(forKey: "didSetUpLoginItem") {
            UserDefaults.standard.set(true, forKey: "didSetUpLoginItem")
            try? SMAppService.mainApp.register()
        }
        item.button?.image = NSImage(systemSymbolName: "person.2.crop.square.stack", accessibilityDescription: "Profile Switch")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        dockTags.refreshOwners()
        let installed = supportedApps.filter { installedURL(of: $0) != nil }
        if installed.isEmpty {
            menu.addItem(withTitle: "No supported app is installed", action: nil, keyEquivalent: "")
            for app in supportedApps {
                add("Download \(app.name)…", #selector(download(_:)), app.downloadURL, to: menu)
            }
        }
        for app in installed {
            menu.addItem(.sectionHeader(title: app.name))
            let processes = mainProcesses(of: app)
            for profile in discover(app: app, home: home) {
                let isRunning = runningPid(app: app, profile: profile, home: home, processes: processes) != nil
                add("\(isRunning ? "●" : "○") \(profile.capitalized)", #selector(choose(_:)), Choice(app: app, profile: profile), to: menu)
            }
            add("New profile…", #selector(newProfile(_:)), Choice(app: app, profile: ""), to: menu)
            let removable = discover(app: app, home: home).filter { $0 != defaultProfile }
            if !removable.isEmpty {
                let submenu = NSMenu()
                for profile in removable {
                    add(profile.capitalized, #selector(deleteProfile(_:)), Choice(app: app, profile: profile), to: submenu)
                }
                menu.addItem(withTitle: "Delete profile", action: nil, keyEquivalent: "").submenu = submenu
            }
        }
        menu.addItem(.separator())
        let settings = NSMenu()
        let login = settings.addItem(withTitle: "Start at login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let showTags = settings.addItem(withTitle: "Show Dock tags", action: #selector(toggleDockTags(_:)), keyEquivalent: "")
        showTags.target = self
        showTags.state = UserDefaults.standard.bool(forKey: "showDockTags") ? .on : .off
        menu.addItem(withTitle: "Settings", action: nil, keyEquivalent: "").submenu = settings
        menu.addItem(withTitle: "Quit Profile Switch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Adds a menu item that calls `action` on this controller with `payload` as its represented object.
    private func add(_ title: String, _ action: Selector, _ payload: Any, to menu: NSMenu) {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.representedObject = payload
    }

    @objc private func download(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        open(app: choice.app, profile: choice.profile) { problem in
            if let problem { DispatchQueue.main.async { self.warn(problem) } }
        }
    }

    @objc private func newProfile(_ sender: NSMenuItem) {
        guard let app = (sender.representedObject as? Choice)?.app else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let alert = NSAlert()
        alert.messageText = "New \(app.name) profile"
        alert.informativeText = "Name it after the subscription, for example Personal. It starts empty: log in with that subscription in the window that opens."
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let profile = slug(field.stringValue) else {
            return warn("Use letters, digits and dashes for the name. \"Default\" is taken.")
        }
        do {
            if !discover(app: app, home: home).contains(profile) {
                try createProfile(app: app, profile: profile, home: home)
            }
            choose(NSMenuItem.carrying(Choice(app: app, profile: profile)))
        } catch {
            warn("Couldn't create the profile. \(error.localizedDescription)")
        }
    }

    @objc private func deleteProfile(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        let name = choice.profile.capitalized
        // A running instance keeps writing to its folders, so it has to be quit first.
        if runningPid(app: choice.app, profile: choice.profile, home: home, processes: mainProcesses(of: choice.app)) != nil {
            return warn("\(name) is running. Quit it first, then delete it.")
        }
        let doomed = folders(app: choice.app, profile: choice.profile, home: home)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the \(name) profile?"
        alert.informativeText = "Its login, chats, sessions, settings and plugins go to the Trash:\n\n"
            + doomed.map { $0.path.replacingOccurrences(of: home.path, with: "~") }.joined(separator: "\n")
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            for folder in doomed { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
        } catch {
            warn("Couldn't delete the profile. \(error.localizedDescription)")
        }
    }

    @objc private func toggleDockTags(_ sender: NSMenuItem) {
        let isOn = !UserDefaults.standard.bool(forKey: "showDockTags")
        UserDefaults.standard.set(isOn, forKey: "showDockTags")
        dockTags.setOn(isOn)
        // Reading the Dock's icons takes the Accessibility permission; this shows macOS's own prompt when it's missing.
        if isOn { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            warn("Couldn't change the login setting. \(error.localizedDescription)")
        }
    }

    private func warn(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        NSApp.activate()
        alert.runModal()
    }
}

extension NSMenuItem {
    /// A detached item holding a payload, for calling a menu action from code.
    static func carrying(_ payload: Any) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = payload
        return item
    }
}

// Flags for checking the app from a terminal, without the menu.
let arguments = CommandLine.arguments.dropFirst()
switch arguments.first(where: { $0 != "--no-apps" && $0 != "--debug-dock" }) {
case "--self-test":
    selfTest()
case "--list":
    for app in supportedApps {
        guard installedURL(of: app) != nil else { print("\(app.name): not installed"); continue }
        let processes = mainProcesses(of: app)
        for profile in discover(app: app, home: home) {
            let pid = runningPid(app: app, profile: profile, home: home, processes: processes)
            print("\(app.name)\t\(profile)\t\(pid.map { "running pid \($0)" } ?? "not running")")
        }
    }
case "--open":
    _ = NSApplication.shared
    let finished = DispatchSemaphore(value: 0)
    open(app: supportedApps[0], profile: arguments.dropFirst().first ?? defaultProfile) { problem in
        print(problem ?? "ok")
        finished.signal()
    }
    finished.wait()
default:
    let controller = Controller()
    NSApplication.shared.delegate = controller
    // An accessory app has a menu bar item but no Dock icon.
    NSApp.setActivationPolicy(.accessory)
    NSApp.run()
}
