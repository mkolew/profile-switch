import Foundation

/// An app that can run several instances side by side, each on its own data folder.
struct SupportedApp {
    /// The name shown in the menu.
    let name: String
    let bundleID: String
    /// The app's folder in `~/Library/Application Support`; a profile's folder is `<dataFolder>-<profile>`.
    let dataFolder: String
    let downloadURL: URL
    /// A second per-profile folder in the home folder, for apps that keep one. Nil when the app has none.
    let config: Config?

    struct Config {
        /// The default profile's folder name; a profile's folder is `<folder>-<profile>`.
        let folder: String
        /// The environment variable that points the app at a profile's folder.
        let variable: String
        /// A file the app itself writes there, which marks a folder as a profile even without our marker.
        let usedFile: String
    }
}

/// Every app this switcher knows. Adding one means adding a row and testing that it honours `--user-data-dir`.
let supportedApps = [
    SupportedApp(
        name: "Claude",
        bundleID: "com.anthropic.claudefordesktop",
        dataFolder: "Claude",
        downloadURL: URL(string: "https://claude.ai/download")!,
        config: .init(folder: ".claude", variable: "CLAUDE_CONFIG_DIR", usedFile: ".claude.json")
    )
]

let defaultProfile = "default"
/// Written into a profile folder this app creates, so the folder counts as a profile before the app has used it.
let markerFile = ".profile-switch"

/// What it takes to start one profile of an app.
struct LaunchPlan: Equatable {
    var arguments: [String] = []
    var environment: [String: String] = [:]
}

/// The longest name a new profile may have; a longer one no longer reads on a Dock icon.
let maxProfileNameLength = 12

/// Turns a typed name into the name of a new profile.
/// - Parameter typed: what the person entered, for example `Personal`.
/// - Returns: the name in lowercase, or nil when it has anything but the letters a to z and digits, is longer than
///   `maxProfileNameLength`, or is taken by the default profile.
func slug(_ typed: String) -> String? {
    let name = typed.trimmingCharacters(in: .whitespaces).lowercased()
    let isValid = name.range(of: "^[a-z0-9]{1,\(maxProfileNameLength)}$", options: .regularExpression) != nil
    return isValid && name != defaultProfile ? name : nil
}

/// Whether a name can be an existing profile's. Looser than `slug`, so folders made by hand or by earlier
/// versions, which allowed dashes and longer names, still show up.
private func isStoredName(_ name: String) -> Bool {
    name != defaultProfile && name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
}

/// The folder in the home folder that marks a profile: the config folder when the app has one, else the data folder.
/// - Returns: the name prefix that profile folders share and the folder they sit in.
private func profileFolders(of app: SupportedApp, home: URL) -> (parent: URL, prefix: String) {
    if let config = app.config { return (home, config.folder + "-") }
    return (home.appendingPathComponent("Library/Application Support"), app.dataFolder + "-")
}

/// Lists an app's profiles, the default one first.
/// - Parameters:
///   - app: the app whose profiles to find.
///   - home: the user's home folder.
/// - Returns: profile names; a folder counts when it holds our marker or a file the app writes itself.
func discover(app: SupportedApp, home: URL) -> [String] {
    let (parent, prefix) = profileFolders(of: app, home: home)
    let files = FileManager.default
    let names = (try? files.contentsOfDirectory(atPath: parent.path)) ?? []
    let found = names.sorted().compactMap { folder -> String? in
        let name = String(folder.dropFirst(prefix.count))
        guard folder.hasPrefix(prefix), isStoredName(name) else { return nil }
        let inside = parent.appendingPathComponent(folder)
        let evidence = [markerFile] + (app.config.map { [$0.usedFile] } ?? [])
        return evidence.contains { files.fileExists(atPath: inside.appendingPathComponent($0).path) } ? name : nil
    }
    return [defaultProfile] + found
}

/// Resolves a profile's data folder, reusing an existing one whatever its letter case.
/// - Returns: for example `~/Library/Application Support/Claude-Action` for profile `action`.
func dataFolder(app: SupportedApp, profile: String, home: URL) -> URL {
    let support = home.appendingPathComponent("Library/Application Support")
    guard profile != defaultProfile else { return support.appendingPathComponent(app.dataFolder) }
    let wanted = "\(app.dataFolder)-\(profile)"
    let existing = ((try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? [])
        .first { $0.lowercased() == wanted.lowercased() }
    return support.appendingPathComponent(existing ?? wanted)
}

/// Works out how to start a profile.
/// - Returns: nothing extra for the default profile; otherwise the data-folder argument and the config-folder variable.
func launchPlan(app: SupportedApp, profile: String, home: URL) -> LaunchPlan {
    guard profile != defaultProfile else { return LaunchPlan() }
    var plan = LaunchPlan(arguments: ["--user-data-dir=\(dataFolder(app: app, profile: profile, home: home).path)"])
    if let config = app.config {
        plan.environment[config.variable] = home.appendingPathComponent("\(config.folder)-\(profile)").path
    }
    return plan
}

/// Finds the running instance of a profile among an app's main processes.
/// - Parameter processes: each main process of the app with its full command line.
/// - Returns: the process id, or nil when the profile isn't running.
func runningPid(app: SupportedApp, profile: String, home: URL, processes: [(pid: Int32, commandLine: String)]) -> Int32? {
    // The default instance is the one started without a data folder of its own.
    guard let argument = launchPlan(app: app, profile: profile, home: home).arguments.first else {
        return processes.first { !$0.commandLine.contains("--user-data-dir=") }?.pid
    }
    return processes.first { $0.commandLine.hasSuffix(argument) }?.pid
}

/// Creates the folder that makes a new profile show up, with our marker in it.
func createProfile(app: SupportedApp, profile: String, home: URL) throws {
    let (parent, prefix) = profileFolders(of: app, home: home)
    let folder = parent.appendingPathComponent(prefix + profile)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent(markerFile))
}

