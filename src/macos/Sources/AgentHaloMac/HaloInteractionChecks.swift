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
    testDraggingHaloSuppressesHoverDetails()
    testDraggingHaloReducesAnimationFrameRate()
    testHaloSizeResizeKeepsWindowOrigin()
    testHaloViewResizeKeepsAnimationMoving()
    testPreviewSubmenuMarksLiveStateInitially()
    testPreviewSubmenuMovesCheckmarkAfterSelection()
    testAlwaysOnTopUsesOverlayWindowLevel()
    testFocusSubmenuMarksCodexInitially()
    testFocusSubmenuSwitchesToClaudeCode()
    testSingleClickDoesNotActivateCodexWhenClaudeCodeFocused()
    testDetailsPanelShowsCodexQuotaAndIdleCopy()
    testDetailsPanelHidesQuotaForClaudeCode()
    testDetailsPanelSwitchCallbackSelectsClaudeCode()
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
    view.mouseUp(with: interactionEvent(type: .leftMouseUp))

    expect(hoverShowCount == 1, "dragging halo should suppress hover details")
    expect(dragStartCount == 1, "dragging halo should request immediate details hide")
}

@MainActor
private func testDraggingHaloReducesAnimationFrameRate() {
    let view = HaloView(frame: NSRect(x: 0, y: 0, width: 112, height: 112))
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 300, width: 112, height: 112),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = view

    expectApproximately(animationFrameInterval(of: view), 1.0 / 60.0, "halo should animate at full frame rate normally")

    view.mouseDown(with: interactionEvent(type: .leftMouseDown))
    view.mouseDragged(with: interactionEvent(type: .leftMouseDragged, location: NSPoint(x: 34, y: 30)))
    expectApproximately(animationFrameInterval(of: view), 1.0 / 15.0, "dragging halo should reduce animation frame rate")

    view.mouseUp(with: interactionEvent(type: .leftMouseUp))
    expectApproximately(animationFrameInterval(of: view), 1.0 / 60.0, "halo should restore full frame rate after dragging")
}

@MainActor
private func testHaloSizeResizeKeepsWindowOrigin() {
    let oldFrame = NSRect(x: 520, y: 640, width: 112, height: 112)

    let resizedFrame = AppDelegate.haloFrameByKeepingOrigin(oldFrame: oldFrame, requestedSize: 168)

    expect(resizedFrame.origin == oldFrame.origin, "halo size slider should not move the halo window origin")
    expect(resizedFrame.size == NSSize(width: 168, height: 168), "halo size slider should resize the halo window")
}

private func expectApproximately(_ actual: TimeInterval, _ expected: TimeInterval, _ message: String) {
    if abs(actual - expected) > 0.001 {
        fatalError("\(message): expected \(expected), got \(actual)")
    }
}

private func animationFrameInterval(of view: HaloView) -> TimeInterval {
    guard let timerValue = Mirror(reflecting: view).children.first(where: { $0.label == "animationTimer" })?.value else {
        fatalError("halo view should expose animation timer for checks")
    }
    let optionalMirror = Mirror(reflecting: timerValue)
    guard let timer = optionalMirror.children.first?.value as? Timer else {
        fatalError("halo view should have an animation timer")
    }
    return timer.timeInterval
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
        AppDelegate.haloWindowLevel(alwaysOnTop: true) == .screenSaver,
        "always-on-top halo should use an overlay window level"
    )
    expect(
        AppDelegate.haloWindowLevel(alwaysOnTop: false) == .normal,
        "non-topmost halo should use the normal window level"
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
        quota: RateLimitSnapshot(primaryUsedPercent: 30, secondaryUsedPercent: 60, contextUsedPercent: 42)
    )

    expect(panel.focusedAgentForTesting == .codex, "details panel should select Codex")
    expect(panel.detailTextForTesting == "Codex 正在待命", "Codex idle copy should be localized")
    expect(panel.contextPillHiddenForTesting == false, "Codex context pill should be visible")
    expect(panel.primaryQuotaHiddenForTesting == false, "Codex primary quota should be visible")
    expect(panel.secondaryQuotaHiddenForTesting == false, "Codex secondary quota should be visible")
}

@MainActor
private func testDetailsPanelHidesQuotaForClaudeCode() {
    let panel = DetailsPanel()
    let aggregate = AggregateSnapshot(
        state: .idle,
        label: "READY",
        detail: AgentKind.claudeCode.standbyDetail,
        sessions: [],
        focusedAgent: .claudeCode
    )

    panel.update(aggregate: aggregate, quota: nil)

    expect(panel.focusedAgentForTesting == .claudeCode, "details panel should select Claude Code")
    expect(panel.detailTextForTesting == "Claude Code 正在待命", "Claude Code idle copy should be localized")
    expect(panel.contextPillHiddenForTesting == true, "Claude Code context pill should be hidden")
    expect(panel.primaryQuotaHiddenForTesting == true, "Claude Code primary quota should be hidden")
    expect(panel.secondaryQuotaHiddenForTesting == true, "Claude Code secondary quota should be hidden")
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
        quota: nil
    )

    panel.selectAgentForTesting(.claudeCode)

    expect(selected == .claudeCode, "details panel switch should emit selected agent")
}
