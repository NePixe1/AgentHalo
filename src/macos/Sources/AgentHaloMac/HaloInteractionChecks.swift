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
    L10n.shared.setLanguage("zh")
    testDetailsPanelUsesEvenPointHeight()
    testDetailsPanelPixelAlignmentUsesBackingScale()
    testDetailsPanelPositioningSnapsToBackingPixels()
    testL10nEnglishSwitchProducesEnglishStrings()
    testLanguageMenuStateSeparatesAutoFromResolvedLanguage()
    testManualLanguagePreferenceSurvivesMatchingSystemLanguage()
    testRightClickInvokesContextMenuCallback()
    testSingleClickDoesNotActivateCodex()
    testHaloContextMenuContainsCurrentControls()
    testHaloClickWaitsForMouseUpAndDragCancelsClick()
    testHaloHoverUsesFilledCircularSurface()
    testDraggingHaloSuppressesHoverDetails()
    testDraggingHaloPausesAnimationDuringDrag()
    testHaloSizeResizeKeepsWindowOrigin()
    testMissingPreferredDisplayRequiresFallbackDespiteCurrentSliver()
    testReconnectedPreferredDisplayRestoresRelativePlacement()
    testUserMoveDuringFallbackReplacesOldDisplayPreference()
    testLegacyPlacementWaitsForItsDisplayAndThenMigrates()
    testRestoredPlacementClampsInsideChangedVisibleFrame()
    testTemporaryFallbackStateProtectsPreferredPlacementUntilUserMove()
    testDisplayRecoveryWiresPreferredPlacementWithoutPersistingFallback()
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
    testClaudeLiveStandbyUsesStableGreenAggregate()
    testCodexRunningIdleUsesStableGreenAggregate()
    testPausedAgentDoesNotUseStableGreenStandby()
    testLiveCodexErrorCyclesThroughBrightAndDimPresentations()
    testDetailsPanelShowsCodexQuotaAndIdleCopy()
    testDetailsPanelShowsCodexStandbyCopy()
    testDetailsPanelShowsSessionMetadataForCodexAndClaudeCode()
    testDetailsPanelUsesCompactMetadataLayout()
    testVisibleDetailsPanelStatusRefreshIsWiredToTick()
    testStatusLineConfigurationReconciliationIsWiredToTick()
    testCodexPollingWorkIsNotPerformedOnMainTick()
    testCodexActivityDispatchIsThrottled()
    testCodexSQLiteReadersUseInProcessSQLite()
    testCodexSQLiteReadersUseRecentRowWindows()
    testCodexAppDetectorCachesRunningApplicationScans()
    testSessionMonitorsUseFastFileMetadata()
    testClaudePollingIsThrottledWhenCodexFocused()
    testClaudeLiveSessionsRefreshIsThrottled()
    testHaloUsesShapeLayersNotCpuRasterization()
    testIdleAnimationUsesLowPowerCadence()
    testDetailsPresentationUsesFocusedSessionAndRejectsStaleQuota()
    testClaudeStandbyDetailsPreferLiveSessionIdentity()
    testClaudeUsageFreshnessTracksExactLiveSession()
    testDetailsPanelUsesTightBottomInset()
    testDetailsPanelShowsExpiredQuotaAsWaitingForRefresh()
    testDetailsPanelShowsAnswerStreamingCopy()
    testDetailsPanelRefreshesStatusFromLatestAggregate()
    testDetailsPanelLocalizesClaudeActivityDetails()
    testDetailsPanelShowsContextAndHidesQuotaForClaudeCode()
    testAgentToggleUsesSharedSVGAssets()
    testAgentToggleUsesCodexAndClaudeIcons()
    testAgentToggleKeepsWholeControlClickable()
    testDetailsPanelSwitchCallbackSelectsClaudeCode()
}

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

