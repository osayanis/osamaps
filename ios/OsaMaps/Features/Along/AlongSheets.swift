import SwiftUI

/// Une seule entrée « sheet » pour le module : bandeau d'aperçu + panneaux along.station / along.fuel / along.weather.
struct AlongSheets: View {
    @Environment(Core.self) private var core

    var body: some View {
        let _ = core.panelVersion
        Group {
            switch core.panel {
            case "along.station":
                if let ref = core.panelData as? AlongStationRef { AlongStationSheet(ref: ref) }
            case "along.fuel":
                AlongListSheet()
            case "along.weather":
                AlongWeatherSheet()
            case nil where core.mode == .preview:
                AlongPreviewStrip()
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Conteneur commun

struct AlongPanel<Content: View>: View {
    var icon: String
    var kicker: String?
    var title: String
    var detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(Osa.lineHi).frame(width: 36, height: 5).frame(maxWidth: .infinity)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(Osa.surfaceHi, in: Circle())
                    .overlay(Circle().strokeBorder(Osa.line))
                VStack(alignment: .leading, spacing: 2) {
                    if let kicker { Text(kicker.uppercased()).font(.osa(11, .bold)).tracking(0.6).foregroundStyle(Osa.faint) }
                    Text(title).font(.osa(19, .bold)).foregroundStyle(Osa.text).lineLimit(2)
                    if let detail, !detail.isEmpty { Text(detail).font(.osa(13, .medium)).foregroundStyle(Osa.dim).lineLimit(2) }
                }
                Spacer(minLength: 0)
                Button { Core.shared.openPanel(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Osa.surfaceHi, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Osa.dim)
                .accessibilityLabel("Fermer")
            }
            content
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 18)
        .osaGlass()
        .padding(.bottom, 4)
    }
}

struct AlongSource: View {
    var text: String
    var body: some View { Text(text).font(.osa(11.5, .medium)).foregroundStyle(Osa.faint) }
}

/// « à 12 km sur le trajet » / « à 3,2 km » depuis ma position.
@MainActor
private func alongRouteInfo(along: Double?, offset: Double?, coord: CLLocationCoordinate2D, mode: Mode, showOffset: Bool) -> String? {
    if let along, mode != .browse {
        let ahead = max(0, along - AlongModel.shared.currentAlong())
        var s = "à \(Geo.formatDistance(ahead)) sur le trajet"
        if showOffset, let offset, offset > 0 { s += " · \(Geo.formatDistance(offset)) du tracé" }
        return s
    }
    guard let p = Core.shared.position else { return nil }
    return "à \(Geo.formatDistance(Geo.distance(p.coordinate, coord)))"
}

private struct AlongActions: View {
    var ref: AlongStationRef
    var mode: Mode
    var body: some View {
        if mode == .browse {
            goButton
        } else {
            // côte à côte si ça tient, sinon l'un sous l'autre (jamais tronqué)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { goButton; stopButton.fixedSize() }
                VStack(spacing: 8) { goButton; stopButton }
            }
        }
    }

    private var goButton: some View {
        Button { AlongModel.shared.go(ref) } label: {
            Label("Y aller", systemImage: "arrow.triangle.turn.up.right.diamond.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.osaPill)
    }

    private var stopButton: some View {
        Button { AlongModel.shared.addStop(ref) } label: {
            Label("Ajouter comme arrêt", systemImage: "plus").lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.osaPillSecondary)
    }
}

// MARK: - Fiche station

struct AlongStationSheet: View {
    var ref: AlongStationRef
    @Environment(Core.self) private var core

    var body: some View {
        switch ref {
        case .fuel(let s): fuel(s)
        case .ev(let s): ev(s)
        }
    }

    private func fuel(_ s: AlongFuelStation) -> some View {
        let mine = AlongPrefs.shared.energy
        let open = AlongFormat.openState(s)
        let now = Date.now
        let sub = [s.address, s.cp.isEmpty ? "" : "\(s.cp) \(s.city)"].filter { !$0.isEmpty }.joined(separator: ", ")
        let info = alongRouteInfo(along: s.along, offset: s.offset, coord: s.coordinate, mode: core.mode, showOffset: true)
        let fuels = AlongEnergy.fuels.filter { s.price($0) != nil || s.isShort($0) }
        return AlongPanel(icon: "fuelpump.fill", kicker: s.highway ? "Station d'autoroute" : "Station-service", title: s.name, detail: sub) {
            HStack(spacing: 6) {
                Circle().fill(open.open == true ? Osa.ok : open.open == false ? Osa.jam : Osa.faint).frame(width: 7, height: 7)
                Text([open.text, info].compactMap { $0 }.joined(separator: " · "))
                    .font(.osa(13, .medium)).foregroundStyle(Osa.dim).lineLimit(2)
            }
            VStack(spacing: 0) {
                ForEach(Array(fuels.enumerated()), id: \.element) { i, f in
                    let pr = s.price(f)
                    let out = s.isShort(f)
                    let fresh = pr.map { AlongFormat.isFresh($0.maj, now: now) } ?? false
                    let isMine = f == mine
                    HStack(spacing: 10) {
                        Text(f.label).font(.osa(15, isMine ? .bold : .semibold))
                            .foregroundStyle(isMine ? Osa.text : Osa.dim)
                        if isMine {
                            Text("MON CARBURANT").font(.osa(9.5, .bold)).tracking(0.4)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Osa.surfaceHi, in: Capsule()).foregroundStyle(Osa.dim)
                        }
                        Spacer(minLength: 8)
                        Text(out ? "temporaire" : pr.map { AlongFormat.ago($0.maj, now: now) } ?? "")
                            .font(.osa(12, .medium)).foregroundStyle(Osa.faint)
                        Text(out ? "Rupture" : pr.map { "\(AlongFormat.price3($0.p)) €" } ?? "—")
                            .font(.osa(16, .bold).monospacedDigit())
                            .foregroundStyle(out || !fresh ? Osa.faint : Osa.text)
                            .frame(minWidth: 76, alignment: .trailing)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .background(isMine ? Osa.surface : .clear)
                    if i < fuels.count - 1 { Divider().overlay(Osa.line) }
                }
            }
            .osaCard(Osa.radiusM)
            .clipShape(RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous))
            AlongActions(ref: ref, mode: core.mode)
            AlongSource(text: "Prix officiels déclarés par la station (prix-carburants.gouv.fr). En gris : prix de plus de 10 jours.")
        }
    }

    private func ev(_ s: AlongEvStation) -> some View {
        let info = alongRouteInfo(along: s.along, offset: s.offset, coord: s.coordinate, mode: core.mode, showOffset: false)
        let hours = s.hours == "24/7" ? "24 h/24, 7 j/7" : s.hours
        return AlongPanel(icon: "bolt.car.fill", kicker: "Borne de recharge", title: s.name, detail: s.address) {
            Text([s.operator_, hours, info ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.osa(13, .medium)).foregroundStyle(Osa.dim).lineLimit(2)
            HStack(spacing: 8) {
                cell(s.kw > 0 ? "\(Int(s.kw)) kW" : "—", "puissance max")
                cell(s.points > 0 ? "\(s.points)" : "—", s.points > 1 ? "points de charge" : "point de charge")
                cell(s.free ? "Gratuit" : "Payant", "recharge")
            }
            if !s.plugs.isEmpty {
                HStack(spacing: 6) {
                    ForEach(s.plugs, id: \.self) { p in
                        Text(p).font(.osa(12.5, .semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Osa.surfaceHi, in: Capsule()).foregroundStyle(Osa.text)
                    }
                }
            }
            AlongActions(ref: ref, mode: core.mode)
            AlongSource(text: "Base nationale des bornes (IRVE, data.gouv.fr). Disponibilité en temps réel non connue.")
        }
    }

    private func cell(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.osa(17, .bold)).foregroundStyle(Osa.text)
            Text(caption).font(.osa(11.5, .medium)).foregroundStyle(Osa.faint).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .osaCard(Osa.radiusS)
    }
}

// MARK: - Liste des stations du trajet

struct AlongListSheet: View {
    @Environment(Core.self) private var core
    private var model: AlongModel { .shared }
    private var prefs: AlongPrefs { .shared }

    var body: some View {
        let energy = prefs.energy
        let r = model.route.flatMap { $0.routeId == core.route?.id && $0.energy == energy ? $0 : nil }
        let loading = r == nil || r?.status == .loading
        let pos = model.currentAlong()
        if energy.isEV {
            let list = (r?.ev ?? []).filter { ($0.along ?? 0) >= pos }
                .sorted { ($0.kw, -($0.along ?? 0)) > ($1.kw, -($1.along ?? 0)) }
            AlongPanel(icon: "bolt.fill", title: "Recharge sur le trajet",
                       detail: loading ? "Recherche des bornes…" : r?.status == .error ? "Bornes indisponibles pour le moment." : "\(list.count) lieu\(list.count > 1 ? "x" : "") à moins de 1,5 km") {
                rows(list.prefix(40).map { s in
                    Row(id: s.id, value: s.kw > 0 ? "\(Int(s.kw)) kW" : "—", best: false, title: s.name,
                        sub: "\(s.operator_) · à \(Geo.formatDistance((s.along ?? 0) - pos))", ref: .ev(s))
                })
            }
        } else {
            let ranked = r.map { AlongFormat.rankOnRoute($0.fuel, energy, fromAlong: pos) } ?? []
            AlongPanel(icon: "fuelpump.fill", title: "Carburant sur le trajet",
                       detail: loading ? "Recherche des stations…" : r?.status == .error ? "Stations indisponibles pour le moment."
                           : "\(energy.label) · \(ranked.count) station\(ranked.count > 1 ? "s" : "") à moins d’1 km") {
                if !loading, r?.status == .ready, ranked.isEmpty {
                    Text("Aucun prix récent pour ce carburant le long du trajet.").font(.osa(14, .medium)).foregroundStyle(Osa.dim)
                }
                rows(ranked.prefix(40).enumerated().map { i, p in
                    let s = p.station
                    let detour = (s.offset ?? 0) > 150 ? " · détour \(Geo.formatDistance((s.offset ?? 0) * 2))" : " · sur la route"
                    return Row(id: s.id, value: AlongFormat.price3(p.price), best: i == 0, title: s.city + (s.highway ? " · autoroute" : ""),
                               sub: "à \(Geo.formatDistance(p.ahead))\(detour)", ref: .fuel(s))
                })
            }
        }
    }

    struct Row: Identifiable { var id: String; var value: String; var best: Bool; var title: String; var sub: String; var ref: AlongStationRef }

    @ViewBuilder
    private func rows(_ items: [Row]) -> some View {
        if !items.isEmpty {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items) { row in
                        Button { Core.shared.openPanel("along.station", data: row.ref) } label: {
                            HStack(spacing: 12) {
                                Text(row.value).font(.osa(14, .bold).monospacedDigit())
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .frame(minWidth: 70)
                                    .background(row.best ? Osa.ok : Color.white, in: Capsule())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title).font(.osa(15, .semibold)).foregroundStyle(Osa.text).lineLimit(1)
                                    Text(row.sub).font(.osa(12.5, .medium)).foregroundStyle(Osa.dim).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Osa.faint)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .osaCard(Osa.radiusS)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 340)
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Météo du trajet

struct AlongWeatherSheet: View {
    private var model: AlongModel { .shared }

    var body: some View {
        let w = model.weather
        let status = model.weatherStatus
        AlongPanel(icon: w.map { AlongWeather.symbol($0.points.first?.code ?? 3) } ?? "cloud.fill", title: "Météo sur le trajet",
                   detail: status == .loading ? "Prévisions en cours…" : status == .error ? "Prévisions indisponibles pour le moment." : "Prévue à l'heure où tu passeras.") {
            if let hz = w?.hazard {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(hz.text).font(.osa(14, .bold))
                }
                .foregroundStyle(hz.tone == .danger ? Osa.danger : Osa.slow)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((hz.tone == .danger ? Osa.danger : Osa.slow).opacity(0.12), in: RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous))
            }
            if let w {
                VStack(spacing: 0) {
                    ForEach(Array(w.points.enumerated()), id: \.offset) { i, p in
                        HStack(spacing: 12) {
                            Text(AlongWeather.hour(p.time)).font(.osa(13, .semibold).monospacedDigit()).foregroundStyle(Osa.dim).frame(width: 44, alignment: .leading)
                            Image(systemName: AlongWeather.symbol(p.code)).symbolRenderingMode(.hierarchical).font(.system(size: 17)).frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.at == 0 ? "Départ" : p.at == 1 ? "Arrivée" : "À \(Geo.formatDistance(p.along))").font(.osa(15, .semibold)).foregroundStyle(Osa.text)
                                Text(AlongWeather.label(p.code) + (p.precip >= 0.1 ? " · \(AlongFormat.decimal((p.precip * 10).rounded() / 10)) mm/h" : ""))
                                    .font(.osa(12.5, .medium)).foregroundStyle(Osa.dim)
                            }
                            Spacer(minLength: 0)
                            Text("\(Int(p.temp.rounded()))°").font(.osa(18, .bold).monospacedDigit()).foregroundStyle(Osa.text)
                        }
                        .padding(.vertical, 9).padding(.horizontal, 14)
                        if i < w.points.count - 1 { Divider().overlay(Osa.line) }
                    }
                }
                .osaCard()
                if let now = w.arrivalNow {
                    Text("En ce moment à l'arrivée : \(Int(now.temp.rounded())) °C, \(AlongWeather.label(now.code).lowercased()).")
                        .font(.osa(13, .medium)).foregroundStyle(Osa.dim)
                }
            }
            AlongSource(text: "Prévisions Open-Meteo.")
        }
    }
}

// MARK: - Bandeau discret au-dessus de l'aperçu d'itinéraire

struct AlongPreviewStrip: View {
    @Environment(Core.self) private var core
    private var model: AlongModel { .shared }
    private var prefs: AlongPrefs { .shared }

