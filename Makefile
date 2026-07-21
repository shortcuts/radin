.PHONY: install test lint

install:
	./install.sh

test:
	bats tests/

lint:
	bash -n install.sh
	shellcheck install.sh
	shfmt -w install.sh
	markdownlint --fix '**/*.md' --ignore node_modules
