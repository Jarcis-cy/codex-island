<div align="center">
  <img src="CodexIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Codex Island logo" width="100" height="100">
  <h1 align="center">Codex Island</h1>
  <p align="center">
    A macOS notch and menu bar companion for Codex CLI.
  </p>
  <p align="center">
    <a href="./README.zh-CN.md">简体中文</a>
    ·
    <a href="https://github.com/Jarcis-cy/codex-island/releases/latest">Latest Release</a>
  </p>
</div>

Codex Island keeps an eye on your local Codex sessions, and it can also connect to Codex running on remote machines over SSH. It surfaces state changes in a Dynamic Island-style overlay on macOS for people who keep Codex in the terminal and want lightweight visibility, fast approval handling, and quick access to recent conversation context without living in every shell window.

## What It Does

- Watches Codex sessions through `~/.codex/hooks.json` and a local Unix socket.
- Connects to remote machines over SSH and talks to `codex app-server` over stdio.
- Expands from the notch area to show session activity, waiting states, and tool execution status.
- Shows recent conversation history with markdown rendering.
- Supports approval flows directly from the app UI.
- Tracks multiple local sessions and remote threads, and lets you switch between them.
- Lets you save SSH targets, optional default working directories, and auto-connect remote hosts from the app.
- Includes launch-at-login, screen selection, sound settings, and in-app updates.
- Falls back gracefully on Macs without a physical notch.

## Requirements

- macOS 15.6 or later
- Codex CLI installed locally
- SSH access to any remote machine you want to manage, with Codex CLI installed on that remote host
- Accessibility permission if you want the app to interact with window focus behavior
- `tmux` if you want tmux-aware messaging and approval workflows
- `yabai` if you want window focusing integrations

## Install

Download the latest release from GitHub, or build it locally with Xcode.

For a debug build:

```bash
xcodebuild -scheme CodexIsland -configuration Debug build
```

For a release build:

```bash
./scripts/build.sh
```

The exported app bundle is written to `build/export/Codex Island.app`.

## Remote Hosts Over SSH

Open `Remote Hosts` from the notch menu to add an SSH target, an optional default working directory, and an auto-connect preference for each remote machine.

When you connect a host, Codex Island launches:

```bash
ssh -T -o BatchMode=yes <target> codex app-server --listen stdio://
```

That means remote hosts currently expect non-interactive SSH authentication, and the remote machine must already have `codex` available on `PATH`. Once connected, you can list remote threads, start a new thread, open an existing thread, send messages, interrupt turns, and handle approvals from the app UI.

Remote app-server diagnostics are written to `~/Library/Application Support/Codex Island/Logs/remote-app-server.jsonl`.

## How It Works

On first launch, Codex Island installs a managed hook script into `~/.codex/hooks/` and updates `~/.codex/hooks.json`. The hook helper forwards local Codex hook events to the app over a Unix domain socket, and the app reconciles those events with transcript data to keep session state accurate.

Remote hosts use a separate path: the app opens an SSH stdio transport to `codex app-server` on the target machine and keeps remote thread state alongside the local hooks-first session model.

The current architecture is still hooks-first inside the macOS app process. The `sidecar/` directory is a reserved Rust scaffold for future work around transcript parsing, state aggregation, and IPC.

## Project Layout

- `CodexIsland/App/`: app lifecycle and window bootstrap
- `CodexIsland/Core/`: shared settings, geometry, and screen selection
- `CodexIsland/Services/`: hooks, local session parsing, remote app-server management, tmux integration, updates, and window management
- `CodexIsland/UI/`: notch views, menu UI, chat UI, and reusable components
- `CodexIsland/Resources/`: bundled scripts such as `codex-island-state.py`
- `scripts/`: build, signing, notarization, and release helpers
- `sidecar/`: future Rust sidecar scaffold

## Privacy

The app currently initializes Mixpanel for anonymous product analytics and Sparkle for app updates.

Tracked analytics are intended to cover app launch and session lifecycle metadata such as:

- app version and build number
- macOS version
- detected Codex version
- session start events

The repository does not claim to collect conversation content in analytics, but you should still review the source and decide whether that tradeoff matches your environment before distributing it broadly.

## Development

Open the project in Xcode for day-to-day work. The repository also includes release automation for signing, notarization, DMG creation, appcast generation, and optional GitHub release publishing:

```bash
./scripts/create-release.sh
```

If you change anything under `CodexIsland/Services/Hooks/` or `CodexIsland/Resources/codex-island-state.py`, treat it as user-impacting local environment behavior and verify it carefully.

## Acknowledgements

Codex Island builds on the original ideas and earlier implementation work from [`farouqaldori/claude-island`](https://github.com/farouqaldori/claude-island). Thanks to Farouq Aldori and the upstream contributors for laying the foundation this Codex-focused version continues from.

## License

Apache 2.0. See [`LICENSE.md`](./LICENSE.md).