/// The folders that make up a profile and exist on disk: its config folder, when the app has one, and its data folder.
/// - Returns: nothing for the default profile, which is the app's own setup and never ours to remove.
func folders(app: SupportedApp, profile: String, home: URL) -> [URL] {
    guard isStoredName(profile) else { return [] }
    let config = app.config.map { home.appendingPathComponent("\($0.folder)-\(profile)") }
    return [config, dataFolder(app: app, profile: profile, home: home)].compactMap { $0 }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
}

/// Where a profile's launcher app lives: a tiny app with its own Dock icon that turns into the real app.
/// - Returns: for example `~/Applications/Profile Switch Launchers/Claude Action.app`.
func launcherURL(app: SupportedApp, profile: String, home: URL) -> URL {
    home.appendingPathComponent("Applications/Profile Switch Launchers/\(app.name) \(profile.capitalized).app")
}

/// Quotes a value for use as one word in a shell script.
private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The launcher's program: a script that sets the profile's environment and replaces itself with the real app.
///
/// Because the script becomes the app instead of starting it, the Dock keeps showing the launcher's icon for it.
/// - Parameters:
///   - executable: the real app's main program.
///   - plan: the arguments and environment of the profile.
func launcherScript(executable: URL, plan: LaunchPlan) -> String {
    let exports = plan.environment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(shellQuoted($0.value))\n" }.joined()
    let words = ([executable.path] + plan.arguments).map(shellQuoted).joined(separator: " ")
    // The version line makes existing launchers count as out of date when their look or layout changes.
    return "#!/bin/bash\n# Profile Switch launcher, version 3\n\(exports)exec \(words) \"$@\"\n"
}

/// Checks the pure logic against a throwaway home folder; stops the program on the first failure.
func selfTest() {
    let app = supportedApps[0]
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("profile-switch-test-\(UUID().uuidString)")
    let support = home.appendingPathComponent("Library/Application Support")
    let files = FileManager.default
    defer { try? files.removeItem(at: home) }
    for folder in [".claude", ".claude-work", ".claude-othertool", "Library/Application Support/Claude-Work"] {
        try! files.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    try! Data().write(to: home.appendingPathComponent(".claude-work/.claude.json"))

    precondition(slug(" Personal2 ") == "personal2")
    precondition(slug("Default") == nil && slug("a/b") == nil && slug("") == nil)
    precondition(slug("my client") == nil && slug("my-client") == nil && slug("café") == nil, "only a to z and digits")
    precondition(slug("abcdefghijkl") != nil && slug("abcdefghijklm") == nil, "at most 12 characters")
    try! files.createDirectory(at: home.appendingPathComponent(".claude-old-name"), withIntermediateDirectories: true)
    try! Data().write(to: home.appendingPathComponent(".claude-old-name/.claude.json"))
    precondition(discover(app: app, home: home) == ["default", "old-name", "work"], "an existing name with a dash still shows up")
    try! files.removeItem(at: home.appendingPathComponent(".claude-old-name"))
    precondition(discover(app: app, home: home) == ["default", "work"], "a used folder is a profile, another tool's is not")

    try! createProfile(app: app, profile: "personal", home: home)
    precondition(discover(app: app, home: home) == ["default", "personal", "work"], "a created profile shows up")

    let work = launchPlan(app: app, profile: "work", home: home)
    precondition(work.arguments == ["--user-data-dir=\(support.path)/Claude-Work"], "an existing data folder keeps its letter case")
    precondition(work.environment == ["CLAUDE_CONFIG_DIR": "\(home.path)/.claude-work"])
    precondition(launchPlan(app: app, profile: "default", home: home) == LaunchPlan())

    let processes: [(pid: Int32, commandLine: String)] = [
        (1, "/Applications/Claude.app/Contents/MacOS/Claude"),
        (2, "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=\(support.path)/Claude-Work"),
    ]
    precondition(runningPid(app: app, profile: "default", home: home, processes: processes) == 1)
    precondition(runningPid(app: app, profile: "work", home: home, processes: processes) == 2)
    precondition(runningPid(app: app, profile: "personal", home: home, processes: processes) == nil)
    precondition(folders(app: app, profile: "work", home: home).map(\.lastPathComponent) == [".claude-work", "Claude-Work"])
    precondition(folders(app: app, profile: "personal", home: home).map(\.lastPathComponent) == [".claude-personal"], "a profile never started has no data folder")
    precondition(folders(app: app, profile: "default", home: home).isEmpty, "the default profile is never deleted")
    precondition(folders(app: app, profile: "../x", home: home).isEmpty)

    let script = launcherScript(executable: URL(fileURLWithPath: "/Applications/It's.app/Contents/MacOS/App"), plan: work)
    precondition(script == "#!/bin/bash\n# Profile Switch launcher, version 3\nexport CLAUDE_CONFIG_DIR='\(home.path)/.claude-work'\nexec '/Applications/It'\\''s.app/Contents/MacOS/App' '--user-data-dir=\(support.path)/Claude-Work' \"$@\"\n", "paths are quoted, an apostrophe included")
    precondition(launcherURL(app: app, profile: "work", home: home).lastPathComponent == "Claude Work.app")
    print("self-test passed")
}
