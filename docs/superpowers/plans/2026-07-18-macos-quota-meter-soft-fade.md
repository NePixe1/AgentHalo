# macOS Quota Meter Soft Fade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS quota meter use `#406984` at 100% remaining and continuously fade through the approved soft palette as remaining quota decreases, without changing Windows or panel layout.

**Architecture:** Add one internal, main-actor-isolated `QuotaMeterPalette` to `DetailsPanel.swift`. It clamps remaining quota to `0...100`, linearly interpolates RGB values between five approved stops, and supplies the fill color used by the existing `RoundedMeterView.draw(_:)`; the existing geometry and zero-fill guard remain unchanged.

**Tech Stack:** Swift 6, AppKit (`NSColor`, `NSView`, `NSBezierPath`), SwiftPM executable self-checks.

## Global Constraints

- Modify only macOS quota meter code and macOS interaction checks; do not modify `src/windows`.
- Full quota color is exactly `#406984`.
- Approved color stops are 100% `#406984`, 75% `#527992`, 50% `#7094A9`, 25% `#A8BFCA`, and 0% `#CAD9E0`.
- Interpolate continuously in RGB space between adjacent stops after clamping input to `0...100`.
- Construct palette colors with `deviceRed` so the approved hexadecimal stops retain their exact deviceRGB bytes.
- Keep the meter width calculation, 4pt height, rounded geometry, background track color, panel sizing, quota parsing, reset text, and quota copy unchanged.
- At 0% remaining, retain the current early return so no fill is drawn.

---

## File Structure

- Modify `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`: own the approved palette, interpolation, and meter drawing integration.
- Modify `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`: pin exact palette stops, interpolation, clamping, and the relationship between remaining values and displayed meter values.
- Do not create a separate palette file: this behavior is private to the details-panel meter and does not justify a new production unit.

### Task 1: Add the soft-fade palette with test-first coverage

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift:16-102,856-876`
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift:802-831`

**Interfaces:**
- Consumes: `RoundedMeterView.value: Double`, where the value is the already-computed remaining percentage.
- Produces: `@MainActor enum QuotaMeterPalette` with `static func fillColor(for remainingPercent: Double) -> NSColor`.
- Preserves: `QuotaRowView.update(usedPercent:resetAt:)` and its existing `remaining = 100 - usedPercent` data flow.

- [ ] **Step 1: Write the failing palette checks**

Add `testQuotaMeterUsesApprovedSoftFadePalette()` beside the existing quota-panel checks and invoke it immediately after `testDetailsPanelShowsFiveHourAndWeeklyRemainingUsage()` in `runHaloInteractionChecks()`:

```swift
@MainActor
private func testQuotaMeterUsesApprovedSoftFadePalette() {
    expectQuotaColor(QuotaMeterPalette.fillColor(for: 100), red: 64, green: 105, blue: 132, "100% quota color")
    expectQuotaColor(QuotaMeterPalette.fillColor(for: 75), red: 82, green: 121, blue: 146, "75% quota color")
    expectQuotaColor(QuotaMeterPalette.fillColor(for: 50), red: 112, green: 148, blue: 169, "50% quota color")
    expectQuotaColor(QuotaMeterPalette.fillColor(for: 25), red: 168, green: 191, blue: 202, "25% quota color")
    expectQuotaColor(QuotaMeterPalette.fillColor(for: 0), red: 202, green: 217, blue: 224, "0% quota color")

    expectQuotaColor(QuotaMeterPalette.fillColor(for: 62.5), red: 97, green: 134.5, blue: 157.5, "interpolated quota color")
    expectQuotaColor(QuotaMeterPalette.fillColor(for: 120), red: 64, green: 105, blue: 132, "quota color upper clamp")
    expectQuotaColor(QuotaMeterPalette.fillColor(for: -20), red: 202, green: 217, blue: 224, "quota color lower clamp")

    let fuller = quotaColorBytes(QuotaMeterPalette.fillColor(for: 75))
    let lower = quotaColorBytes(QuotaMeterPalette.fillColor(for: 25))
    expect(lower.red >= fuller.red && lower.green >= fuller.green && lower.blue >= fuller.blue,
           "lower remaining quota should use a lighter RGB color")
}

@MainActor
private func expectQuotaColor(
    _ color: NSColor,
    red: Double,
    green: Double,
    blue: Double,
    _ message: String
) {
    let actual = quotaColorBytes(color)
    let tolerance = 0.001
    expect(abs(actual.red - red) < tolerance, "\(message) red")
    expect(abs(actual.green - green) < tolerance, "\(message) green")
    expect(abs(actual.blue - blue) < tolerance, "\(message) blue")
}

@MainActor
private func quotaColorBytes(_ color: NSColor) -> (red: Double, green: Double, blue: Double) {
    guard let rgb = color.usingColorSpace(.deviceRGB) else {
        fatalError("quota color should convert to device RGB")
    }
    return (
        Double(rgb.redComponent) * 255,
        Double(rgb.greenComponent) * 255,
        Double(rgb.blueComponent) * 255
    )
}
```

Keep the existing `testDetailsPanelShowsFiveHourAndWeeklyRemainingUsage()` assertions for meter values `70` and `40`; they prove the input remains “percentage remaining” rather than “percentage used.”

- [ ] **Step 2: Run the macOS self-check to verify the new check fails**

Run from `src/macos`:

```bash
swift run AgentHaloMac --self-check
```

Expected: compilation fails with `cannot find 'QuotaMeterPalette' in scope`. This confirms the regression check is exercising a production interface that does not exist yet.

- [ ] **Step 3: Implement the approved palette and interpolation**

