import SwiftUI

@main
struct TrackglassMacApp: App {
    var body: some Scene {
        MenuBarExtra {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Text(Bundle.main.object(forInfoDictionaryKey: "TGProductName") as? String ?? "")
        }
    }
}
