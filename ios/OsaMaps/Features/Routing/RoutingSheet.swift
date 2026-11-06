import SwiftUI

/// Panneau d'aperçu (port de `RoutingSheet.tsx`) : visible en mode `.preview` quand aucun autre panneau n'est ouvert.
struct RoutingSheet: View {
    @Environment(Core.self) private var core
    var body: some View {
        if core.mode == .preview && core.panel == nil {
            RoutingPreviewSheet()
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct RoutingPreviewSheet: View {
    @Environment(Core.self) private var core
    @Environment(Prefs.self) private var prefs
    @State private var model = RoutingModel.shared
    @State private var bodyHeight: CGFloat = 0
    /// Hauteur de l'écran : la zone des cartes ne doit jamais manger la carte (petits iPhone).
    @State private var screenHeight: CGFloat = 800
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var anim: Animation? { reduceMotion ? nil : Osa.anim }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(Osa.lineHi).frame(width: 36, height: 5).frame(maxWidth: .infinity)
            header
            ScrollView {
                content
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bodyHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(bodyHeight, max(130, min(330, screenHeight * 0.34))))
            chips
            goButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .osaGlass()
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .onAppear {
            if let h = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height { screenHeight = h }
        }
        .animation(anim, value: model.section)
        .animation(anim, value: core.routes.map(\.id))
        .animation(anim, value: model.status)
    }

    // MARK: En-tête

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text((prefs.vehicle.isTruck ? "\(prefs.vehicle.kind.label) · " : "")
                     + (model.stops.isEmpty ? "Itinéraire vers" : "Via \(model.stops.count) étape\(model.stops.count > 1 ? "s" : ""), vers"))
                    .font(.osa(13, .semibold))
                    .foregroundStyle(Osa.dim)
                Text(core.destination?.name ?? "Destination")
                    .font(.osa(20, .bold))
                    .foregroundStyle(Osa.text)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { model.cancelPreview() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Osa.text)
                    .frame(width: 36, height: 36)
                    .background(Osa.surfaceHi, in: Circle())
                    .contentShape(Circle().inset(by: -6))
            }
            .accessibilityLabel("Annuler l'itinéraire")
        }
    }

    // MARK: Contenu

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.status == .loading && core.routes.isEmpty { RoutingSkeleton() }
            if model.status == .error {
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.error ?? "Le calcul a échoué.", systemImage: "exclamationmark.triangle")
                        .font(.osa(15, .semibold))
                        .foregroundStyle(Osa.text)
                    if model.retryable {
                        Button { model.computePreview() } label: { Label("Réessayer", systemImage: "arrow.clockwise") }
                            .buttonStyle(.osaPillSecondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .osaCard()
            }
            // avertissements poids lourds en premier : interdiction de circuler, convoi exceptionnel
            if model.section == nil, prefs.vehicle.isTruck, let r = core.route {
                RoutingTruckNotices(route: r, meta: model.meta[r.id], depart: model.depart, vehicle: prefs.vehicle)
            }
            if !core.routes.isEmpty {
                let fastest = core.routes.map(\.duration).min() ?? 0
                VStack(spacing: 6) {
                    // sous-panneau ouvert : seul l'itinéraire choisi reste visible (la carte garde de la place)
                    ForEach(Array(core.routes.enumerated()).filter { model.section == nil || $0.offset == core.activeRoute }, id: \.element.id) { i, r in
                        RoutingRouteCard(route: r, active: i == core.activeRoute, fastest: fastest,
                                         multiple: core.routes.count > 1, meta: model.meta[r.id], depart: model.depart) {
                            model.selectRoute(i)
                        }
                    }
                }
                .opacity(model.status == .loading ? 0.5 : 1)
                if model.section != nil {
                    EmptyView()
                } else if model.depart != nil && core.routes.count == 1 {
                    note("Avec une heure choisie, une seule proposition est calculée.")
                } else if !model.stops.isEmpty && core.routes.count == 1 {
                    note("Avec des étapes, une seule proposition est calculée.")
                }
            }
            if model.section == .depart {
                RoutingDepartPanel(model: model).transition(.opacity)
            }
            if model.section == .stops {
                RoutingStopsPanel(model: model).transition(.opacity)
            }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.osa(13, .medium)).foregroundStyle(Osa.faint)
    }

    // MARK: Options rapides

    private var chips: some View {
        @Bindable var prefs = prefs
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                RoutingChip(title: "Sans péage", icon: "eurosign.circle", on: prefs.avoidTolls) { prefs.avoidTolls.toggle() }
                RoutingChip(title: "Sans autoroute", icon: "road.lanes", on: prefs.avoidHighways) { prefs.avoidHighways.toggle() }
                RoutingChip(title: departTitle, icon: "clock", on: model.depart != nil, open: model.section == .depart) { toggle(.depart) }
                RoutingChip(title: model.stops.isEmpty ? "Ajouter un arrêt" : "Étapes (\(model.stops.count))", icon: "plus",
                            on: !model.stops.isEmpty, open: model.section == .stops) { toggle(.stops) }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    private var departTitle: String {
        guard let d = model.depart else { return "Partir plus tard" }
        return (d.type == 1 ? "Départ " : "Arrivée ") + RoutingTime.format(d.value)
    }

    private func toggle(_ s: RoutingModel.Section) {
        model.section = model.section == s ? nil : s
        model.pickOnMap = false
    }

    // MARK: C'est parti

    private var goButton: some View {
        let loading = model.status == .loading
        return Button { model.startDrive() } label: {
            Label(loading ? "Calcul en cours…" : model.depart != nil ? "Démarrer maintenant" : "C'est parti",
                  systemImage: loading ? "hourglass" : "location.north.fill")
                .font(.osa(17, .heavy))
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.osaPill)
        .disabled(core.route == nil || loading)
        .opacity(core.route == nil || loading ? 0.5 : 1)
    }
}

