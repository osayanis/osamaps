import SwiftUI
import CoreLocation
import Observation

/// Accueil au premier lancement (slot overlay, tant que `Prefs.onboarded` est faux).
/// Écrans courts : merci → ce que fait OsaMaps → « Tu conduis quoi ? » (→ dimensions pour les camions)
/// → autorisations (expliquées AVANT d'être demandées) → pseudo, puis la carte. Glisser à gauche/droite, ou les boutons.
/// « Revoir l'accueil » (réglages) remet onboarded à faux.
/// Tests : `-shellOnboarding YES` l'affiche sans toucher aux préférences, `-shellOnboardingStep 2` ouvre l'écran 3.
struct ShellOnboarding: View {
    var onDone: () -> Void = {}
    @Environment(Prefs.self) private var prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Int = {
        let n = UserDefaults.standard.integer(forKey: "shellOnboardingStep")
        return (0..<6).contains(n) ? n : 0
    }()
    @State private var forward = true
    @State private var name = Identity.nickname
    @State private var leaving = false
    @FocusState private var nameFocused: Bool

    enum Page: Hashable { case welcome, features, vehicle, dimensions, permissions, nickname }

    /// Les dimensions ne sont demandées qu'aux camions.
    private var pages: [Page] {
        prefs.vehicle.isTruck ? [.welcome, .features, .vehicle, .dimensions, .permissions, .nickname]
                              : [.welcome, .features, .vehicle, .permissions, .nickname]
    }
    private var count: Int { pages.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                page(pages[min(step, count - 1)])
                    .id(step)
                    .transition(pageTransition)
            }
            .frame(maxWidth: 520, maxHeight: .infinity)
            .padding(.horizontal, 24)
            footer
        }
        .background(Osa.bg.ignoresSafeArea())
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                    go(step + (dx < 0 ? 1 : -1))
                }
        )
        .opacity(leaving ? 0 : 1)
        .scaleEffect(leaving && !reduceMotion ? 1.03 : 1)
        .accessibilityAddTraits(.isModal)
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
            removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)
        )
    }

    // MARK: - Haut et bas

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.white : i < step ? Color.white.opacity(0.5) : Color.white.opacity(0.18))
                        .frame(width: i == step ? 22 : 7, height: 7)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { go(i) }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Étape \(step + 1) sur \(count)")
            Spacer()
            if step < count - 1 {
                Button("Passer") { go(count - 1) }
                    .font(.osa(15, .semibold))
                    .foregroundStyle(Osa.dim)
                    .frame(minHeight: 44)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .animation(Osa.anim, value: step)
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button { go(step - 1) } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Retour") }
                }
                .font(.osa(16, .semibold))
                .foregroundStyle(Osa.dim)
                .frame(minHeight: 48)
                .transition(.opacity)
            }
            Spacer()
            Button(action: next) {
                HStack(spacing: 6) {
                    Text(step == count - 1 ? "C’est parti" : "Continuer")
                    Image(systemName: step == count - 1 ? "arrow.right" : "chevron.right")
                }
                .contentTransition(.opacity)
            }
            .buttonStyle(.osaPill)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .animation(Osa.anim, value: step)
    }

    @ViewBuilder private func page(_ p: Page) -> some View {
        switch p {
        case .welcome: ShellObWelcome()
        case .features: ShellObFeatures()
        case .vehicle: ShellObVehicle()
        case .dimensions: ShellObDimensions()
        case .permissions: ShellObPermissions()
        case .nickname: ShellObNickname(name: $name, focused: $nameFocused, onSubmit: finish)
        }
    }

    // MARK: - Navigation

    private func go(_ n: Int) {
        guard n >= 0, n < count, n != step else { return }
        nameFocused = false
        forward = n > step
        Haptic.play("light")
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.32)) { step = n }
    }

    private func next() { step == count - 1 ? finish() : go(step + 1) }

    private func finish() {
        nameFocused = false
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { Identity.nickname = trimmed }
        Haptic.play("success")
        withAnimation(.easeIn(duration: reduceMotion ? 0.15 : 0.26)) { leaving = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 260))
            // passer l'accueil vaut choix (voiture par défaut) : la question ne revient pas en feuille
            if !prefs.vehicleChosen { prefs.vehicleChosen = true }
            if !prefs.onboarded { prefs.onboarded = true }
            onDone()
        }
    }
}

// MARK: - Apparitions

/// Apparition douce (montée + flou), décalée de `delay` secondes.
private struct ShellReveal: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .blur(radius: shown || reduceMotion ? 0 : 5)
            .onAppear {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.45).delay(delay)) { shown = true }
            }
    }
}

private extension View {
    func shellReveal(_ delay: Double) -> some View { modifier(ShellReveal(delay: delay)) }
}

