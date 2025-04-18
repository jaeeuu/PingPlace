import ApplicationServices
import Cocoa

enum NotificationPosition {
    case topLeft, topMiddle, topRight
    case middleLeft, middleRight
    case bottomLeft, bottomMiddle, bottomRight
}

protocol NotificationPositionable {
    func repositionNotification()
    func setupObserver()
}

protocol UIConfigurable {
    func setupStatusItem()
    func showAbout()
}

class NotificationMover: NSObject, NSApplicationDelegate {
    private let notificationCenterBundleID = "com.apple.notificationcenterui"
    private let notificationWindowTitle = "Notification Center"
    private let paddingAboveDock: CGFloat = 30
    private var axObserver: AXObserver?
    private var statusItem: NSStatusItem?
    private var currentPosition: NotificationPosition = {
        let rawValue = UserDefaults.standard.string(forKey: "notificationPosition") ?? "topMiddle"
        switch rawValue {
        case "topLeft": return .topLeft
        case "topMiddle": return .topMiddle
        case "topRight": return .topRight
        case "middleLeft": return .middleLeft
        case "middleRight": return .middleRight
        case "bottomLeft": return .bottomLeft
        case "bottomMiddle": return .bottomMiddle
        case "bottomRight": return .bottomRight
        default: return .topMiddle
        }
    }()

    private let launchAgentPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.grimridge.PingPlace.plist"

    func applicationDidFinishLaunching(_: Notification) {
        checkAccessibilityPermissions()
        setupObserver()
        setupStatusItem()
    }

    private func checkAccessibilityPermissions() {
        if !AXIsProcessTrusted() {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permissions Needed"
            alert.informativeText = "Please enable accessibility for PingPlace in System Preferences > Security & Privacy > Privacy > Accessibility.\n\nIf PingPlace is already listed, please select it and click the minus (-) button to remove it completely, then add it again.\n\nSorry for the inconvenience (blame Apple's greed), it shouldn't happen again!"
            alert.addButton(withTitle: "Open System Preferences")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            NSApplication.shared.terminate(nil)
        }
    }
}

