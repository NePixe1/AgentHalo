# Automatic Offscreen Recovery Design

## Goal

Keep the existing `脱离卡死（移到主屏右上角）` menu command as a manual fallback, while automatically recovering the halo when its saved window position is no longer visible after launch or a display-layout change.

## Behavior

- On application launch, validate the halo frame after the window has been created.
- Revalidate whenever the operating system reports a display-configuration change, including connecting, disconnecting, or rearranging displays.
- Treat the halo as off-screen only when its frame has no intersection with the usable area of any connected display.
- If the halo intersects any display's usable area, preserve its exact position. Automatic recovery must not move a deliberately edge-snapped or partially visible halo.
- If the halo is fully off-screen, move it to the existing default location at the primary display's upper-right corner and persist the recovered position.
- Keep the manual `脱离卡死` action unchanged so the user can force a reset even when automatic detection does not cover an unusual window-system state.

## Platform Integration

### macOS

Add one visibility-checking helper to `AppDelegate`. Call it immediately after the halo panel is created and from the application screen-parameter-change callback. Use `NSScreen.screens` and each screen's `visibleFrame` as the visibility source of truth. Reuse `defaultWindowOrigin(topOffset:)` and the existing settings save path when recovery is needed.

### Windows

Add the equivalent helper to `HaloWindow`. Call it after the WPF window has a presentation source and from the system display-settings change event. Compare the halo frame against every `Screen.WorkingArea`, converting coordinates consistently with the existing DPI-aware window-position helpers. Reuse `EscapeOffscreen()` for the actual recovery so manual and automatic placement remain identical. Unsubscribe from the system event when the window closes.

## Verification

- A saved frame wholly outside all connected displays is moved to the primary display and saved at launch.
- A frame on a disconnected secondary display is recovered after the display-change event.
- A frame wholly or partially inside any display's usable area is not moved.
- The existing manual menu item remains present and still moves the halo to the primary display.
- Run the macOS interaction self-checks and build, plus the Windows diagnostics/build checks available in the repository.

## Documentation

Update the English and Chinese README behavior notes to describe automatic recovery first and the existing menu command as the manual fallback.
