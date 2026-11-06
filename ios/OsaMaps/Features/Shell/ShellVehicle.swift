import SwiftUI
import Observation

/// Profil véhicule côté shell : la question « Tu conduis quoi ? » (accueil, ou une fois en feuille pour ceux
/// qui avaient déjà passé l'accueil), les dimensions des camions, la section « Véhicule » des réglages
/// et le petit badge du mode camion sur la carte. Tout est lu / écrit dans `Prefs.shared.vehicle`.
/// Tests : `-shellVehicleSheet YES` ouvre la feuille ; lien `osamaps://shell/vehicle` aussi.
@MainActor
@Observable
final class ShellVehicleState {
    static let shared = ShellVehicleState()
    /// Feuille d'édition ouverte (question unique, réglages, badge).
    var sheetOpen = UserDefaults.standard.bool(forKey: "shellVehicleSheet")
    private init() {}
}

// MARK: - Grille des quatre catégories

/// Les quatre grandes cartes : Voiture / Camion / Poids lourd / Super lourd.
struct ShellVehicleKindGrid: View {
    @Binding var vehicle: Vehicle
    var onPick: (Vehicle.Kind) -> Void = { _ in }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Vehicle.Kind.allCases, id: \.self) { kind in
                ShellVehicleKindCard(kind: kind, on: vehicle.kind == kind) {
                    if vehicle.kind != kind {
                        Haptic.play("light")
                        vehicle = .preset(kind)
                    }
                    onPick(kind)
                }
            }
        }
    }
}

private struct ShellVehicleKindCard: View {
    let kind: Vehicle.Kind
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(on ? Color.black : Osa.text)
                        .frame(height: 34)
                    Spacer(minLength: 0)
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(on ? Color.black : Osa.faint)
                }
                Spacer(minLength: 0)
                Text(kind.label)
                    .font(.osa(18, .bold))
                    .foregroundStyle(on ? Color.black : Osa.text)
                Text(ShellVehicleText.phrase(kind))
                    .font(.osa(13, .medium))
                    .foregroundStyle(on ? Color.black.opacity(0.6) : Osa.dim)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(Osa.surface),
                        in: RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous)
                .strokeBorder(on ? Color.clear : Osa.line))
            .contentShape(RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous))
        }
        .buttonStyle(ShellVehiclePress())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}

struct ShellVehiclePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

enum ShellVehicleText {
    /// La phrase sous chaque carte (plus parlante que `Vehicle.Kind.detail`).
    static func phrase(_ k: Vehicle.Kind) -> String {
        switch k {
        case .car: "Voiture, moto ou utilitaire jusqu'à 3,5\u{00a0}t."
        case .truck: "Porteur jusqu'à 19\u{00a0}t : livraisons, BTP, déménagement."
        case .heavy: "Semi-remorque jusqu'à 44\u{00a0}t, la route au long cours."
        case .superheavy: "Convoi exceptionnel, plus de 44\u{00a0}t ou hors gabarit."
        }
    }

    /// « Poids lourd · 4 m · 44\u{00a0}t ».
    static func summary(_ v: Vehicle) -> String {
        guard v.isTruck else { return "Voiture" }
        var s = "\(v.kind.label) · \(num(v.height)) m · \(num(v.weight)) t"
        if v.hazmat { s += " · ADR" }
        return s
    }

    static func num(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "fr_FR")))
    }
}

// MARK: - Dimensions (camions)