// MARK: - Carte d'itinéraire

private struct RoutingRouteCard: View {
    let route: Route
    let active: Bool
    let fastest: Double
    let multiple: Bool
    let meta: RoutingMeta?
    let depart: RoutingDepart?
    let select: () -> Void

    var body: some View {
        let delta = route.duration - fastest
        let isFastest = multiple && delta < 30
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(Geo.formatDuration(route.duration))
                        .font(.osa(20, .bold))
                        .monospacedDigit()
                        .foregroundStyle(Osa.text)
                    if isFastest {
                        Text("Le plus rapide")
                            .font(.osa(12, .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white, in: Capsule())
                    } else if multiple {
                        Text("+" + Geo.formatDuration(delta))
                            .font(.osa(13, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Osa.faint)
                    }
                    Spacer(minLength: 0)
                    if route.hasToll { tag("Péages", "eurosign.circle") }
                    if route.hasFerry { tag("Ferry", "ferry") }
                }
                Text(subtitle)
                    .font(.osa(13, .medium))
                    .foregroundStyle(Osa.dim)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Osa.surfaceHi : Osa.surface, in: RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous)
                .strokeBorder(active ? Color.white.opacity(0.75) : Osa.line, lineWidth: active ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Osa.radiusM))
        }
        .buttonStyle(RoutingPressStyle())
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var subtitle: String {
        var parts = [Geo.formatDistance(route.distance)]
        if let s = route.summary { parts.append(s) }
        if let depart, let arr = meta?.arriveAt, let dep = meta?.departAt {
            parts.append(depart.type == 1 ? "arrivée \(RoutingTime.format(arr))" : "départ \(RoutingTime.format(dep))")
        } else {
            parts.append("arrivée \(Geo.formatETA(route.duration))")
        }
        return parts.joined(separator: " · ")
    }

    private func tag(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.osa(12, .semibold))
            .foregroundStyle(Osa.dim)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Osa.lineHi))
    }
}

private struct RoutingSkeleton: View {
    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { i in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 5).fill(Osa.surfaceHi).frame(width: 90, height: 18)
                    RoundedRectangle(cornerRadius: 5).fill(Osa.surface).frame(width: 200, height: 12)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .osaCard()
                .opacity(i == 0 ? 1 : 0.5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Calcul de l'itinéraire")
    }
}

