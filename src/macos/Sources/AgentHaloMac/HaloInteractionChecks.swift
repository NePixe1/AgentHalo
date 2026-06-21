import AppKit
import AgentHaloCore

private func expect(_ condition: Bool, _ message: String) {
    if !condition {
        fatalError(message)
    }
}

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fatalError("\(message): expected \(expected), got \(actual)")
    }
}

@MainActor
func runHaloInteractionChecks() {
    testRightClickInvokesContextMenuCallback()
    testSingleClickInvokesPrimaryAction()
    testHaloContextMenuContainsCurrentControls()
    testHaloClickWaitsForMouseUpAndDragCancelsClick()
    testHaloHoverUsesFilledCircularSurface()
    testDraggingHaloSuppressesHoverDetails()
    testDraggingHaloPausesAnimationDuringDrag()
    testHaloSizeResizeKeepsWindowOrigin()
    testHaloFrameVisibilityAcrossScreens()
    testHaloViewResizeKeepsAnimationMoving()
    testHaloViewSystemOverlaySuspensionStopsAnimation()
    testPreviewSubmenuMarksLiveStateInitially()
    testPreviewSubmenuMovesCheckmarkAfterSelection()
    testAlwaysOnTopUsesOverlayWindowLevel()
    testHaloCollectionBehaviorDoesNotStayStationaryInMissionControl()
    testSystemOverlayApplicationDetection()
    testNonOverlayFrontmostAppDoesNotSuspendHalo()
    testSystemOverlaySuspensionKeepsHaloVisible()
    testHaloWindowAllowsScreenCaptureSharing()
    testDetailsPanelAllowsScreenCaptureSharing()
    testDetailsPanelVisibilityAfterCaptureFollowsMouseLocation()
    testFocusSubmenuMarksCodexInitially()
    testFocusSubmenuSwitchesToClaudeCode()
    testSingleClickDoesNotActivateCodexWhenClaudeCodeFocused()
    testDetailsPanelShowsCodexQuotaAndIdleCopy()
    testDetailsPanelShowsSessionMetadataForCodexAndClaudeCode()
    testDetailsPanelShowsExpiredQuotaAsWaitingForRefresh()
    testDetailsPanelShowsAnswerStreamingCopy()
    testDetailsPanelShowsContextAndHidesQuotaForClaudeCode()
    testDetailsPresentationUsesFocusedSessionAndRejectsStaleQuota()
    testClaudeContextUsesRawSessionAfterCompletionAcknowledgement()
    testClaudeContextSurvivesHookSnapshotPruning()
    testDetailsPanelSwitchCallbackSelectsClaudeCode()
}

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

@MainActor
private func testRightClickInvokesContextMenuCallback() {
    let view = HaloView(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
    var callbackPoint: NSPoint?
    view.onRightClick = { event in
        callbackPoint = event.locationInWindow
    }

    let event = NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: NSPoint(x: 24, y: 30),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
    )!

    view.rightMouseDown(with: event)

    expect(callbackPoint == NSPoint(x: 24, y: 30), "right click should invoke context menu callback")
}

@MainActor
private func testSingleClickInvokesPrimaryAction() {
    var activations = 0
    let delegate = AppDelegate(
        settingsStore: SettingsStore(settingsURL: temporarySettingsURL()),
        codexActivator: {
            activations += 1
        }
    )

    delegate.handleHaloPrimaryClick()

    expect(activations == 1, "single click should activate Codex")
}

