import ApplicationServices
import Cocoa
import os.log

enum NotificationPosition: String, CaseIterable {
    case topLeft, topMiddle, topRight
    case middleLeft, deadCenter, middleRight
    case bottomLeft, bottomMiddle, bottomRight

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topMiddle: return "Top Middle"
        case .topRight: return "Top Right"
        case .middleLeft: return "Middle Left"
        case .deadCenter: return "Dead Center"
        case .middleRight: return "Middle Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomMiddle: return "Bottom Middle"
        case .bottomRight: return "Bottom Right"
        }
    }
}

class NotificationMover: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let notificationCenterBundleID = "com.apple.notificationcenterui"
    private let paddingAboveDock: CGFloat = 30
    private var axObserver: AXObserver?
    private var statusItem: NSStatusItem?
    private var isMenuBarIconHidden = UserDefaults.standard.bool(forKey: "isMenuBarIconHidden")
    private let logger = Logger(subsystem: "com.grimridge.PingPlace", category: "NotificationMover")
    private let debugMode = UserDefaults.standard.bool(forKey: "debugMode")
    private let launchAgentPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.grimridge.PingPlace.plist"

    private var cachedInitialPosition: CGPoint?
    private var cachedInitialWindowSize: CGSize?
    private var cachedInitialNotifSize: CGSize?
    private var cachedInitialPadding: CGFloat?

    private var currentPosition: NotificationPosition = {
        guard let rawValue = UserDefaults.standard.string(forKey: "notificationPosition"),
              let position = NotificationPosition(rawValue: rawValue)
        else {
            return .topMiddle
        }
        return position
    }()

    func applicationDidFinishLaunching(_: Notification) {
        checkAccessibilityPermissions()
        setupObserver()
        if !isMenuBarIconHidden {
            setupStatusItem()
        }
    }

    func applicationWillBecomeActive(_: Notification) {
        guard isMenuBarIconHidden else { return }
        isMenuBarIconHidden = false
        UserDefaults.standard.set(false, forKey: "isMenuBarIconHidden")
        setupStatusItem()
    }

    private func checkAccessibilityPermissions() {
        guard !AXIsProcessTrusted() else { return }

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

    func setupStatusItem() {
        guard !isMenuBarIconHidden else {
            statusItem = nil
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button, let menuBarIcon = NSImage(named: "MenuBarIcon") {
            menuBarIcon.isTemplate = true
            button.image = menuBarIcon
        }
        statusItem?.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()

        for position in NotificationPosition.allCases {
            let item = NSMenuItem(title: position.displayName, action: #selector(changePosition(_:)), keyEquivalent: "")
            item.representedObject = position
            item.state = position == currentPosition ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = FileManager.default.fileExists(atPath: launchAgentPlistPath) ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(toggleMenuBarIcon(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let donateMenu = NSMenuItem(title: "Donate", action: nil, keyEquivalent: "")
        let donateSubmenu = NSMenu()
        donateSubmenu.addItem(NSMenuItem(title: "Ko-fi", action: #selector(openKofi), keyEquivalent: ""))
        donateSubmenu.addItem(NSMenuItem(title: "Buy Me a Coffee", action: #selector(openBuyMeACoffee), keyEquivalent: ""))
        donateMenu.submenu = donateSubmenu

        menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(donateMenu)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    @objc private func openKofi() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/wadegrimridge")!)
    }

    @objc private func openBuyMeACoffee() {
        NSWorkspace.shared.open(URL(string: "https://www.buymeacoffee.com/wadegrimridge")!)
    }

    @objc private func toggleMenuBarIcon(_: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Hide Menu Bar Icon"
        alert.informativeText = "The menu bar icon will be hidden. To show it again, launch PingPlace again."
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isMenuBarIconHidden = true
        UserDefaults.standard.set(true, forKey: "isMenuBarIconHidden")
        statusItem = nil
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let isEnabled = FileManager.default.fileExists(atPath: launchAgentPlistPath)

        if isEnabled {
            do {
                try FileManager.default.removeItem(atPath: launchAgentPlistPath)
                sender.state = .off
            } catch {
                showError("Failed to disable launch at login: \(error.localizedDescription)")
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
                showError("Failed to enable launch at login: \(error.localizedDescription)")
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func changePosition(_ sender: NSMenuItem) {
        guard let position = sender.representedObject as? NotificationPosition else { return }
        currentPosition = position
        UserDefaults.standard.set(position.rawValue, forKey: "notificationPosition")

        sender.menu?.items.forEach { item in
            item.state = (item.representedObject as? NotificationPosition) == position ? .on : .off
        }

        moveAllVisibleNotifications()
    }

    private func moveAllVisibleNotifications() {
        guard let pid = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == notificationCenterBundleID
        })?.processIdentifier else { return }

        let app = AXUIElementCreateApplication(pid)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        for window in windows {
            guard !hasWidgetElements(window) else { continue }

            let targetSubroles = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]
            guard let _ = findElementWithSubrole(root: window, targetSubroles: targetSubroles) else { continue }

            if let cachedPos = cachedInitialPosition,
               let cachedWinSize = cachedInitialWindowSize,
               let cachedNotifSize = cachedInitialNotifSize,
               let cachedPad = cachedInitialPadding
            {
                setPosition(window, x: cachedPos.x, y: cachedPos.y)

                let newPosition = calculateNewPosition(
                    windowSize: cachedWinSize,
                    notifSize: cachedNotifSize,
                    position: cachedPos,
                    padding: cachedPad
                )

                setPosition(window, x: newPosition.x, y: newPosition.y)
            }
        }
    }

    @objc func showAbout() {
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

        let elements: [(NSView, CGFloat)] = [
            (createIconView(), 165),
            (createLabel("PingPlace", font: .boldSystemFont(ofSize: 16)), 110),
            (createLabel("Version 1.2.0"), 90),
            (createLabel("Made with <3 by Wade"), 70),
            (createTwitterButton(), 40),
            (createLabel("© 2025 All rights reserved.", color: .secondaryLabelColor, size: 11), 20),
        ]

        for (view, y) in elements {
            view.frame = NSRect(x: 0, y: y, width: 300, height: 20)
            if view is NSImageView {
                view.frame = NSRect(x: 100, y: y, width: 100, height: 100)
            }
            contentView.addSubview(view)
        }

        aboutWindow.contentView = contentView
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createIconView() -> NSImageView {
        let iconImageView = NSImageView()
        if let iconImage = NSImage(named: "icon") {
            iconImageView.image = iconImage
            iconImageView.imageScaling = .scaleProportionallyDown
        }
        return iconImageView
    }

    private func createLabel(_ text: String, font: NSFont = .systemFont(ofSize: 12), color: NSColor = .labelColor, size _: CGFloat = 12) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .center
        label.font = font
        label.textColor = color
        return label
    }

    private func createTwitterButton() -> NSButton {
        let button = NSButton()
        button.title = "@WadeGrimridge"
        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = #selector(openTwitter)
        button.attributedTitle = NSAttributedString(string: "@WadeGrimridge", attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        return button
    }

    @objc private func openTwitter() {
        NSWorkspace.shared.open(URL(string: "https://x.com/WadeGrimridge")!)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func setupObserver() {
        guard let pid = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == notificationCenterBundleID
        })?.processIdentifier else { return }

        let app = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        AXObserverCreate(pid, observerCallback, &observer)
        axObserver = observer

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        AXObserverAddNotification(observer!, app, kAXWindowCreatedNotification as CFString, selfPtr)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer!), .defaultMode)
    }

    func repositionNotification(_ window: AXUIElement) {
        guard currentPosition != .topRight else { return }

        if debugMode {
            let windowTitle = getWindowTitle(window)
            let windowIdentifier = getWindowIdentifier(window)
            logger.info("Window created with title: '\(windowTitle ?? "nil", privacy: .public)', identifier: '\(windowIdentifier ?? "nil", privacy: .public)'")
        }

        guard !hasWidgetElements(window) else {
            if debugMode {
                logger.info("Skipping - detected Notification Center UI (has widget elements)")
            }
            return
        }

        let targetSubroles = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]

        guard let windowSize = getSize(of: window),
              let bannerContainer = findElementWithSubrole(root: window, targetSubroles: targetSubroles),
              let notifSize = getSize(of: bannerContainer),
              let position = getPosition(of: bannerContainer)
        else {
            if debugMode {
                logger.info("Failed validation checks")
            }
            return
        }

        if cachedInitialPosition == nil {
            let screenWidth = NSScreen.main!.frame.width
            let rightEdge = position.x + notifSize.width
            let padding = screenWidth - rightEdge

            cachedInitialPosition = position
            cachedInitialWindowSize = windowSize
            cachedInitialNotifSize = notifSize
            cachedInitialPadding = padding

            if debugMode {
                logger.info("Cached initial notification position and dimensions")
            }
        }

        if debugMode {
            logger.info("Repositioning valid notification window")
        }

        let screenWidth = NSScreen.main!.frame.width
        let rightEdge = position.x + notifSize.width
        let padding = screenWidth - rightEdge

        let newPosition = calculateNewPosition(
            windowSize: windowSize,
            notifSize: notifSize,
            position: position,
            padding: padding
        )

        setPosition(window, x: newPosition.x, y: newPosition.y)
    }

    private func getWindowIdentifier(_ element: AXUIElement) -> String? {
        var identifierRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifierRef) == .success else {
            return nil
        }
        return identifierRef as? String
    }

    private func hasWidgetElements(_ window: AXUIElement) -> Bool {
        return findElementWithWidgetIdentifier(root: window) != nil
    }

    private func findElementWithWidgetIdentifier(root: AXUIElement) -> AXUIElement? {
        if let identifier = getWindowIdentifier(root), identifier.hasPrefix("widget") {
            return root
        }

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else {
            return nil
        }

        for child in children {
            if let found = findElementWithWidgetIdentifier(root: child) {
                return found
            }
        }
        return nil
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
        windowSize: CGSize,
        notifSize: CGSize,
        position: CGPoint,
        padding: CGFloat
    ) -> (x: CGFloat, y: CGFloat) {
        let newX: CGFloat
        let newY: CGFloat

        switch currentPosition {
        case .topLeft, .middleLeft, .bottomLeft:
            newX = padding - position.x
        case .topMiddle, .bottomMiddle, .deadCenter:
            newX = -(windowSize.width - notifSize.width) / 2
        case .topRight, .middleRight, .bottomRight:
            newX = 0
        }

        switch currentPosition {
        case .topLeft, .topMiddle, .topRight:
            newY = 0
        case .middleLeft, .middleRight, .deadCenter:
            let dockSize = NSScreen.main!.frame.height - NSScreen.main!.visibleFrame.height
            newY = (windowSize.height - notifSize.height) / 2 - dockSize - paddingAboveDock
        case .bottomLeft, .bottomMiddle, .bottomRight:
            let dockSize = NSScreen.main!.frame.height - NSScreen.main!.visibleFrame.height
            newY = windowSize.height - notifSize.height - dockSize - paddingAboveDock
        }

        return (newX, newY)
    }

    private func getWindowTitle(_ element: AXUIElement) -> String? {
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return nil
        }
        return titleRef as? String
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

private func observerCallback(observer _: AXObserver, element: AXUIElement, notification _: CFString, context: UnsafeMutableRawPointer?) {
    let mover = Unmanaged<NotificationMover>.fromOpaque(context!).takeUnretainedValue()
    mover.repositionNotification(element)
}

let app = NSApplication.shared
let delegate = NotificationMover()
app.delegate = delegate
app.run()
