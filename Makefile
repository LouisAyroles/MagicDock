.PHONY: app build clean format lint test

app:
	./scripts/build-app.sh

build:
	swift build

test:
	swift test

format:
	swift format --in-place --recursive Sources Tests Package.swift

lint:
	swift format lint --recursive --strict Sources Tests Package.swift

clean:
	swift package clean
	rm -rf dist