@MainActor
private func testDisplayRecoveryWiresPreferredPlacementWithoutPersistingFallback() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appDelegateURL = sourceDirectory.appendingPathComponent("AppDelegate.swift")
    guard let source = try? String(contentsOf: appDelegateURL, encoding: .utf8) else {
        fatalError("AppDelegate source should be readable")
    }

    expect(
        source.contains("placementState.didUseTemporaryFallback()"),
        "display loss should enter temporary fallback"
    )
    expect(
        source.contains("placementState.didApplyPreferredPlacement()"),
        "display return should leave temporary fallback"
    )
    expect(
        source.contains("self?.commitPreferredPlacement(frame: frame)"),
        "user movement should commit preferred placement"
    )
    expect(
        source.contains("placementState.shouldPersistCurrentFrame"),
        "termination should protect fallback coordinates"
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
private func testSingleClickDoesNotActivateCodex() {
    var activations = 0
    let delegate = AppDelegate(
        settingsStore: SettingsStore(settingsURL: temporarySettingsURL()),
        codexActivator: {
            activations += 1
        }
    )

    delegate.handleHaloPrimaryClick()

    expect(activations == 0, "single click should not activate Codex")
}

@MainActor
private func testHaloContextMenuContainsCurrentControls() {
    let delegate = AppDelegate()
    let menu = delegate.makeHaloContextMenu()
    let titles = menu.items.map(\.title)

    expect(menu.items.count >= 7, "halo context menu should expose the control menu")
    expect(!titles.contains(L10n.shared["status.done"]), "halo context menu should not include completion acknowledgement")
    expect(!titles.contains(L10n.shared["status.error"]), "halo context menu should not include error acknowledgement")
    expect(titles.contains(L10n.shared["menu.always_on_top"]), "halo context menu should include always-on-top")
    expect(titles.contains(L10n.shared["menu.pause_monitor"]), "halo context menu should include pause")
    expect(titles.contains(L10n.shared["halo.size"]), "halo context menu should include size slider")
    guard let sizeItem = menu.items.first(where: { $0.title == L10n.shared["halo.size"] }) else {
        fatalError("halo context menu should expose size slider item")
    }
    let sliders = sizeItem.view?.subviews.compactMap { $0 as? NSSlider } ?? []
    expect(sliders.count == 1, "halo size menu item should contain one slider")
    expect(sliders[0].minValue <= 72, "halo size slider should allow smaller halo")
    expect(sliders[0].maxValue >= 180, "halo size slider should allow larger halo")
    sizeItem.view?.layoutSubtreeIfNeeded()
    let sizeLabels = sizeItem.view?.subviews.compactMap { $0 as? NSTextField }
        .filter { $0.stringValue == L10n.shared["halo.size"] } ?? []
    expect(sizeLabels.count == 1, "halo size menu item should contain one title label")
    expect(sizeLabels[0].frame.minX >= 19, "halo size row label should align with regular menu text")
    expect(sizeLabels[0].frame.minX <= 23, "halo size row label should not drift past regular menu text")
    expect(titles.contains(L10n.shared["menu.preview_status"]), "halo context menu should include preview submenu")
    expect(!titles.contains("Switch to Codex"), "halo context menu should not include Codex activation")
    expect(!titles.contains("Quit Agent Halo"), "halo context menu should not include old quit title")
    expect(titles.contains(L10n.shared["menu.quit"]), "halo context menu should include quit")
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

    expect(checkedTitles == [L10n.shared["halo.live_status"]], "live preview item should be checked initially")
}

@MainActor
private func testPreviewSubmenuMovesCheckmarkAfterSelection() {
    let delegate = AppDelegate()
    let submenu = previewSubmenu(in: delegate.makeHaloContextMenu())
    let workingItem = menuItem(titled: L10n.shared["halo.working_preview"], in: submenu)

    NSApplication.shared.sendAction(workingItem.action!, to: workingItem.target, from: workingItem)

    let refreshedSubmenu = previewSubmenu(in: delegate.makeHaloContextMenu())
    let checkedTitles = refreshedSubmenu.items.filter { $0.state == .on }.map(\.title)

    expect(checkedTitles == [L10n.shared["halo.working_preview"]], "selected preview item should be checked after selection")
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

@MainActor
private func testClaudeLiveStandbyUsesStableGreenAggregate() {
    let idle = AggregateSnapshot(
        state: .idle,
        label: "OFFLINE",
        detail: AgentKind.claudeCode.offlineDetail,
        sessions: [],
        focusedAgent: .claudeCode
    )

    let standby = AppDelegate.standbyAggregate(aggregate: idle, hasLiveSession: true)
    expect(standby.state, .done, "live idle Claude Code should use the stable green state")
    expect(standby.label, "STANDBY", "live idle Claude Code label")
    expect(standby.detail, AgentKind.claudeCode.localizedStandbyDetail, "live idle Claude Code detail")

    let offline = AppDelegate.standbyAggregate(aggregate: idle, hasLiveSession: false)
    expect(offline, idle, "offline Claude Code should retain the normal idle aggregate")
}

@MainActor
private func testCodexRunningIdleUsesStableGreenAggregate() {
    let idle = AggregateSnapshot(
        state: .idle,
        label: "OFFLINE",
        detail: AgentKind.codex.offlineDetail,
        sessions: [],
        focusedAgent: .codex
    )

    let standby = AppDelegate.standbyAggregate(aggregate: idle, hasLiveSession: true)
    expect(standby.state, .done, "running idle Codex should use the stable green state")
    expect(standby.label, "STANDBY", "running idle Codex label")
    expect(standby.detail, AgentKind.codex.localizedStandbyDetail, "running idle Codex detail")
    expect(standby.sessions.isEmpty, "running idle Codex standby should not look like a completed session")
}

@MainActor
private func testPausedAgentDoesNotUseStableGreenStandby() {
    for agent in AgentKind.allCases {
        let paused = AggregateSnapshot(
            state: .idle,
            label: "PAUSED",
            detail: "Monitoring paused",
            sessions: [],
            focusedAgent: agent
        )

        let displayed = AppDelegate.standbyAggregate(
            aggregate: paused,
            hasLiveSession: true
        )
        expect(displayed, paused, "paused \(agent.menuTitle) should retain the idle presentation")
    }
}

@MainActor
private func testLiveCodexErrorCyclesThroughBrightAndDimPresentations() {
    let eventAt = Date(timeIntervalSince1970: 1_750_000_000)
    let errorSession = SessionSnapshot(
        threadId: "codex-error",
        projectName: "AgentHalo",
        workingDirectory: "/tmp/AgentHalo",
        state: .error,
        action: "Connection failed",
        lastEventAt: eventAt,
        completedAt: nil,
        active: false,
        agent: .codex
    )
    let aggregate = AggregateSnapshot(
        state: .error,
        label: "INTERRUPTED",
        detail: "Connection failed",
        sessions: [errorSession],
        focusedAgent: .codex
    )
    var state = LiveErrorPresentationState()

    let flashing = state.update(
        aggregate: aggregate,
        codexIsForeground: false,
        codexWasForeground: false,
        now: eventAt
    )
    expect(flashing.presentation, .flashing, "background Codex error should begin by flashing")
    expect(flashing.acknowledgeErrorAt == nil, "new Codex error should remain visible")

    let bright = state.update(
        aggregate: aggregate,
        codexIsForeground: true,
        codexWasForeground: false,
        now: eventAt.addingTimeInterval(1)
    )
    expect(bright.presentation, .bright, "foreground Codex error should become bright")

    let dim = state.update(
        aggregate: aggregate,
        codexIsForeground: false,
        codexWasForeground: true,
        now: eventAt.addingTimeInterval(2)
    )
    expect(dim.presentation, .dim, "Codex error should become dim after leaving the foreground")

    let stillDim = state.update(
        aggregate: aggregate,
        codexIsForeground: false,
        codexWasForeground: false,
        now: eventAt.addingTimeInterval(61)
    )
    expect(stillDim.presentation, .dim, "dim Codex error should remain visible for one minute")
    expect(stillDim.acknowledgeErrorAt == nil, "dim Codex error should not acknowledge early")

    let acknowledged = state.update(
        aggregate: aggregate,
        codexIsForeground: false,
        codexWasForeground: false,
        now: eventAt.addingTimeInterval(63)
    )
    expect(acknowledged.acknowledgeErrorAt, eventAt, "dim Codex error should acknowledge after one minute")
}

private func previewSubmenu(in menu: NSMenu) -> NSMenu {
    guard let preview = menu.items.first(where: { $0.title == L10n.shared["menu.preview_status"] })?.submenu else {
        fatalError("preview submenu should exist")
    }
    return preview
}

private func focusedAgentSubmenu(in menu: NSMenu) -> NSMenu {
    guard let focus = menu.items.first(where: { $0.title == L10n.shared["menu.focus_target"] })?.submenu else {
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
        label: "OFFLINE",
        detail: AgentKind.codex.offlineDetail,
        sessions: [],
        focusedAgent: .codex
    )

    panel.update(
        aggregate: aggregate,
        quota: RateLimitSnapshot(primaryUsedPercent: 30, secondaryUsedPercent: 60, contextUsedPercent: 42),
        contextUsedPercent: 42
    )

    expect(panel.focusedAgentForTesting == .codex, "details panel should select Codex")
    expect(panel.detailTextForTesting == L10n.shared["status.offline_codex"], "Codex offline copy should be localized")
    // OFFLINE has no live session, so the context pill should drop out
    // entirely rather than echo a stale percentage from a prior session.
    expect(panel.contextPillHiddenForTesting == true, "Codex context pill should be hidden when OFFLINE")
    expect(panel.primaryQuotaHiddenForTesting == false, "Codex primary quota should be visible")
    expect(panel.secondaryQuotaHiddenForTesting == false, "Codex secondary quota should be visible")
}

@MainActor
private func testDetailsPanelShowsCodexStandbyCopy() {
    let panel = DetailsPanel()
    // AppDelegate projects a running-but-idle Codex to STANDBY; the panel must
    // surface the standby copy rather than the offline one in that case.
    let aggregate = AggregateSnapshot(
        state: .done,
        label: "STANDBY",
        detail: AgentKind.codex.localizedStandbyDetail,
        sessions: [],
        focusedAgent: .codex
    )

    panel.update(aggregate: aggregate, quota: nil, contextUsedPercent: nil)

    expect(panel.detailTextForTesting == L10n.shared["status.standby_codex"], "Codex standby copy should be localized")
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
    expect(panel.tokenValueForTesting, "↑ 38k  ·  ↓ 1.2k", "details token value")

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
    expect(panel.tokenValueForTesting, "↑ 38k  ·  ↓ 1.2k", "Claude Code token value")
}

@MainActor
private func testDetailsPanelUsesCompactMetadataLayout() {
    let panel = DetailsPanel()
    guard let contentView = panel.contentView else {
        fatalError("details panel should have a content view")
    }
    let metadataGroup = allDescendants(of: contentView)
        .compactMap { $0 as? NSStackView }
        .first { stack in
            let labels = allDescendants(of: stack)
                .compactMap { $0 as? NSTextField }
                .map(\.stringValue)
            let firstLabels = stack.arrangedSubviews.first.map {
                ([$0] + allDescendants(of: $0))
                    .compactMap { $0 as? NSTextField }
                    .map(\.stringValue)
            } ?? []
            return labels.contains(L10n.shared["metadata.project"]) && labels.contains(L10n.shared["metadata.model"]) && labels.contains(L10n.shared["metadata.tokens"])
                && firstLabels.contains(L10n.shared["metadata.project"])
        }

    guard let metadataGroup else {
        fatalError("details panel should expose its metadata group")
    }
    expect(
        metadataGroup.arrangedSubviews.count,
        5,
        "metadata should separate project from model and model from token"
    )
    let arranged = metadataGroup.arrangedSubviews
    for item in arranged.dropLast() {
        expect(
            metadataGroup.customSpacing(after: item) == NSStackView.useDefaultSpacing,
            "metadata rows and separators should not use asymmetric custom spacing"
        )
    }
    for row in [arranged[0], arranged[2], arranged[4]] {
        expect(
            row.constraints.contains { $0.firstAttribute == .height && $0.constant == 28 },
            "each metadata row should use the same 28pt height"
        )
    }
    for separator in [arranged[1], arranged[3]] {
        expect(
            separator.constraints.contains { $0.firstAttribute == .height && $0.constant == 1 },
            "each metadata separator should be a standalone 1pt rule"
        )
    }
}

@MainActor
private func testDetailsPanelUsesTightBottomInset() {
    let panel = DetailsPanel()
    guard let contentView = panel.contentView,
          let contentStack = allDescendants(of: contentView)
            .compactMap({ $0 as? NSStackView })
            .first(where: { $0.edgeInsets.top == 14 && $0.edgeInsets.left == 17 }) else {
        fatalError("details panel should expose its content stack")
    }

    expect(contentStack.edgeInsets.bottom, 4, "details panel bottom inset")
}

@MainActor
private func testDetailsPanelUsesEvenPointHeight() {
    let panel = DetailsPanel()
    expect(Int(panel.frame.height) % 2 == 0, "details panel height should avoid half-point vertical centering")
}

@MainActor
private func testDetailsPanelPixelAlignmentUsesBackingScale() {
    expect(
        AppDelegate.pixelAlignedOrigin(CGPoint(x: 20.25, y: 40.5), backingScaleFactor: 1),
        CGPoint(x: 20, y: 41),
        "1x displays should snap details panel origins to whole points"
    )
    expect(
        AppDelegate.pixelAlignedOrigin(CGPoint(x: 20.25, y: 40.5), backingScaleFactor: 2),
        CGPoint(x: 20.5, y: 40.5),
        "Retina displays should preserve half-point origins that land on physical pixels"
    )
}

private func testDetailsPanelPositioningSnapsToBackingPixels() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appDelegateURL = sourceDirectory.appendingPathComponent("AppDelegate.swift")
    guard let source = try? String(contentsOf: appDelegateURL, encoding: .utf8),
          let positionStart = source.range(of: "    private func positionDetailsPanel() {")?.lowerBound,
          let positionEnd = source.range(of: "    private func displayAggregate()", range: positionStart..<source.endIndex)?.lowerBound else {
        fatalError("AppDelegate positionDetailsPanel source should be readable")
    }

    let positionSource = source[positionStart..<positionEnd]
    expect(
        !positionSource.contains("detailsPanel.setFrameOrigin(CGPoint(x: max(area.minX + 8, min(x, area.maxX - detailsPanel.frame.width - 8)), y: y))"),
        "details panel should not set a raw unsnapped origin"
    )
    expect(
        positionSource.contains("backingScaleFactor") && positionSource.contains(".rounded()"),
        "details panel origin should be snapped to physical pixels before first display"
    )
    expect(
        positionSource.contains("layoutSubtreeIfNeeded()") && positionSource.contains("displayIfNeeded()"),
        "details panel should flush layout and drawing before orderFront"
    )
}

@MainActor
private func testDetailsPanelShowsExpiredQuotaAsWaitingForRefresh() {
    let panel = DetailsPanel()
    let aggregate = AggregateSnapshot(
        state: .idle,
        label: "OFFLINE",
        detail: AgentKind.codex.offlineDetail,
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

    expect(panel.primaryQuotaValueForTesting == L10n.shared["quota.waiting_refresh"], "expired primary quota should wait for Codex refresh")
    expect(panel.secondaryQuotaValueForTesting == L10n.shared.format("quota.remaining", 40), "valid secondary quota should keep remaining percent")
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

    expect(panel.detailTextForTesting == L10n.shared["status.writing_answer"], "answer streaming should use localized copy")
}

@MainActor
private func testDetailsPanelRefreshesStatusFromLatestAggregate() {
    let panel = DetailsPanel()
    panel.update(
        aggregate: AggregateSnapshot(
            state: .thinking,
            label: "THINKING",
            detail: "AgentHalo - Planning",
            sessions: [],
            focusedAgent: .claudeCode
        ),
        quota: nil,
        contextUsedPercent: 27
    )

    panel.updateStatus(aggregate: AggregateSnapshot(
        state: .working,
        label: "EXECUTING",
        detail: "AgentHalo - Running command",
        sessions: [],
        focusedAgent: .claudeCode
    ))

    expect(panel.titleTextForTesting == "EXECUTING", "visible details should use the latest status label")
    expect(panel.detailTextForTesting == L10n.shared["status.running_command"], "visible details should use the latest activity detail")
    expect(panel.contextValueForTesting == L10n.shared.format("context.label", 27), "status refresh should preserve existing metadata")
}

private func testVisibleDetailsPanelStatusRefreshIsWiredToTick() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appDelegateURL = sourceDirectory.appendingPathComponent("AppDelegate.swift")
    guard let source = try? String(contentsOf: appDelegateURL, encoding: .utf8),
          let tickStart = source.range(of: "    private func tick() {")?.lowerBound,
          let tickEnd = source.range(of: "    private func createStatusItem()", range: tickStart..<source.endIndex)?.lowerBound else {
        fatalError("AppDelegate tick source should be readable")
    }

    let tickSource = source[tickStart..<tickEnd]
    expect(
        tickSource.contains("refreshVisibleDetailsStatus()"),
        "tick should refresh visible status without rebuilding details metadata"
    )
    expect(
        !tickSource.contains("refreshVisibleDetailsPanel()"),
        "tick must not run full details refresh because it reads metadata and quota on the main thread"
    )
    expect(
        source.contains("private func refreshVisibleDetailsStatus()"),
        "AppDelegate should keep a status-only visible details refresh path"
    )
    expect(
        source.contains("detailsPanel.updateStatus(aggregate: displayAggregate())"),
        "status-only refresh should preserve existing details metadata and layout"
    )
}

private func testStatusLineConfigurationReconciliationIsWiredToTick() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appDelegateURL = sourceDirectory.appendingPathComponent("AppDelegate.swift")
    guard let source = try? String(contentsOf: appDelegateURL, encoding: .utf8),
          let tickStart = source.range(of: "    private func tick() {")?.lowerBound,
          let tickEnd = source.range(of: "    private func createStatusItem()", range: tickStart..<source.endIndex)?.lowerBound else {
        fatalError("AppDelegate tick source should be readable")
    }

    let tickSource = source[tickStart..<tickEnd]
    expect(
        tickSource.contains("reconcileClaudeStatusLineConfiguration(now:"),
        "AppDelegate tick should reconcile status-line drift"
    )
}

