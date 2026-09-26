import Foundation

class LidLatchManagerTests {
    var sleepCallCount = 0
    var wakeCallCount = 0
    var simulatedClamshellState = false
    var simulatedNow = Date(timeIntervalSinceReferenceDate: 0)
    var simulatedInputIdle: TimeInterval = .infinity
    
    func setUp() {
        sleepCallCount = 0
        wakeCallCount = 0
        simulatedClamshellState = false
        simulatedNow = Date(timeIntervalSinceReferenceDate: 0)
        simulatedInputIdle = .infinity
    }
    
    func advanceTime(by seconds: TimeInterval) {
        simulatedNow = simulatedNow.addingTimeInterval(seconds)
    }
    
    func runAll() {
        print("Running LidLatchManagerTests...")
        testInitialState()
        testLatchTrippedOnLidClose()
        testHardwareOvershootInterception()
        testNormalAwakeStateDoesNothing()
        testLidClosedMaintainedState()
        testKeyPressWakeOverride()
        testKeyPressWhenAlreadyAwake()
        testStopMonitoringAndDeinit()
        testFastCloseCaughtByClamshellMessage()
        testUnrelatedPowerMessageIgnored()
        testDarkWakeResumesEnforcementAfterSettle()
        testLidOpenAfterResumeReleasesViaClamshellMessage()
        testInputDuringResumeHoldReleasesLatch()
        testScreenUnlockReleasesLatch()
        print("All 14 tests passed successfully!")
    }
    
    func createTestManager() -> LidLatchManager {
        return LidLatchManager(
            autoStart: false,
            clamshellReader: { [unowned self] in self.simulatedClamshellState },
            displaySleeper: { [unowned self] in self.sleepCallCount += 1 },
            wakeTrigger: { [unowned self] in self.wakeCallCount += 1 },
            clock: { [unowned self] in self.simulatedNow },
            inputIdleReader: { [unowned self] in self.simulatedInputIdle }
        )
    }
    
    func testInitialState() {
        setUp()
        let manager = createTestManager()
        assert(!manager.userIntendsToClose, "Initial userIntendsToClose must be false")
        assert(sleepCallCount == 0, "No sleep calls initially")
        assert(wakeCallCount == 0, "No wake calls initially")
        print("  ✓ testInitialState passed")
    }
    
    func testLatchTrippedOnLidClose() {
        setUp()
        let manager = createTestManager()
        
        // Simulate user closing lid (sensor reports closed)
        simulatedClamshellState = true
        manager.checkLidState()
        
        assert(manager.userIntendsToClose, "userIntendsToClose must be true after latch trip")
        assert(sleepCallCount == 1, "forceDisplaySleep must be called immediately upon latch trip")
        print("  ✓ testLatchTrippedOnLidClose passed")
    }
    
    func testHardwareOvershootInterception() {
        setUp()
        let manager = createTestManager()
        
        // 1. Trip the latch
        simulatedClamshellState = true
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        assert(sleepCallCount == 1)
        
        // 2. Hardware overshoot: lid closes completely flush, sensor drops to false.
        // Within 1.0s of the latch-trip sleep call, re-sleeping is throttled.
        simulatedClamshellState = false
        manager.checkLidState()
        
        assert(manager.userIntendsToClose, "userIntendsToClose must remain true during overshoot")
        assert(sleepCallCount == 1, "forceDisplaySleep must be paced at 1.0s after the latch-trip call")
        
        // 3. Once 1.0s has passed, the overshoot re-enforces sleep
        advanceTime(by: 1.0)
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        assert(sleepCallCount == 2, "forceDisplaySleep must be called during overshoot to force blank screen")
        
        // 4. Polls within the next 1.0s are throttled
        advanceTime(by: 0.5)
        manager.checkLidState()
        assert(sleepCallCount == 2, "forceDisplaySleep must not be called again within 1.0s")
        
        // 5. Continued overshoot keeps re-enforcing sleep at the 1.0s pace
        advanceTime(by: 0.5)
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        assert(sleepCallCount == 3, "forceDisplaySleep must be called continuously during overshoot")
        print("  ✓ testHardwareOvershootInterception passed")
    }
    
