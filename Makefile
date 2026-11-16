PROJECT := Nook.xcodeproj
SCHEME := Nook
DESTINATION := platform=macOS
DERIVED_DATA_PATH := DerivedData
BUILD_FLAGS := CODE_SIGNING_ALLOWED=NO

# NookPlusServiceAPI generates its Swift client during the build using Apple's
# swift-openapi-generator SwiftPM plugin. Xcode asks a human to trust any
# package that runs code at build time; on the command line that prompt cannot
# be answered, so validation is skipped here.
#
# What is being trusted: Apple's generator, pinned to an exact version in the
# protocol package's manifest, with Package.resolved committed. Opening the
# project in Xcode still shows the prompt once — click "Trust & Enable".
PLUGIN_FLAGS := -skipPackagePluginValidation

.PHONY: build perf-build trace-build clean open legibility legibility-check app-store-screenshots app-store-capture app-store-check-faces macos-signing-secrets

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA_PATH) $(PLUGIN_FLAGS) $(BUILD_FLAGS) build

# Keep DEBUG instrumentation while measuring optimized application code. It
# builds into its own derived data so `make build` (-Onone) never replaces the
# app tools/perf/run.sh launches.
PERF_DERIVED_DATA_PATH := DerivedData-perf

perf-build:
	@set -eu; \
	stamp="$$(tools/perf/build-id.sh)"; \
	plist="$(PERF_DERIVED_DATA_PATH)/Build/Products/Debug/Nook.app/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy -c 'Delete :NookBuildSHA' "$$plist" >/dev/null 2>&1 || true; \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(PERF_DERIVED_DATA_PATH) $(PLUGIN_FLAGS) $(BUILD_FLAGS) SWIFT_OPTIMIZATION_LEVEL=-O build; \
	/usr/libexec/PlistBuddy -c "Add :NookBuildSHA string $$stamp" "$$plist"

# A local Release app with opt-in performance logs and a symptom marker in Help.
# Use the app's Developer ID identity when testing existing bookmarks/Keychain.
TRACE_DERIVED_DATA_PATH := DerivedData-trace
TRACE_SIGN_IDENTITY ?= -

trace-build:
	@set -eu; \
	stamp="$$(tools/perf/build-id.sh)"; \
	app="$(TRACE_DERIVED_DATA_PATH)/Build/Products/Release/Nook.app"; \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination '$(DESTINATION)' -derivedDataPath $(TRACE_DERIVED_DATA_PATH) $(PLUGIN_FLAGS) CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$(TRACE_SIGN_IDENTITY)" CODE_SIGNING_ALLOWED=YES ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp=none SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) NOOK_PERFORMANCE_TRACE' build; \
	/usr/libexec/PlistBuddy -c 'Delete :NookBuildSHA' "$$app/Contents/Info.plist" >/dev/null 2>&1 || true; \
	/usr/libexec/PlistBuddy -c "Add :NookBuildSHA string $$stamp" "$$app/Contents/Info.plist"; \
	codesign --force --sign "$(TRACE_SIGN_IDENTITY)" --timestamp=none --preserve-metadata=identifier,entitlements,requirements,flags "$$app"

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA_PATH) clean

open:
	xed .

# The reader's legibility engine ships as a generated, checked-in asset
# (NookKit/Sources/NookKit/Legibility.html) so that building Nook needs no Rust
# toolchain. Regenerate it only to move the pin in tools/legibility.pin.
legibility:
	tools/build-legibility.sh

# Verifies the checked-in asset was built from the commit the pin names.
legibility-check:
	tools/build-legibility.sh --check

app-store-screenshots:
	marketing/app-store/render.sh

app-store-capture:
	@test -n "$(LOCALE)" -a -n "$(NAME)" || (echo "Usage: make app-store-capture LOCALE=ko NAME=01-library" && exit 64)
	marketing/app-store/capture-simulator.sh "$(LOCALE)" "$(NAME)" "$(or $(SIMULATOR),iPad Air 13-inch (M4))"

app-store-check-faces:
	xcrun swift marketing/app-store/check-faces.swift $$(find marketing/app-store/captures marketing/app-store/output -name '*.png' | sort)

# One-time setup for a signed, notarized Mac build in CI. Prompts for a
# certificate and an App Store Connect key and stores five repository secrets.
# Without them a tag release fails; only a manual run falls back to ad-hoc.
macos-signing-secrets:
	tools/macos-signing-secrets.sh
