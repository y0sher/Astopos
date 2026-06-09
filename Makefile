APP = Astopos
BUNDLE = $(APP).app
BIN = .build/release/$(APP)

.PHONY: build run app clean

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

clean:
	rm -rf .build $(BUNDLE)
