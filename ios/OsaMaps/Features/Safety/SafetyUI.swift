import SwiftUI

// MARK: - HUD (conduite)

/// Bandeau « Zone de danger — reste attentif » tant qu'on est dans une zone.
struct SafetyHud: View {
    @State private var engine = SafetyEngine.shared
    @State private var settings = SafetySettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let z = engine.inside, settings.dangerZones {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(Osa.danger, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zone de danger — reste attentif")
                            .font(.osa(17, .bold))
                            .foregroundStyle(Osa.text)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        Text("encore \(Geo.formatDistance(max(0, z.end - engine.along)))")
                            .font(.osa(14, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Osa.dim)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: 560)
                .osaGlass(Osa.radiusM)
                .overlay(RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous).strokeBorder(Osa.danger.opacity(0.45)))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Osa.anim, value: engine.inside?.id)
    }
}

// MARK: - Aperçu d'itinéraire : ZFE

/// Carte « Ce trajet traverse une ZFE » au-dessus du panneau d'aperçu (seulement si utile pour TA vignette).
struct SafetyZfeCard: View {
    @Environment(Core.self) private var core
    @State private var engine = SafetyEngine.shared
    @State private var settings = SafetySettings.shared

    var body: some View {
        if core.mode == .preview, core.panel == nil, settings.zfe, let info {
            Button { if info.forbidden == nil { core.settingsOpen = true } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(info.forbidden == true ? .black : Osa.text)
                        .frame(width: 38, height: 38)
                        .background(info.forbidden == true ? AnyShapeStyle(Osa.danger) : AnyShapeStyle(Osa.surfaceHi),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title).font(.osa(15, .bold)).foregroundStyle(Osa.text)
                        Text(info.detail).font(.osa(13, .medium)).foregroundStyle(Osa.dim).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if info.forbidden == nil {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Osa.faint)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .osaGlass(Osa.radiusM)
                .overlay {
                    if info.forbidden == true {
                        RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous).strokeBorder(Osa.danger.opacity(0.45))
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .transition(.opacity)
        }
    }

    private var info: (title: String, detail: String, forbidden: Bool?)? {
        let restricted = engine.zfe.filter { $0.props.vp != nil }
        guard !restricted.isEmpty else { return nil }
        let mine = settings.critair
        if restricted.allSatisfy({ mine.forbidden(firstForbidden: $0.props.vp) == false }) { return nil }
        let z = restricted.first { mine.forbidden(firstForbidden: $0.props.vp) == true } ?? restricted[0]
        let forbidden = mine.forbidden(firstForbidden: z.props.vp)
        var detail = z.props.name
        if let h = SafetyGeo.hoursFr(z.props.hours) { detail += " · \(h)" }
        if forbidden == nil { detail += " · règle ta vignette dans Réglages" }
        let title = forbidden == true ? "\(mine.label) non autorisée dans la ZFE" : "Ce trajet traverse une ZFE"
        return (title, detail, forbidden)
    }
}

// MARK: - « Tu es passager ? »

struct SafetyPassengerOverlay: View {
    @State private var passenger = SafetyPassenger.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            if passenger.open {
                Color.black.opacity(0.45).ignoresSafeArea().transition(.opacity)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Tu es passager ?").font(.osa(22, .heavy)).foregroundStyle(Osa.text)
                        .padding(.bottom, 6)
                    Text("Le véhicule roule. Si c'est toi qui conduis, garde les yeux sur la route : la saisie attendra l'arrêt.")
                        .font(.osa(15, .regular)).foregroundStyle(Osa.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 18)
                    VStack(spacing: 10) {
                        Button { passenger.reply(.passenger) } label: {
                            Text("Oui, je suis passager").frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.osaPill)
                        Button { passenger.reply(.driver) } label: {
                            Text("Non, je conduis").frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.osaPillSecondary)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 18)
                .frame(maxWidth: 520)
                .osaGlass()
                .padding(.horizontal, 12).padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(Osa.anim, value: passenger.open)
        .allowsHitTesting(passenger.open)
    }
}

// MARK: - Réglages

/// Interrupteur sobre : capsule blanche + pastille noire quand activé (comme la version web).
struct SafetyToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                Capsule()
                    .fill(configuration.isOn ? Osa.text : Osa.surfaceHi)
                    .overlay(Capsule().strokeBorder(configuration.isOn ? .clear : Osa.lineHi))
                    .frame(width: 48, height: 29)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(configuration.isOn ? Osa.bg : Osa.dim).frame(width: 21, height: 21).padding(4)
                    }
                    .animation(.easeOut(duration: 0.18), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "activé" : "désactivé")
    }
}

