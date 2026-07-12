# Contributing

Thanks for helping improve Agent Workspace. Keep changes focused, local-first, and easy to verify.

## Development setup

You need macOS 13 or newer, Xcode Command Line Tools, tmux, and Claude Code.

```bash
./build.sh --check
bash Tests/sesslist.bash
bash Tests/app.bash
```

The project is intentionally small:

- `Sources/AgentWorkspace.swift` contains the AppKit host, tmux backend, and WebView bridge.
- `Resources/index.html` contains the interface.
- `Resources/Bridge/` contains the bundled tmux session scripts.
- `Tests/` contains isolated bridge and application checks.

## Pull requests

- Explain the user-facing problem and the smallest change that solves it.
- Add or update a regression test for behavior changes.
- Run both test scripts before submitting.
- Include before-and-after screenshots for visible UI changes.
- Keep provider support honest: an icon or interface seam is not end-to-end support.
- Preserve exact tmux session and pane targeting.
- Do not introduce telemetry or a network service without prior discussion.
- Do not make permission-bypass flags the default way to launch an agent.

## Test data and privacy

Use synthetic tmux sessions and pane output. Never commit real conversation output, credentials, tokens, private project paths, account details, or screenshots containing personal data. Redact diagnostic output before attaching it to an issue or pull request.

For security-sensitive reports, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## License

By submitting a contribution, you agree that it may be distributed under the project's [MIT License](LICENSE). Third-party trademarks and provider icons remain subject to their owners' rights as described in [NOTICE](NOTICE).