private func testCodexPollingWorkIsNotPerformedOnMainTick() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appDelegateURL = sourceDirectory.appendingPathComponent("AppDelegate.swift")
    guard let source = try? String(contentsOf: appDelegateURL, encoding: .utf8),
          let tickStart = source.range(of: "    private func tick() {")?.lowerBound,
          let tickEnd = source.range(of: "    private func createStatusItem()", range: tickStart..<source.endIndex)?.lowerBound else {
        fatalError("AppDelegate tick source should be readable")
    }

    let tickSource = source[tickStart..<tickEnd]
    expect(
        !tickSource.contains("_ = monitor.refresh()"),
        "main tick should not synchronously refresh Codex sessions"
    )
    expect(
        !tickSource.contains("failureReader.readRecent("),
        "main tick should not synchronously query Codex failures"
    )
    expect(
        source.contains("private let codexActivityMonitor"),
        "Codex polling should move behind a background activity monitor"
    )
}

private func testCodexActivityDispatchIsThrottled() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let monitorURL = sourceDirectory.appendingPathComponent("CodexActivityMonitor.swift")
    guard let source = try? String(contentsOf: monitorURL, encoding: .utf8) else {
        fatalError("CodexActivityMonitor source should be readable")
    }

    expect(source.contains("dispatchThrottleSeconds"), "Codex activity dispatch should define a throttle window")
    expect(source.contains("pendingSnapshot"), "Codex activity dispatch should coalesce bursts into a pending snapshot")
    expect(source.contains("pendingDispatchWorkItem"), "Codex activity dispatch should schedule a trailing delivery")
    expect(source.contains("asyncAfter"), "Codex activity dispatch should defer the trailing delivery to the utility queue")
    expect(source.contains("DispatchQueue.main.async"), "Codex activity dispatch should still hop to the main thread for onChange")
}

