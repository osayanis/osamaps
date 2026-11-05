#if DEBUG
import SwiftUI

/// Aperçu DEBUG des Live Activities (le simulateur n'a pas de Dynamic Island) : mêmes vues que l'extension
/// (Shared/LiveViews.swift), posées dans des formes qui imitent l'île et l'écran verrouillé.
///   -livePreview YES   guidage : compact, minimal, étendu (musique), écran verrouillé (musique, alerte)
///   -livePreview 2     notifications : police, retard trafic, nouvel itinéraire
///   -livePreview 3     arrivée, rond-point imminent, ami qui arrive
/// La hauteur mesurée des cartes « écran verrouillé » est affichée (limite iOS : 160 pt).
struct LivePreviewScreen: View {
    private let page = UserDefaults.standard.string(forKey: "livePreview") ?? "1"

    var body: some View {
        ZStack {
            Color(white: 0.17).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    switch page {
                    case "2": notifications
                    case "3": others
                    default: guidance
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .environment(\.locale, Locale(identifier: "fr_FR"))
        .environment(\.colorScheme, .dark)
    }

    // MARK: pages

    @ViewBuilder private var guidance: some View {
        let s = Self.nav { $0.musicTitle = "Nightcall"; $0.musicArtist = "Kavinsky"; $0.musicSource = "spotify"; $0.musicPlaying = true }
        caption("Compact · minimal")
        HStack(spacing: 10) {
            LiveIslandCompact { LiveNavCompactLeading(state: s) } trailing: { LiveNavCompactTrailing(state: s) }
            LiveIslandMinimal { LiveNavMinimal(state: s) }
        }
        caption("Étendu · musique")
        nav(s)
        caption("Écran verrouillé · musique")
        LiveLockCard { LiveNavLockScreen(state: s, destination: "Vichy") }
        let a = Self.nav {
            $0.alert = "Police signalée"; $0.alertTone = "police"; $0.alertDistance = 640; $0.alertSymbol = "light.beacon.max.fill"
            $0.delay = 420; $0.eta = $0.eta.addingTimeInterval(420)
        }
        caption("Écran verrouillé · alerte + retard")
        LiveLockCard { LiveNavLockScreen(state: a, destination: "Vichy") }
    }

    @ViewBuilder private var notifications: some View {
        let police = Self.nav {
            $0.alert = "Police signalée"; $0.alertTone = "police"; $0.alertDistance = 800; $0.alertSymbol = "light.beacon.max.fill"
            $0.bannerKind = "alert"; $0.bannerTitle = "Police signalée"; $0.bannerTone = "police"
            $0.bannerSymbol = "light.beacon.max.fill"; $0.bannerDistance = 800
        }
        caption("Alerte : compact puis Dynamic Island ouverte")
        LiveIslandCompact { LiveNavCompactLeading(state: police) } trailing: { LiveNavCompactTrailing(state: police) }
        nav(police)
        let works = Self.nav {
            $0.bannerKind = "alert"; $0.bannerTitle = "Travaux"; $0.bannerDetail = "+1 autre alerte devant"; $0.bannerTone = "warn"
            $0.bannerSymbol = "cone.fill"; $0.bannerDistance = 1200
        }
        caption("Alertes regroupées")
        nav(works)
        let traffic = Self.nav {
            $0.delay = 540; $0.eta = $0.eta.addingTimeInterval(540)
            $0.bannerKind = "traffic"; $0.bannerTitle = "Ralentissement"; $0.bannerDetail = "+9 min au total"
            $0.bannerTone = "slow"; $0.bannerSymbol = "car.2.fill"; $0.bannerShort = "+4 min"
        }
        caption("Retard trafic")
        nav(traffic)
        let reroute = Self.nav {
            $0.bannerKind = "reroute"; $0.bannerTitle = "Nouvel itinéraire"; $0.bannerDetail = "Arrivée à 14:36"
            $0.bannerTone = "info"; $0.bannerSymbol = "arrow.triangle.branch"
        }
        caption("Recalcul · écran verrouillé")
        LiveLockCard { LiveNavLockScreen(state: reroute, destination: "Vichy") }
    }

    @ViewBuilder private var others: some View {
        let round = Self.nav {
            $0.kind = "roundabout"; $0.exit = 2; $0.distance = 60; $0.imminent = true
            $0.instruction = "2e sortie"; $0.street = "D 2209"
            $0.alert = "Zone de danger"; $0.alertTone = "warn"; $0.alertDistance = 1500; $0.alertSymbol = "exclamationmark.triangle.fill"
        }
        caption("Étendu · rond-point imminent + alerte")
        nav(round)
        let arrived = Self.nav {
            $0.arrived = true; $0.kind = "arrive"; $0.distance = 0; $0.progress = 1; $0.street = "Vichy"
            $0.bannerKind = "arrival"; $0.bannerTitle = "Vous voilà à destination"; $0.bannerDetail = "Vichy"
            $0.bannerTone = "ok"; $0.bannerSymbol = "flag.checkered"
        }
        caption("Arrivée")
        HStack(spacing: 10) {
            LiveIslandCompact { LiveNavCompactLeading(state: arrived) } trailing: { LiveNavCompactTrailing(state: arrived) }
            LiveIslandMinimal { LiveNavMinimal(state: arrived) }
        }
        LiveLockCard { LiveNavLockScreen(state: arrived, destination: "Vichy") }
        let f = Self.friend(arrived: false)
        caption("Un ami arrive")
        LiveIslandCompact { LiveFriendAvatar(name: "Léa", arrived: false, size: 22) } trailing: { LiveFriendCompactTrailing(state: f) }
        LiveIslandExpanded {
            LiveFriendAvatar(name: "Léa", arrived: false, size: 48)
        } center: {
            LiveFriendTitle(name: "Léa", state: f).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
        } trailing: {
            LiveFriendETA(state: f, big: 18)
        } bottom: {
            LiveProgress(value: f.progress).padding(.top, 4)
        }
        LiveLockCard { LiveFriendLockScreen(name: "Léa", state: f) }
        LiveLockCard { LiveFriendLockScreen(name: "Léa", state: Self.friend(arrived: true)) }
    }

    // MARK: briques

    private func nav(_ s: LiveNavState) -> some View {
        LiveIslandExpanded {
            LiveNavExpandedLeading(state: s)
        } center: {
            LiveNavExpandedCenter(state: s)
        } trailing: {
            LiveNavExpandedTrailing(state: s)
        } bottom: {
            LiveNavExpandedBottom(state: s)
        }
    }

    private func caption(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }

    static func time(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
    }

    static func friend(arrived: Bool) -> LiveFriendState {
        var f = LiveFriendState(destination: "Gare de Vichy", eta: time(14, 32), remaining: 4200)
        f.progress = arrived ? 1 : 0.62
        f.arrived = arrived
        return f
    }

    static func nav(_ change: (inout LiveNavState) -> Void = { _ in }) -> LiveNavState {
        var s = LiveNavState(distance: 350, instruction: "Tournez à droite", street: "Avenue de Gramont",
                             symbol: "arrow.turn.up.right", eta: time(14, 32), remaining: 18_400)
        s.kind = "right"
        s.progress = 0.42
        change(&s)
        return s
    }
}

/// Île compacte : gauche, caméra, droite.
private struct LiveIslandCompact<L: View, T: View>: View {
    @ViewBuilder var leading: L
    @ViewBuilder var trailing: T

    var body: some View {
        HStack(spacing: 0) {
            leading
            Color.clear.frame(width: 118, height: 1)
            trailing
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 37)
        .background(.black, in: Capsule())
    }
}

private struct LiveIslandMinimal<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        content.foregroundStyle(.white).frame(width: 37, height: 37).background(.black, in: Circle())
    }
}

/// Île ouverte en grand (approximation de la disposition des régions).
private struct LiveIslandExpanded<L: View, C: View, T: View, B: View>: View {
    @ViewBuilder var leading: L
    @ViewBuilder var center: C
    @ViewBuilder var trailing: T
    @ViewBuilder var bottom: B

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 0) {
                leading
                center
                trailing
            }
            bottom
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: 371)
        .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
    }
}

/// Carte de l'écran verrouillé, avec sa hauteur mesurée.
private struct LiveLockCard<C: View>: View {
    @ViewBuilder var content: C
    @State private var height: CGFloat = 0

    var body: some View {
        content
            .frame(maxWidth: 361)
            .background(LiveOsa.bg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .background(GeometryReader { g in Color.clear.onAppear { height = g.size.height } })
            .overlay(alignment: .topTrailing) {
                Text("\(Int(height)) pt")
                    .font(.system(size: 10, weight: .bold)).monospacedDigit()
                    .foregroundStyle(height > 160 ? .red : .white.opacity(0.35))
                    .padding(.trailing, 8).offset(y: -12)
            }
    }
}
#endif
