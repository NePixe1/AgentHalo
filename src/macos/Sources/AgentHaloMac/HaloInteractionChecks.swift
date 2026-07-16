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
    testDetailsPanelNormalizesDynamicHeightForTargetScale()
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
    testDetailsPanelAlwaysShowsProviderRow()
    testDetailsPanelShowsPlanOnlyForOAuth()
    testDetailsPanelKeepsPlanNextToProvider()
    testDetailsPanelKeepsWarningNextToProviderWithoutPlan()
    testDetailsPanelShowsSingleAmberUsageWarning()
    testDetailsPanelShowsFiveHourAndWeeklyRemainingUsage()
    testDetailsPanelShowsMissingAndExpiredUsageWindows()
    testDetailsPanelShowsThreeIndependentSessionRows()
    testDetailsPanelLeavesMissingSessionTitleEmpty()
    testDetailsPanelKeepsUsageAndSessionBodiesMutuallyExclusive()
    testDetailsPanelKeepsContextIndependentFromUsageFailure()
    testDetailsPanelClearsContextAndSessionRowsOffline()
    testDetailsPanelKeepsFixedWidthForLongProviderContent()
    testDetailsPanelResizesHeightWithoutAnimation()
    testDetailsPanelMovesTitleGapIntoBodySpacing()
    testDetailsPanelShowsCodexStandbyCopy()
    testDetailsPanelUsesCompactContextPercent()
    testDetailsPanelKeepsContextPillWidthStable()
    testVisibleDetailsPanelStatusRefreshIsWiredToTick()
    testUsageTerminationWaitsForCoordinatorCancellation()
    testUsageTerminationHandshakeRejectsDuplicateWork()
    testUsageMonitoringLifecycleWiring()
    testPackagedVerificationRuntimeSelectionIsExplicit()
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
    testUsageProviderMappingIsTotal()
    testClaudeStandbyDetailsPreferLiveSessionIdentity()
    testClaudeUsageFreshnessTracksExactLiveSession()
    testDetailsPanelUsesTightBottomInset()
    testDetailsPanelShowsAnswerStreamingCopy()
    testDetailsPanelRefreshesStatusFromLatestAggregate()
    testDetailsPanelLocalizesClaudeActivityDetails()
    testAgentToggleUsesSharedSVGAssets()
    testAgentToggleUsesCodexAndClaudeIcons()
    testAgentToggleKeepsWholeControlClickable()
    testDetailsPanelSwitchCallbackSelectsClaudeCode()
}

private func testPackagedVerificationRuntimeSelectionIsExplicit() {
    let mainURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("main.swift")
    guard let source = try? String(contentsOf: mainURL, encoding: .utf8) else {
        fatalError("main.swift should be readable")
    }
    expect(
        source.contains("let packagedVerificationArgument = \"--packaged-verification\"")
            && source.contains("? .packagedVerification")
            && source.contains(": .production")
            && source.contains("UsageMonitoringCoordinator.live(mode: runtimeMode)"),
        "only the explicit packaged marker should select disabled-Keychain assembly"
    )
    expect(
        source.contains("PACKAGED_VERIFICATION_KEYCHAIN_DISABLED"),
        "packaged verification should emit an auditable runtime marker"
    )
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
private func testDetailsPanelAlwaysShowsProviderRow() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(provider: "Codex")
    )

    expect(panel.providerTextForTesting, "Codex", "provider row should always show the selected provider")
    expect(
        panel.contentOrderForTesting,
        [.agentSwitcher, .provider, .statusTitle, .statusDetail, .usageBody, .sessionBody],
        "provider row should sit directly between the Agent switcher and Halo status in the exact panel structure"
    )
    expect(panel.contentOrderForTesting.count, 6, "details panel should contain exactly six top-level rows")
    expect(!panel.contentOrderForTesting.contains(.unknown), "details panel should reject unknown top-level rows")
    expect(panel.providerRowHeightForTesting, 20, "provider row should use its fixed height")
    let labels = allDescendants(of: panel.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
    expect(!labels.contains("OAuth") && !labels.contains("API"), "details panel should not show an access-mode label")
    expect(!labels.contains("使用情况/余额") && !labels.contains("会话详情"), "details panel should not show section titles")

    panel.render(
        aggregate: detailsAggregate(state: .idle, label: "OFFLINE"),
        model: sessionDetailsModel(provider: "Claude Code")
    )
    expect(panel.providerTextForTesting, "Claude Code", "offline details should retain the provider row")
    expect(
        panel.contentOrderForTesting,
        [.agentSwitcher, .provider, .statusTitle, .statusDetail, .usageBody, .sessionBody],
        "offline provider row should keep the same exact structural position"
    )
    expect(panel.contentOrderForTesting.count, 6, "offline details should keep exactly six top-level rows")
    expect(!panel.contentOrderForTesting.contains(.unknown), "offline details should reject unknown top-level rows")
    expect(panel.providerRowHeightForTesting, 20, "offline provider row should keep the shared height")
}

