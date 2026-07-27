.PHONY: install test lint

install:
	./install.sh

install-force:
	./install.sh --force

test:
	bats tests/

lint:
	bash -n install.sh lib/radin-namespace.sh lib/radin-backlog.sh
	shellcheck install.sh lib/radin-namespace.sh lib/radin-backlog.sh
	shfmt -w install.sh lib/radin-namespace.sh lib/radin-backlog.sh
	markdownlint --fix '**/*.md' --ignore node_modules