    var body: some View {
        if let route = core.route {
            let energy = prefs.energy
            let wx = model.weather.flatMap { $0.routeId == route.id ? $0 : nil }
            let st = model.route.flatMap { $0.routeId == route.id && $0.energy == energy ? $0 : nil }
            let km = route.distance / 1000
            let rows = fuelRows(energy: energy, st: st, km: km)
            VStack(spacing: 0) {
                if let wx, let last = wx.points.last {
                    let tone: Color? = wx.hazard.map { $0.tone == .danger ? Osa.danger : Osa.slow }
                    stripRow(icon: wx.hazard != nil ? "exclamationmark.triangle.fill" : AlongWeather.symbol(last.code), tint: tone,
                             main: AttributedString(wx.hazard?.text ?? "\(AlongWeather.label(last.code)) à l'arrivée · \(Int((wx.points.first?.temp ?? 0).rounded()))° → \(Int(last.temp.rounded()))°"),
                             sub: nil) { Core.shared.openPanel("along.weather") }
                    if rows != nil { Divider().overlay(Osa.line).padding(.leading, 48) }
                }
                if let rows {
                    stripRow(icon: energy.isEV ? "bolt.fill" : "fuelpump.fill", tint: nil, main: rows.main, sub: rows.sub) {
                        Core.shared.openPanel("along.fuel")
                    }
                }
            }
            .osaGlass(Osa.radiusM)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sur le trajet")
        }
    }

