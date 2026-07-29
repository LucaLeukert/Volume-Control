// Copyright © 2026 Luca Leukert.
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Combine
import SwiftUI

@main
struct VolumeControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class VolumeStepMenuView: NSView {
    private let valueLabel = NSTextField(labelWithString: "")
    let slider: NSSlider

    override var intrinsicContentSize: NSSize {
        NSSize(width: 224, height: 62)
    }

    init(value: Int, target: AnyObject, action: Selector) {
        slider = NSSlider(
            value: Double(value),
            minValue: 1,
            maxValue: 5,
            target: target,
            action: action
        )
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 224, height: 62)))

        let titleLabel = NSTextField(labelWithString: "Volume step size")
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        valueLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        slider.numberOfTickMarks = 5
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true

        for view in [titleLabel, valueLabel, slider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])

        setValue(value)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setValue(_ value: Int) {
        slider.integerValue = value
        valueLabel.stringValue = Self.label(for: value)
    }

    private static func label(for value: Int) -> String {
        switch value {
        case 1: "1.5%"
        case 2: "3%"
        case 3: "6%"
        case 4: "12%"
        case 5: "25%"
        default: "3%"
        }
    }
}

private final class PlayerVolumeRangeView: NSView {
    private let preference: String
    private let valueLabel = NSTextField(labelWithString: "")
    private let minimumSlider: NSSlider
    private let maximumSlider: NSSlider
    private let onChange: (String) -> Void

    override var intrinsicContentSize: NSSize {
        NSSize(width: 244, height: 104)
    }

    init(preference: String, onChange: @escaping (String) -> Void) {
        self.preference = preference
        self.onChange = onChange
        let defaults = UserDefaults.standard
        minimumSlider = NSSlider(
            value: defaults.double(forKey: "\(preference).minimumVolume"),
            minValue: 0, maxValue: 100, target: nil, action: nil
        )
        maximumSlider = NSSlider(
            value: defaults.double(forKey: "\(preference).maximumVolume"),
            minValue: 0, maxValue: 100, target: nil, action: nil
        )
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 244, height: 104)))

        let title = NSTextField(labelWithString: "Allowed volume range")
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        valueLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular
        )
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        configure(minimumSlider, action: #selector(minimumChanged(_:)))
        configure(maximumSlider, action: #selector(maximumChanged(_:)))

        let minimumLabel = NSTextField(labelWithString: "Min")
        let maximumLabel = NSTextField(labelWithString: "Max")
        for view in [title, valueLabel, minimumLabel, maximumLabel,
                     minimumSlider, maximumSlider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            minimumLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            minimumLabel.widthAnchor.constraint(equalToConstant: 28),
            minimumSlider.leadingAnchor.constraint(equalTo: minimumLabel.trailingAnchor, constant: 4),
            minimumSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            minimumSlider.centerYAnchor.constraint(equalTo: minimumLabel.centerYAnchor),
            minimumSlider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),

            maximumLabel.leadingAnchor.constraint(equalTo: minimumLabel.leadingAnchor),
            maximumLabel.widthAnchor.constraint(equalTo: minimumLabel.widthAnchor),
            maximumSlider.leadingAnchor.constraint(equalTo: minimumSlider.leadingAnchor),
            maximumSlider.trailingAnchor.constraint(equalTo: minimumSlider.trailingAnchor),
            maximumSlider.centerYAnchor.constraint(equalTo: maximumLabel.centerYAnchor),
            maximumSlider.topAnchor.constraint(equalTo: minimumSlider.bottomAnchor, constant: 3)
        ])
        refreshLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure(_ slider: NSSlider, action: Selector) {
        slider.target = self
        slider.action = action
        slider.numberOfTickMarks = 21
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
    }

    @objc private func minimumChanged(_ sender: NSSlider) {
        let value = min(sender.integerValue, maximumSlider.integerValue)
        sender.integerValue = value
        persist(minimum: value, maximum: maximumSlider.integerValue)
    }

    @objc private func maximumChanged(_ sender: NSSlider) {
        let value = max(sender.integerValue, minimumSlider.integerValue)
        sender.integerValue = value
        persist(minimum: minimumSlider.integerValue, maximum: value)
    }

    private func persist(minimum: Int, maximum: Int) {
        let defaults = UserDefaults.standard
        defaults.set(minimum, forKey: "\(preference).minimumVolume")
        defaults.set(maximum, forKey: "\(preference).maximumVolume")
        refreshLabel()
        onChange(preference)
    }

    private func refreshLabel() {
        valueLabel.stringValue =
            "\(minimumSlider.integerValue)% – \(maximumSlider.integerValue)%"
    }
}