/// Titre qui apparaît mot par mot (les deux derniers mots restent ensemble).
private struct ShellObTitle: View {
    let text: String
    var start: Double = 0
    var size: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        var words = text.split(separator: " ").map(String.init)
        if words.count >= 4 { let last = words.removeLast(); words[words.count - 1] += "\u{00a0}" + last }
        return ShellFlow(spacing: size * 0.26, lineSpacing: 2) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                Text(w)
                    .font(.osa(size, .bold))
                    .foregroundStyle(Osa.text)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown || reduceMotion ? 0 : size * 0.3)
                    .blur(radius: shown || reduceMotion ? 0 : 6)
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.45).delay(start + Double(i) * 0.055), value: shown)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
        .onAppear { shown = true }
    }
}

/// Mise en ligne simple avec retour à la ligne (pour les titres mot par mot).
private struct ShellFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + row.height - s.height), proposal: .unspecified)
                x += s.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? s.width : rows[rows.count - 1].width + spacing + s.width
            if extra > maxWidth && !rows[rows.count - 1].items.isEmpty {
                rows.append(Row(items: [i], width: s.width, height: s.height))
            } else {
                rows[rows.count - 1].items.append(i)
                rows[rows.count - 1].width = extra
                rows[rows.count - 1].height = max(rows[rows.count - 1].height, s.height)
            }
        }
        return rows
    }
}

// MARK: - Écrans

private struct ShellObWelcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            ShellMark(size: 88)
            ShellObTitle(text: "Merci d’utiliser la suite Osa.", start: 0.15, size: 40)
            Text("OsaMaps, c’est la route façon Osa : simple, rapide, et partagée avec celles et ceux qui roulent autour de toi.")
                .font(.osa(17, .medium))
                .foregroundStyle(Osa.dim)
                .fixedSize(horizontal: false, vertical: true)
                .shellReveal(0.55)
            HStack(spacing: 6) {
                Image(systemName: "heart.fill").font(.system(size: 11))
                Text("OsaLabs")
            }
            .font(.osa(13, .semibold))
            .foregroundStyle(Osa.faint)
            .shellReveal(0.75)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShellObItem: View {
    let icon: String
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Osa.text)
                .frame(width: 40, height: 40)
                .background(Osa.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.osa(16, .bold)).foregroundStyle(Osa.text)
                Text(text).font(.osa(14, .regular)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .osaCard()
        .accessibilityElement(children: .combine)
    }
}

private struct ShellObFeatures: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                ShellObTitle(text: "Une carte qui roule avec toi.")
                VStack(spacing: 10) {
                    ShellObItem(icon: "arrow.triangle.turn.up.right.diamond.fill", title: "Itinéraires et guidage vocal",
                                text: "Le chemin le plus rapide, annoncé à voix haute. Péages et autoroutes à éviter si tu préfères.")
                        .shellReveal(0.25)
                    ShellObItem(icon: "flag.fill", title: "Signalé par la communauté",
                                text: "Police, accident, travaux, bouchon : un appui suffit pour prévenir les autres.")
                        .shellReveal(0.33)
                    ShellObItem(icon: "person.2.fill", title: "Tes amis sur la carte",
                                text: "Partage ta position avec qui tu veux, seulement quand tu le décides.")
                        .shellReveal(0.41)
                    ShellObItem(icon: "mic.fill", title: "Siri au volant",
                                text: "« Rentrer à la maison avec OsaMaps », « Signaler la police avec OsaMaps ».")
                        .shellReveal(0.49)
                }
            }
            .padding(.vertical, 24)
        }
    }
}

/// Suit l'autorisation de position (Location n'est pas observable : petit gestionnaire à part).
@MainActor
@Observable
final class ShellLocationAuth: NSObject, CLLocationManagerDelegate {
    static let shared = ShellLocationAuth()
    var status: CLAuthorizationStatus
    var asking = false
    @ObservationIgnored private let manager = CLLocationManager()

    private override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        Task { @MainActor in
            if s != .notDetermined && self.status == .notDetermined && (s == .authorizedWhenInUse || s == .authorizedAlways) {
                Haptic.play("success")
            }
            self.status = s
            if s != .notDetermined { self.asking = false }
        }
    }
}

private struct ShellObVehicle: View {
    @Environment(Prefs.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                ShellObTitle(text: "Tu conduis quoi\u{00a0}?")
                Text("Itinéraires, limitations de vitesse et alertes s’adaptent à ton véhicule.")
                    .font(.osa(15, .medium)).foregroundStyle(Osa.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .shellReveal(0.2)
                ShellVehicleKindGrid(vehicle: $prefs.vehicle) { _ in
                    if !prefs.vehicleChosen { prefs.vehicleChosen = true }
                }
                .shellReveal(0.3)
                Text("Tout se change plus tard dans les réglages.")
                    .font(.osa(13, .medium)).foregroundStyle(Osa.faint)
                    .shellReveal(0.4)
            }
            .padding(.vertical, 24)
        }
    }
}

