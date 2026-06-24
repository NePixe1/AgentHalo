# macOS Display Position Restoration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS halo temporarily fall back to the primary display when its preferred display disconnects, restore it when that display reconnects, and preserve a new position chosen by the user during fallback.

**Architecture:** Persist a stable display UUID plus display-relative coordinates as the user's preferred placement while retaining existing absolute coordinates for migration. A pure macOS placement resolver converts stored preferences and display snapshots into either a resolved preferred frame or a temporary-fallback decision; `AppDelegate` owns only `NSScreen` conversion, panel movement, runtime fallback state, and persistence.

**Tech Stack:** Swift 6, AppKit, Core Graphics display UUID APIs, SwiftPM executable self-checks, JSON `Codable` settings.

---

## File Map

- Modify `src/macos/Sources/AgentHaloCore/HaloSettings.swift`: add optional preferred-display metadata with backward-compatible decoding.
- Modify `src/macos/Sources/AgentHaloCoreChecks/main.swift`: cover legacy decoding and preferred-placement round trips.
- Create `src/macos/Sources/AgentHaloMac/HaloPlacement.swift`: hold display snapshots, pure placement resolution/capture/clamping, stable screen identity, and temporary-fallback runtime state.
- Modify `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`: replace the incorrect partial-intersection contract with placement-state regression checks.
- Modify `src/macos/Sources/AgentHaloMac/AppDelegate.swift`: integrate preferred placement, temporary fallback, reconnection restoration, manual reset, size changes, and termination persistence.
- Modify `README.md` and `README.zh-CN.md`: document the new macOS-only behavior without changing Windows claims.

### Task 1: Persist preferred-display metadata compatibly

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/HaloSettings.swift:9-79`
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift:300-430,1822-1963`

- [ ] **Step 1: Write failing settings tests**

Add tests that decode a legacy object without the new keys and round-trip explicit placement metadata:

```swift
func testSettingsDefaultsPreferredDisplayPlacementForLegacyFiles() throws {
    let data = Data(#"{"hasPosition":true,"left":1800,"top":600}"#.utf8)
    let settings = try JSONDecoder().decode(HaloSettings.self, from: data)

    expect(settings.preferredDisplayUUID == nil, "legacy settings should not invent a display UUID")
    expect(settings.preferredDisplayOffsetX == nil, "legacy settings should not invent an x offset")
    expect(settings.preferredDisplayOffsetY == nil, "legacy settings should not invent a y offset")
}

func testSettingsPersistPreferredDisplayPlacement() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-display-placement-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let url = root.appendingPathComponent("settings.json")
    let store = SettingsStore(settingsURL: url)
    let settings = HaloSettings(
        hasPosition: true,
        left: 1800,
        top: 600,
        preferredDisplayUUID: "secondary-display",
        preferredDisplayOffsetX: 120,
        preferredDisplayOffsetY: 80
    )

    store.save(settings)
    let loaded = store.load()

    expect(loaded.preferredDisplayUUID, "secondary-display", "preferred display UUID")
    expect(loaded.preferredDisplayOffsetX, 120, "preferred display x offset")
    expect(loaded.preferredDisplayOffsetY, 80, "preferred display y offset")
}
```

Register both functions in the top-level check list.

- [ ] **Step 2: Run the core checks and verify RED**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

Expected: compilation fails because `HaloSettings` has no preferred-display properties or initializer parameters.

- [ ] **Step 3: Add optional settings fields**

Add these stored properties, coding keys, defaulted initializer parameters, assignments, and `decodeIfPresent` calls:

```swift
public var preferredDisplayUUID: String?
public var preferredDisplayOffsetX: Double?
public var preferredDisplayOffsetY: Double?
```

Use `nil` defaults so all existing initializer call sites and old JSON remain valid.

- [ ] **Step 4: Run the core checks and verify GREEN**

Run `swift run AgentHaloCoreChecks` from `src/macos`.

Expected: `PASS AgentHaloCore checks`.

- [ ] **Step 5: Commit the settings slice**

```bash
git add src/macos/Sources/AgentHaloCore/HaloSettings.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "feat: persist macOS preferred display placement"
```

### Task 2: Resolve preferred placement independently of the current sliver

**Files:**
- Create: `src/macos/Sources/AgentHaloMac/HaloPlacement.swift`
- Test: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift:17-80`

- [ ] **Step 1: Replace the partial-intersection check with failing placement tests**

Remove `testHaloFrameVisibilityAcrossScreens()` and its registration. Add focused tests for missing/reconnected displays, capture, clamping, legacy migration, and runtime fallback state:

```swift
@MainActor
private func testMissingPreferredDisplayRequiresFallbackDespiteCurrentSliver() {
    let primary = HaloDisplaySnapshot(
        identifier: "primary",
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
    )
    let preference = HaloStoredPlacement(
        displayIdentifier: "secondary",
        absoluteOrigin: NSPoint(x: 1900, y: 600),
        relativeOffset: NSPoint(x: 100, y: 80)
    )

    expect(
        HaloPlacementResolver.resolve(preference, haloSize: 112, displays: [primary]) == nil,
        "a missing preferred display should require fallback even if macOS moved a sliver onscreen"
    )
}

