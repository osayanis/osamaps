import SwiftUI
import ActivityKit
import AppIntents

// Vues des Live Activities (écran verrouillé + Dynamic Island), sobriété Osa.
// Dans Shared/ : l'extension OsaMapsLive les assemble dans ActivityConfiguration, l'app les affiche
// telles quelles dans l'écran d'aperçu DEBUG (-livePreview), pour les vérifier sans Dynamic Island.

/// Couleurs Osa (l'extension ne voit pas Theme.swift de l'app).
enum LiveOsa {
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.059)
    static let dim = Color.white.opacity(0.6)
    static let faint = Color.white.opacity(0.4)
    static let line = Color.white.opacity(0.14)
    static let glass = Color.white.opacity(0.1)
    static let ok = Color(red: 0.204, green: 0.78, blue: 0.349)
    static let slow = Color(red: 1.0, green: 0.624, blue: 0.039)
    static let jam = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let police = Color(red: 0.353, green: 0.663, blue: 1.0)
    static let danger = Color(red: 1.0, green: 0.8, blue: 0.0)

    /// Couleur d'état : la seule couleur de l'affichage.
    static func tone(_ t: String?) -> Color {
        switch t {
        case "danger": jam
        case "police": police
        case "warn": danger
        case "slow": slow
        case "ok": ok
        default: Color.white.opacity(0.75)
        }
    }

    /// Pictogramme posé sur la couleur d'état : noir sur jaune / vert / bleu, blanc sur rouge / neutre.
    static func ink(_ t: String?) -> Color {
        switch t {
        case "warn", "ok", "police", "slow": .black
        default: .white
        }
    }

    static func fill(_ t: String?) -> Color {
        switch t {
        case "danger", "police", "warn", "slow", "ok": tone(t)
        default: Color.white.opacity(0.16)
        }
    }

    static func distance(_ m: Double) -> String {
        if m < 50 { return "\(Int((m / 5).rounded()) * 5) m" }
        if m < 1000 { return "\(Int((m / 10).rounded()) * 10) m" }
        if m < 10_000 { return String(format: "%.1f km", m / 1000).replacingOccurrences(of: ".", with: ",") }
        return "\(Int((m / 1000).rounded())) km"
    }

    /// Distance d'une alerte : « ici » tout près.
    static func alertDistance(_ m: Double) -> String { m <= 20 ? "ici" : distance(m) }

    /// « +6 min », « +1 h 05 ».
    static func delay(_ s: Double) -> String {
        let m = max(1, Int((s / 60).rounded()))
        return m < 60 ? "+\(m) min" : "+\(m / 60) h \(String(format: "%02d", m % 60))"
    }
}

typealias LiveNavState = NavActivityAttributes.ContentState

extension NavActivityAttributes.ContentState {
    var hasBanner: Bool { bannerKind != nil && bannerTitle != nil }
    var hasMusic: Bool { !(musicTitle ?? "").isEmpty }
    /// Retard affiché à partir d'une minute.
    var showsDelay: Bool { delay >= 60 }
    var delayTone: String { delay >= 900 ? "danger" : "slow" }

    /// Ligne sous la distance : « Tournez à droite · Rue de Paris ».
    var streetLine: String {
        guard let street, !street.isEmpty else { return instruction }
        return instruction.isEmpty || kind == "straight" ? street : "\(instruction) · \(street)"
    }

    /// Texte à droite de la pastille compacte pendant une notification.
    var bannerTrailing: String? {
        if let d = bannerDistance { return LiveOsa.alertDistance(d) }
        return bannerShort
    }
}

// MARK: - Briques