@MainActor
private func testDetailsPanelShowsPlanOnlyForOAuth() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(provider: "Codex", plan: "Plus")
    )
    expect(panel.planTextForTesting, "Plus", "OAuth details should show the plan")
    expect(!panel.planHiddenForTesting, "OAuth plan should be visible")

    panel.render(
        aggregate: detailsAggregate(),
        model: sessionDetailsModel(provider: "Codex", plan: nil)
    )
    expect(panel.providerTextForTesting, "Codex", "API details should keep the provider")
    expect(panel.planHiddenForTesting, "API details should hide the plan")
}

@MainActor
private func testDetailsPanelKeepsPlanNextToProvider() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(provider: "Codex", plan: "Plus")
    )

    let spacing = panel.providerPlanVisibleSpacingForTesting
    expect(
        spacing >= 5 && spacing <= 7.5,
        "OAuth plan should follow the provider by 5-7pt, got \(spacing)pt"
    )
}

@MainActor
private func testDetailsPanelKeepsWarningNextToProviderWithoutPlan() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(plan: nil, warning: "Refresh failed")
    )

    let spacing = panel.providerWarningVisibleSpacingForTesting
    expect(
        spacing >= 5 && spacing <= 7.5,
        "warning should follow the provider by 5-7pt when plan is absent, got \(spacing)pt"
    )
}

@MainActor
private func testDetailsPanelShowsSingleAmberUsageWarning() {
    let panel = DetailsPanel()
    let warning = L10n.shared["usage.warning.network"]
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(warning: warning)
    )

    expect(!panel.warningHiddenForTesting, "OAuth refresh failure should show one warning image")
    expect(panel.warningToolTipForTesting, warning, "warning should expose its full text as a native tooltip")
    expect(panel.warningAccessibilityLabelForTesting, warning, "warning should expose an accessibility label")
    expect(panel.warningColorForTesting, NSColor.systemYellow, "warning should use the system amber color")
    let warningImages = allDescendants(of: panel.contentView!).compactMap { $0 as? NSImageView }
        .filter { $0.image?.accessibilityDescription == "exclamationmark.triangle.fill" }
    expect(warningImages.count, 1, "provider row should contain a single warning image")
}

@MainActor
private func testDetailsPanelShowsFiveHourAndWeeklyRemainingUsage() {
    let panel = DetailsPanel()
    let reset = Date().addingTimeInterval(3_600)
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(windows: [
            UsageWindow(kind: .weekly, usedPercent: 60, resetsAt: reset, duration: 604_800),
            UsageWindow(kind: .session, usedPercent: 30, resetsAt: reset, duration: 18_000),
        ])
    )

    expect(panel.primaryQuotaTitleForTesting, L10n.shared["quota.5h"], "short window title")
    expect(panel.secondaryQuotaTitleForTesting, L10n.shared["quota.weekly"], "weekly window title")
    expect(panel.primaryQuotaValueForTesting, L10n.shared.format("quota.remaining", 70), "short window remaining value")
    expect(panel.secondaryQuotaValueForTesting, L10n.shared.format("quota.remaining", 40), "weekly remaining value")
    expect(panel.primaryQuotaMeterFillForTesting, 70, "short window meter should use remaining percent")
    expect(panel.secondaryQuotaMeterFillForTesting, 40, "weekly meter should use remaining percent")
    expect(!panel.primaryQuotaResetHiddenForTesting, "future short-window reset should be visible")
    expect(!panel.secondaryQuotaResetHiddenForTesting, "future weekly reset should be visible")
}

@MainActor
private func testDetailsPanelShowsMissingAndExpiredUsageWindows() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(windows: [
            UsageWindow(kind: .weekly, usedPercent: 15, resetsAt: Date().addingTimeInterval(-1), duration: 604_800),
        ])
    )

    expect(panel.primaryQuotaValueForTesting, L10n.shared["quota.no_data"], "missing short window should show no data")
    expect(panel.primaryQuotaResetHiddenForTesting, "missing short-window reset should be hidden")
    expect(panel.primaryQuotaMeterFillForTesting, 0, "missing short-window meter should be empty")
    expect(panel.secondaryQuotaValueForTesting, L10n.shared["quota.waiting_refresh"], "expired weekly window should wait for refresh")
    expect(panel.secondaryQuotaResetHiddenForTesting, "expired weekly reset should be hidden")
    expect(panel.secondaryQuotaMeterFillForTesting, 0, "expired weekly meter should be empty")

    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(windows: [
            UsageWindow(kind: .session, usedPercent: 25, resetsAt: nil, duration: 18_000),
        ])
    )
    expect(panel.primaryQuotaValueForTesting, L10n.shared.format("quota.remaining", 75), "nil reset should preserve remaining usage")
    expect(panel.primaryQuotaResetHiddenForTesting, "nil reset should not show a placeholder reset")
}