private func testCodexSQLiteReadersUseInProcessSQLite() {
    let sourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("AgentHaloCore")
    let failureURL = sourceDirectory.appendingPathComponent("CodexFailureReader.swift")
    let realtimeURL = sourceDirectory.appendingPathComponent("CodexRealtimeActivityReader.swift")
    guard let failureSource = try? String(contentsOf: failureURL, encoding: .utf8),
          let realtimeSource = try? String(contentsOf: realtimeURL, encoding: .utf8) else {
        fatalError("Codex SQLite reader sources should be readable")
    }

    let combined = failureSource + "\n" + realtimeSource
    expect(!combined.contains("Process()"), "Codex SQLite readers should not launch sqlite3 subprocesses")
    expect(!combined.contains("waitUntilExit()"), "Codex SQLite readers should not block on sqlite3 subprocesses")
    expect(!combined.contains("sqlitePath"), "Codex SQLite readers should not depend on an external sqlite3 path")
    expect(combined.contains("CodexSQLiteLogStore"), "Codex SQLite readers should share the in-process SQLite store")
}

private func testCodexSQLiteReadersUseRecentRowWindows() {
    let sourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("AgentHaloCore")
    let failureURL = sourceDirectory.appendingPathComponent("CodexFailureReader.swift")
    let realtimeURL = sourceDirectory.appendingPathComponent("CodexRealtimeActivityReader.swift")
    guard let failureSource = try? String(contentsOf: failureURL, encoding: .utf8),
          let realtimeSource = try? String(contentsOf: realtimeURL, encoding: .utf8) else {
        fatalError("Codex SQLite reader sources should be readable")
    }

    expect(
        !realtimeSource.contains("where ts >="),
        "realtime reader should not scan the logs table with a timestamp predicate"
    )
    // The failure reader pushes the 120s cutoff into SQL as `ts >= ?` and orders
    // by the idx_logs_ts key so SQLite SEEKS the index (ts>?) and scans only the
    // recent window. The previous `order by id desc` plus the non-indexable
    // `lower(level)` predicate forced a full backward btree scan of the entire
    // logs table on every 2s poll; errors are rare enough that the PK-ordered
    // scan touched most of the table before collecting 256 error rows.
    expect(
        failureSource.contains("and ts>="),
        "failure reader should bound its scan to the recent window via idx_logs_ts (ts>=?) instead of a full backward btree scan"
    )
    expect(
        failureSource.contains("order by ts desc, ts_nanos desc, id desc limit 256"),
        "failure reader should order by the idx_logs_ts key so SQLite seeks the index"
    )
    expect(
        realtimeSource.contains("order by id desc limit 512"),
        "realtime reader should inspect a bounded recent row window"
    )
    // Cheap equality predicates are pushed server-side so only matching rows
    // (and their feedback_log_body) are materialized and transferred, instead
    // of reading a full window of arbitrary rows and discarding the rest.
    expect(
        failureSource.contains("where lower(level)='error'"),
        "failure reader should filter error rows server-side instead of transferring all levels"
    )
    expect(
        realtimeSource.contains("where target='codex_api::sse::responses'"),
        "realtime reader should filter SSE response rows server-side instead of transferring all targets"
    )
}