    func testNormalAwakeStateDoesNothing() {
        setUp()
        let manager = createTestManager()
        
        // Lid is open (false) and latch is false
        simulatedClamshellState = false
        manager.checkLidState()
        manager.checkLidState()
        
        assert(!manager.userIntendsToClose, "userIntendsToClose must remain false")
        assert(sleepCallCount == 0, "No sleep calls should be made in normal open state")
        print("  ✓ testNormalAwakeStateDoesNothing passed")
    }
    
    func testLidClosedMaintainedState() {
        setUp()
        let manager = createTestManager()
        
        // 1. Close lid
        simulatedClamshellState = true
        manager.checkLidState()
        assert(sleepCallCount == 1)
        
        // 2. Lid stays closed (true)
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        assert(sleepCallCount == 1, "Should not trigger additional sleep calls if sensor stays true")
        print("  ✓ testLidClosedMaintainedState passed")
    }
    
    func testKeyPressWakeOverride() {
        setUp()
        let manager = createTestManager()
        
        // Put into overshoot latch state
        simulatedClamshellState = true
        manager.checkLidState()
        advanceTime(by: 1.0)
        simulatedClamshellState = false
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        assert(sleepCallCount == 2)
        
        // Keypress intercepted
        manager.handleKeyPress()
        
        assert(!manager.userIntendsToClose, "userIntendsToClose must be reset to false on keypress")
        assert(wakeCallCount == 1, "wakeTrigger must be called on keypress override")
        
        // Next poll should not sleep because latch is now false
        manager.checkLidState()
        assert(sleepCallCount == 2, "Sleep should not be called after keypress override")
        print("  ✓ testKeyPressWakeOverride passed")
    }
    
    func testKeyPressWhenAlreadyAwake() {
        setUp()
        let manager = createTestManager()
        
        manager.handleKeyPress()
        assert(!manager.userIntendsToClose)
        assert(wakeCallCount == 0, "No wake trigger should be sent if not latched")
        print("  ✓ testKeyPressWhenAlreadyAwake passed")
    }
    
    func testStopMonitoringAndDeinit() {
        setUp()
        var manager: LidLatchManager? = createTestManager()
        manager?.startMonitoring()
        manager?.stopMonitoring()
        manager = nil
        assert(manager == nil)
        print("  ✓ testStopMonitoringAndDeinit passed")
    }
    
    func testFastCloseCaughtByClamshellMessage() {
        setUp()
        let manager = createTestManager()
        let closedMessage = LidLatchManager.clamshellStateBit
        
        // Lid slams shut: the sensor blips CLOSED and back to OPEN between two polls,
        // so polling alone only ever reads OPEN.
        simulatedClamshellState = false
        manager.checkLidState()
        assert(!manager.userIntendsToClose)
        
        // The kernel reports both transitions as messages.
        manager.handlePowerMessage(LidLatchManager.clamshellStateChangeMessage, argument: closedMessage)
        assert(manager.userIntendsToClose, "Clamshell CLOSED message must trip the latch")
        assert(sleepCallCount == 1, "forceDisplaySleep must be called on the CLOSED message")
        
        manager.handlePowerMessage(LidLatchManager.clamshellStateChangeMessage, argument: 0)
        assert(manager.userIntendsToClose, "Clamshell OPEN message right after close is an overshoot")
        
        // The poll keeps enforcing sleep through the overshoot.
        advanceTime(by: 1.0)
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        assert(sleepCallCount == 2, "Overshoot must keep enforcing sleep after a message-tripped latch")
        print("  ✓ testFastCloseCaughtByClamshellMessage passed")
    }
    
