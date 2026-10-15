import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - La fenetre

struct Fenetre: View {
    @ObservedObject var projet: Projet
    @StateObject private var enregistreur = Enregistreur()
    @StateObject private var lecteur = Lecteur()
    @StateObject private var prompteur = Prompteur()
    @StateObject private var ondes = Ondes()

    @State private var outil: Outil = .selection
    @StateObject private var montage = Montage()
    @State private var pisteActive = 0
    @State private var micros: [Peripherique] = []
    @State private var zoomPDF: Double = 0
    @State private var reglagesOuverts = false
    @State private var erreur: String?
    @State private var demarre = false
    /// le dernier projet, propose au lancement
    @State private var reprise: Reprise.Offre?
    /// la piste de la prise a deja ete creee, et retenue pour Commande Z
    @State private var priseRetenue = false

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                HSplitView {
                    // La barre de commande vit sous le script, juste au-dessus des
                    // pistes : le support garde toute la hauteur pour lui.
                    VStack(spacing: 0) {
                        Editeur(texte: Binding(get: { projet.script },
                                               set: { projet.script = $0; projet.modifie = true }),
                                format: Binding(get: { projet.scriptFormat },
                                                set: { projet.scriptFormat = $0; projet.modifie = true }),
                                prompteur: prompteur,
                                police: projet.reglages.policeEditeur,
                                interligne: projet.reglages.interligneEditeur)
                            .overlay(alignment: .topLeading) {
                                if projet.script.isEmpty {
                                    Text("Écrivez votre script ici.\n\nPlacez ensuite le curseur sur le mot "
                                       + "où commencer,\npuis appuyez sur le bouton rouge : le prompteur part de là.")
                                        .font(.system(size: 15))
                                        .foregroundColor(Color(white: 0.33))
                                        .padding(.leading, 31).padding(.top, 26)
                                        .allowsHitTesting(false)
                                }
                            }
                        Divider().overlay(Color(white: 0.22))
                        BarreHaut(projet: projet, enregistreur: enregistreur, lecteur: lecteur,
                                  prompteur: prompteur, micros: $micros, outil: $outil,
                                  reglagesOuverts: $reglagesOuverts,
                                  basculerEnregistrement: basculerEnregistrement,
                                  basculerLecture: basculerLecture,
                                  exporter: exporter)
                    }
                    // la barre se resserre : le PDF peut prendre presque toute la place
                    .frame(minWidth: 560, idealWidth: 940)

                    Group {
                        if projet.pdf.isEmpty {
                            PDFAbsent(ouvrir: { Fichier.importerPDF(projet) })
                        } else {
                            VisionneusePDF(chemin: projet.pdf, zoom: $zoomPDF)
                                .overlay(alignment: .topTrailing) {
                                    BoutonFermerPDF { Fichier.fermerPDF(projet) }
                                        .padding(.top, 8).padding(.trailing, 8)
                                }
                        }
                    }
                    .frame(minWidth: 240, idealWidth: 520)
                }
                .frame(minHeight: 240)

