# macOS Zero-Visual-Change CPU Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce AgentHalo macOS continuous CPU use without changing any ring frame, animation cadence, geometry, color, opacity, or transition timing.

**Architecture:** Preserve the current `HaloView -> HaloRenderer -> CAShapeLayer` per-frame pipeline and build deterministic model/pixel guards around it. Remove LaunchServices queries from the 0.3-second tick by maintaining event-driven Codex running/foreground state, then remove redundant redraw and constant layer-property assignments while keeping all dynamic layer properties updated every frame.

**Tech Stack:** Swift 6, AppKit, Core Animation, Core Graphics, SwiftPM, existing `AgentHaloMac --self-check` harness.

## Global Constraints

- Keep active animation at exactly `1.0 / 60.0` seconds and low-power animation at exactly `1.0 / 30.0` seconds.
- Do not modify `HaloMath`, `HaloVisualModel`, state transitions, transition durations, ring geometry, colors, opacity, glow ordering, gap sizes, or gap trajectories.
- Continue rebuilding and submitting the current `CGPath` on every animation frame.
- Do not introduce parent-layer rotation, Metal rendering, path decimation, implicit Core Animation, or frame-rate reduction.
- macOS only; do not modify `src/windows`.
- A visual-equivalence failure rejects the optimization that caused it.

---

