import SwiftUI

/// Shared presentation tokens. Transport and feature state stay in their existing owners.
enum GlassStyle {
    static let background = Color(red: 0.063, green: 0.067, blue: 0.071)
    static let surface = Color(red: 0.098, green: 0.102, blue: 0.110)
    static let raised = Color(red: 0.137, green: 0.145, blue: 0.153)
    static let ink = Color(red: 0.929, green: 0.937, blue: 0.945)
    static let secondary = Color(red: 0.659, green: 0.682, blue: 0.702)
    static let muted = Color(red: 0.553, green: 0.580, blue: 0.604)
    static let accent = Color(red: 0.455, green: 0.816, blue: 0.863)
    static let positive = Color(red: 0.478, green: 0.769, blue: 0.624)
    static let warning = Color(red: 0.898, green: 0.690, blue: 0.435)
    static let line = ink.opacity(0.09)
}

struct GlassPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) { content }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 32)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }
        .background(GlassStyle.background)
        .scrollDismissesKeyboard(.interactively)
        .toolbarBackground(GlassStyle.background, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GlassPageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.weight(.medium)).foregroundStyle(GlassStyle.ink)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.subheadline).foregroundStyle(GlassStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GlassSection<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline.weight(.medium)).foregroundStyle(GlassStyle.ink)
                .accessibilityAddTraits(.isHeader)
            content
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(GlassStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct GlassPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(GlassStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(GlassStyle.line, lineWidth: 1) }
    }
}

struct GlassPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16)
            .foregroundStyle(isEnabled ? GlassStyle.background : GlassStyle.muted)
            .background(isEnabled ? GlassStyle.ink : GlassStyle.raised, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct GlassFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(minHeight: 48)
            .background(GlassStyle.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(GlassStyle.line, lineWidth: 1) }
    }
}

struct GlassStatus: View {
    let text: String
    var active = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(active ? GlassStyle.accent : GlassStyle.muted)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(text).font(.caption.monospaced()).foregroundStyle(GlassStyle.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct GlassEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light))
                .foregroundStyle(GlassStyle.muted).accessibilityHidden(true)
            Text(title).font(.title3.weight(.medium)).foregroundStyle(GlassStyle.ink)
            Text(detail).font(.subheadline).foregroundStyle(GlassStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }
}

/// A vector side study of the Explorer's titanium band, camera housing and optical prism.
/// Scales with its container; it never stands in for a connection or battery reading.
struct ExplorerIllustration: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 320, size.height / 124)
            let offset = CGPoint(x: (size.width - 320 * scale) / 2, y: (size.height - 124 * scale) / 2)
            context.translateBy(x: offset.x, y: offset.y)
            context.scaleBy(x: scale, y: scale)

            var farBand = Path()
            farBand.move(to: CGPoint(x: 36, y: 64))
            farBand.addCurve(to: CGPoint(x: 238, y: 30), control1: CGPoint(x: 82, y: 8), control2: CGPoint(x: 178, y: 12))
            context.stroke(farBand, with: .color(Color(white: 0.34)), style: StrokeStyle(lineWidth: 3, lineCap: .round))

            var band = Path()
            band.move(to: CGPoint(x: 24, y: 64))
            band.addCurve(to: CGPoint(x: 196, y: 70), control1: CGPoint(x: 72, y: 88), control2: CGPoint(x: 144, y: 58))
            band.addCurve(to: CGPoint(x: 278, y: 54), control1: CGPoint(x: 226, y: 78), control2: CGPoint(x: 242, y: 64))
            context.stroke(band, with: .color(Color(white: 0.72)), style: StrokeStyle(lineWidth: 5, lineCap: .round))

            let housing = Path(roundedRect: CGRect(x: 178, y: 58, width: 92, height: 20), cornerRadius: 6)
            context.fill(housing, with: .color(Color(white: 0.27)))
            context.stroke(housing, with: .color(Color(white: 0.43)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: 244, y: 62, width: 12, height: 12)), with: .color(Color(white: 0.10)))
            context.stroke(Path(ellipseIn: CGRect(x: 247, y: 65, width: 6, height: 6)), with: .color(Color(white: 0.52)), lineWidth: 1)

            var prism = Path()
            prism.move(to: CGPoint(x: 264, y: 68))
            prism.addLine(to: CGPoint(x: 294, y: 76))
            prism.addLine(to: CGPoint(x: 290, y: 98))
            prism.addLine(to: CGPoint(x: 260, y: 88))
            prism.closeSubpath()
            context.fill(prism, with: .color(GlassStyle.accent.opacity(0.22)))
            context.stroke(prism, with: .color(GlassStyle.accent), lineWidth: 1.5)

            var bridge = Path()
            bridge.move(to: CGPoint(x: 146, y: 68))
            bridge.addQuadCurve(to: CGPoint(x: 134, y: 96), control: CGPoint(x: 150, y: 92))
            context.stroke(bridge, with: .color(Color(white: 0.61)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .aspectRatio(320.0 / 124.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