@MainActor
private func testHaloContextMenuContainsCurrentControls() {
    let delegate = AppDelegate()
    let menu = delegate.makeHaloContextMenu()
    let titles = menu.items.map(\.title)

    expect(menu.items.count >= 7, "halo context menu should expose the control menu")
    expect(!titles.contains("确认已完成任务"), "halo context menu should not include completion acknowledgement")
    expect(!titles.contains("确认当前错误"), "halo context menu should not include error acknowledgement")
    expect(titles.contains("始终置顶"), "halo context menu should include always-on-top")
    expect(titles.contains("暂停状态监听"), "halo context menu should include pause")
    expect(titles.contains("圆环大小"), "halo context menu should include size slider")
    guard let sizeItem = menu.items.first(where: { $0.title == "圆环大小" }) else {
        fatalError("halo context menu should expose size slider item")
    }
    let sliders = sizeItem.view?.subviews.compactMap { $0 as? NSSlider } ?? []
    expect(sliders.count == 1, "halo size menu item should contain one slider")
    expect(sliders[0].minValue <= 72, "halo size slider should allow smaller halo")
    expect(sliders[0].maxValue >= 180, "halo size slider should allow larger halo")
    sizeItem.view?.layoutSubtreeIfNeeded()
    let sizeLabels = sizeItem.view?.subviews.compactMap { $0 as? NSTextField }
        .filter { $0.stringValue == "圆环大小" } ?? []
    expect(sizeLabels.count == 1, "halo size menu item should contain one title label")
    expect(sizeLabels[0].frame.minX >= 19, "halo size row label should align with regular menu text")
    expect(sizeLabels[0].frame.minX <= 23, "halo size row label should not drift past regular menu text")
    expect(titles.contains("预览状态"), "halo context menu should include preview submenu")
    expect(!titles.contains("切换到 Codex"), "halo context menu should not include Codex activation")
    expect(!titles.contains("退出 Agent Halo"), "halo context menu should not include old quit title")
    expect(titles.contains("退出"), "halo context menu should include quit")
}

@MainActor
private func testHaloClickWaitsForMouseUpAndDragCancelsClick() {
    let view = HaloView(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 300, width: 112, height: 112),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view

    var clickCount = 0
    view.onClick = {
        clickCount += 1
    }

    view.mouseDown(with: interactionEvent(type: .leftMouseDown))
    expect(clickCount == 0, "halo click should not activate on mouse down")
    view.mouseUp(with: interactionEvent(type: .leftMouseUp))
    expect(clickCount == 1, "halo click should activate on mouse up when no drag occurred")

    view.mouseDown(with: interactionEvent(type: .leftMouseDown))
    view.mouseDragged(with: interactionEvent(type: .leftMouseDragged, location: NSPoint(x: 34, y: 30)))
    view.mouseUp(with: interactionEvent(type: .leftMouseUp))
    expect(clickCount == 1, "dragging halo should cancel click activation")
}

@MainActor
private func testHaloHoverUsesFilledCircularSurface() {
    let view = HaloView(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
    var enterCount = 0
    var exitCount = 0
    view.onMouseEntered = {
        enterCount += 1
    }
    view.onMouseExited = {
        exitCount += 1
    }

    view.mouseEntered(with: interactionEvent(type: .mouseMoved, location: NSPoint(x: 2, y: 2)))
    expect(enterCount == 0, "transparent halo corners should not trigger hover details")

    view.mouseMoved(with: interactionEvent(type: .mouseMoved, location: NSPoint(x: 56, y: 56)))
    expect(enterCount == 1, "the hollow halo center should trigger hover details")

    view.mouseMoved(with: interactionEvent(type: .mouseMoved, location: NSPoint(x: 72, y: 56)))
    expect(enterCount == 1, "moving within the circular hover surface should not duplicate entry")

    view.mouseMoved(with: interactionEvent(type: .mouseMoved, location: NSPoint(x: 110, y: 110)))
    expect(exitCount == 1, "moving into a transparent halo corner should exit hover details")
}

@MainActor
private func testDraggingHaloSuppressesHoverDetails() {
    let view = HaloView(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 300, width: 112, height: 112),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view

    var hoverShowCount = 0
    var dragStartCount = 0
    view.onMouseEntered = {
        hoverShowCount += 1
    }
    view.onDragStarted = {
        dragStartCount += 1
    }

    view.mouseEntered(with: interactionEvent(type: .leftMouseDown))
    view.mouseDown(with: interactionEvent(type: .leftMouseDown))
    view.mouseDragged(with: interactionEvent(type: .leftMouseDragged, location: NSPoint(x: 34, y: 30)))
    view.mouseEntered(with: interactionEvent(type: .leftMouseDown))
    expect(hoverShowCount == 1, "dragging halo should suppress hover details")
    view.mouseUp(with: interactionEvent(type: .leftMouseUp))

    expect(hoverShowCount == 2, "releasing halo inside its hover surface should restore details")
    expect(dragStartCount == 1, "dragging halo should request immediate details hide")
}

@MainActor
private func testDraggingHaloPausesAnimationDuringDrag() {
    let view = HaloView(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 300, width: 112, height: 112),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view

    expect(view.hasAnimationDriverForChecks, "halo should animate normally before drag")

    view.mouseDown(with: interactionEvent(type: .leftMouseDown))
    view.mouseDragged(with: interactionEvent(type: .leftMouseDragged, location: NSPoint(x: 34, y: 30)))
    expect(!view.hasAnimationDriverForChecks, "dragging halo should pause animation entirely")

    view.mouseUp(with: interactionEvent(type: .leftMouseUp))
    expect(view.hasAnimationDriverForChecks, "halo should restore animation after dragging")
}

@MainActor
private func testHaloSizeResizeKeepsWindowOrigin() {
    let oldFrame = NSRect(x: 520, y: 640, width: 112, height: 112)

    let resizedFrame = AppDelegate.haloFrameByKeepingOrigin(oldFrame: oldFrame, requestedSize: 168)

    expect(resizedFrame.origin == oldFrame.origin, "halo size slider should not move the halo window origin")
    expect(resizedFrame.size == NSSize(width: 168, height: 168), "halo size slider should resize the halo window")
}

private func interactionEvent(
    type: NSEvent.EventType,
    location: NSPoint = NSPoint(x: 24, y: 30)
) -> NSEvent {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 0
    )!
}

