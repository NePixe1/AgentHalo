import AppKit
import AgentHaloCore

@MainActor
final class HaloView: NSView {
    var aggregate = AggregateSnapshot(
        state: .idle,
        label: "READY",
        detail: "Codex is standing by",
        sessions: []
    )
    var onDoubleClick: (() -> Void)?
    var onMoved: ((NSRect) -> Void)?
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var animationTimer: Timer?
    var visualState: HaloState = .idle
    var errorPresentation: ErrorPresentation = .flashing
    var steadyDone = false
    private var animationTime = 0.0
    private var sinceState = 0.0
    private var transitionProgress = 1.0
    private var gapA = 97.0
    private var gapB = 247.0

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
        let velocity = targetGapVelocity(for: visualState)
        gapA += velocity * delta
        gapB = gapA + 150 + 5 * sin(animationTime)
        needsDisplay = true
    }

    private func targetGapVelocity(for state: HaloState) -> Double {
        switch state {
        case .thinking: 78
        case .working: 106
        case .attention: 46
        case .error: 60
        case .done: 38
        case .idle: 27
        }
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

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
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
