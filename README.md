# Peekaboo

A lightweight macOS menu bar app for discovering and connecting to remote Macs via Screen Sharing, with one-click access, saved credentials, and automatic High Performance mode selection.

![macOS](https://img.shields.io/badge/macOS-12%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Why Peekaboo?

macOS Screen Sharing is great, but it has no quick-access menu bar presence and no way to set a default connection mode. Every time you connect via `vnc://`, it asks you to choose between "Standard" and "High Performance." There's no preference to skip that dialog, no plist key, no launch argument. Peekaboo solves both problems: a persistent menu bar icon for one-click connections, and automatic dismissal of the mode-selection dialog based on your per-host preferences.

## Features

- **Menu bar icon** with quick access to all your remote Macs
- **Bonjour auto-discovery** finds Macs on your local network automatically
- **Saved hosts** with per-host usernames, passwords, and connection preferences
- **High Performance mode** auto-selects your preferred mode and clicks through the dialog for you
- **Keychain integration** stores credentials securely in the macOS Keychain
- **Favorites** pinned to the top of the menu for one-click access
- **Quick Connect** (Cmd+K) for ad-hoc connections
- **No Dock icon**, runs cleanly as a menu bar-only utility
- **Custom app icon** (friendly monitor with eyes, because peekaboo)

## Requirements

- macOS 12 Monterey or later
- Xcode Command Line Tools
- Remote Macs must have Screen Sharing or Remote Management enabled in System Settings > General > Sharing

## Build & Install

```bash
xcode-select --install   # if not already installed
chmod +x build.sh
./build.sh
```

The build script compiles the Swift source, generates the app icon at all required resolutions, bundles everything into a signed `.app`, and installs it to `/Applications`.

## First-Run Setup

On first launch, macOS will prompt for **Accessibility** permission. This is required for Peekaboo to auto-dismiss Screen Sharing's mode-selection dialog.

1. Open **System Settings > Privacy & Security > Accessibility**
2. Enable **Peekaboo**

Without this permission, Peekaboo still works for connections and discovery. You'll just need to click through the Standard/High Performance dialog manually.

> **After rebuilding:** macOS silently invalidates Accessibility entries when the code signature changes. If auto-dismiss stops working after a rebuild, remove Peekaboo from the Accessibility list and re-add it.

## Usage

Click the Peekaboo icon in the menu bar to see:

- **Favorites** (starred hosts, shown at top)
- **Saved Hosts** (all manually configured hosts)
- **Discovered on Network** (Macs found via Bonjour)
- **Quick Connect...** (Cmd+K) for one-off connections
- **Refresh Discovery** (Cmd+R) to re-scan the network
- **Preferences...** (Cmd+,) to configure defaults and manage saved hosts

Hosts with a lightning bolt icon have High Performance mode enabled.

### Adding a Saved Host

1. Open **Preferences > Saved Hosts**
2. Click **Add Host**
3. Fill in the hostname/IP, username, and password
4. Check **Save password in Keychain** to store credentials securely
5. Check **High Performance mode** for lower latency on that host
6. Check **Favorite** to pin it to the top of the menu

### High Performance Mode

When enabled (globally in Preferences or per-host), Peekaboo automatically selects "High Performance" in Screen Sharing's type-selection dialog and clicks Continue for you. When disabled, it selects "Standard" instead. Either way, the dialog is dismissed without any manual interaction.

High Performance mode is ideal for remote admin work over Wi-Fi or WAN connections where responsiveness matters more than visual fidelity.

## How It Works

- Uses `NSNetServiceBrowser` to discover `_rfb._tcp` services (Bonjour) on the local network
- Connects by opening `vnc://` URLs, which launches the built-in macOS Screen Sharing app
- On macOS Tahoe (26.x), Screen Sharing shows a "Select Screen Sharing Type" dialog for every URL-initiated connection. There is no plist key, launch argument, or API to suppress it. Peekaboo auto-dismisses it via System Events, targeting the dialog elements by index (the SwiftUI dialog has no accessibility labels)
- Stores credentials in the macOS Keychain via the Security framework
- Preferences persist via UserDefaults
- Menu bar icon and app icon are drawn programmatically (no external image assets)

## Troubleshooting

**No hosts discovered?**
Make sure the remote Mac has Screen Sharing enabled: System Settings > General > Sharing > Screen Sharing. Both Macs need to be on the same subnet for Bonjour discovery.

**Connection fails with credentials?**
The remote Mac must have your username authorized for Screen Sharing access. Check the "Allow access for" list in the remote Mac's Screen Sharing settings.

**Auto-dismiss not working?**
Check that Peekaboo has Accessibility permission enabled in System Settings > Privacy & Security > Accessibility. If you recently rebuilt, remove and re-add the entry to force macOS to re-evaluate the new binary.

**Repeated "access data from other apps" prompts?**
The binary isn't code signed. Always build via `./build.sh`, which handles ad-hoc code signing automatically.

## License

MIT License. See [LICENSE](LICENSE) for details.
