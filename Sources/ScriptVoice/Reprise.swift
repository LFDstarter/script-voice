import AppKit
import SwiftUI

/// Rouvrir le dernier projet. A la fermeture de l'application, le dossier du
/// projet ouvert est retenu ; au lancement suivant, une feuille propose de le
/// reprendre, ou de passer.
enum Reprise {
    private static let cleDossier = "dernierProjet"
    private static let cleDate = "dernierProjetFerme"

    /// Les modes d'essai (`--capture`, `--ouvrir`, `--autotest`…) ne retiennent
    /// rien et ne proposent rien : ils travaillent sur des copies jetables.
    static var actif: Bool { !CommandLine.arguments.contains { $0.hasPrefix("--") } }

    static func retenir(_ dossier: URL?) {
        let d = UserDefaults.standard
        if let dossier {
            d.set(dossier.path, forKey: cleDossier)
            d.set(Date(), forKey: cleDate)
        } else {
            d.removeObject(forKey: cleDossier)
        }
    }

    struct Offre: Identifiable {
        let dossier: URL
        let projet: Projet
        let ferme: Date?
        var id: String { dossier.path }
    }

    /// Le projet a proposer, s'il existe encore et se lit. `chemin` sert aux
    /// essais ; sinon, celui retenu a la derniere fermeture.
    static func offre(chemin: String? = nil) -> Offre? {
        let d = UserDefaults.standard
        guard let chemin = chemin ?? d.string(forKey: cleDossier) else { return nil }
        let url = URL(fileURLWithPath: chemin)
        guard let projet = try? Projet.ouvrir(url) else {
            // dossier deplace ou supprime : on n'en parle plus
            if chemin == d.string(forKey: cleDossier) { d.removeObject(forKey: cleDossier) }
            return nil
        }
        return Offre(dossier: url, projet: projet, ferme: d.object(forKey: cleDate) as? Date)
    }
}

/// Les projets ouverts recemment, du plus recent au plus ancien, comme le
/// menu « Open Recent » de VS Code.
enum Recents {
    private static let cle = "projetsRecents"
    static let maximum = 12
    /// le banc d'essai travaille sur ses propres reglages, pas sur la vraie liste
    nonisolated(unsafe) static var reglages = UserDefaults.standard

    static var liste: [URL] {
        (reglages.stringArray(forKey: cle) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func ajouter(_ url: URL) {
        var l = reglages.stringArray(forKey: cle) ?? []
        l.removeAll { $0 == url.path }
        l.insert(url.path, at: 0)
        reglages.set(Array(l.prefix(maximum)), forKey: cle)
    }

    static func retirer(_ url: URL) {
        let l = (reglages.stringArray(forKey: cle) ?? []).filter { $0 != url.path }
        reglages.set(l, forKey: cle)
    }

    static func effacer() { reglages.removeObject(forKey: cle) }

    /// « ~/Documents/scriptvoice/Projet.scriptvoice »
    static func chemin(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
}

/// Le sous-menu Fichier › Ouvert récemment, refait a chaque ouverture.
@MainActor
final class MenuRecents: NSObject, NSMenuDelegate {
    let projet: Projet
    init(projet: Projet) { self.projet = projet }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let liste = Recents.liste
        if liste.isEmpty {
            let vide = NSMenuItem(title: "Aucun projet récent", action: nil, keyEquivalent: "")
            vide.isEnabled = false
            menu.addItem(vide)
            return
        }
        for url in liste {
            let item = NSMenuItem(title: Recents.chemin(url), action: #selector(ouvrir(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            // le projet ouvert est coche, comme dans les menus du systeme
            item.state = url.standardizedFileURL == projet.dossier?.standardizedFileURL ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let effacer = NSMenuItem(title: "Effacer la liste", action: #selector(vider), keyEquivalent: "")
        effacer.target = self
        menu.addItem(effacer)
    }

    @objc private func ouvrir(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        guard let charge = try? Projet.ouvrir(url) else {
            Recents.retirer(url)
            Montage.prevenir("Le projet « \(Recents.chemin(url)) » est introuvable : il a été déplacé ou supprimé. "
                             + "Il est retiré de la liste.")
            return
        }
        projet.enregistrerSiPossible()
        projet.reprendre(charge)
        Projet.oublierHistorique()
        Journal.ecrire("projet recent ouvert : \(url.lastPathComponent)")
    }

    @objc private func vider() { Recents.effacer() }
}

/// La feuille de reprise. Le debut du script, derriere un liseré vert, dit
/// d'un coup d'oeil de quel projet il s'agit.
struct VueReprise: View {
    let offre: Reprise.Offre
    let rouvrir: () -> Void
    let passer: () -> Void

    private let vert = Color(red: 0.41, green: 0.81, blue: 0.59)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("REPRENDRE LE DERNIER PROJET")
                    .font(.system(size: 10, weight: .bold)).tracking(1.4)
                    .foregroundColor(vert)
                Text(offre.dossier.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 17, weight: .semibold))
                Text(details)
                    .font(.system(size: 11)).foregroundColor(Color(white: 0.55))
            }

            if !extrait.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Rectangle().fill(vert).frame(width: 2)
                    Text(extrait)
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.72))
                        .lineLimit(3)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(offre.dossier.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(white: 0.4))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Spacer()
                Button("Passer", action: passer).keyboardShortcut(.cancelAction)
                Button("Rouvrir", action: rouvrir).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
        // un fond plein, celui des barres de l'application : le fond translucide
        // par defaut d'une feuille ne se dessine pas partout
        .background(Color(white: 0.13))
        .preferredColorScheme(.dark)
    }

    /// « Fermé le 15 octobre à 02:31 · 3 pistes · 1 min 18 de montage »
    private var details: String {
        var morceaux: [String] = []
        if let f = offre.ferme {
            let jour = DateFormatter()
            jour.locale = Locale(identifier: "fr_FR")
            jour.dateFormat = "d MMMM 'à' HH:mm"
            morceaux.append("Fermé le \(jour.string(from: f))")
        }
        let n = offre.projet.pistes.count
        morceaux.append("\(n) piste\(n > 1 ? "s" : "")")
        let d = Int(offre.projet.duree.rounded())
        if d > 0 {
            morceaux.append(d >= 60 ? "\(d / 60) min \(String(format: "%02d", d % 60)) de montage"
                                    : "\(d) s de montage")
        } else {
            morceaux.append("aucune prise")
        }
        return morceaux.joined(separator: " · ")
    }

    private var extrait: String {
        offre.projet.script
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: "\n")
    }
}
