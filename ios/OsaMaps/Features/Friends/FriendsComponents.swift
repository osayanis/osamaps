import SwiftUI

/// Petites briques d'interface du module Amis (sobriété Osa).

struct FriendsAvatar: View {
    var name: String
    var live = false
    var size: CGFloat = 42
    /// Avec le pid : la mascotte personnalisée de l'ami (module mascot), ses initiales sinon.
    var pid: String?
    var body: some View {
        if let pid {
            MascotFriendFace(pid: pid, size: size) { initials }
                .background(Osa.surfaceHi, in: Circle())
                .overlay(Circle().strokeBorder(live ? Color.white : .clear, lineWidth: 2))
                .accessibilityHidden(true)
        } else {
            initials
        }
    }

    private var initials: some View {
        Text(FriendsUtil.initials(name))
            .font(.osa(size * 0.36, .heavy))
            .foregroundStyle(live ? .black : Osa.text)
            .frame(width: size, height: size)
            .background(live ? AnyShapeStyle(Color.white) : AnyShapeStyle(Osa.surfaceHi), in: Circle())
            .accessibilityHidden(true)
    }
}

struct FriendsLiveDot: View {
    var on = true
    var body: some View {
        Circle().fill(on ? Osa.ok : Osa.faint)
            .frame(width: 10, height: 10)
            .background(Circle().fill(on ? Osa.ok.opacity(0.18) : .clear).frame(width: 18, height: 18))
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

struct FriendsCloseButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Osa.dim)
                .frame(width: 36, height: 36).background(Osa.surfaceHi, in: Circle())
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fermer")
    }
}

struct FriendsBackButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold)).foregroundStyle(Osa.dim)
                .frame(width: 36, height: 36).background(Osa.surfaceHi, in: Circle())
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Retour")
    }
}

/// En-tête de panneau : (retour) titre (fermer).
struct FriendsHead: View {
    var title: String
    var back: (() -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            if let back { FriendsBackButton(action: back) }
            Text(title).font(.osa(20, .bold)).foregroundStyle(Osa.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            FriendsCloseButton { Core.shared.openPanel(nil) }
        }
    }
}

struct FriendsLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.osa(13, .semibold)).foregroundStyle(Osa.faint)
    }
}

/// Bouton discret (texte seul) ; `danger` = rouge pour une action destructive.
struct FriendsGhostButton: View {
    var title: String
    var danger = false
    var action: () -> Void
    init(_ title: String, danger: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.danger = danger; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(.osa(15, .semibold))
                .foregroundStyle(danger ? Osa.jam : Osa.dim)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12).frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Champ texte sobre (blanc 5 % + trait 8 %).
struct FriendsField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.osa(16, .semibold))
            .foregroundStyle(Osa.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .osaCard(Osa.radiusM - 2)
    }
}

/// Saisie du pseudo (dans le panneau tant qu'il est vide, et dans les réglages).
struct FriendsNicknameField: View {
    var placeholder = "Ton pseudo (visible par tes amis)"
    @State private var store = FriendsStore.shared
    @State private var value = Identity.nickname
    @State private var saved = false
    @FocusState private var focused: Bool

    var body: some View {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 8) {
            TextField("", text: $value, prompt: Text(placeholder).foregroundStyle(Osa.faint))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: value) { _, v in if v.count > 24 { value = String(v.prefix(24)) } }
                .modifier(FriendsField())
                .accessibilityLabel("Pseudo")
            Button(action: save) {
                if saved { Image(systemName: "checkmark") } else { Text("OK") }
            }
            .buttonStyle(.osaPill)
            .disabled(clean.isEmpty || clean == store.nickname)
            .opacity(clean.isEmpty || clean == store.nickname ? 0.4 : 1)
        }
    }

    private func save() {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != store.nickname else { return }
        focused = false
        Task {
            await store.rename(clean)
            saved = true
            Haptic.play("success")
            try? await Task.sleep(for: .seconds(1.5))
            saved = false
        }
    }
}