@MainActor
private func testDetailsPanelShowsThreeIndependentSessionRows() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(),
        model: sessionDetailsModel(session: SessionDetailsSnapshot(
            projectName: "AgentHalo",
            sessionTitle: "Redesign details",
            modelName: "gpt-5.5",
            inputTokens: 38_000,
            outputTokens: 1_200
        ))
    )

    expect(panel.sessionTitleValueForTesting, "Redesign details", "session title row")
    expect(panel.modelValueForTesting, "gpt-5.5", "model row")
    expect(panel.tokenValueForTesting, "↑ 38k  ·  ↓ 1.2k", "token row")
    expect(panel.sessionTitleToolTipForTesting, "Redesign details", "session title tooltip")
    expect(panel.modelToolTipForTesting, "gpt-5.5", "model tooltip")
    expect(
        panel.sessionBodyOrderForTesting,
        [.sessionTitle, .separator, .model, .separator, .tokens],
        "API rows should omit the project row"
    )
    expect(panel.sessionBodyOrderForTesting.count, 5, "API body should contain exactly five arranged subviews")
    expect(!panel.sessionBodyOrderForTesting.contains(.unknown), "API body should reject unknown rows or titles")
    expect(
        panel.sessionBodyOrderForTesting.filter { $0 == .separator }.count,
        2,
        "API rows should contain two separators"
    )
    expect(
        panel.sessionRowHeightsForTesting,
        [24, 24, 24],
        "all API metadata rows should use the same 24pt height"
    )
}

@MainActor
private func testDetailsPanelLeavesMissingSessionTitleEmpty() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(),
        model: sessionDetailsModel(session: SessionDetailsSnapshot(projectName: "AgentHalo"))
    )

    expect(panel.sessionTitleValueForTesting, "--", "missing title should not fall back to projectName")
}

@MainActor
private func testDetailsPanelKeepsUsageAndSessionBodiesMutuallyExclusive() {
    let panel = DetailsPanel()
    panel.render(aggregate: detailsAggregate(), model: usageDetailsModel())
    expect(!panel.usageGroupHiddenForTesting, "OAuth body should show usage")
    expect(panel.sessionGroupHiddenForTesting, "OAuth body should hide session rows")

    panel.render(aggregate: detailsAggregate(), model: sessionDetailsModel())
    expect(panel.usageGroupHiddenForTesting, "API body should hide usage")
    expect(!panel.sessionGroupHiddenForTesting, "API body should show session rows")
}

@MainActor
private func testDetailsPanelKeepsContextIndependentFromUsageFailure() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(warning: L10n.shared["usage.warning.network"], context: 42)
    )

    expect(!panel.contextPillHiddenForTesting, "usage failure should not hide live context")
    expect(panel.contextValueForTesting, "42%", "usage failure should not overwrite context")
}

@MainActor
private func testDetailsPanelClearsContextAndSessionRowsOffline() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(state: .idle, label: "OFFLINE"),
        model: sessionDetailsModel(
            context: 58,
            session: SessionDetailsSnapshot(
                projectName: "AgentHalo",
                sessionTitle: "Stale title",
                modelName: "gpt-5.5",
                inputTokens: 100,
                outputTokens: 20
            )
        )
    )

    expect(panel.contextPillHiddenForTesting, "offline should clear context")
    expect(panel.sessionTitleValueForTesting, "--", "offline should clear session title")
    expect(panel.modelValueForTesting, "--", "offline should clear model")
    expect(panel.tokenValueForTesting, "--", "offline should clear tokens")
}

@MainActor
private func testDetailsPanelKeepsFixedWidthForLongProviderContent() {
    let panel = DetailsPanel()
    let initialWidth = panel.frame.width
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(
            provider: String(repeating: "Very Long Provider ", count: 8),
            plan: String(repeating: "Very Long Plan ", count: 8)
        )
    )
    panel.contentView?.layoutSubtreeIfNeeded()

    expect(panel.frameWidthForTesting, initialWidth, "long provider content should not widen the panel")
    expect(panel.frameWidthForTesting, 268, "details panel should keep the fixed width")
    expect((panel.contentView?.fittingSize.width ?? 0) <= 268.5, "content should fit the fixed width")
}

