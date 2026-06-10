APP = Astopos
VERSION = 0.3.0
BUNDLE = $(APP).app
BIN = .build/release/$(APP)
DMG = $(APP)-$(VERSION).dmg

.PHONY: build run app dmg icon clean

build:
	swift build

run:
	swift run

# Regenerate Astopos.icns from the source art (kept out of git; see images/icon.png).
# The compiled .icns IS committed — it's the icon resource the build embeds.
icon:
	@set -e; \
	ICONSET=$$(mktemp -d)/Astopos.iconset; mkdir -p "$$ICONSET"; \
	magick images/icon.png -resize 1024x1024\! "$$ICONSET/master.png"; \
	for s in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
	         "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do \
	  set -- $$s; magick "$$ICONSET/master.png" -resize $$1x$$1 "$$ICONSET/icon_$$2.png"; \
	done; \
	rm "$$ICONSET/master.png"; \
	iconutil -c icns "$$ICONSET" -o Astopos.icns; \
	echo "Built Astopos.icns"

# Assemble a menu-bar .app bundle (LSUIElement) you can drop in /Applications.
app:
	swift build -c release
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp Astopos.icns $(BUNDLE)/Contents/Resources/Astopos.icns
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
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"; \
	lipo -create "$$A/$(APP)" "$$X/$(APP)" -output "$(BUNDLE)/Contents/MacOS/$(APP)"; \
	cp Info.plist "$(BUNDLE)/Contents/Info.plist"; \
	cp Astopos.icns "$(BUNDLE)/Contents/Resources/Astopos.icns"; \
	codesign --force --deep --sign - "$(BUNDLE)"; \
	mkdir dmg-stage; cp -R "$(BUNDLE)" dmg-stage/; ln -s /Applications dmg-stage/Applications; \
	hdiutil create -volname "$(APP) $(VERSION)" -srcfolder dmg-stage -ov -format UDZO "$(DMG)"; \
	rm -rf dmg-stage; \
	echo "Built $(DMG)"; lipo -info "$(BUNDLE)/Contents/MacOS/$(APP)"

clean:
	rm -rf .build $(BUNDLE) $(DMG) dmg-stage
