import AppKit
import AgentHaloCore

@MainActor
final class HaloView: NSView {
    var aggregate = AggregateSnapshot(
        state: .idle,
        label: "READY",
        detail: "Codex is standing by",
        sessions: []
    ) {
        didSet {
            guard !previewMode else {
                return
            }
            applyVisualState(aggregate.state, presentation: .flashing)
        }
    }
    var onDoubleClick: (() -> Void)?
    var onMoved: ((NSRect) -> Void)?
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var animationTimer: Timer?
    private var visualState: HaloState = .idle
    private var errorPresentation: ErrorPresentation = .flashing
    private var steadyDone = false
    private var previewMode = false
    private var animationTime = 0.0
    private var sinceState = 0.0
    private var transitionProgress = 1.0
    private var gapA = 97.0
    private var gapB = 247.0
    private var outerVelocity = 0.0
    private var gapSeparation = GeneratedHaloSpec.maximumGapSeparation
    private var gapRepelling = false
    private var gapRepulsionElapsed = 0.0
    private var gapRepulsionStart = GeneratedHaloSpec.minimumGapSeparation
    private var gapRepulsionDuration = 1.4
    private var gapRepulsionCount = 0
    private var smallGapAnchor = 247.0
    private var smallGapDriftElapsed = 0.0
    private var smallGapInertiaOffset = 0.0
    private var smallGapInertiaVelocity = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        animationTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(stepAnimation),
            userInfo: nil,
            repeats: true
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    @objc private func stepAnimation() {
        let delta = 1.0 / 60.0
        animationTime += max(0.001, min(delta, 0.08))
        sinceState += max(0.001, min(delta, 0.08))
        let targetVelocity = HaloMath.targetGapVelocity(visualState) *
            HaloMath.gapVelocityEnvelope(visualState, time: animationTime)
        outerVelocity = HaloMath.damp(
            current: outerVelocity,
            target: targetVelocity,
            delta: delta,
            response: 2.1
        )
        gapA += outerVelocity * delta

        if gapRepelling {
            gapRepulsionElapsed += delta
            let progress = HaloMath.clamp(gapRepulsionElapsed / max(0.01, gapRepulsionDuration), 0, 1)
            gapSeparation = HaloMath.lerp(
                gapRepulsionStart,
                GeneratedHaloSpec.maximumGapSeparation,
                HaloMath.magneticRepulsionEase(progress)
            )
            gapB = gapA + gapSeparation
            if progress >= 1 {
                gapRepelling = false
                gapSeparation = GeneratedHaloSpec.maximumGapSeparation
                gapB = gapA + gapSeparation
                smallGapAnchor = gapB
                smallGapDriftElapsed = 0
                smallGapInertiaOffset = 0
                smallGapInertiaVelocity = HaloMath.repulsionExitVelocityFromOrbit(outerVelocity)
            }
        } else {
            smallGapDriftElapsed += delta
            smallGapInertiaVelocity *= exp(-HaloMath.smallGapInertiaDamping(visualState) * delta)
            smallGapInertiaOffset += smallGapInertiaVelocity * delta
            gapB = smallGapAnchor +
                smallGapInertiaOffset +
                HaloMath.smallGapDriftOffset(
                    state: visualState,
                    time: smallGapDriftElapsed,
                    cycle: gapRepulsionCount
                )
            gapSeparation = HaloMath.positiveModulo(gapB - gapA, 360)
            if gapSeparation <= 41.5 || gapSeparation > 300 {
                gapSeparation = GeneratedHaloSpec.minimumGapSeparation
                gapB = gapA + gapSeparation
                gapRepelling = true
                gapRepulsionElapsed = 0
                gapRepulsionStart = gapSeparation
                gapRepulsionDuration = HaloMath.repulsionDurationFromOrbit(outerVelocity)
                gapRepulsionCount += 1
                smallGapInertiaOffset = 0
                smallGapInertiaVelocity = 0
            }
        }

        if gapA > 36_000 {
            gapA -= 36_000
            gapB -= 36_000
            smallGapAnchor -= 36_000
        }
        transitionProgress = min(1, transitionProgress + delta / 0.56)
        needsDisplay = true
    }

    func showPreview(state: HaloState, presentation: ErrorPresentation) {
        previewMode = true
        applyVisualState(state, presentation: presentation)
    }

    func useLiveState() {
        previewMode = false
        applyVisualState(aggregate.state, presentation: .flashing)
    }

    private func applyVisualState(_ state: HaloState, presentation: ErrorPresentation) {
        if visualState != state {
            sinceState = 0
            transitionProgress = 0
        }
        visualState = state
        errorPresentation = state == .error ? presentation : .flashing
        steadyDone = state == .done && aggregate.sessions.isEmpty
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        HaloRenderer.drawPureRing(
            context: context,
            bounds: bounds,
            input: HaloRenderInput(
                state: visualState,
                errorPresentation: errorPresentation,
                steadyDone: steadyDone,
                time: animationTime,
                sinceState: sinceState,
                transition: transitionProgress,
                gapA: gapA,
                gapB: gapB
            )
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        if event.clickCount == 1 {
            onClick?()
        }
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick {
            onRightClick(event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart, let windowStart else {
            return
        }
        let current = NSEvent.mouseLocation
        let next = CGPoint(
            x: windowStart.x + current.x - dragStart.x,
            y: windowStart.y + current.y - dragStart.y
        )
        window.setFrameOrigin(next)
    }

    override func mouseUp(with event: NSEvent) {
        if let frame = window?.frame {
            onMoved?(frame)
        }
        dragStart = nil
        windowStart = nil
    }
}
