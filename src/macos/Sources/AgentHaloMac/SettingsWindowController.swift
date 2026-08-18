import AppKit
import AgentHaloCore

/// Key settings panel above the halo for enabled agents and preferences.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSettingsChanged: ((HaloSettings) -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    var onResetPosition: (() -> Void)?

    private var settings = HaloSettings()
    private var isApplyingUI = false

    private let contentWidth: CGFloat = 360
    private let horizontalInset: CGFloat = 20
    private let sectionSpacing: CGFloat = 18
    private let rowSpacing: CGFloat = 10

    private let rootStack = NSStackView()
    private let homeTitleLabel = NSTextField(labelWithString: "")
    private let homeSubtitleLabel = NSTextField(labelWithString: "")
    private let chipsContainer = SettingsChipFlowView()
    private let appearanceTitleLabel = NSTextField(labelWithString: "")
    private let haloSizeLabel = NSTextField(labelWithString: "")
    private let haloSizeValueLabel = NSTextField(labelWithString: "")
    private let haloSizeSlider = NSSlider(
        value: HaloSettings.defaultHaloSize,
        minValue: HaloSettings.minimumHaloSize,
        maxValue: HaloSettings.maximumHaloSize,
        target: nil,
        action: nil
    )
    private let languageLabel = NSTextField(labelWithString: "")
    private let languageControl = NSSegmentedControl(
        labels: ["", "", ""],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let generalTitleLabel = NSTextField(labelWithString: "")
    private let alwaysOnTopSwitch = NSSwitch()
    private let alwaysOnTopLabel = NSTextField(labelWithString: "")
    private let showMenuBarIconSwitch = NSSwitch()
    private let showMenuBarIconLabel = NSTextField(labelWithString: "")
    private let launchAtLoginSwitch = NSSwitch()
    private let launchAtLoginLabel = NSTextField(labelWithString: "")
    private let resetPositionButton = NSButton(title: "", target: nil, action: nil)
    private let versionLabel = NSTextField(labelWithString: "")

    private var chipButtons: [AgentKind: SettingsAgentChip] = [:]

    convenience init() {
        let panel = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.title = L10n.shared["settings.title"]
        self.init(window: panel)
        panel.delegate = self
        buildUI()
        panel.contentView = makeContentView()
        panel.setContentSize(fittedContentSize())
    }

    // MARK: - Public

    func present(settings: HaloSettings, launchAtLogin: Bool) {
        refresh(settings: settings, launchAtLogin: launchAtLogin)
        centerOnMainScreen()
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh(settings: HaloSettings, launchAtLogin: Bool) {
        self.settings = settings.normalized()
        isApplyingUI = true
        defer { isApplyingUI = false }

        applyLocalizedStrings()
        syncChips()
        haloSizeSlider.doubleValue = self.settings.haloSize
        haloSizeValueLabel.stringValue = "\(Int(self.settings.haloSize.rounded()))"
        syncLanguageSegment()
        alwaysOnTopSwitch.state = self.settings.alwaysOnTop ? .on : .off
        showMenuBarIconSwitch.state = self.settings.showMenuBarIcon ? .on : .off
        launchAtLoginSwitch.state = launchAtLogin ? .on : .off
        versionLabel.stringValue = Self.versionFooterText()

        window?.title = L10n.shared["settings.title"]
        window?.setContentSize(fittedContentSize())
    }

    func toggleAgentForTesting(_ agent: AgentKind) {
        toggleAgent(agent)
    }

    var enabledAgentsForTesting: [AgentKind] {
        settings.enabledAgents
    }

    // MARK: - UI construction

    private func buildUI() {
        styleSectionTitle(homeTitleLabel)
        styleSubtitle(homeSubtitleLabel)
        styleSectionTitle(appearanceTitleLabel)
        styleSectionTitle(generalTitleLabel)
        styleRowLabel(haloSizeLabel)
        styleRowLabel(languageLabel)
        styleRowLabel(alwaysOnTopLabel)
        styleRowLabel(showMenuBarIconLabel)
        styleRowLabel(launchAtLoginLabel)

        haloSizeValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        haloSizeValueLabel.textColor = .secondaryLabelColor
        haloSizeValueLabel.alignment = .right
        haloSizeValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        haloSizeSlider.target = self
        haloSizeSlider.action = #selector(haloSizeChanged(_:))
        haloSizeSlider.isContinuous = true

        languageControl.segmentStyle = .rounded
        languageControl.segmentCount = 3
        languageControl.target = self
        languageControl.action = #selector(languageChanged(_:))

        alwaysOnTopSwitch.target = self
        alwaysOnTopSwitch.action = #selector(alwaysOnTopChanged(_:))
        showMenuBarIconSwitch.target = self
        showMenuBarIconSwitch.action = #selector(showMenuBarIconChanged(_:))
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginChanged(_:))

        resetPositionButton.bezelStyle = .rounded
        resetPositionButton.target = self
        resetPositionButton.action = #selector(resetPositionClicked(_:))
        resetPositionButton.setContentHuggingPriority(.defaultLow, for: .horizontal)

        versionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .center
        versionLabel.isSelectable = true

        chipsContainer.onChipTapped = { [weak self] agent in
            self?.toggleAgent(agent)
        }

        for agent in AgentKind.allCases {
            let chip = SettingsAgentChip(agent: agent)
            chipButtons[agent] = chip
            chipsContainer.addChip(chip)
        }
    }

    private func makeContentView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = sectionSpacing
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.edgeInsets = NSEdgeInsets(
            top: 16,
            left: horizontalInset,
            bottom: 16,
            right: horizontalInset
        )
        container.addSubview(rootStack)

        // Home display
        let homeStack = NSStackView(views: [homeTitleLabel, homeSubtitleLabel, chipsContainer])
        homeStack.orientation = .vertical
        homeStack.alignment = .leading
        homeStack.spacing = 6
        chipsContainer.translatesAutoresizingMaskIntoConstraints = false

        // Appearance
        let sizeHeader = NSStackView(views: [haloSizeLabel, haloSizeValueLabel])
        sizeHeader.orientation = .horizontal
        sizeHeader.alignment = .centerY
        sizeHeader.distribution = .fill
        sizeHeader.spacing = 8
        haloSizeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let appearanceStack = NSStackView(views: [
            appearanceTitleLabel,
            sizeHeader,
            haloSizeSlider,
            languageLabel,
            languageControl,
        ])
        appearanceStack.orientation = .vertical
        appearanceStack.alignment = .leading
        appearanceStack.spacing = rowSpacing
        sizeHeader.translatesAutoresizingMaskIntoConstraints = false
        haloSizeSlider.translatesAutoresizingMaskIntoConstraints = false
        languageControl.translatesAutoresizingMaskIntoConstraints = false

        // General
        let alwaysRow = toggleRow(label: alwaysOnTopLabel, control: alwaysOnTopSwitch)
        let menuBarRow = toggleRow(label: showMenuBarIconLabel, control: showMenuBarIconSwitch)
        let launchRow = toggleRow(label: launchAtLoginLabel, control: launchAtLoginSwitch)
        let generalStack = NSStackView(views: [
            generalTitleLabel,
            alwaysRow,
            menuBarRow,
            launchRow,
            resetPositionButton,
        ])
        generalStack.orientation = .vertical
        generalStack.alignment = .leading
        generalStack.spacing = rowSpacing

        rootStack.addArrangedSubview(homeStack)
        rootStack.addArrangedSubview(appearanceStack)
        rootStack.addArrangedSubview(generalStack)
        rootStack.addArrangedSubview(versionLabel)

        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: container.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            chipsContainer.widthAnchor.constraint(equalToConstant: contentWidth),
            sizeHeader.widthAnchor.constraint(equalToConstant: contentWidth),
            haloSizeSlider.widthAnchor.constraint(equalToConstant: contentWidth),
            languageControl.widthAnchor.constraint(equalToConstant: contentWidth),
            alwaysRow.widthAnchor.constraint(equalToConstant: contentWidth),
            menuBarRow.widthAnchor.constraint(equalToConstant: contentWidth),
            launchRow.widthAnchor.constraint(equalToConstant: contentWidth),
            resetPositionButton.widthAnchor.constraint(equalToConstant: contentWidth),
            versionLabel.widthAnchor.constraint(equalToConstant: contentWidth),
        ])

        return container
    }

    private func toggleRow(label: NSTextField, control: NSSwitch) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func styleSectionTitle(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .labelColor
    }

    private func styleSubtitle(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 11, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 2
        field.preferredMaxLayoutWidth = contentWidth
    }

    private func styleRowLabel(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 12, weight: .regular)
        field.textColor = .labelColor
    }

    private func fittedContentSize() -> NSSize {
        let fitting = rootStack.fittingSize
        let width = contentWidth + horizontalInset * 2
        let height = max(fitting.height, 1)
        return NSSize(width: width, height: height)
    }

    private func centerOnMainScreen() {
        guard let window else { return }
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    // MARK: - Sync

    private func applyLocalizedStrings() {
        homeTitleLabel.stringValue = L10n.shared["settings.home_display.title"]
        homeSubtitleLabel.stringValue = L10n.shared["settings.home_display.subtitle"]
        appearanceTitleLabel.stringValue = L10n.shared["settings.appearance"]
        haloSizeLabel.stringValue = L10n.shared["settings.halo_size"]
        languageLabel.stringValue = L10n.shared["settings.language"]
        generalTitleLabel.stringValue = L10n.shared["settings.general"]
        alwaysOnTopLabel.stringValue = L10n.shared["settings.general.always_on_top"]
        showMenuBarIconLabel.stringValue = L10n.shared["settings.general.show_menu_bar_icon"]
        launchAtLoginLabel.stringValue = L10n.shared["settings.general.launch_at_startup"]
        resetPositionButton.title = L10n.shared["settings.general.reset_position"]

        languageControl.setLabel(L10n.shared["menu.language.auto"], forSegment: 0)
        languageControl.setLabel(L10n.shared["menu.language.zh"], forSegment: 1)
        languageControl.setLabel(L10n.shared["menu.language.en"], forSegment: 2)
    }

    private func syncChips() {
        let onlyOne = settings.enabledAgents.count == 1
        for agent in AgentKind.allCases {
            guard let chip = chipButtons[agent] else { continue }
            let enabled = settings.isAgentEnabled(agent)
            chip.setSelected(enabled, isLastEnabled: onlyOne && enabled)
        }
        chipsContainer.invalidateIntrinsicContentSize()
        chipsContainer.needsLayout = true
    }

    private func syncLanguageSegment() {
        switch settings.language {
        case "zh":
            languageControl.selectedSegment = 1
        case "en":
            languageControl.selectedSegment = 2
        default:
            languageControl.selectedSegment = 0
        }
    }

    private static func versionFooterText() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? ""
        if version.isEmpty {
            return L10n.shared.format("settings.about.version", "").trimmingCharacters(in: .whitespaces)
        }
        return L10n.shared.format("settings.about.version", version)
    }

    // MARK: - Actions

    private func toggleAgent(_ agent: AgentKind) {
        let wasEnabled = settings.isAgentEnabled(agent)
        settings.setAgent(agent, enabled: !wasEnabled)
        let nowEnabled = settings.isAgentEnabled(agent)
        if nowEnabled == wasEnabled {
            // Last enabled agent: setAgent no-op — do not fire callback.
            syncChips()
            return
        }
        syncChips()
        emitSettingsChanged()
    }

    private func emitSettingsChanged() {
        onSettingsChanged?(settings)
    }

    @objc private func haloSizeChanged(_ sender: NSSlider) {
        guard !isApplyingUI else { return }
        let clamped = HaloSettings.clampedHaloSize(sender.doubleValue)
        settings.haloSize = clamped
        haloSizeValueLabel.stringValue = "\(Int(clamped.rounded()))"
        emitSettingsChanged()
    }

    @objc private func languageChanged(_ sender: NSSegmentedControl) {
        guard !isApplyingUI else { return }
        switch sender.selectedSegment {
        case 1:
            settings.language = "zh"
        case 2:
            settings.language = "en"
        default:
            settings.language = nil
        }
        emitSettingsChanged()
    }

    @objc private func alwaysOnTopChanged(_ sender: NSSwitch) {
        guard !isApplyingUI else { return }
        settings.alwaysOnTop = sender.state == .on
        emitSettingsChanged()
    }

    @objc private func showMenuBarIconChanged(_ sender: NSSwitch) {
        guard !isApplyingUI else { return }
        settings.showMenuBarIcon = sender.state == .on
        emitSettingsChanged()
    }

    @objc private func launchAtLoginChanged(_ sender: NSSwitch) {
        guard !isApplyingUI else { return }
        onLaunchAtLoginChanged?(sender.state == .on)
    }

    @objc private func resetPositionClicked(_ sender: Any?) {
        onResetPosition?()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }
}