private func testCodexAppDetectorCachesRunningApplicationScans() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let detectorURL = sourceDirectory.appendingPathComponent("CodexAppDetector.swift")
    guard let source = try? String(contentsOf: detectorURL, encoding: .utf8) else {
        fatalError("CodexAppDetector source should be readable")
    }

    expect(source.contains("runningCacheExpiresAt"), "Codex running detection should cache app scans")
    expect(source.contains("runningCacheInterval"), "Codex running detection should throttle LaunchServices work")
    expect(source.contains("executableURL"), "Codex app detection should prefer cheap executable metadata before localizedName")
    expect(source.contains("allowLocalizedName: false"), "Codex running scans should skip localizedName fallback")
}

private func testSessionMonitorsUseFastFileMetadata() {
    let sourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("AgentHaloCore")
    for fileName in ["CodexSessionMonitor.swift", "ClaudeSessionMonitor.swift", "ClaudeHookStatusMonitor.swift"] {
        let url = sourceDirectory.appendingPathComponent(fileName)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("\(fileName) should be readable")
        }
        expect(
            !source.contains("attributesOfItem"),
            "\(fileName) should not use Foundation attributes in high-frequency refresh"
        )
        expect(
            source.contains("FastFileMetadata.read"),
            "\(fileName) should use POSIX stat-backed file metadata"
        )
    }
}

private func testClaudePollingIsThrottledWhenCodexFocused() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let monitorURL = sourceDirectory.appendingPathComponent("ClaudeActivityMonitor.swift")
    guard let monitorSource = try? String(contentsOf: monitorURL, encoding: .utf8) else {
        fatalError("ClaudeActivityMonitor source should be readable")
    }
    let appDelegateURL = sourceDirectory.appendingPathComponent("AppDelegate.swift")
    guard let appDelegateSource = try? String(contentsOf: appDelegateURL, encoding: .utf8) else {
        fatalError("AppDelegate source should be readable")
    }

    expect(monitorSource.contains("idleIntervalMilliseconds"), "Claude activity monitor should define a slower idle cadence")
    expect(monitorSource.contains("activeIntervalMilliseconds"), "Claude activity monitor should define an active cadence")
    expect(monitorSource.contains("focusedAgent == .claudeCode"), "Claude polling should slow down when Claude Code is not focused")
    expect(monitorSource.contains("dispatchThrottleSeconds"), "Claude activity dispatch should throttle main-thread wakeups")
    expect(appDelegateSource.contains("claudeActivityMonitor"), "AppDelegate should delegate Claude polling to a background monitor")
    expect(!appDelegateSource.contains("refreshClaudeSourcesIfNeeded"), "AppDelegate should not poll Claude sources on the main tick")
    expect(!appDelegateSource.contains("claudeHookMonitor.refresh"), "AppDelegate should not refresh Claude hook status on the main thread")
    expect(!appDelegateSource.contains("claudeSessionMonitor.refresh"), "AppDelegate should not refresh Claude transcripts on the main thread")
}

