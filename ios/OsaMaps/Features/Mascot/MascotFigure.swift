import SwiftUI

/// La mascotte OsaLabs — reprise fidèle de `Mascot.swift` (OsaHUB) : corps crème arrondi
/// (largeur w, hauteur 0,92 w, rayon 0,42 w) éclairé en haut à gauche, bras en capsules derrière le corps,
/// pieds ovales, yeux en capsules avec un reflet, joues roses. Elle cligne des yeux, regarde où on lui dit
/// (`look`, de -1 à 1), lève les bras, saute quand `hop` change.
/// Ajouts d'OsaMaps (comme la version web) : humeur « sleepy », petite voiture (`kart`), accessoires,
/// rebond en roulant, recadrage sur la tête (bouton rond).
/// Les traits ajoutés sont dessinés dans le repère du web : corps de 100 unités centré sur l'origine.
struct MascotFigure: View {
    typealias Mood = MascotEngine.Mood
    typealias Arms = MascotEngine.Arms

    var mood: Mood = .calm
    var arms: Arms = .rest
    var look: CGSize = .zero
    /// Largeur rendue : du corps en mode normal (le cadre fait 1,6 × size), du cadre carré en mode `head`.
    var size: CGFloat = 90
    var hop = 0
    var kart = false
    var accessories: [MascotAccessory] = []
    var blinks = true
    /// Recadré sur le corps (bouton rond, vignettes).
    var head = false
    /// Rebond léger en boucle (en roulant).
    var bounce = false
    /// Réglage « Animations » de la mascotte (le système « Réduire les animations » est lu ici aussi).
    var animated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blink = false
    @State private var swing = false
    @State private var bob = false

    static let ink = Color(red: 0.106, green: 0.114, blue: 0.141)
    static let light = Color(red: 0.995, green: 0.99, blue: 0.97)
    static let shade = Color(red: 0.84, green: 0.81, blue: 0.76)
    static let cheek = Color(red: 1, green: 0.5, blue: 0.59)
    private var ink: Color { Self.ink }
    private var light: Color { Self.light }
    private var shade: Color { Self.shade }
    private var cheek: Color { Self.cheek }

    private var moves: Bool { animated && !reduceMotion }
    /// Largeur du corps.
    private var w: CGFloat { head ? size * 100 / 124 : size }
    /// Une unité du repère web (corps = 100).
    private var u: CGFloat { w / 100 }

