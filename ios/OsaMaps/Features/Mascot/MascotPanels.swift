import SwiftUI

// Panneaux du bas de la mascotte (slot .sheet) : "trip-summary" (data = MascotTrip) et "profile".

/// L'entrée unique du slot .sheet : n'affiche rien si le panneau ouvert n'est pas à la mascotte.
struct MascotSheet: View {
    @Environment(Core.self) private var core
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if core.panel == "trip-summary", let trip = core.panelData as? MascotTrip {
                MascotTripSummary(trip: trip).id(core.panelVersion)
            } else if core.panel == "profile" {
                MascotProfile()
            } else if core.panel == "mascot-editor" {
                MascotEditor()
            }
        }
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .animation(Osa.anim, value: core.panel)
    }
}

// MARK: - Habillage commun

struct MascotSheetChrome: ViewModifier {
    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Osa.radiusL, topTrailingRadius: Osa.radiusL, style: .continuous)
        content
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(Osa.bg.opacity(0.72)))
                    .overlay(shape.stroke(Osa.line))
                    .shadow(color: .black.opacity(0.45), radius: 20, y: -4)
                    .ignoresSafeArea(edges: .bottom)
            }
    }
}

extension View {
    func mascotSheet() -> some View { modifier(MascotSheetChrome()) }
}

struct MascotGrabber: View {
    var body: some View {
        Capsule().fill(Osa.lineHi).frame(width: 36, height: 5).frame(maxWidth: .infinity).accessibilityHidden(true)
    }
}

struct MascotEyebrow: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.osa(12, .bold)).tracking(0.5).foregroundStyle(Osa.faint)
    }
}

private struct MascotStat: View {
    var label: String
    var value: String
    var strong = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.osa(19, .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(strong ? Color.black : Osa.text)
            Text(label).font(.osa(12, .semibold)).foregroundStyle(strong ? Color.black.opacity(0.6) : Osa.dim).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(strong ? AnyShapeStyle(Osa.text) : AnyShapeStyle(Osa.surface), in: RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous).strokeBorder(strong ? Color.clear : Osa.line))
        .accessibilityElement(children: .combine)
    }
}

private struct MascotBar: View {
    var progress: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Osa.surfaceHi)
                Capsule().fill(Osa.text).frame(width: g.size.width * progress)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Résumé du trajet

struct MascotTripSummary: View {
    let trip: MascotTrip
    @Environment(Core.self) private var core
    @State private var hop = 0
    @State private var shown = false