                VStack(spacing: 0) {
                    BarrePistes(projet: projet, pisteActive: $pisteActive, montage: montage)
                    VueTimeline(projet: projet, lecteur: lecteur, ondes: ondes,
                                enregistreur: enregistreur, montage: montage, outil: $outil)
                }
                .frame(minHeight: 170, idealHeight: 260)
            }
        }
        .background(Color(white: 0.09))
        .sheet(isPresented: $reglagesOuverts) { VueReglages(projet: projet) }
        .background(Color.clear.sheet(item: $reprise) { offre in
            VueReprise(offre: offre,
                       rouvrir: { reprendre(offre); reprise = nil },
                       passer: { reprise = nil })
        })
        .alert("Script Voice", isPresented: .constant(erreur != nil)) {
            Button("Fermer") { erreur = nil }
        } message: { Text(erreur ?? "") }
        .onAppear { demarrer() }
        .onDisappear { projet.enregistrerSiPossible() }
        .background(Raccourcis(action: toucheAppuyee))
        .background(Disposition(projet: projet))
    }

    // MARK: Mise en route

    private func demarrer() {
        // SwiftUI peut rappeler onAppear quand la fenetre se reorganise. Sans ce
        // garde-fou, le projet se rechargeait et le prompteur repartait du debut
        // en pleine lecture.
        guard !demarre else { return }
        demarre = true
        montage.projet = projet
        montage.lecteur = lecteur
        montage.pisteActive = { pisteActive }
        Montage.courant = montage
        if let i = CommandLine.arguments.firstIndex(of: "--ouvrir"),
           i + 1 < CommandLine.arguments.count,
           let charge = try? Projet.ouvrir(URL(fileURLWithPath: CommandLine.arguments[i + 1])) {
            projet.reprendre(charge)
            Projet.oublierHistorique()
            Journal.ecrire("projet ouvert en ligne de commande : \(charge.dossier?.lastPathComponent ?? "?")")
        }
        micros = Micros.entrees()
        Journal.ecrire("entrees detectees : \(micros.map(\.nom).joined(separator: ", "))")
        prompteur.vitesse = projet.reglages.vitessePrompteur
        if let p = Micros.parUID(projet.reglages.peripheriqueID) ?? micros.first {
            projet.reglages.peripheriqueID = p.uid
            enregistreur.choisir(p)
        }
        // L'autorisation se demande tout de suite, mais sans bloquer l'affichage.
        Task { _ = await Enregistreur.demanderAcces() }
        // Mode de controle visuel : le prompteur sans le micro.
        if CommandLine.arguments.contains("--prompteur") {
            prompteur.vitesse = projet.reglages.vitessePrompteur
            prompteur.demarrer(texte: projet.script, depuis: 0)
        }
        // Controle visuel de la palette de mise en forme : on selectionne un
        // morceau de texte pour la faire apparaitre.
        if CommandLine.arguments.contains("--essai-palette") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard let vue = NSApp.windows.first?.contentView?.premierTexte() else { return }
                vue.window?.makeFirstResponder(vue)
                let ns = vue.string as NSString
                let fin = ns.range(of: "\n").location
                vue.setSelectedRange(NSRange(location: 0, length: fin == NSNotFound ? min(28, ns.length) : fin))
                vue.delegate?.textViewDidChangeSelection?(
                    Notification(name: NSTextView.didChangeSelectionNotification, object: vue))
                // --essai-format gras,taille3 applique les commandes demandees
                if let i = CommandLine.arguments.firstIndex(of: "--essai-format"),
                   i + 1 < CommandLine.arguments.count {
                    for cle in CommandLine.arguments[i + 1].split(separator: ",") {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        PaletteTexte.demander(String(cle))
                    }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    projet.enregistrerSiPossible()
                }
            }
        }
        // Essai de prise par l'application complete, interface comprise : c'est le
        // seul moyen de reproduire ce que vit l'utilisateur sans cliquer soi-meme.
        if let i = CommandLine.arguments.firstIndex(of: "--essai-prise"),
           i + 1 < CommandLine.arguments.count {
            let secondes = Double(CommandLine.arguments[i + 1]) ?? 3
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                basculerEnregistrement()
                // Mesure de la reactivite du fil principal : si l'interface se
                // fige pendant la prise, le retard se voit ici.
                let depart = Date()
                var prochain = 1.0
                while prochain <= secondes {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let reel = Date().timeIntervalSince(depart)
                    Journal.ecrire(String(format: "interface : %.2f s ecoulees, chrono %.2f s, "
                                        + "onde %d tranches, mot %d",
                                          reel, enregistreur.duree, enregistreur.onde.count,
                                          prompteur.index))
                    prochain += 1
                }
                basculerEnregistrement()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                Journal.ecrire("essai de prise termine")
                if !CommandLine.arguments.contains("--essai-lecture") { NSApp.terminate(nil) }
            }
        }
        // Controle visuel de la ligne de volume : --essai-volume -4 regle le
        // premier clip et laisse son etiquette affichee pour la capture.
        if let i = CommandLine.arguments.firstIndex(of: "--essai-volume"),
           i + 1 < CommandLine.arguments.count, let v = Double(CommandLine.arguments[i + 1]),
           !projet.pistes.isEmpty, !projet.pistes[0].clips.isEmpty {
            projet.pistes[0].clips[0].volume = v
            montage.selection = [projet.pistes[0].clips[0].id]
        }
        if CommandLine.arguments.contains("--essai-reglages") { reglagesOuverts = true }
        // Controle visuel de la timeline : deux clips selectionnes, des fondus
        // sur le premier, le troisieme desactive.
        if CommandLine.arguments.contains("--essai-timeline"), let p = projet.pistes.first, p.clips.count >= 3 {
            Edition.fondus([p.clips[0].id], duree: 1.2, dans: &projet.pistes)
            projet.pistes[0].clips[2].actif = false
            montage.selection = [p.clips[0].id, p.clips[1].id]
            lecteur.tete = p.clips[1].debut + 0.4
        }
        // Essai de la lame : --essai-lame 4,9 coupe le premier clip a 4 s puis a
        // 9 s, par de vrais clics poses dans la timeline.
        if let i = CommandLine.arguments.firstIndex(of: "--essai-lame"),
           i + 1 < CommandLine.arguments.count {
            let temps = CommandLine.arguments[i + 1].split(separator: ",").compactMap { Double($0) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let f = NSApp.windows.first(where: { $0.contentView?.premierTexte() != nil }),
                      let defil = f.contentView?.defilementTimeline(),
                      let doc = defil.documentView else { return }
                outil = .lame
                // une fenetre inactive avale le premier clic : l'essai prend la main
                NSApp.activate(ignoringOtherApps: true)
                f.makeKeyAndOrderFront(nil)
                try? await Task.sleep(nanoseconds: 600_000_000)
                let echelle = projet.reglages.zoomTimeline
                var numero = 100
                for t in temps {
                    // milieu de la premiere piste, sous la regle
                    var p = NSPoint(x: t * echelle, y: 26 + 48)
                    if !doc.isFlipped { p.y = doc.bounds.height - p.y }
                    let w = doc.convert(p, to: nil)
                    numero += 1
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: w, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: f.windowNumber, context: nil,
                                                      eventNumber: numero, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                        try? await Task.sleep(nanoseconds: 120_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let bornes = projet.pistes[0].clips.map { String(format: "%.2f-%.2f", $0.debut, $0.fin) }
                    Journal.ecrire(String(format: "lame a %.2f s : ", t) + bornes.joined(separator: " | "))
                }
                NSApp.terminate(nil)
            }
        }
        // Essai de l'annulation : deux coupes, un deplacement, du texte tape,
        // puis Commande Z quatre fois et Commande Majuscule Z deux fois, par le
        // menu comme au clavier. Le journal note l'etat apres chaque etape.
        if CommandLine.arguments.contains("--essai-annuler") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let f = NSApp.windows.first(where: { $0.contentView?.premierTexte() != nil }),
                      let texte = f.contentView?.premierTexte(),
                      let doc = f.contentView?.defilementTimeline()?.documentView else { return }
                NSApp.activate(ignoringOtherApps: true)
                f.makeKeyAndOrderFront(nil)
                let echelle = projet.reglages.zoomTimeline
                @MainActor func point(_ t: Double) -> NSPoint {
                    var p = NSPoint(x: t * echelle, y: 26 + 74)   // sous la ligne de volume
                    if !doc.isFlipped { p.y = doc.bounds.height - p.y }
                    return doc.convert(p, to: nil)
                }
                @MainActor func souris(_ type: NSEvent.EventType, _ p: NSPoint) async {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: f.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(e, atStart: false)
                    }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
                @MainActor func touche(_ c: String, _ m: NSEvent.ModifierFlags) {
                    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: m,
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: f.windowNumber, context: nil,
                                                characters: c, charactersIgnoringModifiers: c,
                                                isARepeat: false, keyCode: 6) {
                        _ = NSApp.mainMenu?.performKeyEquivalent(with: e)
                    }
                }
                @MainActor func etat(_ etape: String) {
                    let bornes = projet.pistes[0].clips.map { String(format: "%.2f-%.2f", $0.debut, $0.fin) }
                    let pile = Projet.annulation
                    Journal.ecrire("annuler, \(etape) : \(bornes.joined(separator: " | ")) ; texte \(projet.script.count) car. ; "
                                 + "prochaine annulation « \(pile?.canUndo == true ? pile!.undoActionName : "rien") »")
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                etat("depart")
                // une fenetre qu'on vient d'activer avale son premier clic
                await souris(.leftMouseDown, point(1)); await souris(.leftMouseUp, point(1))
                try? await Task.sleep(nanoseconds: 600_000_000)
                outil = .lame
                try? await Task.sleep(nanoseconds: 300_000_000)
                for t in [3.0, 6.0] {
                    await souris(.leftMouseDown, point(t)); await souris(.leftMouseUp, point(t))
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    etat(String(format: "coupe a %.0f s", t))
                }
                outil = .selection
                try? await Task.sleep(nanoseconds: 300_000_000)
                await souris(.leftMouseDown, point(4.5))
                for pas in 1...10 { await souris(.leftMouseDragged, point(4.5 + Double(pas) * 0.15)) }
                await souris(.leftMouseUp, point(6.0))
                try? await Task.sleep(nanoseconds: 400_000_000)
                etat("clip du milieu deplace")
                f.makeFirstResponder(texte)
                texte.setSelectedRange(NSRange(location: 0, length: 0))
                texte.insertText("ESSAI ", replacementRange: texte.selectedRange())
                try? await Task.sleep(nanoseconds: 300_000_000)
                etat("texte tape")
                // le clic dans la timeline retire le clavier au script : Commande Z
                // doit alors toujours defaire, texte compris
                await souris(.leftMouseDown, point(20)); await souris(.leftMouseUp, point(20))
                for i in 1...4 {
                    touche("z", .command)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    etat("Commande Z n\u{00B0} \(i)")
                }
                for i in 1...2 {
                    touche("Z", [.command, .shift])
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    etat("Commande Majuscule Z n\u{00B0} \(i)")
                }
                NSApp.terminate(nil)
            }
        }
        // Aide › Envoyer le journal, pour voir le menu de partage
        if CommandLine.arguments.contains("--essai-envoyer") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // presse-papier prive : l'essai ne touche a rien
                // de ce que l'utilisateur est en train de faire
                let pp = NSPasteboard(name: NSPasteboard.Name("fr.lfd.scriptvoice.essai-envoyer"))
                Journal.envoyer(presse: pp)
                let url = (pp.readObjects(forClasses: [NSURL.self]) as? [URL])?.first
                Journal.ecrire("essai envoyer : presse-papier \(url?.lastPathComponent ?? "vide"), "
                             + "fichier \(url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false ? "present" : "absent")")
                pp.releaseGlobally()
            }
        }
        // Colle a la fin du script un passage noir en Times, comme venu d'une
        // page web, par un presse-papier prive : il doit prendre le style du script.
        if CommandLine.arguments.contains("--essai-coller") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let f = NSApp.windows.first(where: { $0.contentView?.premierTexte() != nil }),
                      let texte = f.contentView?.premierTexte() else { return }
                let pp = NSPasteboard(name: NSPasteboard.Name("fr.lfd.scriptvoice.essai-coller"))
                pp.clearContents()
                pp.writeObjects([NSAttributedString(
                    string: "\nTexte collé depuis une page web, en noir et en Times 11.",
                    attributes: [.font: NSFont(name: "Times New Roman", size: 11) ?? NSFont.systemFont(ofSize: 11),
                                 .foregroundColor: NSColor.black])])
                texte.setSelectedRange(NSRange(location: (texte.string as NSString).length, length: 0))
                Journal.ecrire("essai coller : \(texte.readSelection(from: pp) ? "colle" : "refuse")")
                pp.releaseGlobally()
            }
        }
        // Essai du clavier : clic dans le script, clic dans la timeline, espace,
        // puis retour dans le script. Les evenements passent par la file de
        // l'application, comme ceux de la souris et du clavier.
        if CommandLine.arguments.contains("--essai-focus") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let f = NSApp.windows.first(where: { $0.contentView?.premierTexte() != nil }),
                      let texte = f.contentView?.premierTexte() else { return }
                @MainActor func cliquer(_ p: NSPoint) async {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: f.windowNumber, context: nil,
                                                      eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(e, atStart: false)
                        }
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                @MainActor func espace() async {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: f.windowNumber, context: nil,
                                                    characters: " ", charactersIgnoringModifiers: " ",
                                                    isARepeat: false, keyCode: 49) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                @MainActor func etat(_ etape: String) {
                    Journal.ecrire("focus, \(etape) : clavier au script \(f.firstResponder === texte ? "oui" : "non"), "
                                 + "lecture \(lecteur.enLecture ? "oui" : "non"), "
                                 + "texte \(projet.script.count) car., curseur \(texte.selectedRange().location), "
                                 + "repondeur \(f.firstResponder.map { String(describing: type(of: $0)) } ?? "aucun")")
                }
                NSApp.activate(ignoringOtherApps: true)
                f.makeKeyAndOrderFront(nil)
                try? await Task.sleep(nanoseconds: 600_000_000)
                let dansTexte = texte.convert(NSPoint(x: texte.visibleRect.minX + 120, y: texte.visibleRect.minY + 40), to: nil)
                let dansTimeline = NSPoint(x: 400, y: 60)
                f.makeFirstResponder(texte); etat("clavier donne au script")
                await espace(); etat("espace dans le script")
                await cliquer(dansTimeline); etat("clic dans la timeline")
                await espace(); etat("espace apres la timeline")
                await espace(); etat("espace encore")
                await cliquer(dansTexte); etat("retour dans le script")
                if let r = f.contentView, let sup = r.superview {
                    let surTexte = r.hitTest(sup.convert(dansTexte, from: nil))?.dansLeTexte ?? false
                    let surTimeline = r.hitTest(sup.convert(dansTimeline, from: nil))?.dansLeTexte ?? false
                    Journal.ecrire("focus, reperage : script \(surTexte ? "oui" : "non"), timeline \(surTimeline ? "texte" : "hors texte"), "
                                 + "fenetre cle \(f.isKeyWindow ? "oui" : "non")")
                }
                NSApp.terminate(nil)
            }
        }
        // Essai de lecture : rejoue le montage depuis le debut et note, chaque
        // seconde, ou en est la tete et ou en est vraiment le son.
        if let i = CommandLine.arguments.firstIndex(of: "--essai-lecture"),
           i + 1 < CommandLine.arguments.count {
            let secondes = Double(CommandLine.arguments[i + 1]) ?? 5
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // Apres un essai de prise, on attend que le clip soit pose.
                if let j = CommandLine.arguments.firstIndex(of: "--essai-prise"),
                   j + 1 < CommandLine.arguments.count {
                    let prise = Double(CommandLine.arguments[j + 1]) ?? 3
                    try? await Task.sleep(nanoseconds: UInt64((prise + 2) * 1e9))
                    while enregistreur.enCours { try? await Task.sleep(nanoseconds: 200_000_000) }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                lecteur.mesurerSortie = true
                lecteur.tete = 0
                basculerLecture()
                Journal.ecrire("essai de lecture lance : \(lecteur.enLecture ? "en lecture" : "rien a jouer")")
                for _ in 0..<Int(secondes) {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    Journal.ecrire(String(format: "lecture : tete %.2f s, son %@, crete %.3f, moteur %@, %@",
                                          lecteur.tete,
                                          lecteur.positionAudio.map { String(format: "%.2f s", $0) } ?? "aucun",
                                          lecteur.releverCrete(),
                                          lecteur.moteurEnMarche ? "en marche" : "arrete",
                                          lecteur.enLecture ? "en lecture" : "a l'arret"))
                }
                Journal.ecrire("essai de lecture termine")
                NSApp.terminate(nil)
            }
        }
        // Le dernier projet ferme est propose, si rien d'autre n'est ouvert.
        // --essai-reprise <dossier> montre la feuille sur un projet donne.
        if let i = CommandLine.arguments.firstIndex(of: "--essai-reprise"), i + 1 < CommandLine.arguments.count {
            reprise = Reprise.offre(chemin: CommandLine.arguments[i + 1])
        } else if Reprise.actif, projet.dossier == nil {
            reprise = Reprise.offre()
        }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in projet.enregistrerSiPossible() }
        }
    }

    // MARK: Actions

    private func reprendre(_ offre: Reprise.Offre) {
        projet.reprendre(offre.projet)
        Projet.oublierHistorique()
        // le micro et la vitesse du prompteur sont ceux du projet repris
        prompteur.vitesse = projet.reglages.vitessePrompteur
        if let p = Micros.parUID(projet.reglages.peripheriqueID) { enregistreur.choisir(p) }
        let e = NSApp.currentEvent
        Journal.ecrire("dernier projet rouvert : \(offre.dossier.lastPathComponent)"
                       + (e.map { " (evenement \($0.type.rawValue), touche \($0.type == .keyDown ? Int($0.keyCode) : -1))" } ?? ""))
    }

    private func basculerEnregistrement() {
        if enregistreur.enCours {
            Journal.ecrire("arret de la prise demande")
            enregistreur.arreter()
            prompteur.arreter()
            return
        }
        guard let dossier = projet.dossierPrises else {
            erreur = "Enregistrez d'abord le projet : Fichier, Enregistrer sous."
            Journal.attention("enregistrement refuse : le projet n'a pas encore de dossier")
            return
        }
        enregistreur.gain = Float(projet.reglages.gainEntree)
        let nom = "prise-\(Horloge.nomDeFichier())"
        let depart = lecteur.tete
        enregistreur.debutTimeline = depart
        enregistreur.pisteTimeline = pistePourLaPrise(depuis: depart)
        // Le prompteur part du curseur : on lit la ou on regarde.
        let position = positionDuCurseur()
        Task {
            do {
                Journal.ecrire("demarrage d'une prise : \(nom)")
                let fichier = try await enregistreur.demarrer(dans: dossier, nom: nom)
                Journal.ecrire("prise en cours : \(fichier)")
                prompteur.vitesse = projet.reglages.vitessePrompteur
                prompteur.demarrer(texte: projet.script, depuis: position)
                Journal.ecrire("prompteur lance au mot \(prompteur.index) sur \(prompteur.mots.count)")
                surveillerFin(fichier: fichier, depart: depart)
            } catch {
                erreur = error.localizedDescription
                Journal.erreur("impossible de demarrer la prise", error)
            }
        }
    }

    /// La piste ou s'ecrira la prise. Sa fin est inconnue : il lui faut une
    /// piste libre de la tete jusqu'au bout. La piste active d'abord, puis
    /// celles du dessus ; sinon une piste se cree au-dessus de l'active, et le
    /// clip deja la reste visible en dessous.
    private func pistePourLaPrise(depuis t: Double) -> Int {
        let active = min(max(0, pisteActive), projet.pistes.count - 1)
        let libre = { (i: Int) in !projet.pistes[i].clips.contains { $0.fin > t + 0.001 } }
        if let i = stride(from: active, through: 0, by: -1).first(where: libre) { return i }
        projet.retenir("Enregistrer la prise")
        priseRetenue = true
        projet.pistes.insert(Piste(nom: Edition.nomDePiste(projet.pistes)), at: active)
        return active
    }

    /// Quand la prise s'arrete, elle devient un clip pose sous la tete de lecture.
    private func surveillerFin(fichier: String, depart: Double) {
        Task { @MainActor in
            while enregistreur.enCours { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard let url = projet.dossierPrises?.appendingPathComponent(fichier),
                  let f = try? AVAudioFile(forReading: url) else { return }
            let duree = Double(f.length) / f.processingFormat.sampleRate
            guard duree > 0.1 else {
                Journal.attention("prise trop courte, ecartee : \(fichier)")
                try? FileManager.default.removeItem(at: url); return
            }
            Journal.ecrire(String(format: "prise terminee : %@ (%.2f s)", fichier, duree))
            let clip = Clip(fichier: fichier, debut: depart, entree: 0, sortie: duree,
                            nom: fichier.replacingOccurrences(of: ".wav", with: ""),
                            dureeSource: duree)
            let i = min(enregistreur.pisteTimeline, projet.pistes.count - 1)
            if !priseRetenue { projet.retenir("Enregistrer la prise") }
            priseRetenue = false
            // Une prise faite par-dessus un clip ne le cache pas : elle monte
            // sur une piste libre, l'ancienne reste visible en dessous.
            Edition.poser([ClipPlace(piste: i, clip: clip)], dans: &projet.pistes)
            projet.modifie = true
            montage.selection = [clip.id]
            lecteur.tete = clip.fin
            projet.enregistrerSiPossible()
        }
    }

    private func basculerLecture() {
        if lecteur.enLecture { lecteur.arreter() } else { lecteur.jouer(projet, depuis: lecteur.tete) }
    }

    private func positionDuCurseur() -> Int {
        // Le script garde son curseur meme quand on a clique dans la timeline :
        // on le lit dans le champ lui-meme, pas dans celui qui a le clavier.
        guard let vue = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil
                                                     && $0.contentView?.premierTexte() != nil })?
                .contentView?.premierTexte() else { return 0 }
        return vue.selectedRange().location
    }


    private func exporter() {
        guard projet.duree > 0 else { erreur = "La timeline est vide."; return }
        let p = NSSavePanel()
        let format = projet.reglages.formatExport
        p.nameFieldStringValue = "voix-off.\(format)"
        p.allowedContentTypes = [UTType(filenameExtension: format) ?? .wav]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try Export.rendre(projet, vers: url, format: format)
            Journal.ecrire("export reussi : \(url.lastPathComponent)")
        } catch {
            erreur = error.localizedDescription
            Journal.erreur("export impossible", error)
        }
    }

    // MARK: Clavier

    private func toucheAppuyee(_ e: NSEvent) -> Bool {
        let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
        // Pendant une prise, apres un clic dans la timeline (le script n'a plus
        // le clavier), espace arrete l'enregistrement. Dans le script, il met
        // toujours le prompteur en pause.
        if enregistreur.enCours, e.keyCode == 49, m.isEmpty,
           !((e.window ?? NSApp.keyWindow)?.firstResponder is NSTextView) {
            basculerEnregistrement()
            return true
        }
        // Pendant la lecture du prompteur, le clavier pilote le prompteur.
        if prompteur.actif, m.isDisjoint(with: [.command, .option, .control]) {
            switch e.keyCode {
            case 49:  prompteur.pause(); return true                 // espace
            case 125: prompteur.rattraper(1); return true            // bas
            case 126: prompteur.rattraper(-1); return true           // haut
            case 53:  basculerEnregistrement(); return true          // echap
            default: break
            }
        }
        // Le script a le clavier : tout lui revient, menus compris. Les
        // panneaux (reglages) gardent aussi leurs touches.
        guard let fenetre = e.window ?? NSApp.keyWindow, fenetre.sheetParent == nil,
              !(fenetre.firstResponder is NSTextView) else { return false }
        return raccourciDeMontage(e, m)
    }

    /// Les raccourcis de la timeline, ceux des logiciels de montage. Ils ne valent que
    /// quand le script n'a pas le clavier : on clique dans la timeline, et
    /// espace, Commande C ou Commande B y travaillent.
    private func raccourciDeMontage(_ e: NSEvent, _ m: NSEvent.ModifierFlags) -> Bool {
        let c = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let k = e.keyCode
        switch m {
        case [.command]:
            switch c {
            case "a": montage.toutSelectionner()
            case "c": montage.copier()
            case "x": montage.couper()
            case "v": montage.coller()
            case "d": montage.dupliquer()
            case "b": montage.lame(toutesPistes: false)
            case "=", "+": montage.zoomer?(1.5)
            case "-": montage.zoomer?(1 / 1.5)
            default: return false
            }
        case [.command, .shift]:
            switch c {
            case "a": montage.deselectionner()
            case "b": montage.lame(toutesPistes: true)
            default: return false
            }
        case [.option]:
            switch k {
            case 33: montage.elaguerJusquaTete(debut: true)        // Option [ (^ en AZERTY)
            case 30: montage.elaguerJusquaTete(debut: false)       // Option ] ($ en AZERTY)
            case 9:  montage.coller(inserer: false)                // Option V
            default: return false
            }
        case [.control]:
            // Controle = et Controle - : la position de la touche (QWERTY) ou le
            // caractere tape (AZERTY, ou le moins est sur le 6)
            if [24, 69].contains(k) || c == "=" || c == "+" { montage.volume(1) }
            else if [27, 78].contains(k) || c == "-" { montage.volume(-1) }
            else { return false }
        case [.shift]:
            switch k {
            case 51, 117: montage.supprimer(refermer: false)       // remplacer par un blanc
            case 123: montage.avancer(images: -10)
            case 124: montage.avancer(images: 10)
            case 43:  montage.decaler(images: -10)
            case 47:  montage.decaler(images: 10)
            default:
                guard c == "z" else { return false }
                montage.zoomer?(nil)                               // tout le montage a l'ecran
            }
        case []:
            switch k {
            case 49: basculerLecture()                              // espace
            case 51, 117: montage.supprimer(refermer: true)
            case 123: montage.avancer(images: -1)
            case 124: montage.avancer(images: 1)
            case 126: montage.pointDeMontage(suivant: false)
            case 125: montage.pointDeMontage(suivant: true)
            case 115: montage.allerAuDebut()
            case 119: montage.allerALaFin()
            case 43:  montage.decaler(images: -1)                   // virgule (; en AZERTY)
            case 47:  montage.decaler(images: 1)                    // point (: en AZERTY)
            case 53:  montage.deselectionner()                      // Echap
            default:
                switch c {
                case "a": outil = .selection
                case "b": outil = .lame
                case "t": outil = .elaguer
                case "h": outil = .main
                case "n": projet.reglages.aimantation.toggle()
                case "v": montage.basculerActif()
                case "l": if !lecteur.enLecture { basculerLecture() }
                case "k": if lecteur.enLecture { basculerLecture() }
                case ",": montage.decaler(images: -1)
                default: return false
                }
            }
        default:
            return false
        }
        return true
    }
}

