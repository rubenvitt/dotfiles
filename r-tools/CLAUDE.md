# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

r-tools is a collection of bash utility scripts for macOS, part of a larger dotfiles repository (`~/.dotfiles`). Each tool is a standalone executable bash script. The main `r-tools` script acts as a dispatcher that auto-discovers other tools in the directory.

## Architecture

- **r-tools** — Interactive tool launcher/dispatcher. Discovers executables in its directory, extracts descriptions from comments, provides help and a TUI picker via `gum`.
- **pw** — Secure password generator with concealed macOS clipboard integration (NSPasteboard with ConcealedType), auto-clear timeout, and character requirement enforcement.
- **rnd** — Random string generator supporting hex, base64, and alphanumeric encodings. Copies to clipboard via `pbcopy`.
- **photobackup** — Complete, year-sorted backup of the iCloud photo library to an external drive. Wraps `osxphotos export` with `--directory "{created.year}"`, `--download-missing --use-photokit` (streams the iCloud-only originals — most of the library when "Optimize Mac Storage" is on), and `--update` for resumable incremental runs. Adds a `caffeinate` wrapper, a background disk-space watchdog that cleanly SIGINTs the export if the boot disk runs low, and timestamped logs/report on the target drive. Design: `docs/2026-07-23-photobackup-design.md`.
- **ccp** — Claude Code profile switcher. Maps four profiles (`personal`/`work`/`innoq`/`dev`) to separate `CLAUDE_CONFIG_DIR`s, symlinks shared workflow config (`skills`, `plugins`, `agents`, `commands`, `hooks`, `CLAUDE.md`, plus `settings.json` for personal↔work), generates an INNOQ-gateway `settings.json`, and tracks the active profile in `~/.claude-active-profile`. `dev` is the exception to isolation: it shares everything with `~/.claude` except the login — every non-dotfile entry is symlinked except `DEV_PRIVATE_ITEMS` (daemon/jobs/scheduled-tasks, org and MCP-auth caches, backups), and `mcpServers`/`projects`/UI prefs are copied one-way from `~/.claude/.claude.json` into dev's own `.claude.json` (which keeps `oauthAccount`). `_ccp_launch` runs `ccp sync dev` on every dev start. Companion fish functions live in `~/.dotfiles/fish/functions/`: the `claude` wrapper follows the active profile, and `claude-personal`/`claude-work`/`claude-innoq`/`claude-dev` launch a specific one. Two claude processes in the same config dir corrupt `.claude.json`, so each profile gets its own dir and the launchers hold a `.ccp.lock`. Design: `docs/2026-07-14-ccp-design.md`.

