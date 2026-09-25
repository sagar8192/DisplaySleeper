import Cocoa
import Foundation
import IOKit
import CoreGraphics

public class LidLatchManager {
    // State Tracking
    private(set) var userIntendsToClose = false
    private var pollTimer: Timer?
    private var keyMonitor: Any?
    private var latchTrippedTime: Date?
    private var latchReleasedTime: Date?
    private var lastSleepCallTime: Date?
    private var wasInOvershoot = false
    
    // Configurable hooks for testing / dependency injection
    var clamshellReader: () -> Bool
    var displaySleeper: () -> Void
    var wakeTrigger: () -> Void
    var clock: () -> Date
    var inputIdleReader: () -> TimeInterval
    
    public init(
        autoStart: Bool = true,
        dryRun: Bool = false,
        clamshellReader: (() -> Bool)? = nil,
        displaySleeper: (() -> Void)? = nil,
        wakeTrigger: (() -> Void)? = nil,
        clock: (() -> Date)? = nil,
        inputIdleReader: (() -> TimeInterval)? = nil
    ) {
        self.clamshellReader = clamshellReader ?? LidLatchManager.defaultReadHardwareLidFlag
        self.clock = clock ?? { Date() }
        self.inputIdleReader = inputIdleReader ?? LidLatchManager.defaultSecondsSinceLastUserInput

        if dryRun {
            self.displaySleeper = {
                print("[DisplaySleeper] [DRY RUN] Would execute: pmset sleepnow")
                fflush(stdout)
            }
            self.wakeTrigger = {
                print("[DisplaySleeper] [DRY RUN] Would execute: wake display (CGEvent mouseMoved)")
                fflush(stdout)
            }
        } else {
            self.displaySleeper = displaySleeper ?? LidLatchManager.defaultForceDisplaySleep
            self.wakeTrigger = wakeTrigger ?? LidLatchManager.defaultWakeDisplay
        }
        
        if autoStart {
            startMonitoring()
        }
    }
    
    public func startMonitoring() {
        guard pollTimer == nil else { return }
        
        // 1. Poll the hardware registry flag every 10ms (0.01s)
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            self?.checkLidState()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        
        // 2. Monitor for a global keypress to wake the screen back up
        // Note: Requires Accessibility permissions if running entirely in the background
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.handleKeyPress()
        }
        
        NSLog("[DisplaySleeper] Started monitoring lid state and keyboard events.")
        print("[DisplaySleeper] Started monitoring lid state and keyboard events.")
        fflush(stdout)
    }
    
    public func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        NSLog("[DisplaySleeper] Stopped monitoring.")
        print("[DisplaySleeper] Stopped monitoring.")
        fflush(stdout)
    }
    
    public func checkLidState() {
        let lidIsCurrentlyClosed = clamshellReader()
        let now = clock()
        
        // 1. User Input Wake Check:
        // Check if user pressed a key or clicked without needing Accessibility permissions.
        if userIntendsToClose {
            if let latchTime = latchTrippedTime, now.timeIntervalSince(latchTime) > 1.0 {
                let inputIdle = inputIdleReader()
                
                if inputIdle < 0.8 {
                    NSLog("[DisplaySleeper] User input detected via CGEventSource (idle: %.2fs). Releasing latch.", inputIdle)
                    print("[DisplaySleeper] User input detected. Releasing display lock.")
                    fflush(stdout)
                    handleKeyPress()
                    return
                }
            }
        }
        
        // 2. Hardware Sensor Transitions:
        if lidIsCurrentlyClosed && !userIntendsToClose {
            // LATCH TRIPPED: The user closed the lid 1-2 inches, triggering the sensor.
            // Suppress re-latching for 2s after a release (lid passes through sensor zone on opening).
            if let releasedTime = latchReleasedTime, now.timeIntervalSince(releasedTime) < 2.0 {
                return
            }
            userIntendsToClose = true
            latchTrippedTime = now
            lastSleepCallTime = now
            latchReleasedTime = nil
            wasInOvershoot = false
            NSLog("[DisplaySleeper] Lid latch activated. Enforcing system sleep.")
            print("[DisplaySleeper] Lid latch activated. Enforcing system sleep.")
            fflush(stdout)
            displaySleeper()
        } else if !lidIsCurrentlyClosed && userIntendsToClose {
            // OVERSHOOT DETECTED: The lid went completely flush, turning the flag back to 'No'.
            // Enforce true system sleep.
            wasInOvershoot = true
            if lastSleepCallTime == nil || now.timeIntervalSince(lastSleepCallTime!) >= 1.0 {
                lastSleepCallTime = now
                let durationStr: String
                if let latchTime = latchTrippedTime {
                    let ms = now.timeIntervalSince(latchTime) * 1000
                    durationStr = String(format: " (%.0fms in sensor zone)", ms)
                } else {
                    durationStr = ""
                }
                NSLog("[DisplaySleeper] Hardware overshoot detected%@. Enforcing system sleep.", durationStr)
                print("[DisplaySleeper] Hardware overshoot detected\(durationStr). Enforcing system sleep.")
                fflush(stdout)
                displaySleeper()
            }
        } else if lidIsCurrentlyClosed && userIntendsToClose && wasInOvershoot {
            // SENSOR HIT TRUE AFTER OVERSHOOT: The lid was flush closed (overshoot) and is now
            // passing back through the 1-2 inch sensor zone as the user lifts it open!
            userIntendsToClose = false
            wasInOvershoot = false
            latchTrippedTime = nil
            lastSleepCallTime = nil
            latchReleasedTime = now
            NSLog("[DisplaySleeper] Lid opening detected (sensor transitioned to True from overshoot). Releasing display lock.")
            print("[DisplaySleeper] Lid opening detected. Releasing display lock.")
            fflush(stdout)
            wakeTrigger()
        }
    }
    
    public func handleKeyPress() {
        if userIntendsToClose {
            // RESET LATCH: User pressed a key, meaning they want the Mac awake
            userIntendsToClose = false
            wasInOvershoot = false
            latchTrippedTime = nil
            lastSleepCallTime = nil
            latchReleasedTime = clock()
            NSLog("[DisplaySleeper] Keypress detected. Releasing display lock.")
            print("[DisplaySleeper] Keypress detected. Releasing display lock.")
            fflush(stdout)
            wakeTrigger()
        }
    }
    
    // MARK: - Default Hardware & System Calls
    
    public static func defaultReadHardwareLidFlag() -> Bool {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/")
        guard entry != MACH_PORT_NULL else { return false }
        defer { IOObjectRelease(entry) }
        
        if let state = IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            return state
        }
        if let state = IORegistryEntrySearchCFProperty(
            entry,
            kIOServicePlane,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) as? Bool {
            return state
        }
        return false
    }
    
    /// Seconds since the most recent keypress, modifier change, or mouse click.
    /// Uses CGEventSource, which needs no Accessibility permission.
    public static func defaultSecondsSinceLastUserInput() -> TimeInterval {
        let eventTypes: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        return eventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }
    
    public static func defaultForceDisplaySleep() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        do {
            try process.run()
        } catch {
            NSLog("[DisplaySleeper] Failed to execute pmset: %@", error.localizedDescription)
        }
    }
    
    public static func defaultWakeDisplay() {
        // Wake the display naturally by mimicking a tiny trackpad movement
        let source = CGEventSource(stateID: .combinedSessionState)
        let mouseEvent = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: NSEvent.mouseLocation,
            mouseButton: .left
        )
        mouseEvent?.post(tap: .cghidEventTap)
    }
    
    deinit {
        stopMonitoring()
    }
}
