import AppKit
import AgentHaloCore

enum DetailsPanelContentRole: Equatable {
    case agentSwitcher
    case statusTitle
    case statusDetail
    case usageBody
    case sessionBody
    case unknown
}

enum DetailsPanelSessionBodyRole: Equatable {
    case empty
    case sessionCard
    case unknown
}

enum DetailsPanelUsageTrackMode: Equatable {
    case dual
    case single
}

@MainActor
struct DetailsPanelThemePalette {
    let isDark: Bool
    let surfaceFill: NSColor
    let containerBorder: NSColor
    let primaryText: NSColor
    let mutedText: NSColor
    let divider: NSColor
    let meterTrack: NSColor
    let meterAccentStart: NSColor
    let meterAccentEnd: NSColor
    let contextPillFill: NSColor
    let contextPillBorder: NSColor
    let contextPillText: NSColor
    let toggleBgFill: NSColor
    let toggleBgBorder: NSColor
    let toggleActiveFill: NSColor
    let toggleActiveBorder: NSColor
    let modelChipFill: NSColor
    let modelChipText: NSColor
    let inputChipFill: NSColor
    let inputChipText: NSColor
    let outputChipFill: NSColor
    let outputChipText: NSColor

    static let light = DetailsPanelThemePalette(
        isDark: false,
        surfaceFill: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 246 / 255),
        containerBorder: NSColor(calibratedRed: 183 / 255, green: 199 / 255, blue: 207 / 255, alpha: 64 / 255),
        primaryText: NSColor(calibratedRed: 17 / 255, green: 24 / 255, blue: 39 / 255, alpha: 1),
        mutedText: NSColor(calibratedRed: 103 / 255, green: 117 / 255, blue: 126 / 255, alpha: 1),
        divider: NSColor(calibratedRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 22 / 255),
        meterTrack: NSColor(calibratedRed: 229 / 255, green: 231 / 255, blue: 235 / 255, alpha: 1),
        meterAccentStart: NSColor(calibratedRed: 29 / 255, green: 140 / 255, blue: 248 / 255, alpha: 1),
        meterAccentEnd: NSColor(calibratedRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1),
        contextPillFill: NSColor(calibratedRed: 224 / 255, green: 240 / 255, blue: 252 / 255, alpha: 1),
        contextPillBorder: NSColor(calibratedRed: 174 / 255, green: 205 / 255, blue: 224 / 255, alpha: 72 / 255),
        contextPillText: NSColor(calibratedRed: 64 / 255, green: 105 / 255, blue: 132 / 255, alpha: 1),
        toggleBgFill: NSColor(calibratedRed: 244 / 255, green: 248 / 255, blue: 250 / 255, alpha: 1),
        toggleBgBorder: NSColor(calibratedRed: 221 / 255, green: 233 / 255, blue: 238 / 255, alpha: 1),
        toggleActiveFill: NSColor(calibratedRed: 225 / 255, green: 249 / 255, blue: 255 / 255, alpha: 1),
        toggleActiveBorder: NSColor(calibratedRed: 183 / 255, green: 235 / 255, blue: 246 / 255, alpha: 1),
        modelChipFill: NSColor(calibratedRed: 238 / 255, green: 241 / 255, blue: 244 / 255, alpha: 1),
        modelChipText: NSColor(calibratedRed: 77 / 255, green: 97 / 255, blue: 112 / 255, alpha: 1),
        inputChipFill: NSColor(calibratedRed: 228 / 255, green: 242 / 255, blue: 252 / 255, alpha: 1),
        inputChipText: NSColor(calibratedRed: 51 / 255, green: 119 / 255, blue: 160 / 255, alpha: 1),
        outputChipFill: NSColor(calibratedRed: 228 / 255, green: 246 / 255, blue: 238 / 255, alpha: 1),
        outputChipText: NSColor(calibratedRed: 35 / 255, green: 133 / 255, blue: 112 / 255, alpha: 1)
    )

    static let dark = DetailsPanelThemePalette(
        isDark: true,
        surfaceFill: NSColor(calibratedRed: 10 / 255, green: 11 / 255, blue: 14 / 255, alpha: 246 / 255),
        containerBorder: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 30 / 255),
        primaryText: NSColor(calibratedRed: 248 / 255, green: 250 / 255, blue: 252 / 255, alpha: 1),
        mutedText: NSColor(calibratedRed: 148 / 255, green: 163 / 255, blue: 184 / 255, alpha: 1),
        divider: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 26 / 255),
        meterTrack: NSColor(calibratedRed: 38 / 255, green: 41 / 255, blue: 48 / 255, alpha: 1),
        meterAccentStart: NSColor(calibratedRed: 34 / 255, green: 148 / 255, blue: 252 / 255, alpha: 1),
        meterAccentEnd: NSColor(calibratedRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1),
        contextPillFill: NSColor(calibratedRed: 56 / 255, green: 189 / 255, blue: 248 / 255, alpha: 42 / 255),
        contextPillBorder: NSColor(calibratedRed: 56 / 255, green: 189 / 255, blue: 248 / 255, alpha: 76 / 255),
        contextPillText: NSColor(calibratedRed: 125 / 255, green: 211 / 255, blue: 252 / 255, alpha: 1),
        toggleBgFill: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 16 / 255),
        toggleBgBorder: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 26 / 255),
        toggleActiveFill: NSColor(calibratedRed: 56 / 255, green: 189 / 255, blue: 248 / 255, alpha: 52 / 255),
        toggleActiveBorder: NSColor(calibratedRed: 56 / 255, green: 189 / 255, blue: 248 / 255, alpha: 108 / 255),
        modelChipFill: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 22 / 255),
        modelChipText: NSColor(calibratedRed: 203 / 255, green: 213 / 255, blue: 225 / 255, alpha: 1),
        inputChipFill: NSColor(calibratedRed: 56 / 255, green: 189 / 255, blue: 248 / 255, alpha: 36 / 255),
        inputChipText: NSColor(calibratedRed: 125 / 255, green: 211 / 255, blue: 252 / 255, alpha: 1),
        outputChipFill: NSColor(calibratedRed: 16 / 255, green: 185 / 255, blue: 129 / 255, alpha: 36 / 255),
        outputChipText: NSColor(calibratedRed: 110 / 255, green: 231 / 255, blue: 183 / 255, alpha: 1)
    )
}

@MainActor
class DetailsPanel: NSPanel {
    private static let panelWidth: CGFloat = 304
    private static let contextPillWidth: CGFloat = 46
    private static let contextPillHeight: CGFloat = 24
    private static let usageBodyHeight: CGFloat = 104
    /// Fixed session body slot height (Scheme B).
    private static let sessionBodyHeight: CGFloat = 68
    /// Bottom inset keeps the session body contribution aligned with the 104pt
    /// usage group (11 + 68 + 41 == 16 + 104) so both panels fit to 226.
    private static let sessionBodyBottomEqualizer: CGFloat = 41
    /// After COMPLETE settles into STANDBY (empty sessions), keep the last live
    /// context percent for this long before hiding. OFFLINE still clears immediately.
    nonisolated static let standbyContextHoldDuration: TimeInterval = 12