extension NotificationMover: UIConfigurable {
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            if let menuBarIcon = NSImage(named: "MenuBarIcon") {
                menuBarIcon.isTemplate = true
                button.image = menuBarIcon
            }
        }

        let menu = createMenu()
        statusItem?.menu = menu
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()

        let positions: [(String, NotificationPosition)] = [
            ("Top Left", .topLeft),
            ("Top Middle", .topMiddle),
            ("Top Right", .topRight),
            ("Middle Left", .middleLeft),
            ("Middle Right", .middleRight),
            ("Bottom Left", .bottomLeft),
            ("Bottom Middle", .bottomMiddle),
            ("Bottom Right", .bottomRight),
        ]

        for (title, position) in positions {
            let item = NSMenuItem(title: title, action: #selector(changePosition(_:)), keyEquivalent: "")
            item.representedObject = position
            item.state = position == currentPosition ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = FileManager.default.fileExists(atPath: launchAgentPlistPath) ? .on : .off
        menu.addItem(launchItem)

        let donateMenu = NSMenuItem(title: "Donate", action: nil, keyEquivalent: "")
        let donateSubmenu = NSMenu()

        let kofiItem = NSMenuItem(title: "Ko-fi", action: #selector(openKofi), keyEquivalent: "")
        let buyMeACoffeeItem = NSMenuItem(title: "Buy Me a Coffee", action: #selector(openBuyMeACoffee), keyEquivalent: "")

        menu.addItem(NSMenuItem.separator())
        donateSubmenu.addItem(kofiItem)
        donateSubmenu.addItem(buyMeACoffeeItem)
        donateMenu.submenu = donateSubmenu
        menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(donateMenu)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func openKofi() {
        if let url = URL(string: "https://ko-fi.com/wadegrimridge") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openBuyMeACoffee() {
        if let url = URL(string: "https://www.buymeacoffee.com/wadegrimridge") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let isEnabled = FileManager.default.fileExists(atPath: launchAgentPlistPath)
        if isEnabled {
            do {
                try FileManager.default.removeItem(atPath: launchAgentPlistPath)
                sender.state = .off
            } catch {
                let alert = NSAlert()
                alert.messageText = "Error"
                alert.informativeText = "Failed to disable launch at login: \(error.localizedDescription)"
                alert.runModal()
            }
        } else {
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.grimridge.PingPlace</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(Bundle.main.executablePath!)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            do {
                try plistContent.write(toFile: launchAgentPlistPath, atomically: true, encoding: .utf8)
                sender.state = .on
            } catch {
                let alert = NSAlert()
                alert.messageText = "Error"
                alert.informativeText = "Failed to enable launch at login: \(error.localizedDescription)"
                alert.runModal()
            }
        }
    }

    @objc private func changePosition(_ sender: NSMenuItem) {
        guard let position = sender.representedObject as? NotificationPosition else { return }
        currentPosition = position

        let positionString = String(describing: position)
        UserDefaults.standard.set(positionString, forKey: "notificationPosition")

        if let positionMenu = sender.menu {
            for item in positionMenu.items {
                item.state = (item.representedObject as? NotificationPosition) == position ? .on : .off
            }
        }

        repositionNotification()
    }

    @objc func showAbout() {
        let aboutWindow = createAboutWindow()
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createAboutWindow() -> NSWindow {
        let aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        aboutWindow.center()
        aboutWindow.title = "About PingPlace"
        aboutWindow.delegate = self

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))

        addLabelsToAboutWindow(contentView)

        aboutWindow.contentView = contentView
        return aboutWindow
    }

    private func addLabelsToAboutWindow(_ contentView: NSView) {
        let iconImageView = NSImageView(frame: NSRect(x: 100, y: 165, width: 100, height: 100))
        if let iconImage = NSImage(named: "icon") {
            iconImageView.image = iconImage
            iconImageView.imageScaling = .scaleProportionallyDown
            contentView.addSubview(iconImageView)
        }

        let titleLabel = NSTextField(labelWithString: "PingPlace")
        titleLabel.frame = NSRect(x: 0, y: 110, width: 300, height: 20)
        titleLabel.alignment = .center
        titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
        contentView.addSubview(titleLabel)

        let versionLabel = NSTextField(labelWithString: "Version 1.0.1")
        versionLabel.frame = NSRect(x: 0, y: 90, width: 300, height: 20)
        versionLabel.alignment = .center
        contentView.addSubview(versionLabel)

        let creditLabel = NSTextField(labelWithString: "Made with <3 by Wade")
        creditLabel.frame = NSRect(x: 0, y: 70, width: 300, height: 20)
        creditLabel.alignment = .center
        contentView.addSubview(creditLabel)

        let twitterButton = NSButton(frame: NSRect(x: 0, y: 40, width: 300, height: 20))
        twitterButton.title = "@WadeGrimridge"
        twitterButton.bezelStyle = .inline
        twitterButton.isBordered = false
        twitterButton.target = self
        twitterButton.action = #selector(openTwitter)
        twitterButton.attributedTitle = NSAttributedString(string: "@WadeGrimridge", attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        contentView.addSubview(twitterButton)

        let copyrightLabel = NSTextField(labelWithString: "© 2025 All rights reserved.")
        copyrightLabel.frame = NSRect(x: 0, y: 20, width: 300, height: 20)
        copyrightLabel.alignment = .center
        copyrightLabel.textColor = .secondaryLabelColor
        copyrightLabel.font = NSFont.systemFont(ofSize: 11)
        contentView.addSubview(copyrightLabel)
    }

    @objc private func openTwitter() {
        if let url = URL(string: "https://x.com/WadeGrimridge") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension NotificationMover: NotificationPositionable {
    func setupObserver() {
        guard let pid = getNotificationCenterPID() else { return }

        let app = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        AXObserverCreate(pid, observerCallback, &observer)
        axObserver = observer

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        AXObserverAddNotification(observer!, app, kAXWindowCreatedNotification as CFString, selfPtr)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer!), .defaultMode)
    }

    private func getNotificationCenterPID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == notificationCenterBundleID
        })?.processIdentifier
    }

    func repositionNotification() {
        if currentPosition == .topRight { return }

        guard let pid = getNotificationCenterPID() else { return }
        let app = AXUIElementCreateApplication(pid)
        guard let windows = getWindows(from: app) else { return }

        let targetSubroles = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]

        for window in windows where isNotificationWindow(window) {
            guard let windowSize = getSize(of: window),
                  let bannerContainer = findElementWithSubrole(root: window, targetSubroles: targetSubroles),
                  let notifSize = getSize(of: bannerContainer)
            else {
                continue
            }

            guard let position = getPosition(of: bannerContainer) else { continue }

            let screenWidth = NSScreen.main!.frame.width
            let rightEdge = position.x + notifSize.width
            let padding = screenWidth - rightEdge

            let newPosition = calculateNewPosition(
                currentPosition: currentPosition,
                windowSize: windowSize,
                notifSize: notifSize,
                position: position,
                padding: padding
            )

            setPosition(window, x: newPosition.x, y: newPosition.y)
        }
    }

    private func getPosition(of element: AXUIElement) -> CGPoint? {
        var positionValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        guard let posVal = positionValue, AXValueGetType(posVal as! AXValue) == .cgPoint else {
            return nil
        }
        var position = CGPoint.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
        return position
    }

    private func calculateNewPosition(
        currentPosition: NotificationPosition,
        windowSize: CGSize,
        notifSize: CGSize,
        position: CGPoint,
        padding: CGFloat
    ) -> (x: CGFloat, y: CGFloat) {
        var newX: CGFloat = 0
        var newY: CGFloat = 0

        switch currentPosition {
        case .topLeft, .middleLeft, .bottomLeft:
            newX = padding - position.x
        case .topMiddle, .bottomMiddle:
            newX = -(windowSize.width - notifSize.width) / 2
        case .topRight, .middleRight, .bottomRight:
            newX = 0
        }

        switch currentPosition {
        case .topLeft, .topMiddle, .topRight:
            newY = 0
        case .middleLeft, .middleRight:
            let dockSize = NSScreen.main!.frame.height - NSScreen.main!.visibleFrame.height
            newY = (windowSize.height - notifSize.height) / 2 - dockSize - paddingAboveDock
        case .bottomLeft, .bottomMiddle, .bottomRight:
            let dockSize = NSScreen.main!.frame.height - NSScreen.main!.visibleFrame.height
            newY = windowSize.height - notifSize.height - dockSize - paddingAboveDock
        }

        return (newX, newY)
    }
}