@MainActor
private func testHaloViewResizeKeepsAnimationMoving() {
    let view = HaloView(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
    expect(view.usesCommonRunLoopAnimationDriverForChecks, "halo animation should run in common run-loop modes")

    let before = view.animationSnapshotForChecks()
    view.resizeForHaloSize(168)
    view.advanceAnimationForChecks(delta: 0.5)
    let after = view.animationSnapshotForChecks()

    expect(view.bounds.size == NSSize(width: 168, height: 168), "resized halo view should update its bounds")
    expect(after.time > before.time, "halo animation time should keep advancing after resize")
    expect(after.gapA != before.gapA, "halo gaps should keep rotating after resize")
}

@MainActor
private func testHaloViewSystemOverlaySuspensionStopsAnimation() {
    let view = HaloView(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
    var exitCount = 0
    view.onMouseExited = {
        exitCount += 1
    }
    view.mouseEntered(with: interactionEvent(type: .mouseMoved, location: NSPoint(x: 56, y: 56)))
    expect(view.hasAnimationDriverForChecks, "halo view should animate before system overlay suspension")

    view.setSystemOverlaySuspended(true)

    expect(!view.hasAnimationDriverForChecks, "system overlay suspension should stop halo animation")
    let before = view.animationSnapshotForChecks()
    view.advanceAnimationForChecks(delta: 0.5)
    let after = view.animationSnapshotForChecks()
    expect(after.time == before.time, "suspended halo should not advance animation state")

    view.setSystemOverlaySuspended(false)

    expect(view.hasAnimationDriverForChecks, "halo view should restore animation after system overlay suspension")
    view.mouseMoved(with: interactionEvent(type: .mouseMoved, location: NSPoint(x: 110, y: 110)))
    expect(exitCount == 1, "hover exit should still fire after system overlay suspension")
}

@MainActor
private func testPreviewSubmenuMarksLiveStateInitially() {
    let delegate = AppDelegate()
    let submenu = previewSubmenu(in: delegate.makeHaloContextMenu())
    let checkedTitles = submenu.items.filter { $0.state == .on }.map(\.title)

    expect(checkedTitles == ["实时状态"], "live preview item should be checked initially")
}

@MainActor
private func testPreviewSubmenuMovesCheckmarkAfterSelection() {
    let delegate = AppDelegate()
    let submenu = previewSubmenu(in: delegate.makeHaloContextMenu())
    let workingItem = menuItem(titled: "执行中", in: submenu)

    NSApplication.shared.sendAction(workingItem.action!, to: workingItem.target, from: workingItem)

    let refreshedSubmenu = previewSubmenu(in: delegate.makeHaloContextMenu())
    let checkedTitles = refreshedSubmenu.items.filter { $0.state == .on }.map(\.title)

    expect(checkedTitles == ["执行中"], "selected preview item should be checked after selection")
}

@MainActor
private func testAlwaysOnTopUsesOverlayWindowLevel() {
    expect(
        AppDelegate.haloWindowLevel(alwaysOnTop: true) == .floating,
        "always-on-top halo should use floating window level to stay above normal windows but below screenshot overlays"
    )
    expect(
        AppDelegate.haloWindowLevel(alwaysOnTop: false) == .normal,
        "non-topmost halo should use the normal window level"
    )
}

@MainActor
private func testHaloCollectionBehaviorDoesNotStayStationaryInMissionControl() {
    let behavior = AppDelegate.haloCollectionBehavior

    expect(behavior.contains(.canJoinAllSpaces), "halo should stay available across Spaces")
    expect(behavior.contains(.fullScreenAuxiliary), "halo should stay available beside full-screen apps")
    expect(behavior.contains(.transient), "halo should hide during Mission Control instead of floating over it")
    expect(!behavior.contains(.stationary), "halo should not remain stationary over Mission Control")
}

@MainActor
private func testSystemOverlayApplicationDetection() {
    expect(
        AppDelegate.isSystemOverlayApplication(bundleIdentifier: "com.apple.screenshot.launcher", localizedName: "Screenshot"),
        "Screenshot app should suspend the halo"
    )
    expect(
        AppDelegate.isSystemOverlayApplication(bundleIdentifier: "com.apple.dock", localizedName: "Dock"),
        "Dock-owned Mission Control should suspend the halo"
    )
    expect(
        AppDelegate.isSystemOverlayApplication(bundleIdentifier: nil, localizedName: "Snipaste"),
        "Snipaste capture overlay should suspend the halo without hiding visible details"
    )
    expect(
        !AppDelegate.isSystemOverlayApplication(bundleIdentifier: "com.todesktop.230313mzl4w4u92", localizedName: "Codex"),
        "regular app activation should not suspend the halo"
    )
}

@MainActor
private func testNonOverlayFrontmostAppDoesNotSuspendHalo() {
    let shouldSuspend = AppDelegate.shouldSuspendForSystemOverlay(
        frontmostBundleIdentifier: "com.todesktop.230313mzl4w4u92",
        frontmostLocalizedName: "Codex"
    )

    expect(!shouldSuspend, "regular frontmost app should not suspend halo")
}

@MainActor
private func testSystemOverlaySuspensionKeepsHaloVisible() {
    expect(
        AppDelegate.haloWindowVisibilityDuringSystemOverlay == .visible,
        "system overlay suspension should freeze the halo without hiding it"
    )
}

@MainActor
private func testHaloWindowAllowsScreenCaptureSharing() {
    expect(AppDelegate.haloWindowSharingType == .readOnly, "halo window should be included in screen capture")
}

@MainActor
private func testDetailsPanelAllowsScreenCaptureSharing() {
    let panel = DetailsPanel()

    expect(panel.sharingType == .readOnly, "details panel should be included in screen capture")
}

@MainActor
private func testDetailsPanelVisibilityAfterCaptureFollowsMouseLocation() {
    let haloFrame = NSRect(x: 100, y: 100, width: 96, height: 96)
    let detailsFrame = NSRect(x: 0, y: 80, width: 90, height: 120)

    expect(
        AppDelegate.shouldKeepDetailsVisibleAfterSystemOverlay(
            mouseLocation: NSPoint(x: 148, y: 148),
            haloFrame: haloFrame,
            detailsFrame: detailsFrame
        ),
        "details should stay visible when the pointer returns over the hollow halo center"
    )
    expect(
        AppDelegate.shouldKeepDetailsVisibleAfterSystemOverlay(
            mouseLocation: NSPoint(x: 40, y: 120),
            haloFrame: haloFrame,
            detailsFrame: detailsFrame
        ),
        "details should stay visible when the pointer returns over the details panel"
    )
    expect(
        !AppDelegate.shouldKeepDetailsVisibleAfterSystemOverlay(
            mouseLocation: NSPoint(x: 102, y: 102),
            haloFrame: haloFrame,
            detailsFrame: detailsFrame
        ),
        "details should hide when the pointer returns over a transparent halo corner"
    )
    expect(
        !AppDelegate.shouldKeepDetailsVisibleAfterSystemOverlay(
            mouseLocation: NSPoint(x: 260, y: 260),
            haloFrame: haloFrame,
            detailsFrame: detailsFrame
        ),
        "details should hide after capture when the pointer is outside both hover surfaces"
    )
}

@MainActor
private func testFocusSubmenuMarksCodexInitially() {
    let delegate = AppDelegate(settingsStore: SettingsStore(settingsURL: temporarySettingsURL()))
    let submenu = focusedAgentSubmenu(in: delegate.makeHaloContextMenu())
    let checkedTitles = submenu.items.filter { $0.state == .on }.map(\.title)

    expect(checkedTitles == ["Codex"], "Codex focus should be checked initially")
}

@MainActor
private func testFocusSubmenuSwitchesToClaudeCode() {
    let store = SettingsStore(settingsURL: temporarySettingsURL())
    let delegate = AppDelegate(settingsStore: store)
    let submenu = focusedAgentSubmenu(in: delegate.makeHaloContextMenu())
    let claudeItem = menuItem(titled: "Claude Code", in: submenu)

    NSApplication.shared.sendAction(claudeItem.action!, to: claudeItem.target, from: claudeItem)

    let refreshedSubmenu = focusedAgentSubmenu(in: delegate.makeHaloContextMenu())
    let checkedTitles = refreshedSubmenu.items.filter { $0.state == .on }.map(\.title)
    let loaded = store.load()

    expect(checkedTitles == ["Claude Code"], "Claude Code focus should be checked after selection")
    expect(loaded.focusedAgent, .claudeCode, "focused agent should persist after menu selection")
}

@MainActor
private func testSingleClickDoesNotActivateCodexWhenClaudeCodeFocused() {
    var activations = 0
    let delegate = AppDelegate(
        settingsStore: SettingsStore(settingsURL: temporarySettingsURL()),
        codexActivator: {
            activations += 1
        }
    )

    delegate.setFocusedAgent(.claudeCode)
    delegate.handleHaloPrimaryClick()

    expect(activations == 0, "single click should not activate Codex when Claude Code is focused")
}

private func previewSubmenu(in menu: NSMenu) -> NSMenu {
    guard let preview = menu.items.first(where: { $0.title == "预览状态" })?.submenu else {
        fatalError("preview submenu should exist")
    }
    return preview
}

private func focusedAgentSubmenu(in menu: NSMenu) -> NSMenu {
    guard let focus = menu.items.first(where: { $0.title == "监控对象" })?.submenu else {
        fatalError("focused-agent submenu should exist")
    }
    return focus
}

private func temporarySettingsURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-interaction-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("settings.json")
}

private func menuItem(titled title: String, in menu: NSMenu) -> NSMenuItem {
    guard let item = menu.items.first(where: { $0.title == title }) else {
        fatalError("\(title) menu item should exist")
    }
    return item
}

@MainActor
private func testDetailsPanelShowsCodexQuotaAndIdleCopy() {
    let panel = DetailsPanel()
    let aggregate = AggregateSnapshot(
        state: .idle,
        label: "READY",
        detail: AgentKind.codex.standbyDetail,
        sessions: [],
        focusedAgent: .codex
    )

    panel.update(
        aggregate: aggregate,
        quota: RateLimitSnapshot(primaryUsedPercent: 30, secondaryUsedPercent: 60, contextUsedPercent: 42),
        contextUsedPercent: 42
    )

    expect(panel.focusedAgentForTesting == .codex, "details panel should select Codex")
    expect(panel.detailTextForTesting == "Codex 正在待命", "Codex idle copy should be localized")
    expect(panel.contextPillHiddenForTesting == false, "Codex context pill should be visible")
    expect(panel.primaryQuotaHiddenForTesting == false, "Codex primary quota should be visible")
    expect(panel.secondaryQuotaHiddenForTesting == false, "Codex secondary quota should be visible")
}

@MainActor
private func testDetailsPanelShowsSessionMetadataForCodexAndClaudeCode() {
    let panel = DetailsPanel()
    let codex = AggregateSnapshot(
        state: .working,
        label: "EXECUTING",
        detail: "AgentHalo - Running command",
        sessions: [],
        focusedAgent: .codex
    )
    let details = SessionDetailsSnapshot(
        projectName: "AgentHalo",
        modelName: "gpt-5.5",
        inputTokens: 38_000,
        outputTokens: 1_200
    )

    panel.update(
        aggregate: codex,
        quota: nil,
        contextUsedPercent: 42,
        sessionDetails: details,
        showsQuota: false
    )

    expect(panel.primaryQuotaHiddenForTesting, "third-party Codex quota should be hidden")
    expect(!panel.metadataGroupHiddenForTesting, "third-party Codex metadata should be visible")
    expect(panel.projectValueForTesting, "AgentHalo", "details project value")
    expect(panel.modelValueForTesting, "gpt-5.5", "details model value")
    expect(panel.tokenValueForTesting, "输入 38k · 输出 1.2k", "details token value")

    let claude = AggregateSnapshot(
        state: .working,
        label: "EXECUTING",
        detail: "AgentHalo - Running command",
        sessions: [],
        focusedAgent: .claudeCode
    )
    panel.update(
        aggregate: claude,
        quota: nil,
        contextUsedPercent: 58,
        sessionDetails: details,
        showsQuota: false
    )

    expect(panel.focusedAgentForTesting == .claudeCode, "details panel should select Claude Code")
    expect(!panel.metadataGroupHiddenForTesting, "Claude Code metadata should be visible")
    expect(panel.tokenValueForTesting, "输入 38k · 输出 1.2k", "Claude Code token value")
}

@MainActor
private func testDetailsPanelShowsExpiredQuotaAsWaitingForRefresh() {
    let panel = DetailsPanel()
    let aggregate = AggregateSnapshot(
        state: .idle,
        label: "READY",
        detail: AgentKind.codex.standbyDetail,
        sessions: [],
        focusedAgent: .codex
    )

    panel.update(
        aggregate: aggregate,
        quota: RateLimitSnapshot(
            primaryUsedPercent: 30,
            secondaryUsedPercent: 60,
            primaryResetAt: Date().addingTimeInterval(-5),
            secondaryResetAt: Date().addingTimeInterval(300),
            contextUsedPercent: 42
        ),
        contextUsedPercent: 42
    )

    expect(panel.primaryQuotaValueForTesting == "等待 Codex 刷新", "expired primary quota should wait for Codex refresh")
    expect(panel.secondaryQuotaValueForTesting == "剩余 40%", "valid secondary quota should keep remaining percent")
}

@MainActor
private func testDetailsPanelShowsAnswerStreamingCopy() {
    let panel = DetailsPanel()
    let aggregate = AggregateSnapshot(
        state: .working,
        label: "WORKING",
        detail: "AgentHalo - Writing answer",
        sessions: [],
        focusedAgent: .codex,
        answerStreaming: true
    )

    panel.update(aggregate: aggregate, quota: nil, contextUsedPercent: nil)

    expect(panel.detailTextForTesting == "正在输出答案", "answer streaming should use localized copy")
}

@MainActor
private func testDetailsPanelShowsContextAndHidesQuotaForClaudeCode() {
    let panel = DetailsPanel()
    let aggregate = AggregateSnapshot(
        state: .idle,
        label: "READY",
        detail: AgentKind.claudeCode.standbyDetail,
        sessions: [],
        focusedAgent: .claudeCode
    )

    panel.update(aggregate: aggregate, quota: nil, contextUsedPercent: 58.4)

    expect(panel.focusedAgentForTesting == .claudeCode, "details panel should select Claude Code")
    expect(panel.detailTextForTesting == "Claude Code 正在待命", "Claude Code idle copy should be localized")
    expect(panel.contextPillHiddenForTesting == false, "Claude Code context pill should be visible")
    expect(panel.contextValueForTesting == "上下文 58%", "Claude Code context percent should be shown")
    expect(panel.primaryQuotaHiddenForTesting == true, "Claude Code primary quota should be hidden")
    expect(panel.secondaryQuotaHiddenForTesting == true, "Claude Code secondary quota should be hidden")
}

@MainActor
private func testDetailsPresentationUsesFocusedSessionAndRejectsStaleQuota() {
    let now = Date()
    let thirdPartySession = SessionSnapshot(
        threadId: "codex-third-party",
        projectName: "AgentHalo",
        workingDirectory: "/tmp/AgentHalo",
        state: .working,
        action: "Running command",
        lastEventAt: now,
        completedAt: nil,
        active: true,
        modelName: "gpt-5.5",
        inputTokens: 38_000,
        outputTokens: 1_200,
        hasRateLimits: false,
        contextUsedPercent: 20
    )
    let staleQuota = RateLimitSnapshot(
        primaryUsedPercent: 20,
        secondaryUsedPercent: 80,
        contextUsedPercent: 42
    )
    let codexAggregate = AggregateSnapshot(
        state: .working,
        label: "EXECUTING",
        detail: "AgentHalo - Running command",
        sessions: [thirdPartySession],
        focusedAgent: .codex
    )

    let thirdParty = AppDelegate.detailsPresentationForDetails(
        focusedAgent: .codex,
        displayedAggregate: codexAggregate,
        rawClaudeSnapshots: [],
        quota: staleQuota,
        claudeUsage: nil
    )
    expect(!thirdParty.showsQuota, "stale global quota must not override current third-party Codex session")
    expect(thirdParty.sessionDetails.modelName, "gpt-5.5", "Codex details should use focused session model")
    expect(thirdParty.contextUsedPercent, 20, "Codex context should use the focused session rather than stale quota")

    var subscriptionSession = thirdPartySession
    subscriptionSession.hasRateLimits = true
    let subscriptionAggregate = AggregateSnapshot(
        state: .working,
        label: "EXECUTING",
        detail: "AgentHalo - Running command",
        sessions: [subscriptionSession],
        focusedAgent: .codex
    )
    let subscription = AppDelegate.detailsPresentationForDetails(
        focusedAgent: .codex,
        displayedAggregate: subscriptionAggregate,
        rawClaudeSnapshots: [],
        quota: staleQuota,
        claudeUsage: nil
    )
    expect(subscription.showsQuota, "Codex session with rate limits should keep quota UI")

    let claudeSession = SessionSnapshot(
        threadId: "cc-current",
        projectName: "AgentHalo",
        workingDirectory: "/tmp/AgentHalo",
        state: .working,
        action: "Thinking",
        lastEventAt: now,
        completedAt: nil,
        active: true,
        agent: .claudeCode
    )
    let claudeAggregate = AggregateSnapshot(
        state: .working,
        label: "THINKING",
        detail: "AgentHalo - Thinking",
        sessions: [claudeSession],
        focusedAgent: .claudeCode
    )
    let matchingUsage = ClaudeContextUsageSnapshot(
        sessionId: "cc-current",
        usedPercent: 58,
        modelName: "claude-sonnet-4",
        inputTokens: 38_000,
        outputTokens: 1_200,
        updatedAt: now
    )
    let claude = AppDelegate.detailsPresentationForDetails(
        focusedAgent: .claudeCode,
        displayedAggregate: claudeAggregate,
        rawClaudeSnapshots: [claudeSession],
        quota: nil,
        claudeUsage: matchingUsage
    )
    expect(!claude.showsQuota, "Claude Code should use metadata UI")
    expect(claude.contextUsedPercent, 58, "Claude Code should retain context usage")
    expect(claude.sessionDetails.modelName, "claude-sonnet-4", "Claude details should use matching statusline model")

    var mismatchedUsage = matchingUsage
    mismatchedUsage.sessionId = "cc-other"
    let mismatched = AppDelegate.detailsPresentationForDetails(
        focusedAgent: .claudeCode,
        displayedAggregate: claudeAggregate,
        rawClaudeSnapshots: [claudeSession],
        quota: nil,
        claudeUsage: mismatchedUsage
    )
    expect(mismatched.sessionDetails.modelName == nil, "Claude details must reject another session's model")
    expect(mismatched.contextUsedPercent == nil, "Claude details must reject another session's context usage")
}

@MainActor
private func testClaudeContextUsesRawSessionAfterCompletionAcknowledgement() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-context-ui-\(UUID().uuidString)", isDirectory: true)
    let snapshotURL = root.appendingPathComponent("claude-code-context.json")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let context = ClaudeContextUsageSnapshot(
        sessionId: "cc-done",
        usedPercent: 30,
        contextWindowSize: 200_000,
        updatedAt: now
    )
    try! JSONEncoder().encode(context).write(to: snapshotURL)
    let rawClaudeSession = SessionSnapshot(
        threadId: "cc-done",
        projectName: "AgentHalo",
        workingDirectory: "/tmp/AgentHalo",
        state: .done,
        action: "Complete",
        lastEventAt: now,
        completedAt: now,
        active: false,
        agent: .claudeCode
    )
    let acknowledgedAggregate = AggregateSnapshot(
        state: .idle,
        label: "READY",
        detail: AgentKind.claudeCode.standbyDetail,
        sessions: [],
        focusedAgent: .claudeCode
    )

    let testQueue = DispatchQueue(label: "com.agenthalo.test-context-reader")
    let percent = AppDelegate.contextUsedPercentForDetails(
        focusedAgent: .claudeCode,
        quota: nil,
        displayedAggregate: acknowledgedAggregate,
        rawClaudeSnapshots: [rawClaudeSession],
        claudeContextUsageReader: ClaudeContextUsageReader(snapshotURL: snapshotURL),
        contextReaderQueue: testQueue,
        now: now
    )

    expect(percent == 30, "acknowledged Claude completion should retain matching context usage")
}