@MainActor
@objc(MenuBarStatusController)
final class MenuBarStatusController: NSObject, NSMenuDelegate {
    @objc static let shared = MenuBarStatusController()

    private struct PlayerDefinition {
        let title: String
        let bundleIdentifier: String
        let preference: String
    }

    private let players = [
        PlayerDefinition(title: "Music", bundleIdentifier: "com.apple.Music", preference: "iTunesControl"),
        PlayerDefinition(title: "Spotify", bundleIdentifier: "com.spotify.client", preference: "spotifyControl"),
        PlayerDefinition(title: "Doppler", bundleIdentifier: "co.brushedtype.doppler-macos", preference: "dopplerControl"),
        PlayerDefinition(title: "Swinsian", bundleIdentifier: "com.swinsian.Swinsian", preference: "swinsianControl")
    ]
    private weak var delegate: AppDelegate?
    private var statusItem: NSStatusItem?
    private weak var playersMenuItem: NSMenuItem?
    private weak var volumeStepMenuView: VolumeStepMenuView?
    private let imageView = PassthroughImageView(frame: .zero)
    private var cancellables = Set<AnyCancellable>()
    private var displayedSymbol: String?
    private var volumeSymbol = "speaker.wave.2.fill"

    @objc(installWithDelegate:)
    func install(delegate: AppDelegate) {
        guard statusItem == nil else { return }
        self.delegate = delegate

        // squareLength is a fixed allocation owned by AppKit. Image changes
        // cannot resize this item or move neighboring menu-bar items.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.image = nil
            button.toolTip = "Volume Control"

            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            // Speaker symbols share their body on the leading edge while their
            // wave variants grow toward the trailing edge. Leading alignment
            // keeps that common body stationary across replacement animations.
            imageView.imageAlignment = .alignLeft
            imageView.contentTintColor = .labelColor
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: 14,
                weight: .regular
            )
            button.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 20),
                imageView.heightAnchor.constraint(equalToConstant: 18)
            ])
        }

        item.menu = makeMenu()
        refreshInstalledPlayers()
        observeVolumeIcon()
    }

    private func observeVolumeIcon() {
        VolumeStatusAnimator.shared.$symbolName
            .receive(on: RunLoop.main)
            .sink { [weak self] symbolName in
                self?.volumeSymbol = symbolName
                self?.refreshEnabledState()
            }
            .store(in: &cancellables)
    }

    @objc func refreshEnabledState() {
        setSymbol(delegate?.tapping == false ? "xmark" : volumeSymbol)
    }

    private func setSymbol(_ symbolName: String) {
        guard displayedSymbol != symbolName else { return }
        guard let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Volume Control"
        ) else { return }
        image.isTemplate = true
        imageView.imageAlignment = symbolName == "xmark" ? .alignCenter : .alignLeft

        if displayedSymbol == nil {
            imageView.image = image
        } else {
            imageView.setSymbolImage(image, contentTransition: .replace)
        }

        displayedSymbol = symbolName
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(actionItem("Volume Control Enabled", symbol: "speaker.wave.2", action: #selector(toggleEnabled)))
        menu.addItem(.separator())

        let players = actionItem("Controlled Players", symbol: "music.note.list", action: nil)
        playersMenuItem = players
        menu.addItem(players)

        let volumeStep = actionItem("Volume Step", symbol: "speaker.plus", action: nil)
        volumeStep.submenu = makeVolumeStepMenu()
        menu.addItem(volumeStep)
        menu.addItem(.separator())

        menu.addItem(actionItem("Invert Behavior", symbol: "command", action: #selector(toggleCommandBehavior)))
        menu.addItem(actionItem("Lock System and Player Volume", symbol: "link", action: #selector(toggleVolumeLock)))
        menu.addItem(actionItem("Start at Login", symbol: "power", action: #selector(toggleStartAtLogin)))
        menu.addItem(.separator())

        let application = actionItem("Application", symbol: "gearshape", action: nil)
        let applicationMenu = NSMenu()
        applicationMenu.addItem(actionItem("Copy Diagnostics…", symbol: "doc.on.doc", action: #selector(copyDiagnostics)))
        applicationMenu.addItem(actionItem("About Volume Control", symbol: "info.circle", action: #selector(showAbout)))
        application.submenu = applicationMenu
        menu.addItem(application)
        menu.addItem(.separator())

        let quit = actionItem("Quit Volume Control", symbol: "power", action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        return menu
    }

    private func makePlayersMenu(installedPlayers: [(PlayerDefinition, URL)]) -> NSMenu {
        let menu = NSMenu()
        for (player, applicationURL) in installedPlayers {
            menu.addItem(playerItem(player, applicationURL: applicationURL))
        }
        return menu
    }

    private func refreshInstalledPlayers() {
        let installedPlayers = players.compactMap { player -> (PlayerDefinition, URL)? in
            guard let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: player.bundleIdentifier
            ) else {
                return nil
            }
            enableDiscoveredPlayerByDefaultIfNeeded(player.preference)
            return (player, applicationURL)
        }
        playersMenuItem?.submenu = makePlayersMenu(installedPlayers: installedPlayers)
    }

    private func enableDiscoveredPlayerByDefaultIfNeeded(_ preference: String) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let persistedPreferences = UserDefaults.standard.persistentDomain(forName: bundleIdentifier) ?? [:]
        guard persistedPreferences[preference] == nil else { return }
        UserDefaults.standard.set(true, forKey: preference)
    }

    private func makeVolumeStepMenu() -> NSMenu {
        let menu = NSMenu()
        let currentValue = max(1, min(UserDefaults.standard.integer(forKey: "volumeIncrement"), 5))
        let view = VolumeStepMenuView(
            value: currentValue,
            target: self,
            action: #selector(selectVolumeIncrementFromSlider(_:))
        )
        volumeStepMenuView = view

        let item = NSMenuItem()
        item.view = view
        menu.addItem(item)
        return menu
    }

    private func actionItem(_ title: String, symbol: String, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func playerItem(_ player: PlayerDefinition, applicationURL: URL) -> NSMenuItem {
        let item = NSMenuItem(title: player.title, action: nil, keyEquivalent: "")
        let image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        image.size = NSSize(width: 14, height: 14)
        item.image = image

        let submenu = NSMenu()
        let enabled = actionItem("Enabled", symbol: "checkmark.circle", action: #selector(togglePlayer(_:)))
        enabled.representedObject = player.preference
        submenu.addItem(enabled)
        submenu.addItem(.separator())

        let rangeItem = NSMenuItem()
        rangeItem.view = PlayerVolumeRangeView(preference: player.preference) { [weak self] preference in
            self?.delegate?.applyVolumeLimit(forPreference: preference)
        }
        submenu.addItem(rangeItem)
        item.submenu = submenu
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshInstalledPlayers()
        let currentVolumeStep = max(
            1,
            min(UserDefaults.standard.integer(forKey: "volumeIncrement"), 5)
        )
        volumeStepMenuView?.setValue(currentVolumeStep)
        refreshMenuState(menu)
    }

    private func refreshMenuState(_ menu: NSMenu) {
        guard let delegate else { return }
        for item in menu.items {
            switch item.action {
            case #selector(toggleEnabled):
                item.state = delegate.tapping ? .on : .off
                item.image = NSImage(
                    systemSymbolName: delegate.tapping ? "speaker.wave.2" : "xmark",
                    accessibilityDescription: nil
                )
            case #selector(toggleCommandBehavior):
                item.state = delegate.useAppleCMDModifier ? .on : .off
            case #selector(toggleVolumeLock):
                item.state = delegate.lockSystemAndPlayerVolume ? .on : .off
            case #selector(toggleStartAtLogin):
                item.state = delegate.startAtLogin ? .on : .off
            case #selector(togglePlayer(_:)):
                if let key = item.representedObject as? String {
                    item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
                }
            default:
                break
            }
            if let submenu = item.submenu {
                refreshMenuState(submenu)
            }
        }
    }

    @objc private func toggleEnabled() {
        delegate?.toggleTapping(nil)
        refreshEnabledState()
    }
    @objc private func toggleCommandBehavior() { delegate?.toggleUseAppleCMDModifier(nil) }
    @objc private func toggleVolumeLock() { delegate?.toggleLockSystemAndPlayerVolume(nil) }
    @objc private func toggleStartAtLogin() { delegate?.toggleStartAtLogin(nil) }
    @objc private func copyDiagnostics() { delegate?.copyDiagnostics(nil) }
    @objc private func showAbout() {
        // Let AppKit finish dismissing the tracked status menu before creating
        // the About panel. Presenting a window during menu tracking can
        // interrupt Tahoe's remote theme-widget service.
        guard let delegate else { return }
        DispatchQueue.main.async {
            delegate.aboutPanel(nil)
        }
    }
    @objc private func quit() { delegate?.terminate(nil) }

    @objc private func togglePlayer(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    @objc private func selectVolumeIncrementFromSlider(_ sender: NSSlider) {
        let value = sender.integerValue
        volumeStepMenuView?.setValue(value)
        UserDefaults.standard.set(value, forKey: "volumeIncrement")
        delegate?.updateVolumeIncrement(value)
    }
}