extension NotificationMover {
    private func getWindows(from element: AXUIElement) -> [AXUIElement]? {
        var windows: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
        return windows as? [AXUIElement]
    }

    private func isNotificationWindow(_ window: AXUIElement) -> Bool {
        var title: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        return (title as? String) == notificationWindowTitle
    }

    private func getSize(of element: AXUIElement) -> CGSize? {
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard let sizeVal = sizeValue, AXValueGetType(sizeVal as! AXValue) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return size
    }

    private func getFirstChild(of element: AXUIElement) -> AXUIElement? {
        var children: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        return (children as? [AXUIElement])?.first
    }

    private func setPosition(_ element: AXUIElement, x: CGFloat, y: CGFloat) {
        var point = CGPoint(x: x, y: y)
        let value = AXValueCreate(.cgPoint, &point)!
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func findElementWithSubrole(root: AXUIElement, targetSubroles: [String]) -> AXUIElement? {
        var subroleRef: AnyObject?
        if AXUIElementCopyAttributeValue(root, kAXSubroleAttribute as CFString, &subroleRef) == .success {
            if let subrole = subroleRef as? String, targetSubroles.contains(subrole) {
                return root
            }
        }

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else {
            return nil
        }

        for child in children {
            if let found = findElementWithSubrole(root: child, targetSubroles: targetSubroles) {
                return found
            }
        }
        return nil
    }
}

extension NotificationMover: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private func observerCallback(observer _: AXObserver, element _: AXUIElement, notification _: CFString, context: UnsafeMutableRawPointer?) {
    let mover = Unmanaged<NotificationMover>.fromOpaque(context!).takeUnretainedValue()
    mover.repositionNotification()
}

let app = NSApplication.shared
let delegate = NotificationMover()
app.delegate = delegate
app.run()
