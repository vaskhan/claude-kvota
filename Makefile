APP      = Kvota
BUNDLE   = $(APP).app
IDENT    = ru.khanin.kvota
PLIST    = $(HOME)/Library/LaunchAgents/$(IDENT).plist
UID     := $(shell id -u)

.PHONY: build bundle install uninstall clean run

build:
	swiftc -O -target arm64-apple-macos12 -o $(APP)-arm64 main.swift -framework AppKit
	swiftc -O -target x86_64-apple-macos12 -o $(APP)-x64 main.swift -framework AppKit
	lipo -create -output $(APP) $(APP)-arm64 $(APP)-x64
	rm -f $(APP)-arm64 $(APP)-x64

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(APP) $(BUNDLE)/Contents/MacOS/
	sed -e 's/__IDENT__/$(IDENT)/g' -e 's/__APP__/$(APP)/g' Info.plist.in > $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)

# Order matters: stop the running instance BEFORE replacing its binary —
# overwriting a running signed executable in place gets it SIGKILLed on
# Apple Silicon (invalidated code-signature pages).
install: bundle
	-launchctl bootout gui/$(UID)/$(IDENT) 2>/dev/null
	rm -rf /Applications/$(BUNDLE)
	cp -R $(BUNDLE) /Applications/
	sed -e 's/__IDENT__/$(IDENT)/g' -e 's/__APP__/$(APP)/g' launchagent.plist.in > $(PLIST)
	launchctl bootstrap gui/$(UID) $(PLIST)
	@echo "$(APP) installed and running. It will start automatically at login."

uninstall:
	-launchctl bootout gui/$(UID)/$(IDENT) 2>/dev/null
	rm -f $(PLIST)
	rm -rf /Applications/$(BUNDLE)
	@echo "$(APP) removed."

run: bundle
	./$(BUNDLE)/Contents/MacOS/$(APP)

clean:
	rm -rf $(APP) $(APP)-arm64 $(APP)-x64 $(BUNDLE)