@MainActor
private func testClaudeContextSurvivesHookSnapshotPruning() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-context-pruned-\(UUID().uuidString)", isDirectory: true)
    let snapshotURL = root.appendingPathComponent("claude-code-context.json")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let testQueue = DispatchQueue(label: "com.agenthalo.test-context-reader")
    let now = Date()
    let context = ClaudeContextUsageSnapshot(
        sessionId: "cc-recent",
        usedPercent: 30,
        contextWindowSize: 200_000,
        updatedAt: now.addingTimeInterval(-60)
    )
    try! JSONEncoder().encode(context).write(to: snapshotURL)
    let placeholderSession = SessionSnapshot(
        threadId: "claude-code",
        projectName: "Claude Code",
        workingDirectory: "",
        state: .idle,
        action: "Ready",
        lastEventAt: now,
        completedAt: nil,
        active: false,
        agent: .claudeCode
    )
    let readyAggregate = AggregateSnapshot(
        state: .idle,
        label: "READY",
        detail: AgentKind.claudeCode.standbyDetail,
        sessions: [placeholderSession],
        focusedAgent: .claudeCode
    )

    let percent = AppDelegate.contextUsedPercentForDetails(
        focusedAgent: .claudeCode,
        quota: nil,
        displayedAggregate: readyAggregate,
        rawClaudeSnapshots: [],
        claudeContextUsageReader: ClaudeContextUsageReader(snapshotURL: snapshotURL),
        contextReaderQueue: testQueue,
        now: now
    )

    expect(percent == 30, "fresh Claude context should remain visible after hook snapshots prune")
}

@MainActor
private func testDetailsPanelSwitchCallbackSelectsClaudeCode() {
    let panel = DetailsPanel()
    var selected: AgentKind?
    panel.onAgentSelected = { selected = $0 }
    panel.update(
        aggregate: AggregateSnapshot(
            state: .idle,
            label: "READY",
            detail: AgentKind.codex.standbyDetail,
            sessions: [],
            focusedAgent: .codex
        ),
        quota: nil,
        contextUsedPercent: nil
    )

    panel.selectAgentForTesting(.claudeCode)

    expect(selected == .claudeCode, "details panel switch should emit selected agent")
}