    var body: some View {
        let w = self.w, h = w * 0.92
        ZStack {
            Ellipse().fill(.black.opacity(0.55))
                .frame(width: kart ? w * 1.28 : w * 0.85, height: w * 0.12).blur(radius: w * 0.03).offset(y: h * 0.56)
            figure
                .offset(y: bob ? -3 * u : 0)
                .keyframeAnimator(initialValue: 0.0, trigger: moves ? hop : 0) { view, y in
                    view.offset(y: y).scaleEffect(x: 1 - y / (w * 6), y: 1 + y / (w * 8), anchor: .bottom)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(w * 0.04, duration: 0.08)
                        SpringKeyframe(-w * 0.3, duration: 0.22, spring: .snappy)
                        SpringKeyframe(0, duration: 0.25, spring: .bouncy)
                    }
                }
        }
        .offset(y: head ? 8 * u : 0)
        .frame(width: head ? size : w * 1.6, height: head ? size : h * 1.35)
        .animation(moves ? .spring(response: 0.35, dampingFraction: 0.7) : nil, value: look)
        .animation(moves ? .spring(response: 0.4, dampingFraction: 0.6) : nil, value: arms)
        .animation(moves ? .easeInOut(duration: 0.25) : nil, value: mood)
        .animation(.easeOut(duration: 0.25), value: kart)
        .onAppear { updateSwing(); updateBob() }
        .onChange(of: arms) { updateSwing() }
        .onChange(of: bounce) { updateBob() }
        .onChange(of: moves) { updateSwing(); updateBob() }
        .task(id: blinks && moves && mood != .happy && mood != .sleepy) {
            guard blinks && moves && mood != .happy && mood != .sleepy else { blink = false; return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 2.4...5)))
                if Task.isCancelled { break }
                withAnimation(.easeIn(duration: 0.06)) { blink = true }
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.easeOut(duration: 0.1)) { blink = false }
            }
        }
        .accessibilityHidden(true)
    }

    /// Tout ce qui saute et rebondit (l'ombre reste au sol).
    private var figure: some View {
        let w = self.w, h = w * 0.92
        return ZStack {
            if !kart {
                ForEach([-1.0, 1.0], id: \.self) { s in
                    Ellipse().fill(LinearGradient(colors: [shade, Color(red: 0.7, green: 0.67, blue: 0.62)], startPoint: .top, endPoint: .bottom))
                        .frame(width: w * 0.24, height: w * 0.13).offset(x: s * w * 0.2, y: h * 0.47)
                }
            }
            arm(side: -1)
            arm(side: 1)
            RoundedRectangle(cornerRadius: w * 0.42, style: .continuous)
                .fill(RadialGradient(colors: [light, light, shade], center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: w * 0.78))
                .frame(width: w, height: h)
                .overlay(RoundedRectangle(cornerRadius: w * 0.42, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1).blur(radius: 0.5))
                // contour discret : lisible aussi sur une carte claire
                .overlay(RoundedRectangle(cornerRadius: w * 0.42, style: .continuous).stroke(.black.opacity(0.28), lineWidth: max(0.6, 1.2 * u)))
            ZStack {
                face
                if accessories.contains(.lunettes) { units { MascotDrawing.glasses(&$0) } }
            }
            .offset(x: look.width * w * 0.05, y: look.height * w * 0.035)
            if kart { units { MascotDrawing.kart(&$0) }.transition(.opacity) }
            if !accessories.isEmpty {
                units { ctx in
                    if accessories.contains(.echarpe) { MascotDrawing.scarf(&ctx) }
                    if accessories.contains(.noeud) { MascotDrawing.bow(&ctx) }
                    if accessories.contains(.casquette) { MascotDrawing.cap(&ctx) }
                    if accessories.contains(.bonnet) { MascotDrawing.beanie(&ctx) }
                    if accessories.contains(.couronne) { MascotDrawing.crown(&ctx) }
                }
            }
        }
    }

    /// Un Canvas dans le repère web (origine au centre du corps, 100 unités = largeur du corps).
    private func units(_ draw: @escaping (inout GraphicsContext) -> Void) -> some View {
        let u = self.u
        return Canvas { ctx, sz in
            ctx.translateBy(x: sz.width / 2, y: sz.height / 2)
            ctx.scaleBy(x: u, y: u)
            draw(&ctx)
        }
        .frame(width: 180 * u, height: 180 * u)
        .allowsHitTesting(false)
    }

    // Les bras ne bougent en boucle que pendant le coucou (sinon ça coûte du CPU pour rien).
    private func updateSwing() {
        if arms == .wave && moves {
            swing = false
            withAnimation(.easeInOut(duration: 0.28).repeatCount(7, autoreverses: true)) { swing = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { swing = false }
        }
    }

    private func updateBob() {
        if bounce && moves {
            bob = false
            withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) { bob = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { bob = false }
        }
    }

    private func angle(_ side: Double) -> Double {
        // 0° = bras qui pend ; on tourne autour de l'épaule
        let out: Double
        switch arms {
        case .rest: out = kart ? 8 : 18
        case .up: out = 150
        case .wave: out = side > 0 ? (moves ? (swing ? 165 : 125) : 150) : 18
        }
        return -side * out
    }

    private func arm(side: Double) -> some View {
        let w = self.w, len = w * 0.36
        return Capsule()
            .fill(LinearGradient(colors: [light, shade], startPoint: .top, endPoint: .bottom))
            .frame(width: w * 0.15, height: len)
            .rotationEffect(.degrees(angle(side)), anchor: .top)
            .offset(x: side * w * 0.44, y: w * 0.02 + len / 2)
    }

    private var face: some View {
        let w = self.w
        return ZStack {
            ForEach([-1.0, 1.0], id: \.self) { s in
                eye(s).offset(x: s * w * 0.17, y: -w * 0.05)
                if mood == .worried || mood == .sad {
                    Capsule().fill(ink).frame(width: w * 0.13, height: w * 0.03)
                        .rotationEffect(.degrees(s * (mood == .sad ? 20 : 16)))
                        .offset(x: s * w * 0.18, y: -w * 0.2)
                }
                Ellipse().fill(cheek.opacity(0.55)).frame(width: w * 0.16, height: w * 0.08).offset(x: s * w * 0.3, y: w * 0.1)
            }
            mouth.offset(y: w * 0.16)
        }
    }

    @ViewBuilder private func eye(_ s: Double) -> some View {
        let w = self.w
        switch mood {
        case .happy:
            MascotSmile(up: true).stroke(ink, style: StrokeStyle(lineWidth: w * 0.045, lineCap: .round)).frame(width: w * 0.15, height: w * 0.08)
        case .sleepy:
            MascotSmile(up: false).stroke(ink, style: StrokeStyle(lineWidth: w * 0.04, lineCap: .round)).frame(width: w * 0.14, height: w * 0.05)
        default:
            let big = mood == .excited ? 1.2 : 1
            let round = mood == .worried || mood == .sad
            Capsule().fill(ink)
                .frame(width: w * 0.12 * big, height: (round ? w * 0.13 : w * 0.2) * big)
                .overlay(Circle().fill(.white.opacity(0.92)).frame(width: w * 0.045 * big).offset(x: w * 0.015, y: -w * 0.035 * big))
                .scaleEffect(x: 1, y: blink ? 0.1 : 1)
        }
    }

    @ViewBuilder private var mouth: some View {
        let w = self.w
        switch mood {
        case .sad:
            MascotSmile(up: true).stroke(ink, style: StrokeStyle(lineWidth: w * 0.035, lineCap: .round)).frame(width: w * 0.15, height: w * 0.05)
        case .worried:
            Capsule().fill(ink).frame(width: w * 0.1, height: w * 0.03)
        case .excited:
            Ellipse().fill(ink).frame(width: w * 0.15, height: w * 0.12)
                .overlay(Ellipse().fill(cheek).frame(width: w * 0.08, height: w * 0.045).offset(y: w * 0.03))
                .clipShape(Ellipse())
        case .curious, .busy:
            Ellipse().fill(ink).frame(width: w * 0.07, height: w * 0.07)
        case .sleepy:
            Circle().fill(ink).frame(width: w * 0.052, height: w * 0.052)
        case .calm, .happy:
            MascotSmile(up: false).stroke(ink, style: StrokeStyle(lineWidth: w * 0.035, lineCap: .round))
                .frame(width: mood == .happy ? w * 0.24 : w * 0.18, height: w * 0.07)
        }
    }
}

