.PHONY: install test lint

install:
	./install.sh

test:
	bats tests/

lint:
	bash -n install.sh
	shellcheck install.sh
	shfmt -d install.sh
	markdownlint '**/*.md' --ignore node_modules
