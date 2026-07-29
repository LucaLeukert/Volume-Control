// Copyright © 2026 Luca Leukert.
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

@MainActor
@objc(SwiftUIModalController)
public final class SwiftUIModalController: NSObject {
    @objc public static let shared = SwiftUIModalController()
    private var window: NSWindow?

    @objc public func showMessage(_ title: String, details: String) {
        present(size: NSSize(width: 430, height: 250)) {
            MessageView(title: title, details: details) { [weak self] in self?.close() }
        }
    }

    @objc public func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        present(size: NSSize(width: 390, height: 330)) {
            AboutView(version: version, build: build) { [weak self] in self?.close() }
        }
    }

    @objc public func showDiagnostics(_ report: String) {
        present(size: NSSize(width: 620, height: 520)) {
            DiagnosticsView(report: report) { [weak self] in self?.close() }
        }
    }

    private func present<Content: View>(size: NSSize, @ViewBuilder content: () -> Content) {
        window?.close()
        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.contentView = NSHostingView(rootView: content())
        panel.center()
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
        window = nil
    }
}

private struct MessageView: View {
    let title: String
    let details: String
    let close: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38)).foregroundStyle(.yellow)
            Text(title).font(.title2.bold())
            Text(details).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("OK", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct AboutView: View {
    let version: String
    let build: String
    let close: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 86, height: 86)
            Text("Volume Control").font(.title.bold())
            Text("Version \(version) (\(build))").foregroundStyle(.secondary)
            Text("Native volume-key control for Music, Spotify, Doppler, Swinsian and system audio.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("A fork by Luca Leukert")
                .foregroundStyle(.secondary)
            Link("Luca Leukert on GitHub", destination: URL(string: "https://github.com/lucaleukert")!)
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct DiagnosticsView: View {
    let report: String
    let close: () -> Void
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Diagnostics").font(.title2.bold())
            Text("Review this plain-text report before sharing it.")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(report).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Link("Luca Leukert on GitHub", destination: URL(string: "https://github.com/lucaleukert")!)
                Spacer()
                Button("Done", action: close)
                Button(copied ? "Copied" : "Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }
}
