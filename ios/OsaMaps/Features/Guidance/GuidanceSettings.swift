import SwiftUI

/// Section « Guidage » de l'écran Réglages : voix, bip, annonce des limitations, tolérance.
struct GuidanceSettingsSection: View {
    @Environment(Prefs.self) private var prefs
    @Bindable private var gp = GuidancePrefs.shared

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 0) {
            Text("Guidage")
                .font(.osa(17, .bold))
                .padding(.top, 14).padding(.bottom, 4)
            GuidanceSettingRow(title: "Guidage vocal", hint: "Les annonces de virages, d'alertes et de recalcul", isOn: $prefs.voice, first: true)
            GuidanceSettingRow(title: "Bip de dépassement", hint: "Un petit bip quand vous dépassez la limitation", isOn: $gp.speedBeep)
            GuidanceSettingRow(title: "Annoncer les limitations", hint: "Dire la nouvelle limitation quand elle change", isOn: $gp.speedVoice)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tolérance de vitesse").font(.osa(16, .semibold))
                        Text("Au-delà de la limitation + \(prefs.speedTolerance) km/h, le compteur passe au rouge")
                            .font(.osa(13, .regular)).foregroundStyle(Osa.dim)
                    }
                    Spacer()
                    Text("+\(prefs.speedTolerance) km/h").font(.osa(16, .heavy)).monospacedDigit()
                }
                Slider(value: Binding(get: { Double(prefs.speedTolerance) }, set: { prefs.speedTolerance = Int($0.rounded()) }), in: 0...20, step: 1)
                    .tint(.white)
                    .accessibilityLabel("Tolérance de vitesse")
                    .accessibilityValue("\(prefs.speedTolerance) km/h")
            }
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Osa.line).frame(height: 1) }
        }
        .foregroundStyle(Osa.text)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .osaCard()
    }
}

struct GuidanceSettingRow: View {
    var title: String
    var hint: String
    @Binding var isOn: Bool
    var first = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.osa(16, .semibold))
                Text(hint).font(.osa(13, .regular)).foregroundStyle(Osa.dim)
            }
        }
        .toggleStyle(GuidanceSwitch())
        .padding(.vertical, 14)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Osa.line).frame(height: 1) } }
    }
}

/// Interrupteur sobre : piste blanche + pastille noire quand activé.
struct GuidanceSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 14) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color.white.opacity(0.95) : Osa.surfaceHi)
                        .overlay(Capsule().strokeBorder(configuration.isOn ? .clear : Osa.lineHi))
                    Circle().fill(configuration.isOn ? Color.black : Osa.dim).frame(width: 24, height: 24).padding(4)
                }
                .frame(width: 52, height: 32)
                .animation(.easeOut(duration: 0.18), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "activé" : "désactivé")
    }
}