// MARK: - Panel

private final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Agent chip

@MainActor
private final class SettingsAgentChip: NSView {
    let agent: AgentKind
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var selected = false
    private var isLastEnabled = false

    var onTap: (() -> Void)?

    init(agent: AgentKind) {
        self.agent = agent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        let assetName: String
        switch agent {
        case .codex: assetName = "codex"
        case .claudeCode: assetName = "claude-code"
        case .grok: assetName = "grok"
        case .pi: assetName = "pi"
        case .antigravity: assetName = "antigravity"
        }
        iconView.image = AgentIconAssets.image(named: assetName)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = agent.menuTitle
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        applyAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = titleLabel.intrinsicContentSize.width
        return NSSize(width: 10 + 14 + 6 + titleWidth + 10, height: 28)
    }

    func setSelected(_ selected: Bool, isLastEnabled: Bool) {
        self.selected = selected
        self.isLastEnabled = isLastEnabled
        applyAppearance()
    }

    private func applyAppearance() {
        if selected {
            layer?.backgroundColor = NSColor(
                calibratedRed: 0.88,
                green: 0.97,
                blue: 1.0,
                alpha: 1.0
            ).cgColor
            layer?.borderColor = NSColor(
                calibratedRed: 0.72,
                green: 0.92,
                blue: 0.97,
                alpha: 0.85
            ).cgColor
            titleLabel.textColor = .labelColor
            alphaValue = isLastEnabled ? 0.85 : 1.0
        } else {
            layer?.backgroundColor = NSColor(
                calibratedRed: 0.96,
                green: 0.96,
                blue: 0.96,
                alpha: 0.85
            ).cgColor
            layer?.borderColor = NSColor(
                calibratedRed: 0.88,
                green: 0.88,
                blue: 0.88,
                alpha: 0.7
            ).cgColor
            titleLabel.textColor = .secondaryLabelColor
            alphaValue = 1.0
        }
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }
}