@MainActor
private func testDetailsPanelResizesHeightWithoutAnimation() {
    let panel = RecordingDetailsPanel()
    panel.setFrameOrigin(NSPoint(x: 100, y: 500))
    panel.resetResizeCalls()
    let initialTopEdge = panel.frame.maxY
    panel.render(aggregate: detailsAggregate(), model: usageDetailsModel())
    guard let usageCall = panel.resizeCalls.last else {
        fatalError("usage render should apply a resize frame")
    }
    let usageExpectedHeight = DetailsPanel.evenPanelHeight(
        for: panel.stackFittingHeightForTesting,
        backingScaleFactor: panel.backingScaleForTesting
    )
    expect(!usageCall.display, "usage resize should not request immediate display")
    expect(!usageCall.animate, "usage resize should not animate")
    expect(usageCall.frame.height, usageExpectedHeight, "usage height should be an even, pixel-aligned stack fitting height")
    expect(usageCall.frame.height, 196, "title refinements should preserve the established panel height")
    expect(usageCall.frame.maxY, initialTopEdge, "usage resize should preserve the prior top edge")
    expect(panel.frame, usageCall.frame, "window should apply the observed usage resize frame")

    let usageHeight = usageCall.frame.height
    let usageTopEdge = panel.frame.maxY
    panel.resetResizeCalls()
    panel.render(aggregate: detailsAggregate(), model: sessionDetailsModel())
    guard let sessionCall = panel.resizeCalls.last else {
        fatalError("session render should apply a resize frame")
    }
    expect(panel.metadataTopInsetForTesting, 0, "session metadata should start immediately after the subtitle")
    let sessionExpectedHeight = DetailsPanel.evenPanelHeight(
        for: panel.stackFittingHeightForTesting,
        backingScaleFactor: panel.backingScaleForTesting
    )
    expect(!sessionCall.display, "session resize should not request immediate display")
    expect(!sessionCall.animate, "session resize should not animate")
    expect(sessionCall.frame.height, sessionExpectedHeight, "session height should be an even, pixel-aligned stack fitting height")
    expect(sessionCall.frame.height, usageHeight, "switching bodies should keep the same panel height")
    expect(sessionCall.frame.maxY, usageTopEdge, "session resize should preserve the prior top edge")
    expect(panel.frame, sessionCall.frame, "window should apply the observed session resize frame")
}

@MainActor
private func testDetailsPanelMovesTitleGapIntoBodySpacing() {
    let panel = DetailsPanel()
    let aggregate = AggregateSnapshot(
        state: .done,
        label: "STANDBY",
        detail: "Codex Standing By",
        sessions: [],
        focusedAgent: .codex
    )
    panel.render(
        aggregate: aggregate,
        model: usageDetailsModel(
            windows: [
                UsageWindow(kind: .session, usedPercent: 25, resetsAt: nil, duration: 18_000),
                UsageWindow(kind: .weekly, usedPercent: 10, resetsAt: nil, duration: 604_800)
            ]
        )
    )
    guard let contentView = panel.contentView else {
        fatalError("details panel should expose its content view")
    }
    contentView.layoutSubtreeIfNeeded()

    func field(of value: String) -> NSTextField {
        guard let field = allDescendants(of: contentView)
            .compactMap({ $0 as? NSTextField })
            .first(where: { $0.stringValue == value }) else {
            fatalError("details panel should expose text field: \(value)")
        }
        return field
    }

    func frame(of value: String) -> NSRect {
        let field = field(of: value)
        return field.convert(field.bounds, to: contentView)
    }

    func containingFrame(of value: String) -> NSRect {
        guard let field = allDescendants(of: contentView)
            .compactMap({ $0 as? NSTextField })
            .first(where: { $0.stringValue == value }),
              let container = field.superview else {
            fatalError("details panel should expose container for text field: \(value)")
        }
        return container.convert(container.bounds, to: contentView)
    }

    guard let providerField = allDescendants(of: contentView)
        .compactMap({ $0 as? NSTextField })
        .first(where: { $0.stringValue == "Plus" }),
          let providerHeader = providerField.superview else {
        fatalError("details panel should expose provider header")
    }
    guard let agentToggle = allDescendants(of: contentView)
        .first(where: { $0 is AgentToggleView }),
          let topRow = agentToggle.superview else {
        fatalError("details panel should expose top row")
    }
    let topRowFrame = topRow.convert(topRow.bounds, to: contentView)
    let providerFrame = providerHeader.convert(providerHeader.bounds, to: contentView)
    let titleField = field(of: "STANDBY")
    let detailField = field(of: "Codex Standing By")
    let titleFrame = titleField.convert(titleField.bounds, to: contentView)
    let detailFrame = detailField.convert(detailField.bounds, to: contentView)
    let quotaRow = containingFrame(of: L10n.shared["quota.5h"])
    let weeklyQuotaRow = containingFrame(of: L10n.shared["quota.weekly"])

    expect(titleField.font?.pointSize, 22, "status title should use the smaller font")
    expect(detailField.font?.pointSize, 12, "status detail should use the smaller font")
    expect(topRowFrame.minY - providerFrame.maxY, 0, "provider and title should move 2pt closer to the top row")
    expect(providerFrame.minY - titleFrame.maxY, 3, "title should move 4pt closer to provider")
    expect(detailFrame.minY - quotaRow.maxY, 16, "usage body should keep a clear gap below the subtitle")
    expect(quotaRow.minY - weeklyQuotaRow.maxY, 4, "quota rows should be compact")

    panel.render(
        aggregate: aggregate,
        model: sessionDetailsModel(
            provider: "Claude Code",
            plan: nil,
            session: SessionDetailsSnapshot(
                sessionTitle: "Layout spacing",
                modelName: "gpt-5.5",
                inputTokens: 100,
                outputTokens: 20
            )
        )
    )
    contentView.layoutSubtreeIfNeeded()
    let sessionProviderFrame = providerHeader.convert(providerHeader.bounds, to: contentView)
    let sessionTitleFrame = frame(of: "STANDBY")
    let sessionDetailFrame = frame(of: "Codex Standing By")
    let sessionTitleRow = containingFrame(of: L10n.shared["metadata.session_title"])
    expect(sessionProviderFrame.minY - sessionTitleFrame.maxY, 3, "session title should keep the tightened provider gap")
    expect(sessionDetailFrame.minY - sessionTitleRow.maxY, 11, "session body should receive the released title spacing")
}

