# Profile Switch

A macOS menu bar app that runs several instances of a desktop app side by side, each on its own profile, and switches between them. It is a profile switcher for the Claude desktop app: one instance per subscription, with nothing shared between them.

Not affiliated with, endorsed or sponsored by Anthropic. Claude is a trademark of Anthropic PBC.

```
[menu bar icon]
  Claude
  ● Default
  ● Work
  ○ Personal
  New profile…
  Delete profile  ▸
  ──────────────
  Settings  ▸
  Quit Profile Switch
```

- `●` is running, `○` is not. Click a profile to bring its window to the front, or to start it.
- **New profile…** asks for a name, creates the profile, and starts it. Log in with that subscription in the window that opens.
- **Delete profile** lists the profiles you added. After you confirm, the profile's folders move to the Trash. Quit the profile first; the default profile can't be deleted.
- If the app isn't installed, the menu offers a download link instead.
- **Settings → Start at login** is on by default; untick it to stop Profile Switch starting when you log in.
- **Settings → Show Dock tags** puts a small coloured name tag on the Dock icon of every running profile, so you can tell the identical icons apart. Off by default; turning it on asks for the Accessibility permission, which is how macOS lets an app see where the Dock's icons are.

## Profiles

A profile is a pair of folders. Profiles share nothing: each has its own login, sessions, settings, plugins, skills and memory.

| Profile   | Claude Code config | Desktop data                                  |
| --------- | ------------------ | --------------------------------------------- |
| `Default` | `~/.claude`        | `~/Library/Application Support/Claude`        |
| `<name>`  | `~/.claude-<name>` | `~/Library/Application Support/Claude-<name>` |

`Default` is the app as you already use it. Any `~/.claude-<name>` folder that Claude Code has used, or that this app created, shows up as a profile. Names take lowercase letters, digits and dashes.

A profile is started like this, which you can also run by hand:

```bash
open -n -a /Applications/Claude.app --env CLAUDE_CONFIG_DIR="$HOME/.claude-work" --args --user-data-dir="$HOME/Library/Application Support/Claude-work"
```

## Build and install

Needs macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). No Xcode project.

```bash
./build.sh install
```

This builds `build/Profile Switch.app`, copies it to `~/Applications` (the Applications folder in your home folder) and starts it. The app is signed locally, not notarised, so build it yourself rather than passing the binary around.

The first time you switch to a running instance, macOS may ask whether Profile Switch may control the other app. It is used only to ask that app to show its window.

## Check from a terminal

```bash
"build/Profile Switch.app/Contents/MacOS/Profile Switch" --self-test
"build/Profile Switch.app/Contents/MacOS/Profile Switch" --list
"build/Profile Switch.app/Contents/MacOS/Profile Switch" --open work
```

To see the menu as it looks when no supported app is installed, start the app with `--no-apps`:

```bash
pkill -x "Profile Switch"; open ~/Applications/"Profile Switch.app" --args --no-apps
```

## Limits

- Every running instance shows the app's own icon in the Dock. macOS takes the icon from the app, all profiles run the same app, and macOS doesn't let one app hide another app's Dock icon.
- Dock tags are matched to instances by the order they started in, because the Dock doesn't say which instance an icon belongs to. When the icons and instances can't be paired one to one, no tags are shown. The tags are checked five times a second, so they trail when the Dock magnifies or rearranges.
- The app is signed locally, so macOS may ask for the Accessibility permission again after each rebuild.
- Signing in opens your browser. If the browser is already signed in to another account, a new profile can end up on that account: use a private window, or sign out in the browser first.
- No command to rename a profile.
- Only the Claude desktop app is supported. The app list is one table in `Sources/Profiles.swift`; another app needs a row there and a check that it honours `--user-data-dir`.
- `CLAUDE_CONFIG_DIR` and `--user-data-dir` aren't documented by Anthropic for this use and could change.

## License

MIT — see [LICENSE](LICENSE).
