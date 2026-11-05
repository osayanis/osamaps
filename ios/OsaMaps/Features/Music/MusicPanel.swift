import SwiftUI

/// Panneau « Musique » (core.openPanel("music")) : source, lecture en cours, playlists, réglages.
struct MusicSheet: View {
    @Environment(Core.self) private var core

    var body: some View {
        if core.panel == "music" {
            MusicPanelCard { MusicPanel() }
                .id("music-\(core.panelVersion)")
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Carte en verre sombre, défilante si le contenu dépasse (hauteur ajustée au contenu).
struct MusicPanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(18)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .frame(height: min(contentHeight, maxHeight))
        .osaGlass()
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var maxHeight: CGFloat { (UIScreen.main.bounds.height * 0.7).rounded() }
}

struct MusicPanel: View {
    @Environment(Core.self) private var core
    private var center: MusicCenter { .shared }
    @State private var showAll = false

    var body: some View {
        let p = center.provider(center.preferred)
        HStack {
            Text("Musique").font(.osa(22, .heavy)).foregroundStyle(Osa.text)
            Spacer()
            Button {
                core.openPanel(nil)
            } label: { Image(systemName: "xmark").font(.system(size: 15, weight: .bold)) }
            .buttonStyle(OsaRoundStyle(size: 40))
            .accessibilityLabel("Fermer")
        }

        MusicSourcePicker()

        if let n = center.notice { MusicNoticeRow(notice: n) }

        switch p.status {
        case .ready:
            if let now = p.now { MusicNowCard(source: p.source, now: now) } else { emptyNow(p.source) }
            playlists(p)
        case .needsAuth:
            if p.source == .apple {
                MusicStateCard(symbol: "music.note.list", title: "Accède à ta musique",
                               text: "OsaMaps affiche le morceau en cours, le pilote et lance tes playlists, sans quitter le GPS.") {
                    Button("Autoriser l'accès") { Task { await center.apple.requestAccess() } }.buttonStyle(.osaPill)
                }
            } else {
                MusicStateCard(symbol: "person.crop.circle.badge.checkmark", title: "Connecte ton compte Spotify",
                               text: "Pour voir le morceau en cours, tes playlists et piloter la lecture.") {
                    Button(center.spotify.connecting ? "Connexion…" : "Se connecter à Spotify") { center.spotify.connect() }
                        .buttonStyle(.osaPill)
                    if let e = center.spotify.connectError {
                        Text(e).font(.osa(13, .medium)).foregroundStyle(Osa.jam).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .minimal:
            MusicStateCard(symbol: "arrow.up.forward.app", title: "Spotify en mode simple",
                           text: "OsaMaps peut ouvrir Spotify. Pour voir le morceau ici et le piloter, ajoute ton Client ID Spotify dans les réglages ci-dessous.") {
                Button("Ouvrir Spotify") { center.open(.spotify) }.buttonStyle(.osaPill)
            }
        case .unavailable(let why):
            MusicStateCard(symbol: "lock.fill", title: "Accès à la musique refusé", text: why) {
                Button("Ouvrir les Réglages") {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }
                .buttonStyle(.osaPillSecondary)
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            MusicLabel("Réglages")
            MusicSettingsContent(inPanel: true)
                .padding(.horizontal, 14)
                .osaCard()
        }
        .padding(.top, 4)
    }

    private func emptyNow(_ s: MusicSource) -> some View {
        MusicStateCard(symbol: "music.note", title: "Rien en cours de lecture",
                       text: "Choisis une playlist ci-dessous ou lance un morceau dans \(s == .apple ? "Musique" : "Spotify").") {
            MusicGhostButton("Ouvrir \(s == .apple ? "Musique" : "Spotify")", symbol: "arrow.up.forward") { center.open(s) }
        }
    }

    private func playlists(_ p: MusicProvider) -> some View {
        let all = p.playlists
        let favs = center.favorites.compactMap { id in all.first { $0.id == id } }
        let recents = center.recents.compactMap { id in all.first { $0.id == id } }.filter { !center.isFavorite($0) }.prefix(4)
        let limit = 6
        return VStack(alignment: .leading, spacing: 16) {
            if !favs.isEmpty { MusicPlaylistSection(title: "Favorites", items: favs) }
            if !recents.isEmpty { MusicPlaylistSection(title: "Récentes", items: Array(recents)) }
            if all.isEmpty {
                Text(p.source == .apple ? "Aucune playlist dans ta bibliothèque." : "Aucune playlist sur ce compte.")
                    .font(.osa(14, .medium)).foregroundStyle(Osa.dim)
            } else {
                MusicPlaylistSection(title: "Toutes tes playlists · \(all.count)", items: showAll ? all : Array(all.prefix(limit)))
                if all.count > limit {
                    MusicGhostButton(showAll ? "Afficher moins" : "Tout afficher", symbol: showAll ? "chevron.up" : "chevron.down") {
                        withAnimation(Osa.anim) { showAll.toggle() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: p.source) { await p.loadPlaylists() }
    }
}

/// Lecture en cours, en grand.
struct MusicNowCard: View {
    var source: MusicSource
    var now: MusicNow

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                MusicArtworkView(artwork: now.track.artwork, size: 76, radius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(now.track.title).font(.osa(19, .heavy)).foregroundStyle(Osa.text).lineLimit(2)
                    if !now.track.artist.isEmpty {
                        Text(now.track.artist).font(.osa(15, .semibold)).foregroundStyle(Osa.dim).lineLimit(1)
                    }
                    Text(now.track.album.isEmpty ? source.label : "\(now.track.album) · \(source.label)")
                        .font(.osa(12.5, .medium)).foregroundStyle(Osa.faint).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            if now.track.duration > 0 { MusicProgress(now: now, showsTimes: true) }
            MusicControls(playing: now.playing, size: 60, playSize: 64, spacing: 22)
        }
        .padding(14)
        .osaCard()
    }
}

/// Carte d'état (accès à demander, rien en cours…), sobre et centrée.
struct MusicStateCard<Actions: View>: View {
    var symbol: String
    var title: String
    var text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(Osa.dim)
                .frame(width: 48, height: 48)
                .background(Osa.surfaceHi, in: Circle())
                .overlay(Circle().strokeBorder(Osa.line))
            Text(title).font(.osa(17, .bold)).foregroundStyle(Osa.text)
            Text(text).font(.osa(14, .medium)).foregroundStyle(Osa.dim)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            actions.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 18)
        .osaCard()
    }
}

struct MusicPlaylistSection: View {
    var title: String
    var items: [MusicPlaylist]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MusicLabel(title)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, p in
                    MusicPlaylistRow(playlist: p)
                        .overlay(alignment: .top) {
                            if i > 0 { Rectangle().fill(Osa.line).frame(height: 1).padding(.leading, 66) }
                        }
                }
            }
            .osaCard()
        }
    }
}

struct MusicPlaylistRow: View {
    var playlist: MusicPlaylist
    private var center: MusicCenter { .shared }

    var body: some View {
        HStack(spacing: 0) {
            Button { center.play(playlist) } label: {
                HStack(spacing: 12) {
                    MusicArtworkView(artwork: playlist.artwork, size: 44, radius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name).font(.osa(15.5, .bold)).foregroundStyle(Osa.text).lineLimit(1)
                        if let n = playlist.count {
                            Text("\(n) titre\(n > 1 ? "s" : "")").font(.osa(12.5, .medium)).foregroundStyle(Osa.dim)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Osa.faint)
                }
                .padding(.leading, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(MusicPress())
            .accessibilityLabel("Lancer \(playlist.name)")

            let fav = center.isFavorite(playlist)
            Button { center.toggleFavorite(playlist) } label: {
                Image(systemName: fav ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(fav ? Osa.text : Osa.faint)
                    .frame(width: 48, height: 52)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(MusicPress())
            .accessibilityLabel(fav ? "Retirer des favorites" : "Ajouter aux favorites")
        }
    }
}
