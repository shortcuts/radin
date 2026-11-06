.PHONY: install update build run test golden verify-hosts bench-tui screenshot lint check gen diagrams serve-diagrams clean

install:
	./install.sh

update:
	./install.sh --update

# The TUI and the cbm-config JSON helper are the two compiled files radin
# ships; the two mocks are test-only.
build: lib/radin-tui lib/radin-cbm-json tests/helpers/pty-run tests/helpers/mock

lib/radin-tui: lib/radin-tui.c
	cc -O2 -o $@ $<

lib/radin-cbm-json: lib/radin-cbm-json.c
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
# mktemp -d, and bats' own -j costs more in bookkeeping than it wins here. The
# slowest files go first so no worker starts one last; tui is four shards.
test: build
# Every temp repo a test builds is deleted in teardown, so git's fsync is pure
# latency here: it cost ~0.1s per test that runs `git init`.
# A test that follows a cc symlink once overwrote the real settings.json, so
# bats runs without CLAUDE_CONFIG_DIR and the run fails if a real file changes.
	@before=$$(scripts/real-setup-sum.sh); \
		GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsync GIT_CONFIG_VALUE_0=none \
		env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u XDG_CONFIG_HOME -u OPENCODE_CONFIG -u OPENCODE sh -c '{ ls tests/install*.bats tests/backlog.bats tests/tui-*.bats; ls tests/*.bats | grep -v -e install -e backlog -e tui-; } | xargs -P $$(getconf _NPROCESSORS_ONLN) -n1 bats; exit $$?'; \
		status=$$?; \
		after=$$(scripts/real-setup-sum.sh); \
		if [ "$$before" != "$$after" ]; then \
			echo "make test changed the real setup:"; \
			printf "before:\n%s\nafter:\n%s\n" "$$before" "$$after"; status=1; \
		fi; \
		exit $$status

# Rewrites the golden sums after an intended change to the Claude render.
golden:
	env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u XDG_CONFIG_HOME -u OPENCODE_CONFIG GOLDEN_UPDATE=1 bats --filter 'golden render of the Claude install' tests/install*.bats

# Opt-in: drives the real opencode and codex CLIs without a model call. Needs a C
# compiler, about a minute per host, and npm for VERIFY_ARGS=--install-missing.
VERIFY_ARGS ?=
verify-hosts:
	@before=$$(scripts/real-setup-sum.sh); \
		env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u XDG_CONFIG_HOME -u OPENCODE_CONFIG scripts/verify-hosts.sh $(VERIFY_ARGS); \
		status=$$?; \
		after=$$(scripts/real-setup-sum.sh); \
		if [ "$$before" != "$$after" ]; then \
			echo "make verify-hosts changed the real setup:"; \
			printf "before:\n%s\nafter:\n%s\n" "$$before" "$$after"; status=1; \
		fi; \
		exit $$status

# Key-to-frame latency on a seeded 42-task backlog; see tests/bench-tui.sh.
bench-tui:
	@tests/bench-tui.sh

# Renders docs/img/tui.svg from the real TUI; see scripts/screenshot-tui.sh.
screenshot:
	@scripts/screenshot-tui.sh

SH_FILES = tests/bench-tui.sh scripts/screenshot-tui.sh scripts/shipped.sh install.sh bin/radin lib/radin-namespace.sh lib/radin-json.sh lib/radin-migrate.sh lib/radin-backlog.sh lib/radin-state.sh lib/radin-scope.sh lib/radin-prompt.sh lib/radin-cbm-hooks.sh lib/radin-cbm-config.sh lib/radin-update.sh lib/radin-doctor.sh lib/radin-stats.sh lib/radin-uninstall.sh scripts/check-prose.sh scripts/real-setup-sum.sh scripts/golden-render.sh scripts/render-host.sh scripts/verify-hosts.sh

clean:
	rm -f lib/radin-tui lib/radin-cbm-json tests/helpers/pty-run tests/helpers/mock

lint:
	bash -n $(SH_FILES)
	shellcheck $(SH_FILES)
	shfmt -w $(SH_FILES)
	markdownlint --fix '**/*.md' --ignore node_modules --ignore CHANGELOG.md

check:
	bash -n $(SH_FILES)
	shellcheck $(SH_FILES)
	shfmt -d $(SH_FILES)
	markdownlint '**/*.md' --ignore node_modules --ignore CHANGELOG.md
	scripts/check-prose.sh
	scripts/shipped.sh check

gen:
	scripts/shipped.sh gen

# Pinned so a pele release never reshuffles the committed SVGs. node_modules is
# removed after the run: radin ships no JS and tracks no lockfile.
diagrams:
	npm i --no-save --no-package-lock pele@1.6.0
	node docs/agents/lifecycle/render.mjs
	rm -rf node_modules

# Reads the .mmd files on every request: edit one, refresh the browser.
serve-diagrams:
	npm i --no-save --no-package-lock pele@1.6.0
	trap 'rm -rf node_modules' EXIT; node docs/agents/lifecycle/serve.mjs