- **sbar** — Lädt die Bar (mbar, Nachfolger von SketchyBar; Anmeldeobjekt `dev.rubeen.mbar` aus `/Applications/mbar.app`, `mbar` und `sketchybar` aus `mbar.app/Contents/Resources/bin` über `/etc/paths.d/mbar`) neu und prüft, dass die Config wirklich durchlief. `--reload` meldet nichts: bricht die Config ab, läuft die Bar mit Werkseinstellungen (Höhe 25, keine Items) weiter. Die Lua-Config läuft unter mbar im Daemon selbst, „gesund“ heißt deshalb: `mbar --query bar` liefert Items; ein Fehlversuch wird einmal wiederholt. `sbar status` zeigt Daemon-PID, Items, Event-Provider, Systemlast und die letzten Warnungen aus `~/Library/Logs/mbar.log`; `sbar restart` startet den Prozess per `launchctl kickstart -k` neu (nötig für `launchctl setenv`-Variablen und nach einem neuen mbar-Binary).
- **apager** — Nimmt den Webhook entgegen, den aPager PRO bei einem Einsatzalarm vom Handy absetzt, und zeigt ihn in einem Dialog. **HTTPS ist Pflicht:** iOS App Transport Security lässt `http://` gar nicht erst zu (`NSURLErrorDomain Code=-1022`), deshalb steht `tailscale serve --bg --https=443 http://127.0.0.1:<port>` als Haustür davor — echtes `*.ts.net`-Zertifikat, nur Tailnet, **nie Funnel**. Das Backend muss Loopback sein: auf die eigene Tailnet-Adresse zu proxen läuft zurück durch den Tailscale-Stack und blockiert (gemessen: Loopback 200 in 25 ms, eigene Tailnet-Adresse Timeout nach 20 s). Der Listener (`apager-listener.py`, unter launchd) bindet deshalb ausschliesslich an `127.0.0.1`, nimmt nur Loopback-Quellen an, prüft ein Zufallstoken im Pfad, protokolliert den Rohrequest und startet erst dann die Anzeige. `apager status` prüft die Kette bis zum Ende mit einer echten HTTPS-Anfrage an `/healthz`, die der Listener spurlos mit 204 beantwortet — sonst zählte jede Statusabfrage als abgewiesener Alarm. Ein Zweitalarm ersetzt den offenen Dialog durch einen, der beide zeigt. Bewusste Abgrenzung: kein Ton, keine Benachrichtigung, kein Wecken — der Mac ist Anzeige, alarmiert wird über das Handy. Design: `docs/2026-09-10-apager-design.md`.
- **diskwatch** — Hält die Platte frei, die parallele Agent-Builds binnen Stunden füllen (gemessen bis ~80 GB/h). Ein LaunchAgent (`dev.rubeen.diskwatch`, `StartInterval` 60) ruft `diskwatch check` auf; unter `DISKWATCH_THRESHOLD_GB` (Standard 50) löscht er ausschließlich cargo-Build-Artefakte: Targets in den Session-Scratchpads unter `/private/tmp/claude-501`, `~/.cache/cargo-target/debug`, `~/.cache/cargo-target-*` und `target/` in Worktrees. Scratchpad-Targets heißen beliebig, deshalb wird über `CACHEDIR.TAG` gesucht — und zusätzlich über `<target>/<profil>/.fingerprint`, weil cargo ein mitten im Build gelöschtes Target ohne `CACHEDIR.TAG` neu anlegt. Läuft unter launchd mit `/bin/bash` 3.2 und minimalem PATH, deshalb `/usr/bin/find` (das interaktive `find` ist ein `bfs`-Alias). Warum launchd: ein Watcher in einer Claude-Session stirbt mit der Session oder am Zeitlimit für Hintergrundaufgaben. Reicht das nicht, folgen höchstens stündlich (Stempel `~/Library/Caches/dev.rubeen.diskwatch.deep`) zwei weitere Stufen: Stufe 2 räumt den Docker-Build-Cache, `node_modules/` und cargo-`target/` in `~/dev`-Repos, die seit `DISKWATCH_STALE_DAYS` (Standard 30) keine Datei geändert haben — gemessen am ganzen Repo, nicht am Paket, damit aktive Monorepos heil bleiben —, und ruft `pnpm store prune` (pnpm verlinkt `node_modules` per Hardlink in den Store, erst der Prune gibt den Platz frei). Stufe 3 löscht gestoppte Container und ungenutzte Images älter als 24 h; lokal gebaute `testbed-*:SNAPSHOT`-Images lassen sich nicht neu pullen, deshalb kommen sie zuletzt. Docker-Volumes bleiben immer stehen. Docker wird nur angefasst, wenn `orbctl status` bereits `Running` meldet, und über `-H unix://~/.orbstack/run/docker.sock` angesprochen — ein Aufruf gegen ein gestopptes OrbStack würde die VM starten. docker, orbctl und pnpm werden über absolute Kandidatenpfade gefunden; fehlt eines oder scheitert ein Schritt, protokolliert diskwatch das und macht weiter. Log: `~/Library/Logs/diskwatch.log`; `diskwatch list` zeigt die Kandidaten aller Stufen, `diskwatch deep` räumt sofort alle Stufen, `diskwatch status` zeigt Agent, Platz und Swap.

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

## Tests

Die Shell-Skripte haben kein Testframework und werden mit `shellcheck` geprüft.
Einzige Ausnahme ist `apager-listener.py`: dessen reine Funktionen — Herkunfts-
prüfung, Tokenvergleich, Alarmspeicher, HTTP-Handler — tragen die Prüfungen,
die im Ernstfall still brechen, und haben deshalb Unit-Tests:

    /usr/bin/python3 -m unittest discover -s tests -v

`unittest` und `/usr/bin/python3` sind bewusst gewählt: keine Installation, kein
venv, keine mise-Abhängigkeit, die einen LaunchAgent lahmlegen könnte.
