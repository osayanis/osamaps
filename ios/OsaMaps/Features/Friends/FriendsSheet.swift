import SwiftUI
import CoreLocation

/// Panneau du bas du module : n'apparaît que si `core.panel` lui appartient.
/// Panneaux : "friends" (liste), "friend" (fiche, data = pid), "share" (mon trajet partagé),
/// "friends-invite" (lien d'invitation, data = code), "friends-follow" (suivre un trajet, data = jeton).
struct FriendsSheet: View {
    @Environment(Core.self) private var core
    static let panels: Set<String> = ["friends", "friend", "share", "friends-invite", "friends-follow"]

    var body: some View {
        if let p = core.panel, Self.panels.contains(p) {
            Group {
                if p == "friends-follow" {
                    FriendsFollowSheet()
                } else {
                    FriendsPanelCard {
                        switch p {
                        case "friend": FriendsDetail(pid: core.panelData as? String ?? "")
                        case "share": FriendsShareTrip()
                        case "friends-invite": FriendsInvite(code: core.panelData as? String ?? "")
                        default: FriendsList()
                        }
                    }
                }
            }
            .id("\(p)-\(core.panelVersion)")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Carte en verre sombre, défilante si le contenu dépasse (hauteur ajustée au contenu).
struct FriendsPanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 200

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
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

    private var maxHeight: CGFloat { (UIScreen.main.bounds.height * 0.66).rounded() }
}

// MARK: - Liste

struct FriendsList: View {
    @State private var store = FriendsStore.shared
    @Environment(Core.self) private var core
    @Environment(Prefs.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        FriendsHead(title: "Amis")

        if store.status == .error {
            HStack(spacing: 8) {
                Text(store.error ?? "Connexion impossible.").font(.osa(14, .medium)).foregroundStyle(Osa.jam)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                FriendsGhostButton("Réessayer") { store.reconnect() }
            }
        } else if store.status != .ready {
            HStack(spacing: 8) { ProgressView().tint(Osa.dim); Text("Connexion…") }
                .font(.osa(14, .medium)).foregroundStyle(Osa.dim)
        }

        if store.nickname.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FriendsLabel("Choisis un pseudo pour que tes amis te reconnaissent")
                FriendsNicknameField(placeholder: "Ton pseudo")
            }
        }

        if let me = store.me { myCode(me) }

        FriendsAddForm()

        if !store.incoming.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FriendsLabel("Demandes reçues")
                ForEach(store.incoming) { r in
                    HStack(spacing: 12) {
                        FriendsAvatar(name: r.name ?? "?")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name ?? "Quelqu'un").font(.osa(16, .bold)).foregroundStyle(Osa.text).lineLimit(1)
                            Text("veut t'ajouter").font(.osa(13, .medium)).foregroundStyle(Osa.dim)
                        }
                        Spacer(minLength: 4)
                        FriendsGhostButton("Refuser") { Task { await store.respond(r.pid, accept: false) } }
                        Button("Accepter") { Task { await store.respond(r.pid, accept: true) } }.buttonStyle(.osaPill)
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            FriendsLabel(store.friends.isEmpty ? "Mes amis" : "Mes amis · \(store.friends.count)")
            if store.friends.isEmpty {
                Text("Pas encore d'amis. Donne ton code ou envoie ton lien d'invitation.")
                    .font(.osa(14, .medium)).foregroundStyle(Osa.dim).padding(.top, 4)
            }
            ForEach(sorted) { f in
                Button { core.openPanel("friend", data: f.pid) } label: { row(f) }
                    .buttonStyle(.plain)
            }
        }