private func testHaloUsesShapeLayersNotCpuRasterization() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let haloViewURL = sourceDirectory.appendingPathComponent("HaloView.swift")
    guard let haloViewSource = try? String(contentsOf: haloViewURL, encoding: .utf8) else {
        fatalError("HaloView source should be readable")
    }
    let rendererURL = sourceDirectory.appendingPathComponent("HaloRenderer.swift")
    guard let rendererSource = try? String(contentsOf: rendererURL, encoding: .utf8) else {
        fatalError("HaloRenderer source should be readable")
    }

    expect(haloViewSource.contains("CAShapeLayer"), "HaloView should host ring strokes as CAShapeLayer sublayers")
    expect(haloViewSource.contains("ringLayers"), "HaloView should keep a ringLayers array")
    expect(haloViewSource.contains("setupRingLayers"), "HaloView should set up shape sublayers")
    expect(haloViewSource.contains("redrawRing"), "HaloView should refresh shape layers via redrawRing")
    expect(haloViewSource.contains("HaloRenderer.applyRingLayers"), "HaloView should apply ring layers through HaloRenderer")
    expect(!haloViewSource.contains("override func draw(_ dirtyRect"), "HaloView should not rasterize via draw(_:) CPU backing store")
    expect(!haloViewSource.contains("needsDisplay = true"), "HaloView should not drive CPU rasterization via needsDisplay")
    expect(rendererSource.contains("applyRingLayers"), "HaloRenderer should expose applyRingLayers for shape-layer rendering")
    expect(rendererSource.contains("ringLayerCount"), "HaloRenderer should declare the fixed ring layer count")
    expect(rendererSource.contains("CATransaction.setDisableActions(true)"), "HaloRenderer should disable implicit animations so per-frame updates snap instead of smoothing")
    expect(rendererSource.contains("path.move(to: startPoint)"), "HaloRenderer should start each ring arc as a fresh subpath so the two gaps are not bridged by a connecting chord")
}

private func testClaudeLiveSessionsRefreshIsThrottled() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let monitorURL = sourceDirectory.appendingPathComponent("ClaudeActivityMonitor.swift")
    guard let monitorSource = try? String(contentsOf: monitorURL, encoding: .utf8) else {
        fatalError("ClaudeActivityMonitor source should be readable")
    }

    expect(
        monitorSource.contains("liveSessionsPollIntervalSeconds"),
        "Claude activity monitor should bound live-session reads with a safety interval"
    )
    expect(
        monitorSource.contains("cachedLiveSessions"),
        "Claude activity monitor should cache live sessions between refreshes"
    )
    expect(
        monitorSource.contains("lastLiveSessionsPollAt"),
        "Claude activity monitor should track when live sessions were last read"
    )
    // The expensive reader call must be gated behind a condition, not unconditional.
    expect(
        monitorSource.contains("if forceLiveSessions"),
        "Claude live-session reads should be gated by a force/sources-changed/interval condition"
    )
    expect(
        monitorSource.contains("now.timeIntervalSince(lastLiveSessionsPollAt) >= Self.liveSessionsPollIntervalSeconds"),
        "Claude live-session reads should be bounded by the safety interval"
    )
    // preferredStandbySession must still be recomputed every poll with fresh hooks
    // so standby selection stays responsive without re-reading the sessions dir.
    expect(
        monitorSource.contains("ClaudeLiveSessionReader.preferredStandbySession"),
        "Claude activity monitor should still recompute preferred standby each poll"
    )
}

private func testIdleAnimationUsesLowPowerCadence() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let haloViewURL = sourceDirectory.appendingPathComponent("HaloView.swift")
    guard let source = try? String(contentsOf: haloViewURL, encoding: .utf8) else {
        fatalError("HaloView source should be readable")
    }

    expect(source.contains("lowPowerAnimationInterval"), "HaloView should define a low-power animation interval")
    expect(source.contains("normalAnimationInterval = 1.0 / 60.0"), "HaloView should run active animation at 60fps for smooth orbit motion (cheap once the ring is GPU-rasterized via CAShapeLayer)")
    expect(source.contains("preferredAnimationInterval"), "HaloView should choose animation cadence by visual state")
    expect(source.contains("steadyDone"), "steady standby state should be eligible for low-power animation")
}

@MainActor
private func testClaudeStandbyDetailsPreferLiveSessionIdentity() {
    let now = Date()
    let staleHook = SessionSnapshot(
        threadId: "stale-session",
        projectName: "stale-project",
        workingDirectory: "/tmp/stale-project",
        state: .done,
        action: "Complete",
        lastEventAt: now.addingTimeInterval(-60),
        completedAt: now.addingTimeInterval(-60),
        active: false,
        agent: .claudeCode
    )
    let standby = AggregateSnapshot(
        state: .done,
        label: "STANDBY",
        detail: AgentKind.claudeCode.standbyDetail,
        sessions: [],
        focusedAgent: .claudeCode
    )
    let live = ClaudeLiveSessionSnapshot(
        sessionId: "live-session",
        workingDirectory: "/tmp/live-project",
        processId: 1,
        status: "idle",
        updatedAt: now
    )

    expect(
        AppDelegate.claudeMainSessionIdForDetails(
            displayedAggregate: standby,
            rawClaudeSnapshots: [staleHook],
            liveSession: live
        ),
        "live-session",
        "standby details must use the selected live session before stale hook snapshots"
    )
}

