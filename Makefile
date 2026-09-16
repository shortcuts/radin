.PHONY: install install-force update test lint bench tui

install:
	./install.sh

install-force:
	./install.sh --force

update:
	./install.sh --update

# One bats per file, run concurrently: every file isolates its state under
# mktemp -d, and bats' own -j costs more in bookkeeping than it wins here.
# The TUI is the one compiled file; the tests build it too, this is for `make tui`.
tui: lib/radin-tui
lib/radin-tui: lib/radin-tui.c
	cc -O2 -o $@ $<

test: lib/radin-tui
# Every temp repo a test builds is deleted in teardown, so git's fsync is pure
# latency here: it cost ~0.1s per test that runs `git init`.
	@GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsync GIT_CONFIG_VALUE_0=none \
		sh -c 'bats -j 4 tests/install.bats & \
			ls tests/*.bats | grep -v install | xargs -P 6 -n1 bats; wait'

BENCH_N ?= 200
BENCH_DIR ?= /tmp/radin-bench

bench:
	rm -rf $(BENCH_DIR)
	bash tests/helpers/seed-backlog.sh $(BENCH_DIR) $(BENCH_N)
	python3 tests/helpers/bench-tui.py $(BENCH_DIR) $(PWD)/lib/radin-tui 20

SH_FILES = install.sh tests/helpers/seed-backlog.sh bin/radin lib/radin-namespace.sh lib/radin-json.sh lib/radin-backlog.sh lib/radin-state.sh lib/radin-scope.sh lib/radin-cbm-hooks.sh lib/radin-cbm-config.sh lib/radin-update.sh lib/radin-doctor.sh lib/radin-uninstall.sh

lint:
	bash -n $(SH_FILES)
	shellcheck $(SH_FILES)
	shfmt -w $(SH_FILES)
	markdownlint --fix '**/*.md' --ignore node_modules