struct RoutingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct RoutingChip: View {
    let title: String
    let icon: String
    let on: Bool
    var open = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: on && icon != "clock" && icon != "plus" ? "checkmark" : icon)
                .font(.osa(14, .semibold))
                .lineLimit(1)
                .foregroundStyle(on ? Color.black : Osa.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(open ? Osa.surfaceHi : Color.clear), in: Capsule())
                .overlay(Capsule().strokeBorder(on ? Color.clear : Osa.lineHi))
        }
        .buttonStyle(RoutingPressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Partir à / Arriver à

/// Heures locales « 2026-11-05T08:00 » (format de Valhalla).
enum RoutingTime {
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d"
        return f
    }()

    static func stamp(_ d: Date) -> String { stampFormatter.string(from: d) }
    static func date(_ s: String) -> Date? { stampFormatter.date(from: s) }

    /// « 08:00 », « demain 08:00 », « jeu. 6 08:00 ».
    static func format(_ s: String) -> String {
        guard let d = date(s) else { return String(s.suffix(5)) }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: d)).day ?? 0
        if days == 0 { return hm.string(from: d) }
        if days == 1 { return "demain \(hm.string(from: d))" }
        return "\(day.string(from: d)) \(hm.string(from: d))"
    }
}

private struct RoutingDepartPanel: View {
    let model: RoutingModel
    @State private var type = 1
    @State private var date = Date().addingTimeInterval(30 * 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                seg("Partir à", 1)
                seg("Arriver à", 2)
            }
            .padding(3)
            .background(Osa.surface, in: Capsule())

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    mini("Maintenant", on: model.depart == nil) { model.setDepart(nil) }
                    ForEach([15, 30, 60], id: \.self) { m in
                        mini(m < 60 ? "+\(m) min" : "+1 h", on: false) {
                            date = Date().addingTimeInterval(Double(m) * 60)
                            apply()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(type == 1 ? "Heure de départ" : "Heure d'arrivée souhaitée")
                    .font(.osa(13, .semibold))
                    .foregroundStyle(Osa.dim)
                DatePicker(type == 1 ? "Heure de départ" : "Heure d'arrivée souhaitée", selection: $date,
                           in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "fr_FR"))
            }

            Button("Calculer pour cette heure") { apply() }
                .buttonStyle(.osaPillSecondary)
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .osaCard()
        .onAppear {
            if let d = model.depart {
                type = d.type
                date = RoutingTime.date(d.value) ?? date
            }
        }
    }

    private func apply() {
        // une heure passée n'a pas de sens : on remet « maintenant »
        if date < Date().addingTimeInterval(-60) { model.setDepart(nil); return }
        model.setDepart(RoutingDepart(type: type, value: RoutingTime.stamp(date)))
    }

    private func seg(_ title: String, _ t: Int) -> some View {
        Button {
            type = t
            if model.depart != nil { apply() }
        } label: {
            Text(title)
                .font(.osa(14, .semibold))
                .foregroundStyle(type == t ? Color.black : Osa.dim)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(type == t ? Color.white : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(RoutingPressStyle())
        .accessibilityAddTraits(type == t ? .isSelected : [])
    }

    private func mini(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.osa(13, .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? Color.black : Osa.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(on ? Color.white : Osa.surfaceHi, in: Capsule())
        }
        .buttonStyle(RoutingPressStyle())
    }
}

// MARK: - Étapes

private struct RoutingStopsPanel: View {
    @Bindable var model: RoutingModel
    @Environment(Core.self) private var core
    @State private var query = ""
    @State private var hits: [RoutingHit] = []
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.stops.enumerated()), id: \.element.id) { i, s in
                HStack(spacing: 10) {
                    Text("\(i + 1)")
                        .font(.osa(12, .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Osa.bg, in: Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.osa(15, .semibold)).foregroundStyle(Osa.text).lineLimit(2)
                        if let d = s.detail, !d.isEmpty { Text(d).font(.osa(12, .medium)).foregroundStyle(Osa.faint).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    iconButton("chevron.up", "Monter \(s.name)", disabled: i == 0) { model.moveStop(i, by: -1) }
                    iconButton("chevron.down", "Descendre \(s.name)", disabled: i == model.stops.count - 1) { model.moveStop(i, by: 1) }
                    iconButton("xmark", "Retirer \(s.name)", disabled: false) { model.removeStop(i) }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Osa.faint)
                TextField("", text: $query, prompt: Text("Ajouter une étape (ville, adresse…)").foregroundStyle(Osa.faint))
                    .font(.osa(15, .medium))
                    .foregroundStyle(Osa.text)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                if busy { ProgressView().controlSize(.small).tint(Osa.dim) }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Osa.surface, in: RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous).strokeBorder(Osa.line))

            ForEach(hits) { h in
                Button {
                    model.addStop(RoutingModel.stopPlace(name: h.name, coordinate: h.coordinate, detail: h.detail))
                    query = ""; hits = []; focused = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin").foregroundStyle(Osa.dim).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.name).font(.osa(15, .semibold)).foregroundStyle(Osa.text)
                            if let d = h.detail { Text(d).font(.osa(12, .medium)).foregroundStyle(Osa.faint) }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RoutingPressStyle())
            }

            Button {
                model.pickOnMap.toggle()
                focused = false
            } label: {
                Label(model.pickOnMap ? "Touchez la carte pour poser l'étape…" : "Choisir sur la carte", systemImage: "mappin.and.ellipse")
                    .font(.osa(13, .semibold))
                    .foregroundStyle(model.pickOnMap ? Color.black : Osa.text)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(model.pickOnMap ? Color.white : Osa.surfaceHi, in: Capsule())
            }
            .buttonStyle(RoutingPressStyle())
        }
        .padding(14)
        .osaCard()
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 3 else { hits = []; busy = false; return }
            // on attend que l'on arrête de taper
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            busy = true
            let found = (try? await RoutingGeocode.search(q, near: core.position?.coordinate)) ?? []
            guard !Task.isCancelled else { return }
            hits = found
            busy = false
        }
    }

    private func iconButton(_ icon: String, _ label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(disabled ? Osa.faint.opacity(0.5) : Osa.text)
                .frame(width: 34, height: 34)
                .background(Osa.surfaceHi, in: Circle())
                .contentShape(Circle().inset(by: -5))
        }
        .buttonStyle(RoutingPressStyle())
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