### Task 1: Lock the Current Runtime Ring Output

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`
- Reference: `src/macos/Sources/AgentHaloMac/HaloRenderer.swift`
- Reference: `src/macos/Sources/AgentHaloMac/HaloView.swift`

**Interfaces:**
- Consumes: `HaloRenderer.applyRingLayers(_:bounds:input:)`, `HaloRenderInput`, `HaloState`, `CAShapeLayer`.
- Produces: `testRuntimeRingLayerPixelsMatchBaseline()` and `testRuntimeRingLayerModelMatchesVisualModel()` in the existing self-check harness.

- [ ] **Step 1: Add a deterministic CAShapeLayer pixel digest helper and an intentionally unrecorded baseline**

Add self-check-only helpers that create a transparent root `CALayer`, add exactly `HaloRenderer.ringLayerCount` shape layers with the same constant setup as `HaloView`, call `HaloRenderer.applyRingLayers`, render into an 8-bit RGBA bitmap at 1x and 2x, and return a stable FNV-1a 64-bit digest.

```swift
private func ringPixelDigest(
    input: HaloRenderInput,
    scale: CGFloat
) -> UInt64 {
    let size = CGSize(width: 112, height: 112)
    let root = CALayer()
    root.bounds = CGRect(origin: .zero, size: size)
    root.anchorPoint = .zero
    root.position = .zero
    let layers = (0..<HaloRenderer.ringLayerCount).map { _ in
        let layer = CAShapeLayer()
        layer.fillColor = NSColor.clear.cgColor
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.frame = root.bounds
        layer.contentsScale = scale
        root.addSublayer(layer)
        return layer
    }
    HaloRenderer.applyRingLayers(layers, bounds: root.bounds, input: input)

    let width = Int(size.width * scale)
    let height = Int(size.height * scale)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(
            data: bytes.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: scale, y: scale)
        root.render(in: context)
    }
    return pixels.reduce(1_469_598_103_934_665_603) { hash, byte in
        (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
}
```

Register a test that covers idle, thinking, working, done, error, steady done, and answer streaming at representative transition/flash timestamps. Set expected digest values to zero for the first run so the test prints the actual values.

- [ ] **Step 2: Run the self-check to capture the baseline failure**

Run: `cd src/macos && swift run AgentHaloMac --self-check`

Expected: FAIL only in `testRuntimeRingLayerPixelsMatchBaseline`, with actual nonzero 1x/2x digests for every scenario.

- [ ] **Step 3: Record the current digests and add exact layer-model assertions**

Replace zero values with the observed digests. Add model assertions for all eight layers:

```swift
expect(layers.count == HaloRenderer.ringLayerCount, "runtime ring must keep eight layers")
for layer in layers {
    expect(layer.frame == bounds, "every runtime ring layer must match HaloView bounds")
    expect(layer.path != nil, "every runtime ring layer must receive the current path")
    expect(layer.fillColor == NSColor.clear.cgColor, "ring fill must stay transparent")
    expect(layer.lineCap == .round, "ring line caps must stay round")
    expect(layer.lineJoin == .round, "ring line joins must stay round")
}
```

For each scenario, recompute target/transition/material values through the unchanged `HaloVisualModel` and assert the eight `lineWidth` and `strokeColor` values exactly equal the current renderer contract.

- [ ] **Step 4: Run the guard and full core checks**

Run: `cd src/macos && swift run AgentHaloMac --self-check && swift run AgentHaloCoreChecks`

Expected: PASS with no visual-baseline or model assertion failures.

- [ ] **Step 5: Commit the visual guard**

```bash
git add src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "test: lock macOS runtime ring output"
```

---

### Task 2: Make Codex Application State Event-Driven

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/CodexAppDetector.swift`
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

**Interfaces:**
- Consumes: `NSWorkspace` launch, terminate, activate, and active-Space notifications.
- Produces: `CodexAppDetector.noteApplicationDidLaunch(_:)`, `noteApplicationDidTerminate(_:)`, `isCodexForeground(_:)`; cached `AppDelegate.codexIsForeground`.

- [ ] **Step 1: Write failing application-state source and behavior checks**

Add checks requiring:

```swift
expect(detectorSource.contains("noteApplicationDidLaunch"), "Codex launch events should update the running cache")
expect(detectorSource.contains("noteApplicationDidTerminate"), "Codex termination should invalidate the running cache")
expect(detectorSource.contains("static func isCodexForeground(_ app: NSRunningApplication?)"), "foreground checks should consume notification applications")
expect(appDelegateSource.contains("NSWorkspace.didLaunchApplicationNotification"), "AppDelegate should observe application launches")
expect(appDelegateSource.contains("NSWorkspace.didTerminateApplicationNotification"), "AppDelegate should observe application termination")
```

Extract the `tick()` and `refreshAggregateAndUI` source ranges and assert they contain neither `frontmostApplication` nor `CodexAppDetector.isCodexForeground()`.

- [ ] **Step 2: Run the self-check and verify the intended failure**

Run: `cd src/macos && swift run AgentHaloMac --self-check`

Expected: FAIL because launch/terminate handlers and cached foreground state do not yet exist.

- [ ] **Step 3: Implement minimal event-driven cache APIs**

In `CodexAppDetector`, replace the expiration-based cache with a lazy optional cache:

```swift
private static var runningCacheValue: Bool?

static func isCodexRunning() -> Bool {
    if let runningCacheValue { return runningCacheValue }
    let value = NSWorkspace.shared.runningApplications.contains {
        isCodexApp($0, allowLocalizedName: false)
    }
    runningCacheValue = value
    return value
}

static func noteApplicationDidLaunch(_ app: NSRunningApplication?) {
    guard let app, isCodexApp(app, allowLocalizedName: false) else { return }
    runningCacheValue = true
}

static func noteApplicationDidTerminate(_ app: NSRunningApplication?) {
    guard let app, isCodexApp(app, allowLocalizedName: false) else { return }
    runningCacheValue = nil
}

static func isCodexForeground(_ app: NSRunningApplication?) -> Bool {
    guard let app else { return false }
    return isCodexApp(app, allowLocalizedName: true)
}
```

Keep the zero-argument `isCodexForeground()` only if a user-triggered non-tick call still needs it; no periodic path may call it.

- [ ] **Step 4: Wire workspace notifications and cache foreground state**

Add `private var codexIsForeground = false` to `AppDelegate`. Register launch and terminate observers beside the existing activate/Space observers. On activation, update `codexIsForeground` from the notification application before updating overlay suspension. On Space change, read `frontmostApplication` once and pass it through the same helper. Launch and terminate handlers update the detector cache and call `tick()` only when the cached running state can affect UI.

Change:

```swift
acknowledgeCompletedIfCodexIsForeground()
```

to consume `codexIsForeground`, and pass that same cached value to `liveErrorPresentationState.update(...)` in `refreshAggregateAndUI`.

- [ ] **Step 5: Run self-check and core checks**

Run: `cd src/macos && swift run AgentHaloMac --self-check && swift run AgentHaloCoreChecks`

Expected: PASS, including unchanged runtime ring pixel digests.

- [ ] **Step 6: Commit event-driven application state**

```bash
git add src/macos/Sources/AgentHaloMac/CodexAppDetector.swift src/macos/Sources/AgentHaloMac/AppDelegate.swift src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "perf: make macOS app detection event driven"
```

---

### Task 3: Remove Redundant Ring Submissions

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloRenderer.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

**Interfaces:**
- Consumes: existing `HaloView.updateLiveAggregate(...)`, `setupRingLayers()`, `resizeForHaloSize(_:)`.
- Produces: one aggregate-driven redraw and per-frame writes only for `path`, `strokeColor`, and `lineWidth`.

- [ ] **Step 1: Write failing structural checks**

Extract `refreshAggregateAndUI` and `applyRingLayers` source ranges and require:

```swift
expect(!refreshSource.contains("haloView?.redrawRing()"), "aggregate refresh should not redraw twice")
expect(!applySource.contains("layer.fillColor ="), "fillColor should be initialized once")
expect(!applySource.contains("layer.lineCap ="), "lineCap should be initialized once")
expect(!applySource.contains("layer.lineJoin ="), "lineJoin should be initialized once")
expect(!applySource.contains("layer.frame = bounds"), "frame should change only during setup or resize")
expect(applySource.contains("layer.path = path"), "path must still update every frame")
expect(applySource.contains("layer.strokeColor = style.color.cgColor"), "stroke color must still update every frame")
expect(applySource.contains("layer.lineWidth = style.width"), "line width must still update every frame")
```

Also retain assertions that setup sets transparent fill/round cap/round join/frame and resize updates every ring-layer frame.

- [ ] **Step 2: Run the self-check and verify the intended failure**

Run: `cd src/macos && swift run AgentHaloMac --self-check`

Expected: FAIL because the duplicate redraw and four constant per-frame assignments still exist.

- [ ] **Step 3: Make the minimal removals**

Delete the explicit `redrawRing()` block at the end of `refreshAggregateAndUI`. In `HaloRenderer.applyRingLayers`, keep the disabled-action transaction and reduce the loop to:

```swift
for (layer, style) in zip(layers, styles) {
    layer.path = path
    layer.strokeColor = style.color.cgColor
    layer.lineWidth = style.width
}
```

Do not change calculations, style order, path creation, animation driver, setup, or resize code.

- [ ] **Step 4: Run visual, interaction, and core checks**

Run: `cd src/macos && swift run AgentHaloMac --self-check && swift run AgentHaloCoreChecks`

Expected: PASS with byte-identical runtime ring pixel digests at 1x/2x and exact layer-model values.

- [ ] **Step 5: Commit redundant-work removal**

```bash
git add src/macos/Sources/AgentHaloMac/AppDelegate.swift src/macos/Sources/AgentHaloMac/HaloRenderer.swift src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "perf: remove redundant macOS ring submissions"
```

---

### Task 4: Full Verification and Packaged-App Evidence

**Files:**
- Verify: `src/macos`
- Verify: `outputs/AgentHalo-macOS/AgentHalo.app`
- Modify only if packaging checks require it: existing macOS build/package scripts.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: fresh self-check, core-check, release-build, package, pixel-baseline, and CPU-sampling evidence.

- [ ] **Step 1: Run complete Swift verification**

Run:

```bash
cd src/macos
swift run AgentHaloMac --self-check
swift run AgentHaloCoreChecks
swift build -c release
```

Expected: all commands exit 0 with no failed checks.

- [ ] **Step 2: Run diagnostics and benchmark**

Run the existing diagnostics benchmark to a temporary output path and confirm it exits 0. Re-run the runtime ring baseline twice to prove the 1x/2x digests are deterministic within the same environment.

- [ ] **Step 3: Build the packaged application**

Run the repository's existing macOS packaging command discovered from the root build scripts. Confirm `outputs/AgentHalo-macOS/AgentHalo.app/Contents/MacOS/AgentHalo` exists and the packaged self-check or launch smoke check exits successfully.

- [ ] **Step 4: Compare CPU under fixed scenarios**

For both the pre-optimization commit and the final package, sample the same duration in steady standby and active motion. Record median/mean CPU and inspect a `sample` trace for the absence of periodic LaunchServices calls from `tick()`.

Expected: CPU improves or remains neutral, LaunchServices polling disappears from the periodic tick, and visual baselines remain identical. If CPU regresses or a visual digest changes, revert the responsible optimization before completion.

- [ ] **Step 5: Review the final diff against the design**

Run:

```bash
git diff 1802e32..HEAD -- src/macos docs/superpowers
git diff --check
git status --short
```

Confirm no Windows files, visual math, animation cadence, transition duration, or path-update-frequency changes.
