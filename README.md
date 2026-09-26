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
     OR Unlock / Key / Click         (Flush closed in bag)
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
1. **Latch Tripped**: When `AppleClamshellState` flips to `True` at 1–2", DisplaySleeper sets `userIntendsToClose = true` and invokes `/usr/bin/pmset sleepnow`. The sensor is watched two ways: a 10ms poll, and the kernel's clamshell-change notifications from `IOPMrootDomain`. The notifications report every transition, so even a fast close that flips the sensor for only a few milliseconds is caught.
2. **Overshoot Interception**: When the lid reaches flush closed and the sensor falsely drops back to `False`, DisplaySleeper catches the overshoot and enforces `pmset sleepnow` (paced at 1.0s) until the system settles into deep sleep. If the overshoot itself wakes the Mac right after closing, it's put straight back to sleep.
3. **True System Sleep**: The CPU halts, RAM refreshes in low-power mode, and the Mac sleeps cold (saving battery and eliminating heat).
4. **Waking Back Up**: A flush-closed lid and an open lid both read `False`, so after any wake DisplaySleeper holds off for **5 seconds** and releases the latch only on a sign that you really opened it:
   - **Automatic Lid-Lift**: As you open the lid, the magnet passes back through the 1–2" sweet spot (`False → True`). DisplaySleeper sees this (via the poll or the kernel's notification, which arrives just after the Mac wakes) and **immediately releases the lock**. A 2-second cooldown prevents re-latching while the lid swings open.
   - **Unlock or User Input**: Unlocking the screen (Touch ID or password), pressing a key or clicking also releases the latch. Key and click detection uses `CGEventSource`, so no special permissions are required.
   - **Otherwise**: Apple's background maintenance wakes (DarkWake), and wakes caused by bumping or peeking under the lid, never pass through the sensor zone, so the Mac goes back to sleep after the 5 seconds.

---

## ✨ Features

- 💻 **Menu Bar Icon (`NSStatusItem`)**: Clean laptop icon in your top menu bar with one-click **Status**, manual **Sleep System Now**, and **Quit**.
- 💤 **True System Sleep (`pmset sleepnow`)**: Completely halts the CPU and powers down the display—just like a brand-new MacBook lid.
- ⚡ **Fast-Close Detection**: Kernel clamshell notifications catch lid closes too quick for polling to see.
- 🔁 **DarkWake Friendly**: Gracefully allows Apple's native ~15-minute maintenance cycles (Find My beacons, network keep-alives) to run for ~5 seconds before returning to deep sleep.
- 🚀 **Autostart Daemon (`launchd`)**: Automatically launches on reboot and login via a native macOS LaunchAgent.
- 🛡️ **Zero-Permission Fallback**: Uses CoreGraphics `CGEventSource` event timing to detect keypresses and trackpad clicks even if Accessibility permissions have not been granted.

---

## ⚡ Quick Start

### 1. Point the LaunchAgent at Your Checkout
`Resources/com.custom.DisplaySleeper.plist` contains absolute paths for the app executable and the log file (`/Users/sagar/...`). Either clone the repository to `~/Applications/Mac Apps/DisplaySleeper` under the `sagar` account, or edit those three paths to match your username and checkout location.

### 2. Build and Install the Daemon
From the repository folder, run:

```bash
make install-daemon
```

This compiles and ad-hoc signs `DisplaySleeper.app` inside the repository folder, copies the LaunchAgent plist to `~/Library/LaunchAgents/`, and starts the daemon immediately. The app runs from the repository folder, so don't move or delete it.

### 3. Verify It's Running
Look at your macOS top menu bar (near Wi-Fi and the clock)—you will see a **laptop icon** (💻).

You can also check the daemon status in Terminal:
```bash
make status-daemon
```

### 4. Test the Lid
1. **Close the lid**: As soon as it closes, the laptop will enter deep system sleep.
2. **Open the lid**: The screen will wake back up automatically to your lock screen. (If needed, unlock or tap any key within 5 seconds.)

