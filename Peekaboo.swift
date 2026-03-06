// Peekaboo - A macOS menu bar app for quick Screen Sharing connections
// Compile: swiftc -framework Cocoa -framework Security Peekaboo.swift -o Peekaboo
// Run: ./Peekaboo

import Cocoa
import Foundation
import Security

// MARK: - Data Models

struct SavedHost: Codable {
    var displayName: String
    var hostname: String
    var port: Int
    var username: String
    var storeCredential: Bool
    var highPerformance: Bool
    var isFavorite: Bool

    init(displayName: String = "", hostname: String, port: Int = 5900, username: String = "", storeCredential: Bool = false, highPerformance: Bool = false, isFavorite: Bool = false) {
        self.displayName = displayName.isEmpty ? hostname : displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.storeCredential = storeCredential
        self.highPerformance = highPerformance
        self.isFavorite = isFavorite
    }
}

struct AppPreferences: Codable {
    var defaultHighPerformance: Bool = false
    var autoDiscoverOnLaunch: Bool = true
    var refreshIntervalSeconds: Int = 30
    var showDiscoveredHosts: Bool = true
    var showFavoritesAtTop: Bool = true
    var launchAtLogin: Bool = false
}

// MARK: - Keychain Helper

class KeychainHelper {
    static let serviceName = "com.peekaboo.credentials"

    static func save(password: String, for host: String, username: String) -> Bool {
        let account = "\(username)@\(host)"
        delete(for: host, username: username)

        guard let data = password.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func load(for host: String, username: String) -> String? {
        let account = "\(username)@\(host)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for host: String, username: String) {
        let account = "\(username)@\(host)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Bonjour Discovery

class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    var discoveredHosts: [(name: String, hostname: String, port: Int)] = []
    var onUpdate: (() -> Void)?

    override init() {
        super.init()
        browser.delegate = self
    }

    func startBrowsing() {
        discoveredHosts.removeAll()
        browser.searchForServices(ofType: "_rfb._tcp.", inDomain: "local.")
    }

    func stopBrowsing() {
        browser.stop()
    }

    func refresh() {
        stopBrowsing()
        startBrowsing()
    }

    // NetServiceBrowserDelegate
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 10.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        discoveredHosts.removeAll { $0.name == service.name }
        resolving.removeAll { $0 == service }
        if !moreComing { onUpdate?() }
    }

    // NetServiceDelegate
    func netServiceDidResolveAddress(_ sender: NetService) {
        if let host = sender.hostName {
            let cleanHost = host.hasSuffix(".") ? String(host.dropLast()) : host
            if !discoveredHosts.contains(where: { $0.hostname == cleanHost }) {
                discoveredHosts.append((name: sender.name, hostname: cleanHost, port: sender.port))
            }
        }
        resolving.removeAll { $0 == sender }
        onUpdate?()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 == sender }
    }
}

// MARK: - Preferences / Host Storage

class SettingsStore {
    static let shared = SettingsStore()
    private let hostsKey = "Peekaboo_SavedHosts"
    private let prefsKey = "Peekaboo_Preferences"

    var savedHosts: [SavedHost] {
        get {
            guard let data = UserDefaults.standard.data(forKey: hostsKey),
                  let hosts = try? JSONDecoder().decode([SavedHost].self, from: data)
            else { return [] }
            return hosts
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: hostsKey)
            }
        }
    }

    var preferences: AppPreferences {
        get {
            guard let data = UserDefaults.standard.data(forKey: prefsKey),
                  let prefs = try? JSONDecoder().decode(AppPreferences.self, from: data)
            else { return AppPreferences() }
            return prefs
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: prefsKey)
            }
        }
    }

    func addOrUpdateHost(_ host: SavedHost) {
        var hosts = savedHosts
        if let idx = hosts.firstIndex(where: { $0.hostname == host.hostname }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
        savedHosts = hosts
    }

    func removeHost(hostname: String) {
        var hosts = savedHosts
        hosts.removeAll { $0.hostname == hostname }
        savedHosts = hosts
    }
}

