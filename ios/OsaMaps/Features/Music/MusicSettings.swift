import SwiftUI

/// Section « Musique » de l'écran Réglages.
struct MusicSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Musique")
                .font(.osa(17, .bold))
                .padding(.top, 14).padding(.bottom, 4)
            MusicSettingsContent(inPanel: false)
        }
        .foregroundStyle(Osa.text)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .osaCard()
    }
}

/// Contenu des réglages (écran Réglages et bas du panneau Musique) :
/// mini-lecteur, source, Apple Music, Spotify (Client ID + mode d'emploi).
struct MusicSettingsContent: View {
    var inPanel: Bool
    @Bindable private var center = MusicCenter.shared
    @Bindable private var spotify = MusicCenter.shared.spotify
    @State private var showHelp = false
    @State private var copied = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $center.miniPlayer) {
                row("Mini-lecteur en conduite", "Pochette et commandes sous la flèche de guidage")
            }
            .toggleStyle(MusicSwitch())
            .padding(.vertical, 14)

            if !inPanel {
                VStack(alignment: .leading, spacing: 10) {
                    row("Source préférée", "Affichée en priorité ; l'autre prend le relais si elle joue")
                    MusicSourcePicker()
                }
                .padding(.vertical, 14)
                .overlay(alignment: .top) { divider }
            }

            appleRow
                .padding(.vertical, 14)
                .overlay(alignment: .top) { divider }

            spotifyBlock
                .padding(.vertical, 14)
                .overlay(alignment: .top) { divider }
        }
        .foregroundStyle(Osa.text)
    }

    private var divider: some View { Rectangle().fill(Osa.line).frame(height: 1) }

    private func row(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.osa(16, .semibold))
            Text(hint).font(.osa(13, .regular)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Apple Music

    private var appleRow: some View {
        HStack(spacing: 12) {
            switch center.apple.status {
            case .ready:
                row("Apple Music", "Accès autorisé : lecture en cours et playlists de ta bibliothèque")
                Spacer(minLength: 0)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Osa.ok).font(.system(size: 20))
            case .needsAuth:
                row("Apple Music", "Autorise l'accès pour voir et piloter ta musique")
                Spacer(minLength: 0)
                MusicGhostButton("Autoriser") { Task { await center.apple.requestAccess() } }
            case .unavailable(let why):
                row("Apple Music", why)
            case .minimal:
                row("Apple Music", "")
            }
        }
    }

    // MARK: - Spotify

    private var spotifyBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Spotify", spotifyHint)

            VStack(alignment: .leading, spacing: 6) {
                Text("Client ID Spotify").font(.osa(13, .bold)).foregroundStyle(Osa.dim)
                TextField("", text: $spotify.clientId, prompt: Text("32 caractères, ex. 1a2b3c…").foregroundStyle(Osa.faint))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.done)
                    .focused($editing)
                    .padding(.horizontal, 12).frame(minHeight: 46)
                    .background(Osa.surface, in: RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous)
                        .strokeBorder(editing ? Osa.lineHi : Osa.line))
                if !spotify.clientId.isEmpty && !MusicSpotify.validClientId(spotify.clientId) {
                    Text("Un Client ID fait 32 caractères (chiffres et lettres a à f).")
                        .font(.osa(12.5, .medium)).foregroundStyle(Osa.slow)
                }
            }

            switch spotify.status {
            case .ready:
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Osa.ok).font(.system(size: 18))
                    Text(spotify.accountName.map { "Connecté : \($0)" } ?? "Connecté")
                        .font(.osa(15, .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    MusicGhostButton("Se déconnecter") { spotify.disconnect() }
                }
            case .needsAuth:
                Button(spotify.connecting ? "Connexion…" : "Se connecter à Spotify") {
                    editing = false
                    spotify.connect()
                }
                .buttonStyle(.osaPill)
                .disabled(spotify.connecting)
            default:
                EmptyView()
            }
            if let e = spotify.connectError {
                Text(e).font(.osa(13, .medium)).foregroundStyle(Osa.jam).fixedSize(horizontal: false, vertical: true)
            }

            Button {
                withAnimation(Osa.anim) { showHelp.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Obtenir un Client ID (5 minutes)").font(.osa(14, .bold))
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                        .rotationEffect(.degrees(showHelp ? 180 : 0))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Osa.text)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showHelp { help.transition(.opacity) }
        }
    }

    private var spotifyHint: String {
        switch spotify.status {
        case .minimal: "Sans Client ID, OsaMaps ouvre seulement Spotify. Avec, il affiche le morceau, tes playlists et pilote la lecture."
        case .needsAuth: "Client ID enregistré : connecte ton compte."
        case .ready: "Morceau en cours et playlists ; les commandes demandent Premium."
        case .unavailable(let why): why
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Sur developer.spotify.com, ouvre le Dashboard et connecte-toi avec ton compte Spotify (accepte les conditions la première fois).")
            MusicGhostButton("Ouvrir le Dashboard Spotify", symbol: "arrow.up.forward") {
                if let u = URL(string: "https://developer.spotify.com/dashboard") { UIApplication.shared.open(u) }
            }
            .padding(.leading, 34)
            step(2, "« Create app » : nom « OsaMaps », une description au choix (ex. « GPS perso »).")
            step(3, "Redirect URIs : colle exactement cette adresse, puis « Add » :")
            HStack(spacing: 8) {
                Text(MusicSpotify.redirectURI)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                MusicGhostButton(copied ? "Copié" : "Copier", symbol: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = MusicSpotify.redirectURI
                    Haptic.play("success")
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
            }
            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
            .background(Osa.surface, in: RoundedRectangle(cornerRadius: Osa.radiusS, style: .continuous))
            .padding(.leading, 34)
            step(4, "« Which API/SDKs are you planning to use? » : coche « Web API », accepte les conditions, puis « Save ».")
            step(5, "Ouvre l'app créée › « Settings » : copie le « Client ID », colle-le dans le champ ci-dessus, puis « Se connecter à Spotify ».")
            Text("Bon à savoir : Spotify demande que le propriétaire d'une app en mode développement ait un abonnement Premium. Sans Premium, OsaMaps reste en mode simple et ouvre Spotify. Le Client ID n'est pas un secret, aucun mot de passe n'est enregistré.")
                .font(.osa(12.5, .medium)).foregroundStyle(Osa.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.osa(13, .heavy)).foregroundStyle(.black)
                .frame(width: 24, height: 24).background(Color.white, in: Circle())
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 7 }
            Text(text).font(.osa(14, .medium)).foregroundStyle(Osa.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
