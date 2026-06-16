# Agent Halo cross-platform shared contract

Version 0.13.0 keeps two native applications and one generated behavior contract:

```text
src/shared/spec/agent-halo.v2.json
        |
        +--> src/windows/GeneratedHaloSpec.cs
        +--> src/macos/Sources/AgentHaloCore/GeneratedHaloSpec.swift
```

The JSON contract is the only editable source for shared state metadata, lifecycle
matching, action and failure rules, rate-limit paths, animation parameters, transition
timing, gap motion, and shared settings metadata. The native applications compile
generated source and do not load the JSON file at runtime.

## Ownership boundary

Shared:

- state names, labels, priority, colors, brightness, and motion parameters
- Codex lifecycle event matching
- tool action labels and blocking failure classification
- rate-limit JSON paths and scan limits
- deterministic animation and lifecycle test vectors

Windows-only:

- WPF window, tray menu, hit testing, multi-display recovery, and startup integration
- Windows foreground detection and tray-specific menu hosting

macOS-only:

- AppKit panels, menu bar integration, launch agent, and application activation
- macOS display-link rendering and native menu bar hosting

## Change workflow

1. Edit `src/shared/spec/agent-halo.v2.json`.
2. Run `python scripts/generate_shared.py`.
3. Run `python scripts/validate_schema.py` and `python scripts/check_shared.py`.
4. Run the Windows self-test and macOS `swift run AgentHaloCoreChecks`.
5. Commit the spec and both generated outputs together.

CI rejects stale generated files or fixture drift. Generated files must never be
edited manually.

## Compatibility

`contractVersion` changes only for incompatible schema or semantic changes.
`releaseVersion` follows the application release. Platform extension data may evolve
without requiring pixel-identical rendering across operating systems.

## Platform implementation differences

- macOS and Windows both use the dark/lit tube material, bright white core,
  dim/blend/power-up transitions, and completion double flash behavior.
- macOS uses `CVDisplayLink`; Windows uses WPF composition callbacks. Both
  advance animation from display timing and clamp frame delta to avoid jumps.
- macOS exposes the same control menu from the menu bar and halo right click.
  Windows exposes the same controls from its tray menu and halo right click.
- Platform-specific window, menu, startup, hit-testing, and display behavior
  remain native and intentionally separate.