    private let containerView = NSVisualEffectView()
    private let surfaceView = NSView()
    private let stack = NSStackView()
    private let contextValue = NSTextField(labelWithString: L10n.shared["context.empty"])
    private let titleField = NSTextField(labelWithString: "OFFLINE")
    private let detailField = NSTextField(labelWithString: L10n.shared["status.offline_codex"])
    private let primaryQuota = QuotaRowView(title: L10n.shared["quota.5h"])
    private let secondaryQuota = QuotaRowView(title: L10n.shared["quota.weekly"])
    private let dualTrackContainer = NSView()
    private let quotaTopDivider = NSView()
    private let quotaInterRowDivider = NSView()
    private let singleTrackView = SingleTrackQuotaView()
    private let agentToggle = AgentToggleView()
    private let contextPill = NSView()
    private let quotaGroup = NSView()
    /// Hosts the fixed-height session body slot (empty | session card).
    /// Plain `NSView` (not `NSStackView`) so width is explicit and not ambiguous.
    private let metadataGroup = NSView()
    private let bodySlot = NSView()
    private let emptyBody = EmptySessionBodyView()
    private let sessionCard = SessionCardView()
    private var topRow: NSView?
    private var agentToggleWidthConstraint: NSLayoutConstraint?
    private var sessionBodyMode: DetailsPanelSessionBodyRole = .unknown
    private var usageTrackMode: DetailsPanelUsageTrackMode = .dual
    private var appearanceOverride: Bool?
    /// Last live context percent used to soft-hold the pill after STANDBY.
    private var heldContextPercent: Double?
    /// When the standby hold started/should end; `nil` means not currently holding.
    private var contextHoldExpiresAt: Date?
    private var contextHoldAgent: AgentKind?
    private var statusMotionKey = ""
    private var statusMotionAgent: AgentKind?
    private let sessionDivider = NSView()
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onAgentSelected: ((AgentKind) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 226),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .readOnly
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: Self.panelWidth, height: 0)
        contentMaxSize = NSSize(width: Self.panelWidth, height: CGFloat.greatestFiniteMagnitude)

        containerView.frame = contentView?.bounds ?? .zero
        containerView.material = .popover
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 22
        containerView.layer?.masksToBounds = true
        containerView.layer?.borderWidth = 1
        containerView.translatesAutoresizingMaskIntoConstraints = false

        surfaceView.identifier = NSUserInterfaceItemIdentifier("details-panel-surface")
        surfaceView.wantsLayer = true
        surfaceView.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 17, bottom: 4, right: 17)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let topRow = makeTopRow()
        self.topRow = topRow
        stack.addArrangedSubview(topRow)
        stack.setCustomSpacing(12, after: topRow)

        titleField.font = .systemFont(ofSize: 22, weight: .bold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.usesSingleLineMode = true
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.alignment = .left
        detailField.font = .systemFont(ofSize: 13)
        detailField.lineBreakMode = .byTruncatingTail
        detailField.maximumNumberOfLines = 1
        detailField.usesSingleLineMode = true
        detailField.cell?.truncatesLastVisibleLine = true
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailField.alignment = .left
        stack.addArrangedSubview(titleField)
        stack.setCustomSpacing(2, after: titleField)
        stack.addArrangedSubview(detailField)
        stack.setCustomSpacing(11, after: detailField)

        quotaGroup.translatesAutoresizingMaskIntoConstraints = false
        dualTrackContainer.translatesAutoresizingMaskIntoConstraints = false
        singleTrackView.translatesAutoresizingMaskIntoConstraints = false
        quotaTopDivider.wantsLayer = true
        quotaTopDivider.translatesAutoresizingMaskIntoConstraints = false
        quotaInterRowDivider.wantsLayer = true
        quotaInterRowDivider.translatesAutoresizingMaskIntoConstraints = false

        dualTrackContainer.addSubview(primaryQuota)
        dualTrackContainer.addSubview(quotaInterRowDivider)
        dualTrackContainer.addSubview(secondaryQuota)

        quotaGroup.addSubview(quotaTopDivider)
        quotaGroup.addSubview(dualTrackContainer)
        quotaGroup.addSubview(singleTrackView)
        singleTrackView.isHidden = true
        stack.addArrangedSubview(quotaGroup)

        // Plain container: explicit full-width pin avoids NSStackView width
        // ambiguity that shrank empty/card to label-hugging size (right-biased).
        metadataGroup.translatesAutoresizingMaskIntoConstraints = false

        bodySlot.translatesAutoresizingMaskIntoConstraints = false
        emptyBody.translatesAutoresizingMaskIntoConstraints = false
        sessionCard.translatesAutoresizingMaskIntoConstraints = false
        for view in [quotaGroup, dualTrackContainer, singleTrackView, bodySlot, emptyBody, sessionCard] as [NSView] {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        sessionDivider.wantsLayer = true
        sessionDivider.translatesAutoresizingMaskIntoConstraints = false
        bodySlot.addSubview(sessionDivider)
        bodySlot.addSubview(emptyBody)
        bodySlot.addSubview(sessionCard)
        metadataGroup.addSubview(bodySlot)
        metadataGroup.isHidden = true
        stack.addArrangedSubview(metadataGroup)

        emptyBody.isHidden = true
        sessionCard.isHidden = true

        let rootView = TrackingDetailsContentView()
        rootView.owner = self
        contentView = rootView
        contentView?.addSubview(containerView)
        containerView.addSubview(surfaceView)
        containerView.addSubview(stack)

        NSLayoutConstraint.activate([
            contentView!.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            containerView.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: contentView!.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
            surfaceView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: containerView.topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: containerView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            topRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            titleField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 17),
            titleField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            detailField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 17),
            detailField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),

            quotaGroup.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 17),
            quotaGroup.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            quotaGroup.heightAnchor.constraint(equalToConstant: Self.usageBodyHeight),

            quotaTopDivider.leadingAnchor.constraint(equalTo: quotaGroup.leadingAnchor),
            quotaTopDivider.trailingAnchor.constraint(equalTo: quotaGroup.trailingAnchor),
            quotaTopDivider.bottomAnchor.constraint(equalTo: quotaGroup.topAnchor, constant: -7),
            quotaTopDivider.heightAnchor.constraint(equalToConstant: 1),

            dualTrackContainer.leadingAnchor.constraint(equalTo: quotaGroup.leadingAnchor),
            dualTrackContainer.trailingAnchor.constraint(equalTo: quotaGroup.trailingAnchor),
            dualTrackContainer.topAnchor.constraint(equalTo: quotaGroup.topAnchor),
            dualTrackContainer.bottomAnchor.constraint(equalTo: quotaGroup.bottomAnchor),

            primaryQuota.leadingAnchor.constraint(equalTo: dualTrackContainer.leadingAnchor),
            primaryQuota.trailingAnchor.constraint(equalTo: dualTrackContainer.trailingAnchor),
            primaryQuota.topAnchor.constraint(equalTo: dualTrackContainer.topAnchor),

            quotaInterRowDivider.leadingAnchor.constraint(equalTo: dualTrackContainer.leadingAnchor),
            quotaInterRowDivider.trailingAnchor.constraint(equalTo: dualTrackContainer.trailingAnchor),
            quotaInterRowDivider.topAnchor.constraint(equalTo: primaryQuota.bottomAnchor, constant: 4),
            quotaInterRowDivider.heightAnchor.constraint(equalToConstant: 1),

            secondaryQuota.leadingAnchor.constraint(equalTo: dualTrackContainer.leadingAnchor),
            secondaryQuota.trailingAnchor.constraint(equalTo: dualTrackContainer.trailingAnchor),
            secondaryQuota.topAnchor.constraint(equalTo: primaryQuota.bottomAnchor, constant: 8),

            singleTrackView.leadingAnchor.constraint(equalTo: quotaGroup.leadingAnchor),
            singleTrackView.trailingAnchor.constraint(equalTo: quotaGroup.trailingAnchor),
            singleTrackView.topAnchor.constraint(equalTo: quotaGroup.topAnchor),
            singleTrackView.bottomAnchor.constraint(equalTo: quotaGroup.bottomAnchor),

            metadataGroup.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 17),
            metadataGroup.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            bodySlot.leadingAnchor.constraint(equalTo: metadataGroup.leadingAnchor),
            bodySlot.trailingAnchor.constraint(equalTo: metadataGroup.trailingAnchor),
            bodySlot.topAnchor.constraint(equalTo: metadataGroup.topAnchor),
            bodySlot.bottomAnchor.constraint(
                equalTo: metadataGroup.bottomAnchor,
                constant: -Self.sessionBodyBottomEqualizer
            ),
            bodySlot.heightAnchor.constraint(equalToConstant: Self.sessionBodyHeight),
            sessionDivider.leadingAnchor.constraint(equalTo: bodySlot.leadingAnchor),
            sessionDivider.trailingAnchor.constraint(equalTo: bodySlot.trailingAnchor),
            sessionDivider.topAnchor.constraint(equalTo: bodySlot.topAnchor),
            sessionDivider.heightAnchor.constraint(equalToConstant: 1),
            emptyBody.leadingAnchor.constraint(equalTo: bodySlot.leadingAnchor),
            emptyBody.trailingAnchor.constraint(equalTo: bodySlot.trailingAnchor),
            emptyBody.topAnchor.constraint(equalTo: bodySlot.topAnchor),
            emptyBody.bottomAnchor.constraint(equalTo: bodySlot.bottomAnchor),
            sessionCard.leadingAnchor.constraint(equalTo: bodySlot.leadingAnchor),
            sessionCard.trailingAnchor.constraint(equalTo: bodySlot.trailingAnchor),
            sessionCard.topAnchor.constraint(equalTo: bodySlot.topAnchor),
            sessionCard.bottomAnchor.constraint(equalTo: bodySlot.bottomAnchor)
        ])

        applyTheme()
    }

    var currentThemePalette: DetailsPanelThemePalette {
        if let appearanceOverride {
            return appearanceOverride ? .dark : .light
        }
        // In the live macOS app (`NSApp != nil`), follow the system's effective
        // appearance. In headless CLI self-tests (`NSApp == nil`), default to
        // light unless explicitly overridden via `setAppearanceOverrideForTesting`.
        guard let app = NSApp else {
            return .light
        }
        let match = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
    }

    func applyTheme() {
        let palette = currentThemePalette
        containerView.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        containerView.layer?.borderColor = palette.containerBorder.cgColor
        surfaceView.layer?.backgroundColor = palette.surfaceFill.cgColor
        detailField.textColor = palette.mutedText
        contextPill.layer?.backgroundColor = palette.contextPillFill.cgColor
        contextPill.layer?.borderColor = palette.contextPillBorder.cgColor
        contextValue.textColor = palette.contextPillText
        quotaTopDivider.layer?.backgroundColor = palette.divider.cgColor
        quotaInterRowDivider.layer?.backgroundColor = palette.divider.cgColor
        sessionDivider.layer?.backgroundColor = palette.divider.cgColor

        agentToggle.applyTheme(palette)
        primaryQuota.applyTheme(palette)
        secondaryQuota.applyTheme(palette)
        singleTrackView.applyTheme(palette)
        emptyBody.applyTheme(palette)
        sessionCard.applyTheme(palette)
    }

    func setAppearanceOverrideForTesting(_ isDark: Bool?) {
        appearanceOverride = isDark
        applyTheme()
    }

    var isDarkThemeForTesting: Bool {
        currentThemePalette.isDark
    }

    func render(aggregate: AggregateSnapshot, model: DetailsPanelViewModel, now: Date = Date()) {
        #if DEBUG
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if duration > 16.67 {
                NSLog("[Performance] DetailsPanel.render took %.2fms (>1 frame)", duration)
            }
        }
        #endif

        applyTheme()
        updateStatus(aggregate: aggregate, now: now)
        let isOffline = aggregate.state == .idle && aggregate.label == "OFFLINE"
        let isStandby = aggregate.label == "STANDBY"
        updateContext(
            model.contextUsedPercent,
            isOffline: isOffline,
            isStandby: isStandby,
            focusedAgent: aggregate.focusedAgent,
            now: now
        )

        quotaGroup.isHidden = true
        metadataGroup.isHidden = true

        switch model.body {
        case .usage(let usage):
            stack.setCustomSpacing(16, after: detailField)
            stack.edgeInsets.bottom = 4
            sessionBodyMode = .unknown
            renderUsage(usage, focusedAgent: aggregate.focusedAgent, now: now)
            quotaGroup.isHidden = false
        case .session(let session):
            stack.setCustomSpacing(11, after: detailField)
            stack.edgeInsets.bottom = 4
            renderSession(session, isOffline: isOffline)
            metadataGroup.isHidden = false
        }
        resizeToFitContent()
    }

    /// Disk-/statusline-backed agents (Grok, Claude) only refresh context on
    /// full content render. While the panel stays open mid-turn, AppDelegate
    /// can push a fresh percent without rebuilding quota/session rows.
    func updateLiveContextPercent(
        _ contextUsedPercent: Double?,
        aggregate: AggregateSnapshot,
        now: Date = Date()
    ) {
        let isOffline = aggregate.state == .idle && aggregate.label == "OFFLINE"
        let isStandby = aggregate.label == "STANDBY"
        updateContext(
            contextUsedPercent,
            isOffline: isOffline,
            isStandby: isStandby,
            focusedAgent: aggregate.focusedAgent,
            now: now
        )
    }

    private func updateContext(
        _ contextUsedPercent: Double?,
        isOffline: Bool,
        isStandby: Bool = false,
        focusedAgent: AgentKind? = nil,
        now: Date = Date()
    ) {
        if let focusedAgent {
            if let contextHoldAgent, contextHoldAgent != focusedAgent {
                heldContextPercent = nil
                contextHoldExpiresAt = nil
            }
            contextHoldAgent = focusedAgent
        }

        let resolved = Self.resolveContextDisplay(
            contextUsedPercent: contextUsedPercent,
            isOffline: isOffline,
            isStandby: isStandby,
            heldPercent: heldContextPercent,
            holdExpiresAt: contextHoldExpiresAt,
            now: now,
            holdDuration: Self.standbyContextHoldDuration
        )
        heldContextPercent = resolved.heldPercent
        contextHoldExpiresAt = resolved.holdExpiresAt
        contextPill.isHidden = resolved.display == nil
        contextValue.stringValue = resolved.display.map(Self.compactContextPercent)
            ?? L10n.shared["context.empty"]
    }

    /// Pure display/hold state machine for the context pill.
    /// - Live percent: show and remember for a future STANDBY hold.
    /// - STANDBY + remembered percent: keep showing until `holdDuration` elapses.
    /// - OFFLINE: clear immediately (no hold).
    nonisolated static func resolveContextDisplay(
        contextUsedPercent: Double?,
        isOffline: Bool,
        isStandby: Bool,
        heldPercent: Double?,
        holdExpiresAt: Date?,
        now: Date,
        holdDuration: TimeInterval = standbyContextHoldDuration
    ) -> (display: Double?, heldPercent: Double?, holdExpiresAt: Date?) {
        if isOffline {
            return (nil, nil, nil)
        }
        if let contextUsedPercent {
            return (contextUsedPercent, contextUsedPercent, nil)
        }
        guard isStandby, let heldPercent else {
            return (nil, nil, nil)
        }
        let expiresAt = holdExpiresAt ?? now.addingTimeInterval(holdDuration)
        if now < expiresAt {
            return (heldPercent, heldPercent, expiresAt)
        }
        return (nil, nil, nil)
    }

    static func resolveUsageTrackMode(
        usage: UsageDetailsModel,
        focusedAgent: AgentKind
    ) -> DetailsPanelUsageTrackMode {
        let hasSession = usage.windows.contains { $0.kind == .session }
        let hasWeekly = usage.windows.contains { $0.kind == .weekly }
        if hasSession && hasWeekly {
            return .dual
        }
        if hasSession != hasWeekly {
            return .single
        }
        return focusedAgent == .grok ? .single : .dual
    }

    private func renderUsage(_ usage: UsageDetailsModel, focusedAgent: AgentKind, now: Date) {
        let sessionWindow = usage.windows.first { $0.kind == .session }
        let weeklyWindow = usage.windows.first { $0.kind == .weekly }

        primaryQuota.setTitle(L10n.shared["quota.5h"])
        secondaryQuota.setTitle(L10n.shared["quota.weekly"])
        renderUsageWindow(sessionWindow, in: primaryQuota, now: now)
        renderUsageWindow(weeklyWindow, in: secondaryQuota, now: now)

        let mode = Self.resolveUsageTrackMode(usage: usage, focusedAgent: focusedAgent)
        usageTrackMode = mode
        dualTrackContainer.isHidden = (mode == .single)
        singleTrackView.isHidden = (mode == .dual)

        if let weeklyWindow {
            singleTrackView.setTitle(L10n.shared["quota.weekly"])
            singleTrackView.update(usedPercent: weeklyWindow.usedPercent, resetAt: weeklyWindow.resetsAt, now: now)
        } else if let sessionWindow {
            singleTrackView.setTitle(L10n.shared["quota.5h"])
            singleTrackView.update(usedPercent: sessionWindow.usedPercent, resetAt: sessionWindow.resetsAt, now: now)
        } else {
            singleTrackView.setTitle(L10n.shared["quota.weekly"])
            singleTrackView.updateUnavailable()
        }
    }

    private func renderUsageWindow(_ window: UsageWindow?, in row: QuotaRowView, now: Date) {
        guard let window else {
            row.updateUnavailable()
            return
        }
        row.update(usedPercent: window.usedPercent, resetAt: window.resetsAt, now: now)
    }

    private func renderSession(_ session: SessionDetailsSnapshot, isOffline: Bool) {
        // Soft empty rectangle for both OFFLINE and online-with-no-fields so we
        // never show a card full of "--" (STANDBY often has empty snapshots).
        // Same copy for offline and blank/standby: "○ No session".
        if isOffline || !Self.hasSessionCardContent(session) {
            emptyBody.isHidden = false
            sessionCard.isHidden = true
            emptyBody.setText("○ " + L10n.shared["session.empty.api_key"])
            sessionBodyMode = .empty
            // Clear hidden card fields so a11y / subsequent reads do not leak
            // the previous session title, model, or tokens.
            sessionCard.setTitle("--", toolTip: nil)
            sessionCard.setModel("--")
            sessionCard.setTokens(input: nil, output: nil)
            return
        }

        emptyBody.isHidden = true
        sessionCard.isHidden = false
        sessionBodyMode = .sessionCard
        let line = Self.sessionCardLine(session)
        sessionCard.setTitle(line.text, toolTip: line.toolTip)
        sessionCard.setModel(Self.displayValue(session.modelName))
        sessionCard.setTokens(input: session.inputTokens, output: session.outputTokens)
    }

    /// Card is only worth showing when at least one field the card paints has data.
    /// `projectName` alone does not count — the card never surfaces it.
    /// A working directory does: Pi, OpenCode, and WorkBuddy use it as the primary line.
    static func hasSessionCardContent(_ session: SessionDetailsSnapshot) -> Bool {
        if nonEmpty(session.workingDirectory) != nil {
            return true
        }
        if nonEmpty(session.sessionTitle) != nil {
            return true
        }
        if let model = session.modelName, !model.isEmpty {
            return true
        }
        return session.inputTokens != nil || session.outputTokens != nil
    }

    /// Primary session line. A path wins over a raw session name; Claude and
    /// Codex keep the session title when no directory was supplied.
    static func sessionCardLine(
        _ session: SessionDetailsSnapshot
    ) -> (text: String, toolTip: String?) {
        if let path = nonEmpty(session.workingDirectory) {
            return (path, path)
        }
        if let title = nonEmpty(session.sessionTitle) {
            return (title, title)
        }
        return ("--", nil)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resizeToFitContent() {
        contentView?.layoutSubtreeIfNeeded()
        let scale = effectiveBackingScale
        let fittingHeight = Self.evenPanelHeight(
            for: stack.fittingSize.height,
            backingScaleFactor: scale
        )
        let topEdge = frame.maxY
        let newFrame = NSRect(
            x: frame.minX,
            y: topEdge - fittingHeight,
            width: Self.panelWidth,
            height: fittingHeight
        )
        applyResizeFrame(newFrame, display: false, animate: false)
    }

    func applyResizeFrame(_ frame: NSRect, display: Bool, animate: Bool) {
        setFrame(frame, display: display, animate: animate)
    }

    private var effectiveBackingScale: CGFloat {
        screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    static func evenPanelHeight(for fittingHeight: CGFloat, backingScaleFactor: CGFloat) -> CGFloat {
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 1
        let pixelAlignedHeight = ceil(fittingHeight * scale) / scale
        return ceil(pixelAlignedHeight / 2) * 2
    }

    func updateStatus(aggregate: AggregateSnapshot, now: Date = Date()) {
        titleField.stringValue = aggregate.label
        let rgb = HaloVisualModel.stateColor(aggregate.state)
        titleField.textColor = NSColor(calibratedRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: 1)
        detailField.stringValue = Self.localizedDetail(for: aggregate)
        agentToggle.setAgent(aggregate.focusedAgent)
        playStatusMotion(
            agent: aggregate.focusedAgent,
            label: aggregate.label,
            detail: detailField.stringValue
        )
        let isOffline = aggregate.state == .idle && aggregate.label == "OFFLINE"
        let isStandby = aggregate.label == "STANDBY"
        switch aggregate.focusedAgent {
        case .codex:
            // Codex streams context on the status-only path from live snapshots.
            // Empty sessions on STANDBY soft-hold the last percent briefly.
            updateContext(
                aggregate.sessions.first?.contextUsedPercent,
                isOffline: isOffline,
                isStandby: isStandby,
                focusedAgent: .codex,
                now: now
            )
        case .grok, .claudeCode, .pi, .antigravity, .opencode, .workbuddy:
            // Grok/Claude/Pi context is disk-, statusline-, or extension-backed on
            // full content refresh. Only STANDBY/OFFLINE status ticks should touch
            // the pill: STANDBY soft-holds the last live percent; OFFLINE clears
            // immediately. Active labels leave existing metadata alone (status-only
            // path must not wipe context when sessions briefly look empty).
            if isOffline || isStandby {
                updateContext(
                    nil,
                    isOffline: isOffline,
                    isStandby: isStandby,
                    focusedAgent: aggregate.focusedAgent,
                    now: now
                )
            }
        }
    }

    /// Short crossfade plus a few points of travel when the focused agent changes.
    /// Opacity stays high so the panel does not flash white.
    private func playStatusMotion(agent: AgentKind, label: String, detail: String) {
        let key = "\(agent.rawValue)\u{1f}\(label)\u{1f}\(detail)"
        let previousAgent = statusMotionAgent
        let changed = key != statusMotionKey
        statusMotionKey = key
        statusMotionAgent = agent
        guard changed, previousAgent != nil else { return }
        var shift: CGFloat = 0
        if let previousAgent, previousAgent != agent,
           let from = AgentKind.allCases.firstIndex(of: previousAgent),
           let to = AgentKind.allCases.firstIndex(of: agent),
           from != to {
            shift = to > from ? 5 : -5
        }
        for view in [titleField, detailField, metadataGroup, quotaGroup] as [NSView] {
            view.wantsLayer = true
            view.layer?.removeAnimation(forKey: "agenthalo.status.move")
            view.layer?.removeAnimation(forKey: "agenthalo.status.fade")
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = -shift
            move.toValue = 0
            move.duration = 0.18
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.78
            fade.toValue = 1
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layer?.add(move, forKey: "agenthalo.status.move")
            view.layer?.add(fade, forKey: "agenthalo.status.fade")
        }
    }

    /// Formats a future reset timestamp as a compact relative countdown:
    /// - `>= 1 day`: `"3d 18:30"`
    /// - `>= 1 hour`: `"2h 14m"`
    /// - `< 1 hour`: `"45m"`
    static func formatResetTime(_ date: Date?, now: Date = Date()) -> String {
        guard let date else {
            return ""
        }
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else {
            return ""
        }
        let totalMinutes = max(1, Int(ceil(remaining / 60)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return String(format: "%dd %02d:%02d", days, hours, minutes)
        }
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        return "\(minutes)m"
    }

    static func makeClockIcon(color: NSColor, size: CGFloat = 11) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setStroke()
            let inset = rect.insetBy(dx: 1.1, dy: 1.1)
            let circle = NSBezierPath(ovalIn: inset)
            circle.lineWidth = 1.25
            circle.stroke()

            let center = NSPoint(x: rect.midX, y: rect.midY)
            let hands = NSBezierPath()
            hands.lineWidth = 1.25
            hands.lineCapStyle = .round
            hands.lineJoinStyle = .round
            hands.move(to: NSPoint(x: center.x, y: center.y + inset.height * 0.28))
            hands.line(to: center)
            hands.line(to: NSPoint(x: center.x + inset.width * 0.22, y: center.y - inset.height * 0.12))
            hands.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func compactTokenCount(_ count: Int64?) -> String {
        guard let count else {
            return "--"
        }
        guard count >= 1_000 else {
            return String(count)
        }
        let thousands = Double(count) / 1_000
        if thousands.rounded() == thousands {
            return "\(Int(thousands))k"
        }
        return String(format: "%.1fk", locale: Locale(identifier: "en_US_POSIX"), thousands)
    }

    static func compactContextPercent(_ value: Double) -> String {
        "\(min(99, max(0, Int(value.rounded()))))%"
    }

    static func formatTokenChip(input: Bool, count: Int64?) -> String {
        (input ? "↑ " : "↓ ") + compactTokenCount(count)
    }

    private static func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "--"
        }
        return value
    }

    static func localizedDetail(for aggregate: AggregateSnapshot) -> String {
        if aggregate.state == .idle {
            if aggregate.label == "PAUSED" {
                return L10n.shared["status.paused"]
            }
            if aggregate.label == "CONNECTING" {
                return aggregate.detail.isEmpty
                    ? aggregate.focusedAgent.localizedConnectingDetail
                    : aggregate.detail
            }
            return aggregate.focusedAgent.localizedOfflineDetail
        }
        if aggregate.label == "STANDBY",
           !aggregate.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return aggregate.detail
        }
        let action = aggregate.sessions.first?.action ?? aggregate.detail
        if action.localizedCaseInsensitiveContains("Writing answer") {
            return L10n.shared["status.writing_answer"]
        }
        if action.localizedCaseInsensitiveContains("command") { return L10n.shared["status.running_command"] }
        if action.localizedCaseInsensitiveContains("Editing") { return L10n.shared["status.editing_files"] }
        if action.localizedCaseInsensitiveContains("Search") { return L10n.shared["status.searching"] }
        if action.localizedCaseInsensitiveContains("Compressing context") { return L10n.shared["status.compressing_context"] }
        if action.localizedCaseInsensitiveContains("Context compacted") { return L10n.shared["status.context_compacted"] }
        if action.localizedCaseInsensitiveContains("Awaiting permission") { return L10n.shared["status.awaiting_permission"] }
        if action.localizedCaseInsensitiveContains("Permission denied") { return L10n.shared["status.permission_denied"] }
        if action.localizedCaseInsensitiveContains("Reviewing result") { return L10n.shared["status.reviewing_result"] }
        switch aggregate.state {
        case .thinking: return L10n.shared["status.thinking"]
        case .working: return L10n.shared["status.working"]
        case .done: return L10n.shared["status.done"]
        case .attention: return L10n.shared["status.attention"]
        case .error:
            if let action = aggregate.sessions.first?.action,
               !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return action
            }
            return aggregate.detail.isEmpty ? L10n.shared["status.error"] : aggregate.detail
        case .idle: return aggregate.focusedAgent.localizedOfflineDetail
        }
    }

    private func makeTopRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        agentToggle.onAgentSelected = { [weak self] agent in
            self?.onAgentSelected?(agent)
        }

        contextPill.wantsLayer = true
        contextPill.layer?.cornerRadius = 8
        contextPill.layer?.masksToBounds = true
        contextPill.layer?.borderWidth = 1
        contextPill.translatesAutoresizingMaskIntoConstraints = false

        contextValue.font = .systemFont(ofSize: 15, weight: .bold)
        contextValue.alignment = .center
        contextValue.lineBreakMode = .byTruncatingTail
        contextValue.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(agentToggle)
        row.addSubview(contextPill)
        contextPill.addSubview(contextValue)

        let toggleWidth = agentToggle.widthAnchor.constraint(
            equalToConstant: AgentToggleView.slotWidth * CGFloat(HaloSettings.defaultEnabledAgents.count)
        )
        agentToggleWidthConstraint = toggleWidth

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 32),
            agentToggle.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            agentToggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            toggleWidth,
            agentToggle.heightAnchor.constraint(equalToConstant: 32),
            contextPill.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            contextPill.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            contextPill.widthAnchor.constraint(equalToConstant: Self.contextPillWidth),
            contextPill.heightAnchor.constraint(equalToConstant: Self.contextPillHeight),
            contextPill.leadingAnchor.constraint(greaterThanOrEqualTo: agentToggle.trailingAnchor, constant: 10),
            contextValue.centerXAnchor.constraint(equalTo: contextPill.centerXAnchor),
            contextValue.centerYAnchor.constraint(equalTo: contextPill.centerYAnchor),
            contextValue.leadingAnchor.constraint(greaterThanOrEqualTo: contextPill.leadingAnchor, constant: 2),
            contextValue.trailingAnchor.constraint(lessThanOrEqualTo: contextPill.trailingAnchor, constant: -2)
        ])
        return row
    }

    func setEnabledAgents(_ agents: [AgentKind], focused: AgentKind) {
        agentToggle.setEnabledAgents(
            agents,
            focused: focused,
            maximumWidth: Self.agentToggleMaximumWidth
        )
        agentToggleWidthConstraint?.constant = agentToggle.toggleWidthForTesting
    }

    /// Room left of the context pill inside the fixed 304pt panel:
    /// 304 - insets 34 - pill 46 - gap 10.
    static let agentToggleMaximumWidth: CGFloat = 214

    var enabledAgentsForTesting: [AgentKind] {
        agentToggle.enabledAgentsForTesting
    }

    var agentToggleWidthForTesting: CGFloat {
        agentToggle.toggleWidthForTesting
    }

    var focusedAgentForTesting: AgentKind {
        agentToggle.selectedAgent
    }

    var titleTextForTesting: String {
        titleField.stringValue
    }

    var detailTextForTesting: String {
        detailField.stringValue
    }

    var detailFrameForTesting: CGRect {
        detailField.convert(detailField.bounds, to: contentView)
    }

    var contextPillHiddenForTesting: Bool {
        contextPill.isHidden
    }

    var contextValueForTesting: String {
        contextValue.stringValue
    }

    var contextPillWidthForTesting: CGFloat {
        contextPill.frame.width
    }

    var contextValueWidthForTesting: CGFloat {
        contextValue.bounds.width
    }

    var contextValueIntrinsicWidthForTesting: CGFloat {
        contextValue.intrinsicContentSize.width
    }

    var contextValueExpansionFrameForTesting: CGRect {
        contextValue.cell?.expansionFrame(withFrame: contextValue.bounds, in: contextValue) ?? .zero
    }

    var contentOrderForTesting: [DetailsPanelContentRole] {
        stack.arrangedSubviews.map { view in
            if view === topRow { return .agentSwitcher }
            if view === titleField { return .statusTitle }
            if view === detailField { return .statusDetail }
            if view === quotaGroup { return .usageBody }
            if view === metadataGroup { return .sessionBody }
            return .unknown
        }
    }

    var usageGroupHiddenForTesting: Bool {
        quotaGroup.isHidden
    }

    var sessionGroupHiddenForTesting: Bool {
        metadataGroup.isHidden
    }

    var usageTrackModeForTesting: DetailsPanelUsageTrackMode {
        usageTrackMode
    }

    var singleTrackTitleForTesting: String {
        singleTrackView.titleForTesting
    }

    var singleTrackHeroValueForTesting: String {
        singleTrackView.heroValueForTesting
    }

    var singleTrackUsedValueForTesting: String {
        singleTrackView.usedValueForTesting
    }

    var singleTrackRemainingValueForTesting: String {
        singleTrackView.remainingValueForTesting
    }

    var singleTrackResetValueForTesting: String {
        singleTrackView.resetValueForTesting
    }

    var singleTrackMeterFillForTesting: Double {
        singleTrackView.meterFillForTesting
    }

    var sessionBodyOrderForTesting: [DetailsPanelSessionBodyRole] {
        [sessionBodyModeForTesting]
    }

    var sessionRowHeightsForTesting: [CGFloat] {
        contentView?.layoutSubtreeIfNeeded()
        return [sessionBodySlotHeightForTesting]
    }

    // MARK: - Scheme B session body accessors

    var sessionBodyModeForTesting: DetailsPanelSessionBodyRole { sessionBodyMode }

    var sessionCardTitleForTesting: String { sessionCard.titleText }

    var sessionCardModelForTesting: String { sessionCard.modelText }

    var sessionCardTokensForTesting: String { sessionCard.tokensText }

    var sessionCardTitleToolTipForTesting: String? { sessionCard.titleToolTipText }

    var sessionBodySlotHeightForTesting: CGFloat {
        contentView?.layoutSubtreeIfNeeded()
        return bodySlot.frame.height
    }

    var sessionCardHeightForTesting: CGFloat {
        contentView?.layoutSubtreeIfNeeded()
        return sessionCard.frame.height
    }

    var sessionEmptyTextForTesting: String { emptyBody.text }

    var emptyBodyHeightForTesting: CGFloat {
        contentView?.layoutSubtreeIfNeeded()
        return emptyBody.frame.height
    }

    var primaryQuotaTitleForTesting: String {
        primaryQuota.titleForTesting
    }

    var secondaryQuotaTitleForTesting: String {
        secondaryQuota.titleForTesting
    }

    var primaryQuotaValueForTesting: String {
        primaryQuota.valueForTesting
    }

    var secondaryQuotaValueForTesting: String {
        secondaryQuota.valueForTesting
    }

    var primaryQuotaUsedValueForTesting: String {
        primaryQuota.usedForTesting
    }

    var secondaryQuotaUsedValueForTesting: String {
        secondaryQuota.usedForTesting
    }

    var primaryQuotaResetTextForTesting: String {
        primaryQuota.resetTextForTesting
    }

    var secondaryQuotaResetTextForTesting: String {
        secondaryQuota.resetTextForTesting
    }

    var primaryQuotaResetHiddenForTesting: Bool {
        primaryQuota.resetHiddenForTesting
    }

    var secondaryQuotaResetHiddenForTesting: Bool {
        secondaryQuota.resetHiddenForTesting
    }

    var primaryQuotaMeterFillForTesting: Double {
        primaryQuota.meterFillForTesting
    }

    var secondaryQuotaMeterFillForTesting: Double {
        secondaryQuota.meterFillForTesting
    }

    var primaryQuotaFrameForTesting: CGRect {
        primaryQuota.convert(primaryQuota.bounds, to: contentView)
    }

    var primaryQuotaNameFrameForTesting: CGRect {
        primaryQuota.convert(primaryQuota.nameFrameForTesting, to: contentView)
    }

    var secondaryQuotaFrameForTesting: CGRect {
        secondaryQuota.convert(secondaryQuota.bounds, to: contentView)
    }

    var secondaryQuotaResetFrameForTesting: CGRect {
        secondaryQuota.convert(secondaryQuota.resetFrameForTesting, to: contentView)
    }

    var primaryQuotaHasAmbiguousLayoutForTesting: Bool {
        primaryQuota.hasAmbiguousLayout
    }

    var secondaryQuotaHasAmbiguousLayoutForTesting: Bool {
        secondaryQuota.hasAmbiguousLayout
    }

    var sessionTitleValueForTesting: String {
        sessionCard.titleText
    }

    var modelValueForTesting: String {
        sessionCard.modelText
    }

    var tokenValueForTesting: String {
        sessionCard.tokensText
    }

    var sessionTitleToolTipForTesting: String? {
        sessionCard.titleToolTipText
    }

    var modelToolTipForTesting: String? {
        nil
    }

    var frameWidthForTesting: CGFloat {
        frame.width
    }

    var frameHeightForTesting: CGFloat {
        frame.height
    }

    var stackFittingHeightForTesting: CGFloat {
        stack.fittingSize.height
    }

    var metadataTopInsetForTesting: CGFloat {
        0
    }

    var backingScaleForTesting: CGFloat {
        effectiveBackingScale
    }

    func selectAgentForTesting(_ agent: AgentKind) {
        agentToggle.setAgent(agent)
        onAgentSelected?(agent)
    }
}

