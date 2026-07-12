# Security policy

workdpace controls local tmux sessions and reads local Claude Code transcripts. Please treat security reports involving session targeting, command or message injection, transcript rendering, local file access, or the in-process WebView bridge as sensitive.

## Supported versions

workdpace is currently alpha software. Security fixes are made on the latest `main` revision; older revisions may not receive patches.

## Report a vulnerability

Use this repository's GitHub **Report a vulnerability** flow to submit a private report. Do not publish exploit details in a public issue.

Include:

- The affected revision or release.
- macOS, tmux, and Claude Code versions.
- Expected and observed behavior.
- Minimal reproduction steps and impact.
- Redacted logs, if necessary.

Never include credentials, tokens, private conversation text, unredacted home-directory paths, or project source in a report. A synthetic tmux session and synthetic transcript are strongly preferred.

## Security model

- The app is local-only and contains no telemetry.
- The WebView uses a non-persistent data store and an in-process URL scheme.
- Session messages are transferred through a tmux buffer to a validated pane target.
- The app reads Claude Code session metadata and transcripts but does not handle Claude authentication or Keychain credentials.
- Deleting a session terminates the complete tmux session after confirmation.
- Builds are ad-hoc signed and are not notarized by Apple.

Claude Code and tmux remain separate dependencies with their own security models. A vulnerability in either dependency should also be reported to its maintainer.
