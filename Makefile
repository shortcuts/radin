.PHONY: install update run test golden verify-hosts real-setup-sum bench-tui screenshot lint check diagrams serve-diagrams clean

install:
	cargo run -q -- install

update:
	cargo run -q -- install --update

# Runs the TUI against this repo's own backlog, straight from the build tree.
run:
	cargo run -q

# A test that follows a cc symlink once overwrote the real settings.json, so
# cargo test runs without CLAUDE_CONFIG_DIR and the run fails if a real file changes.
test:
	@before=$$($(MAKE) -s real-setup-sum); \
		env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u XDG_CONFIG_HOME -u OPENCODE_CONFIG cargo test; \
		status=$$?; \
		after=$$($(MAKE) -s real-setup-sum); \
		if [ "$$before" != "$$after" ]; then \
			echo "make test changed the real setup:"; \
			printf "before:\n%s\nafter:\n%s\n" "$$before" "$$after"; status=1; \
		fi; \
		exit $$status

# One checksum line per real device-setup file, or "absent".
real-setup-sum:
	@set -- "$$HOME/.claude/settings.json" "$$HOME/.config/.claude/settings.json" "$$HOME/.claude.json" \
		"$${CODEX_HOME:-$$HOME/.codex}/AGENTS.md" "$${CODEX_HOME:-$$HOME/.codex}/hooks.json" "$${CODEX_HOME:-$$HOME/.codex}/config.toml" \
		"$${XDG_CONFIG_HOME:-$$HOME/.config}/opencode/AGENTS.md" "$${XDG_CONFIG_HOME:-$$HOME/.config}/opencode/opencode.json" \
		"$$HOME/.radin/manifest.json"; \
		[ -z "$$OPENCODE_CONFIG" ] || set -- "$$@" "$$OPENCODE_CONFIG"; \
		[ -z "$$CLAUDE_CONFIG_DIR" ] || set -- "$$@" "$$CLAUDE_CONFIG_DIR/settings.json"; \
		for f; do \
			if [ -f "$$f" ]; then echo "$$f $$(cksum <"$$f")"; else echo "$$f absent"; fi; \
		done

# Rewrites the golden sums after an intended change to the Claude render.
golden:
	env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u XDG_CONFIG_HOME -u OPENCODE_CONFIG GOLDEN_UPDATE=1 cargo test --test golden_render

# Opt-in: drives the real opencode and codex CLIs without a model call, about a
# minute per host. VERIFY_ARGS=--install-missing installs a missing CLI with npm.
VERIFY_ARGS ?=
verify-hosts:
	@before=$$($(MAKE) -s real-setup-sum); \
		case "$(VERIFY_ARGS)" in *--install-missing*) VERIFY_INSTALL_MISSING=1; export VERIFY_INSTALL_MISSING ;; esac; \
		env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u XDG_CONFIG_HOME -u OPENCODE_CONFIG cargo test --test verify_hosts -- --ignored --nocapture; \
		status=$$?; \
		after=$$($(MAKE) -s real-setup-sum); \
		if [ "$$before" != "$$after" ]; then \
			echo "make verify-hosts changed the real setup:"; \
			printf "before:\n%s\nafter:\n%s\n" "$$before" "$$after"; status=1; \
		fi; \
		exit $$status

# Key-to-frame latency on a seeded 42-task backlog; see tests/tui_bench.rs.
bench-tui:
	@cargo test --release --test tui_bench -- --ignored --nocapture

# Renders docs/img/tui.svg from the real TUI on a seeded demo backlog, so the README
# screenshot never shows a screen the code no longer draws. The xterm package is
# pinned and removed after the run: radin tracks no JS dependency.
screenshot:
	@set -e; work=$$(mktemp -d); trap 'rm -rf "$$work" node_modules' EXIT; \
		RADIN_SCREENSHOT_RAW="$$work/screen" cargo test -q --test tui_pty screenshot_dump -- --ignored >/dev/null; \
		npm i --no-save --no-package-lock @xterm/headless@5.5.0 >/dev/null; \
		node scripts/tui-svg.mjs "$$work/screen" docs/img/tui.svg 150 26

SH_FILES = install.sh

clean:
	cargo clean

lint:
	sh -n $(SH_FILES)
	shellcheck $(SH_FILES)
	shfmt -w $(SH_FILES)
	cargo fmt
	cargo clippy --all-targets -- -D warnings
	markdownlint --fix '**/*.md' --ignore node_modules --ignore CHANGELOG.md

check:
	sh -n $(SH_FILES)
	shellcheck $(SH_FILES)
	shfmt -d $(SH_FILES)
	cargo fmt --check
	cargo clippy --all-targets -- -D warnings
	markdownlint '**/*.md' --ignore node_modules --ignore CHANGELOG.md
	cargo test --test lints --test shipped

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
