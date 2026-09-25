# Photos Vault. `make` on its own lists what there is.
#
# Release in one command:  make release
# It formats, analyses, tests, archives an obfuscated Release build and
# uploads it to App Store Connect. Xcode never has to be opened — the
# Product ▸ Archive ▸ Distribute dance is what scripts/release-ios.sh does.

FLUTTER := $(shell [ -x .tools/flutter/bin/flutter ] && echo .tools/flutter/bin/flutter || echo flutter)
DART    := $(shell [ -x .tools/flutter/bin/dart ] && echo .tools/flutter/bin/dart || echo dart)

# The paired iPhone, unless you name one: make install DEVICE=<udid>
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/physical/ { for (i = 1; i <= NF; i++) if ($$i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$$/) { print $$i; exit } }')

APP     := build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app
BUDGET  := 33

.DEFAULT_GOAL := help
.PHONY: help bootstrap l10n fmt analyze test check build install install-ios run archive upload release size screenshots clean

help: ## List the targets
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Clone the Flutter SDK into .tools/ (no system install)
	./scripts/bootstrap-flutter.sh

l10n: ## Regenerate AppLocalizations from the .arb files
	$(FLUTTER) gen-l10n

fmt: ## Format lib and test
	$(DART) format lib test

analyze: ## Static analysis
	$(FLUTTER) analyze lib test

test: ## The whole suite
	$(FLUTTER) test

check: fmt analyze test ## Format, analyse, test — the pass before any build

build: ## Release build for a device, obfuscated
	$(FLUTTER) build ios --release --obfuscate --split-debug-info=build/symbols

install: ## Install on the phone in place, keeping its data
	@test -n "$(DEVICE)" || { echo "No device. Plug the iPhone in, or pass DEVICE=<udid>."; exit 1; }
	xcrun devicectl device install app --device $(DEVICE) build/ios/iphoneos/Runner.app

install-ios: build install ## Build and install on the paired iPhone, keeping its data

run: install-ios ## Same as install-ios

archive: ## Archive a Release build without uploading it
	$(FLUTTER) build ipa --release --build-number=$$(date +%Y%m%d%H%M) \
	  --obfuscate --split-debug-info=build/symbols/$$(date +%Y%m%d%H%M)

upload: ## Upload the archive that already exists, without rebuilding
	xcodebuild -exportArchive \
	  -archivePath build/ios/archive/Runner.xcarchive \
	  -exportOptionsPlist ios/ExportOptions.plist \
	  -exportPath build/ios/ipa -allowProvisioningUpdates

release: check ## Test, archive and upload to App Store Connect
	./scripts/release-ios.sh

size: ## Measure the archived app against the 33 MB budget
	@test -d $(APP) || { echo "No archive yet — run 'make archive'."; exit 1; }
	@du -sh $(APP)
	@mb=$$(du -sm $(APP) | cut -f1); \
	  if [ $$mb -gt $(BUDGET) ]; then \
	    echo "over the $(BUDGET) MB budget by $$(($$mb - $(BUDGET))) MB — see CLAUDE.md"; exit 1; \
	  else echo "inside the $(BUDGET) MB budget, $$(($(BUDGET) - $$mb)) MB spare"; fi

screenshots: ## Convert a folder of iPhone shots to the store sizes: make screenshots FROM=~/Desktop/shots
	@test -n "$(FROM)" || { echo "usage: make screenshots FROM=<dir-of-shots>"; exit 1; }
	./scripts/store-screenshots.sh $(FROM)

clean: ## Drop build output
	$(FLUTTER) clean
