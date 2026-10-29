import SwiftUI
import UIKit

@MainActor @Observable
final class SurfaceRecordingState { var isRecording = false }

struct SettingsSheet: View {
    @Bindable var themes: ThemeStore
    @Bindable var connection: ConnectionState
    let manager: ConnectionManager
    let connect: (DiscoveredMac) -> Void
    /// Opens the pairing flow (over the Macs sheet).
    let openPairing: () -> Void
    let startRecording: () async throws -> Void
    let finishRecording: () async throws -> URL
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("hapticsStrength") private var hapticsStrength = 1.0
    @AppStorage("trackingOverride") private var trackingOverride = 0.0
    @AppStorage("showsHUD") private var showsHUD = true
    @AppStorage("showsLatencyOverlay") private var showsLatencyOverlay = false
    @AppStorage("coalescedSamples") private var coalescedSamples = false
    @Bindable var recordingState: SurfaceRecordingState
    @State private var busy = false
    @State private var share: RecordingShare?
    @State private var error: String?
    @State private var discoveryViewer = UUID()
    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    MacsListView(state: connection, manager: manager, connect: connect, pair: openPairing)
                }
                Section("Appearance") {
                    Picker("Theme", selection: Binding(get: { themes.theme.id }, set: { themes.select(id: $0) })) {
                        ForEach(Theme.ID.allCases, id: \.self) { id in Text(Theme.preset(id).name).tag(id) }
                    }
                    // The accent tints the finger glow and the dot grid; with neither it would change nothing.
                    if themes.theme.fingerGlow == .accent || themes.theme.showsGrid {
                        ColorPicker("Accent", selection: colorBinding(background: false), supportsOpacity: false)
                    }
                    if themes.theme.id == .custom {
                        ColorPicker("Background", selection: colorBinding(background: true), supportsOpacity: false)
                    }
                    Toggle("Finger glow", isOn: Binding(get: { themes.theme.fingerGlow != .none }, set: { enabled in
                        var value = themes.theme
                        value.fingerGlow = enabled ? (value.background == .aluminum ? .dark : .accent) : .none
                        themes.select(value)
                    }))
                    if themes.theme.id == .custom {
                        Toggle("Dot grid", isOn: Binding(get: { themes.theme.showsGrid }, set: { enabled in
                            var value = themes.theme; value.showsGrid = enabled; themes.select(value)
                        }))
                    }
                    Toggle("Show connection status", isOn: $showsHUD)
                }
                Section("Feel") {
                    // Without a Taptic Engine (most iPads) the phone never asks the Mac for haptics (HELLO caps bit 0).
                    if HapticEngine.supportsHaptics {
                        Toggle("Haptics", isOn: $hapticsEnabled)
                        Slider(value: $hapticsStrength, in: 0.5...1) { Text("Haptic strength") }.disabled(!hapticsEnabled)
                            .accessibilityValue(Self.strengthDescription(hapticsStrength))
                    }
                    LabeledContent("Tracking offset", value: String(format: "%+.2f", trackingOverride))
                    Slider(value: $trackingOverride, in: -1...1, step: 0.05) { Text("Tracking speed relative to your Mac") }
                        .accessibilityValue(Self.trackingDescription(trackingOverride))
                        .onChange(of: trackingOverride) { _, value in Task { await manager.setTrackingOverride(Float(value)) } }
                    Button("Use Mac tracking speed") { trackingOverride = 0 }
                    Text("Zero follows your Mac’s tracking speed.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    Toggle("Latency overlay", isOn: $showsLatencyOverlay)
                    Toggle("Coalesced touch samples", isOn: $coalescedSamples)
                    Text("Experimental: sends every digitizer sample when the touch rate exceeds the display rate. Takes effect on the next connection.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(recordingState.isRecording ? "Stop and share recording" : "Record session") {
                        busy = true
                        Task {
                            do {
                                if recordingState.isRecording { share = RecordingShare(url: try await finishRecording()); recordingState.isRecording = false }
                                else { try await startRecording(); recordingState.isRecording = true }
                            } catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }.disabled(busy)
                    if recordingState.isRecording { Text("Recording touch input on this device.").foregroundStyle(.secondary) }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Text("Trackglass never leaves your network")
                    if let privacyPolicy = AppLinks.privacyPolicy { Link("Privacy Policy", destination: privacyPolicy) }
                    // §1.5 / §5.1: the Mac download page is the newest GitHub release; the support page explains setup.
                    if let download = AppLinks.macDownload { Link("Download the Mac app", destination: download) }
                    if let support = AppLinks.support { Link("Setup help and support", destination: support) }
                }
            }
            .navigationTitle("Settings")
            // Availability is only known while browsing, which pauses during a session unless a list is shown. On the
            // whole sheet, not the section: a lazily loaded row scrolled out of view would stop it mid-sheet.
            .onAppear { Task { await manager.setDiscoveryVisible(true, viewer: discoveryViewer) } }
            .onDisappear { Task { await manager.setDiscoveryVisible(false, viewer: discoveryViewer) } }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $share) { ActivitySheet(url: $0.url) }
            .alert("Recording unavailable", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    nonisolated static func strengthDescription(_ value: Double) -> String { "\(Int((value * 100).rounded())) percent" }

    nonisolated static func trackingDescription(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == 0 { return "Same as your Mac" }
        return String(format: rounded > 0 ? "%.2f faster than your Mac" : "%.2f slower than your Mac", abs(rounded))
    }

    private func colorBinding(background: Bool) -> Binding<Color> {
        Binding(get: { Color(uiColor: Theme.color(background ? themes.theme.backgroundRGB : themes.theme.accentRGB)) }, set: { color in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            // Extended-sRGB components (P3 picks) can be < 0 or > 1; clamp before converting or UInt32() traps.
            func channel(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
            let rgb = channel(red) << 16 | channel(green) << 8 | channel(blue)
            themes.select(Self.edited(themes.theme, rgb: rgb, background: background))
        })
    }
}
extension SettingsSheet {
    /// A colour edit never changes a built-in theme in place (it would still be listed under the preset's name, and
    /// re-selecting the preset would silently undo it): the edited copy becomes the Custom theme.
    nonisolated static func edited(_ theme: Theme, rgb: UInt32, background: Bool) -> Theme {
        var value = theme
        value.id = .custom
        if background {
            value.backgroundRGB = rgb
            value.background = .solid   // the aluminum finish ignores the colour; a picked colour must show
        } else {
            value.accentRGB = rgb
        }
        return value
    }
}
private struct RecordingShare: Identifiable { let id = UUID(); let url: URL }
private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct GripButton: View {
    let themes: ThemeStore
    let open: () -> Void
    var body: some View {
        // `gripStyle` .dark (light surfaces: Glass White, Aluminum) draws a dark glyph on light material.
        let scheme: ColorScheme = themes.theme.gripStyle == .dark ? .light : .dark
        Button(action: open) { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
            .foregroundStyle(.primary)
            .background(.ultraThinMaterial, in: Circle())
            .environment(\.colorScheme, scheme)
            .accessibilityLabel("Open settings")
    }
}
