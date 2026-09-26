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
    
    // Wake handling: after resuming from sleep while latched, overshoot readings don't
    // force sleep until this time, giving a lid opening, unlock or keypress the chance to release the latch.
    private var enforcementHoldUntil: Date?
    private var lastReadingTime: Date?
    private var unlockObserver: NSObjectProtocol?
    
    /// A gap this long between sensor readings means the process was suspended, i.e. the system slept.
    static let resumeGapThreshold: TimeInterval = 5.0
    /// After a resume, how long to hold off re-enforcing sleep.
    static let resumeSettlePeriod: TimeInterval = 5.0
    
    // Clamshell change notifications (catch transitions shorter than the poll interval)
    private var rootDomainService: io_service_t = 0
    private var clamshellNotifyPort: IONotificationPortRef?
    private var clamshellNotifier: io_object_t = 0
    private var pollActivity: NSObjectProtocol?
    
    // From IOKit/pwr_mgt/IOPM.h; the kIOPMMessageClamshellStateChange macro isn't imported into Swift.
    static let clamshellStateChangeMessage: UInt32 = 0xE003_4100
    static let clamshellStateBit = 1 << 0 // kClamshellStateBit
    
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
        
        // Keep App Nap from coalescing the 10ms poll timer. Idle system sleep stays allowed.
        pollActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Polling lid sensor for brief clamshell transitions"
        )
        
        // Subscribe to kernel clamshell messages, which report every transition,
        // including ones that flip back before the next poll.
        startClamshellNotifications()
        
        // A screen unlock means the user has the lid open.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenUnlocked()
        }
        
        // 2. Monitor for a global keypress to wake the screen back up
        // Note: Requires Accessibility permissions if running entirely in the background
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.handleKeyPress()
        }
        
        log("Started monitoring lid state and keyboard events.")
    }
    
    public func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        
        if let activity = pollActivity {
            ProcessInfo.processInfo.endActivity(activity)
            pollActivity = nil
        }
        if clamshellNotifier != 0 {
            IOObjectRelease(clamshellNotifier)
            clamshellNotifier = 0
        }
        if let port = clamshellNotifyPort {
            IONotificationPortDestroy(port)
            clamshellNotifyPort = nil
        }
        if rootDomainService != 0 {
            IOObjectRelease(rootDomainService)
            rootDomainService = 0
        }
        
        if let observer = unlockObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            unlockObserver = nil
        }
        
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        NSLog("[DisplaySleeper] Stopped monitoring.")
        print("[DisplaySleeper] Stopped monitoring.")
        fflush(stdout)
    }
    
    private func startClamshellNotifications() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            log("Could not find IOPMrootDomain; relying on polling only.")
            return
        }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            IOObjectRelease(service)
            log("Could not create IOKit notification port; relying on polling only.")
            return
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
            .commonModes
        )
        
        var notifier: io_object_t = 0
        let result = IOServiceAddInterestNotification(
            port,
            service,
            "IOGeneralInterest",
            { refcon, _, messageType, messageArgument in
                guard let refcon = refcon else { return }
                let manager = Unmanaged<LidLatchManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handlePowerMessage(messageType, argument: Int(bitPattern: messageArgument))
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &notifier
        )
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            IOObjectRelease(service)
            log(String(format: "IOServiceAddInterestNotification failed (0x%x); relying on polling only.", result))
            return
        }
        
        rootDomainService = service
        clamshellNotifyPort = port
        clamshellNotifier = notifier
        log("Subscribed to clamshell state change notifications.")
    }
    
    /// Handles an IOPMrootDomain interest message. The kernel sends one message per
    /// clamshell transition, so a fast close that flips back before the next poll is still seen.
    public func handlePowerMessage(_ messageType: UInt32, argument: Int) {
        guard messageType == LidLatchManager.clamshellStateChangeMessage else { return }
        let closed = (argument & LidLatchManager.clamshellStateBit) != 0
        processLidReading(closed)
    }
    
    public func checkLidState() {
        processLidReading(clamshellReader())
    }
    
    /// Runs the latch state machine on one sensor reading, from either the poll or a clamshell message.
    func processLidReading(_ lidIsCurrentlyClosed: Bool) {
        let now = clock()
        
        // 0. Resume Detection:
        // Readings arrive every 10ms while awake, so a long gap means we just resumed from sleep.
        // When the lid is opened, the Mac can wake before or after the lid clears the sensor zone;
        // the kernel's queued clamshell CLOSED message for the zone pass may arrive shortly after
        // resume. Briefly hold off enforcing sleep so that message, an unlock, or a keypress can
        // release the latch. DarkWakes only ever report OPEN, so they're re-slept after the hold.
        // Don't extend the hold on a full wake: the overshoot itself can cause one with the lid shut.
        if userIntendsToClose, let lastReading = lastReadingTime,
           now.timeIntervalSince(lastReading) > LidLatchManager.resumeGapThreshold {
            enforcementHoldUntil = now.addingTimeInterval(LidLatchManager.resumeSettlePeriod)
            log(String(format: "Resumed after %.0fs while latched. Holding sleep enforcement for %.0fs.",
                       now.timeIntervalSince(lastReading), LidLatchManager.resumeSettlePeriod))
        }
        lastReadingTime = now
        
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
            enforcementHoldUntil = nil
            NSLog("[DisplaySleeper] Lid latch activated. Enforcing system sleep.")
            print("[DisplaySleeper] Lid latch activated. Enforcing system sleep.")
            fflush(stdout)
            displaySleeper()
        } else if !lidIsCurrentlyClosed && userIntendsToClose {
            // OVERSHOOT DETECTED: The lid went completely flush, turning the flag back to 'No'.
            // Enforce true system sleep.
            wasInOvershoot = true
            if let holdUntil = enforcementHoldUntil {
                if now < holdUntil {
                    return
                }
                enforcementHoldUntil = nil
                log("No lid opening, unlock or user input after wake. Re-enforcing system sleep.")
                lastSleepCallTime = nil
            }
            if lastSleepCallTime == nil || now.timeIntervalSince(lastSleepCallTime!) >= 1.0 {
                lastSleepCallTime = now
                let durationStr: String
                if let latchTime = latchTrippedTime {
                    let ms = now.timeIntervalSince(latchTime) * 1000
                    durationStr = String(format: " (%.0fms since latch)", ms)
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
            releaseLatch(reason: "Lid opening detected (sensor transitioned to True from overshoot).")
        }
    }
    
    public func handleKeyPress() {
        // RESET LATCH: User pressed a key, meaning they want the Mac awake
        releaseLatch(reason: "Keypress detected.")
    }
    
    public func handleScreenUnlocked() {
        releaseLatch(reason: "Screen unlocked.")
    }
    
    private func releaseLatch(reason: String) {
        guard userIntendsToClose else { return }
        userIntendsToClose = false
        wasInOvershoot = false
        latchTrippedTime = nil
        lastSleepCallTime = nil
        enforcementHoldUntil = nil
        latchReleasedTime = clock()
        log("\(reason) Releasing display lock.")
        wakeTrigger()
    }
    
    private func log(_ message: String) {
        NSLog("[DisplaySleeper] %@", message)
        print("[DisplaySleeper] \(message)")
        fflush(stdout)
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
