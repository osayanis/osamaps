import SwiftUI

/// Bouton du rail : ouvre le panneau Musique. Hors conduite toujours ; en conduite seulement
/// quand le mini-lecteur n'est pas là (rien ne joue, ou mini-lecteur désactivé), pour lancer une playlist.
struct MusicRail: View {
    @Environment(Core.self) private var core
    private var center: MusicCenter { .shared }

    var body: some View {
        let playing = center.current?.now.playing == true
        let drive = core.mode == .drive
        if !drive || !center.showsMiniPlayer {
            Button {
                Haptic.play("light")
                core.openPanel(core.panel == "music" ? nil : "music")
            } label: {
                Image(systemName: "music.note")
                    .overlay(alignment: .topTrailing) {
                        if playing {
                            Circle().fill(Color.white).frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(Osa.bg, lineWidth: 2))
                                .offset(x: 11, y: -9)
                        }
                    }
            }
            .buttonStyle(OsaRoundStyle(size: drive ? 56 : 48))
            .accessibilityLabel(playing ? "Musique, lecture en cours" : "Musique")
            .transition(.opacity)
        }
    }
}