// MARK: - Connection Manager

class ConnectionManager {

    // Screen Sharing on macOS Tahoe shows a "Select Screen Sharing Type"
    // dialog for every URL-initiated connection. There is no plist key or
    // launch method that suppresses it. The only reliable approach is to
    // open the vnc:// URL (which shows the dialog), then auto-click
    // through it via System Events.
    //
    // The dialog is SwiftUI and its elements have no accessibility names
    // or titles. We target by index:
    //   AXGroup > AXRadioGroup > radio button 1 (Standard) / 2 (High Perf)
    //   AXGroup > button 3 (Continue)  [1=Help, 2=Cancel, 3=Continue]
    //
    // Requires one-time Accessibility permission grant.

    static func connect(host: SavedHost) {
        let prefs = SettingsStore.shared.preferences
        let useHighPerf = host.highPerformance || prefs.defaultHighPerformance

        // Build the VNC URL
        var urlString = "vnc://"
        if !host.username.isEmpty {
            let encodedUser = host.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? host.username
            if host.storeCredential, let password = KeychainHelper.load(for: host.hostname, username: host.username) {
                let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
                urlString += "\(encodedUser):\(encodedPass)@"
            } else {
                urlString += "\(encodedUser)@"
            }
        }
        urlString += host.hostname
        if host.port != 5900 {
            urlString += ":\(host.port)"
        }

        // Open the URL. This will trigger Screen Sharing.
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }

