import SwiftUI

/// Rail de droite : « Amis » (hors conduite, avec le nombre de demandes) et « Partager mon trajet » (en conduite).
struct FriendsRail: View {
    @Environment(Core.self) private var core
    @State private var store = FriendsStore.shared
    @State private var busy = false

    var body: some View {
        if FriendsFollow.shared.token != nil && core.panel == "friends-follow" {
            EmptyView()
        } else if core.mode == .drive {
            Button(action: shareTap) {
                Image(systemName: busy ? "ellipsis" : "square.and.arrow.up")
                    .overlay(alignment: .topTrailing) {
                        if store.trip != nil {
                            Circle().fill(Osa.ok).frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                                .offset(x: 12, y: -10)
                        }
                    }
            }
            .buttonStyle(OsaRoundStyle(size: 56))
            .accessibilityLabel(store.trip != nil ? "Trajet partagé" : "Partager mon trajet")
        } else {
            Button {
                core.openPanel(core.panel == "friends" ? nil : "friends")
            } label: {
                Image(systemName: "person.2.fill")
                    .overlay(alignment: .topTrailing) {
                        if store.pendingCount > 0 {
                            Text("\(store.pendingCount)")
                                .font(.osa(12, .heavy)).foregroundStyle(.black)
                                .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                                .background(Color.white, in: Capsule())
                                .overlay(Capsule().strokeBorder(Osa.bg, lineWidth: 2))
                                .offset(x: 16, y: -14)
                        }
                    }
            }
            .buttonStyle(.osaRound)
            .accessibilityLabel(store.pendingCount > 0 ? "Amis, \(store.pendingCount) demande\(store.pendingCount > 1 ? "s" : "")" : "Amis")
        }
    }

    private func shareTap() {
        if core.panel == "share" { core.openPanel(nil); return }
        if store.trip != nil { core.openPanel("share"); return }
        busy = true
        Task {
            let t = await store.startTrip()
            busy = false
            guard let t else { return }
            core.openPanel("share")
            FriendsUtil.presentShare([store.tripMessage, t.url])
        }
    }
}
