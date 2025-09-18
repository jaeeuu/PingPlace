import Cocoa
import ApplicationServices
import os.log
import ServiceManagement

enum NotificationPosition: String, CaseIterable {
    case topLeft, topMiddle, topRight
    case middleLeft, deadCenter, middleRight
    case bottomLeft, bottomMiddle, bottomRight

    var displayName: String {
        switch self {
        case .topLeft:       return "Top Left"
        case .topMiddle:     return "Top Middle"
        case .topRight:      return "Top Right"
        case .middleLeft:    return "Middle Left"
        case .deadCenter:    return "Middle"
        case .middleRight:   return "Middle Right"
        case .bottomLeft:    return "Bottom Left"
        case .bottomMiddle:  return "Bottom Middle"
        case .bottomRight:   return "Bottom Right"
        }
    }
}

private enum DefaultsKey {
    static let isMenuBarIconHidden   = "isMenuBarIconHidden"
    static let notificationPosition  = "notificationPosition"
    static let debugMode             = "debugMode"
}

final class NotificationMover: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let notificationCenterBundleID = "com.apple.notificationcenterui"
    private var axObserver: AXObserver?
    private var statusItem: NSStatusItem?
    private var widgetMonitorTimer: Timer?
    private var observerRetryTimer: Timer?
    private let edgeInset: CGFloat = 16              
    private let bottomInsetAboveDock: CGFloat = 30   
    private let userDefaults = UserDefaults.standard

    private var isMenuBarIconHidden: Bool {
        get { userDefaults.bool(forKey: DefaultsKey.isMenuBarIconHidden) }
        set { userDefaults.set(newValue, forKey: DefaultsKey.isMenuBarIconHidden) }
    }

    private var debugMode: Bool {
        userDefaults.bool(forKey: DefaultsKey.debugMode)
    }

    
    private var currentPosition: NotificationPosition {
        get {
            if let raw = userDefaults.string(forKey: DefaultsKey.notificationPosition),
               let pos = NotificationPosition(rawValue: raw) {
                return pos
            }
            return .topMiddle
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: DefaultsKey.notificationPosition)
        }
    }

    
    private let logger = Logger(subsystem: "com.grimridge.PingPlace", category: "NotificationMover")
    private var pollingEndTime: Date?
    private var lastWidgetPresenceFlag = 0

    

    func applicationDidFinishLaunching(_ : Notification) {
        guard checkAccessibilityPermissions() else { return }

        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        setupObserver() 
        setupStatusItem()
        moveAllNotifications()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        
        if isMenuBarIconHidden {
            setupStatusItem(forceShowWhileActive: true)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        
        if isMenuBarIconHidden {
            setupStatusItem(forceShowWhileActive: false)
        }
    }

    deinit {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        widgetMonitorTimer?.invalidate()
        observerRetryTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func debugLog(_ message: String) {
        guard debugMode else { return }
        logger.info("\(message, privacy: .public)")
    }

    @discardableResult
    private func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "PingPlace needs accessibility permission to detect and move notifications.\n\nPlease grant permission in System Settings and restart the app."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            NSApplication.shared.terminate(nil)
            return false
        }
        return true
    }

    private func setupStatusItem(forceShowWhileActive: Bool = false) {
        let shouldShow = forceShowWhileActive || !isMenuBarIconHidden
        if !shouldShow {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }

        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = statusItem?.button, let icon = NSImage(named: "MenuBarIcon") {
                icon.isTemplate = true
                button.image = icon
            }
        }
        statusItem?.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()

        
        for pos in NotificationPosition.allCases {
            let item = NSMenuItem(title: pos.displayName, action: #selector(changePosition(_:)), keyEquivalent: "")
            item.representedObject = pos
            item.state = (pos == currentPosition) ? .on : .off
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(launchItem)

        let hideItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(toggleMenuBarIcon(_:)), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        
        let about = NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let donateMenu = NSMenuItem(title: "Donate", action: nil, keyEquivalent: "")
        let donateSub = NSMenu()
        let kofi = NSMenuItem(title: "Ko-fi", action: #selector(openKofi), keyEquivalent: "")
        kofi.target = self
        let bmac = NSMenuItem(title: "Buy Me a Coffee", action: #selector(openBuyMeACoffee), keyEquivalent: "")
        bmac.target = self
        donateSub.addItem(kofi)
        donateSub.addItem(bmac)
        donateMenu.submenu = donateSub
        menu.addItem(donateMenu)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    @objc private func openKofi() {
        if let url = URL(string: "https://ko-fi.com/wadegrimridge") { NSWorkspace.shared.open(url) }
    }
    @objc private func openBuyMeACoffee() {
        if let url = URL(string: "https://www.buymeacoffee.com/wadegrimridge") { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleMenuBarIcon(_ : NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Hide Menu Bar Icon"
        alert.informativeText =
            "The menu bar icon will be hidden.\n\n" +
            "Tip: Open PingPlace (bring it to the foreground) and the icon will temporarily reappear so you can change settings."
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isMenuBarIconHidden = true
        
        setupStatusItem(forceShowWhileActive: false)
    }

    private func isLoginItemEnabled() -> Bool {
        return SMAppService.mainApp.status == .registered
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .registered {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            showError("Failed to update Launch at Login: \(error.localizedDescription)")
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func changePosition(_ sender: NSMenuItem) {
        guard let pos = sender.representedObject as? NotificationPosition else { return }
        currentPosition = pos

        
        sender.menu?.items.forEach { item in
            guard let p = item.representedObject as? NotificationPosition else { return }
            item.state = (p == pos) ? .on : .off
        }

        debugLog("Position changed to: \(pos.displayName)")
        moveAllNotifications()
    }

    @objc private func showAbout() {
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

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "N/A"
        let copyright = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""

        let elements: [(NSView, CGFloat)] = [
            (createIconView(), 165),
            (createLabel("PingPlace", font: .boldSystemFont(ofSize: 16)), 110),
            (createLabel("Version \(version)"), 90),
            (createLabel("Made with <3 by Wade"), 70),
            (createTwitterButton(), 40),
            (createLabel(copyright, color: .secondaryLabelColor, size: 11), 20),
        ]

        for (view, y) in elements {
            if view is NSImageView {
                view.frame = NSRect(x: 100, y: y, width: 100, height: 100)
            } else {
                view.frame = NSRect(x: 0, y: y, width: 300, height: 20)
            }
            contentView.addSubview(view)
        }

        aboutWindow.contentView = contentView
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createIconView() -> NSImageView {
        let v = NSImageView()
        if let img = NSImage(named: "icon") {
            v.image = img
            v.imageScaling = .scaleProportionallyDown
        }
        return v
    }

    private func createLabel(_ text: String, font: NSFont = .systemFont(ofSize: 12), color: NSColor = .labelColor, size _: CGFloat = 12) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .center
        l.font = font
        l.textColor = color
        return l
    }

    private func createTwitterButton() -> NSButton {
        let b = NSButton()
        b.title = "@WadeGrimridge"
        b.bezelStyle = .inline
        b.isBordered = false
        b.target = self
        b.action = #selector(openTwitter)
        b.attributedTitle = NSAttributedString(
            string: "@WadeGrimridge",
            attributes: [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        )
        return b
    }

    @objc private func openTwitter() {
        if let url = URL(string: "https:
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func appLaunched(_ note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.bundleIdentifier == notificationCenterBundleID
        else { return }
        debugLog("Notification Center launched; attempting to set up AX observer.")
        setupObserver()
    }

    @objc private func appTerminated(_ note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.bundleIdentifier == notificationCenterBundleID
        else { return }
        debugLog("Notification Center terminated; tearing down AX observer.")
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        scheduleObserverRetry()
    }

    private func setupObserver() {
        
        if axObserver != nil { return }

        guard let axApp = notificationCenterAXApp(), let pid = pidForNotificationCenter() else {
            debugLog("Notification Center not found; scheduling retry.")
            scheduleObserverRetry()
            return
        }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, observerCallback, &observer)
        guard result == .success, let observer else {
            debugLog("AXObserverCreate failed: \(result.rawValue); scheduling retry.")
            scheduleObserverRetry()
            return
        }
        axObserver = observer

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let add1 = AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString, ctx)
        if add1 != .success { debugLog("AddNotification(WindowCreated) failed: \(add1.rawValue)") }

        
        _ = AXObserverAddNotification(observer, axApp, kAXWindowMovedNotification as CFString, ctx)
        _ = AXObserverAddNotification(observer, axApp, kAXWindowResizedNotification as CFString, ctx)

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)

        debugLog("Observer setup complete for Notification Center (PID: \(pid))")
        observerRetryTimer?.invalidate()

        
        widgetMonitorTimer?.invalidate()
        widgetMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkForWidgetChanges()
        }
    }

    private func scheduleObserverRetry() {
        observerRetryTimer?.invalidate()
        observerRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.setupObserver()
        }
    }

    private func pidForNotificationCenter() -> pid_t? {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == notificationCenterBundleID })?.processIdentifier
    }

    private func notificationCenterAXApp() -> AXUIElement? {
        guard let pid = pidForNotificationCenter() else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    func moveNotification(_ element: AXUIElement) {
        
        if hasNotificationCenterUI() {
            debugLog("Skipping move - Notification Center UI (widgets) visible")
            return
        }

        guard let (winPos, winSize) = getWindowFrame(element) else {
            debugLog("Failed to read window frame")
            return
        }

        guard let screen = screenForPoint(CGPoint(x: winPos.x + winSize.width/2,
                                                  y: winPos.y + winSize.height/2)) ??
                              NSScreen.main else {
            debugLog("No screen for window; skipping")
            return
        }

        let target = targetOrigin(for: winSize, on: screen, position: currentPosition)
        setWindowOrigin(element, target)
        pollingEndTime = Date().addingTimeInterval(6.5)
        debugLog("Moved notification to \(currentPosition.displayName) → (\(Int(target.x)), \(Int(target.y)))")
    }

    private func moveAllNotifications() {
        guard let axApp = notificationCenterAXApp() else {
            debugLog("Cannot find Notification Center process")
            return
        }

        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            debugLog("Failed to get notification windows")
            return
        }

        for w in windows where isNotificationWindow(w) {
            moveNotification(w)
        }
    }

    private func isNotificationWindow(_ window: AXUIElement) -> Bool {
        
        return findElementWithSubrole(root: window, targetSubroles: ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]) != nil
    }

    private func getWindowFrame(_ element: AXUIElement) -> (CGPoint, CGSize)? {
        guard let pos = getPosition(of: element), let size = getSize(of: element) else { return nil }
        return (pos, size)
    }

    private func screenForPoint(_ p: CGPoint) -> NSScreen? {
        
        return NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: p.x, y: p.y)) })
    }

    private func targetOrigin(for windowSize: CGSize, on screen: NSScreen, position: NotificationPosition) -> CGPoint {
        let vf = screen.visibleFrame
        let leftX  = vf.minX + edgeInset
        let rightX = vf.maxX - edgeInset - windowSize.width
        let midX   = vf.midX - windowSize.width / 2
        let topY    = vf.maxY - edgeInset - windowSize.height
        let midY    = vf.midY - windowSize.height / 2
        let bottomY = vf.minY + bottomInsetAboveDock

        switch position {
        case .topLeft:       return CGPoint(x: leftX,  y: topY)
        case .topMiddle:     return CGPoint(x: midX,   y: topY)
        case .topRight:      return CGPoint(x: rightX, y: topY)
        case .middleLeft:    return CGPoint(x: leftX,  y: midY)
        case .deadCenter:    return CGPoint(x: midX,   y: midY)
        case .middleRight:   return CGPoint(x: rightX, y: midY)
        case .bottomLeft:    return CGPoint(x: leftX,  y: bottomY)
        case .bottomMiddle:  return CGPoint(x: midX,   y: bottomY)
        case .bottomRight:   return CGPoint(x: rightX, y: bottomY)
        }
    }

    private func getPosition(of element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        let res = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard res == .success, let ax = value as? AXValue, AXValueGetType(ax) == .cgPoint else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(ax, .cgPoint, &p)
        return p
    }

    private func getSize(of element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        let res = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        guard res == .success, let ax = value as? AXValue, AXValueGetType(ax) == .cgSize else { return nil }
        var s = CGSize.zero
        AXValueGetValue(ax, .cgSize, &s)
        return s
    }

    private func setWindowOrigin(_ element: AXUIElement, _ origin: CGPoint) {
        var p = origin
        if let v = AXValueCreate(.cgPoint, &p) {
            let res = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v)
            if res != .success { debugLog("Failed to set position: \(res.rawValue)") }
        }
    }

    private func findElementWithSubrole(root: AXUIElement, targetSubroles: [String]) -> AXUIElement? {
        var subroleRef: AnyObject?
        if AXUIElementCopyAttributeValue(root, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String, targetSubroles.contains(subrole) {
            return root
        }
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for c in children {
            if let found = findElementWithSubrole(root: c, targetSubroles: targetSubroles) {
                return found
            }
        }
        return nil
    }

    private func getWindowIdentifier(_ element: AXUIElement) -> String? {
        var idRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &idRef) == .success else {
            return nil
        }
        return idRef as? String
    }

    private func hasNotificationCenterUI() -> Bool {
        
        guard let axApp = notificationCenterAXApp() else { return false }

        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }

        for w in windows {
            if let id = getWindowIdentifier(w), id.hasPrefix("widget-local") { return true }
        }
        return false
    }

    private func checkForWidgetChanges() {
        guard let end = pollingEndTime, Date() < end else { return }
        let hasUI = hasNotificationCenterUI()
        let flag = hasUI ? 1 : 0
        if lastWidgetPresenceFlag != flag {
            debugLog("Notification Center widget state changed (\(lastWidgetPresenceFlag) → \(flag))")
            if !hasUI { moveAllNotifications() }
        }
        lastWidgetPresenceFlag = flag
    } 

    func handleAX(notification: String, senderElement: AXUIElement) {
        switch notification {
        case (kAXWindowCreatedNotification as String):
            
            moveAllNotifications()

        case (kAXWindowMovedNotification as String),
             (kAXWindowResizedNotification as String):
            if isNotificationWindow(senderElement) {
                moveNotification(senderElement)
            } else {
                moveAllNotifications()
            }

        default:
            break
        }
    }
}

private func observerCallback(observer _: AXObserver, element: AXUIElement, notification: CFString, context: UnsafeMutableRawPointer?) {
    guard let ctx = context else { return }
    let mover = Unmanaged<NotificationMover>.fromOpaque(ctx).takeUnretainedValue()
    mover.handleAX(notification: notification as String, senderElement: element)
}

let app = NSApplication.shared
let delegate = NotificationMover()
app.delegate = delegate
app.run()
