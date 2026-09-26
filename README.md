# 🌙 DisplaySleeper

A small macOS menu bar app that makes a MacBook with a **faulty lid sensor** actually sleep when you close it, so it doesn't wake up, heat up, or drain its battery in your bag.

## 🔍 The Problem

On some MacBooks the lid's magnet sensor is misaligned:

- At **1–2 inches open**, the sensor reports the lid as **closed**.
- When the lid is **fully shut**, the magnet overshoots and the sensor reports it as **open** again.

So macOS thinks you reopened the lid: the screen turns on inside the closed laptop, and it won't stay asleep.

## 💡 How It Works

1. **Closing:** the moment the sensor reports "closed" (at 1–2"), DisplaySleeper remembers that you're closing the lid and puts the Mac to sleep (`pmset sleepnow`). It catches even very fast closes.
2. **Fully shut:** when the sensor falsely flips back to "open", DisplaySleeper ignores it and keeps putting the Mac to sleep.
3. **Opening:** as you lift the lid, it passes back through the 1–2" zone, and DisplaySleeper lets the Mac wake normally.
4. **Any other wake:** DisplaySleeper waits 5 seconds. If you open the lid, unlock, or press a key in that time, it lets the Mac stay awake. Otherwise it's a background or accidental wake, and the Mac goes back to sleep.

## ⚡ Install

1. **Set the paths.** `Resources/com.custom.DisplaySleeper.plist` has three hardcoded paths under `/Users/sagar/...` (the app and its log file). Edit them to match your username and where you cloned this repository.
2. **Build and start it** from the repository folder:
   ```bash
   make install-daemon
   ```
   This builds `DisplaySleeper.app` in the repository folder and starts it now and at every login. The app runs from that folder, so don't move or delete it.
3. **Check it's running:** a 💻 laptop icon appears in the menu bar, or run `make status-daemon`.

Requires macOS 12 or later and Xcode command line tools (`xcode-select --install`).

## 🖥️ Using It

The menu bar icon offers **Sleep System Now** and **Quit**. Quitting stops DisplaySleeper until your next login. To start it again right away:

```bash
launchctl kickstart gui/$(id -u)/com.custom.DisplaySleeper
```

No special permissions are needed. You may see an Accessibility permission prompt: granting it is optional.

## 🤔 What to Expect

- **The screen flickers for a moment after closing or peeking.** macOS wakes the Mac before any app can react, and DisplaySleeper puts it back to sleep within about a second. This happens when:
  - **You peek under the lid.** Lifting it a crack wakes the Mac, but the lid doesn't reach the 1–2" zone, so it goes straight back to sleep.
  - **You touch or press the closed laptop.** Because the faulty sensor tells macOS the lid is open, macOS leaves the built-in trackpad switched on under the closed lid. Pressing the lid shut, or gripping or moving the laptop, can register as trackpad touches, and each one briefly wakes the Mac. It settles once you put the laptop down.
- **A firm press on the closed lid could register as a trackpad click.** DisplaySleeper treats a click as you using the Mac and lets it stay awake. If your Mac is ever warm in your bag, check the logs (below) for `User input detected`.
- **Brief background wakes every ~15 minutes are normal.** Apple wakes the Mac without the screen for maintenance (Find My, network, etc.), usually for about 2 seconds.

## 📊 Checking It Worked

DisplaySleeper's log (`make logs`) is quiet while the Mac sleeps. A typical night looks like this (trimmed):

```log
23:52:14 Lid latch activated. Enforcing system sleep.
00:02:15 Resumed after 536s while latched. Holding sleep enforcement for 5s.
00:02:20 No lid opening, unlock or user input after wake. Re-enforcing system sleep.
   ... the same pair every ~15 minutes (Apple's background wakes) ...
10:28:45 Lid opening detected (sensor transitioned to True from overshoot). Releasing display lock.
```

Apple's own record of every sleep and wake, with the reason:

```bash
pmset -g log | grep -E " (Sleep|Wake|DarkWake) "
```

While the lid is closed you should mostly see `Sleep` and `DarkWake` (background) lines. A `Wake` line is a full wake with the screen on; its reason follows `due to` (`lid` when you open it).

## 📋 Commands

| Command | What it does |
| :--- | :--- |
| `make install-daemon` | Build, install and start (also starts at login) |
| `make uninstall-daemon` | Stop and remove |
| `make status-daemon` | Check whether it's running |
| `make logs` | Follow the log (`~/Library/Logs/DisplaySleeper.log`) |
| `make build` / `make run` | Build the app / build and launch it directly |
| `make test` | Run the test suite |
| `make clean` | Remove build output |

## 📄 License

MIT. Feel free to use, modify, and share with anyone else stuck with a faulty MacBook lid sensor!