/// Empty session copy shares the status text's left edge. No separate dashed box.
@MainActor
private final class EmptySessionBodyView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String) {
        label.stringValue = text
    }

    func applyTheme(_ palette: DetailsPanelThemePalette) {
        label.textColor = palette.mutedText
    }
}

/// Online session summary: path or title, then model / input / output chips.
@MainActor
private final class SessionCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "--")
    private let modelChip = NSView()
    private let modelLabel = NSTextField(labelWithString: "--")
    private let inputChip = NSView()
    private let inputLabel = NSTextField(labelWithString: "↑ --")
    private let outputChip = NSView()
    private let outputLabel = NSTextField(labelWithString: "↓ --")

    var titleText: String { titleLabel.stringValue }
    var modelText: String { modelLabel.stringValue }
    var tokensText: String { "\(inputLabel.stringValue) \(outputLabel.stringValue)" }
    var titleToolTipText: String? { titleLabel.toolTip }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        configureChip(modelChip, label: modelLabel)
        configureChip(inputChip, label: inputLabel)
        configureChip(outputChip, label: outputLabel)
        inputLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        outputLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        addSubview(titleLabel)
        addSubview(modelChip)
        addSubview(inputChip)
        addSubview(outputChip)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),

            modelChip.leadingAnchor.constraint(equalTo: leadingAnchor),
            modelChip.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            modelChip.heightAnchor.constraint(equalToConstant: 22),
            modelChip.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            modelChip.trailingAnchor.constraint(lessThanOrEqualTo: inputChip.leadingAnchor, constant: -8),

            inputChip.centerYAnchor.constraint(equalTo: modelChip.centerYAnchor),
            inputChip.heightAnchor.constraint(equalToConstant: 22),
            inputChip.widthAnchor.constraint(lessThanOrEqualToConstant: 75),
            inputChip.trailingAnchor.constraint(equalTo: outputChip.leadingAnchor, constant: -5),

            outputChip.trailingAnchor.constraint(equalTo: trailingAnchor),
            outputChip.centerYAnchor.constraint(equalTo: modelChip.centerYAnchor),
            outputChip.heightAnchor.constraint(equalToConstant: 22),
            outputChip.widthAnchor.constraint(lessThanOrEqualToConstant: 75)
        ])

        applyTheme(.light)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ palette: DetailsPanelThemePalette) {
        titleLabel.textColor = palette.primaryText
        modelChip.layer?.backgroundColor = palette.modelChipFill.cgColor
        modelLabel.textColor = palette.modelChipText
        inputChip.layer?.backgroundColor = palette.inputChipFill.cgColor
        inputLabel.textColor = palette.inputChipText
        outputChip.layer?.backgroundColor = palette.outputChipFill.cgColor
        outputLabel.textColor = palette.outputChipText
    }

    func setTitle(_ title: String, toolTip: String?) {
        titleLabel.stringValue = title
        if let toolTip, !toolTip.isEmpty, toolTip != "--" {
            titleLabel.toolTip = toolTip
        } else {
            titleLabel.toolTip = nil
        }
    }

    func setModel(_ model: String) {
        modelLabel.stringValue = model
        modelLabel.toolTip = model == "--" ? nil : model
    }

    func setTokens(input: Int64?, output: Int64?) {
        inputLabel.stringValue = DetailsPanel.formatTokenChip(input: true, count: input)
        outputLabel.stringValue = DetailsPanel.formatTokenChip(input: false, count: output)
    }

    private func configureChip(_ chip: NSView, label: NSTextField) {
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 5
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: chip.centerYAnchor)
        ])
    }
}

