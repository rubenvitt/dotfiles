# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

r-tools is a collection of bash utility scripts for macOS, part of a larger dotfiles repository (`~/.dotfiles`). Each tool is a standalone executable bash script. The main `r-tools` script acts as a dispatcher that auto-discovers other tools in the directory.

## Architecture

- **r-tools** — Interactive tool launcher/dispatcher. Discovers executables in its directory, extracts descriptions from comments, provides help and a TUI picker via `gum`.
- **pw** — Secure password generator with concealed macOS clipboard integration (NSPasteboard with ConcealedType), auto-clear timeout, and character requirement enforcement.
- **rnd** — Random string generator supporting hex, base64, and alphanumeric encodings. Copies to clipboard via `pbcopy`.
- **photobackup** — Complete, year-sorted backup of the iCloud photo library to an external drive. Wraps `osxphotos export` with `--directory "{created.year}"`, `--download-missing --use-photokit` (streams the iCloud-only originals — most of the library when "Optimize Mac Storage" is on), and `--update` for resumable incremental runs. Adds a `caffeinate` wrapper, a background disk-space watchdog that cleanly SIGINTs the export if the boot disk runs low, and timestamped logs/report on the target drive. Design: `docs/2026-07-23-photobackup-design.md`.
- **ccp** — Claude Code profile switcher. Maps three profiles (`personal`/`work`/`innoq`) to isolated `CLAUDE_CONFIG_DIR`s, symlinks shared workflow config (`skills`, `plugins`, `agents`, `commands`, `hooks`, `CLAUDE.md`, plus `settings.json` for personal↔work), generates an INNOQ-gateway `settings.json`, and tracks the active profile in `~/.claude-active-profile`. Companion fish functions live in `~/.dotfiles/fish/functions/`: the `claude` wrapper follows the active profile, and `claude-personal`/`claude-work`/`claude-innoq` launch a specific one. Two claude processes in the same config dir corrupt `.claude.json`, so each profile gets its own dir and the launchers hold a `.ccp.lock`. Design: `docs/2026-07-14-ccp-design.md`.

### Adding New Tools

Drop an executable bash script into the root directory. The dispatcher discovers it automatically. Use the comment format `# toolname - Description` near the top for auto-extracted descriptions. Provide a `usage()` function with a heredoc for `--help` output.

## Conventions

- All scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`
- `gum` (TUI library) is an optional dependency — scripts degrade gracefully without it
- macOS-specific: clipboard via `pbcopy`/`osascript`, AppleScript JavaScript bridge for secure clipboard ops
- Sensitive values (passwords) are passed via environment variables to subprocesses, never as command arguments
- Help is accessible via `-h`, `--help`, or through the dispatcher (`r-tools <toolname>`)

## Dependencies

- **Required**: bash, openssl, `/dev/urandom`, macOS CLI tools (`osascript`, `pbcopy`, `sed`, `tr`, `grep`, `awk`)
- **Optional**: `gum` (`brew install gum`) for interactive TUI modes

## No Build/Test/Lint

Pure shell scripts — no compilation, no test framework, no CI. Scripts can be validated with `shellcheck`.