    var body: some View {
        let m = MascotEngine.shared
        let lvl = m.level
        let t = trip
        let badge = t.badges.first.flatMap(MascotData.badge)
        VStack(alignment: .leading, spacing: 14) {
            MascotGrabber()
            HStack(spacing: 12) {
                MascotFigure(mood: .happy, arms: .up, size: 74, hop: hop, style: MascotLookStore.shared.shown, animated: m.settings.animations)
                    .frame(width: 96, height: 80)
                VStack(alignment: .leading, spacing: 2) {
                    MascotEyebrow("Résumé du trajet")
                    Text(t.arrived ? "Bien arrivé !" : "Trajet terminé").font(.osa(22, .bold)).foregroundStyle(Osa.text)
                    if let d = t.destination, !d.isEmpty {
                        Text(d).font(.osa(15, .medium)).foregroundStyle(Osa.dim).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    MascotStat(label: "Distance", value: Geo.formatDistance(t.distance))
                    MascotStat(label: "Durée", value: Geo.formatDuration(t.duration))
                    MascotStat(label: "Moyenne", value: MascotData.kmh(t.avgKmh))
                }
                GridRow {
                    MascotStat(label: "Max", value: MascotData.kmh(t.maxKmh))
                    MascotStat(label: "Arrêts", value: "\(t.stops)")
                    MascotStat(label: "Points", value: "+\(t.points)", strong: true)
                }
            }
            if let badge {
                unlock(icon: AnyView(Image(systemName: badge.symbol).font(.system(size: 19, weight: .semibold))),
                       eyebrow: "Badge débloqué", title: badge.name,
                       extra: t.badges.count > 1 ? " et \(t.badges.count - 1) autre\(t.badges.count > 2 ? "s" : "")" : nil)
            }
            if let up = t.levelUp {
                unlock(icon: AnyView(Text("\(up.level)").font(.osa(18, .heavy))), eyebrow: "Niveau supérieur", title: up.name, extra: nil)
            }
            HStack(spacing: 10) {
                Text("Niv. \(lvl.level)").font(.osa(13, .semibold))
                MascotBar(progress: lvl.progress)
                Text(lvl.next.map { "\(MascotData.nf(m.saved.points)) / \(MascotData.nf($0))" } ?? "\(MascotData.nf(m.saved.points)) pts")
                    .font(.osa(13, .semibold)).foregroundStyle(Osa.dim).monospacedDigit()
            }
            HStack(spacing: 10) {
                Button { core.openPanel("profile") } label: { Text("Mon profil").lineLimit(1).frame(maxWidth: .infinity) }
                    .buttonStyle(.osaPillSecondary)
                Button { core.openPanel(nil) } label: { Text("Fermer").lineLimit(1).frame(maxWidth: .infinity) }
                    .buttonStyle(.osaPill)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .mascotSheet()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Résumé du trajet")
        .onAppear {
            hop += 1
            Haptic.play("success")
            withAnimation(MascotEngine.shared.animated ? .timingCurve(0.23, 1, 0.32, 1, duration: 0.3).delay(0.25) : nil) { shown = true }
        }
    }

    private func unlock(icon: AnyView, eyebrow: String, title: String, extra: String?) -> some View {
        HStack(spacing: 12) {
            icon.foregroundStyle(.black).frame(width: 44, height: 44).background(Osa.text, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                MascotEyebrow(eyebrow)
                (Text(title).font(.osa(16, .bold)).foregroundColor(Osa.text)
                 + Text(extra ?? "").font(.osa(14, .medium)).foregroundColor(Osa.dim))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .osaCard(Osa.radiusM)
        .scaleEffect(shown ? 1 : 0.92)
        .opacity(shown ? 1 : 0)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Profil

struct MascotProfile: View {
    @Environment(Core.self) private var core
    @State private var tab = "badges"
    @State private var hop = 0
    @State private var board: MascotBoard.Board?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d MMM · HH:mm"
        return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM"
        return f
    }()

    var body: some View {
        let m = MascotEngine.shared
        let s = m.saved
        let lvl = m.level
        VStack(alignment: .leading, spacing: 14) {
            MascotGrabber()
            HStack(alignment: .center, spacing: 12) {
                Button { core.openPanel("mascot-editor"); Haptic.play("light") } label: {
                    MascotFigure(size: 64, hop: hop, style: MascotLookStore.shared.shown, animated: m.settings.animations)
                        .frame(width: 84, height: 72)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "paintbrush.pointed.fill")
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 26, height: 26)
                                .background(Osa.text, in: Circle())
                                .overlay(Circle().strokeBorder(Osa.bg, lineWidth: 2))
                                .offset(x: -2, y: -2)
                        }
                }
                .buttonStyle(MascotPressStyle())
                .accessibilityLabel("Personnaliser \(MascotLookStore.shared.look.displayName)")
                VStack(alignment: .leading, spacing: 6) {
                    MascotEyebrow("\(MascotLookStore.shared.look.displayName) · Niveau \(lvl.level)")
                    Text(lvl.name).font(.osa(20, .bold)).foregroundStyle(Osa.text).lineLimit(1).minimumScaleFactor(0.8)
                    MascotBar(progress: lvl.progress)
                    Text(lvl.next.map { "\(MascotData.nf(s.points)) pts · encore \(MascotData.nf($0 - s.points)) pour le niveau \(lvl.level + 1)" }
                         ?? "\(MascotData.nf(s.points)) pts · niveau maximum")
                        .font(.osa(13, .medium)).foregroundStyle(Osa.dim).lineLimit(2)
                }
                Button { core.openPanel(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Osa.dim)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fermer")
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)

            Grid(horizontalSpacing: 8) {
                GridRow {
                    MascotStat(label: "km au total", value: Self.km(s.totalDistance))
                    MascotStat(label: s.trips > 1 ? "trajets" : "trajet", value: "\(s.trips)")
                    MascotStat(label: "cette semaine", value: "\(MascotData.nf(m.weekPoints)) pts")
                }
            }

            tabs(badges: s.badges.count)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case "trajets": history(s.history)
                    default: badges(s.badges)
                    }
                    if m.settings.leaderboard, let board, !board.top.isEmpty { leaderboard(board) }
                }
                .padding(.bottom, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.scrollMax)
        }
        .mascotSheet()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mon profil")
        .task(id: m.settings.leaderboard) {
            board = m.settings.leaderboard ? await MascotBoard.sync() : nil
        }
    }

    /// Hauteur max de la zone qui défile : le profil ne doit pas couvrir toute la carte (petits écrans compris).
    private static var scrollMax: CGFloat {
        let h = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 800
        return max(170, min(330, h * 0.5 - 250))
    }

    static func km(_ m: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal
        f.maximumFractionDigits = m < 10_000 ? 1 : 0
        return f.string(from: NSNumber(value: m / 1000)) ?? "0"
    }

    private func tabs(badges: Int) -> some View {
        HStack(spacing: 4) {
            ForEach([("badges", "Badges \(badges)/\(MascotData.badges.count)"), ("trajets", "Trajets")], id: \.0) { id, label in
                Button { withAnimation(.easeOut(duration: 0.16)) { tab = id } } label: {
                    Text(label).font(.osa(14, .semibold))
                        .foregroundStyle(tab == id ? Color.black : Osa.dim)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(tab == id ? AnyShapeStyle(Osa.text) : AnyShapeStyle(Color.clear), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == id ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Osa.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Osa.line))
    }

    private let grid = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    private func badges(_ got: [String: Date]) -> some View {
        LazyVGrid(columns: grid, spacing: 8) {
            ForEach(MascotData.badges) { b in
                let date = got[b.id]
                VStack(spacing: 4) {
                    Image(systemName: b.symbol).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(date != nil ? Color.black : Osa.faint)
                        .frame(width: 40, height: 40)
                        .background { if date != nil { Circle().fill(Osa.text) } }
                        .overlay { if date == nil { Circle().strokeBorder(Osa.lineHi, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])) } }
                    Text(b.name).font(.osa(13, .semibold)).foregroundStyle(date != nil ? Osa.text : Osa.dim)
                        .multilineTextAlignment(.center).lineLimit(2)
                    Text(date.map { Self.dayFmt.string(from: $0) } ?? b.hint).font(.osa(11, .medium)).foregroundStyle(date != nil ? Osa.dim : Osa.faint)
                        .multilineTextAlignment(.center).lineLimit(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 10)
                .background(date != nil ? Osa.surfaceHi : Osa.surface, in: RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous).strokeBorder(Osa.line))
                .accessibilityElement(children: .combine)
                .accessibilityValue(date != nil ? "obtenu" : "à débloquer")
            }
        }
    }

    @ViewBuilder private func history(_ list: [MascotTrip]) -> some View {
        if list.isEmpty {
            Text("Pas encore de trajet. Choisis une destination et lance le guidage : je compte les kilomètres pour toi.")
                .font(.osa(14, .medium)).foregroundStyle(Osa.dim).lineSpacing(3).padding(.vertical, 8)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.destination ?? (t.arrived ? "Trajet" : "Trajet interrompu")).font(.osa(14, .semibold)).foregroundStyle(Osa.text).lineLimit(1)
                            Text(Self.dateFmt.string(from: t.start)).font(.osa(12, .medium)).foregroundStyle(Osa.dim)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Geo.formatDistance(t.distance)) · \(Geo.formatDuration(t.duration))").font(.osa(14, .semibold)).foregroundStyle(Osa.text)
                            Text("\(MascotData.kmh(t.avgKmh)) moy. · +\(t.points) pts").font(.osa(12, .medium)).foregroundStyle(Osa.dim)
                        }
                        .monospacedDigit()
                    }
                    .padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                    if i < list.count - 1 { Rectangle().fill(Osa.line).frame(height: 1) }
                }
            }
        }
    }

    private func leaderboard(_ b: MascotBoard.Board) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MascotEyebrow("Classement de la semaine")
            VStack(spacing: 2) {
                ForEach(Array(b.top.prefix(10).enumerated()), id: \.offset) { i, r in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.osa(14, .bold)).foregroundStyle(Osa.faint).frame(width: 20, alignment: .leading)
                        Text(r.name + (r.me == true ? " (toi)" : "")).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(MascotData.nf(r.points)) pts")
                    }
                    .font(.osa(14, r.me == true ? .bold : .medium)).monospacedDigit().foregroundStyle(Osa.text)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(r.me == true ? Osa.surfaceHi : .clear, in: RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous))
                }
            }
            if let rank = b.rank, rank > 10 {
                Text("Tu es \(rank)e sur \(b.total).").font(.osa(13, .medium)).foregroundStyle(Osa.dim)
            }
        }
    }
}