@MainActor
private func testReconnectedPreferredDisplayRestoresRelativePlacement() {
    let secondary = HaloDisplaySnapshot(
        identifier: "secondary",
        visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1080)
    )
    let preference = HaloStoredPlacement(
        displayIdentifier: "secondary",
        absoluteOrigin: NSPoint(x: 1900, y: 600),
        relativeOffset: NSPoint(x: 100, y: 80)
    )

    let resolved = HaloPlacementResolver.resolve(preference, haloSize: 112, displays: [secondary])

    expect(resolved?.origin, NSPoint(x: 1540, y: 80), "reconnected display origin")
    expect(resolved?.display.identifier, "secondary", "reconnected display identity")
}

@MainActor
private func testUserMoveDuringFallbackReplacesOldDisplayPreference() {
    let primary = HaloDisplaySnapshot(
        identifier: "primary",
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
    )
    let secondary = HaloDisplaySnapshot(
        identifier: "secondary",
        visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1080)
    )
    let movedFrame = NSRect(x: 1100, y: 700, width: 112, height: 112)

    let captured = HaloPlacementResolver.capture(frame: movedFrame, displays: [primary, secondary])
    let restored = captured.flatMap {
        HaloPlacementResolver.resolve($0, haloSize: 112, displays: [primary, secondary])
    }

    expect(captured?.displayIdentifier, "primary", "user move should choose the primary display")
    expect(restored?.origin, movedFrame.origin, "reconnection should retain the new user position")
}

@MainActor
private func testLegacyPlacementWaitsForItsDisplayAndThenMigrates() {
    let primary = HaloDisplaySnapshot(
        identifier: "primary",
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
    )
    let secondary = HaloDisplaySnapshot(
        identifier: "secondary",
        visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1080)
    )
    let legacy = HaloStoredPlacement(
        displayIdentifier: nil,
        absoluteOrigin: NSPoint(x: 1800, y: 600),
        relativeOffset: nil
    )

    expect(
        HaloPlacementResolver.resolve(legacy, haloSize: 112, displays: [primary]) == nil,
        "unmatched legacy coordinates should remain pending"
    )
    let migrated = HaloPlacementResolver.resolve(legacy, haloSize: 112, displays: [primary, secondary])
    expect(migrated?.display.identifier, "secondary", "legacy coordinates should bind after reconnect")
    expect(migrated?.relativeOffset, NSPoint(x: 360, y: 600), "legacy relative offset")
}

@MainActor
private func testRestoredPlacementClampsInsideChangedVisibleFrame() {
    let display = HaloDisplaySnapshot(
        identifier: "secondary",
        visibleFrame: NSRect(x: 100, y: 50, width: 800, height: 600)
    )
    let preference = HaloStoredPlacement(
        displayIdentifier: "secondary",
        absoluteOrigin: .zero,
        relativeOffset: NSPoint(x: 900, y: 700)
    )

    let resolved = HaloPlacementResolver.resolve(preference, haloSize: 112, displays: [display])
    expect(resolved?.origin, NSPoint(x: 788, y: 538), "restored frame should fit the usable area")
}

@MainActor
private func testTemporaryFallbackStateProtectsPreferredPlacementUntilUserMove() {
    var state = HaloPlacementRuntimeState()
    state.didUseTemporaryFallback()
    expect(!state.shouldPersistCurrentFrame, "untouched fallback must not overwrite preferred placement")

    state.didChoosePlacement()
    expect(state.shouldPersistCurrentFrame, "user movement should make the new placement persistent")
    expect(!state.isUsingTemporaryFallback, "user movement should cancel pending restoration")
}
```

Register all six tests in `runHaloInteractionChecks()`.

- [ ] **Step 2: Run the macOS checks and verify RED**

Run:

```bash
cd src/macos
swift run AgentHaloMac --self-check
```

Expected: compilation fails because the placement types do not exist.

- [ ] **Step 3: Implement the pure placement model**

Create `HaloPlacement.swift` with these interfaces and behavior:

```swift
import AppKit
import CoreGraphics

struct HaloDisplaySnapshot: Equatable {
    let identifier: String
    let visibleFrame: NSRect
}

struct HaloStoredPlacement: Equatable {
    var displayIdentifier: String?
    var absoluteOrigin: NSPoint
    var relativeOffset: NSPoint?
}