Lifting the lid just a crack to peek may briefly light the screen: macOS wakes the Mac before DisplaySleeper can react. Because the lid never reaches the sensor zone, DisplaySleeper keeps the latch and puts it back to sleep within about a second.

---

## 📋 Make Commands Cheatsheet

| Command | Description |
| :--- | :--- |
| `make install-daemon` | Compiles app, sets up LaunchAgent, and starts daemon on login/boot |
| `make status-daemon` | Checks if the background daemon is currently active in `launchd` |
| `make logs` | Streams live application logs (`tail -f ~/Library/Logs/DisplaySleeper.log`) |
| `make uninstall-daemon` | Stops and uninstalls the LaunchAgent from macOS |
| `make build` | Compiles `DisplaySleeper.app` bundle locally |
| `make run` | Builds and launches the app directly (without `launchd`) |
| `make test` | Runs the automated state-machine test suite |
| `make clean` | Removes build artifacts (`.build/` and `DisplaySleeper.app`) |

---

## 🖥️ Menu Bar Controls & Relaunching

- **Check Status**: Click the laptop icon in the menu bar to verify that the daemon is active.
- **Manual Sleep**: Select **Sleep System Now** to test sleep without closing the lid.
- **Quit**: Select **Quit DisplaySleeper** to stop the daemon.
- **Relaunching**: Quitting stops the daemon until your next login. To start it again right away, run:
  ```bash
  launchctl kickstart gui/$(id -u)/com.custom.DisplaySleeper
  ```
  or double-click `DisplaySleeper.app` in the repository folder.

---

## 📊 How to Verify Your Mac Was Truly Asleep

Want proof that your Mac stayed asleep in your bag for hours?

### Method 1: Check DisplaySleeper Logs (`make logs`)
```log
19:14:10 [DisplaySleeper] Lid latch activated. Enforcing system sleep.
19:14:11 [DisplaySleeper] Hardware overshoot detected (1021ms since latch). Enforcing system sleep.
          💤 (Gap: the Mac is asleep)
19:30:04 [DisplaySleeper] Resumed after 907s while latched. Holding sleep enforcement for 5s.
19:30:09 [DisplaySleeper] No lid opening, unlock or user input after wake. Re-enforcing system sleep.
          💤 (Gap: a DarkWake came and went)
21:05:17 [DisplaySleeper] Resumed after 727s while latched. Holding sleep enforcement for 5s.
21:05:18 [DisplaySleeper] Lid opening detected (sensor transitioned to True from overshoot). Releasing display lock.
```
Because DisplaySleeper runs a timer on the main thread, **gaps with zero logs prove the CPU was halted in hardware sleep.** A `Resumed … / Re-enforcing` pair roughly every 15 minutes is Apple's DarkWake maintenance cycle. During some DarkWakes, `Hardware overshoot detected` repeats every second for up to ~45s; that's harmless, as macOS finishes its maintenance before sleeping again.

### Method 2: macOS Native Power Management Log
Run this command in Terminal to see every sleep and wake with its cause:
```bash
pmset -g log | grep -E " (Sleep|Wake|DarkWake) "
```
With the lid closed you should only see `Sleep` and `DarkWake` entries. A plain `Wake` line shows its cause after `due to`; opening the lid shows up as `lid`.

---

## 🛠️ Project Structure

```
DisplaySleeper/
├── Sources/
│   └── DisplaySleeper/
│       ├── LidLatchManager.swift   # State machine, lid polling & clamshell notifications, sleep trigger
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
├── CLAUDE.md                       # Notes for AI coding assistants working on this repo
└── README.md                       # Project documentation
```

---

## 🔒 Permissions & Security

- **User Privileges**: DisplaySleeper runs entirely under standard user permissions. It never asks for `sudo` or root access.
- **Accessibility (Optional)**: For optimal global key monitoring, you can grant Accessibility permissions under **System Settings > Privacy & Security > Accessibility**. If omitted, DisplaySleeper automatically falls back to CoreGraphics input detection with zero permissions required.

---

## 📄 License

MIT License. Feel free to use, modify, and distribute to anyone dealing with faulty MacBook lid sensors!
