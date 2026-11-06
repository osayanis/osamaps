import SwiftUI

/// Tout ce qu'on dessine par-dessus le corps de la mascotte : chapeaux, lunettes, détails du cou,
/// expressions du visage et véhicules (vus de face). Repère commun avec la version web (`parts.tsx`) :
/// corps de 100 unités centré sur l'origine (x de -50 à 50, y de -46 à 46), ombre au sol vers y = 51.
enum MascotDrawing {
    static let ink = MascotFigure.ink
    private static func hex(_ v: UInt32, _ a: Double = 1) -> Color { .mascotHex(v, a) }
    private static func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
    }
    private static func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }
    private static func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path(); p.move(to: a); p.addLine(to: b); return p
    }
    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    private static func round(_ w: CGFloat) -> StrokeStyle { StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }
    /// Le même tracé, retourné de gauche à droite.
    private static func mirrored(_ p: Path) -> Path { p.applying(CGAffineTransform(scaleX: -1, y: 1)) }

    // MARK: - Tête

    /// Liseré clair des chapeaux sombres : lisibles sur la carte et les fonds noirs.
    private static func rim(_ c: inout GraphicsContext, _ p: Path) {
        c.stroke(p, with: .color(.white.opacity(0.26)), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
    }

    static func hat(_ c: inout GraphicsContext, _ h: MascotLook.Hat) {
        switch h {
        case .none: break
        case .casquette: cap(&c)
        case .bonnet: beanie(&c)
        case .beret: beret(&c)
        case .chapeau: fedora(&c)
        case .chantier: hardHat(&c)
        case .couronne: crown(&c)
        }
    }

    private static func cap(_ c: inout GraphicsContext) {
        var dome = Path()
        dome.move(to: pt(-43, -28))
        dome.addCurve(to: pt(43, -28), control1: pt(-43, -66), control2: pt(43, -66))
        dome.closeSubpath()
        c.fill(dome, with: .color(ink))
        rim(&c, dome)
        var visor = Path()
        visor.move(to: pt(-46, -31))
        visor.addQuadCurve(to: pt(56, -30), control: pt(4, -40))
        visor.addQuadCurve(to: pt(52, -24), control: pt(58, -25))
        visor.addQuadCurve(to: pt(-44, -25), control: pt(4, -31))
        visor.addQuadCurve(to: pt(-46, -31), control: pt(-50, -27))
        visor.closeSubpath()
        c.fill(visor, with: .color(hex(0x2a2d38)))
        rim(&c, visor)
        c.stroke(line(pt(0, -56), pt(0, -30)), with: .color(.white.opacity(0.14)), lineWidth: 2)
        c.fill(oval(0, -56, 3.4, 3.4), with: .color(.white.opacity(0.85)))
    }

    private static func beanie(_ c: inout GraphicsContext) {
        var dome = Path()
        dome.move(to: pt(-42, -28))
        dome.addCurve(to: pt(42, -28), control1: pt(-44, -64), control2: pt(44, -64))
        dome.closeSubpath()
        c.fill(dome, with: .color(hex(0x2c2f3a)))
        rim(&c, dome)
        for x in [-24.0, -8, 8, 24] {
            c.stroke(line(pt(x, -30), pt(x * 0.8, -52)), with: .color(.white.opacity(0.16)), style: round(2.4))
        }
        c.fill(rr(-46, -34, 92, 12, 6), with: .color(hex(0x3a3e4b)))
        rim(&c, rr(-46, -34, 92, 12, 6))
        c.fill(oval(0, -60, 7, 7), with: .color(MascotFigure.light))
        c.stroke(oval(0, -60, 7, 7), with: .color(.black.opacity(0.18)), lineWidth: 1)
    }

    private static func beret(_ c: inout GraphicsContext) {
        var p = Path()
        p.move(to: pt(-47, -33))
        p.addCurve(to: pt(43, -41), control1: pt(-56, -60), control2: pt(24, -72))
        p.addQuadCurve(to: pt(-47, -33), control: pt(-2, -27))
        p.closeSubpath()
        c.fill(rr(-6.5, -67, 5, 9, 2.5), with: .color(hex(0x24262f)))
        c.fill(p, with: .color(hex(0x24262f)))
        rim(&c, p)
        var hi = Path()
        hi.move(to: pt(-32, -47)); hi.addQuadCurve(to: pt(10, -59), control: pt(-14, -59))
        c.stroke(hi, with: .color(.white.opacity(0.13)), style: round(2.6))
    }

    private static func fedora(_ c: inout GraphicsContext) {
        var crown = Path()
        crown.move(to: pt(-31, -36))
        crown.addCurve(to: pt(-16, -70), control1: pt(-34, -56), control2: pt(-28, -68))
        crown.addQuadCurve(to: pt(16, -70), control: pt(0, -63))
        crown.addCurve(to: pt(31, -36), control1: pt(28, -68), control2: pt(34, -56))
        crown.closeSubpath()
        c.fill(crown, with: .color(hex(0x2b2e38)))
        rim(&c, crown)
        var band = c
        band.clip(to: crown)
        band.fill(rr(-40, -47, 80, 9, 0), with: .color(hex(0x14151a)))
        var hi = Path()
        hi.move(to: pt(-21, -62)); hi.addQuadCurve(to: pt(-25, -49), control: pt(-25, -57))
        c.stroke(hi, with: .color(.white.opacity(0.13)), style: round(2.6))
        var brim = Path()
        brim.move(to: pt(-60, -33))
        brim.addQuadCurve(to: pt(60, -33), control: pt(0, -47))
        brim.addQuadCurve(to: pt(55, -27), control: pt(63, -28))
        brim.addQuadCurve(to: pt(-55, -27), control: pt(0, -38))
        brim.addQuadCurve(to: pt(-60, -33), control: pt(-63, -28))
        brim.closeSubpath()
        c.fill(brim, with: .color(hex(0x363a47)))
        rim(&c, brim)
    }

    private static func hardHat(_ c: inout GraphicsContext) {
        var dome = Path()
        dome.move(to: pt(-42, -30))
        dome.addCurve(to: pt(42, -30), control1: pt(-42, -70), control2: pt(42, -70))
        dome.closeSubpath()
        c.fill(dome, with: .color(hex(0xffc21a)))
        var ridge = c
        ridge.clip(to: dome)
        ridge.fill(rr(-6.5, -70, 13, 42, 6.5), with: .color(hex(0xffd75a)))
        c.stroke(dome, with: .color(ink.opacity(0.4)), lineWidth: 1.4)
        var hi = Path()
        hi.move(to: pt(-31, -44)); hi.addQuadCurve(to: pt(-14, -59), control: pt(-26, -56))
        c.stroke(hi, with: .color(.white.opacity(0.5)), style: round(3))
        var brim = Path()
        brim.move(to: pt(-54, -33))
        brim.addQuadCurve(to: pt(54, -33), control: pt(0, -41))
        brim.addLine(to: pt(52, -26))
        brim.addQuadCurve(to: pt(-52, -26), control: pt(0, -34))
        brim.closeSubpath()
        c.fill(brim, with: .color(hex(0xeca800)))
        c.stroke(brim, with: .color(ink.opacity(0.4)), lineWidth: 1.2)
    }

    private static func crown(_ c: inout GraphicsContext) {
        var p = Path()
        p.addLines([pt(-26, -38), pt(-30, -62), pt(-14, -50), pt(0, -66), pt(14, -50), pt(30, -62), pt(26, -38)])
        p.closeSubpath()
        c.fill(p, with: .color(hex(0xffcc00)))
        c.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
        c.fill(oval(0, -47, 3, 3), with: .color(ink.opacity(0.8)))
    }

    // MARK: - Lunettes (sur le visage, qui glisse avec le regard)

    static func glasses(_ c: inout GraphicsContext, _ g: MascotLook.Glasses) {
        switch g {
        case .none: break
        case .soleil:
            var bridge = Path()
            bridge.move(to: pt(-5, -6)); bridge.addQuadCurve(to: pt(5, -6), control: pt(0, -9))
            c.stroke(bridge, with: .color(ink), style: round(2.6))
            for s in [-1.0, 1.0] {
                c.fill(rr(s * 17 - 11, -13, 22, 16, 7), with: .color(ink))
                c.stroke(line(pt(s * 17 - 6, -9), pt(s * 17 - 1, -9)), with: .color(.white.opacity(0.55)), style: round(2))
                c.stroke(line(pt(s * 28, -8), pt(s * 46, -12)), with: .color(ink), style: round(2.6))
            }
        case .rondes:
            var bridge = Path()
            bridge.move(to: pt(-5.5, -7)); bridge.addQuadCurve(to: pt(5.5, -7), control: pt(0, -11.5))
            c.stroke(bridge, with: .color(ink), style: round(2.2))
            for s in [-1.0, 1.0] {
                let lens = oval(s * 17, -5, 11.5, 11.5)
                c.fill(lens, with: .color(.white.opacity(0.2)))
                c.stroke(lens, with: .color(ink), lineWidth: 2.4)
                var glint = Path()
                glint.addArc(center: pt(s * 17, -5), radius: 8, startAngle: .degrees(200), endAngle: .degrees(245), clockwise: false)
                c.stroke(glint, with: .color(.white.opacity(0.85)), style: round(2))
                c.stroke(line(pt(s * 28.5, -7), pt(s * 46, -11)), with: .color(ink), style: round(2.2))
            }
        case .aviateur:
            let frame = hex(0xb8934a)
            var right = Path()
            right.move(to: pt(5, -14))
            right.addLine(to: pt(29, -15))
            right.addCurve(to: pt(18, 6), control1: pt(31.5, -3), control2: pt(27, 6))
            right.addCurve(to: pt(5, -14), control1: pt(9, 6), control2: pt(3.5, -3))
            right.closeSubpath()
            for lens in [right, mirrored(right)] {
                c.fill(lens, with: .linearGradient(Gradient(colors: [hex(0x232733), hex(0x4a5468)]), startPoint: pt(0, -15), endPoint: pt(0, 6)))
                c.stroke(lens, with: .color(frame), lineWidth: 1.8)
            }
            for s in [-1.0, 1.0] {
                c.stroke(line(pt(s * 9, -10), pt(s * 15, -10)), with: .color(.white.opacity(0.4)), style: round(1.8))
                c.stroke(line(pt(s * 29, -14), pt(s * 46, -12)), with: .color(frame), style: round(1.8))
            }
            c.stroke(line(pt(-5, -13.5), pt(5, -13.5)), with: .color(frame), style: round(1.8))
            var low = Path()
            low.move(to: pt(-4.5, -8.5)); low.addQuadCurve(to: pt(4.5, -8.5), control: pt(0, -10.5))
            c.stroke(low, with: .color(frame), style: round(1.6))
        case .carrees:
            c.fill(rr(-5, -9.5, 10, 3.2, 1.6), with: .color(ink))
            for s in [-1.0, 1.0] {
                let lens = rr(s * 17 - 12.5, -15, 25, 19.5, 5.5)
                c.fill(lens, with: .color(.white.opacity(0.16)))
                c.stroke(lens, with: .color(ink), lineWidth: 3.6)
                c.stroke(line(pt(s * 17 - 7, -10), pt(s * 17 - 3, -10)), with: .color(.white.opacity(0.75)), style: round(1.8))
                c.stroke(line(pt(s * 29.5, -9), pt(s * 46, -12)), with: .color(ink), style: round(3))
            }
        }
    }

    // MARK: - Cou

    static func neck(_ c: inout GraphicsContext, _ n: MascotLook.Neck) {
        switch n {
        case .none: break
        case .noeud:
            var p = Path()
            for s in [-1.0, 1.0] {
                p.move(to: pt(0, 33))
                p.addLine(to: pt(s * 16, 24))
                p.addQuadCurve(to: pt(s * 16, 42), control: pt(s * 19, 33))
                p.closeSubpath()
            }
            c.fill(p, with: .color(ink))
            c.fill(rr(-4.5, 28.5, 9, 9, 3), with: .color(hex(0x2f3240)))
        case .echarpe:
            var tail = Path()
            tail.addLines([pt(26, 24), pt(34, 52), pt(22, 54), pt(16, 26)]); tail.closeSubpath()
            c.fill(tail, with: .color(hex(0xc9455c)))
            var band = Path()
            band.move(to: pt(-47, 16))
            band.addQuadCurve(to: pt(47, 16), control: pt(0, 30))
            band.addLine(to: pt(46, 27))
            band.addQuadCurve(to: pt(-46, 27), control: pt(0, 41))
            band.closeSubpath()
            c.fill(band, with: .color(hex(0xe05a70)))
            for (a, b) in [((-30.0, 25.0), (-26.0, 33.0)), ((-10, 28), (-7, 36)), ((10, 28), (7, 36)), ((30, 25), (26, 33))] {
                c.stroke(line(pt(a.0, a.1), pt(b.0, b.1)), with: .color(.white.opacity(0.45)), style: round(2.2))
            }
        case .bandana:
            var tri = Path()
            tri.move(to: pt(-25, 25)); tri.addQuadCurve(to: pt(25, 25), control: pt(0, 32))
            tri.addQuadCurve(to: pt(0, 47), control: pt(10, 38)); tri.addQuadCurve(to: pt(-25, 25), control: pt(-10, 38))
            tri.closeSubpath()
            c.fill(tri, with: .color(hex(0x2f63c8)))
            var band = Path()
            band.move(to: pt(-45, 18)); band.addQuadCurve(to: pt(45, 18), control: pt(0, 32))
            band.addLine(to: pt(44, 25)); band.addQuadCurve(to: pt(-44, 25), control: pt(0, 39))
            band.closeSubpath()
            c.fill(band, with: .color(hex(0x3a72dc)))
            for d in [pt(-30, 23.5), pt(-14, 28), pt(14, 28), pt(30, 23.5), pt(-7, 35), pt(7, 35), pt(0, 41.5)] {
                c.fill(oval(d.x, d.y, 1.7, 1.7), with: .color(.white.opacity(0.8)))
            }
        case .cravate:
            var knot = Path()
            knot.addLines([pt(-5.5, 21), pt(5.5, 21), pt(4, 27.5), pt(-4, 27.5)]); knot.closeSubpath()
            c.fill(knot, with: .color(hex(0x26346a)))
            var blade = Path()
            blade.addLines([pt(-4, 27.5), pt(4, 27.5), pt(7.5, 39), pt(0, 45), pt(-7.5, 39)]); blade.closeSubpath()
            c.fill(blade, with: .color(hex(0x30448c)))
            var stripes = c
            stripes.clip(to: blade)
            for y in [33.0, 40] {
                stripes.stroke(line(pt(-9, y + 3), pt(9, y - 3)), with: .color(.white.opacity(0.28)), lineWidth: 1.8)
            }
        case .medaille:
            var l = Path()
            l.addLines([pt(-15, 19), pt(-7.5, 19), pt(1.5, 32), pt(-3, 34)]); l.closeSubpath()
            c.fill(l, with: .color(hex(0x2e68d2)))
            c.fill(mirrored(l), with: .color(hex(0xd63b42)))
            let medal = oval(0, 36, 8, 8)
            c.fill(medal, with: .color(hex(0xf2c232)))
            c.stroke(medal, with: .color(hex(0xc2911a)), lineWidth: 1.6)
            c.fill(star(0, 36, 4, 1.8), with: .color(hex(0xc2911a)))
        }
    }

    private static func star(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ r2: CGFloat) -> Path {
        var p = Path()
        for i in 0..<10 {
            let a = Double(i) * .pi / 5 - .pi / 2
            let rad = i.isMultiple(of: 2) ? r : r2
            let q = pt(cx + rad * cos(a), cy + rad * sin(a))
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
        return p
    }

    // MARK: - Expressions (au repos ; « Doux » est dessiné directement par MascotFigure)

    static func face(_ c: inout GraphicsContext, _ f: MascotLook.Face, blink: Bool, skin: Color, cheek: Color) {
        func eye(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            let hh = blink ? h * 0.1 : h
            c.fill(rr(cx - w / 2, cy - hh / 2, w, hh, min(w, hh) / 2), with: .color(ink))
            if !blink { c.fill(oval(cx + 1.5, cy - h * 0.175, w * 0.19, w * 0.19), with: .color(.white.opacity(0.92))) }
        }
        let bigCheeks = f == .timide
        for s in [-1.0, 1.0] {
            c.fill(oval(s * 30, 10, bigCheeks ? 10 : 8, bigCheeks ? 5.5 : 4), with: .color(cheek.opacity(bigCheeks ? 0.85 : 0.55)))
        }
        switch f {
        case .doux:
            break
        case .rieur:
            eye(-17, -5, 12, 20); eye(17, -5, 12, 20)
            var m = Path()
            m.move(to: pt(-10.5, 12))
            m.addQuadCurve(to: pt(10.5, 12), control: pt(0, 15))
            m.addCurve(to: pt(0, 25), control1: pt(10.5, 20), control2: pt(5.5, 25))
            m.addCurve(to: pt(-10.5, 12), control1: pt(-5.5, 25), control2: pt(-10.5, 20))
            m.closeSubpath()
            c.fill(m, with: .color(ink))
            var t = c
            t.clip(to: m)
            t.fill(oval(0, 24, 6, 4), with: .color(cheek))
        case .malin:
            eye(-17, -5, 12, 20); eye(17, -5, 12, 20)
            var brow = Path()
            brow.move(to: pt(10, -21)); brow.addQuadCurve(to: pt(25, -22), control: pt(17, -28.5))
            c.stroke(brow, with: .color(ink), style: round(3))
            c.stroke(line(pt(-25, -19.5), pt(-10, -18.5)), with: .color(ink), style: round(3))
            var m = Path()
            m.move(to: pt(-8, 16.5)); m.addQuadCurve(to: pt(11, 12.5), control: pt(3, 21.5))
            c.stroke(m, with: .color(ink), style: round(3.5))
        case .timide:
            eye(-16, -3, 10.5, 14); eye(16, -3, 10.5, 14)
            var m = Path()
            m.move(to: pt(-4.5, 16.5)); m.addQuadCurve(to: pt(4.5, 16.5), control: pt(0, 20))
            c.stroke(m, with: .color(ink), style: round(3))
        case .cool:
            eye(-17, -5, 12, 20); eye(17, -5, 12, 20)
            for s in [-1.0, 1.0] {
                c.fill(rr(s * 17 - 8, -17.5, 16, 12, 0), with: .color(skin))
                c.stroke(line(pt(s * 17 - 7.5, -5.5), pt(s * 17 + 7.5, -5.5)), with: .color(ink), style: round(3))
            }
            var m = Path()
            m.move(to: pt(-9, 16)); m.addQuadCurve(to: pt(9, 15), control: pt(0, 20.5))
            c.stroke(m, with: .color(ink), style: round(3.5))
        }
    }

    // MARK: - Véhicules (vue de face) : derrière le corps (cabine) puis devant (calandre)

    private struct Paint {
        let body: Color
        let edge: Color
        let hi: Color
        let light: Bool
        init(_ r: MascotLook.Ride) {
            body = r.color
            light = r.isLight
            edge = r.isLight ? MascotDrawing.ink.opacity(0.4) : .white.opacity(0.28)
            hi = r.isLight ? MascotDrawing.ink.opacity(0.14) : .white.opacity(0.13)
        }
    }

    private static let tire = Color.mascotHex(0x0c0d11)
    private static let bumper = Color.mascotHex(0x2a2d38)
    private static let amber = Color.mascotHex(0xff9f0a)
    private static let beacon = Color.mascotHex(0xff8a00)

    /// La cabine (montants, toit, rétroviseurs) : dessinée derrière le corps. Rien pour la voiture.
    static func vehicleBack(_ c: inout GraphicsContext, _ kind: Vehicle.Kind, _ ride: MascotLook.Ride, flash: Bool?) {
        guard kind != .car else { return }
        let p = Paint(ride)
        // pare-brise : un voile clair et un reflet
        let glass = rr(-58, -73, 116, 96, 12)
        c.fill(glass, with: .color(hex(0xbfd3e6, 0.14)))
        var reflet = c
        reflet.clip(to: glass)
        reflet.stroke(line(pt(-36, -73), pt(-60, -30)), with: .color(.white.opacity(0.1)), lineWidth: 9)
        // rétroviseurs
        for s in [-1.0, 1.0] {
            c.stroke(line(pt(s * 64, -36), pt(s * 76, -40)), with: .color(bumper), style: round(3))
            let m = rr(s * 78 - 5, -54, 10, 25, 3.5)
            c.fill(m, with: .color(hex(0x1e2028)))
            c.stroke(m, with: .color(.white.opacity(0.2)), lineWidth: 1.2)
        }
        // montants
        for s in [-1.0, 1.0] {
            let post = rr(s * 61 - 4.5, -76, 9, 104, 4.5)
            c.fill(post, with: .color(p.body))
            c.fill(post, with: .color(.black.opacity(0.18)))
        }
        // déflecteur du semi-remorque
        if kind == .heavy {
            var d = Path()
            d.move(to: pt(-50, -80))
            d.addCurve(to: pt(50, -80), control1: pt(-46, -101), control2: pt(46, -101))
            d.closeSubpath()
            c.fill(d, with: .color(p.body))
            c.fill(d, with: .color(.black.opacity(0.1)))
            c.stroke(line(pt(-30, -92), pt(30, -92)), with: .color(p.hi), style: round(2))
        }
        // toit
        let roof = rr(-69, -84, 138, 13, 6.5)
        c.fill(roof, with: .color(p.body))
        c.stroke(roof, with: .color(p.edge), lineWidth: 1.4)
        let markers: [CGFloat] = kind == .truck ? [-46, 46] : [-44, -22, 0, 22, 44]
        for x in markers { c.fill(rr(x - 3.5, -79.5, 7, 4, 2), with: .color(amber)) }
        // convoi exceptionnel : panneau jaune et deux gyrophares orange qui clignotent en alternance
        if kind == .superheavy {
            let sign = rr(-46, -102, 92, 16, 3)
            c.fill(rr(-1.5, -87, 3, 4, 0), with: .color(bumper))
            c.fill(sign, with: .color(hex(0xffc400)))
            c.stroke(sign, with: .color(ink), lineWidth: 1.6)
            c.draw(Text("CONVOI EXCEPTIONNEL").font(.system(size: 6, weight: .black)).foregroundColor(ink), at: pt(0, -94))
            for s in [-1.0, 1.0] {
                let on = flash.map { s < 0 ? $0 : !$0 } ?? true
                let x = s * 57
                if on && flash != nil {
                    c.drawLayer { g in
                        g.addFilter(.blur(radius: 5))
                        g.fill(oval(x, -94, 15, 13), with: .color(beacon.opacity(0.7)))
                    }
                }
                c.fill(rr(x - 7.5, -90, 15, 6, 2), with: .color(bumper))
                let dome = rr(x - 6, -101, 12, 13, 6)
                c.fill(dome, with: .color(on ? hex(0xffa526) : hex(0xb35a00)))
                c.fill(rr(x - 3.5, -98.5, 3, 6, 1.5), with: .color(.white.opacity(on ? 0.75 : 0.25)))
            }
        }
    }

    /// Le devant : coque de la petite voiture, ou calandre de camion (porteur, semi, convoi).
    static func vehicleFront(_ c: inout GraphicsContext, _ kind: Vehicle.Kind, _ ride: MascotLook.Ride) {
        let p = Paint(ride)
        let lamp = Color.white.opacity(0.95)
        if kind == .car {
            for s in [-1.0, 1.0] { c.fill(rr(s * 46 - 11, 44, 22, 16, 6), with: .color(tire)) }
            let shell = rr(-62, 22, 124, 32, 16)
            c.fill(shell, with: .color(p.body))
            c.stroke(shell, with: .color(p.edge), lineWidth: 1.6)
            c.fill(rr(-40, 27, 80, 4, 2), with: .color(p.hi))
            for s in [-1.0, 1.0] {
                let l = oval(s * 44, 38, 5, 5)
                c.fill(l, with: .color(lamp))
                if p.light { c.stroke(l, with: .color(ink.opacity(0.45)), lineWidth: 1.2) }
            }
            c.fill(rr(-14, 38, 28, 7, 3.5), with: .color(p.light ? ink.opacity(0.16) : .white.opacity(0.1)))
            return
        }
        for s in [-1.0, 1.0] { c.fill(rr(s * 52 - 14, 46, 28, 21, 7), with: .color(tire)) }
        let shell = rr(-66, 22, 132, 35, 12)
        c.fill(shell, with: .color(p.body))
        c.stroke(shell, with: .color(p.edge), lineWidth: 1.6)
        c.fill(rr(-46, 26, 92, 3, 1.5), with: .color(p.hi))
        // calandre : plus large et plus haute pour les gros
        let big = kind != .truck
        let grille = big ? rr(-28, 30.5, 56, 19.5, 4) : rr(-23, 31.5, 46, 17, 4)
        c.fill(grille, with: .color(p.light ? ink.opacity(0.78) : .black.opacity(0.42)))
        let slats: [CGFloat] = big ? [34.5, 38.5, 42.5, 46.5] : [36, 40.5, 45]
        for y in slats {
            c.stroke(line(pt(big ? -23 : -18.5, y), pt(big ? 23 : 18.5, y)), with: .color(.white.opacity(0.17)), style: round(1.6))
        }
        for s in [-1.0, 1.0] {
            let l = rr(s * 49 - 9, 31, 18, 9, 3.5)
            c.fill(l, with: .color(lamp))
            if p.light { c.stroke(l, with: .color(ink.opacity(0.45)), lineWidth: 1.2) }
            c.fill(rr(s * 49 - 9, 42.5, 18, 3.5, 1.75), with: .color(amber))
        }
        let bar = rr(-68, 51.5, 136, 9.5, 4.75)
        c.fill(bar, with: .color(bumper))
        if kind == .superheavy {
            // pare-chocs rayé rouge et blanc (gabarit hors norme)
            var h = c
            h.clip(to: bar)
            h.fill(bar, with: .color(.white.opacity(0.92)))
            var x: CGFloat = -80
            while x < 80 {
                var band = Path()
                band.addLines([pt(x, 62), pt(x + 7, 62), pt(x + 15, 50), pt(x + 8, 50)]); band.closeSubpath()
                h.fill(band, with: .color(hex(0xe5383b)))
                x += 14
            }
        }
    }
}
