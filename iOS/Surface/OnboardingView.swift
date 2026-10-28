import SwiftUI
import UIKit

struct OnboardingView: View {
    let finish: () -> Void
    @State private var page = 0
    private var lastPage: Int { UIDevice.current.userInterfaceIdiom == .pad ? 3 : 2 }
    /// §5.1 page 2: the Mac download URL (§1.5 `releases/latest`) as a tappable link plus a Copy button.
    private var download: URL? { AppLinks.macDownload }
    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                pageView(symbol: "hand.point.up.left", title: "Your Mac, at your fingertips",
                    detail: "Turn your iPhone or iPad into a wireless trackpad. Point, click and use familiar gestures.").tag(0)
                VStack(spacing: 24) {
                    pageView(symbol: "desktopcomputer", title: "Install Trackglass for Mac",
                        detail: "Install the companion on your Mac and allow Accessibility when prompted. Keep both devices on the same network.")
                    if let download {
                        Link("Download for Mac", destination: download)
                        Text(download.absoluteString).font(.footnote.monospaced()).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).textSelection(.enabled)
                        Button("Copy download link") { UIPasteboard.general.url = download }
                            .accessibilityHint("Copies the Mac download address so you can paste it on your Mac.")
                    }
                }.tag(1)
                pageView(symbol: "qrcode.viewfinder", title: "Pair your devices",
                    detail: "Choose Pair a device in the Mac menu, then scan its code or enter the pairing code on this device.").tag(2)
                if lastPage == 3 {
                    pageView(symbol: "hand.draw", title: "Make room for gestures",
                        detail: "For four- and five-finger Mac gestures, turn off iPad multitasking gestures in Settings → Multitasking & Gestures → Gestures. Rotate or resize Trackglass whenever you need.").tag(3)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button(page == lastPage ? "Pair a Mac" : "Continue") {
                if page == lastPage { finish() } else { withAnimation { page += 1 } }
            }.buttonStyle(.borderedProminent).padding(.bottom, 32)
        }
        .padding(24)
        .background(Color(uiColor: .systemBackground))
    }
    private func pageView(symbol: String, title: String, detail: String) -> some View {
        // Scrolls at the largest accessibility text sizes (iPhone SE) instead of clipping.
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: symbol).font(.system(size: 64)).accessibilityHidden(true)
                Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text(detail).font(.body).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }.padding()
        }
    }
}