@MainActor
private final class TrackingDetailsContentView: NSView {
    weak var owner: DetailsPanel?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.applyTheme()
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        owner?.onMouseExited?()
    }
}

/// Dual-Track quota row (Scheme A):
/// Top row: Window title (left) + Clock icon & countdown (right)
/// Middle row: 6pt rounded capsule progress bar
/// Bottom row: Used X% (left) + Remaining Y% (right)
@MainActor
private final class QuotaRowView: NSView {
    private let nameField: NSTextField
    private let resetContainer = NSView()
    private let resetClockView = NSImageView()
    private let resetField = NSTextField(labelWithString: "")
    private let usedField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: L10n.shared["quota.no_data"])
    private let meter = RoundedMeterView()
    private var currentPalette: DetailsPanelThemePalette = .light
    private var lastUsedPercent: Double?

    init(title: String) {
        nameField = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ palette: DetailsPanelThemePalette) {
        currentPalette = palette
        nameField.textColor = palette.primaryText
        resetField.textColor = palette.mutedText
        resetClockView.image = DetailsPanel.makeClockIcon(color: palette.mutedText, size: 11)
        meter.trackColor = palette.meterTrack
        meter.accentStartColor = palette.meterAccentStart
        meter.accentEndColor = palette.meterAccentEnd
        if let used = lastUsedPercent {
            applyActiveDualLabels(usedPercent: used)
        } else {
            usedField.textColor = palette.mutedText
            valueField.textColor = palette.mutedText
        }
    }

    func update(usedPercent: Double, resetAt: Date?, now: Date = Date()) {
        if let resetAt, resetAt <= now {
            lastUsedPercent = nil
            usedField.attributedStringValue = NSAttributedString(string: "")
            usedField.stringValue = "\(L10n.shared["quota.used_label"]) --"
            usedField.textColor = currentPalette.mutedText
            valueField.attributedStringValue = NSAttributedString(string: "")
            valueField.stringValue = L10n.shared["quota.waiting_refresh"]
            valueField.textColor = currentPalette.mutedText
            resetField.stringValue = ""
            resetContainer.isHidden = true
            meter.value = 0
            return
        }
        let clampedUsed = min(100, max(0, usedPercent))
        lastUsedPercent = clampedUsed
        applyActiveDualLabels(usedPercent: clampedUsed)
        meter.value = clampedUsed
        let resetText = DetailsPanel.formatResetTime(resetAt, now: now)
        resetField.stringValue = resetText
        resetContainer.isHidden = resetText.isEmpty
    }

    func updateUnavailable() {
        lastUsedPercent = nil
        usedField.attributedStringValue = NSAttributedString(string: "")
        usedField.stringValue = "\(L10n.shared["quota.used_label"]) --"
        usedField.textColor = currentPalette.mutedText
        valueField.attributedStringValue = NSAttributedString(string: "")
        valueField.stringValue = L10n.shared["quota.no_data"]
        valueField.textColor = currentPalette.mutedText
        resetField.stringValue = ""
        resetContainer.isHidden = true
        meter.value = 0
    }

    private func applyActiveDualLabels(usedPercent: Double) {
        let usedInt = Int(usedPercent.rounded())
        let remainingInt = min(100, max(0, 100 - usedInt))
        usedField.attributedStringValue = Self.makePairAttributedString(
            label: L10n.shared["quota.used_label"],
            value: "\(usedInt)%",
            palette: currentPalette,
            alignment: .left
        )
        valueField.attributedStringValue = Self.makePairAttributedString(
            label: L10n.shared["quota.remaining_label"],
            value: "\(remainingInt)%",
            palette: currentPalette,
            alignment: .right
        )
    }

    private static func makePairAttributedString(
        label: String,
        value: String,
        palette: DetailsPanelThemePalette,
        alignment: NSTextAlignment
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let result = NSMutableAttributedString(
            string: "\(label) ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: palette.mutedText,
                .paragraphStyle: paragraph
            ]
        )
        result.append(NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .bold),
                .foregroundColor: palette.primaryText,
                .paragraphStyle: paragraph
            ]
        ))
        return result
    }

    func setTitle(_ title: String) {
        nameField.stringValue = title
    }

    var titleForTesting: String {
        nameField.stringValue
    }

    var valueForTesting: String {
        valueField.stringValue
    }

    var usedForTesting: String {
        usedField.stringValue
    }

    var resetTextForTesting: String {
        resetField.stringValue
    }

    var resetHiddenForTesting: Bool {
        resetContainer.isHidden
    }

    var meterFillForTesting: Double {
        meter.value
    }

    var nameFrameForTesting: CGRect {
        nameField.frame
    }

    var resetFrameForTesting: CGRect {
        resetContainer.frame
    }

    private func setup() {
        meter.usesAccentFill = true
        nameField.font = .systemFont(ofSize: 12.5, weight: .bold)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameField.setContentHuggingPriority(.required, for: .horizontal)

        resetClockView.translatesAutoresizingMaskIntoConstraints = false
        resetClockView.imageScaling = .scaleProportionallyDown

        resetField.font = .systemFont(ofSize: 11, weight: .medium)
        resetField.lineBreakMode = .byTruncatingTail
        resetField.alignment = .right
        resetField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        resetField.setContentHuggingPriority(.required, for: .horizontal)
        resetField.translatesAutoresizingMaskIntoConstraints = false

        resetContainer.translatesAutoresizingMaskIntoConstraints = false
        resetContainer.addSubview(resetClockView)
        resetContainer.addSubview(resetField)

        usedField.font = .systemFont(ofSize: 11, weight: .regular)
        usedField.alignment = .left
        usedField.lineBreakMode = .byTruncatingTail
        usedField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        valueField.font = .systemFont(ofSize: 11.5, weight: .semibold)
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingTail
        valueField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        valueField.setContentHuggingPriority(.required, for: .horizontal)

        [nameField, resetContainer, meter, usedField, valueField].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        resetContainer.isHidden = true

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),

            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.topAnchor.constraint(equalTo: topAnchor),

            resetContainer.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 8),
            resetContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            resetContainer.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            resetContainer.heightAnchor.constraint(equalToConstant: 14),

            resetClockView.leadingAnchor.constraint(equalTo: resetContainer.leadingAnchor),
            resetClockView.centerYAnchor.constraint(equalTo: resetContainer.centerYAnchor),
            resetClockView.widthAnchor.constraint(equalToConstant: 11),
            resetClockView.heightAnchor.constraint(equalToConstant: 11),

            resetField.leadingAnchor.constraint(equalTo: resetClockView.trailingAnchor, constant: 4),
            resetField.trailingAnchor.constraint(equalTo: resetContainer.trailingAnchor),
            resetField.centerYAnchor.constraint(equalTo: resetContainer.centerYAnchor),

            meter.leadingAnchor.constraint(equalTo: leadingAnchor),
            meter.trailingAnchor.constraint(equalTo: trailingAnchor),
            meter.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 4),
            meter.heightAnchor.constraint(equalToConstant: 6),

            usedField.leadingAnchor.constraint(equalTo: leadingAnchor),
            usedField.topAnchor.constraint(equalTo: meter.bottomAnchor, constant: 4),
            usedField.trailingAnchor.constraint(lessThanOrEqualTo: valueField.leadingAnchor, constant: -8),

            valueField.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueField.centerYAnchor.constraint(equalTo: usedField.centerYAnchor)
        ])

        applyTheme(.light)
    }
}

