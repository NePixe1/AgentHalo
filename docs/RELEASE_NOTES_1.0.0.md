# Agent Halo 1.0.0

Agent Halo 1.0.0 is the first stable release of the cross-platform desktop
status halo for Codex and Claude Code.

## Highlights

- Adds native Codex and Claude Code usage monitoring on macOS, including
  account-aware detail views and retained session context.
- Adds real-time Codex runtime monitoring and usage refresh improvements on
  Windows.
- Supports custom Codex API configurations without exposing sensitive
  connection details in the UI.
- Improves the macOS details panel: session titles, current-turn token usage,
  quota presentation, localization, and stable layout across agent switches.
- Reduces macOS monitoring CPU work while preserving the rendered halo output.

## Installation

- macOS: open `AgentHalo-macOS-1.0.0.dmg`, then drag Agent Halo to
  Applications.
- Windows: extract `AgentHalo-Windows-v1.0.0.zip` completely, then run
  `AgentHalo.exe`.

## Notes

- The application is local-first. OAuth usage refreshes reuse the existing
  Codex or Claude Code sign-in; no API key is required for official accounts.
- Windows requires .NET Framework 4.8. macOS requires macOS 13 or later.
