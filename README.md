# 🌙 DisplaySleeper

**DisplaySleeper** is a lightweight macOS menu bar daemon written in Swift that fixes the infamous **MacBook broken lid sensor overshoot bug**. It uses a custom state-machine latch to ensure your Mac goes into true, cold system sleep when closed—preventing it from waking up, overheating, or draining battery inside your bag.

---

## 🔍 The Problem

Due to a faulty hinge or misaligned Hall effect sensor on certain MacBooks:
1. When you lower the lid to about **1–2 inches open**, the magnet aligns with the sensor, and the macOS `AppleClamshellState` register flips to **`Yes`** (Closed).
2. When closed **completely flush**, the magnet overshoots the physical sensor. The register falsely flips back to **`No`** (Open).
3. macOS thinks you opened the lid and immediately:
   - Wakes the internal display inside the closed chassis.
   - Refuses to enter system sleep.
   - Heats up your laptop and drains the battery while stored in your backpack.

---

## 💡 The Solution: State Machine Latch

DisplaySleeper runs silently in your menu bar (`LSUIElement = true`) and acts as a software latch (`userIntendsToClose`):

```
                      [Lid Lowered to 1–2"]
                       Sensor flips: True
              ┌─────────────────────────────────┐
              │                                 │
              ▼                                 │
      ┌───────────────┐                ┌────────────────┐
      │     AWAKE     │                │  LATCH TRIPPED │
      │ userIntends   │                │ userIntends    │
      │ ToClose=false │                │ ToClose=true   │
      └───────────────┘                └────────────────┘
              ▲                                 │
              │                                 │
     [Lid Lifted Open]               [Hardware Overshoot]
     Sensor hits 1-2" (True)           Sensor flips: False
     OR Keypress / Click             (Flush closed in bag)
              │                                 ▼
              │                        ┌────────────────┐
              │                        │  SYSTEM SLEEP  │
              │                        │ /usr/bin/pmset │
              │                        │    sleepnow    │
              │                        └────────────────┘
              │                                 │
              └─────────────────────────────────┘
```

### State Machine Lifecycle:
1. **Latch Tripped**: When `AppleClamshellState` momentarily flips to `True` at 1–2", DisplaySleeper sets `userIntendsToClose = true` and invokes `/usr/bin/pmset sleepnow`.
2. **Overshoot Interception**: When the lid reaches flush closed and the sensor falsely drops back to `False`, DisplaySleeper catches the overshoot and enforces `pmset sleepnow` (paced at 1.0s) until the system settles into deep sleep.
3. **True System Sleep**: The CPU halts, RAM refreshes in low-power mode, and the Mac sleeps cold (saving battery and eliminating heat).
4. **Dual-Channel Wake**:
   - **Automatic Lid-Lift**: As you open the lid, the magnet passes back through the 1–2" sweet spot (`False → True`). DisplaySleeper detects this upward motion and **immediately releases the lock**. A 2-second cooldown prevents re-latching while the lid swings open.
   - **User Input Override**: If you open the lid quickly past the sensor zone, tapping any key or clicking the trackpad instantly releases the latch via low-level `CGEventSource` detection (no special permissions required).

---

## ✨ Features

- 💻 **Menu Bar Icon (`NSStatusItem`)**: Clean laptop icon in your top menu bar with one-click **Status**, manual **Sleep System Now**, and **Quit**.
- 💤 **True System Sleep (`pmset sleepnow`)**: Completely halts the CPU and powers down the display—just like a brand-new MacBook lid.
- 🔁 **DarkWake Friendly**: Gracefully allows Apple's native ~17-minute maintenance cycles (Find My beacons, network keep-alives) to run for ~5 seconds before returning to deep sleep.
- 🚀 **Autostart Daemon (`launchd`)**: Automatically launches on reboot and login via a native macOS LaunchAgent.
- 🎯 **Double-Click from Applications**: Symlinked into `~/Applications/DisplaySleeper.app` so you can launch it from Finder or Spotlight at any time.
- 🛡️ **Zero-Permission Fallback**: Uses CoreGraphics `CGEventSource` event timing to detect keypresses and trackpad clicks even if Accessibility permissions have not been granted.

