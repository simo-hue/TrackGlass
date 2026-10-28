import SwiftUI
import UIKit

@MainActor @Observable
final class SurfaceRecordingState { var isRecording = false }

struct SettingsSheet: View {
    @Bindable var themes: ThemeStore
    @Bindable var connection: ConnectionState
    let manager: ConnectionManager
    let connect: (DiscoveredMac) -> Void
    let openMacs: () -> Void
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
    private var website: URL? { (Bundle.main.object(forInfoDictionaryKey: "TGWebsiteURL") as? String).flatMap(URL.init(string:)) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    MacsListView(state: connection, manager: manager, connect: connect, pair: openMacs)
                }
                Section("Appearance") {
                    Picker("Theme", selection: Binding(get: { themes.theme.id }, set: { themes.select(id: $0) })) {
                        ForEach(Theme.ID.allCases, id: \.self) { id in Text(Theme.preset(id).name).tag(id) }
                    }
                    ColorPicker("Accent", selection: colorBinding(background: false), supportsOpacity: false)
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
                    Toggle("Haptics", isOn: $hapticsEnabled)
                    Slider(value: $hapticsStrength, in: 0.5...1) { Text("Haptic strength") }.disabled(!hapticsEnabled)
                    LabeledContent("Tracking offset", value: String(format: "%+.2f", trackingOverride))
                    Slider(value: $trackingOverride, in: -1...1, step: 0.05) { Text("Tracking speed relative to your Mac") }
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
                    if let website {
                        Link("Privacy Policy", destination: website.appendingPathComponent("privacy.html"))
                        Link("Download the Mac app", destination: website.appendingPathComponent("support.html"))
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $share) { ActivitySheet(url: $0.url) }
            .alert("Recording unavailable", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func colorBinding(background: Bool) -> Binding<Color> {
        Binding(get: { Color(uiColor: Theme.color(background ? themes.theme.backgroundRGB : themes.theme.accentRGB)) }, set: { color in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            // Extended-sRGB components (P3 picks) can be < 0 or > 1; clamp before converting or UInt32() traps.
            func channel(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
            let rgb = channel(red) << 16 | channel(green) << 8 | channel(blue)
            var value = themes.theme
            if background { value.backgroundRGB = rgb } else { value.accentRGB = rgb }
            themes.select(value)
        })
    }
}
private struct RecordingShare: Identifiable { let id = UUID(); let url: URL }
private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct GripButton: View {
    let open: () -> Void
    var body: some View {
        Button(action: open) { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
            .background(.ultraThinMaterial, in: Circle())
            .accessibilityLabel("Open settings")
    }
}