@MainActor
private func testClaudeUsageFreshnessTracksExactLiveSession() {
    let now = Date()
    let live = ClaudeLiveSessionSnapshot(
        sessionId: "live-main",
        workingDirectory: "/tmp/live-project",
        processId: 1,
        status: "busy",
        updatedAt: now
    )
    let other = ClaudeLiveSessionSnapshot(
        sessionId: "other-main",
        workingDirectory: "/tmp/other-project",
        processId: 2,
        status: "idle",
        updatedAt: now
    )

    expect(
        AppDelegate.claudeUsageFreshness(
            mainSessionId: "live-main",
            liveSessions: [live, other]
        ),
        .whileSessionIsLive,
        "an exact live Claude session should retain its last status-line metadata"
    )
    expect(
        AppDelegate.claudeUsageFreshness(
            mainSessionId: "missing-main",
            liveSessions: [live, other]
        ),
        .recentOnly,
        "another live Claude session must not keep stale metadata alive"
    )
    expect(
        AppDelegate.claudeUsageFreshness(mainSessionId: nil, liveSessions: [live]),
        .recentOnly,
        "missing session identity must use the bounded freshness policy"
    )
}

@MainActor
private func testDetailsPanelLocalizesClaudeActivityDetails() {
    let cases: [(action: String, expected: String)] = [
        ("Compressing context", L10n.shared["status.compressing_context"]),
        ("Context compacted", L10n.shared["status.context_compacted"]),
        ("Awaiting permission", L10n.shared["status.awaiting_permission"]),
        ("Permission denied", L10n.shared["status.permission_denied"]),
        ("Reviewing result", L10n.shared["status.reviewing_result"]),
    ]

    for item in cases {
        let aggregate = AggregateSnapshot(
            state: .working,
            label: "EXECUTING",
            detail: "AgentHalo - \(item.action)",
            sessions: [
                SessionSnapshot(
                    threadId: "claude-detail",
                    projectName: "AgentHalo",
                    workingDirectory: "/tmp/AgentHalo",
                    state: .working,
                    action: item.action,
                    lastEventAt: Date(),
                    completedAt: nil,
                    active: true,
                    agent: .claudeCode
                )
            ],
            focusedAgent: .claudeCode
        )

        expect(
            DetailsPanel.localizedDetail(for: aggregate),
            item.expected,
            "details panel should localize \(item.action) precisely"
        )
    }
}

@MainActor
private func testDetailsPanelShowsContextAndHidesQuotaForClaudeCode() {
    let panel = DetailsPanel()
    let aggregate = AggregateSnapshot(
        state: .idle,
        label: "OFFLINE",
        detail: AgentKind.claudeCode.offlineDetail,
        sessions: [],
        focusedAgent: .claudeCode
    )

    panel.update(aggregate: aggregate, quota: nil, contextUsedPercent: 58.4)

    expect(panel.focusedAgentForTesting == .claudeCode, "details panel should select Claude Code")
    expect(panel.detailTextForTesting == L10n.shared["status.offline_claude"], "Claude Code offline copy should be localized")
    // OFFLINE drops the context pill so the panel doesn't carry over a
    // percentage from a session that's no longer live.
    expect(panel.contextPillHiddenForTesting == true, "Claude Code context pill should be hidden when OFFLINE")
    expect(panel.projectValueForTesting == "--", "Claude Code project should be placeholder when OFFLINE")
    expect(panel.modelValueForTesting == "--", "Claude Code model should be placeholder when OFFLINE")
    expect(panel.tokenValueForTesting == "--", "Claude Code tokens should be placeholder when OFFLINE")
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
        claudeMainSessionId: nil,
        mainClaudeSessions: [],
        liveClaudeSession: nil,
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
        claudeMainSessionId: nil,
        mainClaudeSessions: [],
        liveClaudeSession: nil,
        quota: staleQuota,
        claudeUsage: nil
    )
    expect(subscription.showsQuota, "Codex session with rate limits should keep quota UI")

    let claudeSession = SessionSnapshot(
        threadId: "cc-current",
        projectName: "agent-a47ee146bdd2ba852",
        workingDirectory: "/tmp/AgentHalo/.claude/worktrees/agent-a47ee146bdd2ba852",
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
    let mainTranscript = SessionSnapshot(
        threadId: "cc-current",
        projectName: "AgentHalo",
        workingDirectory: "/tmp/AgentHalo",
        state: .idle,
        action: "Ready",
        lastEventAt: now,
        completedAt: nil,
        active: false,
        agent: .claudeCode
    )
    let liveSession = ClaudeLiveSessionSnapshot(
        sessionId: "cc-current",
        workingDirectory: "/tmp/AgentHalo",
        processId: 1,
        status: "idle",
        updatedAt: now
    )
    let claude = AppDelegate.detailsPresentationForDetails(
        focusedAgent: .claudeCode,
        displayedAggregate: claudeAggregate,
        claudeMainSessionId: "cc-current",
        mainClaudeSessions: [mainTranscript],
        liveClaudeSession: liveSession,
        quota: nil,
        claudeUsage: matchingUsage
    )
    expect(!claude.showsQuota, "Claude Code should use metadata UI")
    expect(claude.contextUsedPercent, 58, "Claude Code should retain context usage")
    expect(claude.sessionDetails.projectName, "AgentHalo", "standby details should use the main project")
    expect(claude.sessionDetails.modelName, "claude-sonnet-4", "Claude details should use matching statusline model")

    var mismatchedUsage = matchingUsage
    mismatchedUsage.sessionId = "cc-other"
    let mismatched = AppDelegate.detailsPresentationForDetails(
        focusedAgent: .claudeCode,
        displayedAggregate: claudeAggregate,
        claudeMainSessionId: "cc-current",
        mainClaudeSessions: [mainTranscript],
        liveClaudeSession: liveSession,
        quota: nil,
        claudeUsage: mismatchedUsage
    )
    expect(mismatched.sessionDetails.modelName == nil, "Claude details must reject another session's model")
    expect(mismatched.contextUsedPercent == nil, "Claude details must reject another session's context usage")
}

