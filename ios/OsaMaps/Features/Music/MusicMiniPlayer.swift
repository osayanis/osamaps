import SwiftUI

/// Mini-lecteur de conduite (slot .hud, order 90 : sous la carte de manœuvre et les alertes).
/// En bas, au-dessus de la barre de guidage, il cachait la mascotte : en conduite la caméra garde la position
/// au même endroit quel que soit le panneau du bas (MapView ignore sheetHeight). En haut il ne couvre que la
/// route lointaine. N'apparaît qu'en conduite, quand un morceau est là (et pas avec le panneau Musique ouvert).
/// Une seule ligne : pochette + titre/artiste (touchés → panneau Musique) et les trois commandes de 56 pt.
struct MusicMiniPlayer: View {
    @Environment(Core.self) private var core
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var center: MusicCenter { .shared }

    var body: some View {
        Group {
            if core.mode == .drive, core.panel != "music", center.miniPlayer, let c = center.current {
                card(c.source, c.now)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Osa.anim, value: center.current?.now.track.id)
        .animation(Osa.anim, value: center.notice)
    }

    private func card(_ source: MusicSource, _ now: MusicNow) -> some View {
        VStack(spacing: 8) {
            if let n = center.notice { MusicNoticeRow(notice: n, compact: true) }
            HStack(spacing: 4) {
                Button {
                    Haptic.play("light")
                    core.openPanel("music")
                } label: {
                    HStack(spacing: 11) {
                        MusicArtworkView(artwork: now.track.artwork, size: 46, radius: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(now.track.title)
                                .font(.osa(15.5, .bold)).foregroundStyle(Osa.text)
                            Text(now.track.artist.isEmpty ? source.label : now.track.artist)
                                .font(.osa(13, .semibold)).foregroundStyle(Osa.dim)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MusicPress())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(now.track.title), \(now.track.artist). \(source.label)")
                .accessibilityHint("Ouvre le panneau Musique")

                MusicControls(playing: now.playing, size: 56, playSize: 56, spacing: 0)
                    .frame(minHeight: 56)
            }
        }
        .padding(.leading, 6).padding(.trailing, 2).padding(.vertical, 2)
        .padding(6)
        .overlay(alignment: .bottom) {
            MusicProgress(now: now, subtle: true)
                .padding(.horizontal, 22)
                .padding(.bottom, 1)
                .opacity(now.track.duration > 0 ? 1 : 0)
        }
        .osaGlass(22)
    }
}