    func testUnrelatedPowerMessageIgnored() {
        setUp()
        let manager = createTestManager()
        
        manager.handlePowerMessage(0xE000_0280, argument: LidLatchManager.clamshellStateBit) // kIOMessageSystemWillSleep
        assert(!manager.userIntendsToClose, "Non-clamshell power messages must not trip the latch")
        assert(sleepCallCount == 0)
        print("  ✓ testUnrelatedPowerMessageIgnored passed")
    }
    
    /// Latches, goes through overshoot, and "sleeps" for an hour (no readings), then resumes with the sensor OPEN.
    func createManagerResumedFromSleep() -> LidLatchManager {
        let manager = createTestManager()
        simulatedClamshellState = true
        manager.checkLidState()
        simulatedClamshellState = false
        advanceTime(by: 1.0)
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        assert(sleepCallCount == 2)
        
        // System sleeps for an hour; on resume the sensor reads OPEN (lid open, or overshoot)
        advanceTime(by: 3600)
        manager.checkLidState()
        return manager
    }
    
    func testDarkWakeResumesEnforcementAfterSettle() {
        setUp()
        let manager = createManagerResumedFromSleep()
        assert(manager.userIntendsToClose)
        assert(sleepCallCount == 2, "Sleep must not be forced immediately on resume")
        
        // On every wake the kernel re-reports the clamshell state; for a DarkWake it's OPEN.
        manager.handlePowerMessage(LidLatchManager.clamshellStateChangeMessage, argument: 0)
        assert(manager.userIntendsToClose, "A clamshell OPEN message on resume must not release the latch")
        
        // Still held within the settle period.
        advanceTime(by: 4.0)
        manager.checkLidState()
        assert(sleepCallCount == 2, "Sleep must be held during the resume settle period")
        
        // Settle period over: back to enforcing sleep.
        advanceTime(by: 1.5)
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        assert(sleepCallCount == 3, "Sleep must be re-enforced after a DarkWake settle period")
        print("  ✓ testDarkWakeResumesEnforcementAfterSettle passed")
    }
    
    func testLidOpenAfterResumeReleasesViaClamshellMessage() {
        setUp()
        let manager = createManagerResumedFromSleep()
        
        // Lid opened: the poll only ever read OPEN, but the kernel reports the zone pass after resume.
        advanceTime(by: 0.15)
        manager.handlePowerMessage(LidLatchManager.clamshellStateChangeMessage, argument: LidLatchManager.clamshellStateBit)
        assert(!manager.userIntendsToClose, "Clamshell CLOSED after overshoot must release the latch")
        assert(wakeCallCount == 1)
        
        manager.handlePowerMessage(LidLatchManager.clamshellStateChangeMessage, argument: 0)
        advanceTime(by: 6.0)
        manager.checkLidState()
        assert(!manager.userIntendsToClose)
        assert(sleepCallCount == 2, "No sleep calls after the lid-open release")
        print("  ✓ testLidOpenAfterResumeReleasesViaClamshellMessage passed")
    }
    
    func testInputDuringResumeHoldReleasesLatch() {
        setUp()
        let manager = createManagerResumedFromSleep()
        
        // User presses a key within the resume hold
        advanceTime(by: 2.0)
        simulatedInputIdle = 0.1
        manager.checkLidState()
        assert(!manager.userIntendsToClose, "User input during the resume hold must release the latch")
        assert(wakeCallCount == 1)
        assert(sleepCallCount == 2)
        print("  ✓ testInputDuringResumeHoldReleasesLatch passed")
    }
    
    func testScreenUnlockReleasesLatch() {
        setUp()
        let manager = createManagerResumedFromSleep()
        
        manager.handleScreenUnlocked()
        assert(!manager.userIntendsToClose, "Screen unlock must release the latch")
        assert(wakeCallCount == 1)
        
        // Lid is open and reads OPEN: no more sleep calls
        advanceTime(by: 1.0)
        manager.checkLidState()
        assert(sleepCallCount == 2)
        print("  ✓ testScreenUnlockReleasesLatch passed")
    }
}

let suite = LidLatchManagerTests()
suite.runAll()
