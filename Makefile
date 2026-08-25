# mcastsyslog — build, run and test the macOS app.
#
# The Xcode project is generated from project.yml rather than checked in, so
# `make` regenerates it whenever project.yml is newer.

PROJECT    := MCastSyslog.xcodeproj
SCHEME     := MCastSyslog
CONFIG     ?= Release
DERIVED    := build
APP        := $(DERIVED)/Build/Products/$(CONFIG)/MCastSyslog.app
SIM        := $(DERIVED)/Build/Products/$(CONFIG)/stormsim

XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
	-derivedDataPath $(DERIVED) CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
	CODE_SIGNING_ALLOWED=YES

.PHONY: all app run test sim clean project icon

all: app

project: $(PROJECT)

$(PROJECT): project.yml
	@command -v xcodegen >/dev/null || { echo "xcodegen not found — brew install xcodegen"; exit 1; }
	xcodegen generate --spec project.yml

app: $(PROJECT)
	$(XCB) build
	@echo "built $(APP)"

# Launch the app. macOS will ask once for local network access; the group is
# never joined until that is granted.
run: app
	open $(APP)

# Unit tests. Debug configuration, because the test bundle loads the app binary.
test: $(PROJECT)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
		test

# Synthetic traffic, for working on the viewer without a fleet to watch.
sim: app
	$(SIM)

# Redraw the app icon. The .icns is committed, but it is generated from
# Tools/make-icon.swift rather than from a drawing program, so changing it is
# an edit to a file that can be read and reviewed.
icon:
	swift Tools/make-icon.swift Resources
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

clean:
	rm -rf $(DERIVED) $(PROJECT)