Insert the following internal palette immediately before `RoundedMeterView` in `DetailsPanel.swift`:

```swift
@MainActor
enum QuotaMeterPalette {
    private struct Stop {
        let percent: Double
        let red: Double
        let green: Double
        let blue: Double
    }

    private static let stops = [
        Stop(percent: 0, red: 202, green: 217, blue: 224),
        Stop(percent: 25, red: 168, green: 191, blue: 202),
        Stop(percent: 50, red: 112, green: 148, blue: 169),
        Stop(percent: 75, red: 82, green: 121, blue: 146),
        Stop(percent: 100, red: 64, green: 105, blue: 132),
    ]

    static func fillColor(for remainingPercent: Double) -> NSColor {
        let clamped = min(100, max(0, remainingPercent))
        guard let upperIndex = stops.firstIndex(where: { clamped <= $0.percent }) else {
            return color(for: stops[stops.count - 1])
        }
        guard upperIndex > 0 else {
            return color(for: stops[0])
        }

        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let progress = (clamped - lower.percent) / (upper.percent - lower.percent)
        return NSColor(
            deviceRed: component(from: lower.red, to: upper.red, progress: progress),
            green: component(from: lower.green, to: upper.green, progress: progress),
            blue: component(from: lower.blue, to: upper.blue, progress: progress),
            alpha: 1
        )
    }

    private static func color(for stop: Stop) -> NSColor {
        NSColor(
            deviceRed: CGFloat(stop.red) / 255,
            green: CGFloat(stop.green) / 255,
            blue: CGFloat(stop.blue) / 255,
            alpha: 1
        )
    }

    private static func component(from start: Double, to end: Double, progress: Double) -> CGFloat {
        CGFloat(start + (end - start) * progress) / 255
    }
}
```

In `RoundedMeterView.draw(_:)`, replace only the fixed fill-color statement:

```swift
QuotaMeterPalette.fillColor(for: value).setFill()
```

Leave the background color, `rawFillWidth` calculation, `guard rawFillWidth > 0`, minimum visible fill width, and rounded path unchanged.

- [ ] **Step 4: Run focused macOS checks**

Run from `src/macos`:

```bash
swift run AgentHaloMac --self-check
```

Expected: exits 0 and prints the existing successful self-check completion message with no fatal error from the new palette assertions.

Then run:

```bash
swift build
```

Expected: exits 0 with `Build complete!`.

- [ ] **Step 5: Inspect the scoped diff**

Run from the repository root:

```bash
git diff --check
git diff -- src/macos/Sources/AgentHaloMac/DetailsPanel.swift src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git status --short
```

Expected: no whitespace errors; the source diff contains only the palette, the one draw-site replacement, and self-check coverage; no `src/windows` file appears.

- [ ] **Step 6: Commit the tested implementation**

```bash
git add src/macos/Sources/AgentHaloMac/DetailsPanel.swift src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "feat: fade macOS quota meter with remaining usage"
```

Expected: one commit containing only the two macOS files.

### Task 2: Verify core behavior and the packaged application

**Files:**
- Verify only: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`
- Verify only: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`
- Verify artifact: `outputs/AgentHalo-macOS/AgentHalo.app`

**Interfaces:**
- Consumes: `QuotaMeterPalette.fillColor(for:)` and `RoundedMeterView.draw(_:)` from Task 1.
- Produces: verification evidence for core checks, the staged production app, and platform scope.

- [ ] **Step 1: Run the core regression executable**

Run from `src/macos`:

```bash
swift run AgentHaloCoreChecks
```

Expected: exits 0 with all core checks passing; quota parsing and usage-window selection remain unchanged.

- [ ] **Step 2: Rebuild the staged macOS app**

Run from the repository root:

```bash
bash scripts/build-macos.sh
```

Expected: exits 0 and refreshes `outputs/AgentHalo-macOS/AgentHalo.app` from the current source.

- [ ] **Step 3: Run packaged verification**

Run from the repository root:

```bash
bash scripts/run-macos.sh --verify
```

Expected: exits 0 after launching the staged app in isolated verification mode and completing the packaged runtime checks.

- [ ] **Step 4: Verify the final rendered meter output**

The `AgentHaloMac --self-check` suite must render the real `RoundedMeterView.draw(_:)` path into a deterministic offscreen deviceRGB bitmap and inspect its pixels. Verify the approved fill colors, translucent track distinction, remaining-based width, 4pt height, rounded corners, and the absence of an opaque fill at 0%.

When UI automation can open the borderless hover panel, also run the staged app from the repository root for an optional visual companion check:

```bash
bash scripts/run-macos.sh run
```

Hover the halo to open the details panel and inspect the live quota row. Compare its displayed remaining percentage with the exact automated color stops from Task 1; capture a screenshot for handoff when possible. If automation cannot expand the borderless AppKit panel, the deterministic offscreen pixel check is the acceptance evidence rather than blocking verification.

Expected: the rendered bar is darker at higher remaining values and lighter at lower remaining values; it retains the existing 4pt height, rounded ends, background track, and remaining-based width. Exact 100%, 75%, 50%, and 25% RGB values remain enforced by the self-check even when the live account is not currently at those percentages.

- [ ] **Step 5: Prove Windows and layout scope remain unchanged**

Run from the repository root:

```bash
git diff d636934..HEAD --name-only
git status --short
```

Expected: implementation files are limited to `src/macos/Sources/AgentHaloMac/DetailsPanel.swift` and `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`; no `src/windows` file is listed. Ignored `.superpowers/` visual-companion files may remain and are not product changes.

No additional commit is required for this verification-only task.
