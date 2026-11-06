import SwiftUI

// Flèches de manœuvre dessinées (port des SVG de la version web, repère 48 × 48).
// COPIE de OsaMaps/Features/Guidance/GuidanceArrow.swift (préfixe Live au lieu de Guidance) : garder les deux synchronisés.
// Dans Shared/ : compilée dans l’extension (Live Activity) ET dans l’app (écran d’aperçu DEBUG -livePreview).
// `kind` = valeur brute de GuidanceKind (« right », « roundabout », « arrive-left »…).

enum LiveArrowLayer { case main, dim, fill }

struct LiveArrowShape: Shape {
    var kind: String
    var layer: LiveArrowLayer = .main

    func path(in rect: CGRect) -> Path {
        var p = Path()
        LiveArrowPaths.draw(kind, layer, into: &p)
        let t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / 48, y: rect.height / 48)
        return p.applying(t)
    }
}

/// Flèche de voie : directions « straight », « slight_right », « left », « uturn »… (plusieurs par voie).
struct LiveLaneShape: Shape {
    var directions: [String]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let angles: [String: Double] = [
            "through": 0, "straight": 0, "none": 0, "slight_right": 45, "right": 90, "sharp_right": 135,
            "slight_left": -45, "left": -90, "sharp_left": -135, "merge_to_right": 30, "merge_to_left": -30,
        ]
        for raw in directions.isEmpty ? ["straight"] : directions {
            let d = raw.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            if d.contains("uturn") || d == "reverse" { LiveArrowPaths.uturn(&p, left: true) }
            else { LiveArrowPaths.turn(&p, angles[d] ?? 0, baseX: 24) }
        }
        let t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: rect.width / 48, y: rect.height / 48)
        return p.applying(t)
    }
}

/// La flèche complète (trait arrondi, parties secondaires atténuées, numéro de sortie au centre du rond-point).
struct LiveArrow: View {
    var kind: String
    var exit: Int? = nil
    var size: CGFloat = 64