@MainActor
private final class RecordingDetailsPanel: DetailsPanel {
    struct ResizeCall {
        var frame: NSRect
        var display: Bool
        var animate: Bool
    }

    private(set) var resizeCalls: [ResizeCall] = []

    override func applyResizeFrame(_ frame: NSRect, display: Bool, animate: Bool) {
        resizeCalls.append(ResizeCall(frame: frame, display: display, animate: animate))
        super.applyResizeFrame(frame, display: display, animate: animate)
    }

    func resetResizeCalls() {
        resizeCalls.removeAll()
    }
}

private func detailsAggregate(
    state: HaloState = .working,
    label: String = "EXECUTING",
    agent: AgentKind = .codex
) -> AggregateSnapshot {
    AggregateSnapshot(
        state: state,
        label: label,
        detail: "AgentHalo - Running command",
        sessions: [],
        focusedAgent: agent
    )
}

private func usageDetailsModel(
    provider: String = "Codex",
    plan: String? = "Plus",
    warning: String? = nil,
    context: Double? = nil,
    windows: [UsageWindow] = []
) -> DetailsPanelViewModel {
    DetailsPanelViewModel(
        providerName: provider,
        planName: plan,
        usageWarning: warning,
        contextUsedPercent: context,
        body: .usage(UsageDetailsModel(windows: windows, status: .noData))
    )
}

private func sessionDetailsModel(
    provider: String = "Claude Code",
    plan: String? = nil,
    context: Double? = nil,
    session: SessionDetailsSnapshot = SessionDetailsSnapshot()
) -> DetailsPanelViewModel {
    DetailsPanelViewModel(
        providerName: provider,
        planName: plan,
        usageWarning: nil,
        contextUsedPercent: context,
        body: .session(session)
    )
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

    panel.render(aggregate: aggregate, model: usageDetailsModel())

    expect(panel.detailTextForTesting == L10n.shared["status.standby_codex"], "Codex standby copy should be localized")
}

@MainActor
private func testDetailsPanelUsesCompactContextPercent() {
    let panel = DetailsPanel()
    let aggregate = AggregateSnapshot(
        state: .working,
        label: "EXECUTING",
        detail: "AgentHalo - Running command",
        sessions: [],
        focusedAgent: .codex
    )

    panel.render(aggregate: aggregate, model: usageDetailsModel(context: 58.4))
    expect(panel.contextValueForTesting, "58%", "context block should use compact percentage-only copy")

    panel.render(aggregate: aggregate, model: usageDetailsModel(context: 100))
    expect(panel.contextValueForTesting, "99%", "context block should cap the visible percentage at 99%")
}