/// Single-Track Hero View (Style 1):
/// Used when an agent or subscription provides only a single window (e.g., Grok Weekly or Codex Weekly-only Plus).
@MainActor
private final class SingleTrackQuotaView: NSView {
    private let titleField = NSTextField(labelWithString: L10n.shared["quota.weekly"])
    private let heroValueField = NSTextField(labelWithString: L10n.shared["quota.no_data"])
    private let meter = RoundedMeterView()
    private let usedCaptionField = NSTextField(labelWithString: L10n.shared["quota.used_label"])
    private let usedValueField = NSTextField(labelWithString: "--")
    private let remainingCaptionField = NSTextField(labelWithString: L10n.shared["quota.remaining_label"])
    private let remainingValueField = NSTextField(labelWithString: "--")
    private let divider = NSView()
    private let resetClockView = NSImageView()
    private let resetTitleField = NSTextField(labelWithString: L10n.shared["quota.reset_at"])
    private let resetValueField = NSTextField(labelWithString: "--")
    private var currentPalette: DetailsPanelThemePalette = .light
    private var isAvailable = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ palette: DetailsPanelThemePalette) {
        currentPalette = palette
        titleField.textColor = palette.primaryText
        heroValueField.textColor = isAvailable ? palette.primaryText : palette.mutedText
        usedCaptionField.textColor = palette.mutedText
        usedValueField.textColor = palette.primaryText
        remainingCaptionField.textColor = palette.mutedText
        remainingValueField.textColor = palette.primaryText
        divider.layer?.backgroundColor = palette.divider.cgColor
        resetClockView.image = DetailsPanel.makeClockIcon(color: palette.primaryText, size: 12)
        resetTitleField.textColor = palette.primaryText
        resetValueField.textColor = palette.mutedText
        meter.trackColor = palette.meterTrack
        meter.accentStartColor = palette.meterAccentStart
        meter.accentEndColor = palette.meterAccentEnd
    }

    func setTitle(_ title: String) {
        titleField.stringValue = title
        usedCaptionField.stringValue = L10n.shared["quota.used_label"]
        remainingCaptionField.stringValue = L10n.shared["quota.remaining_label"]
        resetTitleField.stringValue = L10n.shared["quota.reset_at"]
    }

    func update(usedPercent: Double, resetAt: Date?, now: Date = Date()) {
        usedCaptionField.stringValue = L10n.shared["quota.used_label"]
        remainingCaptionField.stringValue = L10n.shared["quota.remaining_label"]
        resetTitleField.stringValue = L10n.shared["quota.reset_at"]

        if let resetAt, resetAt <= now {
            isAvailable = false
            heroValueField.font = .systemFont(ofSize: 13, weight: .semibold)
            heroValueField.textColor = currentPalette.mutedText
            heroValueField.stringValue = L10n.shared["quota.waiting_refresh"]
            usedValueField.stringValue = "--"
            remainingValueField.stringValue = "--"
            resetValueField.stringValue = "--"
            meter.value = 0
            return
        }

        isAvailable = true
        let clampedUsed = min(100, max(0, usedPercent))
        let usedInt = Int(clampedUsed.rounded())
        let remainingInt = min(100, max(0, 100 - usedInt))

        heroValueField.font = .systemFont(ofSize: 25, weight: .heavy)
        heroValueField.textColor = currentPalette.primaryText
        heroValueField.stringValue = "\(usedInt)%"

        usedValueField.stringValue = "\(usedInt)%"
        remainingValueField.stringValue = "\(remainingInt)%"
        meter.value = clampedUsed

        let resetText = DetailsPanel.formatResetTime(resetAt, now: now)
        resetValueField.stringValue = resetText.isEmpty ? "--" : resetText
    }

    func updateUnavailable() {
        isAvailable = false
        usedCaptionField.stringValue = L10n.shared["quota.used_label"]
        remainingCaptionField.stringValue = L10n.shared["quota.remaining_label"]
        resetTitleField.stringValue = L10n.shared["quota.reset_at"]

        heroValueField.font = .systemFont(ofSize: 13, weight: .semibold)
        heroValueField.textColor = currentPalette.mutedText
        heroValueField.stringValue = L10n.shared["quota.no_data"]
        usedValueField.stringValue = "--"
        remainingValueField.stringValue = "--"
        resetValueField.stringValue = "--"
        meter.value = 0
    }

    var titleForTesting: String { titleField.stringValue }
    var heroValueForTesting: String { heroValueField.stringValue }
    var usedValueForTesting: String { usedValueField.stringValue }
    var remainingValueForTesting: String { remainingValueField.stringValue }
    var resetValueForTesting: String { resetValueField.stringValue }
    var meterFillForTesting: Double { meter.value }

    private func setup() {
        meter.usesAccentFill = true
        titleField.font = .systemFont(ofSize: 16, weight: .bold)
        titleField.lineBreakMode = .byTruncatingTail

        heroValueField.font = .systemFont(ofSize: 25, weight: .heavy)
        heroValueField.alignment = .right
        heroValueField.setContentCompressionResistancePriority(.required, for: .horizontal)

        usedCaptionField.font = .systemFont(ofSize: 11, weight: .regular)
        usedValueField.font = .systemFont(ofSize: 12.5, weight: .bold)

        remainingCaptionField.font = .systemFont(ofSize: 11, weight: .regular)
        remainingCaptionField.alignment = .right
        remainingValueField.font = .systemFont(ofSize: 12.5, weight: .bold)
        remainingValueField.alignment = .right

        divider.wantsLayer = true

        resetClockView.imageScaling = .scaleProportionallyDown
        resetTitleField.font = .systemFont(ofSize: 11.5, weight: .semibold)
        resetValueField.font = .systemFont(ofSize: 11.5, weight: .medium)
        resetValueField.alignment = .right

        [
            titleField, heroValueField, meter,
            usedCaptionField, usedValueField,
            remainingCaptionField, remainingValueField,
            divider, resetClockView, resetTitleField, resetValueField
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            heroValueField.topAnchor.constraint(equalTo: topAnchor, constant: -2),
            heroValueField.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.centerYAnchor.constraint(equalTo: heroValueField.centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: heroValueField.leadingAnchor, constant: -8),

            meter.leadingAnchor.constraint(equalTo: leadingAnchor),
            meter.trailingAnchor.constraint(equalTo: trailingAnchor),
            meter.topAnchor.constraint(equalTo: topAnchor, constant: 29),
            meter.heightAnchor.constraint(equalToConstant: 7),

            usedCaptionField.leadingAnchor.constraint(equalTo: leadingAnchor),
            usedCaptionField.topAnchor.constraint(equalTo: meter.bottomAnchor, constant: 5),

            usedValueField.leadingAnchor.constraint(equalTo: leadingAnchor),
            usedValueField.topAnchor.constraint(equalTo: usedCaptionField.bottomAnchor, constant: 1),

            remainingCaptionField.trailingAnchor.constraint(equalTo: trailingAnchor),
            remainingCaptionField.centerYAnchor.constraint(equalTo: usedCaptionField.centerYAnchor),

            remainingValueField.trailingAnchor.constraint(equalTo: trailingAnchor),
            remainingValueField.centerYAnchor.constraint(equalTo: usedValueField.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: usedValueField.bottomAnchor, constant: 6),
            divider.heightAnchor.constraint(equalToConstant: 1),

            resetClockView.leadingAnchor.constraint(equalTo: leadingAnchor),
            resetClockView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 7),
            resetClockView.widthAnchor.constraint(equalToConstant: 12),
            resetClockView.heightAnchor.constraint(equalToConstant: 12),

            resetTitleField.leadingAnchor.constraint(equalTo: resetClockView.trailingAnchor, constant: 5),
            resetTitleField.centerYAnchor.constraint(equalTo: resetClockView.centerYAnchor),

            resetValueField.trailingAnchor.constraint(equalTo: trailingAnchor),
            resetValueField.centerYAnchor.constraint(equalTo: resetClockView.centerYAnchor),
            resetValueField.leadingAnchor.constraint(greaterThanOrEqualTo: resetTitleField.trailingAnchor, constant: 8)
        ])

        applyTheme(.light)
    }
}