        // Auto-dismiss the type dialog on a background thread.
        // Radio button index: 1 = Standard, 2 = High Performance
        let radioIndex = useHighPerf ? 2 : 1
        DispatchQueue.global(qos: .userInitiated).async {
            dismissTypeDialog(radioIndex: radioIndex)
        }
    }

    private static func dismissTypeDialog(radioIndex: Int) {
        // Use osascript via Process instead of NSAppleScript.
        // NSAppleScript has threading issues on background GCD queues.
        //
        // The script polls for up to 60 seconds (user may need to
        // authenticate first). Once it finds a window with an
        // AXRadioGroup inside an AXGroup, it clicks the right radio
        // button by index, then clicks the last button (Continue).

        let script = """
        tell application "System Events"
            repeat 120 times
                delay 0.5
                try
                    if exists process "Screen Sharing" then
                        tell process "Screen Sharing"
                            repeat with w in (every window)
                                try
                                    set g to first group of w
                                    set rg to first radio group of g
                                    set rbs to every radio button of rg
                                    if (count of rbs) is greater than or equal to 2 then
                                        click radio button \(radioIndex) of rg
                                        delay 0.2
                                        -- Continue is the last button in the group
                                        set btns to every button of g
                                        click last item of btns
                                        return "ok"
                                    end if
                                end try
                            end repeat
                        end tell
                    end if
                end try
            end repeat
            return "timeout"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                NSLog("Peekaboo: dialog dismiss result: \(result)")
            }
        } catch {
            NSLog("Peekaboo: failed to run osascript: \(error)")
        }
    }
}

// MARK: - Preferences Window

class PreferencesWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!
    var tabView: NSTabView!
    var hostsTableView: NSTableView!
    var onClose: (() -> Void)?

    // General prefs controls
    var highPerfCheckbox: NSButton!
    var autoDiscoverCheckbox: NSButton!
    var showDiscoveredCheckbox: NSButton!
    var favoritesTopCheckbox: NSButton!
    var refreshIntervalField: NSTextField!

    func showWindow() {
        if window != nil {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Peekaboo Preferences"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        tabView = NSTabView(frame: NSRect(x: 10, y: 10, width: 540, height: 420))

        // Tab 1: General
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        generalTab.view = buildGeneralTab()
        tabView.addTabViewItem(generalTab)

        // Tab 2: Saved Hosts
        let hostsTab = NSTabViewItem(identifier: "hosts")
        hostsTab.label = "Saved Hosts"
        hostsTab.view = buildHostsTab()
        tabView.addTabViewItem(hostsTab)

        window.contentView?.addSubview(tabView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildGeneralTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 380))
        let prefs = SettingsStore.shared.preferences
        var y = 320

        let titleLabel = NSTextField(labelWithString: "Connection Defaults")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        view.addSubview(titleLabel)
        y -= 30

        highPerfCheckbox = NSButton(checkboxWithTitle: "Enable High Performance mode by default", target: self, action: #selector(generalPrefsChanged))
        highPerfCheckbox.frame = NSRect(x: 20, y: y, width: 400, height: 20)
        highPerfCheckbox.state = prefs.defaultHighPerformance ? .on : .off
        view.addSubview(highPerfCheckbox)
        y -= 30

        let note = NSTextField(wrappingLabelWithString: "High Performance mode reduces image quality and color depth for lower latency. Best for remote admin tasks over slower connections.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 40, y: y - 20, width: 440, height: 40)
        view.addSubview(note)
        y -= 60

        let discTitle = NSTextField(labelWithString: "Network Discovery")
        discTitle.font = NSFont.boldSystemFont(ofSize: 13)
        discTitle.frame = NSRect(x: 20, y: y, width: 300, height: 20)
        view.addSubview(discTitle)
        y -= 30

        autoDiscoverCheckbox = NSButton(checkboxWithTitle: "Auto-discover Macs on local network (Bonjour)", target: self, action: #selector(generalPrefsChanged))
        autoDiscoverCheckbox.frame = NSRect(x: 20, y: y, width: 400, height: 20)
        autoDiscoverCheckbox.state = prefs.autoDiscoverOnLaunch ? .on : .off
        view.addSubview(autoDiscoverCheckbox)
        y -= 28

        showDiscoveredCheckbox = NSButton(checkboxWithTitle: "Show discovered hosts in menu", target: self, action: #selector(generalPrefsChanged))
        showDiscoveredCheckbox.frame = NSRect(x: 20, y: y, width: 400, height: 20)
        showDiscoveredCheckbox.state = prefs.showDiscoveredHosts ? .on : .off
        view.addSubview(showDiscoveredCheckbox)
        y -= 28

        favoritesTopCheckbox = NSButton(checkboxWithTitle: "Show favorites at top of menu", target: self, action: #selector(generalPrefsChanged))
        favoritesTopCheckbox.frame = NSRect(x: 20, y: y, width: 400, height: 20)
        favoritesTopCheckbox.state = prefs.showFavoritesAtTop ? .on : .off
        view.addSubview(favoritesTopCheckbox)
        y -= 30

        let refreshLabel = NSTextField(labelWithString: "Discovery refresh interval (seconds):")
        refreshLabel.frame = NSRect(x: 20, y: y, width: 250, height: 20)
        view.addSubview(refreshLabel)

        refreshIntervalField = NSTextField(frame: NSRect(x: 280, y: y, width: 60, height: 22))
        refreshIntervalField.stringValue = "\(prefs.refreshIntervalSeconds)"
        refreshIntervalField.target = self
        refreshIntervalField.action = #selector(generalPrefsChanged)
        view.addSubview(refreshIntervalField)

        return view
    }

    @objc func generalPrefsChanged() {
        var prefs = SettingsStore.shared.preferences
        prefs.defaultHighPerformance = highPerfCheckbox.state == .on
        prefs.autoDiscoverOnLaunch = autoDiscoverCheckbox.state == .on
        prefs.showDiscoveredHosts = showDiscoveredCheckbox.state == .on
        prefs.showFavoritesAtTop = favoritesTopCheckbox.state == .on
        prefs.refreshIntervalSeconds = Int(refreshIntervalField.stringValue) ?? 30
        SettingsStore.shared.preferences = prefs
    }

    private func buildHostsTab() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 380))

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 60, width: 480, height: 280))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        hostsTableView = NSTableView()
        hostsTableView.dataSource = self
        hostsTableView.delegate = self
        hostsTableView.rowHeight = 24

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 120
        hostsTableView.addTableColumn(nameCol)

        let hostCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        hostCol.title = "Hostname"
        hostCol.width = 150
        hostsTableView.addTableColumn(hostCol)

        let userCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("user"))
        userCol.title = "Username"
        userCol.width = 80
        hostsTableView.addTableColumn(userCol)

        let perfCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("perf"))
        perfCol.title = "High Perf"
        perfCol.width = 60
        hostsTableView.addTableColumn(perfCol)

        let favCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fav"))
        favCol.title = "Favorite"
        favCol.width = 55
        hostsTableView.addTableColumn(favCol)

        scrollView.documentView = hostsTableView
        view.addSubview(scrollView)

        let addButton = NSButton(title: "Add Host", target: self, action: #selector(addHost))
        addButton.frame = NSRect(x: 20, y: 20, width: 100, height: 30)
        view.addSubview(addButton)

        let editButton = NSButton(title: "Edit", target: self, action: #selector(editHost))
        editButton.frame = NSRect(x: 130, y: 20, width: 80, height: 30)
        view.addSubview(editButton)

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeHost))
        removeButton.frame = NSRect(x: 220, y: 20, width: 80, height: 30)
        view.addSubview(removeButton)

        return view
    }

    @objc func addHost() {
        showHostEditor(host: nil)
    }

    @objc func editHost() {
        let row = hostsTableView.selectedRow
        guard row >= 0 else { return }
        let host = SettingsStore.shared.savedHosts[row]
        showHostEditor(host: host)
    }

    @objc func removeHost() {
        let row = hostsTableView.selectedRow
        guard row >= 0 else { return }
        let host = SettingsStore.shared.savedHosts[row]
        if host.storeCredential {
            KeychainHelper.delete(for: host.hostname, username: host.username)
        }
        SettingsStore.shared.removeHost(hostname: host.hostname)
        hostsTableView.reloadData()
        onClose?()
    }

    func showHostEditor(host: SavedHost?) {
        let alert = NSAlert()
        alert.messageText = host == nil ? "Add Remote Mac" : "Edit Remote Mac"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 220))

        var y = 190
        func addField(label: String, value: String = "", isSecure: Bool = false) -> NSTextField {
            let lbl = NSTextField(labelWithString: label)
            lbl.frame = NSRect(x: 0, y: y, width: 100, height: 20)
            accessory.addSubview(lbl)
            let field: NSTextField
            if isSecure {
                field = NSSecureTextField(frame: NSRect(x: 110, y: y, width: 220, height: 22))
            } else {
                field = NSTextField(frame: NSRect(x: 110, y: y, width: 220, height: 22))
            }
            field.stringValue = value
            accessory.addSubview(field)
            y -= 32
            return field
        }

        let nameField = addField(label: "Display Name:", value: host?.displayName ?? "")
        let hostnameField = addField(label: "Hostname/IP:", value: host?.hostname ?? "")
        let portField = addField(label: "Port:", value: "\(host?.port ?? 5900)")
        let userField = addField(label: "Username:", value: host?.username ?? "")
        let passField = addField(label: "Password:", isSecure: true)
        if let h = host, h.storeCredential {
            passField.stringValue = KeychainHelper.load(for: h.hostname, username: h.username) ?? ""
        }

        let storeCheck = NSButton(checkboxWithTitle: "Save password in Keychain", target: nil, action: nil)
        storeCheck.frame = NSRect(x: 110, y: y, width: 220, height: 20)
        storeCheck.state = (host?.storeCredential ?? false) ? .on : .off
        accessory.addSubview(storeCheck)
        y -= 28

        let perfCheck = NSButton(checkboxWithTitle: "High Performance mode", target: nil, action: nil)
        perfCheck.frame = NSRect(x: 110, y: y, width: 220, height: 20)
        perfCheck.state = (host?.highPerformance ?? false) ? .on : .off
        accessory.addSubview(perfCheck)
        y -= 28

        let favCheck = NSButton(checkboxWithTitle: "Favorite (show at top)", target: nil, action: nil)
        favCheck.frame = NSRect(x: 110, y: y, width: 220, height: 20)
        favCheck.state = (host?.isFavorite ?? false) ? .on : .off
        accessory.addSubview(favCheck)

        alert.accessoryView = accessory
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let newHost = SavedHost(
                displayName: nameField.stringValue,
                hostname: hostnameField.stringValue,
                port: Int(portField.stringValue) ?? 5900,
                username: userField.stringValue,
                storeCredential: storeCheck.state == .on,
                highPerformance: perfCheck.state == .on,
                isFavorite: favCheck.state == .on
            )

            if newHost.storeCredential && !passField.stringValue.isEmpty {
                _ = KeychainHelper.save(password: passField.stringValue, for: newHost.hostname, username: newHost.username)
            } else if !newHost.storeCredential {
                KeychainHelper.delete(for: newHost.hostname, username: newHost.username)
            }

            SettingsStore.shared.addOrUpdateHost(newHost)
            hostsTableView.reloadData()
            onClose?()
        }
    }

    // NSTableViewDataSource
    func numberOfRows(in tableView: NSTableView) -> Int {
        return SettingsStore.shared.savedHosts.count
    }

    // NSTableViewDelegate
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let host = SettingsStore.shared.savedHosts[row]
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail

        switch tableColumn?.identifier.rawValue {
        case "name": cell.stringValue = host.displayName
        case "host": cell.stringValue = host.hostname
        case "user": cell.stringValue = host.username
        case "perf": cell.stringValue = host.highPerformance ? "Yes" : "No"
        case "fav": cell.stringValue = host.isFavorite ? "\u{2605}" : ""
        default: break
        }
        return cell
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - Quick Connect Panel

class QuickConnectPanel {
    static func show() {
        let alert = NSAlert()
        alert.messageText = "Quick Connect"
        alert.informativeText = "Enter the hostname or IP of the remote Mac."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 90))

        let hostLabel = NSTextField(labelWithString: "Host:")
        hostLabel.frame = NSRect(x: 0, y: 62, width: 60, height: 20)
        accessory.addSubview(hostLabel)

        let hostField = NSTextField(frame: NSRect(x: 70, y: 60, width: 220, height: 22))
        hostField.placeholderString = "mac-mini.local or 192.168.1.50"
        accessory.addSubview(hostField)

        let userLabel = NSTextField(labelWithString: "User:")
        userLabel.frame = NSRect(x: 0, y: 30, width: 60, height: 20)
        accessory.addSubview(userLabel)

        let userField = NSTextField(frame: NSRect(x: 70, y: 28, width: 220, height: 22))
        userField.placeholderString = "username (optional)"
        accessory.addSubview(userField)

        let perfCheck = NSButton(checkboxWithTitle: "High Performance mode", target: nil, action: nil)
        perfCheck.frame = NSRect(x: 70, y: 0, width: 220, height: 20)
        perfCheck.state = SettingsStore.shared.preferences.defaultHighPerformance ? .on : .off
        accessory.addSubview(perfCheck)

        alert.accessoryView = accessory
        let response = alert.runModal()

        if response == .alertFirstButtonReturn && !hostField.stringValue.isEmpty {
            let host = SavedHost(
                hostname: hostField.stringValue,
                username: userField.stringValue,
                highPerformance: perfCheck.state == .on
            )
            ConnectionManager.connect(host: host)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var bonjourBrowser = BonjourBrowser()
    var prefsController = PreferencesWindowController()
    var refreshTimer: Timer?

    // Draws the Peekaboo icon: a monitor with two friendly dot eyes.
    // Used for the menu bar (18pt) and app icon (any size).
    func drawPeekabooIcon(size: CGFloat, color: NSColor, lineScale: CGFloat = 1.0) -> NSImage {
        let s = size / 18.0  // scale factor relative to 18pt base
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            color.setStroke()
            color.setFill()

            let lw = 1.3 * lineScale * s

            // Monitor body with rounded corners
            let monitorRect = NSRect(x: 2 * s, y: 2 * s, width: 14 * s, height: 10 * s)
            let monitorPath = NSBezierPath(roundedRect: monitorRect, xRadius: 1.5 * s, yRadius: 1.5 * s)
            monitorPath.lineWidth = lw
            monitorPath.stroke()

            // Stand neck
            let neckPath = NSBezierPath()
            neckPath.move(to: NSPoint(x: 9 * s, y: 12 * s))
            neckPath.line(to: NSPoint(x: 9 * s, y: 14.5 * s))
            neckPath.lineWidth = lw
            neckPath.lineCapStyle = .round
            neckPath.stroke()

            // Stand base
            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: 6 * s, y: 15 * s))
            basePath.line(to: NSPoint(x: 12 * s, y: 15 * s))
            basePath.lineWidth = lw
            basePath.lineCapStyle = .round
            basePath.stroke()

            // Left eye
            let leftEye = NSBezierPath(ovalIn: NSRect(
                x: 5.3 * s - 1.2 * s, y: 7.2 * s - 1.2 * s,
                width: 2.4 * s, height: 2.4 * s
            ))
            leftEye.fill()

            // Right eye
            let rightEye = NSBezierPath(ovalIn: NSRect(
                x: 12.7 * s - 1.2 * s, y: 7.2 * s - 1.2 * s,
                width: 2.4 * s, height: 2.4 * s
            ))
            rightEye.fill()

            return true
        }
        return image
    }

    func createMenuBarIcon() -> NSImage {
        let icon = drawPeekabooIcon(size: 18, color: .black)
        icon.isTemplate = true  // lets macOS handle light/dark
        return icon
    }

    func createAppIcon() -> NSImage {
        // Draw at 512pt for the app icon (Dock, Activity Monitor, etc.)
        // White monitor on a gradient blue background in a rounded rect
        let size: CGFloat = 512
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            // Background: rounded square with gradient
            let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2),
                                      xRadius: size * 0.22, yRadius: size * 0.22)
            let gradient = NSGradient(starting: NSColor(red: 0.2, green: 0.5, blue: 0.95, alpha: 1.0),
                                      ending: NSColor(red: 0.15, green: 0.35, blue: 0.8, alpha: 1.0))
            gradient?.draw(in: bgPath, angle: -90)

            return true
        }

        // Draw the monitor icon on top
        let monitorIcon = drawPeekabooIcon(size: size * 0.55, color: .white, lineScale: 1.8)
        image.lockFocus()
        let iconSize = size * 0.55
        let offset = (size - iconSize) / 2
        monitorIcon.draw(in: NSRect(x: offset, y: offset - size * 0.02, width: iconSize, height: iconSize))
        image.unlockFocus()

        return image
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the application icon (visible in Activity Monitor, Force Quit, etc.)
        NSApp.applicationIconImage = createAppIcon()

        // Create the menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = createMenuBarIcon()
            button.image?.isTemplate = true
        }

        // Start Bonjour discovery
        bonjourBrowser.onUpdate = { [weak self] in
            DispatchQueue.main.async {
                self?.rebuildMenu()
            }
        }

        let prefs = SettingsStore.shared.preferences
        if prefs.autoDiscoverOnLaunch {
            bonjourBrowser.startBrowsing()
        }

        // Set up periodic refresh
        startRefreshTimer()

        // Build initial menu
        rebuildMenu()
    }

    func startRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(SettingsStore.shared.preferences.refreshIntervalSeconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.bonjourBrowser.refresh()
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let prefs = SettingsStore.shared.preferences
        let savedHosts = SettingsStore.shared.savedHosts

        // Favorites section
        let favorites = savedHosts.filter { $0.isFavorite }
        if prefs.showFavoritesAtTop && !favorites.isEmpty {
            let header = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(string: "\u{2605} Favorites", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            menu.addItem(header)

            for host in favorites {
                let title = host.highPerformance ? "\(host.displayName) \u{26A1}" : host.displayName
                let item = NSMenuItem(title: title, action: #selector(connectToSaved(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = host.hostname
                item.toolTip = "\(host.hostname) (\(host.username.isEmpty ? "no user" : host.username))"
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Saved hosts section (non-favorites)
        let nonFavSaved = prefs.showFavoritesAtTop ? savedHosts.filter { !$0.isFavorite } : savedHosts
        if !nonFavSaved.isEmpty {
            let header = NSMenuItem(title: "Saved Hosts", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(string: "Saved Hosts", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            menu.addItem(header)

            for host in nonFavSaved {
                let title = host.highPerformance ? "\(host.displayName) \u{26A1}" : host.displayName
                let item = NSMenuItem(title: title, action: #selector(connectToSaved(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = host.hostname
                item.toolTip = "\(host.hostname) (\(host.username.isEmpty ? "no user" : host.username))"
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Discovered hosts section
        if prefs.showDiscoveredHosts && !bonjourBrowser.discoveredHosts.isEmpty {
            let header = NSMenuItem(title: "Discovered on Network", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(string: "Discovered on Network", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            menu.addItem(header)

            for discovered in bonjourBrowser.discoveredHosts {
                // Skip if already in saved hosts
                let alreadySaved = savedHosts.contains { $0.hostname == discovered.hostname }
                if alreadySaved { continue }

                let item = NSMenuItem(title: "\(discovered.name)", action: #selector(connectToDiscovered(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = discovered
                item.toolTip = discovered.hostname

                // Submenu for discovered host options
                let sub = NSMenu()
                let connectItem = NSMenuItem(title: "Connect", action: #selector(connectToDiscovered(_:)), keyEquivalent: "")
                connectItem.target = self
                connectItem.representedObject = discovered
                sub.addItem(connectItem)

                let saveItem = NSMenuItem(title: "Save to Favorites...", action: #selector(saveDiscovered(_:)), keyEquivalent: "")
                saveItem.target = self
                saveItem.representedObject = discovered
                sub.addItem(saveItem)

                item.submenu = sub
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Actions
        let quickConnect = NSMenuItem(title: "Quick Connect...", action: #selector(quickConnect), keyEquivalent: "k")
        quickConnect.target = self
        menu.addItem(quickConnect)

        let refreshItem = NSMenuItem(title: "Refresh Discovery", action: #selector(refreshDiscovery), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Peekaboo", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func connectToSaved(_ sender: NSMenuItem) {
        guard let hostname = sender.representedObject as? String,
              let host = SettingsStore.shared.savedHosts.first(where: { $0.hostname == hostname })
        else { return }
        ConnectionManager.connect(host: host)
    }

    @objc func connectToDiscovered(_ sender: NSMenuItem) {
        guard let discovered = sender.representedObject as? (name: String, hostname: String, port: Int) else { return }
        let host = SavedHost(
            displayName: discovered.name,
            hostname: discovered.hostname,
            port: discovered.port,
            highPerformance: SettingsStore.shared.preferences.defaultHighPerformance
        )
        ConnectionManager.connect(host: host)
    }

    @objc func saveDiscovered(_ sender: NSMenuItem) {
        guard let discovered = sender.representedObject as? (name: String, hostname: String, port: Int) else { return }
        let host = SavedHost(
            displayName: discovered.name,
            hostname: discovered.hostname,
            port: discovered.port,
            isFavorite: true
        )
        prefsController.showHostEditor(host: host)
        rebuildMenu()
    }

    @objc func quickConnect() {
        QuickConnectPanel.show()
    }

    @objc func refreshDiscovery() {
        bonjourBrowser.refresh()
    }

    @objc func showPreferences() {
        prefsController.onClose = { [weak self] in
            self?.rebuildMenu()
            self?.startRefreshTimer()
        }
        prefsController.showWindow()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