struct SafetySettingsSection: View {
    @State private var s = SafetySettings.shared
    @State private var status: String?

    private struct Item { var key: ReferenceWritableKeyPath<SafetySettings, Bool>; var label: String; var hint: String? }
    private let items: [Item] = [
        .init(key: \.dangerZones, label: "Zones de danger", hint: "300 m en ville, 2 km sur route, 4 km sur autoroute"),
        .init(key: \.zfe, label: "Zones à faibles émissions", hint: nil),
        .init(key: \.curves, label: "Virages serrés", hint: nil),
        .init(key: \.levelCrossings, label: "Passages à niveau", hint: nil),
        .init(key: \.schools, label: "Abords d'écoles", hint: "en semaine, de 7 h à 19 h"),
        .init(key: \.night, label: "Rappel de fatigue la nuit", hint: "entre 1 h et 5 h"),
        .init(key: \.passenger, label: "Demander « Tu es passager ? »", hint: "quand tu tapes en roulant"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sécurité routière").font(.osa(17, .bold)).foregroundStyle(Osa.text).padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vignette Crit'Air").font(.osa(15, .semibold)).foregroundStyle(Osa.text)
                    Text("\(s.critair.label) · pour les alertes ZFE").font(.osa(12.5, .regular)).foregroundStyle(Osa.faint)
                }
                HStack(spacing: 6) {
                    ForEach(SafetyCritAir.allCases, id: \.self) { c in
                        let on = s.critair == c
                        Button { s.critair = c; Haptic.play("light") } label: {
                            Text(c.short)
                                .font(.osa(14, .bold))
                                .foregroundStyle(on ? .black : Osa.text)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(on ? AnyShapeStyle(Osa.text) : AnyShapeStyle(Osa.surface),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? .clear : Osa.line))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.label)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(Osa.line).frame(height: 1) }

            ForEach(items, id: \.label) { item in
                Toggle(isOn: Binding(get: { s[keyPath: item.key] }, set: { s[keyPath: item.key] = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label).font(.osa(15, .semibold)).foregroundStyle(Osa.text)
                        if let h = item.hint { Text(h).font(.osa(12.5, .regular)).foregroundStyle(Osa.faint) }
                    }
                }
                .toggleStyle(SafetyToggleStyle())
                .frame(minHeight: 52)
                .overlay(alignment: .top) { Rectangle().fill(Osa.line).frame(height: 1) }
            }

            if let status {
                Text(status)
                    .font(.osa(13, .medium)).foregroundStyle(Osa.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous).strokeBorder(Osa.danger.opacity(0.35)))
                    .padding(.top, 10)
            }
            Text("Conformément à la loi (décret n° 2012-3, art. R413-15 du Code de la route), OsaMaps ne montre jamais l'emplacement des radars : seulement des zones de danger, d'après la liste publique des radars fixes (data.gouv.fr). Périmètres ZFE : base nationale de transport.data.gouv.fr. Passages à niveau et écoles : OpenStreetMap.")
                .font(.osa(12, .regular)).foregroundStyle(Osa.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .padding(16)
        .osaCard()
        .task { await checkData() }
    }

    /// Dit honnêtement si les données publiques ne sont pas disponibles côté serveur.
    private func checkData() async {
        async let z = try? SafetyData.zones((w: 2.3, s: 46.5, e: 2.4, n: 46.6))
        async let f = try? SafetyData.zfe()
        let (zr, fr) = await (z, f)
        var missing: [String] = []
        if zr?.available != true { missing.append("zones de danger") }
        if fr?.available != true { missing.append("ZFE") }
        status = missing.isEmpty ? nil
            : "Données indisponibles pour le moment : \(missing.joined(separator: " et ")). Les autres alertes fonctionnent."
    }
}