struct HaloResolvedPlacement: Equatable {
    let display: HaloDisplaySnapshot
    let origin: NSPoint
    let relativeOffset: NSPoint
}

enum HaloPlacementResolver {
    static func resolve(
        _ placement: HaloStoredPlacement,
        haloSize: CGFloat,
        displays: [HaloDisplaySnapshot]
    ) -> HaloResolvedPlacement? {
        let display: HaloDisplaySnapshot
        let desiredOrigin: NSPoint

        if let identifier = placement.displayIdentifier {
            guard let match = displays.first(where: { $0.identifier == identifier }) else {
                return nil
            }
            display = match
            if let offset = placement.relativeOffset {
                desiredOrigin = NSPoint(
                    x: display.visibleFrame.minX + offset.x,
                    y: display.visibleFrame.minY + offset.y
                )
            } else {
                desiredOrigin = placement.absoluteOrigin
            }
        } else {
            let center = NSPoint(
                x: placement.absoluteOrigin.x + haloSize / 2,
                y: placement.absoluteOrigin.y + haloSize / 2
            )
            guard let match = displays.first(where: { $0.visibleFrame.contains(center) }) else {
                return nil
            }
            display = match
            desiredOrigin = placement.absoluteOrigin
        }

        let origin = clampedOrigin(desiredOrigin, haloSize: haloSize, inside: display.visibleFrame)
        return HaloResolvedPlacement(
            display: display,
            origin: origin,
            relativeOffset: NSPoint(
                x: origin.x - display.visibleFrame.minX,
                y: origin.y - display.visibleFrame.minY
            )
        )
    }

    static func capture(
        frame: NSRect,
        displays: [HaloDisplaySnapshot]
    ) -> HaloStoredPlacement? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let display = displays.first(where: { $0.visibleFrame.contains(center) })
            ?? displays.max { lhs, rhs in
                lhs.visibleFrame.intersection(frame).area < rhs.visibleFrame.intersection(frame).area
            }
        guard let display, display.visibleFrame.intersects(frame) else { return nil }
        return HaloStoredPlacement(
            displayIdentifier: display.identifier,
            absoluteOrigin: frame.origin,
            relativeOffset: NSPoint(
                x: frame.minX - display.visibleFrame.minX,
                y: frame.minY - display.visibleFrame.minY
            )
        )
    }

    static func clampedOrigin(
        _ origin: NSPoint,
        haloSize: CGFloat,
        inside visibleFrame: NSRect
    ) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - haloSize),
            y: min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - haloSize)
        )
    }
}

struct HaloPlacementRuntimeState {
    private(set) var isUsingTemporaryFallback = false
    var shouldPersistCurrentFrame: Bool { !isUsingTemporaryFallback }

    mutating func didUseTemporaryFallback() {
        isUsingTemporaryFallback = true
    }

    mutating func didApplyPreferredPlacement() {
        isUsingTemporaryFallback = false
    }

    mutating func didChoosePlacement() {
        isUsingTemporaryFallback = false
    }
}
```

Add a private `NSRect.area` helper if the SDK does not expose one. Add `HaloScreenIdentity.identifier(for:)` in the same file, reading `NSScreenNumber`, calling `CGDisplayCreateUUIDFromDisplayID`, and returning the UUID string. A transient numeric fallback identifier is acceptable only when UUID creation fails; prefix it so it cannot collide with UUID strings.

- [ ] **Step 4: Run the macOS checks and verify GREEN**

Run `swift run AgentHaloMac --self-check` from `src/macos`.

Expected: `PASS AgentHaloMac checks`.

- [ ] **Step 5: Commit the pure placement slice**

```bash
git add src/macos/Sources/AgentHaloMac/HaloPlacement.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "feat: resolve macOS halo placement by display"
```

### Task 3: Integrate temporary fallback and reconnection restoration

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift:15-86,131-165,224-235,292-310,358-395`
- Test: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

- [ ] **Step 1: Add a failing source-wiring regression check**

Add a focused check using the existing source-inspection style in `HaloInteractionChecks.swift` to require all integration boundaries:

```swift
@MainActor
private func testDisplayRecoveryWiresPreferredPlacementWithoutPersistingFallback() {
    let source = try! String(contentsOf: appDelegateSourceURL(), encoding: .utf8)
    expect(source.contains("placementState.didUseTemporaryFallback()"), "display loss should enter temporary fallback")
    expect(source.contains("placementState.didApplyPreferredPlacement()"), "display return should leave temporary fallback")
    expect(source.contains("commitPreferredPlacement(frame:)"), "user movement should commit preferred placement")
    expect(source.contains("placementState.shouldPersistCurrentFrame"), "termination should protect fallback coordinates")
}
```

If no shared source URL helper exists, add a local helper that resolves `AppDelegate.swift` relative to `#filePath`, following the existing source-inspection tests in this file.

