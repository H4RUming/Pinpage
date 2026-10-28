.PHONY: project test build release run clean

project:
	xcodegen generate

test:
	cd Packages/PinpageCore && swift test

build: project
	xcodebuild -project Pinpage.xcodeproj -scheme Pinpage -configuration Debug -derivedDataPath build build

release: project
	xcodebuild -project Pinpage.xcodeproj -scheme Pinpage -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build build

run: build
	open build/Build/Products/Debug/Pinpage.app

clean:
	rm -rf build Pinpage.xcodeproj