@MainActor
enum QuotaMeterPalette {
    private struct Stop {
        let percent: Double
        let red: Double
        let green: Double
        let blue: Double
    }

    private static let stops = [
        Stop(percent: 0, red: 202, green: 217, blue: 224),
        Stop(percent: 25, red: 168, green: 191, blue: 202),
        Stop(percent: 50, red: 112, green: 148, blue: 169),
        Stop(percent: 75, red: 82, green: 121, blue: 146),
        Stop(percent: 100, red: 64, green: 105, blue: 132),
    ]

    static func fillColor(for remainingPercent: Double) -> NSColor {
        let clamped = min(100, max(0, remainingPercent))
        guard let upperIndex = stops.firstIndex(where: { clamped <= $0.percent }) else {
            return color(for: stops[stops.count - 1])
        }
        guard upperIndex > 0 else {
            return color(for: stops[0])
        }

        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let progress = (clamped - lower.percent) / (upper.percent - lower.percent)
        return NSColor(
            deviceRed: component(from: lower.red, to: upper.red, progress: progress),
            green: component(from: lower.green, to: upper.green, progress: progress),
            blue: component(from: lower.blue, to: upper.blue, progress: progress),
            alpha: 1
        )
    }

    private static func color(for stop: Stop) -> NSColor {
        NSColor(
            deviceRed: CGFloat(stop.red) / 255,
            green: CGFloat(stop.green) / 255,
            blue: CGFloat(stop.blue) / 255,
            alpha: 1
        )
    }