// MARK: - Wrapping chip flow

@MainActor
private final class SettingsChipFlowView: NSView {
    var onChipTapped: ((AgentKind) -> Void)?
    private var chips: [SettingsAgentChip] = []
    private let chipSpacing: CGFloat = 8
    private let lineSpacing: CGFloat = 8

    func addChip(_ chip: SettingsAgentChip) {
        chip.onTap = { [weak self, weak chip] in
            guard let agent = chip?.agent else { return }
            self?.onChipTapped?(agent)
        }
        chips.append(chip)
        addSubview(chip)
    }

    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 0 ? bounds.width : 360
        let height = layoutHeight(forWidth: width)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        _ = layoutChips(width: bounds.width)
    }

    private func layoutHeight(forWidth width: CGFloat) -> CGFloat {
        layoutChips(width: width, apply: false)
    }

    @discardableResult
    private func layoutChips(width: CGFloat, apply: Bool = true) -> CGFloat {
        guard width > 0 else { return 28 }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxY: CGFloat = 0

        for chip in chips {
            let size = chip.intrinsicContentSize
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            if apply {
                // AppKit origin is bottom-left; we'll flip after measuring.
                chip.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            }
            x += size.width + chipSpacing
            rowHeight = max(rowHeight, size.height)
            maxY = max(maxY, y + rowHeight)
        }

        if apply {
            // Flip to top-down within this view.
            let totalHeight = maxY
            for chip in chips {
                var frame = chip.frame
                frame.origin.y = totalHeight - frame.origin.y - frame.height
                chip.frame = frame
            }
        }
        return max(maxY, 28)
    }
}
