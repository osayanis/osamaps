import SwiftUI

/// Section Réglages « Mes lieux » : Maison, Travail, favoris, voiture, historique.
struct SearchSettingsView: View {
    @State private var search = SearchState.shared
    @State private var editing: String?
    @State private var draft = ""
    @State private var confirmClear = false
    @FocusState private var editFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Mes lieux")
                .font(.osa(20, .bold))
                .foregroundStyle(Osa.text)
                .padding(.bottom, 8)

            shortcut(.home, search.home)
            shortcut(.work, search.work)

            divider
            HStack {
                Text("Favoris").font(.osa(15, .bold)).foregroundStyle(Osa.dim)
                Spacer()
                Button { search.startPicking(.favorite) } label: {
                    Label("Ajouter", systemImage: "plus").font(.osa(14, .semibold))
                }
                .foregroundStyle(Osa.text)
            }
            .padding(.vertical, 6)
            if search.favorites.isEmpty {
                note("Ajoutez un lieu en favori depuis sa fiche (étoile).")
            }
            ForEach(search.favorites) { f in favoriteRow(f) }

            divider
            row(symbol: "car.fill", title: "Ma voiture",
                sub: search.car.map { c in
                    "Garée \(c.time.map { SearchFormat.ago($0) } ?? "")" + (c.detail.map { " · \($0)" } ?? "")
                } ?? "Enregistrée automatiquement à l'arrivée") {
                if search.car != nil {
                    textButton("Oublier") {
                        search.forgetCar()
                        search.toast("Stationnement oublié", icon: "car.fill")
                    }
                }
            }

            divider
            let n = search.recents.count
            row(symbol: "clock.arrow.circlepath", title: "Historique de recherche",
                sub: n > 0 ? "\(n) lieu\(n > 1 ? "x" : "") récent\(n > 1 ? "s" : ""), gardés sur cet appareil" : "Vide") {
                if n > 0 {
                    if confirmClear {
                        Button("Confirmer") {
                            search.clearRecents()
                            confirmClear = false
                            Haptic.play("success")
                            search.toast("Historique effacé", icon: "checkmark", tone: .good)
                        }
                        .font(.osa(14, .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(Osa.jam, in: Capsule())
                    } else {
                        textButton("Effacer") { withAnimation(Osa.anim) { confirmClear = true } }
                    }
                }
            }
        }
        .padding(16)
        .osaCard()
    }

    private var divider: some View {
        Rectangle().fill(Osa.line).frame(height: 1).padding(.vertical, 8)
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.osa(13, .medium)).foregroundStyle(Osa.faint).padding(.vertical, 4)
    }

    private func textButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.osa(14, .semibold))
            .foregroundStyle(Osa.text)
            .padding(.horizontal, 12).frame(height: 34)
            .background(Osa.surfaceHi, in: Capsule())
    }

    private func row<Trailing: View>(symbol: String, title: String, sub: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            SearchBadge(symbol: symbol, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.osa(15, .semibold)).foregroundStyle(Osa.text)
                Text(sub).font(.osa(13, .medium)).foregroundStyle(Osa.dim).lineLimit(2)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.vertical, 6)
    }

    private func shortcut(_ which: SearchPick, _ p: SearchSaved?) -> some View {
        let title = which == .home ? "Maison" : "Travail"
        let sub = p.map { s in s.detail.map { d in "\(s.name), \(d)" } ?? s.name } ?? (which == .home ? "Non définie" : "Non défini")
        return row(symbol: which.symbol, title: title, sub: sub) {
            textButton(p == nil ? "Définir" : "Modifier") { search.startPicking(which) }
            if p != nil {
                Button { search.setShortcut(which, nil) } label: {
                    Image(systemName: "trash").font(.system(size: 14, weight: .semibold)).foregroundStyle(Osa.dim)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Retirer \(title)")
            }
        }
    }

    @ViewBuilder private func favoriteRow(_ f: SearchSaved) -> some View {
        if editing == f.id {
            HStack(spacing: 10) {
                SearchBadge(symbol: "star.fill", size: 34)
                TextField("Nouveau nom", text: $draft)
                    .font(.osa(15, .semibold))
                    .foregroundStyle(Osa.text)
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(Osa.surfaceHi, in: RoundedRectangle(cornerRadius: Osa.radiusS))
                    .focused($editFocused)
                    .submitLabel(.done)
                    .onSubmit { commit(f.id) }
                    .onChange(of: draft) { _, v in if v.count > 60 { draft = String(v.prefix(60)) } }
                Button { commit(f.id) } label: {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 34, height: 34).background(Color.white, in: Circle())
                }
                .accessibilityLabel("Valider")
            }
            .padding(.vertical, 6)
            .onAppear { editFocused = true }
        } else {
            row(symbol: "star.fill", title: f.name, sub: f.detail ?? SearchFormat.coord(f.coordinate)) {
                Button { editing = f.id; draft = f.name } label: {
                    Image(systemName: "pencil").font(.system(size: 14, weight: .semibold)).foregroundStyle(Osa.dim)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Renommer \(f.name)")
                Button { withAnimation(Osa.anim) { search.removeFavorite(f.id) } } label: {
                    Image(systemName: "trash").font(.system(size: 14, weight: .semibold)).foregroundStyle(Osa.dim)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Supprimer \(f.name)")
            }
        }
    }

    private func commit(_ id: String) {
        search.renameFavorite(id, draft)
        editing = nil
    }
}
