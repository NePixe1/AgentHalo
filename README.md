<a id="readme-top"></a>

<div align="center">
  <img src="assets/agent-halo-readme-banner.png" alt="Agent Halo Banner" width="760"/>
</div>

<h1 align="center">Agent Halo</h1>

<div align="center">
  <p>
    <a href="https://github.com/NePixe1/AgentHalo/releases/latest">
      <img src="https://img.shields.io/github/downloads/NePixe1/AgentHalo/latest/total?style=flat&label=Downloads%20%40latest&labelColor=444&logo=github&logoColor=white&cacheSeconds=600" alt="Latest downloads">
    </a>
    <a href="https://github.com/NePixe1/AgentHalo/releases">
      <img src="https://img.shields.io/github/downloads/NePixe1/AgentHalo/total?label=Total%20Downloads" alt="Total downloads">
    </a>
  </p>
  <p>
    <img src="https://img.shields.io/badge/version-0.14.0-14B8A6?style=for-the-badge" alt="Version"/>
    <img src="https://img.shields.io/badge/privacy--first-0F172A?style=for-the-badge" alt="Privacy First"/>
    <img src="https://img.shields.io/badge/Swift-FA7343?style=for-the-badge&logo=swift&logoColor=white" alt="Swift"/>
    <img src="https://img.shields.io/badge/Xcode-007ACC?style=for-the-badge&logo=xcode&logoColor=white" alt="Xcode"/>
    <img src="https://img.shields.io/badge/C%23-512BD4?style=for-the-badge&logo=csharp&logoColor=white" alt="C#"/>
    <img src="https://img.shields.io/badge/.NET-512BD4?style=for-the-badge&logo=dotnet&logoColor=white" alt=".NET"/>
    <img src="https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS"/>
    <img src="https://img.shields.io/badge/Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows"/>
    <img src="https://img.shields.io/badge/Git-E44C30?style=for-the-badge&logo=git&logoColor=white" alt="Git"/>
  </p>
  <p>A local, always-on-top status halo for agents, rendering execution and planning states natively on your desktop.</p>
  <p>English | <a href="README.zh-CN.md">Simplified Chinese</a></p>
</div>


---

Cross-platform behavior is generated from
[`src/shared/spec/agent-halo.v2.json`](src/shared/spec/agent-halo.v2.json), while
platform-specific rendering remains native. See the
[shared contract guide](src/shared/README.md) and
[architecture notes](docs/CROSS_PLATFORM_SHARED_CONTRACT.md).

## Requirements

- Windows 10 or Windows 11
- The Codex desktop app installed and in use, or Claude Code on macOS
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

There is no installer, and Agent Halo does not require an OpenAI API key. To
refresh usage independently, it reuses the existing Codex OAuth login. When an
OAuth token rotates, the original Codex `auth.json` is updated atomically.

## Controls

- Drag the halo to reposition it; it gently snaps to display edges.
- Hover to inspect the current state plus five-hour and weekly usage limits.
- Hover details include a `Codex / CC` switch. Agent Halo keeps watching both tools, while the halo color, status text, and quota rows follow the selected focused agent.
- The context pill displays context usage for the focused agent: Codex shows quota-based context usage, while Claude Code shows context window usage captured via status line proxy.
- Codex quota rows are Codex-only. When `CC` is focused, the hover panel shows Claude Code session state without Codex balance information.
- Completed green breathes until Codex returns to the foreground, then settles
  into a non-glowing standby green.
- Right-click for state previews, pause, startup, and exit controls.
- Use the `Halo Size` submenu to select `75% / 100% / 125%`;
  the selected size persists across restarts.
- On macOS, Agent Halo remembers the halo's display and relative position. If
  that display disconnects, the halo temporarily moves to the primary display's
  upper-right corner and returns when the display reconnects. Dragging it while
  temporarily recovered makes the new position preferred instead.
- Windows keeps its existing off-screen recovery behavior: after launch or a
  display change, a fully off-screen halo returns to the primary display.
- On either platform, select `Reset Position` from the context menu to explicitly
  reset the halo to the primary display's upper-right corner.
- Click the halo to bring the Codex window forward.

## Status language

- Amber long-bright/short-dim breathing: an agent is thinking or planning.
- Blue long-bright/short-dim breathing: an agent is running a command, search,
  edit, or tool.
- Green double flash: an agent finished, then breathes slowly until acknowledged.
- Coral double pulse: an agent is waiting for approval, confirmation, or input.
- Red: a blocking failure. It flashes while unseen, stays brightly lit when
  Codex is foregrounded, and becomes dim red after you leave.
- Stable green: a monitored agent is running with no active task.
- Dim white: no monitored agent activity is visible.

For the full motion, material, breathing, and Plan Mode rules, see
[Windows visual behavior](docs/WINDOWS_VISUAL_BEHAVIOR.md) and
[macOS visual behavior](docs/MACOS_VISUAL_BEHAVIOR.md). The shared state-machine
contract is documented in
[CROSS_PLATFORM_SHARED_CONTRACT.md](docs/CROSS_PLATFORM_SHARED_CONTRACT.md).

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

Agent Halo locally reads lifecycle events from `%USERPROFILE%\.codex\sessions`
and, on macOS, automatically configures Claude Code
lifecycle hooks and status line proxy in `~/.claude/settings.json`. It writes hook
events to `~/.agent-halo/claude-code-status.jsonl` and context snapshots to
`~/.agent-halo/claude-code-context.json`. It also performs read-only structured queries
against `logs_2.sqlite` for Codex connection and service failures.

To refresh Codex usage independently, Agent Halo reads the existing OAuth login and
makes HTTPS requests only to the official `auth.openai.com` and `chatgpt.com`
endpoints. OAuth tokens are never stored in Agent Halo's cache; rotated tokens are
written atomically back to the original Codex credential file. The usage cache stores
only an account hash, percentages, and reset times. Session content is not uploaded,
and OpenAI API keys are neither read nor stored.

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