/// Tuile colorée d'état avec un pictogramme (notification, alerte).
struct LiveToneTile: View {
    let symbol: String
    let tone: String?
    var size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(LiveOsa.ink(tone))
            .frame(width: size, height: size)
            .background(LiveOsa.fill(tone), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Flèche dans une tuile : verre blanc 10 % ; blanche à flèche noire quand la manœuvre est imminente ; verte à l'arrivée.
struct LiveArrowTile: View {
    let state: LiveNavState
    var size: CGFloat

    var body: some View {
        let fill: Color = state.arrived ? LiveOsa.ok : state.imminent ? .white : LiveOsa.glass
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(fill)
            if state.arrived {
                Image(systemName: "flag.checkered").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.black)
            } else {
                LiveArrow(kind: state.kind, exit: state.exit, size: size * 0.82)
                    .foregroundStyle(state.imminent ? .black : .white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Ligne d'alerte / de notification : pictogramme coloré, texte, distance qui décompte.
struct LiveNoticeRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    let tone: String?
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            LiveToneTile(symbol: symbol, tone: tone, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.85)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 12, weight: .semibold)).foregroundStyle(LiveOsa.dim).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 16, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(tone == nil || tone == "info" ? .white : LiveOsa.tone(tone))
            }
        }
        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 3)
        .background(LiveOsa.tone(tone).opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Bouton rond d'une Live Activity (App Intent, iOS 17).
struct LiveIntentButton<I: AppIntent>: View {
    let intent: I
    let symbol: String
    let label: String
    var size: CGFloat = 30
    var filled = false

    var body: some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(filled ? .black : .white)
                .frame(width: size, height: size)
                .background(filled ? Color.white : LiveOsa.glass, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Morceau en cours (contrat « music:now ») + précédent / lecture / suivant.
struct LiveMusicRow: View {
    let state: LiveNavState
    var buttonSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.musicPlaying ? "music.note" : "pause")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(LiveOsa.dim)
                .frame(width: 28, height: 28)
                .background(LiveOsa.glass, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(state.musicTitle ?? "").font(.system(size: 14, weight: .bold)).lineLimit(1)
                if let a = state.musicArtist, !a.isEmpty {
                    Text(a).font(.system(size: 12, weight: .semibold)).foregroundStyle(LiveOsa.dim).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                LiveIntentButton(intent: LiveMusicIntent(action: "previous"), symbol: "backward.fill", label: "Morceau précédent", size: buttonSize)
                LiveIntentButton(intent: LiveMusicIntent(action: "toggle"), symbol: state.musicPlaying ? "pause.fill" : "play.fill",
                                 label: state.musicPlaying ? "Pause" : "Lecture", size: buttonSize, filled: true)
                LiveIntentButton(intent: LiveMusicIntent(action: "next"), symbol: "forward.fill", label: "Morceau suivant", size: buttonSize)
            }
        }
    }
}

struct LiveProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LiveOsa.line)
                Capsule().fill(Color.white.opacity(0.85)).frame(width: max(4, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// Heure d'arrivée + reste (+ retard trafic en couleur).
struct LiveETA: View {
    let state: LiveNavState
    var big: CGFloat = 20

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(state.eta, style: .time)
                .font(.system(size: big, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(state.showsDelay ? LiveOsa.tone(state.delayTone) : .white)
            HStack(spacing: 4) {
                if state.showsDelay {
                    Text(LiveOsa.delay(state.delay)).foregroundStyle(LiveOsa.tone(state.delayTone))
                }
                Text(LiveOsa.distance(state.remaining)).foregroundStyle(LiveOsa.dim)
            }
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Guidage : Dynamic Island

struct LiveNavCompactLeading: View {
    let state: LiveNavState
    var body: some View {
        Group {
            if state.hasBanner, let sym = state.bannerSymbol {
                Image(systemName: sym).font(.system(size: 15, weight: .bold)).foregroundStyle(LiveOsa.tone(state.bannerTone))
            } else if state.arrived {
                Image(systemName: "flag.checkered").font(.system(size: 15, weight: .bold)).foregroundStyle(LiveOsa.ok)
            } else {
                LiveArrow(kind: state.kind, exit: nil, size: 22)
                    .foregroundStyle(.white)
                    .overlay(alignment: .topTrailing) {
                        if state.alert != nil {
                            Circle().fill(LiveOsa.tone(state.alertTone)).frame(width: 7, height: 7).offset(x: 3, y: -1)
                        }
                    }
            }
        }
        .padding(.leading, 2)
    }
}

struct LiveNavCompactTrailing: View {
    let state: LiveNavState
    var body: some View {
        let banner = state.hasBanner ? state.bannerTrailing : nil
        Text(banner ?? (state.arrived ? "Arrivé" : LiveOsa.distance(state.distance)))
            .font(.system(size: 14, weight: .heavy))
            .monospacedDigit()
            .foregroundStyle(banner != nil ? LiveOsa.tone(state.bannerTone) : .white)
            .padding(.trailing, 2)
    }
}

struct LiveNavMinimal: View {
    let state: LiveNavState
    var body: some View {
        if state.hasBanner, let sym = state.bannerSymbol {
            Image(systemName: sym).font(.system(size: 13, weight: .bold)).foregroundStyle(LiveOsa.tone(state.bannerTone))
        } else if state.arrived {
            Image(systemName: "flag.checkered").font(.system(size: 13, weight: .bold)).foregroundStyle(LiveOsa.ok)
        } else {
            LiveArrow(kind: state.kind, exit: nil, size: 20).foregroundStyle(.white)
        }
    }
}

struct LiveNavExpandedLeading: View {
    let state: LiveNavState
    var body: some View {
        Group {
            if state.hasBanner, let sym = state.bannerSymbol {
                LiveToneTile(symbol: sym, tone: state.bannerTone, size: 52)
            } else {
                LiveArrowTile(state: state, size: 52)
            }
        }
        .padding(.leading, 4)
    }
}

struct LiveNavExpandedCenter: View {
    let state: LiveNavState
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if state.hasBanner {
                Text(state.bannerTitle ?? "")
                    .font(.system(size: 19, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let d = state.bannerDetail, !d.isEmpty {
                    Text(d).font(.system(size: 14, weight: .semibold)).foregroundStyle(LiveOsa.dim).lineLimit(1)
                }
            } else {
                Text(state.arrived ? "Arrivé" : LiveOsa.distance(state.distance))
                    .font(.system(size: 30, weight: .heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(state.arrived ? (state.street ?? "") : (state.street ?? state.instruction))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LiveOsa.dim)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 6)
    }
}

struct LiveNavExpandedTrailing: View {
    let state: LiveNavState
    var body: some View {
        Group {
            if state.hasBanner {
                if let t = state.bannerTrailing {
                    Text(t)
                        .font(.system(size: 22, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(LiveOsa.tone(state.bannerTone))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else if !state.arrived {
                LiveETA(state: state, big: 18)
            }
        }
        .padding(.trailing, 4)
    }
}

struct LiveNavExpandedBottom: View {
    let state: LiveNavState
    var body: some View {
        VStack(spacing: 8) {
            if state.arrived {
                LiveProgress(value: 1)
            } else if state.hasBanner {
                // la notification occupe le haut : la prochaine manœuvre reste visible en petit
                HStack(spacing: 8) {
                    LiveArrow(kind: state.kind, exit: nil, size: 22).foregroundStyle(.white)
                    Text(LiveOsa.distance(state.distance)).font(.system(size: 15, weight: .heavy)).monospacedDigit()
                    Text(state.street ?? state.instruction).font(.system(size: 14, weight: .semibold)).foregroundStyle(LiveOsa.dim).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(state.eta, style: .time).font(.system(size: 14, weight: .heavy)).monospacedDigit()
                }
                LiveProgress(value: state.progress)
            } else {
                // une seule ligne en plus de la progression (l'île ouverte ne dépasse pas 160 pt) :
                // alerte, sinon musique, sinon les boutons voix / arrêter
                if let alert = state.alert {
                    LiveNoticeRow(symbol: state.alertSymbol ?? "exclamationmark.triangle.fill", title: alert, tone: state.alertTone,
                                  trailing: state.alertDistance.map(LiveOsa.alertDistance))
                    LiveProgress(value: state.progress)
                } else if state.hasMusic {
                    LiveMusicRow(state: state, buttonSize: 30)
                    LiveProgress(value: state.progress)
                } else {
                    HStack(spacing: 8) {
                        LiveProgress(value: state.progress)
                        LiveIntentButton(intent: LiveVoiceIntent(), symbol: state.voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                         label: state.voiceOn ? "Couper la voix" : "Remettre la voix", size: 30)
                        LiveIntentButton(intent: LiveStopIntent(), symbol: "xmark", label: "Arrêter le guidage", size: 30)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

// MARK: - Guidage : écran verrouillé

/// Grand, lisible d'un coup d'œil : flèche, distance, rue, heure d'arrivée ; une ligne d'état ; progression et boutons.
/// Reste sous 160 pt de haut (limite de l'écran verrouillé).
struct LiveNavLockScreen: View {
    let state: LiveNavState
    let destination: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                LiveArrowTile(state: state, size: 52)
                VStack(alignment: .leading, spacing: 1) {
                    if state.arrived {
                        Text("Vous voilà à destination").font(.system(size: 21, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.8)
                        Text(state.street ?? destination).font(.system(size: 15, weight: .semibold)).foregroundStyle(LiveOsa.dim).lineLimit(1)
                    } else {
                        Text(LiveOsa.distance(state.distance))
                            .font(.system(size: 30, weight: .heavy))
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(state.street ?? state.instruction)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(LiveOsa.dim)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if !state.arrived { LiveETA(state: state, big: 22) }
            }
            if !state.arrived {
                if state.hasBanner, let sym = state.bannerSymbol {
                    LiveNoticeRow(symbol: sym, title: state.bannerTitle ?? "", detail: state.bannerDetail, tone: state.bannerTone,
                                  trailing: state.bannerTrailing)
                } else if let alert = state.alert {
                    LiveNoticeRow(symbol: state.alertSymbol ?? "exclamationmark.triangle.fill", title: alert, tone: state.alertTone,
                                  trailing: state.alertDistance.map(LiveOsa.alertDistance))
                } else if state.hasMusic {
                    LiveMusicRow(state: state, buttonSize: 26)
                }
                HStack(spacing: 8) {
                    LiveProgress(value: state.progress)
                    Text(destination)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiveOsa.faint)
                        .lineLimit(1)
                        .frame(maxWidth: 110, alignment: .trailing)
                    LiveIntentButton(intent: LiveVoiceIntent(), symbol: state.voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                     label: state.voiceOn ? "Couper la voix" : "Remettre la voix", size: 26)
                    LiveIntentButton(intent: LiveStopIntent(), symbol: "xmark", label: "Arrêter le guidage", size: 26)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Un ami arrive

typealias LiveFriendState = FriendActivityAttributes.ContentState

struct LiveFriendAvatar: View {
    let name: String
    let arrived: Bool
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(arrived ? LiveOsa.ok : LiveOsa.glass)
            if arrived {
                Image(systemName: "checkmark").font(.system(size: size * 0.42, weight: .heavy)).foregroundStyle(.black)
            } else {
                Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.46, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct LiveFriendTitle: View {
    let name: String
    let state: LiveFriendState
    var size: CGFloat = 19

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.arrived ? "\(name) est là" : "\(name) arrive")
                .font(.system(size: size, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.8)
            Text(state.arrived ? state.destination : state.stale ? "Position non mise à jour" : "vers \(state.destination)")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(LiveOsa.dim).lineLimit(1)
        }
    }
}

struct LiveFriendETA: View {
    let state: LiveFriendState
    var big: CGFloat = 20

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if let eta = state.eta, !state.arrived {
                Text(eta, style: .time).font(.system(size: big, weight: .heavy)).monospacedDigit()
            }
            if let r = state.remaining, !state.arrived {
                Text(LiveOsa.distance(r)).font(.system(size: 13, weight: .semibold)).foregroundStyle(LiveOsa.dim).monospacedDigit()
            }
        }
    }
}

struct LiveFriendLockScreen: View {
    let name: String
    let state: LiveFriendState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                LiveFriendAvatar(name: name, arrived: state.arrived, size: 48)
                LiveFriendTitle(name: name, state: state, size: 21)
                Spacer(minLength: 4)
                LiveFriendETA(state: state, big: 22)
            }
            if !state.arrived { LiveProgress(value: state.progress) }
        }
        .foregroundStyle(.white)
        .padding(14)
    }
}

struct LiveFriendCompactTrailing: View {
    let state: LiveFriendState
    var body: some View {
        Group {
            if state.arrived {
                Text("Là").foregroundStyle(LiveOsa.ok)
            } else if let eta = state.eta {
                Text(eta, style: .time)
            } else {
                Text("…")
            }
        }
        .font(.system(size: 14, weight: .heavy))
        .monospacedDigit()
        .padding(.trailing, 2)
    }
}
