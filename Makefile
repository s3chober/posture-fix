APP_NAME := Posture Focus
CONFIG   := release
APP_ARCHIVE = $(CURDIR)/dist/$(APP_NAME).zip

.PHONY: build run install uninstall clean

build:
	./build.sh $(CONFIG)

run: install
	open -a "$(APP_NAME)"

install: build
	@echo "› Installing to /Applications/$(APP_NAME).app"
	rm -rf "/Applications/$(APP_NAME).app"
	ditto -x -k "$(APP_ARCHIVE)" /Applications
	@echo '✓ Installed. Launch from Spotlight or: open -a "$(APP_NAME)"'

uninstall:
	rm -rf "/Applications/$(APP_NAME).app"
	@echo "✓ Removed /Applications/$(APP_NAME).app"

clean:
	rm -rf .build
