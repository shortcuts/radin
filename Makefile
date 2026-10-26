.PHONY: install update build run test bench-tui lint check gen diagrams serve-diagrams clean

install:
	./install.sh

update:
	./install.sh --update

# The TUI and the cbm-config JSON helper are the two compiled files radin
# ships; the two mocks are test-only.
build: lib/radin-tui lib/radin-cbm-json tests/helpers/pty-run tests/helpers/mock

lib/radin-tui: lib/radin-tui.c
	cc -O2 -o $@ $<

lib/radin-cbm-json: lib/radin-cbm-json.c
	cc -O2 -o $@ $<

tests/helpers/pty-run: tests/helpers/pty-run.c
	cc -O1 -o $@ $<

tests/helpers/mock: tests/helpers/mock.c
	cc -O1 -o $@ $<

# Runs the TUI against this repo's own backlog, straight from the build tree --
# no install needed: it finds radin-backlog.sh next to the binary.
run: lib/radin-tui
	./lib/radin-tui

# One bats per file, run concurrently: every file isolates its state under
# mktemp -d, and bats' own -j costs more in bookkeeping than it wins here. The
# slowest files go first so no worker starts one last; tui is four shards.
test: build
# Every temp repo a test builds is deleted in teardown, so git's fsync is pure
# latency here: it cost ~0.1s per test that runs `git init`.
	@GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsync GIT_CONFIG_VALUE_0=none \
		sh -c 'bats -j 4 tests/install.bats & install=$$!; \
			{ ls tests/backlog.bats tests/tui-*.bats; ls tests/*.bats | grep -v -e install -e backlog -e tui-; } | xargs -P 6 -n1 bats; status=$$?; \
			wait $$install || status=1; exit $$status'

# Key-to-frame latency on a seeded 42-task backlog; see tests/bench-tui.sh.
bench-tui:
	@tests/bench-tui.sh

SH_FILES = tests/bench-tui.sh scripts/shipped.sh install.sh bin/radin lib/radin-namespace.sh lib/radin-json.sh lib/radin-backlog.sh lib/radin-state.sh lib/radin-scope.sh lib/radin-prompt.sh lib/radin-cbm-hooks.sh lib/radin-cbm-config.sh lib/radin-update.sh lib/radin-doctor.sh lib/radin-stats.sh lib/radin-uninstall.sh scripts/check-prose.sh

clean:
	rm -f lib/radin-tui lib/radin-cbm-json tests/helpers/pty-run tests/helpers/mock

lint:
	bash -n $(SH_FILES)
	shellcheck $(SH_FILES)
	shfmt -w $(SH_FILES)
	markdownlint --fix '**/*.md' --ignore node_modules

check:
	bash -n $(SH_FILES)
	shellcheck $(SH_FILES)
	shfmt -d $(SH_FILES)
	markdownlint '**/*.md' --ignore node_modules
	scripts/check-prose.sh
	scripts/shipped.sh check

gen:
	scripts/shipped.sh gen

# Pinned so a pele release never reshuffles the committed SVGs. node_modules is
# removed after the run: radin ships no JS and tracks no lockfile.
diagrams:
	npm i --no-save --no-package-lock pele@1.6.0
	node docs/lifecycle/render.mjs
	rm -rf node_modules

# Reads the .mmd files on every request: edit one, refresh the browser.
serve-diagrams:
	npm i --no-save --no-package-lock pele@1.6.0
	trap 'rm -rf node_modules' EXIT; node docs/lifecycle/serve.mjs