    private static func component(from start: Double, to end: Double, progress: Double) -> CGFloat {
        CGFloat(start + (end - start) * progress) / 255
    }
}

@MainActor
final class RoundedMeterView: NSView {
    var value: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }

    var usesAccentFill: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    var trackColor: NSColor = NSColor(calibratedRed: 0.72, green: 0.79, blue: 0.84, alpha: 0.30) {
        didSet {
            needsDisplay = true
        }
    }

    var accentStartColor: NSColor = DetailsPanelThemePalette.light.meterAccentStart {
        didSet {
            needsDisplay = true
        }
    }

    var accentEndColor: NSColor = DetailsPanelThemePalette.light.meterAccentEnd {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let radius = bounds.height / 2
        let trackPath = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        if usesAccentFill {
            trackColor.setFill()
        } else {
            NSColor(calibratedRed: 0.72, green: 0.79, blue: 0.84, alpha: 0.30).setFill()
        }
        trackPath.fill()

        let rawFillWidth = bounds.width * min(100, max(0, value)) / 100
        guard rawFillWidth > 0 else {
            return
        }
        let fillWidth = max(bounds.height, rawFillWidth)
        let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        if usesAccentFill,
           let gradient = NSGradient(starting: accentStartColor, ending: accentEndColor) {
            gradient.draw(in: fillPath, angle: 0)
        } else {
            QuotaMeterPalette.fillColor(for: value).setFill()
            fillPath.fill()
        }
    }
}

@MainActor
final class AgentToggleView: NSView {
    static let slotWidth: CGFloat = 36

    var onAgentSelected: ((AgentKind) -> Void)?

    private(set) var selectedAgent: AgentKind = .codex {
        didSet {
            updateSelectedState(animated: true)
        }
    }

    private var enabledAgents: [AgentKind] = HaloSettings.defaultEnabledAgents
    var enabledAgentsForTesting: [AgentKind] { enabledAgents }
    var toggleWidthForTesting: CGFloat { widthConstraint.constant }

    private let bgView = AgentToggleContentView()
    private let activeBg = NSView()
    private let codexIcon = NSImageView()
    private let claudeIcon = NSImageView()
    private let grokIcon = NSImageView()
    private let piIcon = NSImageView()
    private let antigravityIcon = NSImageView()
    private let openCodeIcon = NSImageView()
    private let workBuddyIcon = NSImageView()
    private var colorIconImages: [AgentKind: NSImage] = [:]
    private var darkActiveIconImages: [AgentKind: NSImage] = [:]
    private var grayIconImages: [AgentKind: NSImage] = [:]
    private var darkGrayIconImages: [AgentKind: NSImage] = [:]
    private var currentPalette: DetailsPanelThemePalette = .light
    private var maximumWidth: CGFloat?
    private var activeBgConstraints: [NSLayoutConstraint] = []
    private var iconLayoutConstraints: [NSLayoutConstraint] = []
    private var slotGuides: [NSView] = []
    private var widthConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func applyTheme(_ palette: DetailsPanelThemePalette) {
        currentPalette = palette
        bgView.layer?.borderColor = palette.toggleBgBorder.cgColor
        bgView.layer?.backgroundColor = palette.toggleBgFill.cgColor
        activeBg.layer?.borderColor = palette.toggleActiveBorder.cgColor
        activeBg.layer?.backgroundColor = palette.toggleActiveFill.cgColor
        updateSelectedState(animated: false)
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 16
        bgView.layer?.borderWidth = 1
        bgView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bgView)

        activeBg.wantsLayer = true
        activeBg.layer?.cornerRadius = 13
        activeBg.layer?.borderWidth = 1
        activeBg.layer?.shadowColor = NSColor(calibratedRed: 0.26, green: 0.70, blue: 0.80, alpha: 1).cgColor
        activeBg.layer?.shadowOpacity = 0.12
        activeBg.layer?.shadowRadius = 5
        activeBg.layer?.shadowOffset = .zero
        activeBg.translatesAutoresizingMaskIntoConstraints = false
        bgView.addSubview(activeBg)