        if !prefs.shareLocation && !store.friends.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Osa.dim).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ta position n'est pas partagée").font(.osa(15, .bold)).foregroundStyle(Osa.text)
                    Text("Si tu l'actives, seuls tes amis acceptés te voient sur la carte. Rien n'est enregistré : ta position s'efface quelques minutes après ton dernier passage.")
                        .font(.osa(13, .medium)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
                    Button("Partager avec mes amis") { prefs.shareLocation = true; Haptic.play("success") }
                        .buttonStyle(.osaPillSecondary).padding(.top, 4)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .osaCard()
        }

        if !store.outgoing.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FriendsLabel("Demandes envoyées")
                ForEach(store.outgoing) { r in
                    HStack(spacing: 12) {
                        FriendsAvatar(name: "?")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Code \(FriendsUtil.prettyCode(r.code))").font(.osa(16, .bold)).foregroundStyle(Osa.text)
                            Text("En attente de réponse").font(.osa(13, .medium)).foregroundStyle(Osa.dim)
                        }
                        Spacer(minLength: 4)
                        FriendsGhostButton("Annuler") { Task { await store.removeFriend(r.pid) } }
                    }
                }
            }
        }
    }

    /// Ceux qui conduisent, puis ceux qui partagent, puis en ligne, puis par nom.
    private var sorted: [FriendsFriend] {
        store.friends.sorted { a, b in
            let ka = (a.loc?.drive != nil ? 0 : 1, a.loc != nil ? 0 : 1, a.online ? 0 : 1)
            let kb = (b.loc?.drive != nil ? 0 : 1, b.loc != nil ? 0 : 1, b.online ? 0 : 1)
            if ka != kb { return ka < kb }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    private func row(_ f: FriendsFriend) -> some View {
        var status = FriendsUtil.statusLine(f)
        if let loc = f.loc, loc.drive == nil, let p = core.position {
            status += " · \(Geo.formatDistance(Geo.distance(p.coordinate, loc.coordinate)))"
        }
        return HStack(spacing: 12) {
            FriendsAvatar(name: f.name, live: f.loc != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(.osa(16, .bold)).foregroundStyle(Osa.text).lineLimit(1)
                Text(status).font(.osa(13, .medium)).lineLimit(1)
                    .foregroundStyle(f.loc?.drive != nil ? Osa.ok : f.online ? Osa.text.opacity(0.8) : Osa.dim)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Osa.faint)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvre la fiche")
    }

    private func myCode(_ me: FriendsMe) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                FriendsLabel("Mon code ami")
                Text(FriendsUtil.prettyCode(me.code)).font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Osa.text).monospacedDigit()
                    .accessibilityLabel("Mon code ami : \(me.code.map(String.init).joined(separator: " "))")
            }
            Spacer(minLength: 4)
            Button {
                UIPasteboard.general.string = me.code
                Haptic.play("success")
                emit(.toast(Toast(text: "Code copié", icon: "doc.on.doc", tone: .good)))
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(OsaRoundStyle(size: 44))
                .accessibilityLabel("Copier mon code")
            if let url = store.inviteURL {
                ShareLink(item: url, subject: Text("OsaMaps"), message: Text(store.inviteMessage)) {
                    Label("Inviter", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.osaPill)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .osaCard()
    }
}

/// Ajout par code à 6 chiffres.
struct FriendsAddForm: View {
    @State private var store = FriendsStore.shared
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        let digits = code.filter(\.isNumber)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("", text: $code, prompt: Text("Code ami à 6 chiffres").foregroundStyle(Osa.faint))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .onChange(of: code) { _, v in
                        let d = String(v.filter(\.isNumber).prefix(6))
                        let pretty = d.count > 3 ? "\(d.prefix(3)) \(d.dropFirst(3))" : d
                        if pretty != v { code = pretty }
                        error = nil
                    }
                    .modifier(FriendsField())
                    .accessibilityLabel("Code ami")
                Button {
                    focused = false
                    busy = true
                    Task {
                        let err = await store.addFriend(digits)
                        busy = false
                        error = err
                        if err == nil { code = "" } else { Haptic.play("error") }
                    }
                } label: {
                    if busy { ProgressView().tint(.black) } else { Text("Ajouter") }
                }
                .buttonStyle(.osaPill)
                .disabled(digits.count != 6 || busy || store.status != .ready)
                .opacity(digits.count != 6 || store.status != .ready ? 0.4 : 1)
            }
            if let error {
                Text(error).font(.osa(13, .semibold)).foregroundStyle(Osa.jam)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
}

// MARK: - Fiche d'un ami

struct FriendsDetail: View {
    var pid: String
    @State private var store = FriendsStore.shared
    @Environment(Core.self) private var core
    @State private var confirm = false
    @State private var busy = false

    var body: some View {
        let back = { core.openPanel("friends") }
        if let f = store.friends.first(where: { $0.pid == pid }) {
            let at = f.loc?.coordinate
            let away = at.flatMap { a in core.position.map { Geo.distance($0.coordinate, a) } }
            FriendsHead(title: f.name, back: back)
            HStack(spacing: 14) {
                FriendsAvatar(name: f.name, live: f.loc != nil, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(FriendsUtil.statusLine(f)).font(.osa(16, .bold))
                        .foregroundStyle(f.loc?.drive != nil ? Osa.ok : Osa.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(away.map { "À \(Geo.formatDistance($0)) de toi" } ?? (f.loc != nil ? "Position partagée" : "Ne partage pas sa position"))
                        .font(.osa(14, .medium)).foregroundStyle(Osa.dim)
                }
            }
            .accessibilityElement(children: .combine)

            if let at {
                HStack(spacing: 10) {
                    Button {
                        core.openPanel(nil)
                        emit(.placeGo(Place(id: "friend-\(f.pid)", name: f.name, detail: "Position de ton ami", coordinate: at, kind: "friend")))
                    } label: { Label("Rejoindre", systemImage: "location.north.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.osaPill)
                    Button { meet(f, at) } label: {
                        Group {
                            if busy { Text("Recherche…") } else { Label("À mi-chemin", systemImage: "point.3.connected.trianglepath.dotted") }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.osaPillSecondary)
                    .disabled(core.position == nil || busy)
                    .opacity(core.position == nil ? 0.4 : 1)
                }
            } else {
                Text("Quand \(f.name) partagera sa position, tu pourras le rejoindre ou vous retrouver à mi-chemin.")
                    .font(.osa(14, .medium)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Osa.line)
            HStack {
                Text("Code \(FriendsUtil.prettyCode(f.code))").font(.osa(13, .medium)).foregroundStyle(Osa.faint)
                Spacer()
                if confirm {
                    FriendsGhostButton("Garder") { confirm = false }
                    FriendsGhostButton("Retirer vraiment", danger: true) {
                        Task { await store.removeFriend(f.pid) }
                        back()
                    }
                } else {
                    FriendsGhostButton("Retirer de mes amis") { confirm = true }
                }
            }
            .onAppear { look(at) }
        } else {
            FriendsHead(title: "Ami", back: back)
            Text("Cet ami n'est plus dans ta liste.").font(.osa(14, .medium)).foregroundStyle(Osa.dim)
        }
    }

    /// À l'ouverture, la carte va voir où il est.
    private func look(_ at: CLLocationCoordinate2D?) {
        guard let at else { return }
        let d = 0.006
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120)) // laisse le panneau prendre sa hauteur
            MapHub.fit([.init(latitude: at.latitude - d, longitude: at.longitude - d),
                        .init(latitude: at.latitude + d, longitude: at.longitude + d)])
        }
    }

    private func meet(_ f: FriendsFriend, _ at: CLLocationCoordinate2D) {
        guard let p = core.position?.coordinate else { return }
        busy = true
        Task {
            let mid = FriendsUtil.midpoint(p, at)
            let city = await FriendsUtil.reverseName(mid)
            busy = false
            core.openPanel(nil)
            emit(.placeGo(Place(name: city.map { "Mi-chemin · \($0)" } ?? "Point à mi-chemin",
                                detail: "Entre toi et \(f.name)", coordinate: mid, kind: "friend")))
        }
    }
}

// MARK: - Mon trajet partagé

struct FriendsShareTrip: View {
    @State private var store = FriendsStore.shared
    @Environment(Core.self) private var core
    @State private var busy = false

    var body: some View {
        if let trip = store.trip {
            FriendsHead(title: "Trajet partagé")
            HStack(spacing: 14) {
                FriendsLiveDot()
                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.watchers > 0 ? "\(trip.watchers) personne\(trip.watchers > 1 ? "s" : "") te sui\(trip.watchers > 1 ? "vent" : "t")" : "Lien actif")
                        .font(.osa(16, .bold)).foregroundStyle(Osa.text)
                    Text("Vers \(core.destination?.name ?? "ta destination") · s'arrête 30 min après l'arrivée")
                        .font(.osa(13, .medium)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).osaCard()
            HStack(spacing: 10) {
                ShareLink(item: trip.url, subject: Text("Mon trajet"), message: Text(store.tripMessage)) {
                    Label("Envoyer", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.osaPill)
                Button {
                    UIPasteboard.general.url = trip.url
                    Haptic.play("success")
                    emit(.toast(Toast(text: "Lien copié", icon: "doc.on.doc", tone: .good)))
                } label: { Label("Copier", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                    .buttonStyle(.osaPillSecondary)
            }
            HStack {
                Spacer()
                FriendsGhostButton("Arrêter le partage", danger: true) {
                    Task { await store.stopTrip() }
                    core.openPanel(nil)
                }
            }
        } else {
            FriendsHead(title: "Partager mon trajet")
            Text("Envoie un lien : la personne voit ta voiture avancer et ton heure d'arrivée, sans rien installer. Le lien s'arrête 30 min après ton arrivée.")
                .font(.osa(14, .medium)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
            Button {
                busy = true
                Task {
                    if let t = await store.startTrip() { FriendsUtil.presentShare([store.tripMessage, t.url]) }
                    busy = false
                }
            } label: {
                Group { if busy { ProgressView().tint(.black) } else { Label("Créer le lien", systemImage: "square.and.arrow.up") } }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.osaPill)
            .disabled(core.mode != .drive || busy)
            .opacity(core.mode != .drive ? 0.4 : 1)
        }
    }
}

// MARK: - Invitation reçue

struct FriendsInvite: View {
    var code: String
    @State private var store = FriendsStore.shared
    @Environment(Core.self) private var core
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        FriendsHead(title: "Ajouter un ami")
        Text("Quelqu'un t'a invité sur OsaMaps. Envoie-lui une demande : il pourra l'accepter, puis vous pourrez partager vos positions si vous le souhaitez.")
            .font(.osa(14, .medium)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 2) {
            FriendsLabel("Code")
            Text(FriendsUtil.prettyCode(code)).font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Osa.text).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .osaCard()
        if store.nickname.isEmpty {
            FriendsLabel("Ton pseudo")
            FriendsNicknameField(placeholder: "Ton pseudo")
        }
        if let error { Text(error).font(.osa(13, .semibold)).foregroundStyle(Osa.jam) }
        HStack(spacing: 10) {
            FriendsGhostButton("Plus tard") { core.openPanel(nil) }
            Button {
                busy = true
                Task {
                    let err = await store.addFriend(code)
                    busy = false
                    if let err { error = err; Haptic.play("error") } else { core.openPanel("friends") }
                }
            } label: {
                Group { if busy { ProgressView().tint(.black) } else { Text("Envoyer la demande") } }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.osaPill)
            .disabled(store.status != .ready || busy)
            .opacity(store.status != .ready ? 0.4 : 1)
        }
    }
}