- [ ] **Step 2: Run the macOS checks and verify RED**

Run `swift run AgentHaloMac --self-check`.

Expected: failure mentioning missing temporary-fallback or preferred-placement wiring.

- [ ] **Step 3: Replace one-way recovery with preferred-placement reconciliation**

In `AppDelegate`:

1. Add `private var placementState = HaloPlacementRuntimeState()`.
2. Convert `NSScreen.screens` to `[HaloDisplaySnapshot]` with stable identifiers.
3. Build `HaloStoredPlacement` from `HaloSettings`.
4. Replace `recoverHaloIfOffscreen()` with `reconcileHaloPlacement()`:
   - resolve the stored preference against current displays;
   - when resolved, move to the resolved origin, refresh absolute/relative metadata, save, and call `didApplyPreferredPlacement()`;
   - when unresolved, move to the primary default without writing placement settings and call `didUseTemporaryFallback()`.
5. Call reconciliation after panel creation and from `applicationDidChangeScreenParameters`.
6. Replace the drag callback body with `commitPreferredPlacement(frame:)`, which captures the current display, writes absolute/relative metadata, calls `didChoosePlacement()`, and saves.
7. Make manual `escapeOffscreen()` move to the primary default and then call `commitPreferredPlacement(frame:)`, so it remains an explicit reset.
8. During termination, update the current frame only when `placementState.shouldPersistCurrentFrame`; always save the existing settings object.
9. During halo-size changes, do not update preferred position metadata while temporarily recovered; otherwise recapture the resized frame before scheduling the save.
10. Delete `isHaloFrameVisible` and the old intersection-based recovery path.

Use a helper with this storage contract:

```swift
private func storeResolvedPlacement(_ resolved: HaloResolvedPlacement) {
    settings.hasPosition = true
    settings.left = resolved.origin.x
    settings.top = resolved.origin.y
    settings.preferredDisplayUUID = resolved.display.identifier
    settings.preferredDisplayOffsetX = resolved.relativeOffset.x
    settings.preferredDisplayOffsetY = resolved.relativeOffset.y
}
```

The temporary fallback helper must only call `panel.setFrameOrigin(defaultWindowOrigin(topOffset: 28))`; it must not mutate `settings.left`, `settings.top`, or preferred-display fields.

- [ ] **Step 4: Run focused checks and verify GREEN**

Run:

```bash
cd src/macos
swift run AgentHaloMac --self-check
swift run AgentHaloCoreChecks
```

Expected: both commands print their `PASS` lines.

- [ ] **Step 5: Commit the AppDelegate integration**

```bash
git add src/macos/Sources/AgentHaloMac/AppDelegate.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "fix: restore macOS halo after display reconnect"
```

### Task 4: Document the macOS-only behavior

**Files:**
- Modify: `README.md:71-75`
- Modify: `README.zh-CN.md:66-70`

- [ ] **Step 1: Update the platform-specific wording**

Replace the single generic sentence with wording that says:

- macOS remembers the preferred display and relative position, temporarily uses the primary upper-right corner while that display is absent, restores on reconnect, and treats a drag during fallback as the new preferred placement;
- Windows retains its existing fully-off-screen automatic recovery behavior;
- `脱离卡死` remains the explicit manual reset on both platforms.

- [ ] **Step 2: Check the documentation diff**

Run:

```bash
git diff --check
git diff -- README.md README.zh-CN.md
```

Expected: no whitespace errors and no claim that Windows restores a reconnected display position.

- [ ] **Step 3: Commit documentation**

```bash
git add README.md README.zh-CN.md
git commit -m "docs: explain macOS display position restoration"
```

### Task 5: Verify the complete macOS artifact

**Files:**
- Verify only; modify earlier files only if a check exposes a regression.

- [ ] **Step 1: Run macOS checks serially**

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
```

Expected: both check executables print `PASS` and `swift build` exits 0.

- [ ] **Step 2: Run shared-contract validation**

From the repository root:

```bash
python3 scripts/validate_schema.py
python3 scripts/generate_shared.py --check
python3 scripts/check_shared.py
```

Expected: all commands exit 0 with no generated drift.

- [ ] **Step 3: Build the staged macOS application**

```bash
bash scripts/build-macos.sh
```

Expected: exit 0 and a fresh `outputs/AgentHalo-macOS/AgentHalo.app`.

- [ ] **Step 4: Verify the staged bundle**

```bash
bash scripts/run-macos.sh --verify
```

Expected: bundle verification succeeds for `outputs/AgentHalo-macOS/AgentHalo.app`.

- [ ] **Step 5: Inspect final scope**

```bash
git status --short
git diff HEAD~4 --stat
git diff HEAD~4 -- src/windows
```

Expected: no Windows changes, no uncommitted files, and only the planned macOS/settings/tests/docs files changed.