// MARK: - Poids lourds : interdictions de circuler, convoi exceptionnel

/// Avertissements propres aux camions sous les cartes d'itinéraire (couleur « danger » = état).
private struct RoutingTruckNotices: View {
    let route: Route
    let meta: RoutingMeta?
    let depart: RoutingDepart?
    let vehicle: Vehicle

    var body: some View {
        let bans = currentBans
        VStack(alignment: .leading, spacing: 6) {
            if vehicle.kind == .superheavy {
                notice("exclamationmark.triangle.fill",
                       "Convoi exceptionnel : l'itinéraire réel est celui imposé par ton arrêté préfectoral de transport exceptionnel. OsaMaps n'est qu'une aide.")
            }
            ForEach(Array(bans.enumerated()), id: \.offset) { _, b in
                notice("hand.raised.fill",
                       (b.regional.map { "Sur \($0), c" } ?? "C") + "irculation interdite aux poids lourds de plus de 7,5 t \(b.label). Ton trajet tombe dans cette période (sauf dérogation).",
                       title: b.start <= Date() && b.end > Date() ? "Interdiction en cours" : "Interdiction de circuler")
            }
        }
    }

    /// Trajet [départ, arrivée] : heure choisie (Valhalla renvoie les heures locales) ou maintenant.
    private var currentBans: [RoutingTruck.Ban] {
        guard RoutingTruck.bansApply(vehicle) else { return [] }
        var start = Date()
        if let d = meta?.departAt.flatMap(RoutingTime.date) { start = d }
        else if let depart, let d = RoutingTime.date(depart.value) {
            start = depart.type == 1 ? d : d.addingTimeInterval(-route.duration)
        }
        let end = start.addingTimeInterval(route.duration)
        let national = RoutingTruck.bans(from: start, to: end).filter { b in
            guard b.regional != nil else { return true }
            // hiver Auvergne-Rhône-Alpes : seulement si le tracé passe par les Alpes du Nord
            return route.coords.contains { $0.lat > 44.6 && $0.lat < 46.5 && $0.lng > 4.7 && $0.lng < 7.2 }
        }
        return national + RoutingTruck.idfBans(start: start, passes: RoutingTruck.idfPassages(route))
    }

    private func notice(_ icon: String, _ text: String, title: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Osa.danger)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.osa(14, .bold)).foregroundStyle(Osa.text) }
                Text(text)
                    .font(.osa(13, .medium))
                    .foregroundStyle(title == nil ? Osa.text : Osa.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Osa.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous).strokeBorder(Osa.danger.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}
