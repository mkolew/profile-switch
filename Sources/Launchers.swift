import AppKit

/// One colour per added profile, in menu order; the list repeats when there are more profiles than colours.
private let badgeColours: [NSColor] = [.systemBlue, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemIndigo]

/// Why a launcher couldn't be made.
struct LauncherError: LocalizedError {
    let errorDescription: String?
}

/// Draws the real app's icon with the profile's name on a coloured band across it.
/// - Parameter pixels: the width and height of the picture.
/// - Returns: the picture as PNG data, or nil when it couldn't be drawn.
private func badgedIcon(of appURL: URL, name: String, colour: NSColor, pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let side = CGFloat(pixels)
    let whole = NSRect(x: 0, y: 0, width: side, height: side)
    let appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
    // A first pass, only to read the icon's background colour from a spot near its left edge.
    appIcon.draw(in: whole)
    let background = bitmap.colorAt(x: Int(side * 0.16), y: pixels / 2) ?? .gray
    NSGraphicsContext.current?.cgContext.clear(whole)

    // macOS shrinks an icon onto a grey plate unless it fills the standard shape exactly: an 824-point rounded
    // square on a 1024 canvas. So the shape is filled solid and the app's icon is drawn a little oversized inside
    // it, which pushes that picture's own soft edge and shadow out past the clip.
    let unit = side / 1024
    let tile = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit).addClip()
    background.setFill()
    tile.fill()
    appIcon.draw(in: whole.insetBy(dx: -side * 0.04, dy: -side * 0.04))

    // The band runs edge to edge across the bottom of the tile; the clip rounds its lower corners.
    let band = NSRect(x: tile.minX, y: tile.minY, width: tile.width, height: side * 0.27)
    colour.setFill()
    band.fill()
    var size = side * 0.17
    var label = NSAttributedString()
    // Shrinks the name until it fits the band.
    repeat {
        label = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.white,
        ])
        size *= 0.9
    } while label.size().width > band.width - side * 0.06 && size > 1
    let text = label.size()
    label.draw(at: NSPoint(x: band.midX - text.width / 2, y: band.midY - text.height / 2))
    return bitmap.representation(using: .png, properties: [:])
}

/// Writes a launcher's icon file, in all the sizes macOS asks for.
private func writeIcon(to destination: URL, appURL: URL, name: String, colour: NSColor) throws {
    let files = FileManager.default
    let iconset = files.temporaryDirectory.appendingPathComponent("profile-switch-\(UUID().uuidString).iconset")
    try files.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: iconset) }
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            guard let png = badgedIcon(of: appURL, name: name, colour: colour, pixels: points * factor) else { continue }
            try png.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"))
        }
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    if iconutil.terminationStatus != 0 { throw LauncherError(errorDescription: "Couldn't make the launcher's icon.") }
}

/// Makes sure a profile's launcher app exists and matches the installed app, and returns where it is.
///
/// The launcher is a tiny app of its own, so it has its own icon in the Dock and can be kept there. Its program
/// replaces itself with the real, unmodified app, which is why the Dock goes on showing the launcher's icon.
func ensureLauncher(app: SupportedApp, profile: String) throws -> URL {
    guard let appURL = installedURL(of: app), let executable = Bundle(url: appURL)?.executableURL else {
        throw LauncherError(errorDescription: "\(app.name) isn't installed.")
    }
    let launcher = launcherURL(app: app, profile: profile, home: home)
    let contents = launcher.appendingPathComponent("Contents")
    let program = contents.appendingPathComponent("MacOS/launch")
    let script = launcherScript(executable: executable, plan: launchPlan(app: app, profile: profile, home: home))
    // Up to date when its program is what we would write now; a moved app or data folder changes the script.
    if (try? String(contentsOf: program, encoding: .utf8)) == script { return launcher }

    let files = FileManager.default
    try files.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try files.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    try Data(script.utf8).write(to: program)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    let name = "\(app.name) \(profile.capitalized)"
    let info: [String: Any] = [
        "CFBundleName": name, "CFBundleDisplayName": name, "CFBundleExecutable": "launch",
        "CFBundleIdentifier": "com.mkolew.profile-switch.launcher.\(app.name.lowercased()).\(profile)",
        "CFBundlePackageType": "APPL", "CFBundleIconFile": "AppIcon", "CFBundleShortVersionString": "1.0",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    // The default profile comes first in the list and has no launcher, so the count starts after it.
    let index = max(0, (discover(app: app, home: home).firstIndex(of: profile) ?? 1) - 1)
    try writeIcon(
        to: contents.appendingPathComponent("Resources/AppIcon.icns"), appURL: appURL,
        name: profile.capitalized, colour: badgeColours[index % badgeColours.count])
    return launcher
}