/// Capte les touches sans passer par un menu : un moniteur local, pose une fois.
struct Raccourcis: NSViewRepresentable {
    let action: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let vue = NSView()
        context.coordinator.moniteur = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            action(e) ? nil : e
        }
        return vue
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinateur { Coordinateur() }

    final class Coordinateur {
        var moniteur: Any?
        deinit {
            if let m = moniteur { NSEvent.removeMonitor(m) }
        }
    }
}

extension Horloge {
    static func nomDeFichier() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}


extension NSView {
    /// Le premier champ de texte trouve dans la hierarchie : la capture et les
    /// essais en ont besoin, SwiftUI ne donnant pas acces a ses vues AppKit.
    func premierTexte() -> NSTextView? {
        if let t = self as? NSTextView { return t }
        for sous in subviews { if let t = sous.premierTexte() { return t } }
        return nil
    }

    /// Le defilement de la timeline : celui qui ne porte pas de texte et se
    /// trouve le plus bas dans la fenetre (le PDF a aussi le sien, plus haut).
    func defilementTimeline() -> NSScrollView? {
        var tous: [NSScrollView] = []
        func parcourir(_ v: NSView) {
            if let d = v as? NSScrollView, !(d.documentView is NSTextView) { tous.append(d) }
            v.subviews.forEach(parcourir)
        }
        parcourir(self)
        return tous.min { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
    }

    /// Vrai pour le champ de texte et tout ce qui l'entoure (sa barre de
    /// defilement comprise) : y cliquer ne doit pas lui retirer le clavier.
    var dansLeTexte: Bool {
        var v: NSView? = self
        while let courante = v {
            if courante is NSTextView { return true }
            if let d = courante as? NSScrollView, d.documentView is NSTextView { return true }
            v = courante.superview
        }
        return false
    }
}

/// Garde la disposition de la fenetre dans le projet : la largeur de la
/// colonne du PDF et la hauteur de la timeline. SwiftUI ne dit rien de ses
/// separateurs ; on retrouve les NSSplitView qu'il pose, on les lit quand on
/// les tire, et on les replace quand un projet s'ouvre.
struct Disposition: NSViewRepresentable {
    @ObservedObject var projet: Projet

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ vue: NSView, context: Context) { context.coordinator.suivre(vue, projet: projet) }
    func makeCoordinator() -> Coordinateur { Coordinateur() }

