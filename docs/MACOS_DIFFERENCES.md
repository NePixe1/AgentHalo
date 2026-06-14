# macOS and Windows visual differences

Compared during version 0.12.0 shared-contract migration.

## Deliberate macOS additions

- The macOS renderer morphs ring radius, body width, gap opening, gap skew, and a
  secondary contour over time.
- Windows keeps a more stable tube geometry and concentrates motion in brightness,
  color, orbit speed, and the two moving gaps.
- macOS uses AppKit/Core Graphics at a fixed 60 Hz. Windows uses WPF and follows the
  desktop composition refresh rate.

## Behavior not yet equivalent

- macOS calculates `transitionProgress` but the renderer does not use it, so it does
  not implement the Windows dim, color blend, and power-up transition.
- macOS defines `coreWhite` and `glowGain`, but its renderer does not consume them.
- macOS always draws three colored bloom layers, including steady green; Windows
  steady green has no emitted glow.
- macOS does not implement the Windows completion double flash.
- macOS uses edge highlights and an optional secondary contour. Windows uses dark and
  lit tube materials plus a bright white core.
- The macOS halo context menu contains only Close Ring; full controls are in the menu
  bar. Windows exposes the full menu from both the halo and system tray.

## Shared behavior

- Generated enums, session rules, failure and action matching, colors, breathing
  parameters, orbit motion, gap separation, transition constants, and rate-limit
  scanning limits now come from `shared/spec/agent-halo.v2.json`.
- Shared fixtures and deterministic animation samples are checked in CI.

The migration does not intentionally change macOS visual behavior. Renderer-specific
ring morphing, bloom, highlights, and fixed refresh behavior remain native.
