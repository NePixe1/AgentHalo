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
    testPreviewSubmenuMarksLiveStateInitially()
    testPreviewSubmenuMovesCheckmarkAfterSelection()
    testAlwaysOnTopUsesOverlayWindowLevel()
    testFocusSubmenuMarksCodexInitially()
    testFocusSubmenuSwitchesToClaudeCode()
    testSingleClickDoesNotActivateCodexWhenClaudeCodeFocused()
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
