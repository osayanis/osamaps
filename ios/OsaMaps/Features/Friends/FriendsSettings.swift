import SwiftUI

/// Section « Amis et partage » de l'écran Réglages.
struct FriendsSettings: View {
    @Bindable private var prefs = Prefs.shared
    @State private var store = FriendsStore.shared
    @State private var confirm = false
    @State private var deleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Amis et partage").font(.osa(17, .bold)).foregroundStyle(Osa.text)

            VStack(alignment: .leading, spacing: 6) {
                FriendsLabel("Pseudo")
                FriendsNicknameField()
            }

            row("Partager ma position avec mes amis",
                "Seuls tes amis acceptés te voient. Ta position n'est jamais enregistrée : elle disparaît 5 min après la dernière mise à jour.") {
                Toggle("Partager ma position", isOn: $prefs.shareLocation).labelsHidden().tint(Osa.ok)
            }

            row("Montrer ma destination",
                "En conduite, tes amis voient « en route vers … · arrivée 18 h 42 ». Sinon, seulement « en route ».") {
                Toggle("Montrer ma destination", isOn: Binding(get: { store.showDest }, set: { store.setShowDest($0) }))
                    .labelsHidden().tint(Osa.ok)
            }
            .opacity(prefs.shareLocation ? 1 : 0.45)

            if let me = store.me {
                HStack(spacing: 4) {
                    Text("Mon code ami :").foregroundStyle(Osa.dim)
                    Text(FriendsUtil.prettyCode(me.code)).foregroundStyle(Osa.text).monospacedDigit()
                }
                .font(.osa(14, .semibold))
            }

            Divider().overlay(Osa.line)
            VStack(alignment: .leading, spacing: 8) {
                Text("Supprimer mes données").font(.osa(15, .bold)).foregroundStyle(Osa.text)
                Text("Efface ton pseudo, tes amis, tes demandes et tes trajets partagés du serveur.")
                    .font(.osa(13, .medium)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if deleting {
                        ProgressView().tint(Osa.dim).frame(minHeight: 44)
                    } else if confirm {
                        FriendsGhostButton("Annuler") { confirm = false }
                        FriendsGhostButton("Supprimer vraiment", danger: true) {
                            deleting = true
                            Task {
                                await store.deleteMyData()
                                deleting = false
                                confirm = false
                            }
                        }
                    } else {
                        FriendsGhostButton("Supprimer", danger: true) { confirm = true }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .osaCard()
    }

    private func row<C: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.osa(15, .bold)).foregroundStyle(Osa.text)
                Text(detail).font(.osa(13, .medium)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Osa.line).frame(height: 1) }
    }
}
