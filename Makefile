APP_NAME = DisplaySleeper
APP_BUNDLE = $(APP_NAME).app
BUILD_DIR = .build
SDK_PATH = $(shell xcrun --show-sdk-path)

PLIST_NAME = com.custom.DisplaySleeper.plist
LAUNCH_AGENTS_DIR = $(HOME)/Library/LaunchAgents
INSTALLED_PLIST = $(LAUNCH_AGENTS_DIR)/$(PLIST_NAME)

SWIFTC_FLAGS = -sdk $(SDK_PATH) \
               -module-cache-path $(BUILD_DIR)/module-cache \
               -framework Cocoa \
               -framework IOKit \
               -framework CoreGraphics \
               -framework ApplicationServices

SOURCES = Sources/DisplaySleeper/LidLatchManager.swift \
          Sources/DisplaySleeper/AppDelegate.swift \
          Sources/DisplaySleeper/main.swift

.PHONY: all build test run clean install-daemon uninstall-daemon status-daemon logs

all: build

build: $(APP_BUNDLE)

$(APP_BUNDLE): $(SOURCES) Resources/Info.plist
	@echo "==> Building $(APP_NAME)..."
	@mkdir -p $(BUILD_DIR)/module-cache
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	swiftc $(SWIFTC_FLAGS) -O $(SOURCES) -o $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@echo "==> Signing $(APP_BUNDLE)..."
	codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "==> Built $(APP_BUNDLE) successfully."

install-daemon: build
	@echo "==> Installing LaunchAgent for autostart across reboots..."
	@mkdir -p $(LAUNCH_AGENTS_DIR)
	@mkdir -p $(HOME)/Library/Logs
	cp Resources/$(PLIST_NAME) $(INSTALLED_PLIST)
	-launchctl bootout gui/$$(id -u) $(INSTALLED_PLIST) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(INSTALLED_PLIST)
	@echo "==> DisplaySleeper daemon installed and running."
	@echo "    Menu bar icon is active. Daemon will automatically launch on reboot."

uninstall-daemon:
	@echo "==> Removing DisplaySleeper LaunchAgent..."
	-launchctl bootout gui/$$(id -u) $(INSTALLED_PLIST) 2>/dev/null || true
	rm -f $(INSTALLED_PLIST)
	@echo "==> DisplaySleeper daemon uninstalled."

status-daemon:
	@launchctl print gui/$$(id -u)/com.custom.DisplaySleeper 2>/dev/null | grep -E "state =|pid =" || echo "DisplaySleeper daemon is not running in launchd."

logs:
	tail -n 50 -f $(HOME)/Library/Logs/DisplaySleeper.log

test:
	@echo "==> Running test suite..."
	@mkdir -p $(BUILD_DIR)/module-cache
	swiftc $(SWIFTC_FLAGS) Sources/DisplaySleeper/LidLatchManager.swift Tests/main.swift -o $(BUILD_DIR)/test_runner
	$(BUILD_DIR)/test_runner

run: build
	@echo "==> Launching $(APP_BUNDLE)..."
	open $(APP_BUNDLE)

clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf $(BUILD_DIR) $(APP_BUNDLE)
