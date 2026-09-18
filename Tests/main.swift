import Foundation

class LidLatchManagerTests {
    var sleepCallCount = 0
    var wakeCallCount = 0
    var simulatedClamshellState = false
    var simulatedWakeReason = ""
    
    func setUp() {
        sleepCallCount = 0
        wakeCallCount = 0
        simulatedClamshellState = false
        simulatedWakeReason = ""
    }
    
    func runAll() {
        print("Running LidLatchManagerTests...")
        testInitialState()
        testLatchTrippedOnLidClose()
        testHardwareOvershootInterception()
        testNormalAwakeStateDoesNothing()
        testLidClosedMaintainedState()
        testBagBumpSingleKeyDoesNotReleaseLatch()
        testEmergencyTripleKeyPressWakeOverride()
        testSMCLidWakeReasonReleasesLatch()
        testLidSweepReleasesLatch()
        testKeyPressWhenAlreadyAwake()
        testStopMonitoringAndDeinit()
        print("All 11 tests passed successfully!")
    }
    
    func createTestManager() -> LidLatchManager {
        return LidLatchManager(
            autoStart: false,
            clamshellReader: { [unowned self] in self.simulatedClamshellState },
            wakeReasonReader: { [unowned self] in self.simulatedWakeReason },
            displaySleeper: { [unowned self] in self.sleepCallCount += 1 },
            wakeTrigger: { [unowned self] in self.wakeCallCount += 1 }
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
        
        // 2. Hardware overshoot: lid closes completely flush, sensor drops to false
        simulatedClamshellState = false
        manager.checkLidState()
        
        assert(manager.userIntendsToClose, "userIntendsToClose must remain true during overshoot")
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
    
    func testBagBumpSingleKeyDoesNotReleaseLatch() {
        setUp()
        let manager = createTestManager()
        
        // 1. Enter overshoot (flush closed in bag)
        simulatedClamshellState = true
        manager.checkLidState()
        simulatedClamshellState = false
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        
        // 2. Accidental keypress in bag
        manager.handleKeyPress()
        
        // Latch MUST remain true to prevent screen turning on in bag!
        assert(manager.userIntendsToClose, "Single accidental keypress in bag must NOT release the latch")
        assert(wakeCallCount == 0, "Wake trigger must not be called on bag bump")
        print("  ✓ testBagBumpSingleKeyDoesNotReleaseLatch passed")
    }
    
    func testEmergencyTripleKeyPressWakeOverride() {
        setUp()
        let manager = createTestManager()
        
        // 1. Enter overshoot
        simulatedClamshellState = true
        manager.checkLidState()
        simulatedClamshellState = false
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        
        // 2. Three rapid keypresses (deliberate user override)
        manager.handleKeyPress()
        manager.handleKeyPress()
        manager.handleKeyPress()
        
        assert(!manager.userIntendsToClose, "Triple keypress must disarm the latch")
        assert(wakeCallCount == 1, "Wake trigger must be called after triple keypress")
        print("  ✓ testEmergencyTripleKeyPressWakeOverride passed")
    }
    
    func testSMCLidWakeReasonReleasesLatch() {
        setUp()
        let manager = createTestManager()
        
        // 1. Enter overshoot
        simulatedClamshellState = true
        manager.checkLidState()
        simulatedClamshellState = false
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        
        // 2. System wakes with SMC reporting lid open
        simulatedWakeReason = "smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty"
        manager.checkLidState()
        
        assert(!manager.userIntendsToClose, "SMC lid wake reason must release the latch")
        assert(wakeCallCount == 1, "Wake trigger must be called on SMC lid wake")
        print("  ✓ testSMCLidWakeReasonReleasesLatch passed")
    }
    
    func testLidSweepReleasesLatch() {
        setUp()
        let manager = createTestManager()
        
        // 1. Enter overshoot
        simulatedClamshellState = true
        manager.checkLidState()
        simulatedClamshellState = false
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        
        // 2. User lifts lid: sensor sweeps through 1-2" (reports true)
        simulatedClamshellState = true
        manager.checkLidState()
        
        assert(!manager.userIntendsToClose, "Lid sweep through 1-2\" must release the latch")
        assert(wakeCallCount == 1, "Wake trigger must be called on lid sweep")
        print("  ✓ testLidSweepReleasesLatch passed")
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
}

let suite = LidLatchManagerTests()
suite.runAll()
