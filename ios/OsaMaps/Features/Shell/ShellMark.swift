import SwiftUI

/// Le logo OsaMaps (même dessin que `web/public/favicon.svg` et l'icône de l'app) :
/// une flèche de navigation blanche et sa traînée de trois points, sur fond quasi noir.
/// Coordonnées du SVG (boîte 512 × 512), décalées de (17, -17) comme dans le web.
enum ShellMarkGeometry {
    static let arrow: [CGPoint] = [
        CGPoint(x: 333.5, y: 117.5), CGPoint(x: 299.1, y: 360.8), CGPoint(x: 242.5, y: 275.1), CGPoint(x: 140.0, y: 269.0),
    ].map { CGPoint(x: $0.x + 17, y: $0.y - 17) }
    /// (centre, rayon, opacité)
    static let dots: [(CGPoint, CGFloat, Double)] = [
        (CGPoint(x: 197.0 + 17, y: 353.9 - 17), 15, 0.5),
        (CGPoint(x: 174.0 + 17, y: 393.7 - 17), 11.5, 0.32),
        (CGPoint(x: 155.0 + 17, y: 426.6 - 17), 8.5, 0.18),
    ]
}

/// La flèche seule, cadrée sur sa propre boîte (icône de toast, petits usages).
struct ShellMarkArrow: View {
    var body: some View {
        Canvas { ctx, size in
            let pts = ShellMarkGeometry.arrow
            let minX = pts.map(\.x).min()! - 5, maxX = pts.map(\.x).max()! + 5
            let minY = pts.map(\.y).min()! - 5, maxY = pts.map(\.y).max()! + 5
            let s = min(size.width / (maxX - minX), size.height / (maxY - minY))
            let ox = (size.width - (maxX - minX) * s) / 2, oy = (size.height - (maxY - minY) * s) / 2
            var p = Path()
            p.addLines(pts.map { CGPoint(x: ox + ($0.x - minX) * s, y: oy + ($0.y - minY) * s) })
            p.closeSubpath()
            ctx.fill(p, with: .foreground)
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 10 * s, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Le logo complet (carré arrondi), avec une entrée animée : la flèche arrive, puis les points.
struct ShellMark: View {
    var size: CGFloat = 88
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        let k = size / 512
        ZStack {
            RoundedRectangle(cornerRadius: 116 * k, style: .continuous).fill(Osa.bg)
            RoundedRectangle(cornerRadius: 116 * k, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: max(1, 3 * k))
            ForEach(Array(ShellMarkGeometry.dots.enumerated()), id: \.offset) { i, d in
                Circle()
                    .fill(.white.opacity(d.2))
                    .frame(width: d.1 * 2 * k, height: d.1 * 2 * k)
                    .position(x: d.0.x * k, y: d.0.y * k)
                    .opacity(visible ? 1 : 0)
                    .scaleEffect(visible ? 1 : 0.4)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3).delay(0.35 + Double(i) * 0.09), value: shown)
            }
            Canvas { ctx, _ in
                var p = Path()
                p.addLines(ShellMarkGeometry.arrow.map { CGPoint(x: $0.x * k, y: $0.y * k) })
                p.closeSubpath()
                ctx.fill(p, with: .color(.white))
                ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 10 * k, lineJoin: .round))
            }
            .offset(x: visible ? 0 : -14 * k * 4, y: visible ? 0 : 14 * k * 4)
            .opacity(visible ? 1 : 0)
            .animation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.5).delay(0.05), value: shown)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { shown = true }
    }

    private var visible: Bool { !animated || reduceMotion || shown }
}
