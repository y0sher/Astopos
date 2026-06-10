APP = Astopos
VERSION = 0.2.0
BUNDLE = $(APP).app
BIN = .build/release/$(APP)
DMG = $(APP)-$(VERSION).dmg

.PHONY: build run app dmg clean

build:
	swift build

run:
	swift run

# Assemble a menu-bar .app bundle (LSUIElement) you can drop in /Applications.
app:
	swift build -c release
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --deep --sign - $(BUNDLE) || true
	@echo "Built $(BUNDLE) — open it, or: cp -R $(BUNDLE) /Applications/"

# Build a universal (arm64 + x86_64), ad-hoc-signed .app and package it into a
# drag-to-Applications DMG for distribution. Builds each arch separately and lipo-joins them
# (a single `--arch a --arch b` invocation needs Xcode's xcbuild, which CommandLineTools lacks).
dmg:
	@set -e; \
	swift build -c release --arch arm64; \
	swift build -c release --arch x86_64; \
	A=$$(swift build -c release --arch arm64 --show-bin-path); \
	X=$$(swift build -c release --arch x86_64 --show-bin-path); \
	rm -rf "$(BUNDLE)" "$(DMG)" dmg-stage; \
	mkdir -p "$(BUNDLE)/Contents/MacOS"; \
	lipo -create "$$A/$(APP)" "$$X/$(APP)" -output "$(BUNDLE)/Contents/MacOS/$(APP)"; \
	cp Info.plist "$(BUNDLE)/Contents/Info.plist"; \
	codesign --force --deep --sign - "$(BUNDLE)"; \
	mkdir dmg-stage; cp -R "$(BUNDLE)" dmg-stage/; ln -s /Applications dmg-stage/Applications; \
	hdiutil create -volname "$(APP) $(VERSION)" -srcfolder dmg-stage -ov -format UDZO "$(DMG)"; \
	rm -rf dmg-stage; \
	echo "Built $(DMG)"; lipo -info "$(BUNDLE)/Contents/MacOS/$(APP)"

clean:
	rm -rf .build $(BUNDLE) $(DMG) dmg-stage
