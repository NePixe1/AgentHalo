import AppKit

private func expect(_ condition: Bool, _ message: String) {
    if !condition {
        fatalError(message)
    }
}

@MainActor
func runHaloInteractionChecks() {
    testRightClickInvokesContextMenuCallback()
    testHaloContextMenuContainsCloseAction()
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
private func testHaloContextMenuContainsCloseAction() {
    let delegate = AppDelegate()
    let menu = delegate.makeHaloContextMenu()
    let item = menu.item(at: 0)

    expect(menu.items.count == 1, "halo context menu should contain one item")
    expect(item?.title == "关闭圆环", "halo context menu should label the close item")
    expect(item?.target as AnyObject === delegate, "halo context menu close item should target app delegate")
    expect(item?.action.map(NSStringFromSelector) == "quit", "halo context menu close item should quit")
}
