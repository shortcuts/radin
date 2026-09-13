.PHONY: install install-force update test lint

install:
	./install.sh

install-force:
	./install.sh --force

update:
	./install.sh --update

test:
	bats tests/

SH_FILES = install.sh bin/radin lib/radin-namespace.sh lib/radin-json.sh lib/radin-backlog.sh lib/radin-state.sh lib/radin-scope.sh lib/radin-cbm-hooks.sh lib/radin-cbm-config.sh lib/radin-update.sh lib/radin-doctor.sh lib/radin-uninstall.sh

lint:
	bash -n $(SH_FILES)
	shellcheck $(SH_FILES)
	shfmt -w $(SH_FILES)
	markdownlint --fix '**/*.md' --ignore node_modules
