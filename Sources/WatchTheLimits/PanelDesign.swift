import AppKit
import Combine
import SwiftUI

/// Exported Figma tokens. The shell and switch use native macOS rendering instead.
struct PanelDesign: Decodable {
    struct Typography: Decodable {
        let name: String
        let family: String
        let weight: String
        let size: CGFloat
        let lineHeight: CGFloat

        var font: Font {
            let nativeWeight: Font.Weight = weight == "Semibold" ? .semibold : weight == "Medium" ? .medium : .regular
            return .system(size: size, weight: nativeWeight)
        }
    }

    struct Layout: Decodable {
        let width, padding, sectionSpacing, headerSpacing, headerBottom: CGFloat
        let rowSpacing, labelSpacing, valueSpacing, resetSpacing: CGFloat
        let controlHeight, controlRadius, controlPadding, buttonSpacing, disclosurePadding: CGFloat
        let progressHeight, navIconSize, refreshIconSize, spinnerSize, setupHeight: CGFloat
        let controlRowSpacing, errorPadding, counterSize, counterRadius: CGFloat
    }

    let typography: [Typography]
    let layout: Layout
    let colors: [String: [String: RGBA]]

    struct RGBA: Decodable {
        let r, g, b, a: CGFloat
    }

    static let shared: PanelDesign = {
        let url = AppResources.bundle.url(forResource: "panel-tokens", withExtension: "json", subdirectory: "Figma")!
        return try! JSONDecoder().decode(PanelDesign.self, from: Data(contentsOf: url))
    }()

    func textStyle(_ role: String) -> Typography { typography.first { $0.name == "Panel/" + role }! }

    private static let colorBundle: Bundle = {
        Bundle(url: AppResources.bundle.url(forResource: "PanelColors", withExtension: "bundle")!)!
    }()

    static func color(_ name: String) -> Color {
        Color("panel-" + name.replacingOccurrences(of: "/", with: "-"), bundle: colorBundle)
    }

    static func icon(_ name: String) -> NSImage {
        let url = AppResources.bundle.url(forResource: "panel-" + name, withExtension: "svg", subdirectory: "Figma")!
        let image = NSImage(contentsOf: url)!
        image.isTemplate = true
        return image
    }

    static func verifyResources() throws {
        for mode in ["Light", "Dark"] {
            var invalid: [String] = []
            NSAppearance(named: mode == "Dark" ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                for (name, expected) in shared.colors[mode]! {
                    guard let actual = NSColor(named: name.replacingOccurrences(of: "/", with: "-"), bundle: colorBundle)?.usingColorSpace(.sRGB) else {
                        invalid.append(name); continue
                    }
                    let pairs = [(actual.redComponent, expected.r), (actual.greenComponent, expected.g),
                                 (actual.blueComponent, expected.b), (actual.alphaComponent, expected.a)]
                    if pairs.contains(where: { abs($0.0 - $0.1) > 0.0001 }) { invalid.append(name) }
                }
            }
            if !invalid.isEmpty {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Panel colors differ from Figma in \(mode): \(invalid.joined(separator: ", "))"])
            }
        }
        guard icon("nav-arrow").size == NSSize(width: shared.layout.navIconSize, height: shared.layout.navIconSize),
              icon("refresh").size == NSSize(width: shared.layout.refreshIconSize, height: shared.layout.refreshIconSize) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Panel icon geometry differs from Figma."])
        }
    }
}

struct PanelText: View {
    let text: String
    var role = "Caption"
    private var style: PanelDesign.Typography { PanelDesign.shared.textStyle(role) }

    init(_ text: String, role: String = "Caption") { self.text = text; self.role = role }

    var body: some View {
        Text(text).font(style.font).lineLimit(1).frame(height: style.lineHeight)
    }
}

struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration, prominent: prominent) }

    private struct Chrome: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.panelPreviewHover) private var previewHover
        @StateObject private var hover = PanelHoverState()
        private let layout = PanelDesign.shared.layout

        var body: some View {
            configuration.label
                .font(PanelDesign.shared.textStyle("Button").font)
                .foregroundStyle(PanelDesign.color(enabled ? (prominent ? "foreground-on-fill" : "control/foreground") : "control/foreground-disabled"))
                .padding(.horizontal, layout.controlPadding)
                .frame(height: layout.controlHeight)
                .background(PanelDesign.color(enabled && prominent ? "control/fill-selected" : enabled && (previewHover || hover.isHovered || configuration.isPressed) ? "control/fill-hover" : "control/fill"),
                            in: RoundedRectangle(cornerRadius: layout.controlRadius))
                .contentShape(RoundedRectangle(cornerRadius: layout.controlRadius))
                .onHover { hover.isHovered = $0 }
        }
    }
}

final class PanelHoverState: ObservableObject {
    @Published var isHovered = false
}

struct PanelSelectorButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, selected: selected)
    }

    private struct Chrome: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @StateObject private var hover = PanelHoverState()
        @Environment(\.panelPreviewHover) private var previewHover

        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: PanelDesign.shared.layout.controlRadius))
                .contentShape(RoundedRectangle(cornerRadius: PanelDesign.shared.layout.controlRadius))
                .onHover { hover.isHovered = $0 }
        }

        private var fill: Color {
            if selected { return PanelDesign.color("control/fill-selected") }
            return previewHover || hover.isHovered || configuration.isPressed ? PanelDesign.color("control/fill") : .clear
        }
    }
}

/// Deterministic hover renders for design review; real interaction uses onHover.
private struct PanelPreviewHoverKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var panelPreviewHover: Bool {
        get { self[PanelPreviewHoverKey.self] }
        set { self[PanelPreviewHoverKey.self] = newValue }
    }
}
