# Automatic Offscreen Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically return a fully off-screen halo to the primary display at launch and after display-layout changes while preserving the existing manual recovery menu item.

**Architecture:** Each platform gets a pure, testable rectangle-visibility predicate plus a runtime adapter that obtains the operating system's current usable display rectangles. The existing manual recovery method remains the single placement-and-persistence path, so automatic and manual behavior cannot drift.

**Tech Stack:** Swift/AppKit with the existing `AgentHaloMac --self-check` harness; C#/.NET Framework WPF with WinForms screen geometry and the existing Windows diagnostics executable.

---

### Task 1: macOS visibility predicate and automatic recovery

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`

- [ ] **Step 1: Write the failing visibility-predicate checks**

Add `testHaloFrameVisibilityAcrossScreens()` to `runHaloInteractionChecks()` and define it with fully visible, partially visible, and fully off-screen frames:

```swift
@MainActor
private func testHaloFrameVisibilityAcrossScreens() {
    let screens = [
        NSRect(x: 0, y: 0, width: 1440, height: 900),
        NSRect(x: 1440, y: 0, width: 1920, height: 1080)
    ]
    expect(
        AppDelegate.isHaloFrameVisible(NSRect(x: 1200, y: 700, width: 112, height: 112), in: screens),
        "halo wholly inside a screen should remain visible"
    )
    expect(
        AppDelegate.isHaloFrameVisible(NSRect(x: 3320, y: 900, width: 112, height: 112), in: screens),
        "halo partially intersecting a screen should remain visible"
    )
    expect(
        !AppDelegate.isHaloFrameVisible(NSRect(x: 3500, y: 1200, width: 112, height: 112), in: screens),
        "halo outside every screen should be recovered"
    )
}
```

- [ ] **Step 2: Run the macOS interaction check and verify RED**

Run: `cd src/macos && swift run AgentHaloMac --self-check`

Expected: compilation fails because `AppDelegate.isHaloFrameVisible(_:in:)` does not exist.

- [ ] **Step 3: Add the predicate and recovery wiring**

Add the pure predicate and a helper that delegates actual movement to the existing `escapeOffscreen()` method:

```swift
static func isHaloFrameVisible(_ frame: NSRect, in visibleFrames: [NSRect]) -> Bool {
    visibleFrames.contains { $0.intersects(frame) }
}

private func recoverHaloIfOffscreen() {
    let visibleFrames = NSScreen.screens.map(\.visibleFrame)
    guard !Self.isHaloFrameVisible(panel.frame, in: visibleFrames) else {
        return
    }
    escapeOffscreen()
}
```

Call `recoverHaloIfOffscreen()` after `createHaloPanel()` during launch, and add the AppKit display callback:

```swift
func applicationDidChangeScreenParameters(_ notification: Notification) {
    recoverHaloIfOffscreen()
}
```

- [ ] **Step 4: Run focused macOS checks and build**

Run: `cd src/macos && swift run AgentHaloMac --self-check && swift build`

Expected: both commands exit 0 and the interaction checks report success.

- [ ] **Step 5: Commit the macOS behavior**

```bash
git add src/macos/Sources/AgentHaloMac/AppDelegate.swift src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "feat: recover offscreen halo on macOS"
```

### Task 2: Windows visibility predicate and automatic recovery

**Files:**
- Modify: `src/windows/Diagnostics.cs`
- Modify: `src/windows/HaloWindow.cs`

- [ ] **Step 1: Write the failing Windows diagnostics checks**

Add these assertions near the other `HaloWindow` diagnostics in `Diagnostics.RunSelfTest`:

```csharp
List<System.Drawing.Rectangle> displayAreas =
    new List<System.Drawing.Rectangle>
    {
        new System.Drawing.Rectangle(0, 0, 1920, 1040),
        new System.Drawing.Rectangle(1920, 0, 2560, 1400)
    };
Assert(HaloWindow.DiagnosticIsFrameVisible(
    new System.Drawing.Rectangle(1800, 900, 112, 112), displayAreas),
    "on-screen halo remains visible");
