.PHONY: install install-force update test lint bench

install:
	./install.sh

install-force:
	./install.sh --force

update:
	./install.sh --update

test:
	bats tests/

BENCH_N ?= 200
BENCH_DIR ?= /tmp/radin-bench

bench:
	rm -rf $(BENCH_DIR)
	bash tests/helpers/seed-backlog.sh $(BENCH_DIR) $(BENCH_N)
	python3 tests/helpers/bench-tui.py $(BENCH_DIR) $(PWD)/lib/radin-tui.sh 20

SH_FILES = install.sh tests/helpers/seed-backlog.sh bin/radin lib/radin-namespace.sh lib/radin-json.sh lib/radin-backlog.sh lib/radin-tui.sh lib/radin-state.sh lib/radin-scope.sh lib/radin-cbm-hooks.sh lib/radin-cbm-config.sh lib/radin-update.sh lib/radin-doctor.sh lib/radin-uninstall.sh

lint:
	bash -n $(SH_FILES)
	shellcheck $(SH_FILES)
	shfmt -w $(SH_FILES)
	markdownlint --fix '**/*.md' --ignore node_modules