@MainActor
private func testAgentToggleUsesSharedSVGAssets() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let srcRoot = sourceDirectory
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let assetDirectory = srcRoot.appendingPathComponent("shared/assets/agent-switch", isDirectory: true)
    let codexURL = assetDirectory.appendingPathComponent("codex.svg")
    let claudeURL = assetDirectory.appendingPathComponent("claude-code.svg")
    let detailsSourceURL = sourceDirectory.appendingPathComponent("DetailsPanel.swift")
    let buildScriptURL = srcRoot
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/build-macos.sh")

    expect(FileManager.default.fileExists(atPath: codexURL.path), "Codex SVG should live in shared assets")
    expect(FileManager.default.fileExists(atPath: claudeURL.path), "Claude SVG should live in shared assets")

    let detailsSource = try? String(contentsOf: detailsSourceURL, encoding: .utf8)
    expect(detailsSource?.contains("<svg") == false, "DetailsPanel should not embed SVG markup")

    let buildScript = try? String(contentsOf: buildScriptURL, encoding: .utf8)
    expect(
        buildScript?.contains("src/shared/assets/agent-switch") == true,
        "macOS packaging should copy the shared agent icons"
    )
}

@MainActor
private func testAgentToggleUsesCodexAndClaudeIcons() {
    let toggle = AgentToggleView(frame: NSRect(x: 0, y: 0, width: 110, height: 24))
    let descendants = allDescendants(of: toggle)
    let visibleLabels = descendants
        .compactMap { $0 as? NSTextField }
        .map(\.stringValue)
        .filter { !$0.isEmpty }
    let icons = descendants.compactMap { $0 as? NSImageView }

    expect(!visibleLabels.contains("Codex"), "agent toggle should replace the Codex text with an icon")
    expect(!visibleLabels.contains("CC"), "agent toggle should replace the CC text with an icon")
    expect(icons.count == 2, "agent toggle should render one icon for each agent")
    expect(icons.allSatisfy { $0.image != nil }, "agent toggle should load both shared SVG images")
}

@MainActor
private func testAgentToggleKeepsWholeControlClickable() {
    let toggle = AgentToggleView(frame: NSRect(x: 0, y: 0, width: 110, height: 24))
    toggle.layoutSubtreeIfNeeded()

    expect(
        toggle.hitTest(NSPoint(x: 82, y: 12)) === toggle,
        "agent icons should not intercept clicks from the toggle"
    )
}

@MainActor
private func allDescendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + allDescendants(of: $0) }
}

@MainActor
private func testDetailsPanelSwitchCallbackSelectsClaudeCode() {
    let panel = DetailsPanel()
    var selected: AgentKind?
    panel.onAgentSelected = { selected = $0 }
    panel.update(
        aggregate: AggregateSnapshot(
            state: .idle,
            label: "OFFLINE",
            detail: AgentKind.codex.offlineDetail,
            sessions: [],
            focusedAgent: .codex
        ),
        quota: nil,
        contextUsedPercent: nil
    )

    panel.selectAgentForTesting(.claudeCode)

    expect(selected == .claudeCode, "details panel switch should emit selected agent")
}

/// Switch the L10n singleton to English and verify the translations actually
/// come from the en.json bundle rather than echoing the lookup key. Restores
/// zh afterwards so subsequent zh-anchored assertions in this run still pass.
@MainActor
private func testL10nEnglishSwitchProducesEnglishStrings() {
    L10n.shared.setLanguage("en")
    defer { L10n.shared.setLanguage("zh") }

    expect(L10n.shared.currentLanguage, "en", "explicit en language should be honored")
    expect(L10n.shared["menu.quit"], "Quit", "menu.quit should be English after switch")
    expect(L10n.shared["status.offline_codex"], "Codex Not Running", "Codex offline copy should be English after switch")
    expect(L10n.shared.format("quota.remaining", 42), "42% Remaining", "quota.remaining English formatting")
    expect(L10n.shared.format("context.label", 58), "Context 58%", "context.label English formatting")
    expect(L10n.shared["date.culture"], "en-US", "date.culture should switch alongside language")

    // localizedDetail must reflect the active language too — covers the
    // status.* switch path end-to-end without spinning up a panel.
    let aggregate = AggregateSnapshot(
        state: .idle,
        label: "OFFLINE",
        detail: AgentKind.codex.offlineDetail,
        sessions: [],
        focusedAgent: .codex
    )
    expect(
        DetailsPanel.localizedDetail(for: aggregate),
        L10n.shared["status.offline_codex"],
        "DetailsPanel.localizedDetail should follow the active language"
    )

    // formatResetTime must honor date.culture (en-US) rather than zh-CN.
    // Pin to a known instant so the English locale produces "Jan 5",
    // not the Chinese "1月5日".
    var components = DateComponents()
    components.year = 2026
    components.month = 1
    components.day = 5
    components.hour = 14
    components.minute = 30
    let calendar = Calendar.current
    guard let reset = calendar.date(from: components) else {
        fatalError("test date should be constructible")
    }
    let formatted = DetailsPanel.formatResetTime(reset)
    expect(
        formatted.contains("Jan") && !formatted.contains("刷新") && !formatted.contains("refresh"),
        "formatResetTime should render English date without refresh suffix when language=en (got: \(formatted))"
    )
}

private func testLanguageMenuStateSeparatesAutoFromResolvedLanguage() {
    expect(
        AppDelegate.languageMenuItemState(itemLanguage: nil, savedLanguage: nil),
        .on,
        "auto language item should be checked when preference is follow-system"
    )
    expect(
        AppDelegate.languageMenuItemState(itemLanguage: "en", savedLanguage: nil),
        .off,
        "resolved system language should not make explicit English look manually selected"
    )
    expect(
        AppDelegate.languageMenuItemState(itemLanguage: "en", savedLanguage: "en"),
        .on,
        "explicit English item should be checked when preference is English"
    )
}

private func testManualLanguagePreferenceSurvivesMatchingSystemLanguage() {
    expect(
        AppDelegate.languagePreferenceAfterResolvedLanguageChange(
            savedLanguage: "en",
            currentLanguage: "en",
            systemLanguage: "en"
        ),
        "en",
        "manual language selection should remain explicit even when it matches the system language"
    )
    expect(
        AppDelegate.languagePreferenceAfterResolvedLanguageChange(
            savedLanguage: nil,
            currentLanguage: "en",
            systemLanguage: "en"
        ) == nil,
        "follow-system language selection should remain nil"
    )
}
