# Agent Halo

![Agent Halo READY status banner](assets/agent-halo-readme-banner.png)

A local, always-on-top status halo for the Codex desktop app.

The current release supports Codex, with Claude Code detection planned next.

Version: `0.13.0`

English | [简体中文](README.zh-CN.md)

Cross-platform behavior is generated from
[`src/shared/spec/agent-halo.v2.json`](src/shared/spec/agent-halo.v2.json), while
platform-specific rendering remains native. See the
[shared contract guide](src/shared/README.md) and
[architecture notes](docs/CROSS_PLATFORM_SHARED_CONTRACT.md).

---

## Requirements

- Windows 10 or Windows 11
- The Codex desktop app installed and in use
- .NET Framework 4.8, normally included with current Windows 10/11 systems

## macOS development build

Run and verify:

```bash
bash ./scripts/run-macos.sh --verify
```

The app is a menu bar accessory app and does not show a Dock icon. Quit it from the Agent Halo menu bar icon, or run:

```bash
pkill -x AgentHaloMac
```

Diagnostics:

```bash
cd src/macos
swift run AgentHaloDiagnostics --self-test /tmp/agent-halo-self-test.txt
swift run AgentHaloDiagnostics --render-states /tmp/agent-halo-states
swift run AgentHaloDiagnostics --transition-strip /tmp/agent-halo-transitions
```

## Install and run

1. Download the latest `AgentHalo-Windows-v*.zip` from GitHub Releases.
2. Extract the entire archive. Do not run the app from inside the ZIP.
3. Double-click `AgentHalo.exe`. The halo appears near the upper-right corner
   of the primary display.

There is no installer. Agent Halo does not modify Codex and does not require an
OpenAI API key.

## Controls

- Drag the halo to reposition it; it gently snaps to display edges.
- Hover to inspect the current state plus five-hour and weekly usage limits.
- Completed green breathes until Codex returns to the foreground, then settles
  into a non-glowing standby green.
- Right-click for state previews, pause, startup, and exit controls.
- Use the `光环大小` submenu to select `75% / 100% / 125%`;
  the selected size persists across restarts.
- If a disconnected display leaves the halo off-screen, right-click its system
  tray icon and select `脱离卡死` to move it to the primary display.
- Click the halo to bring the Codex window forward.

## Status language

- Amber long-bright/short-dim breathing: Codex is thinking or planning.
- Blue long-bright/short-dim breathing: Codex is running a command, search,
  edit, or tool.
- Green double flash: Codex finished, then breathes slowly until Codex returns to the foreground.
- Coral double pulse: Codex is waiting for approval, confirmation, or input.
- Red: a blocking failure. It flashes while unseen, stays brightly lit when
  Codex is foregrounded, and becomes dim red after you leave.
- Stable green: Codex is running with no active task.
- Dim white: Codex is not running.

The large gap chases a small gap that drifts gently back and forth. Near 40° of
separation, the small gap is smoothly repelled toward roughly 150°, then coasts with
decaying momentum before returning to its bounded drift. Thinking and working
accelerate the motion. The ring body itself powers up from a dim material into a
bright white core while the state color remains around the tube edge. Its narrow bloom
increases while the center stays transparent. Thinking, execution, and completion use
continuous asymmetric breathing, and state changes dim before blending into the next
color and powering up again. Repulsion duration and exit momentum scale from the
current orbit speed. Animation follows the desktop
composition refresh rate without lowering idle or completed states to 30 FPS.
Monitoring pause is runtime-only and automatically clears on the next launch.
Blue remains visible for roughly 1.8 seconds after a tool returns, so short tool calls
still produce a readable execution state.

## Privacy

Agent Halo locally reads lifecycle and usage events from
`%USERPROFILE%\.codex\sessions`. It also performs read-only structured queries
against `logs_2.sqlite` for connection and service failures. It does not upload data,
call a network service, display conversation content, or read/store an OpenAI API key.

## Windows security notice

This personal build is not signed with a commercial code-signing certificate, so
Windows SmartScreen may display a warning. Run it only when the archive came from
a trusted sender and the value in `SHA256.txt` matches the executable. Select
"More info" to inspect the application name before making a decision.

To verify the file, open PowerShell in the extracted folder and run:

```powershell
Get-FileHash .\AgentHalo.exe -Algorithm SHA256
```

The resulting hash must exactly match the value in `SHA256.txt`.

---

## Project notice

Agent Halo is an independent, unofficial open-source project. It is not affiliated
with or endorsed by OpenAI or Quantic Dream. It uses no game assets, names, logos,
or copied indicator geometry.