private struct ShellObDimensions: View {
    @Environment(Prefs.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ShellObTitle(text: "Ton \(prefs.vehicle.kind.label.lowercased()), en chiffres.", size: 30)
                Text("Pré-rempli avec les valeurs habituelles : ajuste-les pour éviter ponts bas et routes limitées en tonnage.")
                    .font(.osa(15, .medium)).foregroundStyle(Osa.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .shellReveal(0.2)
                ShellVehicleDimensions(vehicle: $prefs.vehicle)
                    .shellReveal(0.3)
                if prefs.vehicle.kind == .superheavy {
                    ShellVehicleConvoyNote().shellReveal(0.4)
                }
            }
            .padding(.vertical, 24)
        }
    }
}

private struct ShellObPermissions: View {
    @Environment(Prefs.self) private var prefs
    @Environment(\.openURL) private var openURL
    private var auth: ShellLocationAuth { .shared }

    var body: some View {
        @Bindable var prefs = prefs
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                ShellObTitle(text: "Deux choses, expliquées avant.")
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 14) {
                        icon("location.fill")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ta position").font(.osa(16, .bold)).foregroundStyle(Osa.text)
                            Text("Pour te situer sur la carte et te guider. Ce que tu partages ensuite, c’est toi qui choisis.")
                                .font(.osa(14, .regular)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
                            locationAction.padding(.top, 8)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .osaCard()
                    .shellReveal(0.25)

                    HStack(alignment: .top, spacing: 14) {
                        icon("gauge.with.needle.fill")
                        VStack(alignment: .leading, spacing: 4) {
                            // l'interrupteur sur la ligne du titre : le texte garde toute la largeur
                            HStack(alignment: .center, spacing: 10) {
                                Text("Aider le trafic, anonymement").font(.osa(16, .bold)).foregroundStyle(Osa.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Toggle("Contribuer au trafic", isOn: $prefs.contributeTraffic)
                                    .labelsHidden().tint(Osa.ok)
                                    .onChange(of: prefs.contributeTraffic) { _, _ in Haptic.play("light") }
                            }
                            Text("Ta vitesse est envoyée sans ton pseudo, pour colorer les routes en vert, orange ou rouge pour tout le monde.")
                                .font(.osa(14, .regular)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .osaCard()
                    .shellReveal(0.35)
                }
                Text("Tout se change plus tard dans les réglages.")
                    .font(.osa(13, .medium)).foregroundStyle(Osa.faint)
                    .shellReveal(0.45)
            }
            .padding(.vertical, 24)
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Osa.text)
            .frame(width: 40, height: 40)
            .background(Osa.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var locationAction: some View {
        if Location.shared.simulated {
            state("checkmark.circle.fill", "Position simulée (test)", Osa.ok)
        } else {
            switch auth.status {
            case .authorizedWhenInUse, .authorizedAlways:
                state("checkmark.circle.fill", "Autorisée", Osa.ok)
            case .denied, .restricted:
                VStack(alignment: .leading, spacing: 8) {
                    state("exclamationmark.triangle.fill", "Refusée — tu peux la réactiver dans Réglages", Osa.danger)
                    Button("Ouvrir les Réglages") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
                    }
                    .buttonStyle(.osaPillSecondary)
                }
            default:
                Button(auth.asking ? "En attente…" : "Autoriser ma position") {
                    auth.asking = true
                    Location.shared.requestAndStart()
                }
                .buttonStyle(.osaPill)
                .disabled(auth.asking)
            }
        }
    }

    private func state(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).foregroundStyle(Osa.text)
        }
        .font(.osa(14, .semibold))
        .transition(.opacity)
    }
}

private struct ShellObNickname: View {
    @Binding var name: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    private let code = Identity.friendCode

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                ShellObTitle(text: "Comment on t’appelle\u{00a0}?")
                VStack(alignment: .leading, spacing: 8) {
                    TextField("", text: $name, prompt: Text("Ton pseudo").foregroundStyle(Osa.faint))
                        .font(.osa(22, .bold))
                        .foregroundStyle(Osa.text)
                        .textContentType(.nickname)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused(focused)
                        .onSubmit(onSubmit)
                        .onChange(of: name) { _, v in if v.count > 24 { name = String(v.prefix(24)) } }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .osaCard()
                        .accessibilityLabel("Ton pseudo")
                    Text("C’est le nom que verront tes amis. Tu peux laisser vide et le choisir plus tard.")
                        .font(.osa(14, .regular)).foregroundStyle(Osa.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .shellReveal(0.25)
                HStack {
                    Text("Ton code ami").font(.osa(15, .semibold)).foregroundStyle(Osa.dim)
                    Spacer()
                    Text("\(code.prefix(3)) \(code.suffix(3))")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(Osa.text)
                }
                .padding(16)
                .osaCard()
                .accessibilityElement(children: .combine)
                .shellReveal(0.35)
            }
            .padding(.vertical, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}