@MainActor
private func testDetailsPanelKeepsContextPillWidthStable() {
    let panel = DetailsPanel()
    let aggregate = AggregateSnapshot(
        state: .working,
        label: "EXECUTING",
        detail: "AgentHalo - Running command",
        sessions: [],
        focusedAgent: .claudeCode
    )

    panel.render(aggregate: aggregate, model: sessionDetailsModel(context: 9))
    panel.contentView?.layoutSubtreeIfNeeded()
    let singleDigitWidth = panel.contextPillWidthForTesting

    panel.render(aggregate: aggregate, model: sessionDetailsModel(context: 99))
    panel.contentView?.layoutSubtreeIfNeeded()
    let doubleDigitWidth = panel.contextPillWidthForTesting

    expect(abs(singleDigitWidth - doubleDigitWidth) < 0.5, "context pill width should stay stable as the percent changes")
    expect(abs(doubleDigitWidth - 42) < 0.5, "context pill should use the tighter fixed width")
    expect(
        panel.contextValueExpansionFrameForTesting.isEmpty,
        "context pill should not ask AppKit for an expansion frame, which means the percent would be truncated"
    )
    expect(
        panel.contextValueIntrinsicWidthForTesting <= panel.contextValueWidthForTesting + 0.5,
        "context pill should still fit a two-digit percent without truncation"
    )
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
private func testDetailsPanelNormalizesDynamicHeightForTargetScale() {
    expect(
        DetailsPanel.evenPanelHeight(for: 191.5, backingScaleFactor: 1),
        192,
        "1x target screens should not display a half-point details-panel height"
    )
    expect(
        DetailsPanel.evenPanelHeight(for: 192.5, backingScaleFactor: 2),
        194,
        "dynamic details-panel heights should remain even when moving between backing scales"
    )
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
    expect(
        positionSource.contains("evenPanelHeight"),
        "details panel height should be normalized for the target screen before first display"
    )
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

    panel.render(aggregate: aggregate, model: usageDetailsModel())

    expect(panel.detailTextForTesting == L10n.shared["status.writing_answer"], "answer streaming should use localized copy")
}

@MainActor
private func testDetailsPanelRefreshesStatusFromLatestAggregate() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: AggregateSnapshot(
            state: .thinking,
            label: "THINKING",
            detail: "AgentHalo - Planning",
            sessions: [],
            focusedAgent: .claudeCode
        ),
        model: sessionDetailsModel(context: 27)
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
    expect(panel.contextValueForTesting == "27%", "status refresh should preserve existing metadata")
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

private func testUsageTerminationWaitsForCoordinatorCancellation() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appDelegateURL = sourceDirectory.appendingPathComponent("AppDelegate.swift")
    guard let source = try? String(contentsOf: appDelegateURL, encoding: .utf8),
          let shouldStart = source.range(of: "    func applicationShouldTerminate")?.lowerBound,
          let willStart = source.range(
            of: "    func applicationWillTerminate",
            range: shouldStart..<source.endIndex
          )?.lowerBound,
          let willEnd = source.range(
            of: "    private func cancelLocalUsageTasks",
            range: willStart..<source.endIndex
          )?.lowerBound,
          let cleanupEnd = source.range(
            of: "    func applicationDidChangeScreenParameters",
            range: willEnd..<source.endIndex
          )?.lowerBound else {
        fatalError("AppDelegate termination source should be readable")
    }

    let shouldSource = source[shouldStart..<willStart]
    let willSource = source[willStart..<willEnd]
    let cleanupSource = source[willEnd..<cleanupEnd]
    expect(
        shouldSource.contains("func applicationShouldTerminate(_ sender: NSApplication)")
            && shouldSource.contains("if usageTerminationHandshake.hasCompleted")
            && shouldSource.contains("return .terminateNow")
            && shouldSource.contains("guard usageTerminationHandshake.beginCancellation() else")
            && shouldSource[
                shouldSource.range(
                    of: "guard usageTerminationHandshake.beginCancellation() else"
                )!.lowerBound..<shouldSource.range(of: "cancelLocalUsageTasks()")!.lowerBound
            ].contains("return .terminateLater")
            && shouldSource.contains("cancelLocalUsageTasks()")
            && shouldSource.contains("Task { @MainActor [weak self] in")
            && shouldSource.contains("await self.usageCoordinator.cancelAll()")
            && shouldSource.contains("usageTerminationHandshake.finishCancellation()")
            && shouldSource.contains("NSApp.reply(toApplicationShouldTerminate: true)"),
        "termination should use AppKit's asynchronous termination handshake"
    )
    expect(
        shouldSource.range(of: "usageTerminationHandshake.hasCompleted")!.lowerBound
            < shouldSource.range(of: "return .terminateNow")!.lowerBound
            && shouldSource.range(of: "return .terminateNow")!.lowerBound
                < shouldSource.range(of: "usageTerminationHandshake.beginCancellation()")!.lowerBound
            && shouldSource.range(of: "usageTerminationHandshake.beginCancellation()")!.lowerBound
                < shouldSource.range(of: "cancelLocalUsageTasks()")!.lowerBound
            && shouldSource.range(of: "cancelLocalUsageTasks()")!.lowerBound
            < shouldSource.range(of: "await self.usageCoordinator.cancelAll()")!.lowerBound
            && shouldSource.range(of: "await self.usageCoordinator.cancelAll()")!.lowerBound
                < shouldSource.range(of: "usageTerminationHandshake.finishCancellation()")!.lowerBound
            && shouldSource.range(of: "usageTerminationHandshake.finishCancellation()")!.lowerBound
                < shouldSource.range(of: "NSApp.reply(toApplicationShouldTerminate: true)")!.lowerBound,
        "termination should await coordinator cancellation before its single MainActor reply"
    )
    expect(
        willSource.contains("cancelLocalUsageTasks()")
            && !willSource.contains("Task {")
            && !willSource.contains("usageCoordinator.cancelAll"),
        "applicationWillTerminate should only repeat idempotent local Usage cleanup"
    )
    expect(
        cleanupSource.contains("usageRefreshLoopTask?.cancel()")
            && cleanupSource.contains("usageRequestTasks.values.forEach { $0.task.cancel() }"),
        "local Usage cleanup should synchronously cancel the loop and wrapper tasks"
    )
}

