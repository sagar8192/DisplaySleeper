import Foundation

class LidLatchManagerTests {
    var sleepCallCount = 0
    var wakeCallCount = 0
    var simulatedClamshellState = false
    
    func setUp() {
        sleepCallCount = 0
        wakeCallCount = 0
        simulatedClamshellState = false
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
        print("All 8 tests passed successfully!")
    }
    
    func createTestManager() -> LidLatchManager {
        return LidLatchManager(
            autoStart: false,
            clamshellReader: { [unowned self] in self.simulatedClamshellState },
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
        assert(sleepCallCount == 2, "forceDisplaySleep must be called during overshoot to force blank screen")
        
        // 3. Next poll during overshoot
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
        simulatedClamshellState = false
        manager.checkLidState()
        assert(manager.userIntendsToClose)
        
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
}

let suite = LidLatchManagerTests()
suite.runAll()
