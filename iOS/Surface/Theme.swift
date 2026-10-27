import Observation
import SwiftUI
import UIKit

enum ThemeBackground: String, Codable { case solid, aluminum }
enum FingerGlowStyle: String, Codable { case accent, dark, none }
enum GripStyle: String, Codable { case light, dark }
struct Theme: Codable, Equatable, Identifiable {
    enum ID: String, Codable, CaseIterable { case glassBlack, glassWhite, aluminum, midnightGrid, custom }
    var id: ID
    var background: ThemeBackground = .solid
    var backgroundRGB: UInt32
    var accentRGB: UInt32
    var fingerGlow: FingerGlowStyle = .accent
    var glowOpacity: Float = 0.35
    var showsGrid = false
    var gripStyle: GripStyle = .light
    var name: String {
        switch id {
        case .glassBlack: "Glass Black"
        case .glassWhite: "Glass White"
        case .aluminum: "Aluminum"
        case .midnightGrid: "Midnight Grid"
        case .custom: "Custom"
        }
    }
    var accent: Color { Color(uiColor: Self.color(accentRGB)) }
    static func color(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    static func preset(_ id: ID) -> Theme {
        switch id {
        case .glassBlack: Theme(id: id, backgroundRGB: 0, accentRGB: 0x8E8E93)
        case .glassWhite: Theme(id: id, backgroundRGB: 0xF2F2F7, accentRGB: 0x636366, glowOpacity: 0.25, gripStyle: .dark)
        case .aluminum: Theme(id: id, background: .aluminum, backgroundRGB: 0xD9D9DE, accentRGB: 0x636366,
                              fingerGlow: .dark, glowOpacity: 0.12, gripStyle: .dark)
        case .midnightGrid: Theme(id: id, backgroundRGB: 0, accentRGB: 0x8E8E93, showsGrid: true)
        case .custom: Theme(id: id, backgroundRGB: 0, accentRGB: 0x8E8E93)
        }
    }
}

@MainActor @Observable
final class ThemeStore {
    private let defaults: UserDefaults
    private(set) var theme: Theme
    var onChange: ((Theme) -> Void)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.data(forKey: "surfaceTheme").flatMap { try? JSONDecoder().decode(Theme.self, from: $0) } ?? .preset(.glassBlack)
    }
    func select(_ theme: Theme) {
        self.theme = theme
        if let data = try? JSONEncoder().encode(theme) { defaults.set(data, forKey: "surfaceTheme") }
        onChange?(theme)
    }
}