---

## ⚡ Quick Start

### 1. Build and Install the Daemon
Clone the repository and run:

```bash
make install-daemon
```

This compiles the Swift application bundle, creates `~/Applications/DisplaySleeper.app`, installs the LaunchAgent plist, and starts the daemon immediately.

### 2. Verify It's Running
Look at your macOS top menu bar (near Wi-Fi and the clock)—you will see a **laptop icon** (💻).

You can also check the daemon status in Terminal:
```bash
make status-daemon
```

### 3. Test the Lid
1. **Close the lid**: As soon as it closes, the laptop will enter deep system sleep.
2. **Open the lid**: The screen will wake back up automatically to your lock screen. (If needed, tap any key or click the trackpad).

---

## 📋 Make Commands Cheatsheet

| Command | Description |
| :--- | :--- |
| `make install-daemon` | Compiles app, sets up LaunchAgent, and starts daemon on login/boot |
| `make status-daemon` | Checks if the background daemon is currently active in `launchd` |
| `make logs` | Streams live application logs (`tail -f ~/Library/Logs/DisplaySleeper.log`) |
| `make uninstall-daemon` | Stops and uninstalls the LaunchAgent from macOS |
| `make build` | Compiles `DisplaySleeper.app` bundle locally |
| `make test` | Runs the automated state-machine test suite |
| `make clean` | Removes build artifacts (`.build/` and `DisplaySleeper.app`) |

---

## 🖥️ Menu Bar Controls & Relaunching

- **Check Status**: Click the laptop icon in the menu bar to verify that the daemon is active.
- **Manual Sleep**: Select **Sleep System Now** to test sleep without closing the lid.
- **Quit**: Select **Quit DisplaySleeper** to stop the daemon.
- **Relaunching**: If you quit the app, simply open your **Applications** folder (`~/Applications` or Finder $\to$ Applications) and double-click **DisplaySleeper**.

---

## 📊 How to Verify Your Mac Was Truly Asleep

Want proof that your Mac stayed asleep in your bag for hours?

### Method 1: Check DisplaySleeper Logs (`make logs`)
```log
10:59:31 [DisplaySleeper] Sleeping now...
          💤 (Notice the multi-hour timestamp gap with ZERO logs)
12:32:29 [DisplaySleeper] Lid opening detected. Releasing display lock.
```
Because DisplaySleeper runs a timer on the main thread, **zero logs during the gap proves the CPU was completely halted in hardware sleep.**

### Method 2: macOS Native Power Management Log
Run this command in Terminal to see Apple's internal power logs:
```bash
pmset -g stats
```
You will see cumulative sleep counts and confirmation of hardware sleep cycles.

---

## 🛠️ Project Structure

```
DisplaySleeper/
├── Sources/
│   └── DisplaySleeper/
│       ├── LidLatchManager.swift   # State machine, IORegistry polling, sleep trigger
│       ├── AppDelegate.swift       # Menu bar icon, AppKit lifecycle, permissions
│       └── main.swift              # AppKit entry point
├── Resources/
│   ├── Info.plist                  # LSUIElement = true (background menu bar agent)
│   └── com.custom.DisplaySleeper.plist # LaunchAgent autostart configuration
├── Tests/
│   └── main.swift                  # Automated unit tests for all state transitions
├── Scripts/
│   ├── build.sh                    # Build and code-signing script
│   └── run_tests.sh                # Test runner script
├── Makefile                        # Build, install, status, and log automation
└── README.md                       # Project documentation
```

---

## 🔒 Permissions & Security

- **User Privileges**: DisplaySleeper runs entirely under standard user permissions. It never asks for `sudo` or root access.
- **Accessibility (Optional)**: For optimal global key monitoring, you can grant Accessibility permissions under **System Settings > Privacy & Security > Accessibility**. If omitted, DisplaySleeper automatically falls back to CoreGraphics input detection with zero permissions required.

---

## 📄 License

MIT License. Feel free to use, modify, and distribute to anyone dealing with faulty MacBook lid sensors!
