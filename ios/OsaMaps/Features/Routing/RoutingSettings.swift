import SwiftUI

/// Section « Itinéraires » de l'écran Réglages.
struct RoutingSettings: View {
    @Environment(Prefs.self) private var prefs
    @State private var model = RoutingModel.shared

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 0) {
            Text("Itinéraires")
                .font(.osa(13, .bold))
                .foregroundStyle(Osa.dim)
                .textCase(.uppercase)
                .padding(.top, 14).padding(.bottom, 4)
            Toggle("Éviter les péages", isOn: $prefs.avoidTolls).toggleStyle(RoutingSwitchStyle())
            divider
            Toggle("Éviter les autoroutes", isOn: $prefs.avoidHighways).toggleStyle(RoutingSwitchStyle())
            divider
            Toggle("Éviter les ferrys", isOn: $prefs.avoidFerries).toggleStyle(RoutingSwitchStyle())
            divider
            Toggle(isOn: $model.alternates) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Proposer d'autres itinéraires")
                    Text("Jusqu'à deux alternatives à comparer avant de partir.")
                        .font(.osa(13, .medium))
                        .foregroundStyle(Osa.faint)
                }
            }
            .toggleStyle(RoutingSwitchStyle())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .osaCard()
    }

    private var divider: some View { Rectangle().fill(Osa.line).frame(height: 1) }
}

/// Interrupteur sobre : blanc quand activé (pastille sombre), gris sinon.
struct RoutingSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
            Haptic.play("light")
        } label: {
            HStack(spacing: 12) {
                configuration.label
                    .font(.osa(16, .semibold))
                    .foregroundStyle(Osa.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color.white : Osa.surfaceHi)
                        .overlay(Capsule().strokeBorder(configuration.isOn ? Color.clear : Osa.lineHi))
                    Circle().fill(configuration.isOn ? Osa.bg : Osa.dim)
                        .frame(width: 22, height: 22)
                        .padding(3)
                }
                .frame(width: 50, height: 30)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: configuration.isOn)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}
