.PHONY: install test lint

install:
	./install.sh

install-force:
	./install.sh --force

test:
	bats tests/

lint:
	bash -n install.sh lib/radin-namespace.sh
	shellcheck install.sh lib/radin-namespace.sh
	shfmt -w install.sh lib/radin-namespace.sh
	markdownlint --fix '**/*.md' --ignore node_modules
