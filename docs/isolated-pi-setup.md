# Isolated Pi setup

Plain `pi` resolves its configuration directory to the user's ordinary global Pi profile, so a Firstmate session launched that way inherits whatever packages, credentials, model defaults, and trust decisions that machine happens to carry.
That is fine for one person and unreproducible for a team.

`bin/fm-pi.sh` and `bin/fm-pi.ps1` launch Pi with `PI_CODING_AGENT_DIR` pointed at `<clone>/data/pi-agent` instead, so every teammate's Firstmate session starts from the same empty, clone-private Pi profile.
Use `bin/fm-pi.sh` on macOS, on Linux, and in Git Bash on Windows; use `bin/fm-pi.ps1` in Windows PowerShell.
The two launchers are deliberately behaviorally identical and are kept in step by `tests/fm-pi-isolation.test.sh`.

## What the boundary covers

Both launchers resolve the clone root from their own file location rather than the shell's current directory, so they work from anywhere.
They set `PI_CODING_AGENT_DIR` to `<clone>/data/pi-agent`, change to the clone root, forward every argument to `pi` unchanged, and exit with `pi`'s own status.
Neither one reads, writes, nor points at the ordinary global profile at any point.
When `pi` is not on `PATH` they report that and stop with status 127 instead of launching something else.

Everything Pi keeps in its configuration directory therefore becomes private to the clone:

- installed packages and their npm storage
- credentials in `data/pi-agent/auth.json`
- project trust decisions in `data/pi-agent/trust.json`
- model defaults, model catalog, and package caches
- session history under `data/pi-agent/sessions`

`data/` is gitignored, so the profile never becomes tracked content and never travels between teammates.
The tracked project settings at `.pi/settings.json` declare no packages, so a fresh profile installs nothing on first launch.

Windows launches also set `MSYS=winsymlinks:nativestrict` so the repository's tracked symlinks (`CLAUDE.md` and `.claude/skills`) resolve natively.
`bin/fm-pi.sh` applies the same setting only when it detects an MSYS-derived shell such as Git Bash.
macOS needs no platform-specific setting of its own: native symlinks are already the default there, and Pi's configuration directory is selected by the same `PI_CODING_AGENT_DIR` variable on every platform.

## Prerequisites

[`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) owns the full tool list and prints an install command for anything missing, so the fastest path is to install the essentials below, launch once, and let the session-start report name the rest.
Both platforms need Git, the GitHub CLI authenticated through `gh auth login`, Node.js with npm, and the CLI for the runtime backend you select ([tmux](tmux-backend.md) is the reference default).

Install Pi itself with npm on either platform:

```sh
npm install -g @earendil-works/pi-coding-agent
```

### macOS

Install the shell-based tools with their published installers:

```sh
curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh
curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh
```

### Windows

Pi requires a bash shell on Windows and looks for Git Bash first, so install [Git for Windows](https://git-scm.com/download/win) before anything else.
Run `bin/fm-pi.sh` from Git Bash or `bin\fm-pi.ps1` from PowerShell; both reach the same isolated profile.

The two shell installers above refuse to run in Git Bash, because `uname -s` there reports `MINGW64_NT-*` rather than a name they recognize.
Both projects support Windows through Go instead, so install [Go](https://go.dev/dl/) and use:

```sh
go install github.com/kunchenguid/treehouse@latest
go install github.com/kunchenguid/no-mistakes/cmd/no-mistakes@latest
```

Add `%USERPROFILE%\go\bin` to `PATH` so the installed binaries resolve.

## Clone and private state

```sh
gh auth login
git clone https://github.com/kunchenguid/firstmate
cd firstmate
```

The clone is the whole installation: there is nothing else to install into a shared location.
`data/`, `state/`, `config/`, and `projects/` are created inside the clone as you use it, are all gitignored, and belong to that one teammate.
The isolated Pi profile lives under `data/pi-agent` for exactly that reason.
[docs/configuration.md](configuration.md) owns what each of those directories holds.

## Launch

```sh
bin/fm-pi.sh
```

```powershell
.\bin\fm-pi.ps1
```

Arguments pass straight through, so provider and model selection works as usual:

```sh
bin/fm-pi.sh --provider openai-codex --model gpt-5.6-sol --thinking max
```

Do not launch plain `pi` for the Firstmate session.
It is not an equivalent shortcut: it uses the global profile and silently loses the boundary.

## Authenticate inside the isolated profile

The isolated profile starts with no credentials, and credentials in the ordinary global profile are not read, copied, or migrated into it.
That is intended: inheriting them would reintroduce exactly the machine-specific state this setup removes.
Expect to authenticate once per clone, and expect the ordinary global profile to keep its own credentials untouched.

Either of the two supported paths works:

- Run `/login` inside the first isolated session and select a provider.
  Pi stores the result in `data/pi-agent/auth.json`.
- Or export the provider's environment variable before launching, for example `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`.
  Pi's own provider documentation owns the full variable list.

Never copy `auth.json` out of the global profile.
Nothing in this setup path writes to the global profile, and hand-copying credentials into the clone puts them one mistake away from a commit.

## Accept project trust once

The isolated profile has an empty trust store, so Pi asks about this project again on the first isolated launch even if the global profile already trusted it.
Accept it once per clone.

Trust is what lets Pi load the project's tracked extensions, which the primary session needs:

- `.pi/extensions/fm-primary-turnend-guard.ts`
- `.pi/extensions/fm-primary-pi-watch.ts`
- `.pi/extensions/fm-calm.ts` for the [`/calm` presentation toggle](calm.md)

The project's `.agents/skills` and context files load through the same trust decision.
If the two supervision extensions have not loaded, the session-start report says so and names the restart needed, so treat a `PI_WATCH_EXTENSION: not loaded` line as the signal that trust was declined or the session predates it.

## Verify the isolation

Run these from the clone after the first launch.

1. `bin/fm-pi.sh list` reports `No packages installed.` rather than any global package.
2. `bin/fm-pi.sh --help` shows no `Extension CLI Flags` section: a profile carrying global packages advertises their flags there, such as Gentle's `--no-skill-registry` or the MCP adapter's `--mcp-config`.
3. An interactive session shows no Gentle persona, Engram, subagent, intercom, web, todo, ask-user, BTW, or MCP surfaces.
4. `data/pi-agent/sessions` holds the new session after a first launch, and the session picker offers only sessions started from this clone.
5. The session-start report does not print `PI_WATCH_EXTENSION: not loaded`.
6. Plain `pi list` run from outside the clone still reports your ordinary global packages, confirming the global profile was left alone.

## Supported limits

The launchers set the configuration directory for the session they start.
Crewmate and secondmate launches are a separate path that Firstmate does not point at the isolated profile; whether one inherits the variable depends on the runtime backend's own environment handling.

`bin/fm-pi.sh` is covered by [`bin/fm-lint.sh`](../bin/fm-lint.sh) like every other tracked shell script.
`bin/fm-pi.ps1` is outside ShellCheck's scope, so `tests/fm-pi-isolation.test.sh` asserts the same boundary against both files statically.

This setup path does not change Firstmate's platform support for anything else; it changes only which Pi profile the primary session uses.