    @MainActor final class Coordinateur: NSObject {
        private weak var projet: Projet?
        /// script | PDF, cote a cote
        private weak var colonnes: NSSplitView?
        /// le haut | la timeline
        private weak var etages: NSSplitView?
        private var observateur: Any?
        private var dossierPlace: URL??
        /// vrai pendant qu'on replace : ce mouvement-la ne doit pas etre releve
        private var enPlacement = true

        func suivre(_ vue: NSView, projet: Projet) {
            self.projet = projet
            guard dossierPlace == nil || dossierPlace! != projet.dossier else { return }
            dossierPlace = .some(projet.dossier)
            enPlacement = true
            // la fenetre doit avoir sa taille et SwiftUI ses separateurs
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak vue] in
                self?.trouver(dans: vue?.window?.contentView)
                self?.placer()
            }
        }

        private func trouver(dans racine: NSView?) {
            guard let racine, colonnes == nil || etages == nil else { return }
            var toutes: [NSSplitView] = []
            func parcourir(_ v: NSView) {
                if let s = v as? NSSplitView { toutes.append(s) }
                v.subviews.forEach(parcourir)
            }
            parcourir(racine)
            colonnes = toutes.first { $0.isVertical }
            etages = toutes.first { !$0.isVertical }
            observateur = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, let s = n.object as? NSSplitView,
                          s === self.colonnes || s === self.etages else { return }
                    self.relever()
                }
            }
        }

        private static func panneaux(_ s: NSSplitView) -> [NSView] {
            s.arrangedSubviews.isEmpty ? s.subviews : s.arrangedSubviews
        }

        private func placer() {
            defer {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.enPlacement = false }
            }
            guard let r = projet?.reglages else { return }
            if let s = colonnes, r.largeurPDF > 0, Self.panneaux(s).count == 2 {
                s.setPosition(s.bounds.width - CGFloat(r.largeurPDF) - s.dividerThickness, ofDividerAt: 0)
            }
            if let s = etages, r.hauteurTimeline > 0, Self.panneaux(s).count == 2 {
                s.setPosition(s.bounds.height - CGFloat(r.hauteurTimeline) - s.dividerThickness, ofDividerAt: 0)
            }
        }

        private func relever() {
            guard !enPlacement, let projet else { return }
            if let s = colonnes, let pdf = Self.panneaux(s).last {
                let l = Double(pdf.frame.width.rounded())
                if abs(l - projet.reglages.largeurPDF) >= 1 { projet.reglages.largeurPDF = l }
            }
            if let s = etages, let bas = Self.panneaux(s).last {
                let h = Double(bas.frame.height.rounded())
                if abs(h - projet.reglages.hauteurTimeline) >= 1 { projet.reglages.hauteurTimeline = h }
            }
        }
    }
}
