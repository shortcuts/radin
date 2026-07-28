.PHONY: install test lint

install:
	./install.sh

install-force:
	./install.sh --force

test:
	bats tests/

lint:
	bash -n install.sh lib/radin-namespace.sh lib/radin-backlog.sh lib/radin-doctor.sh
	shellcheck install.sh lib/radin-namespace.sh lib/radin-backlog.sh lib/radin-doctor.sh
	shfmt -w install.sh lib/radin-namespace.sh lib/radin-backlog.sh lib/radin-doctor.sh
	markdownlint --fix '**/*.md' --ignore node_modules