private func testUsageTerminationHandshakeRejectsDuplicateWork() {
    var handshake = UsageTerminationHandshake()

    expect(!handshake.hasCompleted, "termination handshake should start incomplete")
    expect(handshake.beginCancellation(), "first termination request should start cancellation")
    expect(!handshake.beginCancellation(), "repeated termination requests must not start another Task")
    expect(handshake.finishCancellation(), "the in-flight cancellation should complete once")
    expect(handshake.hasCompleted, "completed cancellation should allow immediate termination")
    expect(!handshake.finishCancellation(), "completion must not send a second termination reply")
    expect(!handshake.beginCancellation(), "completed termination must not restart cancellation")
}

private func testUsageMonitoringLifecycleWiring() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appDelegateURL = sourceDirectory.appendingPathComponent("AppDelegate.swift")
    guard let source = try? String(contentsOf: appDelegateURL, encoding: .utf8),
          let launchStart = source.range(
            of: "    func applicationDidFinishLaunching"
          )?.lowerBound,
          let launchEnd = source.range(
            of: "    func applicationShouldTerminate",
            range: launchStart..<source.endIndex
          )?.lowerBound,
          let willTerminationStart = source.range(
            of: "    func applicationWillTerminate",
            range: launchEnd..<source.endIndex
          )?.lowerBound,
          let terminationEnd = source.range(
            of: "    func applicationDidChangeScreenParameters",
            range: willTerminationStart..<source.endIndex
          )?.lowerBound,
          let tickStart = source.range(of: "    private func tick() {")?.lowerBound,
          let tickEnd = source.range(
            of: "    private func createStatusItem()",
            range: tickStart..<source.endIndex
          )?.lowerBound,
          let showStart = source.range(of: "    private func showDetails() {")?.lowerBound,
          let showEnd = source.range(
            of: "    private func updateDetailsPanelContent",
            range: showStart..<source.endIndex
          )?.lowerBound,
          let updateStart = source.range(
            of: "    private func updateDetailsPanelContent"
          )?.lowerBound,
          let updateEnd = source.range(
            of: "    static func claudeMainSessionIdForDetails",
            range: updateStart..<source.endIndex
          )?.lowerBound,
          let selectionStart = source.range(of: "    func setFocusedAgent(")?.lowerBound,
          let selectionEnd = source.range(
            of: "    @objc private func quit()",
            range: selectionStart..<source.endIndex
          )?.lowerBound,
          let loopStart = source.range(of: "    private func startUsageRefreshLoop()")?.lowerBound,
          let requestStart = source.range(
            of: "    private func requestUsageRefresh",
            range: loopStart..<source.endIndex
          )?.lowerBound,
          let publishStart = source.range(
            of: "    private func publishUsageState",
            range: requestStart..<source.endIndex
          )?.lowerBound,
          let publishEnd = source.range(
            of: "    private func refreshVisibleDetailsPanel",
            range: publishStart..<source.endIndex
          )?.lowerBound else {
        fatalError("AppDelegate usage-monitoring source should be readable")
    }

    let launchSource = source[launchStart..<launchEnd]
    let terminationSource = source[willTerminationStart..<terminationEnd]
    let tickSource = source[tickStart..<tickEnd]
    let showSource = source[showStart..<showEnd]
    let updateSource = source[updateStart..<updateEnd]
    let selectionSource = source[selectionStart..<selectionEnd]
    let loopSource = source[loopStart..<requestStart]
    let requestSource = source[requestStart..<publishStart]
    let publishSource = source[publishStart..<publishEnd]

    expect(
        source.contains("private let usageCoordinator: UsageMonitoringCoordinator")
            && source.contains("usageCoordinator: UsageMonitoringCoordinator = .live()")
            && source.contains("self.usageCoordinator = usageCoordinator"),
        "AppDelegate should own an injectable Usage coordinator with a production default"
    )
    expect(
        source.contains("private var usageRefreshLoopTask: Task<Void, Never>?")
            && source.contains("private var usageRequestTasks: [UsageProviderID: UsageRequestRecord] = [:]")
            && source.contains("private let usageRefreshInterval: TimeInterval = 5 * 60"),
        "Usage refresh should have a dedicated five-minute Task"
    )
    expect(
        launchSource.contains("startUsageRefreshLoop()")
            && launchSource.contains(
                "requestUsageRefresh(for: Self.usageProviderID(for: settings.focusedAgent))"
            )
            && launchSource.range(of: "L10n.shared.setLanguage")!.lowerBound
                < launchSource.range(of: "startUsageRefreshLoop()")!.lowerBound,
        "launch should start the Usage loop and refresh the current Provider"
    )
    expect(
        launchSource.contains("self.refreshVisibleDetailsPanel()"),
        "language changes should redraw visible Provider details"
    )
    expect(
        !tickSource.contains("usageCoordinator")
            && !tickSource.contains("requestUsageRefresh")
            && !tickSource.contains("refreshUsage"),
        "Usage requests must stay out of tick and the 0.3-second timer path"
    )
    expect(
        showSource.contains("updateDetailsPanelContent")
            && showSource.contains("requestUsageRefresh")
            && showSource.range(of: "updateDetailsPanelContent")!.lowerBound
                < showSource.range(of: "requestUsageRefresh")!.lowerBound,
        "showDetails should render current state before preparing and refreshing Usage"
    )
    expect(
        selectionSource.contains("requestUsageRefresh(for: Self.usageProviderID(for: agent))"),
        "agent selection should prepare and refresh the target Provider"
    )
    expect(
        !selectionSource.contains("cancel()"),
        "agent selection must not cancel another Provider's safe request"
    )
    expect(
        requestSource.contains("guard usageRequestTasks[providerID] == nil")
            && requestSource.contains("let token = UUID()")
            && requestSource.contains("let coordinator = usageCoordinator")
            && requestSource.contains("Task { @MainActor [weak self] in")
            && requestSource.contains("defer { self?.clearUsageRequest(for: providerID, token: token) }")
            && requestSource.contains("let prepared = await coordinator.prepare(providerID)")
            && requestSource.contains("self?.publishUsageState(prepared, for: providerID)")
            && requestSource.contains("let refreshed = await coordinator.ensureFresh(providerID)")
            && requestSource.contains("self?.publishUsageState(refreshed, for: providerID)")
            && !requestSource.contains("guard let self")
            && requestSource.contains("guard usageRequestTasks[providerID]?.token == token else")
            && requestSource.contains("usageRequestTasks[providerID] = nil"),
        "Usage requests should publish prepare and ensureFresh results in two phases"
    )
    expect(
        requestSource.contains("UsageRequestRecord(token: token, task: task)"),
        "wrapper cleanup must use token identity so an old task cannot remove its replacement"
    )
    expect(
        publishSource.contains("usageStates[providerID] = state")
            && publishSource.contains(
                "guard providerID == Self.usageProviderID(for: settings.focusedAgent)"
            )
            && publishSource.contains("detailsPanel.isVisible")
            && publishSource.range(of: "usageStates[providerID] = state")!.lowerBound
                < publishSource.range(of: "guard providerID ==")!.lowerBound,
        "async Usage publication should store by Provider before focus and visibility revalidation"
    )
    expect(
        loopSource.contains("Task.sleep(nanoseconds:")
            && loopSource.contains(
                "requestUsageRefresh(for: Self.usageProviderID(for: settings.focusedAgent))"
            ),
        "the dedicated low-frequency loop should refresh the currently focused Provider"
    )
    expect(
        source.contains("case .codex:") && source.contains("return .codex")
            && source.contains("case .claudeCode:") && source.contains("return .claude"),
        "AgentKind should map totally to its Usage Provider"
    )
    expect(
        terminationSource.contains("cancelLocalUsageTasks()")
            && !terminationSource.contains("Task {")
            && !terminationSource.contains("usageCoordinator.cancelAll"),
        "applicationWillTerminate should only repeat local Usage cleanup"
    )
    expect(
        updateSource.contains("DetailsContentResolver.resolve(")
            && updateSource.contains("detailsPanel.render(aggregate: displayedAggregate, model: model)")
            && updateSource.contains("sessionTitle: session?.sessionTitle")
            && updateSource.contains("ClaudeMainSessionDetailsResolver.resolve("),
        "details content should resolve a view model and render it"
    )
    expect(
        !updateSource.contains("rateLimitReader")
            && !updateSource.contains("RateLimitReader")
            && !updateSource.contains("showsQuota")
            && !updateSource.contains("quota")
            && !updateSource.contains("DetailsPresentation"),
        "the new details path must not retain legacy quota assembly"
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
private func testUsageProviderMappingIsTotal() {
    expect(AppDelegate.usageProviderID(for: .codex), .codex, "Codex Provider mapping")
    expect(AppDelegate.usageProviderID(for: .claudeCode), .claude, "Claude Provider mapping")
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
    panel.render(
        aggregate: AggregateSnapshot(
            state: .idle,
            label: "OFFLINE",
            detail: AgentKind.codex.offlineDetail,
            sessions: [],
            focusedAgent: .codex
        ),
        model: usageDetailsModel()
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