    private func fuelRows(energy: AlongEnergy, st: AlongRouteStations?, km: Double) -> (main: AttributedString, sub: AttributedString?)? {
        var main: AttributedString?
        var sub: AttributedString?
        let ready = st?.status == .ready ? st : nil
        if energy.isEV {
            sub = bold("Énergie du trajet ", "≈ \(Int((km * prefs.evConsumption / 100).rounded())) kWh", " · \(AlongFormat.decimal(prefs.evConsumption)) kWh/100 km")
            if let ready {
                let fast = ready.ev.filter { $0.kw >= 50 }.count
                main = ready.ev.isEmpty ? AttributedString("Aucune borne à moins de 1,5 km du trajet")
                    : fast > 0 ? bold("\(ready.ev.count) bornes sur le trajet, dont ", "\(fast) rapides", "") : AttributedString("\(ready.ev.count) bornes sur le trajet")
            }
        } else if let ready {
            let best = AlongFormat.rankOnRoute(ready.fuel, energy).first
            if let avg = AlongFormat.medianPrice(ready.fuel, energy) ?? AlongFormat.medianPrice(model.nearbyFuel, energy) {
                sub = bold("Coût du trajet ", "≈ \(AlongFormat.euros(km * prefs.consumption * avg / 100))", " · \(AlongFormat.decimal(prefs.consumption)) L/100 km")
            }
            main = best.map { bold("Le moins cher : ", "\(AlongFormat.price3($0.price)) €", " à \(Geo.formatDistance($0.ahead))") }
                ?? AttributedString("Pas de prix récent en \(energy.label) sur le trajet")
        }
        if st?.status == .error && main == nil { main = AttributedString("Stations du trajet indisponibles") }
        if main == nil && sub == nil && st?.status != .loading { return nil }
        return (main ?? AttributedString("Recherche des stations du trajet…"), sub)
    }

    private func bold(_ a: String, _ b: String, _ c: String) -> AttributedString {
        var s = AttributedString(a)
        var m = AttributedString(b)
        m.font = .osa(14, .bold)
        m.foregroundColor = Osa.text
        s.append(m)
        s.append(AttributedString(c))
        return s
    }

    private func stripRow(icon: String, tint: Color?, main: AttributedString, sub: AttributedString?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint ?? Osa.text)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(main).font(.osa(14, .semibold)).foregroundStyle(tint ?? Osa.text).lineLimit(1).minimumScaleFactor(0.85)
                    if let sub { Text(sub).font(.osa(12.5, .medium)).foregroundStyle(Osa.dim).lineLimit(1).minimumScaleFactor(0.85) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Osa.faint)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
