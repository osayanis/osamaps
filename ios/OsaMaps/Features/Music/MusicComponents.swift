import SwiftUI

/// Pochette (image locale, image web, ou note de musique sur fond sobre).
struct MusicArtworkView: View {
    var artwork: MusicArtwork?
    var size: CGFloat
    var radius: CGFloat = Osa.radiusS

    var body: some View {
        Group {
            switch artwork {
            case .image(let img):
                Image(uiImage: img).resizable().scaledToFill()
            case .url(let url):
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { placeholder }
                }
            case nil:
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Osa.line))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Osa.surfaceHi
            Image(systemName: "music.note").font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(Osa.faint)
        }
    }
}

/// Bouton de commande : précédent / suivant (transparent) ou lecture-pause (rond blanc).
struct MusicControlButton: View {
    var symbol: String
    var label: String
    var size: CGFloat = 56
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? size * 0.38 : size * 0.36, weight: .bold))
                .foregroundStyle(prominent ? Color.black : Osa.text)
                .frame(width: size, height: size)
                .background { if prominent { Circle().fill(.white) } }
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(MusicPress())
        .accessibilityLabel(label)
    }
}

struct MusicPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Les trois commandes, dans l'ordre habituel.
struct MusicControls: View {
    var playing: Bool
    var size: CGFloat = 56
    var playSize: CGFloat = 56
    var spacing: CGFloat = 2
    private var center: MusicCenter { .shared }

    var body: some View {
        HStack(spacing: spacing) {
            MusicControlButton(symbol: "backward.fill", label: "Morceau précédent", size: size) { center.previous() }
            MusicControlButton(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Lecture",
                               size: playSize, prominent: true) { center.toggle() }
            MusicControlButton(symbol: "forward.fill", label: "Morceau suivant", size: size) { center.next() }
        }
    }
}

/// Barre de progression fine, qui avance toute seule pendant la lecture.
struct MusicProgress: View {
    var now: MusicNow
    var showsTimes = false
    /// Version discrète (mini-lecteur de conduite) : plus fine, moins blanche.
    var subtle = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let pos = now.position(now: ctx.date)
            let frac = now.track.duration > 0 ? pos / now.track.duration : 0
            VStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Osa.line)
                        Capsule().fill(Osa.text.opacity(subtle ? 0.45 : 0.75)).frame(width: geo.size.width * frac)
                    }
                }
                .frame(height: subtle ? 2 : 3)
                if showsTimes {
                    HStack {
                        Text(Self.time(pos))
                        Spacer()
                        Text(now.track.duration > 0 ? "-" + Self.time(now.track.duration - pos) : "")
                    }
                    .font(.osa(11.5, .semibold)).monospacedDigit().foregroundStyle(Osa.faint)
                }
            }
        }
        .accessibilityHidden(true)
    }

    static func time(_ s: Double) -> String {
        let t = Int(max(0, s).rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Message ponctuel (Premium requis…) avec le bouton « Ouvrir … ».
struct MusicNoticeRow: View {
    var notice: MusicNotice
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Osa.dim)
            Text(notice.text)
                .font(.osa(compact ? 13 : 14, .medium)).foregroundStyle(Osa.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let s = notice.openSource {
                Button("Ouvrir \(s.label)") { MusicCenter.shared.open(s) }
                    .font(.osa(13, .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 12).frame(minHeight: 36)
                    .background(Color.white, in: Capsule())
                    .buttonStyle(MusicPress())
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Osa.surfaceHi, in: RoundedRectangle(cornerRadius: Osa.radiusM - 2, style: .continuous))
        .transition(.opacity)
    }
}

/// Choix de la source : deux segments, le choisi en blanc.
struct MusicSourcePicker: View {
    @Bindable private var center = MusicCenter.shared

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MusicSource.allCases) { s in
                let on = center.preferred == s
                Button {
                    guard center.preferred != s else { return }
                    Haptic.play("light")
                    withAnimation(Osa.anim) { center.preferred = s }
                } label: {
                    Text(s.label)
                        .font(.osa(15, .bold))
                        .foregroundStyle(on ? Color.black : Osa.dim)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background { if on { Capsule().fill(.white) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Osa.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Osa.line))
    }
}

/// Interrupteur sobre (blanc quand activé).
struct MusicSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 14) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color.white.opacity(0.95) : Osa.surfaceHi)
                        .overlay(Capsule().strokeBorder(configuration.isOn ? .clear : Osa.lineHi))
                    Circle().fill(configuration.isOn ? Color.black : Osa.dim).frame(width: 24, height: 24).padding(4)
                }
                .frame(width: 52, height: 32)
                .animation(.easeOut(duration: 0.18), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "activé" : "désactivé")
    }
}

/// Petit titre de section.
struct MusicLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.osa(12, .bold)).kerning(0.6).foregroundStyle(Osa.faint)
    }
}

/// Bouton secondaire discret (verre clair).
struct MusicGhostButton: View {
    var title: String
    var symbol: String?
    var action: () -> Void
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .bold)) }
                Text(title).lineLimit(1)
            }
            .font(.osa(14, .bold)).foregroundStyle(Osa.text)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(Osa.surfaceHi, in: Capsule())
            .overlay(Capsule().strokeBorder(Osa.line))
        }
        .buttonStyle(MusicPress())
    }
}
