.PHONY: build release test app install bench clean run

build:
	swift build

release:
	swift build -c release

test:
	swift test

run:
	swift run Nyx

app: release
	scripts/bundle.sh

install: app
	rm -rf /Applications/Nyx.app && cp -R build/Nyx.app /Applications/

bench:
	swift run -c release nyx-bench $(FILE)

clean:
	rm -rf .build build