    var body: some View {
        let w = LiveArrowPaths.lineWidth(kind) * size / 48
        let style = StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round)
        ZStack {
            LiveArrowShape(kind: kind, layer: .dim).stroke(style: style).opacity(0.32)
            LiveArrowShape(kind: kind, layer: .main).stroke(style: style)
            LiveArrowShape(kind: kind, layer: .fill).fill()
            if kind == "roundabout", let exit, exit > 0, size >= 30 {
                Text("\(exit)")
                    .font(.system(size: size * (exit >= 10 ? 0.22 : 0.3), weight: .heavy))
                    .minimumScaleFactor(0.5)
                    .offset(y: size / 48)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct LiveLane: View {
    var directions: [String]
    var valid: Bool
    var size: CGFloat = 38

    var body: some View {
        LiveLaneShape(directions: directions)
            .stroke(style: StrokeStyle(lineWidth: 5 * size / 48, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .opacity(valid ? 1 : 0.3)
    }
}

enum LiveArrowPaths {
    static func lineWidth(_ kind: String) -> CGFloat {
        switch kind {
        case "roundabout", "roundabout-exit": 4
        case "waypoint", "arrive", "arrive-left", "arrive-right", "ferry", "ferry-exit": 3.5
        default: 4.5
        }
    }

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    /// Pointe de flèche en (x, y), orientée selon `theta` (0 = haut, 90 = droite).
    static func head(_ p: inout Path, _ x: Double, _ y: Double, _ theta: Double, size: Double = 8) {
        let back = rad(theta + 180)
        func corner(_ spread: Double) -> CGPoint { pt(x + size * sin(back + rad(spread)), y - size * cos(back + rad(spread))) }
        p.move(to: corner(-42)); p.addLine(to: pt(x, y)); p.addLine(to: corner(42))
    }

    /// Arc échantillonné (angles en degrés, repère écran : 0 = droite, 90 = bas).
    static func arc(_ p: inout Path, cx: Double, cy: Double, r: Double, from a0: Double, to a1: Double) {
        let steps = 24
        for i in 1...steps {
            let a = rad(a0 + (a1 - a0) * Double(i) / Double(steps))
            p.addLine(to: pt(cx + r * cos(a), cy + r * sin(a)))
        }
    }

    /// Flèche de virage : tige verticale puis branche à l'angle `theta`, coin arrondi.
    static func turn(_ p: inout Path, _ theta: Double, pivotY: Double? = nil, len: Double? = nil, baseX: Double? = nil) {
        if theta == 0 {
            let x = baseX ?? 24
            p.move(to: pt(x, 43)); p.addLine(to: pt(x, 7)); head(&p, x, 7, 0)
            return
        }
        let s = sin(rad(theta)), c = cos(rad(theta))
        let sharp = abs(theta) > 100
        let py = pivotY ?? (sharp ? 18 : 24)
        let l = len ?? (sharp ? 15 : 16)
        let px = baseX ?? 24 - 7 * s
        let r = 6.0
        let ex = px + l * s, ey = py - l * c
        p.move(to: pt(px, 43)); p.addLine(to: pt(px, py + r))
        p.addQuadCurve(to: pt(px + r * s, py - r * c), control: pt(px, py))
        p.addLine(to: pt(ex, ey))
        head(&p, ex, ey, theta)
    }

    static func uturn(_ p: inout Path, left: Bool) {
        if left {
            p.move(to: pt(31, 43)); p.addLine(to: pt(31, 20))
            arc(&p, cx: 22.5, cy: 20, r: 8.5, from: 0, to: -180)
            p.addLine(to: pt(14, 33)); head(&p, 14, 33, 180)
        } else {
            p.move(to: pt(17, 43)); p.addLine(to: pt(17, 20))
            arc(&p, cx: 25.5, cy: 20, r: 8.5, from: 180, to: 360)
            p.addLine(to: pt(34, 33)); head(&p, 34, 33, 180)
        }
    }

    static func draw(_ kind: String, _ layer: LiveArrowLayer, into p: inout Path) {
        switch kind {
        case "roundabout", "roundabout-exit":
            // sens giratoire français : on entre par le bas, on tourne par la droite
            let exitOnly = kind == "roundabout-exit"
            if layer == .dim {
                p.addEllipse(in: CGRect(x: 12, y: 13, width: 24, height: 24))
                if exitOnly { p.move(to: pt(24, 46)); p.addLine(to: pt(24, 37)); arc(&p, cx: 24, cy: 25, r: 12, from: 90, to: -90) }
            } else if layer == .main {
                if exitOnly { p.move(to: pt(24, 13)) } else {
                    p.move(to: pt(24, 46)); p.addLine(to: pt(24, 37)); arc(&p, cx: 24, cy: 25, r: 12, from: 90, to: -90)
                }
                p.addLine(to: pt(24, 4)); head(&p, 24, 4, 0)
            }
        case "waypoint":
            guard layer == .main else { return }
            p.move(to: pt(14, 44)); p.addLine(to: pt(14, 6))
            p.move(to: pt(14, 7)); p.addLine(to: pt(36, 7)); p.addLine(to: pt(31, 15.5)); p.addLine(to: pt(36, 24)); p.addLine(to: pt(14, 24))
        case "arrive", "arrive-left", "arrive-right":
            if layer == .main {
                p.move(to: pt(24, 44))
                p.addCurve(to: pt(11, 20), control1: pt(24, 44), control2: pt(11, 31))
                arc(&p, cx: 24, cy: 20, r: 13, from: 180, to: 360)
                p.addCurve(to: pt(24, 44), control1: pt(37, 31), control2: pt(24, 44))
                p.closeSubpath()
            } else if layer == .fill {
                p.addEllipse(in: CGRect(x: 19.5, y: 15.5, width: 9, height: 9))
            }
        case "ferry", "ferry-exit":
            guard layer == .main else { return }
            p.move(to: pt(7, 30)); p.addLine(to: pt(41, 30)); p.addLine(to: pt(36, 39)); p.addLine(to: pt(12, 39)); p.closeSubpath()
            p.move(to: pt(14, 30)); p.addLine(to: pt(14, 20)); p.addLine(to: pt(34, 20)); p.addLine(to: pt(34, 30))
            p.move(to: pt(24, 20)); p.addLine(to: pt(24, 11))
        default:
            switch (kind, layer) {
            case ("slight-right", .main): turn(&p, 45)
            case ("right", .main): turn(&p, 90)
            case ("sharp-right", .main): turn(&p, 135)
            case ("slight-left", .main): turn(&p, -45)
            case ("left", .main): turn(&p, -90)
            case ("sharp-left", .main): turn(&p, -135)
            case ("uturn-left", .main): uturn(&p, left: true)
            case ("uturn-right", .main): uturn(&p, left: false)
            case ("ramp-right", .dim), ("exit-right", .dim): p.move(to: pt(19, 43)); p.addLine(to: pt(19, 6))
            case ("ramp-right", .main), ("exit-right", .main): turn(&p, 45, pivotY: 28, len: 17, baseX: 19)
            case ("ramp-left", .dim), ("exit-left", .dim): p.move(to: pt(29, 43)); p.addLine(to: pt(29, 6))
            case ("ramp-left", .main), ("exit-left", .main): turn(&p, -45, pivotY: 28, len: 17, baseX: 29)
            case ("keep-right", .dim): p.move(to: pt(24, 26)); p.addLine(to: pt(13, 8))
            case ("keep-right", .main):
                p.move(to: pt(24, 43)); p.addLine(to: pt(24, 26)); p.addLine(to: pt(35, 8)); head(&p, 35, 8, 31)
            case ("keep-left", .dim): p.move(to: pt(24, 26)); p.addLine(to: pt(35, 8))
            case ("keep-left", .main):
                p.move(to: pt(24, 43)); p.addLine(to: pt(24, 26)); p.addLine(to: pt(13, 8)); head(&p, 13, 8, -31)
            case ("merge", .dim), ("merge-right", .dim):
                p.move(to: pt(12, 43)); p.addQuadCurve(to: pt(24, 22), control: pt(12, 30))
            case ("merge", .main), ("merge-right", .main):
                p.move(to: pt(36, 43)); p.addQuadCurve(to: pt(24, 22), control: pt(36, 30)); p.addLine(to: pt(24, 7)); head(&p, 24, 7, 0)
            case ("merge-left", .dim):
                p.move(to: pt(36, 43)); p.addQuadCurve(to: pt(24, 22), control: pt(36, 30))
            case ("merge-left", .main):
                p.move(to: pt(12, 43)); p.addQuadCurve(to: pt(24, 22), control: pt(12, 30)); p.addLine(to: pt(24, 7)); head(&p, 24, 7, 0)
            case (_, .main): turn(&p, 0)
            default: break
            }
        }
    }
}
