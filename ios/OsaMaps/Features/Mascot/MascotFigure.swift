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
    /// Apparence choisie (couleur, chapeau, lunettes, visage, cou, couleur du véhicule).
    var style: MascotLook = .standard
    /// Véhicule de conduite (voiture → petite voiture ; camion, poids lourd, super lourd → cabine de camion).
    var vehicle: Vehicle.Kind = .car
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
    private var light: Color { style.body.tones.light }
    private var shade: Color { style.body.tones.shade }
    private var low: Color { style.body.tones.low }
    private var cheek: Color { Self.cheek }
    /// Le visage « Doux » et toutes les émotions du moment sont dessinés en SwiftUI ; les autres expressions au repos, en Canvas.
    private var customFace: Bool { mood == .calm && style.face != .doux }
    /// Gyrophares du convoi exceptionnel.
    private var beacons: Bool { kart && vehicle == .superheavy }

    private var moves: Bool { animated && !reduceMotion }
    /// Largeur du corps.
    private var w: CGFloat { head ? size * 100 / 124 : size }
    /// Une unité du repère web (corps = 100).
    private var u: CGFloat { w / 100 }

    var body: some View {
        let w = self.w, h = w * 0.92
        ZStack {
            Ellipse().fill(.black.opacity(0.55))
                .frame(width: kart ? (vehicle == .car ? w * 1.28 : w * 1.45) : w * 0.85, height: w * 0.12).blur(radius: w * 0.03).offset(y: h * 0.56)
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
        .animation(.easeOut(duration: 0.25), value: vehicle)
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
        let st = style, kind = vehicle
        return ZStack {
            if kart && kind != .car {
                if beacons && moves {
                    TimelineView(.periodic(from: .now, by: 0.42)) { tl in
                        let on = Int(tl.date.timeIntervalSinceReferenceDate / 0.42).isMultiple(of: 2)
                        units { MascotDrawing.vehicleBack(&$0, kind, st.ride, flash: on) }
                    }
                    .transition(.opacity)
                } else {
                    units { MascotDrawing.vehicleBack(&$0, kind, st.ride, flash: nil) }.transition(.opacity)
                }
            }
            if !kart {
                ForEach([-1.0, 1.0], id: \.self) { s in
                    Ellipse().fill(LinearGradient(colors: [shade, low], startPoint: .top, endPoint: .bottom))
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
                if customFace {
                    let b = blink, skin = light, ck = cheek
                    units { MascotDrawing.face(&$0, st.face, blink: b, skin: skin, cheek: ck) }
                } else {
                    face
                }
                if st.glasses != .none { units { MascotDrawing.glasses(&$0, st.glasses) } }
            }
            .offset(x: look.width * w * 0.05, y: look.height * w * 0.035)
            // camions : le cou passe derrière la calandre ; petite voiture : par-dessus (comme avant)
            if kart && kind != .car && st.neck != .none { units { MascotDrawing.neck(&$0, st.neck) } }
            if kart { units { MascotDrawing.vehicleFront(&$0, kind, st.ride) }.transition(.opacity) }
            if (!kart || kind == .car) && st.neck != .none { units { MascotDrawing.neck(&$0, st.neck) } }
            if st.hat != .none { units { MascotDrawing.hat(&$0, st.hat) } }
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
        .frame(width: 220 * u, height: 220 * u)
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
