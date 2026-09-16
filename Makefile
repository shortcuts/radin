.PHONY: install install-force update build run test lint clean

install:
	./install.sh

install-force:
	./install.sh --force

update:
	./install.sh --update

# The TUI is the only compiled file radin ships; the two mocks are test-only.
build: lib/radin-tui tests/helpers/pty-run tests/helpers/mock

lib/radin-tui: lib/radin-tui.c
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
# mktemp -d, and bats' own -j costs more in bookkeeping than it wins here.
test: build
# Every temp repo a test builds is deleted in teardown, so git's fsync is pure
# latency here: it cost ~0.1s per test that runs `git init`.
	@GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsync GIT_CONFIG_VALUE_0=none \
		sh -c 'bats -j 4 tests/install.bats & \
			ls tests/*.bats | grep -v install | xargs -P 6 -n1 bats; wait'

SH_FILES = install.sh bin/radin lib/radin-namespace.sh lib/radin-json.sh lib/radin-backlog.sh lib/radin-state.sh lib/radin-scope.sh lib/radin-cbm-hooks.sh lib/radin-cbm-config.sh lib/radin-update.sh lib/radin-doctor.sh lib/radin-uninstall.sh

clean:
	rm -f lib/radin-tui tests/helpers/pty-run tests/helpers/mock

lint:
	bash -n $(SH_FILES)
	shellcheck $(SH_FILES)
	shfmt -w $(SH_FILES)
	markdownlint --fix '**/*.md' --ignore node_modules
