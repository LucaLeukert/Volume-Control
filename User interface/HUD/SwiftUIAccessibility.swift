// Copyright © 2026 Luca Leukert.
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

@MainActor
@objc(SwiftUIAccessibilityController)
public final class SwiftUIAccessibilityController: NSObject {
    @objc public static let shared = SwiftUIAccessibilityController()
    private var window: NSWindow?

    @objc public func show() {
        if window == nil {
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "Allow Volume Control"
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.contentView = NSHostingView(rootView: AccessibilityPermissionView())
            panel.center()
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc public func close() {
        window?.close()
        window = nil
    }
}

private struct AccessibilityPermissionView: View {
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 48, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
            VStack(spacing: 8) {
                Text("Allow Volume Key Access").font(.system(size: 24, weight: .bold))
                Text("Volume Control needs Accessibility permission to detect volume keys while other apps are active.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: 400)
            }
            VStack(alignment: .leading, spacing: 12) {
                instruction(1, "Open Privacy & Security settings")
                instruction(2, "Enable Volume Control under Accessibility")
                instruction(3, "Return here — the app continues automatically")
            }
            .padding(18)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            HStack {
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open Accessibility Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 520, height: 430)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)").font(.caption.bold()).frame(width: 24, height: 24)
                .background(.blue, in: Circle()).foregroundStyle(.white)
            Text(text)
        }
    }
}
