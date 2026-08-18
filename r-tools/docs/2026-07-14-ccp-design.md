# ccp — Claude-Code-Profil-Switcher

**Datum:** 2026-07-14
**Status:** Umgesetzt. Switcher-**Mechanik** (Config-Dir-Auflösung, `ccp use`-Switch, Symlinks, Lock) verifiziert. **Offene Kern-Verifikation:** ob der Keychain-OAuth-Token pro Config-Dir schreib-isoliert ist (Punkt 1) — entscheidet, ob `work`-Login den `personal`-Login überlebt und ob beide gleichzeitig gehen. `innoq` **funktioniert end-to-end** — LiteLLM-Gateway des Arbeitgebers (Base-URL, Token und Modell-Mapping stehen in der nicht im Git liegenden `~/.claude/settings-innoq.json`), per `claude -p` gegen `~/.claude-innoq` verifiziert. Verfügbare Modelle via `GET <base>/v1/models`; Wechsel über `settings-innoq.json` + `ccp setup innoq`.
**Ort des Tools:** `~/.dotfiles/r-tools/ccp` + Fish-Functions in `~/.dotfiles/fish/functions/` (`claude`, `_ccp_launch`, `claude-personal`, `claude-work`, `claude-innoq`)

**Validiert (mit Fake-`claude`, ohne echtes `~/.claude` anzufassen):** Config-Dir-Auflösung pro Profil, globaler `ccp use`-Switch, Lock anlegen/entfernen, stale Lock überschreiben, nicht-interaktiver Guard blockiert nicht.

**Offen — 30-Sekunden-Test beim ersten `work`-Login** (klärt die Keychain-Frage aus Punkt 1):
1. Vorher `personal`-Token-Zeitstempel merken: `security find-generic-password -s "Claude Code-credentials" | grep mdat`.
2. `claude-work` → `/login` mit dem Arbeits-Account.
3. Zeitstempel erneut prüfen. **Geändert → `work` hat `personal` überschrieben (Kollision).** Unverändert → isoliert. Zusätzlich `security dump-keychain | grep "Claude Code-credentials"` — kam ein neuer suffixierter Eintrag für `work` dazu?
4. `claude-personal -p "ok"` — antwortet `personal` noch **ohne** Neu-Login?
Alle grün → Doc auf „verifiziert" heben. `personal` ausgeloggt → Kollision real; Ausweg wäre setup-token/API-Key-Auth für ein Profil (rechnet anders ab). Interaktiver Guard-Prompt wurde ebenfalls nicht interaktiv getestet.

## Ziel

Bequem zwischen mehreren Claude-Code-Identitäten wechseln, ohne sich jedes Mal neu
einzuloggen:

- `personal` — private Claude-Subscription (OAuth-Login)
- `work` — Arbeits-Claude-Account (OAuth-Login)
- `innoq` — LiteLLM-Gateway des Arbeitgebers (statischer Token, Nicht-Claude-Modelle)

Arbeitsweise (Skills, Plugins, Agents, Commands, Hooks, Permissions) soll geteilt
bleiben; Identität, Verlauf und MCP-Server sollen pro Profil getrennt sein.

## Verifizierte technische Grundlage

Empirisch auf **Claude Code 2.1.209 (macOS)** getestet:

1. **`CLAUDE_CONFIG_DIR` isoliert den Config-State** (eigenes `.claude.json`, eigene
   History/MCP/`oauthAccount`-Metadaten): ein frisches Dir meldet „Not logged in".
   **NOCH NICHT bestätigt:** ob auch der macOS-Keychain-OAuth-Token pro Dir
   *schreib*-isoliert ist. Der Read-only-Probe kann das nicht zeigen — die „Not
   logged in"-Meldung folgt schon aus dem leeren `.claude.json` (`login_state()` prüft
   genau das). Bug [#20553](https://github.com/anthropics/claude-code/issues/20553)
   (geteilter Keychain-Eintrag, v2.1.19) ist damit **weder bestätigt noch widerlegt**.
   **Falls doch geteilt:** Login in `work` überschreibt den `personal`-Token → `personal`
   muss neu einloggen, wenn sein Token abläuft; `work`+`personal` gleichzeitig kollidieren.
   Die Config-Dir-Struktur ist in beiden Fällen richtig — schlimmstenfalls gelegentliches
   Neu-Einloggen, kein Datenverlust. Der 30-Sekunden-Test (unten) klärt es beim ersten
   `work`-Login.
2. **Token-Refresh läuft pro Dir automatisch.** Einmal `/login` pro Profil genügt;
   Claude Code erneuert das Access-Token dieses Dirs dauerhaft selbst.
3. **Gleichzeitigkeit:** Zwei Claude-Prozesse im **selben** Config-Dir überschreiben sich
   beim Schreiben von `.claude.json` und können sie auf einen Stub reduzieren (real
   beobachtet). → Jedes Profil bekommt zwingend sein eigenes Dir; die Starter warnen
   best-effort (Lockfile), wenn im Ziel-Dir bereits ein via ccp gestarteter Claude läuft.
   Ob zwei **verschiedene** OAuth-Profile (work+personal) *gleichzeitig* laufen können,
   hängt an der Keychain-Schreib-Isolation aus Punkt 1 — **ungetestet**. Sicher nacheinander
   umschalten geht in jedem Fall.
4. **Env-Precedence:** `ANTHROPIC_AUTH_TOKEN` (+ `ANTHROPIC_BASE_URL` fürs Routing)
   schlägt den Keychain-Login. Damit braucht `innoq` keinen Login — die Gateway-Env in
   seiner `settings.json` reicht.
5. **Fish-Autoload:** `~/.config/fish` → `~/.dotfiles/fish` ist verlinkt; Functions aus
   `~/.dotfiles/fish/functions/` werden geladen. Eine Function `claude` überschattet das
   Binary; intern ruft sie `command claude`.

## Architektur

### Profile → Config-Dirs

| Profil     | `CLAUDE_CONFIG_DIR`   | Auth                                   | Login |
|------------|-----------------------|----------------------------------------|-------|
| `personal` | `~/.claude` (bestehend, unverändert) | Keychain-OAuth          | vorhanden |
| `work`     | `~/.claude-work` (neu) | Keychain-OAuth                        | 1× `/login` |
| `innoq`    | `~/.claude-innoq` (neu)| Gateway-Env in eigener `settings.json` | keiner |

`personal` bleibt exakt dein heutiges `~/.claude` — keine Migration, kein Risiko.

### Geteilt vs. getrennt

**Geteilt** — als Symlink aus `~/.claude` in jedes neue Profil-Dir:
`skills/`, `plugins/`, `agents/`, `commands/`, `hooks/`, `CLAUDE.md`.

**`settings.json`:**
- `work` → Symlink auf `~/.claude/settings.json` (teilt Permissions, Statusline,
  Keybindings, Hooks, Theme, Model, enabledPlugins).
- `innoq` → **echte Datei**, beim Setup erzeugt aus `~/.claude/settings.json` (geteilte
  Teile) **plus** dem `env`-Block aus `~/.claude/settings-innoq.json` (Gateway-URL,
  Auth-Token, Modell-Mappings). Der Token wird aus der bestehenden, *nicht* im Git
  liegenden `settings-innoq.json` gelesen und landet nur in `~/.claude-innoq/` — **nie im
  Repo**.

**Getrennt** — jedes Dir hat sein eigenes (nicht verlinkt):
Login-Token (automatisch pro Dir), `.claude.json` (Projekte, History-Index, MCP-Server),
`sessions/`, `projects/`, `todos/`, sonstiger Laufzeit-State.

## Komponenten

1. **`~/.dotfiles/r-tools/ccp`** — Bash-CLI, alleinige Quelle der Profil→Dir-Zuordnung.
   Unterkommandos:
   - `ccp setup <profil>` — Dir anlegen, geteilte Teile verlinken, für `innoq` die
     Gateway-`settings.json` schreiben. Bei OAuth-Profilen Hinweis: mit dem richtigen
     Account einloggen (`claude-work`, dann `/login`).
   - `ccp use <profil>` — aktives Profil in Statusdatei `~/.claude-active-profile`
     schreiben; danach folgt das nackte `claude` diesem Profil.
   - `ccp status` — aktives Profil, existierende Dirs, Login-Status je Profil.
   - `ccp list` — Profile + Dirs.
   - `ccp _resolve [<profil>]` / `_resolve-active` — interner Helfer: gibt das Config-Dir
     aus (von den Fish-Functions genutzt, damit die Zuordnung nur hier lebt).
   - Standard-Header/`usage()`/`-h` gemäß r-tools-Konvention; `set -euo pipefail`.
2. **`~/.dotfiles/fish/functions/claude.fish`** — Wrapper. Nacktes `claude` löst das
   aktive Profil via `ccp _resolve-active` auf und startet mit passendem
   `CLAUDE_CONFIG_DIR`. **Fallback** auf `~/.claude` (personal), falls `ccp` fehlt/fehlschlägt
   — `claude` darf nie kaputtgehen, nur weil `ccp` nicht da ist.
3. **`claude-personal.fish` / `claude-work.fish` / `claude-innoq.fish`** — explizite
   Starter. Setzen `CLAUDE_CONFIG_DIR` fix auf ihr Profil (ändern den globalen Default
   *nicht*) und führen den Gleichzeitigkeits-Guard aus.

### Statusdatei

`~/.claude-active-profile` — enthält nur `personal` | `work` | `innoq`.
Fehlt sie → Default `personal`.

### Gleichzeitigkeits-Guard (best-effort)

Vor dem Start prüft der Starter via `ps eww`, ob bereits ein Prozess mit
`CLAUDE_CONFIG_DIR=<ziel-dir>` in der Env läuft. Falls ja: warnen und nachfragen, ob
trotzdem gestartet werden soll. Bewusst best-effort — verhindert den häufigsten
Selbst-Beschuss (dasselbe Profil zweimal), garantiert aber nichts.

## Bedienung (Zielbild)

```
ccp setup work            # Dir + Symlinks anlegen
claude-work               # startet work-Profil → dort einmalig /login (Arbeits-Account)
ccp setup innoq           # Dir + Symlinks + Gateway-settings.json (kein Login)

ccp use work              # ab jetzt ist nacktes `claude` = work
claude                    # → work
ccp status                # zeigt aktiv=work, Dirs, Login-Status

claude-personal           # startet privat, egal welcher globale Default gesetzt ist
claude-innoq              # startet INNOQ-Gateway
```

## Grenzen & bekannte Unbekannte

- **Dasselbe Profil nie zweimal gleichzeitig** (Claude-Code-Limit, s.o.). Guard warnt nur.
- **MCP-Server** sind pro Profil getrennt: `work` startet ohne die persönlichen MCP-Server.
  Plugin-gebundene MCPs (context7, chrome-devtools) kommen über das geteilte `plugins/`
  und sind überall verfügbar.
- **MCP-OAuth-Tokens** liegen evtl. global im Keychain (der beobachtete
  `Claude Code-credentials-61bbd3b1` ist wahrscheinlich genau so einer). Ob OAuth-MCPs pro
  Profil eine erneute Anmeldung brauchen, ist offen → beim ersten `work`-MCP-Setup prüfen.
- **`settings.json`-Drift für `innoq`:** Da `innoq` eine erzeugte Kopie nutzt, greifen
  spätere Änderungen an geteilten Settings (Permissions/Hooks) dort nicht automatisch.
  `ccp setup innoq` erneut ausführen aktualisiert sie (idempotent).

## Umsetzungsreihenfolge

1. `ccp` (Bash): Argument-Parsing, `_resolve`, `list`, `status` (Read-only zuerst).
2. `ccp setup <profil>`: Dir anlegen, Symlinks (idempotent), `innoq`-`settings.json`
   generieren.
3. `ccp use <profil>` + Statusdatei.
4. Fish: `claude.fish` (Wrapper mit Fallback), dann `claude-personal/-work/-innoq.fish`
   inkl. Guard.
5. Manueller End-to-End-Test: `ccp setup work` → `claude-work` → `/login` →
   `ccp use work` → nacktes `claude` landet in work; `ccp status` korrekt;
   `personal` unverändert.
6. Kurzer Eintrag in `~/.dotfiles/r-tools/CLAUDE.md` / `AGENTS.md` (Tool-Liste).
