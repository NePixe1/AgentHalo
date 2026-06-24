# macOS Display Position Restoration Design

## Goal

Make the macOS halo recover correctly when its preferred display disconnects and restore its prior placement when that display reconnects, without overriding a new position explicitly chosen by the user while the display is absent.

This change is macOS-only. The Windows implementation and behavior remain unchanged.

## Confirmed Root Causes

The current macOS recovery has two independent defects:

1. `isHaloFrameVisible` treats any rectangle intersection as visible. After macOS moves a window from a disconnected display so that only a small sliver overlaps the primary display, automatic recovery returns early instead of placing the halo at the primary display's normal upper-right location. The existing interaction check explicitly preserves this partial-intersection behavior.
2. Display-change handling is one-way. It can move an off-screen halo to the primary display, but it does not retain display ownership or attempt to restore a preferred placement when that display reconnects. The recovery path also writes the fallback coordinates into `HaloSettings`, destroying the previous secondary-display coordinates. Application termination can overwrite them again with the temporary fallback frame.

## Placement Model

Treat the saved halo placement as the user's **preferred placement**, not necessarily the panel's current temporary frame.

A preferred placement contains:

- a stable display identifier derived from the Core Graphics display UUID;
- the halo origin relative to that display's `visibleFrame`;
- the existing absolute `left` and `top` coordinates for backward compatibility and legacy migration.

The runtime also tracks whether the panel is in a **temporary primary-display fallback**. Moving to a fallback changes the panel frame only; it does not replace the preferred placement.

## Display Identity

For each `NSScreen`, obtain its Core Graphics display ID from `deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`, then derive a stable UUID with `CGDisplayCreateUUIDFromDisplayID`.

Do not use `NSScreen.localizedName` or the transient numeric display ID as persisted identity. Persisting a UUID allows the same physical display to be recognized after disconnecting and reconnecting.

## Behavior

### Normal launch and connected displays

- If the preferred display is connected, reconstruct the halo origin from that display's current `visibleFrame` and the saved relative offset.
- Clamp the reconstructed frame inside the display's usable area if its resolution, scaling, Dock, menu bar, or arrangement changed.
- If legacy settings have only absolute coordinates, associate them with the display that contains the saved halo center, persist the upgraded placement, and continue normally.

### Preferred display disconnects

- On `applicationDidChangeScreenParameters`, identify whether the preferred display still exists.
- If it is absent, move the panel to the existing default upper-right position on the primary display and mark the panel as temporarily recovered.
- This decision is based on preferred-display availability, not on whether macOS has left a small part of the current panel intersecting the primary display.
- Do not write fallback coordinates into the preferred placement.

### Preferred display reconnects

- While temporarily recovered, re-check display availability after every display-parameter change.
- If the preferred display UUID returns, reconstruct and clamp the preferred frame on that display, move the halo there, and clear the temporary-recovery state.

### User movement during temporary recovery

- A completed halo drag is explicit user intent.
- Save the new placement against the display containing the halo center and clear temporary recovery.
- Reconnecting the old secondary display must not move the halo after this point.

### Manual `脱离卡死`

- Keep the existing menu item.
- Treat it as an explicit reset: move to the primary display's default upper-right position, save that as the new preferred placement, and clear temporary recovery.

### Application termination

- If the panel is temporarily recovered and the user has not moved it, do not overwrite the preferred placement with the fallback frame.
- Otherwise persist the current user-selected placement as usual.

This preserves restoration across quitting and relaunching while the preferred display remains disconnected.

## Legacy Settings

New placement fields are optional so existing `settings.json` files continue to decode.

- If legacy absolute coordinates belong to a currently connected display, upgrade them to a display UUID and relative offset.
- If they do not belong to any connected display, preserve the absolute coordinates as a pending legacy preference and use the primary-display fallback without overwriting them.
- When a later display change makes those coordinates valid again, associate them with that display and complete the migration.
- Coordinates already overwritten by an older AgentHalo build cannot be reconstructed. The user must place the halo on the desired display once to establish a new preferred placement.

## Code Structure

Keep geometry and state decisions testable without live displays:

- Add a small value type describing a display UUID and usable frame.
- Add pure helpers that resolve a preferred placement, detect missing displays, reconstruct a frame, clamp it, and decide between preferred placement and temporary fallback.
- Keep `AppDelegate` responsible only for converting `NSScreen` values into descriptors, applying the selected frame, and persisting user intent.
- Extend `HaloSettings` only with the optional macOS placement metadata required for migration and restoration.

No unrelated window, hover, animation, or status behavior changes are in scope.

## Tests

Use test-first development and verify each failure before implementation:

1. A missing preferred display triggers primary fallback even if the current panel has a small intersection with the primary display.
2. Temporary fallback does not overwrite preferred coordinates.
3. Reconnecting the preferred display restores its relative placement.
4. A user drag during fallback stores the new display placement and cancels restoration.
5. Manual `脱离卡死` replaces the preferred placement with the primary-display default.
6. Termination during untouched fallback preserves the preferred placement.
7. Legacy absolute settings migrate when their display is available and remain pending otherwise.
8. Reconstructed frames are clamped inside a resized or rearranged display's `visibleFrame`.

Run the macOS interaction self-checks, core checks, Swift build, shared-contract checks, and staged macOS app build. Verify the resulting `outputs/AgentHalo-macOS/AgentHalo.app`, not only SwiftPM build artifacts.

## Documentation

Update the macOS behavior wording in the English and Chinese README files to distinguish temporary primary-display fallback from preferred-display restoration. Do not claim that Windows gained the new restoration behavior.
