# Agent Workspace

A calm, native macOS workspace for active Claude Code sessions running in tmux.

![Agent Workspace session workspace](docs/agent-workspace.png)

Agent Workspace is a thin desktop view over Claude Code sessions that keep running in tmux. Search and switch sessions, see the live CLI from its exact pane, and send a prompt without replacing your terminal workflow. Closing or quitting the app never stops those sessions.

The app uses AppKit for the shell and WKWebView for its small interface—there is no Electron runtime and no second terminal emulator.

> **Alpha:** Claude Code is the only working provider today. Codex support is planned, but it is not implemented.

## Features

- Finds active local Claude Code sessions running inside tmux.
- Groups and searches sessions by project.
- Renders the complete live tmux scrollback instead of reconstructing a second conversation UI.
- Sends prompts to the exact tmux pane from the desktop composer.
- Creates sessions and deletes them with confirmation.
- Leaves every tmux session running when its window closes or the app quits.
- Supports `⌘K` to search, `⌘N` to create, and `⌘R` to refresh.

The right panel is the captured Claude CLI pane. tmux remains the terminal emulator, process owner, and source of truth; only the explicit per-session **Delete** action stops a session.

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools (`xcode-select --install`)
- tmux
- Claude Code, installed and authenticated through Claude Code itself

Agent Workspace is standalone and does not require or modify the `work` CLI from its original development environment.

## Build and install

```bash
./build.sh
```

This compiles the native app for the current Mac, signs it ad hoc, and installs it at `~/Applications/Agent Workspace.app`.

To build an isolated copy without installing it:

```bash
./build.sh --check
```

The command prints the temporary app path.

## Run

```bash
open "$HOME/Applications/Agent Workspace.app"
```

To open Agent Workspace with a particular project as its starting directory:

```bash
open -na "$HOME/Applications/Agent Workspace.app" --args "$PWD"
```

Claude Code remains responsible for authentication and for any network requests made while processing prompts.

## Test

```bash
bash Tests/sesslist.bash
bash Tests/app.bash
```

The app test builds an isolated bundle and exercises the session bridge, complete pane capture, message transport, native window drag region, and UI contract.

## Privacy and safety

Agent Workspace has no telemetry and does not operate a remote service. Its WebView uses a non-persistent data store and communicates with the native process through an in-process URL scheme rather than a local HTTP server.

To display a session, the app reads local tmux state and pane scrollback. It does not upload that output, persist a second transcript copy, access the Keychain, read `~/.claude` transcripts, or read or change Claude credentials. See [SECURITY.md](SECURITY.md) for reporting security issues.

Deleting a session runs the equivalent of `tmux kill-session` after confirmation. This stops the entire tmux session; it does not delete the project or Claude files.

## Current limitations

- Only active local Claude Code sessions in tmux are supported.
- Ended or archived sessions are not browsable.
- Codex has a planned provider boundary but no working backend.
- This is a live pane viewer with a prompt composer; tmux remains the terminal emulator.
- Messages are limited to 32 KB.
- Releases are ad-hoc signed and are not notarized by Apple.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License and trademarks

The original project code is available under the [MIT License](LICENSE). Third-party names, trademarks, and provider icons are not granted under that license; see [NOTICE](NOTICE).

Agent Workspace is an independent community project. It is not affiliated with, endorsed by, or sponsored by Anthropic, OpenAI, or Notion.