/// Hauteur, largeur, longueur, poids total, charge à l'essieu et matières dangereuses,
/// pré-remplis par le preset et modifiables (− / +, appui long pour défiler).
struct ShellVehicleDimensions: View {
    @Binding var vehicle: Vehicle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                row("Hauteur", "Ponts et tunnels bas évités.", \.height, step: 0.05, range: 2...6, unit: "m")
                ShellDivider()
                row("Largeur", nil, \.width, step: 0.05, range: 1.8...6, unit: "m")
                ShellDivider()
                row("Longueur", nil, \.length, step: 0.5, range: 4...50, unit: "m")
                ShellDivider()
                row("Poids total", "En charge (PTAC ou PTRA).", \.weight, step: 1, range: 3.5...250, unit: "t")
                ShellDivider()
                row("Charge à l'essieu", nil, \.axleLoad, step: 0.5, range: 1...20, unit: "t")
                ShellDivider()
                ShellRow(label: "Matières dangereuses (ADR)",
                         hint: "Évite les tunnels et les routes interdits au transport de matières dangereuses.") {
                    Toggle("Matières dangereuses", isOn: $vehicle.hazmat).labelsHidden().tint(Osa.ok)
                }
            }
            .osaCard()

            Button {
                Haptic.play("light")
                vehicle = .preset(vehicle.kind)
            } label: {
                Label("Valeurs habituelles d'un \(vehicle.kind.label.lowercased())", systemImage: "arrow.counterclockwise")
                    .font(.osa(14, .semibold))
                    .foregroundStyle(Osa.dim)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .opacity(vehicle == .preset(vehicle.kind) ? 0 : 1)
            .disabled(vehicle == .preset(vehicle.kind))
        }
    }

    private func row(_ label: String, _ hint: String?, _ key: WritableKeyPath<Vehicle, Double>,
                     step: Double, range: ClosedRange<Double>, unit: String) -> some View {
        let value = vehicle[keyPath: key]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.osa(16, .semibold)).foregroundStyle(Osa.text)
                if let hint { Text(hint).font(.osa(12, .regular)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stepButton("minus", "Diminuer \(label.lowercased())", disabled: value <= range.lowerBound + 1e-9) {
                set(key, value - step, range, step)
            }
            Text("\(ShellVehicleText.num(value)) \(unit)")
                .font(.osa(16, .bold))
                .monospacedDigit()
                .foregroundStyle(Osa.text)
                .frame(minWidth: 64)
                .contentTransition(.numericText())
            stepButton("plus", "Augmenter \(label.lowercased())", disabled: value >= range.upperBound - 1e-9) {
                set(key, value + step, range, step)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label) \(ShellVehicleText.num(value)) \(unit == "m" ? "mètres" : "tonnes")")
    }

    private func set(_ key: WritableKeyPath<Vehicle, Double>, _ v: Double, _ range: ClosedRange<Double>, _ step: Double) {
        // arrondi au pas (évite 3,9999…) puis borné
        let r = (v / step).rounded() * step
        vehicle[keyPath: key] = (min(range.upperBound, max(range.lowerBound, r)) * 100).rounded() / 100
    }

    private func stepButton(_ icon: String, _ label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptic.play("light")
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(disabled ? Osa.faint.opacity(0.5) : Osa.text)
                .frame(width: 44, height: 44)
                .background(Osa.surfaceHi, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(ShellVehiclePress())
        .buttonRepeatBehavior(.enabled)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

/// Avertissement du super lourd (convoi exceptionnel).
struct ShellVehicleConvoyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Osa.danger)
                .font(.system(size: 16, weight: .semibold))
            Text("Convoi exceptionnel : ton itinéraire réel est celui imposé par ton arrêté préfectoral de transport exceptionnel. OsaMaps n'est qu'une aide.")
                .font(.osa(13, .medium))
                .foregroundStyle(Osa.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Osa.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Osa.radiusM, style: .continuous).strokeBorder(Osa.danger.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Feuille (question unique + modification depuis les réglages ou le badge)

/// Deux temps : la catégorie, puis (camions) les dimensions. Fermer sans valider garde le véhicule actuel
/// et ne repose plus la question.
struct ShellVehicleSheet: View {
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = Prefs.shared.vehicle
    @State private var showDims = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if showDims {
                    Button {
                        withAnimation(anim) { showDims = false }
                    } label: {
                        HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Retour") }
                    }
                    .font(.osa(16, .semibold))
                    .foregroundStyle(Osa.dim)
                    .frame(minHeight: 44)
                }
                Spacer()
                Button {
                    close(save: false)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Osa.text)
                        .frame(width: 36, height: 36)
                        .background(Osa.surfaceHi, in: Circle())
                        .contentShape(Circle().inset(by: -6))
                }
                .accessibilityLabel("Fermer")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if showDims {
                        title("Ton \(draft.kind.label.lowercased()), en chiffres", "Pré-rempli avec les valeurs habituelles : ajuste-les pour des itinéraires sûrs (ponts bas, routes limitées en tonnage).")
                        ShellVehicleDimensions(vehicle: $draft)
                        if draft.kind == .superheavy { ShellVehicleConvoyNote() }
                    } else {
                        title("Tu conduis quoi\u{00a0}?", "OsaMaps adapte les itinéraires, les limitations de vitesse et les alertes à ton véhicule.")
                        ShellVehicleKindGrid(vehicle: $draft)
                    }
                }
                .padding(20)
                .id(showDims)
                .transition(.opacity)
            }

            Button {
                if !showDims && draft.isTruck {
                    withAnimation(anim) { showDims = true }
                } else {
                    close(save: true)
                }
            } label: {
                Text(!showDims && draft.isTruck ? "Continuer" : "Valider")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.osaPill)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(Osa.bg.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .presentationBackground(Osa.bg)
        .preferredColorScheme(.dark)
    }

    private var anim: Animation { reduceMotion ? .easeOut(duration: 0.15) : Osa.anim }

    private func title(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t).font(.osa(28, .bold)).foregroundStyle(Osa.text).accessibilityAddTraits(.isHeader)
            Text(sub).font(.osa(15, .medium)).foregroundStyle(Osa.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func close(save: Bool) {
        if save {
            if prefs.vehicle != draft { prefs.vehicle = draft }
            Haptic.play("success")
            Bus.shared.emit(.toast(Toast(id: "shell-vehicle", text: draft.isTruck ? "Mode \(draft.kind.label.lowercased()) activé : \(ShellVehicleText.summary(draft))." : "Mode voiture.",
                                         icon: draft.isTruck ? draft.kind.symbol : "car.fill", tone: .good)))
        }
        if !prefs.vehicleChosen { prefs.vehicleChosen = true }
        ShellVehicleState.shared.sheetOpen = false
        dismiss()
    }
}

// MARK: - Réglages

/// Section « Véhicule » des réglages.
struct ShellVehicleSettings: View {
    @Environment(Prefs.self) private var prefs
    @Environment(Core.self) private var core

    var body: some View {
        let v = prefs.vehicle
        ShellSection(title: "Véhicule") {
            ShellRow(label: v.kind.label,
                     hint: v.isTruck ? "\(ShellVehicleText.num(v.height)) m de haut · \(ShellVehicleText.num(v.width)) m de large · \(ShellVehicleText.num(v.length)) m de long · \(ShellVehicleText.num(v.weight)) t\(v.hazmat ? " · matières dangereuses" : "")"
                                     : "Itinéraires et limitations pour les voitures.",
                     action: open) {
                HStack(spacing: 8) {
                    Image(systemName: v.kind.symbol).font(.system(size: 17, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                }
            }
        }
    }

    private func open() {
        Haptic.play("light")
        core.settingsOpen = false
        // la feuille des réglages se ferme avant d'ouvrir celle du véhicule
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            ShellVehicleState.shared.sheetOpen = true
        }
    }
}

// MARK: - Badge sur la carte

/// Petit badge discret du mode camion (rail) : pictogramme + poids. Touché hors conduite : modifier.
struct ShellVehicleBadge: View {
    @Environment(Prefs.self) private var prefs
    @Environment(Core.self) private var core

    var body: some View {
        let v = prefs.vehicle
        // masqué quand un panneau est ouvert : le rail reste court (il ne doit pas monter sur la recherche)
        if v.isTruck && prefs.onboarded && core.panel == nil {
            Button {
                Haptic.play("light")
                ShellVehicleState.shared.sheetOpen = true
            } label: {
                VStack(spacing: 0) {
                    Image(systemName: v.kind.symbol).font(.system(size: 15, weight: .semibold))
                    Text("\(ShellVehicleText.num(v.weight.rounded())) t")
                        .font(.system(size: 10, weight: .heavy))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .buttonStyle(.osaRound)
            .disabled(core.mode == .drive)
            .accessibilityLabel("Mode \(v.kind.label.lowercased()), \(ShellVehicleText.num(v.weight)) tonnes")
            .accessibilityHint(core.mode == .drive ? "" : "Modifier le véhicule")
            .transition(.opacity)
        }
    }
}