        configureIcon(codexIcon, assetName: "codex", accessibilityLabel: "Codex")
        configureIcon(claudeIcon, assetName: "claude-code", accessibilityLabel: "Claude Code")
        configureIcon(grokIcon, assetName: "grok", accessibilityLabel: "Grok")
        configureIcon(piIcon, assetName: "pi", accessibilityLabel: "Pi")
        configureIcon(antigravityIcon, assetName: "antigravity", accessibilityLabel: "Antigravity")
        configureIcon(openCodeIcon, assetName: "opencode", accessibilityLabel: "OpenCode")
        configureIcon(workBuddyIcon, assetName: "workbuddy", accessibilityLabel: "WorkBuddy")
        for agent in AgentKind.allCases {
            guard let image = icon(for: agent).image else { continue }
            colorIconImages[agent] = image
            grayIconImages[agent] = AgentIconAssets.grayscale(image)
            darkGrayIconImages[agent] = AgentIconAssets.lightSilhouette(image, brightness: 200)
            if agent == .codex || agent == .grok || agent == .pi {
                darkActiveIconImages[agent] = AgentIconAssets.lightSilhouette(image, brightness: 248)
            } else {
                darkActiveIconImages[agent] = image
            }
        }
        bgView.addSubview(codexIcon)
        bgView.addSubview(claudeIcon)
        bgView.addSubview(grokIcon)
        bgView.addSubview(piIcon)
        bgView.addSubview(antigravityIcon)
        bgView.addSubview(openCodeIcon)
        bgView.addSubview(workBuddyIcon)

        widthConstraint = widthAnchor.constraint(
            equalToConstant: Self.slotWidth * CGFloat(HaloSettings.defaultEnabledAgents.count)
        )

        NSLayoutConstraint.activate([
            widthConstraint,
            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bgView.topAnchor.constraint(equalTo: topAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyTheme(.light)
        applyEnabledAgents(HaloSettings.defaultEnabledAgents, focused: .codex, animated: false)
    }

    func setEnabledAgents(_ agents: [AgentKind], focused: AgentKind, maximumWidth: CGFloat? = nil) {
        self.maximumWidth = maximumWidth
        applyEnabledAgents(agents, focused: focused, animated: true)
    }

    func setAgent(_ agent: AgentKind) {
        guard selectedAgent != agent else { return }
        selectedAgent = agent
    }

    func selectAgentAtXForTesting(_ x: CGFloat) {
        selectAgent(atX: x)
    }

    private func applyEnabledAgents(_ agents: [AgentKind], focused: AgentKind, animated: Bool) {
        var visible = AgentKind.allCases.filter { agents.contains($0) }
        if visible.isEmpty {
            visible = HaloSettings.defaultEnabledAgents
        }
        enabledAgents = visible

        for agent in AgentKind.allCases {
            icon(for: agent).isHidden = !visible.contains(agent)
        }

        rebuildIconLayout(visible: visible)
        let natural = Self.slotWidth * CGFloat(visible.count)
        widthConstraint.constant = maximumWidth.map { min(natural, $0) } ?? natural

        let nextSelected = visible.contains(focused) ? focused : visible[0]
        if selectedAgent != nextSelected {
            selectedAgent = nextSelected
        } else {
            updateSelectedState(animated: animated)
        }
    }

    private func rebuildIconLayout(visible: [AgentKind]) {
        NSLayoutConstraint.deactivate(iconLayoutConstraints)
        iconLayoutConstraints = []
        slotGuides.forEach { $0.removeFromSuperview() }
        slotGuides = []

        guard !visible.isEmpty else { return }

        let fraction = 1.0 / CGFloat(visible.count)
        for (index, agent) in visible.enumerated() {
            let imageView = icon(for: agent)
            let guide = NSView()
            guide.translatesAutoresizingMaskIntoConstraints = false
            bgView.addSubview(guide)
            slotGuides.append(guide)
            iconLayoutConstraints.append(contentsOf: [
                guide.leadingAnchor.constraint(equalTo: bgView.leadingAnchor),
                guide.widthAnchor.constraint(
                    equalTo: bgView.widthAnchor,
                    multiplier: CGFloat(index) * fraction
                ),
                guide.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
                guide.heightAnchor.constraint(equalToConstant: 0),
                imageView.leadingAnchor.constraint(equalTo: guide.trailingAnchor, constant: 1),
                imageView.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
                imageView.widthAnchor.constraint(
                    equalTo: bgView.widthAnchor,
                    multiplier: fraction,
                    constant: -2
                ),
                imageView.heightAnchor.constraint(equalToConstant: 18),
            ])
        }

        NSLayoutConstraint.activate(iconLayoutConstraints)
    }

    private func updateSelectedState(animated: Bool) {
        NSLayoutConstraint.deactivate(activeBgConstraints)

        let targetIcon = icon(for: selectedAgent)

        activeBgConstraints = [
            activeBg.leadingAnchor.constraint(equalTo: targetIcon.leadingAnchor),
            activeBg.trailingAnchor.constraint(equalTo: targetIcon.trailingAnchor),
            activeBg.topAnchor.constraint(equalTo: bgView.topAnchor, constant: 3),
            activeBg.bottomAnchor.constraint(equalTo: bgView.bottomAnchor, constant: -3)
        ]

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                NSLayoutConstraint.activate(activeBgConstraints)
                self.layoutSubtreeIfNeeded()
            }
        } else {
            NSLayoutConstraint.activate(activeBgConstraints)
        }

        for agent in AgentKind.allCases {
            let imageView = icon(for: agent)
            let isSelected = agent == selectedAgent
            if currentPalette.isDark {
                let activeImg = darkActiveIconImages[agent] ?? colorIconImages[agent]
                let inactiveImg = darkGrayIconImages[agent] ?? grayIconImages[agent] ?? colorIconImages[agent]
                imageView.image = isSelected ? activeImg : inactiveImg
                imageView.alphaValue = isSelected ? 1 : 0.48
            } else {
                let grayImage = grayIconImages[agent]
                imageView.image = isSelected ? colorIconImages[agent] : (grayImage ?? colorIconImages[agent])
                let inactiveAlpha: CGFloat = agent == .workbuddy && grayImage != nil ? 1 : 0.40
                imageView.alphaValue = isSelected ? 1 : inactiveAlpha
            }
        }
    }

    private func icon(for agent: AgentKind) -> NSImageView {
        switch agent {
        case .codex: return codexIcon
        case .claudeCode: return claudeIcon
        case .grok: return grokIcon
        case .pi: return piIcon
        case .antigravity: return antigravityIcon
        case .opencode: return openCodeIcon
        case .workbuddy: return workBuddyIcon
        }
    }

    private func configureIcon(_ imageView: NSImageView, assetName: String, accessibilityLabel: String) {
        imageView.image = AgentIconAssets.image(named: assetName)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setAccessibilityLabel(accessibilityLabel)
        imageView.setAccessibilityRole(.image)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selectAgent(atX: point.x)
    }

    private func selectAgent(atX x: CGFloat) {
        guard !enabledAgents.isEmpty else { return }
        let width = bounds.width > 1 ? bounds.width : Self.slotWidth * CGFloat(enabledAgents.count)
        let slot = max(width / CGFloat(enabledAgents.count), 1)
        let index = min(enabledAgents.count - 1, max(0, Int(x / slot)))
        let newAgent = enabledAgents[index]
        if newAgent != selectedAgent {
            selectedAgent = newAgent
            onAgentSelected?(newAgent)
        }
    }
}

@MainActor
private final class AgentToggleContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

enum AgentIconAssets {
    static func image(named name: String) -> NSImage? {
        guard let url = url(named: name),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return NSImage(data: data)
    }

    private static func url(named name: String) -> URL? {
        for ext in ["svg", "png"] {
            if let bundled = Bundle.main.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "agent-switch"
            ) {
                return bundled
            }
        }

        let srcRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot = srcRoot.deletingLastPathComponent()
        let candidates = [
            srcRoot.appendingPathComponent("shared/assets/agent-switch/\(name).svg"),
            srcRoot.appendingPathComponent("shared/assets/agent-switch/\(name).png"),
            repoRoot.appendingPathComponent("docs/assets/agent-switch/\(name).png"),
            repoRoot.appendingPathComponent("docs/assets/agent-switch/\(name).svg")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Unselected icons keep their silhouette and transparency, without brand colors.
    @MainActor
    static func grayscale(_ image: NSImage) -> NSImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(2, 64 / max(image.size.width, image.size.height))
        let width = max(1, Int(ceil(image.size.width * scale)))
        let height = max(1, Int(ceil(image.size.height * scale)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap),
           let pixels = bitmap.bitmapData else { return nil }

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(bounds)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        for y in 0..<height {
            for x in 0..<width {
                let pixel = pixels.advanced(by: y * bitmap.bytesPerRow + x * 4)
                let luminance = 54 * Int(pixel[0]) + 183 * Int(pixel[1]) + 19 * Int(pixel[2])
                let gray = UInt8((luminance + 128) / 256)
                pixel[0] = gray
                pixel[1] = gray
                pixel[2] = gray
            }
        }
        bitmap.size = image.size
        let result = NSImage(size: image.size)
        result.addRepresentation(bitmap)
        return result
    }

    /// Light silhouette used on dark surfaces so black-ink SVGs remain legible.
    @MainActor
    static func lightSilhouette(_ image: NSImage, brightness: UInt8) -> NSImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(2, 64 / max(image.size.width, image.size.height))
        let width = max(1, Int(ceil(image.size.width * scale)))
        let height = max(1, Int(ceil(image.size.height * scale)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap),
           let pixels = bitmap.bitmapData else { return nil }

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(bounds)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        for y in 0..<height {
            for x in 0..<width {
                let pixel = pixels.advanced(by: y * bitmap.bytesPerRow + x * 4)
                guard pixel[3] > 0 else { continue }
                pixel[0] = brightness
                pixel[1] = brightness
                pixel[2] = brightness
            }
        }
        bitmap.size = image.size
        let result = NSImage(size: image.size)
        result.addRepresentation(bitmap)
        return result
    }
}
