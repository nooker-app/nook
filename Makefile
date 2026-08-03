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

.PHONY: build clean open app-store-screenshots app-store-capture app-store-check-faces

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA_PATH) $(PLUGIN_FLAGS) $(BUILD_FLAGS) build

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA_PATH) clean

open:
	xed .

app-store-screenshots:
	marketing/app-store/render.sh

app-store-capture:
	@test -n "$(LOCALE)" -a -n "$(NAME)" || (echo "Usage: make app-store-capture LOCALE=ko NAME=01-library" && exit 64)
	marketing/app-store/capture-simulator.sh "$(LOCALE)" "$(NAME)" "$(or $(SIMULATOR),iPad Air 13-inch (M4))"

app-store-check-faces:
	xcrun swift marketing/app-store/check-faces.swift $$(find marketing/app-store/captures marketing/app-store/output -name '*.png' | sort)
