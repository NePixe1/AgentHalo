# AGENTS.md

## UI design principle

The entire UI must stay **minimal and refined** : ambient-first, low visual noise, restrained typography and chrome, no decorative clutter. Prefer calm density over busy panels; do not invent extra rows, badges, or copy that break the premium quiet aesthetic. Details panels, menus, and hover surfaces should match the halo itself—readable at a glance, never loud.

## Documentation boundaries

| Document | Audience and scope |
| --- | --- |
| `README.md` / `README.zh-CN.md` | Product overview, supported platforms, installation, everyday use, privacy, troubleshooting |
| `AGENTS.md` | Architecture, runtime layout, source builds, diagnostics, implementation constraints, contributor checks |
| `docs/` | Product intent, detailed visual behavior, cross-platform contracts, design records, implementation plans |

Keep end-user behavior in the README, but move commands, internal paths, generated-source rules, and implementation detail here or into `docs/`.

## Product intent

Agent Halo is a local, always-on-top desktop status ring for coding agents. Windows and macOS support Codex, Claude Code, and Grok Build. Ambient first: readable in peripheral vision; honest lifecycle inference; privacy-first (no session upload). Product framing: [docs/PRODUCT.md](docs/PRODUCT.md).

## Architecture

Cross-platform **behavior parameters** come from a single contract:

| Path | Role |
| --- | --- |
| [`src/shared/spec/agent-halo.v2.json`](src/shared/spec/agent-halo.v2.json) | Canonical shared behavior (states, lifecycle, animation, settings surface) |
| [`src/shared/spec/agent-halo.v2.schema.json`](src/shared/spec/agent-halo.v2.schema.json) | Schema validation |
| [`src/shared/README.md`](src/shared/README.md) | Generate / check workflow |
| [`docs/CROSS_PLATFORM_SHARED_CONTRACT.md`](docs/CROSS_PLATFORM_SHARED_CONTRACT.md) | Architecture notes |

Platform **rendering and OS integration stay native**:

- Windows: C# / .NET under `src/windows/`
- macOS: Swift under `src/macos/`

Generated constants (committed; do not edit by hand):

- `src/windows/GeneratedHaloSpec.cs`
- `src/macos/Sources/AgentHaloCore/GeneratedHaloSpec.swift`

Apps compile generated source; they do **not** load the JSON contract at runtime.

### Shared generate / verify

```bash
python scripts/generate_shared.py
python scripts/generate_shared.py --check
python scripts/check_shared.py
```

CI installs `scripts/requirements-ci.in` and validates the schema. Fixtures under `src/shared/fixtures/` and `src/shared/expected/` cover lifecycle reduction, failure classification, rate limits, and deterministic animation samples.

## Repository map

```
src/shared/          # contract, locales, fixtures, agent-switch assets
src/windows/         # Windows app + monitors
src/macos/           # Swift package: AgentHaloMac, AgentHaloCore, hooks, diagnostics
scripts/             # generate_shared, run-macos, build-*, CI helpers
docs/                # product, visual behavior, cross-platform contract, design/plans
assets/              # banner / icons for docs and packaging
outputs/             # local build artifacts (not source of truth for releases)
```

## Runtime data layout

User-home `.agent-halo` (shared layout):

| Path | Purpose |
| --- | --- |
| `bin/` | Staged hook binaries (`status-hook` / `statusline-proxy` on macOS; `status-hook.exe` on Windows) |
| `state/` | Small durable state (e.g. chained statusline command on macOS) |
| `logs/` | Recent lifecycle events (`claude-status.jsonl`, `grok-status.jsonl`; rotated) |
| `cache/` | Disposable cache (Claude context snapshots, usage snapshots) |

Platform extras:

- **Windows** app settings + `halo.log`: `%LOCALAPPDATA%\CodexHalo\`
- **Windows** usage snapshots: `.agent-halo\cache\`
- **Windows** Claude hook host: on launch, the current `AgentHalo.exe` is atomically staged as `%USERPROFILE%\.agent-halo\bin\status-hook.exe`; hooks invoke `status-hook.exe --claude-hook <event>` (not a separate download)
- **macOS** Claude: lifecycle hooks + status line proxy in `~/.claude/settings.json`
- **macOS** Grok: lifecycle hooks in `~/.grok/hooks/agent-halo-status.json`

## Privacy / network (implementation constraints)

- Lifecycle and session content stay local; no session upload.
- OpenAI API keys are neither read nor stored by Agent Halo.
- Codex usage refresh reuses existing OAuth; HTTPS only to official `auth.openai.com` and `chatgpt.com`.
- OAuth tokens are not stored in Agent Halo cache; rotations write atomically back to the original Codex credential file.
- Usage cache holds account hash, percentages, and reset times only.
- Custom API / CCSwitch UI must never show API keys, base URLs, or relay tool names.
- Official Codex quota rows only in OAuth mode; custom API and CC views use the same fixed-height info rows without fake official quotas.

## Visual / motion contract (implementation)

User-facing color meanings: README. Full motion, material, breathing, Plan Mode:

- [docs/WINDOWS_VISUAL_BEHAVIOR.md](docs/WINDOWS_VISUAL_BEHAVIOR.md)
- [docs/MACOS_VISUAL_BEHAVIOR.md](docs/MACOS_VISUAL_BEHAVIOR.md)
- Shared state machine: [docs/CROSS_PLATFORM_SHARED_CONTRACT.md](docs/CROSS_PLATFORM_SHARED_CONTRACT.md)

Implementation notes (do not dump into user README):

- Large gap chases a small gap that drifts; near ~40° separation the small gap is repelled toward ~150°, then coasts with decaying momentum before bounded drift resumes.
- Thinking / working accelerate orbit; ring body powers from dim material to a bright white core with state color on the tube edge; narrow bloom; transparent center.
- Asymmetric continuous breathing for thinking, execution, completion; state changes dim, blend, then power up.
- Repulsion duration and exit momentum scale with current orbit speed.
- Animation tracks desktop composition refresh rate; do not drop idle/completed to 30 FPS.
- Monitoring pause is **runtime-only** and clears on next launch.
- Blue stays visible ~1.8s after a tool returns so short tool calls remain readable.
- Windows: off-screen recovery after launch / display change → primary upper-right.
- macOS: remembers display + relative position; disconnect temporarily uses primary upper-right; reconnect restores unless user dragged during temporary recovery (then new position is preferred).
- Both: context menu **Reset Position** → primary upper-right.

## macOS development

Menu bar accessory app (no Dock icon). Quit via menu bar, or:

```bash
pkill -x AgentHaloMac
```

Run and verify:

```bash
bash ./scripts/run-macos.sh --verify
```

Diagnostics:

```bash
cd src/macos
swift run AgentHaloDiagnostics --self-test /tmp/agent-halo-self-test.txt
swift run AgentHaloDiagnostics --render-states /tmp/agent-halo-states
swift run AgentHaloDiagnostics --transition-strip /tmp/agent-halo-transitions
```

Related scripts: `scripts/build-macos.sh`, `scripts/create-dmg.sh`. Packaged app for local verification often lands under `outputs/AgentHalo-macOS/AgentHalo.app`.

## Windows development

- Target: .NET Framework 4.8 (WPF + WinForms references via `csc.exe`), Windows 10/11.
- Build from repo root on a Windows machine:

```powershell
.\scripts\build-windows.ps1
```

- Compiler: `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe` (must exist).
- Output: `outputs\AgentHalo\AgentHalo.exe` (locales are copied from `src/shared/locales` into the Windows tree before compile).
- Diagnostics after build, for example:

```powershell
.\outputs\AgentHalo\AgentHalo.exe --self-test $env:TEMP\agent-halo-self-test.txt
```

- Unsigned personal builds may hit SmartScreen; release zips ship `SHA256.txt` for verification.

## UI / product constraints worth preserving

- Hover details: focus switch + usage vs session detail modes by credential type.
- Context pill: Codex quota-based context; Claude via status line proxy; Grok prefers live `totalTokens` from session `updates.jsonl` (fallback end-of-turn `signals.json`).
- Click halo: bring Codex window forward when relevant (Claude focus does not invent a Claude desktop app activate path).
- Halo size submenu: `75% / 100% / 125%`, persisted.
- No pets, chat body content, cost meter, or cloud backend for lifecycle.

## When changing behavior

1. Prefer updating `src/shared/spec/agent-halo.v2.json` for shared parameters, then regenerate and check.
2. Keep platform-only material/morph under `platformExtensions` or native code.
3. Update visual docs if user-visible motion/color meaning changes.
4. Keep README user-facing; put new contributor detail here or under `docs/`.
