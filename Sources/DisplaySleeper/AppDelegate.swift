import Cocoa
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var lidLatchManager: LidLatchManager?
    private var statusItem: NSStatusItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[DisplaySleeper] Application launched in background mode (LSUIElement).")
        print("[DisplaySleeper] Application launched in background mode (LSUIElement).")
        fflush(stdout)
        
        setupStatusItem()
        checkAccessibilityPermissions()
        observeWorkspaceSleepEvents()
        
        // Initialize and start the LidLatchManager
        lidLatchManager = LidLatchManager()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "DisplaySleeper") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "🌙"
            }
            button.toolTip = "DisplaySleeper: Active"
        }
        
        let menu = NSMenu()
        
        let titleItem = NSMenuItem(title: "DisplaySleeper: Active", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let sleepItem = NSMenuItem(title: "Sleep System Now", action: #selector(sleepNowClicked), keyEquivalent: "s")
        sleepItem.target = self
        menu.addItem(sleepItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit DisplaySleeper", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc private func sleepNowClicked() {
        NSLog("[DisplaySleeper] Manual sleep triggered from menu bar.")
        print("[DisplaySleeper] Manual sleep triggered from menu bar.")
        fflush(stdout)
        LidLatchManager.defaultForceDisplaySleep()
    }
    
    @objc private func quitClicked() {
        NSLog("[DisplaySleeper] Quit requested from menu bar.")
        print("[DisplaySleeper] Quit requested from menu bar.")
        fflush(stdout)
        NSApp.terminate(nil)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[DisplaySleeper] Application terminating.")
        print("[DisplaySleeper] Application terminating.")
        fflush(stdout)
        lidLatchManager?.stopMonitoring()
        lidLatchManager = nil
    }
    
    // Diagnostics: log when macOS turns the screens or system off/on, to correlate with lid events.
    private func observeWorkspaceSleepEvents() {
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.screensDidSleepNotification, "Screens did sleep."),
            (NSWorkspace.screensDidWakeNotification, "Screens did wake."),
            (NSWorkspace.willSleepNotification, "System will sleep."),
            (NSWorkspace.didWakeNotification, "System did wake."),
        ]
        let center = NSWorkspace.shared.notificationCenter
        for (name, message) in events {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                NSLog("[DisplaySleeper] [workspace] %@", message)
                print("[DisplaySleeper] [workspace] \(message)")
                fflush(stdout)
            }
            workspaceObservers.append(observer)
        }
    }
    
    private func checkAccessibilityPermissions() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !isTrusted {
            let msg = "[DisplaySleeper] Note: Accessibility permissions not yet granted. System prompt requested. Note: CGEventSource zero-permission fallback is active for keyboard/click wake detection."
            NSLog(msg)
            print(msg)
            fflush(stdout)
        } else {
            NSLog("[DisplaySleeper] Accessibility permissions are granted.")
            print("[DisplaySleeper] Accessibility permissions are granted.")
            fflush(stdout)
        }
    }
}
