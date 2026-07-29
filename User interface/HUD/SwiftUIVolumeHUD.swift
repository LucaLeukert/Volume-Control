// Copyright © 2026 Luca Leukert.
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

private final class VolumeHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class VolumeHUDModel: ObservableObject {
    @Published var volume = 0.5
    @Published var isMuted = false
    @Published var deviceName = ""
    @Published var playerIcon: NSImage?
}

@MainActor
@objc(TahoeVolumeHUD)
final class SwiftUIVolumeHUD: NSObject {
    @objc static let sharedManager = SwiftUIVolumeHUD()
    @objc weak var delegate: AnyObject?

    private static let hudSize = NSSize(width: 292, height: 64)
    private static let screenMargin = NSSize(width: 18, height: 14)

    private let model = VolumeHUDModel()
    private let panel: VolumeHUDPanel
    private var hideWorkItem: DispatchWorkItem?
    private var presentationID = 0

    private override init() {
        let frame = NSRect(origin: .zero, size: Self.hudSize)
        let content = VolumeHUDContent(model: model)
        let hostingView = TransparentHostingView(rootView: content)
        hostingView.frame = frame
        hostingView.autoresizingMask = [.width, .height]

        let glassView = NSGlassEffectView(frame: frame)
        glassView.autoresizingMask = [.width, .height]
        glassView.style = .regular
        glassView.cornerRadius = 24
        glassView.tintColor = nil
        glassView.contentView = hostingView

        panel = VolumeHUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = glassView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        super.init()
    }

    @objc(showHUDWithVolume:usingMusicPlayer:andLabel:)
    func show(volume: Double, player: AnyObject, label: String) {
        presentationID += 1
        let currentPresentation = presentationID

        if let player = player as? PlayerApplication {
            model.deviceName = playerDisplayName(bundleIdentifier: player.bundleIdentifier)
            model.playerIcon = player.icon
        } else {
            model.deviceName = label
            model.playerIcon = (player as? NSObject)?.value(forKey: "icon") as? NSImage
        }
        setVolume(volume)
        VolumeStatusAnimator.shared.update(
            volume: min(max(volume / 100, 0), 1),
            isPreferredSource: player is PlayerApplication
        )
        positionAtTopRight()

        hideWorkItem?.cancel()

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }

        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.14
            $0.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            guard self?.presentationID == currentPresentation else { return }
            self?.hide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    @objc func setVolume(_ volume: Double) {
        let normalized = min(max(volume / 100, 0), 1)
        withAnimation(.smooth(duration: 0.22)) {
            model.volume = normalized
            model.isMuted = normalized <= 0.001
        }
    }

    /// Seeds the menu-bar icon without presenting the HUD.
    @objc(setMenuBarVolume:usingMusicPlayer:)
    func setMenuBarVolume(_ volume: Double, player: AnyObject) {
        VolumeStatusAnimator.shared.update(
            volume: min(max(volume / 100, 0), 1),
            isPreferredSource: player is PlayerApplication,
            temporarily: false
        )
    }

    @objc func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        presentationID += 1
        let currentPresentation = presentationID

        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.22
            $0.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.presentationID == currentPresentation else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func positionAtTopRight() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.maxX - Self.hudSize.width - Self.screenMargin.width,
                y: visibleFrame.maxY - Self.hudSize.height - Self.screenMargin.height
            )
        )
    }

    private func playerDisplayName(bundleIdentifier: String) -> String {
        if let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            let values = try? applicationURL.resourceValues(forKeys: [.localizedNameKey])
            if let localizedName = values?.localizedName {
                return localizedName.replacingOccurrences(of: ".app", with: "")
            }
        }

        return switch bundleIdentifier {
        case "com.apple.Music": "Music"
        case "com.spotify.client": "Spotify"
        case "co.brushedtype.doppler-macos": "Doppler"
        case "com.swinsian.Swinsian": "Swinsian"
        default: "Music Player"
        }
    }

}

private struct VolumeHUDContent: View {
    @ObservedObject var model: VolumeHUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let playerIcon = model.playerIcon {
                    Image(nsImage: playerIcon)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .transition(.scale(scale: 0.75).combined(with: .opacity))
                }

                Text(model.deviceName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }

            HStack(spacing: 7) {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.smooth(duration: 0.2), value: model.isMuted)
                    .frame(width: 13)

                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        Capsule()
                            .fill(.white.opacity(0.28))
                            .frame(height: 4)

                        Capsule()
                            .fill(.white)
                            .frame(
                                width: max(4, proxy.size.width * model.volume),
                                height: 4
                            )
                            .animation(.smooth(duration: 0.22), value: model.volume)

                        HStack(spacing: 0) {
                            ForEach(0..<17, id: \.self) { index in
                                Circle()
                                    .fill(.white.opacity(0.18))
                                    .frame(width: 1, height: 1)
                                if index != 16 {
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .offset(y: 7)
                    }
                }
                .frame(height: 9)

                Image(systemName: volumeLevelSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.smooth(duration: 0.2), value: volumeLevelSymbol)
                    .frame(width: 15)
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .frame(width: 292, height: 64)
        .background(Color.clear)
    }

    private var volumeLevelSymbol: String {
        if model.volume <= 1.0 / 3.0 {
            "speaker.wave.1.fill"
        } else if model.volume <= 2.0 / 3.0 {
            "speaker.wave.2.fill"
        } else {
            "speaker.wave.3.fill"
        }
    }
}

@MainActor
final class VolumeStatusAnimator: ObservableObject {
    static let shared = VolumeStatusAnimator()

    @Published private(set) var symbolName = "speaker.wave.2.fill"

    private var preferredVolume: Double?
    private var restoreTask: Task<Void, Never>?
    private var isShowingTemporarySource = false

    func update(volume: Double, isPreferredSource: Bool = true, temporarily: Bool = true) {
        let normalized = min(max(volume, 0), 1)

        if isPreferredSource {
            preferredVolume = normalized
            // A background relevance refresh only updates the cached resting
            // value. An actual player-volume change takes over immediately.
            if isShowingTemporarySource && !temporarily { return }
            isShowingTemporarySource = false
        } else if !temporarily {
            preferredVolume = nil
            isShowingTemporarySource = false
        }

        restoreTask?.cancel()
        display(normalized)

        guard temporarily, !isPreferredSource, preferredVolume != nil else { return }
        isShowingTemporarySource = true
        restoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            guard let self, let latestPreferredVolume = self.preferredVolume else { return }
            self.isShowingTemporarySource = false
            self.display(latestPreferredVolume)
        }
    }

    private func display(_ volume: Double) {
        let nextSymbol: String
        if volume <= 0.001 {
            nextSymbol = "speaker.slash.fill"
        } else if volume <= 1.0 / 3.0 {
            nextSymbol = "speaker.wave.1.fill"
        } else if volume <= 2.0 / 3.0 {
            nextSymbol = "speaker.wave.2.fill"
        } else {
            nextSymbol = "speaker.wave.3.fill"
        }

        guard nextSymbol != symbolName else { return }
        withAnimation(.smooth(duration: 0.24)) {
            symbolName = nextSymbol
        }
    }
}