struct MascotPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: - Bouton du rail

/// Bouton rond avec la tête de la mascotte : ouvre le profil. Caché en conduite.
struct MascotRailButton: View {
    @Environment(Core.self) private var core

    var body: some View {
        let m = MascotEngine.shared
        let open = core.panel == "profile"
        if core.mode != .drive {
            Button { core.openPanel(open ? nil : "profile"); Haptic.play("light") } label: {
                MascotFigure(mood: m.live.sleeping ? .sleepy : .calm, size: 34, style: MascotLookStore.shared.shown, head: true, animated: m.settings.animations)
                    .offset(y: 3)
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
            }
            .buttonStyle(OsaRoundStyle(size: 48))
            .overlay(Circle().strokeBorder(open ? Osa.lineHi : .clear, lineWidth: 1.5))
            .accessibilityLabel("Mon profil")
            .accessibilityAddTraits(open ? .isSelected : [])
        }
    }
}

// MARK: - Réglages

/// Section « Mascotte » des réglages : accès à l'éditeur, animations, messages, classement.
struct MascotSettingsSection: View {
    @Environment(Core.self) private var core

    var body: some View {
        let m = MascotEngine.shared
        let look = MascotLookStore.shared
        VStack(alignment: .leading, spacing: 0) {
            Button {
                core.settingsOpen = false
                core.openPanel("mascot-editor")
            } label: {
                HStack(spacing: 12) {
                    MascotFigure(size: 44, style: look.shown, head: true, animated: m.settings.animations)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(look.look.displayName).font(.osa(17, .bold)).foregroundStyle(Osa.text)
                        Text("Elle te représente sur la carte.").font(.osa(13, .medium)).foregroundStyle(Osa.dim)
                    }
                    Spacer(minLength: 8)
                    Text("Personnaliser").font(.osa(14, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).frame(minHeight: 36)
                        .background(Osa.text, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MascotPressStyle())
            .padding(.bottom, 12)

            toggle("Animations", hint: "Rebond, clignements, petits sauts", on: m.settings.animations) { v in m.setSetting { $0.animations = v } }
            toggle("Messages de la mascotte", hint: "Rares, jamais pendant une manœuvre", on: m.settings.talk) { v in m.setSetting { $0.talk = v } }
            toggle("Classement de la semaine",
                   hint: "Partage seulement ton pseudo\(Identity.nickname.isEmpty ? " (anonyme)" : " (\(Identity.nickname))") et tes points de la semaine",
                   on: m.settings.leaderboard) { v in
                m.setSetting { $0.leaderboard = v }
                Task { if v { _ = await MascotBoard.sync() } else { await MascotBoard.leave() } }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .osaCard()
    }

    private func toggle(_ label: String, hint: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: set)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.osa(15, .semibold)).foregroundStyle(Osa.text)
                Text(hint).font(.osa(12, .medium)).foregroundStyle(Osa.dim)
            }
        }
        .tint(Osa.ok)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Osa.line).frame(height: 1) }
    }
}
