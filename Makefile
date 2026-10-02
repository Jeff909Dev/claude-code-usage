.PHONY: build test app run install cli release clean

build:
	swift build

test:
	swift test

app:
	./scripts/bundle.sh

run: app
	open "build/Claude Usage.app"

install: app
	rm -rf "/Applications/Claude Usage.app"
	ditto "build/Claude Usage.app" "/Applications/Claude Usage.app"

cli:
	swift run claude-usage-cli $(ARGS)

release:
	./scripts/release.sh

clean:
	rm -rf .build build
