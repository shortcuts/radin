.PHONY: install test lint

install:
	./install.sh

install-force:
	./install.sh --force

test:
	bats tests/

SH_FILES = install.sh lib/radin-namespace.sh lib/radin-json.sh lib/radin-backlog.sh lib/radin-state.sh lib/radin-scope.sh lib/radin-doctor.sh lib/radin-uninstall.sh

lint:
	bash -n $(SH_FILES)
	shellcheck $(SH_FILES)
	shfmt -w $(SH_FILES)
	markdownlint --fix '**/*.md' --ignore node_modules