Assert(HaloWindow.DiagnosticIsFrameVisible(
    new System.Drawing.Rectangle(4440, 1300, 112, 112), displayAreas),
    "partially visible halo remains visible");
Assert(!HaloWindow.DiagnosticIsFrameVisible(
    new System.Drawing.Rectangle(4600, 1500, 112, 112), displayAreas),
    "off-screen halo requires recovery");
```

- [ ] **Step 2: Build on Windows and verify RED**

Run on Windows: `./scripts/build-windows.ps1`

Expected: compilation fails because `HaloWindow.DiagnosticIsFrameVisible` does not exist.

- [ ] **Step 3: Add the Windows predicate and native window-frame adapter**

Add a public diagnostic wrapper and use the native window rectangle so mixed-DPI display coordinates remain in physical pixels:

```csharp
public static bool DiagnosticIsFrameVisible(
    System.Drawing.Rectangle frame,
    IEnumerable<System.Drawing.Rectangle> workingAreas)
{
    return workingAreas.Any(delegate(System.Drawing.Rectangle area)
    {
        return area.IntersectsWith(frame);
    });
}

private void RecoverHaloIfOffscreen()
{
    IntPtr handle = new WindowInteropHelper(this).Handle;
    NativeRect nativeFrame;
    if (handle == IntPtr.Zero || !GetWindowRect(handle, out nativeFrame))
    {
        return;
    }
    System.Drawing.Rectangle frame = System.Drawing.Rectangle.FromLTRB(
        nativeFrame.Left, nativeFrame.Top, nativeFrame.Right, nativeFrame.Bottom);
    IEnumerable<System.Drawing.Rectangle> areas = Forms.Screen.AllScreens
        .Select(delegate(Forms.Screen screen) { return screen.WorkingArea; });
    if (!DiagnosticIsFrameVisible(frame, areas))
    {
        EscapeOffscreen();
    }
}
```

Define `NativeRect` and `GetWindowRect`, call `RecoverHaloIfOffscreen()` immediately after `RestorePosition()`, subscribe to `SystemEvents.DisplaySettingsChanged` in the constructor, dispatch recovery back to the WPF dispatcher in its handler, and unsubscribe in `OnClosing`:

```csharp
private void OnDisplaySettingsChanged(object sender, EventArgs e)
{
    Dispatcher.BeginInvoke(new Action(RecoverHaloIfOffscreen));
}
```

- [ ] **Step 4: Run the Windows build and self-test**

Run on Windows:

```powershell
./scripts/build-windows.ps1
Start-Process -FilePath ./outputs/AgentHalo/AgentHalo.exe `
  -ArgumentList "--self-test", "./outputs/windows-self-test.txt" -Wait
Get-Content ./outputs/windows-self-test.txt
```

Expected: the build exits 0 and the self-test output reports success.

- [ ] **Step 5: Commit the Windows behavior**

```bash
git add src/windows/HaloWindow.cs src/windows/Diagnostics.cs
git commit -m "feat: recover offscreen halo on Windows"
```

### Task 3: Documentation and full verification

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`

- [ ] **Step 1: Update the recovery documentation**

Replace the current manual-only note in each README with wording that says Agent Halo automatically returns a fully off-screen halo after launch or a display change, and that `脱离卡死` remains available as a manual reset.

- [ ] **Step 2: Run repository verification**

Run:

```bash
(cd src/macos && swift run AgentHaloCoreChecks)
(cd src/macos && swift run AgentHaloMac --self-check)
(cd src/macos && swift build)
python3 scripts/validate_schema.py
python3 scripts/generate_shared.py --check
python3 scripts/check_shared.py
git diff --check
```

Expected: every command exits 0. Run the Windows build and diagnostics from Task 2 on a Windows machine or CI because WPF cannot be compiled by the macOS toolchain.

- [ ] **Step 3: Commit documentation**

```bash
git add README.md README.zh-CN.md
git commit -m "docs: explain automatic offscreen recovery"
```

- [ ] **Step 4: Review the final range**

Run: `git log --oneline 7141ef9..HEAD && git diff --stat 7141ef9..HEAD && git status --short`

Expected: the range contains only the macOS implementation, Windows implementation, and documentation commits; the worktree is clean.
