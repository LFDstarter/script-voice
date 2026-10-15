import Foundation

/// Une horloge régulière, pour tout ce qui doit avancer à l'écran : le chrono
/// d'enregistrement, la forme d'onde qui s'allonge, le prompteur, la tête de
/// lecture.
///
/// `Timer.scheduledTimer` ne convient pas ici. Il dépend de la boucle
/// d'événements, et macOS le regroupe avec d'autres pour économiser la
/// batterie : mesuré sur cette application, un battement réglé sur 50 ms
/// restait muet cinq secondes d'affilée, puis rattrapait d'un coup. Le chrono
/// sautait de 2,2 s à 7,4 s et le prompteur ne bougeait pas de la prise.
///
/// Une source dispatch marquée `.strict` refuse ce regroupement : elle tire à
/// l'heure, même quand la fenêtre passe au second plan.
@MainActor
final class Battement {
    private var source: DispatchSourceTimer?

    /// Démarre, ou redémarre, le battement.
    func lancer(toutes intervalle: Double, _ action: @escaping @MainActor () -> Void) {
        arreter()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now() + intervalle, repeating: intervalle, leeway: .milliseconds(4))
        t.setEventHandler { MainActor.assumeIsolated { action() } }
        t.resume()
        source = t
    }

    func arreter() {
        source?.cancel()
        source = nil
    }

    var actif: Bool { source != nil }

    deinit { source?.cancel() }
}

/// Tient le système éveillé le temps d'une prise.
///
/// Sans cela, macOS considère une application dont la fenêtre n'est pas au
/// premier plan comme inactive, et ralentit tout ce qu'elle fait — y compris
/// l'affichage de ce qu'elle est en train d'enregistrer.
@MainActor
final class Vigilance {
    private var jeton: NSObjectProtocol?

    func tenir(_ raison: String) {
        guard jeton == nil else { return }
        jeton = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: raison)
    }

    func relacher() {
        if let jeton { ProcessInfo.processInfo.endActivity(jeton) }
        jeton = nil
    }
}
