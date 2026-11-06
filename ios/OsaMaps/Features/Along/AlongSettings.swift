import SwiftUI

/// Section « Sur le trajet » de l'écran Réglages.
struct AlongSettings: View {
    @Environment(Core.self) private var core
    private var p: AlongPrefs { .shared }

    var body: some View {
        @Bindable var p = p
        let ev = p.energy.isEV
        VStack(alignment: .leading, spacing: 16) {
            Text("Sur le trajet").font(.osa(17, .bold)).foregroundStyle(Osa.text)

            VStack(alignment: .leading, spacing: 8) {
                Text("Mon carburant").font(.osa(14, .semibold)).foregroundStyle(Osa.dim)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(AlongEnergy.allCases, id: \.self) { e in
                        let on = p.energy == e
                        Button { p.energy = e; Haptic.play("light") } label: {
                            Text(e.label).font(.osa(14, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .foregroundStyle(on ? .black : Osa.text)
                                .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Osa.surfaceHi), in: Capsule())
                                .overlay(Capsule().strokeBorder(on ? .clear : Osa.line))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Consommation").font(.osa(15, .semibold)).foregroundStyle(Osa.text)
                    Text(Prefs.shared.vehicle.isTruck ? "\(Prefs.shared.vehicle.kind.label) : pour estimer le coût du trajet." : "Pour estimer le coût du trajet.")
                        .font(.osa(12.5, .medium)).foregroundStyle(Osa.faint)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    stepButton("minus") { step(-1) }
                    Text("\(AlongFormat.decimal(ev ? p.evConsumption : p.consumption)) ")
                        .font(.osa(15, .bold).monospacedDigit()).foregroundStyle(Osa.text)
                    + Text(ev ? "kWh/100" : "L/100").font(.osa(11, .semibold)).foregroundStyle(Osa.faint)
                    stepButton("plus") { step(1) }
                }
                .background(Osa.surfaceHi, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Consommation")
                .accessibilityValue("\(AlongFormat.decimal(ev ? p.evConsumption : p.consumption)) \(ev ? "kilowattheures" : "litres") aux 100 km")
                .accessibilityAdjustableAction { $0 == .increment ? step(1) : step(-1) }
            }

            toggle("Afficher les stations", ev ? "Bornes de recharge sur la carte." : "Prix de mon carburant sur la carte, la moins chère en vert.", $p.showStations)
            toggle("Rappel de pause", "Après environ 2 h de conduite, avec l'aire la plus proche.", $p.pauseReminder)
            toggle("Alertes météo", "Neige, verglas, orages ou forte pluie prévus sur le trajet.", $p.weatherAlerts)
        }
        .padding(18)
        .osaCard()
    }

    private func step(_ dir: Double) {
        if p.energy.isEV { p.evConsumption = min(40, max(8, (p.evConsumption + dir).rounded())) }
        else {
            // camion : pas de 1 L, voiture : 0,5 L
            let stepL = Prefs.shared.vehicle.isTruck ? 1.0 : 0.5
            let r = p.consumptionRange
            p.consumption = min(r.upperBound, max(r.lowerBound, ((p.consumption + dir * stepL) / stepL).rounded() * stepL))
        }
        Haptic.play("light")
    }

    private func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).frame(width: 40, height: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Osa.text)
    }

    private func toggle(_ title: String, _ hint: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.osa(15, .semibold)).foregroundStyle(Osa.text)
                Text(hint).font(.osa(12.5, .medium)).foregroundStyle(Osa.faint)
            }
        }
        .tint(Osa.ok)
    }
}