/// Un arc : sourire (`up` faux) ou œil fermé de joie / bouche triste (`up` vrai).
struct MascotSmile: Shape {
    var up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: up ? r.maxY : r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: up ? r.maxY : r.minY), control: CGPoint(x: r.midX, y: up ? r.minY - r.height : r.maxY + r.height))
        return p
    }
}

/// Voiture et accessoires, cotes reprises du SVG de la version web (repère : corps de 100 centré).
enum MascotDrawing {
    private static let ink = MascotFigure.ink
    private static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255).opacity(a)
    }
    private static func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
    }
    private static func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path(); p.move(to: a); p.addLine(to: b); return p
    }
    private static func round(_ w: CGFloat) -> StrokeStyle { StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }

    /// La petite voiture vue de face : coque sombre avec deux phares, devant le bas du corps.
    static func kart(_ c: inout GraphicsContext) {
        for s in [-1.0, 1.0] { c.fill(rr(s * 46 - 11, 44, 22, 16, 6), with: .color(hex(0x0c0d11))) }
        let shell = rr(-62, 22, 124, 32, 16)
        c.fill(shell, with: .color(ink))
        c.stroke(shell, with: .color(.white.opacity(0.28)), lineWidth: 1.6)
        c.fill(rr(-40, 27, 80, 4, 2), with: .color(.white.opacity(0.12)))
        for s in [-1.0, 1.0] { c.fill(Path(ellipseIn: CGRect(x: s * 44 - 5, y: 33, width: 10, height: 10)), with: .color(.white.opacity(0.92))) }
        c.fill(rr(-14, 38, 28, 7, 3.5), with: .color(.white.opacity(0.1)))
    }

    static func glasses(_ c: inout GraphicsContext) {
        var bridge = Path()
        bridge.move(to: .init(x: -5, y: -6)); bridge.addQuadCurve(to: .init(x: 5, y: -6), control: .init(x: 0, y: -9))
        c.stroke(bridge, with: .color(ink), style: round(2.6))
        for s in [-1.0, 1.0] {
            c.fill(rr(s * 17 - 11, -13, 22, 16, 7), with: .color(ink))
            c.stroke(line(.init(x: s * 17 - 6, y: -9), .init(x: s * 17 - 1, y: -9)), with: .color(.white.opacity(0.55)), style: round(2))
            c.stroke(line(.init(x: s * 28, y: -8), .init(x: s * 46, y: -12)), with: .color(ink), style: round(2.6))
        }
    }

    static func cap(_ c: inout GraphicsContext) {
        var dome = Path()
        dome.move(to: .init(x: -43, y: -28))
        dome.addCurve(to: .init(x: 43, y: -28), control1: .init(x: -43, y: -66), control2: .init(x: 43, y: -66))
        dome.closeSubpath()
        c.fill(dome, with: .color(ink))
        var visor = Path()
        visor.move(to: .init(x: -46, y: -31))
        visor.addQuadCurve(to: .init(x: 56, y: -30), control: .init(x: 4, y: -40))
        visor.addQuadCurve(to: .init(x: 52, y: -24), control: .init(x: 58, y: -25))
        visor.addQuadCurve(to: .init(x: -44, y: -25), control: .init(x: 4, y: -31))
        visor.addQuadCurve(to: .init(x: -46, y: -31), control: .init(x: -50, y: -27))
        visor.closeSubpath()
        c.fill(visor, with: .color(hex(0x2a2d38)))
        c.stroke(line(.init(x: 0, y: -56), .init(x: 0, y: -30)), with: .color(.white.opacity(0.14)), lineWidth: 2)
        c.fill(Path(ellipseIn: CGRect(x: -3.4, y: -59.4, width: 6.8, height: 6.8)), with: .color(.white.opacity(0.85)))
    }

    static func beanie(_ c: inout GraphicsContext) {
        var dome = Path()
        dome.move(to: .init(x: -42, y: -28))
        dome.addCurve(to: .init(x: 42, y: -28), control1: .init(x: -44, y: -64), control2: .init(x: 44, y: -64))
        dome.closeSubpath()
        c.fill(dome, with: .color(hex(0x2c2f3a)))
        for x in [-24.0, -8, 8, 24] {
            c.stroke(line(.init(x: x, y: -30), .init(x: x * 0.8, y: -52)), with: .color(.white.opacity(0.16)), style: round(2.4))
        }
        c.fill(rr(-46, -34, 92, 12, 6), with: .color(hex(0x3a3e4b)))
        c.fill(Path(ellipseIn: CGRect(x: -7, y: -67, width: 14, height: 14)), with: .color(MascotFigure.light))
    }

    static func crown(_ c: inout GraphicsContext) {
        var p = Path()
        let pts: [CGPoint] = [.init(x: -26, y: -38), .init(x: -30, y: -62), .init(x: -14, y: -50), .init(x: 0, y: -66),
                              .init(x: 14, y: -50), .init(x: 30, y: -62), .init(x: 26, y: -38)]
        p.addLines(pts); p.closeSubpath()
        c.fill(p, with: .color(hex(0xffcc00)))
        c.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
        c.fill(Path(ellipseIn: CGRect(x: -3, y: -50, width: 6, height: 6)), with: .color(ink.opacity(0.8)))
    }

    static func scarf(_ c: inout GraphicsContext) {
        var tail = Path()
        tail.addLines([.init(x: 26, y: 24), .init(x: 34, y: 52), .init(x: 22, y: 54), .init(x: 16, y: 26)]); tail.closeSubpath()
        c.fill(tail, with: .color(hex(0xc9455c)))
        var band = Path()
        band.move(to: .init(x: -47, y: 16))
        band.addQuadCurve(to: .init(x: 47, y: 16), control: .init(x: 0, y: 30))
        band.addLine(to: .init(x: 46, y: 27))
        band.addQuadCurve(to: .init(x: -46, y: 27), control: .init(x: 0, y: 41))
        band.closeSubpath()
        c.fill(band, with: .color(hex(0xe05a70)))
        for (a, b) in [((-30.0, 25.0), (-26.0, 33.0)), ((-10, 28), (-7, 36)), ((10, 28), (7, 36)), ((30, 25), (26, 33))] {
            c.stroke(line(.init(x: a.0, y: a.1), .init(x: b.0, y: b.1)), with: .color(.white.opacity(0.45)), style: round(2.2))
        }
    }

    static func bow(_ c: inout GraphicsContext) {
        var p = Path()
        for s in [-1.0, 1.0] {
            p.move(to: .init(x: 0, y: 33))
            p.addLine(to: .init(x: s * 16, y: 24))
            p.addQuadCurve(to: .init(x: s * 16, y: 42), control: .init(x: s * 19, y: 33))
            p.closeSubpath()
        }
        c.fill(p, with: .color(ink))
        c.fill(rr(-4.5, 28.5, 9, 9, 3), with: .color(hex(0x2f3240)))
    }
}
