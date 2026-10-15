import AppKit
import Combine
import SwiftUI

/// Point d'entree en AppKit.
///
/// Une scene SwiftUI (`WindowGroup`) ne produit aucune fenetre quand l'application
/// est construite hors de Xcode : rien ne plante, la boucle tourne, et l'ecran
/// reste vide. On monte donc la fenetre a la main et on y pose la vue SwiftUI.
/// C'est aussi ce qui permet de maitriser la taille, le titre et le menu.

@MainActor
final class Delegue: NSObject, NSApplicationDelegate {
    let projet = Projet()
    var fenetre: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Journal.demarrer()
        // Verification du rattrapage de plantage : `--essai-plantage` provoque
        // volontairement une erreur fatale pour s'assurer qu'elle laisse une trace.
        if CommandLine.arguments.contains("--essai-plantage") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Journal.ecrire("plantage volontaire dans un instant")
                let vide: [Int] = []
                _ = vide[3]
            }
            return
        }
        if CommandLine.arguments.contains("--autotest") {
            // L'application doit avoir fini de se lancer et etre active : une
            // session de capture demarree avant que macOS ne considere le
            // processus comme une application a part entiere reste suspendue.
            construireMenu()
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Task { await Autotest.lancer() }
            }
            return
        }
        if let c = Capture.demandee { Capture.programmer(c) }
        if let i = CommandLine.arguments.firstIndex(of: "--exporter"),
           i + 1 < CommandLine.arguments.count {
            let cible = CommandLine.arguments[i + 1]
            ouvrirDepuisLigneDeCommande()
            let format = (cible as NSString).pathExtension
            do {
                try Export.rendre(projet, vers: URL(fileURLWithPath: cible), format: format)
                print("export ok : \(cible)")
            } catch { print("export impossible : \(error.localizedDescription)") }
            NSApp.terminate(nil)
            return
        }
        construireMenu()
        // L'application est sombre de bout en bout. Sans cela, ses feuilles,
        // alertes et panneaux suivaient le systeme et s'ouvraient en clair.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Tout projet ouvert ou enregistre rejoint la liste des recents. Les
        // modes d'essai, qui travaillent sur des copies, n'y touchent pas.
        if Reprise.actif {
            suiviDossier = projet.$dossier.compactMap { $0 }.removeDuplicates()
                .sink { Recents.ajouter($0) }
        }
        // Enregistrement automatique : un instant apres la derniere modification,
        // quelle qu'elle soit. Le projet n'est ecrit que s'il a change.
        enregistrementAuto = projet.objectWillChange
            .debounce(for: .milliseconds(700), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.projet.enregistrerSiChange() }

        let vue = Fenetre(projet: projet)
            .preferredColorScheme(.dark)
            .tint(Color(red: 0.41, green: 0.81, blue: 0.59))

        fenetre = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1460, height: 900),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        fenetre.title = "Script Voice"
        fenetre.backgroundColor = NSColor(white: 0.09, alpha: 1)
        fenetre.minSize = NSSize(width: 1040, height: 620)
        fenetre.contentView = NSHostingView(rootView: vue)
        fenetre.center()
        fenetre.setFrameAutosaveName("fenetre-principale")
        // En mode capture, la fenetre se montre sans prendre le clavier : voler
        // le focus pendant qu'on travaille ailleurs envoie les frappes au
        // prompteur, qui se met en pause ou saute des mots.
        if Capture.demandee == nil {
            fenetre.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            fenetre.orderFrontRegardless()
        }
    }

    /// Partage avec la fenetre la lecture du projet passe en ligne de commande.
    private func ouvrirDepuisLigneDeCommande() {
        guard let i = CommandLine.arguments.firstIndex(of: "--ouvrir"),
              i + 1 < CommandLine.arguments.count,
              let charge = try? Projet.ouvrir(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        else { return }
        projet.reprendre(charge)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Journal.ecrire("fermeture de l'application")
        projet.enregistrerSiPossible()
        // le projet ouvert sera propose au prochain lancement
        if Reprise.actif { Reprise.retenir(projet.dossier) }
    }

    /// Le menu minimal mais complet : sans lui, pas meme Commande-Q.
    private func construireMenu() {
        let barre = NSMenu()

        let app = NSMenuItem()
        barre.addItem(app)
        let menuApp = NSMenu()
        menuApp.addItem(withTitle: "À propos de Script Voice",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menuApp.addItem(.separator())
        menuApp.addItem(withTitle: "Masquer Script Voice",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menuApp.addItem(withTitle: "Quitter Script Voice",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = menuApp

        let fichier = NSMenuItem()
        barre.addItem(fichier)
        let menuFichier = NSMenu(title: "Fichier")
        ajouter(menuFichier, "Nouveau projet", "n") { Fichier.nouveau(self.projet) }
        ajouter(menuFichier, "Ouvrir un projet...", "o") { Fichier.ouvrir(self.projet) }
        let recents = NSMenuItem(title: "Ouvert récemment", action: nil, keyEquivalent: "")
        let sousMenu = NSMenu(title: "Ouvert récemment")
        sousMenu.delegate = menuRecents
        recents.submenu = sousMenu
        menuFichier.addItem(recents)
        menuFichier.addItem(.separator())
        ajouter(menuFichier, "Importer un PDF…", "") { Fichier.importerPDF(self.projet) }
        ajouter(menuFichier, "Fermer le PDF", "") { Fichier.fermerPDF(self.projet) }
        // Majuscule Commande I : Commande I est deja l'italique du script
        ajouter(menuFichier, "Importer un son…", "I") { Montage.courant?.importerSon() }
        menuFichier.addItem(.separator())
        ajouter(menuFichier, "Enregistrer", "s") { Fichier.enregistrer(self.projet) }
        ajouter(menuFichier, "Enregistrer sous...", "S") { Fichier.enregistrerSous(self.projet) }
        fichier.submenu = menuFichier

        // Mise en forme : les memes commandes que la palette flottante, pour
        // ceux qui tiennent au clavier.
        let format = NSMenuItem()
        barre.addItem(format)
        let menuFormat = NSMenu(title: "Format")
        ajouter(menuFormat, "Gras", "b") { PaletteTexte.demander("gras") }
        ajouter(menuFormat, "Italique", "i") { PaletteTexte.demander("italique") }
        ajouter(menuFormat, "Souligné", "u") { PaletteTexte.demander("souligne") }
        menuFormat.addItem(.separator())
        for (i, t) in PaletteTexte.tailles.enumerated() {
            let item = NSMenuItem(title: t.nom, action: #selector(Action.lancer),
                                  keyEquivalent: "\(i + 1)")
            item.keyEquivalentModifierMask = [.command, .option]
            let cible = Action { PaletteTexte.demander("taille\(i)") }
            item.target = cible
            item.representedObject = cible
            menuFormat.addItem(item)
        }
        format.submenu = menuFormat

        let aide = NSMenuItem()
        barre.addItem(aide)
        let menuAide = NSMenu(title: "Aide")
        ajouter(menuAide, "Envoyer le journal…", "") { Journal.envoyer() }
        ajouter(menuAide, "Ouvrir le journal", "l") { Journal.ouvrirDansLeFinder() }
        ajouter(menuAide, "Copier le diagnostic", "d") {
            let p = NSPasteboard.general
            p.clearContents()
            p.setString(Journal.diagnostic(), forType: .string)
            Journal.ecrire("diagnostic copie dans le presse-papier")
        }
        ajouter(menuAide, "Vider le journal", "") { Journal.vider() }
        aide.submenu = menuAide

        let edition = NSMenuItem()
        barre.addItem(edition)
        let menuEdition = NSMenu(title: "Édition")
        // Annuler et Retablir visent la pile de la fenetre, ou que soit le
        // clavier : apres un clic dans la timeline, aucun champ ne l'a, et une
        // commande envoyee « au premier repondeur » ne trouvait personne.
        for (titre, touche, sens) in [("Annuler", "z", false), ("Rétablir", "Z", true)] {
            let item = NSMenuItem(title: titre, action: #selector(Historique.agir(_:)), keyEquivalent: touche)
            item.target = historique
            item.tag = sens ? 1 : 0
            menuEdition.addItem(item)
        }
        menuEdition.addItem(.separator())
        // Couper, Copier, Coller et Tout selectionner servent le script quand
        // il a le clavier, la timeline sinon.
        for (titre, touche, tag) in [("Couper", "x", 0), ("Copier", "c", 1), ("Coller", "v", 2),
                                     ("Tout sélectionner", "a", 3)] {
            let item = NSMenuItem(title: titre, action: #selector(Aiguillage.agir(_:)), keyEquivalent: touche)
            item.target = aiguillage
            item.tag = tag
            menuEdition.addItem(item)
        }
        edition.submenu = menuEdition

        NSApp.mainMenu = barre
    }

    private func ajouter(_ menu: NSMenu, _ titre: String, _ touche: String,
                         _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: titre, action: #selector(Action.lancer), keyEquivalent: touche)
        let cible = Action(action)
        item.target = cible
        item.representedObject = cible          // garde la cible en vie
        menu.addItem(item)
    }

    private let historique = Historique()
    private lazy var menuRecents = MenuRecents(projet: projet)
    private var suiviDossier: AnyCancellable?
    private var enregistrementAuto: AnyCancellable?
    private let aiguillage = Aiguillage()

    /// Le menu Edition sert le script ou la timeline, selon qui a le clavier.
    @MainActor final class Aiguillage: NSObject, NSMenuItemValidation {
        private static let actions = [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
                                      #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:))]

        private var texte: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }

        @objc func agir(_ item: NSMenuItem) {
            if let texte {
                NSApp.sendAction(Self.actions[item.tag], to: texte, from: item)
                return
            }
            guard let m = Montage.courant else { return }
            switch item.tag {
            case 0: m.couper()
            case 1: m.copier()
            case 2: m.coller()
            default: m.toutSelectionner()
            }
        }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            if texte != nil { return true }
            guard let m = Montage.courant else { return false }
            switch item.tag {
            case 0, 1: return m.peutCopier
            case 2: return m.peutColler
            default: return true
            }
        }
    }

    /// La cible des commandes Annuler et Retablir. Le titre du menu dit ce qui
    /// sera defait : « Annuler Couper », « Rétablir Déplacer le clip ».
    @MainActor final class Historique: NSObject, NSMenuItemValidation {
        @objc func agir(_ item: NSMenuItem) {
            guard let pile = Projet.annulation else { return }
            NSApp.windows.lazy.compactMap { $0.contentView?.premierTexte() }.first?.breakUndoCoalescing()
            if item.tag == 1 { if pile.canRedo { pile.redo() } } else { if pile.canUndo { pile.undo() } }
        }

        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            guard let pile = Projet.annulation else { return false }
            if item.tag == 1 {
                item.title = pile.canRedo ? pile.redoMenuItemTitle : "Rétablir"
                return pile.canRedo
            }
            item.title = pile.canUndo ? pile.undoMenuItemTitle : "Annuler"
            return pile.canUndo
        }
    }

    private final class Action: NSObject {
        let bloc: () -> Void
        init(_ bloc: @escaping () -> Void) { self.bloc = bloc }
        @objc func lancer() { bloc() }
    }
}

// Le code de haut niveau d'un main.swift n'est pas isole sur l'acteur principal :
// on l'y ramene explicitement avant de toucher a AppKit.
MainActor.assumeIsolated {
    let delegue = Delegue()
    let app = NSApplication.shared
    app.delegate = delegue
    app.setActivationPolicy(.regular)
    objc_setAssociatedObject(app, "delegue", delegue, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
