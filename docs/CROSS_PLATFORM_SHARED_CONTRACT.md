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
- dark/lit tube material, white core, and completion double flash rendering

macOS-only:

- AppKit panels, menu bar integration, launch agent, and application activation
- ring radius/width/gap morph, secondary contour, bloom, and edge highlights

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

## Platform rendering differences

- macOS morphs ring radius, body width, gap opening, gap skew, and a secondary
  contour. Windows keeps stable tube geometry and emphasizes brightness, color,
  orbit speed, and gap motion.
- macOS currently uses a fixed 60 Hz AppKit timer. Windows uses WPF composition
  callbacks and follows the desktop compositor when available.
- macOS has edge highlights, secondary contours, and persistent colored bloom.
  Windows uses dark/lit tube materials, a bright white core, and no emitted glow
  for steady green.
- Windows implements dim/blend/power-up transitions and completion double flash.
  These visual behaviors are not yet fully equivalent on macOS.
- Platform-specific window, menu, startup, hit-testing, and display behavior
  remain native and intentionally separate.
