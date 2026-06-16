import AppKit

private func expect(_ condition: Bool, _ message: String) {
    if !condition {
        fatalError(message)
    }
}

@MainActor
func runHaloInteractionChecks() {
    testRightClickInvokesContextMenuCallback()
    testSingleClickInvokesPrimaryAction()
    testHaloContextMenuContainsCurrentControls()
    testAlwaysOnTopUsesOverlayWindowLevel()
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
    let delegate = AppDelegate(codexActivator: {
        activations += 1
    })

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
    expect(titles.contains("预览状态"), "halo context menu should include preview submenu")
    expect(!titles.contains("切换到 Codex"), "halo context menu should not include Codex activation")
    expect(!titles.contains("退出 Agent Halo"), "halo context menu should not include old quit title")
    expect(titles.contains("退出"), "halo context menu should include quit")
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
