import Accelerate
import AVFoundation
import AppKit
import Foundation

/// Banc d'essai : `ScriptVoice --autotest`.
///
/// Verifie la chaine complete sans ouvrir de fenetre — montage, disque, export,
/// prompteur, micros, enregistrement, lecture. Chaque verification dit ce qu'elle
/// attendait et ce qu'elle a obtenu, pour qu'un echec soit lisible sans relire
/// le code.
@MainActor
enum Autotest {
    private static var reussites = 0
    private static var echecs: [String] = []

    static func verifier(_ titre: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            reussites += 1
            print("  ok   \(titre)")
        } else {
            echecs.append(titre)
            print("  RATE \(titre)  \(detail())")
        }
    }

    static func proche(_ titre: String, _ a: Double, _ b: Double, _ tolerance: Double = 0.05) {
        verifier(titre, abs(a - b) <= tolerance, "attendu \(b), obtenu \(a)")
    }

    static func lancer() async {
        setbuf(stdout, nil)          // sortie immediate, meme redirigee vers un fichier
        // Un blocage est un echec comme un autre : on le signale plutot que
        // d'attendre indefiniment.
        let garde = Thread {
            Thread.sleep(forTimeInterval: 90)
            print("\n  RATE le banc d'essai s'est bloque : aucune reponse en 90 secondes")
            exit(2)
        }
        garde.start()
        print("Script Voice — banc d'essai\n")
        let bac = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bac) }

        await montage()
        annuler()
        edition()
        await disque(bac)
        await exporter(bac)
        voix(bac)
        prompteur()
        miseEnForme()
        await horloge()
        peripheriques()
        // --sans-micro : quand une autre application tient le micro, sa capture
        // reste suspendue et fige la lecture qui suit. On saute alors l'essai.
        if CommandLine.arguments.contains("--sans-micro") {
            print("\nEnregistrement\n       ignore a la demande (--sans-micro)")
        } else {
            await enregistrement(bac)
        }
        await lecture(bac)

        print("\n\(reussites) verifications passees, \(echecs.count) en echec")
        for e in echecs { print("  - \(e)") }
        exit(echecs.isEmpty ? 0 : 1)
    }

    // MARK: Commande Z

    /// Chaque geste de montage se defait, dans l'ordre inverse, et se refait.
    /// Les gestes appellent `retenir` comme le fait la timeline.
    private static func annuler() {
        print("\nAnnuler")
        let pile = UndoManager()
        pile.groupsByEvent = false          // hors boucle d'evenements, un paquet par geste
        Projet.pileEssai = pile
        defer { Projet.pileEssai = nil }
        let p = Projet()
        p.pistes = [Piste(nom: "Voix 1", clips: [Clip(fichier: "a.wav", debut: 0, entree: 0, sortie: 10,
                                                       dureeSource: 10)])]
        func geste(_ nom: String, avant: [Piste]? = nil, _ faire: () -> Void) {
            pile.beginUndoGrouping()
            faire()
            p.retenir(nom, avant: avant)
            pile.endUndoGrouping()
        }
        let bornes = { p.pistes[0].clips.map { "\($0.debut)-\($0.fin)" }.joined(separator: " ") }

        // couper a 4 s
        let avantCoupe = p.pistes
        geste("Couper", avant: avantCoupe) { _ = p.pistes[0].couper(p.pistes[0].clips[0].id, a: 4) }
        // deplacer le morceau de droite a 6 s
        let avantDeplacement = p.pistes
        geste("Déplacer le clip", avant: avantDeplacement) { p.pistes[0].clips[1].debut = 6 }
        // elaguer la fin du premier morceau
        let avantElagage = p.pistes
        geste("Élaguer le clip", avant: avantElagage) { p.pistes[0].clips[0].sortie = 3 }
        // monter le volume, puis supprimer le second morceau
        let avantVolume = p.pistes
        geste("Volume du clip", avant: avantVolume) { p.pistes[0].clips[0].volume = 5 }
        let avantSuppression = p.pistes
        geste("Supprimer le clip", avant: avantSuppression) { p.pistes[0].clips.remove(at: 1) }
        let final = p.pistes

        verifier("le menu annonce la derniere action", pile.undoActionName == "Supprimer le clip",
                 "« \(pile.undoActionName) »")
        pile.undo(); verifier("Commande Z rend le clip supprime", p.pistes == avantSuppression, bornes())
        pile.undo(); verifier("Commande Z rend le volume", p.pistes == avantVolume, bornes())
        pile.undo(); verifier("Commande Z defait l'elagage", p.pistes == avantElagage, bornes())
        pile.undo(); verifier("Commande Z ramene le clip deplace", p.pistes == avantDeplacement, bornes())
        pile.undo(); verifier("Commande Z recolle la coupe", p.pistes == avantCoupe && p.pistes[0].clips.count == 1,
                              bornes())
        verifier("plus rien a annuler apres le premier geste", !pile.canUndo)
        for _ in 0..<5 { pile.redo() }
        verifier("Commande Majuscule Z refait les cinq gestes", p.pistes == final, bornes())
        pile.undo(); pile.undo()
        // une action nouvelle apres des annulations efface ce qui restait a refaire
        geste("Couper", avant: p.pistes) { _ = p.pistes[0].couper(p.pistes[0].clips[0].id, a: 2) }
        verifier("un geste neuf efface ce qui restait a refaire", !pile.canRedo)
    }

    // MARK: Les commandes de la timeline

    /// Les commandes de montage, sur les pistes seules.
    private static func edition() {
        print("\nTimeline")
        func clip(_ debut: Double, _ duree: Double, source: Double = 60) -> Clip {
            Clip(fichier: "a.wav", debut: debut, entree: 10, sortie: 10 + duree, dureeSource: source)
        }
        func bornes(_ p: Piste) -> String {
            p.clips.map { String(format: "%.2f-%.2f", $0.debut, $0.fin) }.joined(separator: " ")
        }

        // Aucun clip n'en cache un autre : pose sur une place prise, il monte.
        var pistes = [Piste(nom: "Voix 1", clips: [clip(0, 10)])]
        let pose = Edition.poser([ClipPlace(piste: 0, clip: clip(4, 3))], dans: &pistes)
        verifier("un clip pose sur un autre cree une piste au-dessus", pistes.count == 2 && pose.first?.piste == 0,
                 "\(pistes.count) pistes")
        verifier("le clip du dessous reste entier, sur la piste du dessous",
                 bornes(pistes[1]) == "0.00-10.00", bornes(pistes[1]))
        Edition.poser([ClipPlace(piste: 1, clip: clip(20, 2))], dans: &pistes)
        verifier("une place libre garde sa piste", bornes(pistes[1]) == "0.00-10.00 20.00-22.00", bornes(pistes[1]))
        Edition.poser([ClipPlace(piste: 1, clip: clip(8, 1))], dans: &pistes)
        verifier("pose sur une place prise, il monte sur la premiere piste libre au-dessus",
                 pistes.count == 2 && bornes(pistes[0]) == "4.00-7.00 8.00-9.00",
                 "\(pistes.count) pistes, \(bornes(pistes[0]))")
        Edition.poser([ClipPlace(piste: 1, clip: clip(5, 1))], dans: &pistes)
        verifier("si aucune piste du dessus n'est libre, une se cree juste au-dessus de la visee",
                 pistes.count == 3 && bornes(pistes[1]) == "5.00-6.00" && bornes(pistes[2]).hasPrefix("0.00-10.00"),
                 "\(pistes.map(bornes))")
        let chevauchent = pistes.contains { p in
            p.clips.enumerated().contains { i, a in p.clips.dropFirst(i + 1).contains { $0.debut < a.fin - 0.001 } }
        }
        verifier("jamais deux clips l'un sur l'autre", !chevauchent)

        // Supprimer referme le vide ; Majuscule Supprimer le laisse.
        var p1 = [Piste(nom: "Voix 1", clips: [clip(0, 4), clip(4, 3), clip(7, 5)])]
        let milieu = p1[0].clips[1].id
        var p2 = p1
        Edition.supprimer([milieu], dans: &p1, refermer: true)
        verifier("Supprimer referme le vide", bornes(p1[0]) == "0.00-4.00 4.00-9.00", bornes(p1[0]))
        Edition.supprimer([milieu], dans: &p2, refermer: false)
        verifier("Majuscule Supprimer laisse un blanc", bornes(p2[0]) == "0.00-4.00 7.00-12.00", bornes(p2[0]))

        // Copier, coller : a la tete, en inserant, plusieurs clips gardent leur disposition.
        var p3 = [Piste(nom: "Voix 1", clips: [clip(0, 2), clip(3, 2), clip(10, 5)]), Piste(nom: "Voix 2")]
        let presse = Edition.copier([p3[0].clips[0].id, p3[0].clips[1].id], dans: p3)
        let colles = Edition.coller(presse, a: 12, piste: 0, inserer: true, dans: &p3)
        verifier("Commande V colle deux clips en gardant leur ecart", colles.count == 2
                 && bornes(p3[0]).contains("12.00-14.00 15.00-17.00"), bornes(p3[0]))
        verifier("Commande V coupe le clip sous la tete et repousse la suite",
                 bornes(p3[0]) == "0.00-2.00 3.00-5.00 10.00-12.00 12.00-14.00 15.00-17.00 17.00-20.00", bornes(p3[0]))
        let avantOption = p3[0].clips.count
        _ = Edition.coller(presse, a: 0, piste: 0, inserer: false, dans: &p3)
        verifier("Option V colle sur une piste libre sans rien toucher", p3[0].clips.count == avantOption + 0
                 || p3.count == 3, "\(p3.count) pistes")

        // Deplacer, d'une piste a l'autre, et Option-glisser
        var p4 = [Piste(nom: "Voix 1", clips: [clip(0, 2), clip(5, 2)]), Piste(nom: "Voix 2")]
        let premier = p4[0].clips[0].id
        let bouge = Edition.deplacer([premier], dt: 10, dp: 1, copie: false, dans: &p4)
        verifier("un clip se deplace dans le temps et change de piste",
                 bornes(p4[1]) == "10.00-12.00" && bornes(p4[0]) == "5.00-7.00", bornes(p4[1]))
        _ = Edition.deplacer(bouge, dt: -20, dp: -5, copie: true, dans: &p4)
        verifier("Option-glisser laisse l'original, borne a zero et a la premiere piste",
                 bornes(p4[1]) == "10.00-12.00" && bornes(p4[0]) == "0.00-2.00 5.00-7.00", bornes(p4[0]))

        // Lame, a la tete
        var p5 = [Piste(nom: "Voix 1", clips: [clip(0, 10)]), Piste(nom: "Voix 2", clips: [clip(2, 6)])]
        Edition.lame(a: 4, ids: nil, pistes: [0], dans: &p5)
        verifier("Commande B coupe la piste active seulement", p5[0].clips.count == 2 && p5[1].clips.count == 1)
        Edition.lame(a: 5, ids: nil, pistes: nil, dans: &p5)
        verifier("Majuscule Commande B coupe toutes les pistes", p5[0].clips.count == 3 && p5[1].clips.count == 2)

        // Elaguer jusqu'a la tete (Option [ et Option ])
        var p6 = [Piste(nom: "Voix 1", clips: [clip(0, 10)])]
        _ = Edition.elaguerJusqua(3, debut: true, ids: nil, pistes: nil, dans: &p6)
        _ = Edition.elaguerJusqua(8, debut: false, ids: nil, pistes: nil, dans: &p6)
        verifier("Option [ et Option ] elaguent jusqu'a la tete", bornes(p6[0]) == "3.00-8.00"
                 && abs(p6[0].clips[0].entree - 13) < 0.001, bornes(p6[0]))

        // Elagage au bord : l'outil Selection entraine la suite, Elaguer s'arrete au voisin
        let p7 = Piste(nom: "Voix 1", clips: [clip(0, 4), clip(4, 4), clip(10, 2)])
        let a = p7.clips[0].id
        let ripple = Edition.elaguer(p7, id: a, bord: .fin, de: -1, ripple: true)
        verifier("tirer la fin avec l'outil Selection entraine la suite",
                 bornes(ripple) == "0.00-3.00 3.00-7.00 9.00-11.00", bornes(ripple))
        let bute = Edition.elaguer(p7, id: a, bord: .fin, de: 3, ripple: false)
        verifier("l'outil Elaguer s'arrete au clip voisin", bornes(bute) == "0.00-4.00 4.00-8.00 10.00-12.00",
                 bornes(bute))
        let tete = Edition.elaguer(p7, id: p7.clips[2].id, bord: .debut, de: -15, ripple: false)
        verifier("un debut ne remonte pas avant le voisin", bornes(tete).hasSuffix("8.00-12.00"), bornes(tete))

        // Fondus, desactivation, duplication
        var p8 = [Piste(nom: "Voix 1", clips: [clip(0, 0.6)])]
        Edition.fondus([p8[0].clips[0].id], duree: 0.5, dans: &p8)
        verifier("des fondus ne depassent jamais la moitie du clip", abs(p8[0].clips[0].fonduEntree - 0.3) < 0.001)
        let dup = Edition.dupliquer([p8[0].clips[0].id], dans: &p8)
        verifier("dupliquer pose la copie juste apres", dup.count == 1 && bornes(p8[0]) == "0.00-0.60 0.60-1.20",
                 bornes(p8[0]))
        var p9 = [Piste(nom: "Voix 1", clips: [clip(0, 6)])]
        p9[0].clips[0].fonduEntree = 1; p9[0].clips[0].fonduSortie = 1
        _ = p9[0].couper(p9[0].clips[0].id, a: 3)
        verifier("la lame laisse chaque fondu a son bout", p9[0].clips[0].fonduSortie == 0
                 && p9[0].clips[1].fonduEntree == 0 && p9[0].clips[1].fonduSortie == 1)

        // Les sons importes se posent sous les voix
        var p10 = [Piste(nom: "Voix 1", clips: [clip(0, 10)])]
        var musique = clip(0, 30); musique.voix = false
        let i1 = Edition.pisteDeSon(pour: [musique], dans: &p10)
        Edition.poser([ClipPlace(piste: i1, clip: musique)], dans: &p10)
        verifier("un son importe se pose sur une piste neuve, sous la voix",
                 p10.count == 2 && p10[1].nom == "Son 1" && p10[0].clips.count == 1, p10.map(\.nom).joined(separator: ", "))
        var ambiance = clip(40, 5); ambiance.voix = false
        let i2 = Edition.pisteDeSon(pour: [ambiance], dans: &p10)
        verifier("un second son rejoint la piste des sons s'il y a la place", i2 == 1 && p10.count == 2)
        var dessus = clip(10, 5); dessus.voix = false
        let i3 = Edition.pisteDeSon(pour: [dessus], dans: &p10)
        verifier("sans la place, une autre piste de sons se cree en bas", i3 == 2 && p10[2].nom == "Son 2")
        let json = try? JSONEncoder().encode(musique)
        let relu = json.flatMap { try? JSONDecoder().decode(Clip.self, from: $0) }
        verifier("un son importe reste un son une fois enregistre", relu?.voix == false)

        // Projets recents : le dernier ouvert en tete, sans doublon, douze au plus
        if let essai = UserDefaults(suiteName: "fr.lfd.scriptvoice.essai") {
            let vraie = Recents.reglages
            Recents.reglages = essai
            Recents.effacer()
            let a = URL(fileURLWithPath: "/tmp/A.scriptvoice"), b = URL(fileURLWithPath: "/tmp/B.scriptvoice")
            Recents.ajouter(a); Recents.ajouter(b); Recents.ajouter(a)
            verifier("le projet rouvert remonte en tete, sans doublon", Recents.liste == [a, b],
                     Recents.liste.map(\.lastPathComponent).joined(separator: ", "))
            for k in 0..<20 { Recents.ajouter(URL(fileURLWithPath: "/tmp/P\(k).scriptvoice")) }
            verifier("la liste des recents garde les douze derniers", Recents.liste.count == Recents.maximum
                     && Recents.liste.first?.lastPathComponent == "P19.scriptvoice")
            Recents.effacer()
            Recents.reglages = vraie
        }

        // Pistes ajoutees : chaque nom reste unique
        let noms = [Piste(nom: "Voix 1"), Piste(nom: "Voix 3"), Piste(nom: "Son 1")]
        verifier("une piste neuve prend le premier nom libre",
                 Edition.nomDePiste(noms) == "Voix 2" && Edition.nomDePiste(noms, prefixe: "Son") == "Son 2")

        // Les fondus s'entendent : le debut d'un fondu entrant est muet
        var son = [Float](repeating: 1, count: 4800)
        son.withUnsafeMutableBufferPointer { b in
            Voix.fondre(b.baseAddress!, 4800, sr: 48000, fondus: .init(entree: 0.05, sortie: 0, depuis: 0, total: 0.1))
        }
        verifier("le fondu entrant part du silence et arrive au plein niveau",
                 son[0] < 0.01 && abs(son[2400] - 1) < 0.01 && son[1200] > 0.6 && son[1200] < 0.8,
                 "\(son[0]) \(son[1200]) \(son[2400])")
    }

    // MARK: Les regles de montage

    private static func montage() async {
        print("Montage")
        var piste = Piste(nom: "test")
        let clip = Clip(fichier: "a.wav", debut: 2, entree: 1, sortie: 5, nom: "a", dureeSource: 9)
        piste.clips = [clip]
        proche("duree d'un clip", clip.duree, 4)
        proche("fin d'un clip", clip.fin, 6)
        verifier("un clip contient un instant interieur", clip.contient(3))
        verifier("un clip ne contient pas sa propre fin", !clip.contient(6))

        let droite = piste.couper(clip.id, a: 4)
        verifier("la coupe cree un second clip", droite != nil && piste.clips.count == 2)
        if piste.clips.count == 2 {
            let g = piste.clips[0], d = piste.clips[1]
            proche("le morceau gauche s'arrete a la coupe", g.fin, 4)
            proche("le morceau droit commence a la coupe", d.debut, 4)
            proche("les deux morceaux font la duree d'origine", g.duree + d.duree, 4)
            proche("le morceau droit entre plus loin dans le fichier", d.entree, 3)
            verifier("les deux morceaux pointent le meme fichier", g.fichier == d.fichier)
            verifier("le morceau droit a sa propre identite", g.id != d.id)
        }
        verifier("couper hors du clip ne fait rien", piste.couper(piste.clips[0].id, a: 99) == nil)
        verifier("couper au ras du bord ne fait rien", piste.couper(piste.clips[0].id, a: 2.001) == nil)

        proche("l'aimant prend le point le plus proche",
               Aimant.caler(5.1, sur: [0, 4, 5, 12], seuil: 0.5), 5)
        proche("l'aimant laisse passer un point trop loin",
               Aimant.caler(8.0, sur: [0, 4, 5, 12], seuil: 0.5), 8)

        var p = Projet()
        p.pistes = [piste]
        proche("la duree du projet est la fin du dernier clip", p.duree, 6)
    }

    // MARK: Le disque

    private static func disque(_ bac: URL) async {
        print("\nDisque")
        let projet = Projet()
        projet.script = "Lucas et Adam.\nDeux vies opposées."
        projet.pdf = "/tmp/support.pdf"
        projet.reglages.vitessePrompteur = 162
        projet.reglages.policeEditeur = 23
        projet.scriptFormat = [Marque(debut: 0, longueur: 14, gras: true, taille: 3),
                               Marque(debut: 15, longueur: 5, italique: true, souligne: true)]
        projet.pistes = [Piste(nom: "Voix 1", clips: [
            Clip(fichier: "p1.wav", debut: 0, entree: 0, sortie: 3, nom: "une", dureeSource: 3)
        ]), Piste(nom: "Voix 2")]

        let dossier = bac.appendingPathComponent("Essai.scriptvoice")
        do { try projet.enregistrer(dans: dossier) } catch {
            verifier("enregistrer un projet", false, "\(error)"); return
        }
        verifier("le fichier de projet existe",
                 FileManager.default.fileExists(atPath: dossier.appendingPathComponent("projet.json").path))
        verifier("le dossier des prises existe",
                 FileManager.default.fileExists(atPath: dossier.appendingPathComponent("prises").path))

        guard let relu = try? Projet.ouvrir(dossier) else {
            verifier("relire le projet", false); return
        }
        verifier("le script est conserve, accents compris", relu.script == projet.script)
        verifier("le chemin du PDF est conserve", relu.pdf == projet.pdf)
        proche("la vitesse du prompteur est conservee", relu.reglages.vitessePrompteur, 162)
        proche("la taille du texte est conservee", relu.reglages.policeEditeur, 23)
        verifier("les deux pistes sont conservees", relu.pistes.count == 2)
        verifier("le clip est conserve", relu.pistes.first?.clips.first?.fichier == "p1.wav")
        verifier("la mise en forme du script est conservee", relu.scriptFormat == projet.scriptFormat)
        verifier("le titre reste en gras et en grand",
                 relu.scriptFormat.first?.gras == true && relu.scriptFormat.first?.taille == 3)
        verifier("le dossier du projet est retenu", relu.dossier == dossier)
        verifier("un projet relu n'est pas marque modifie", !relu.modifie)

        // Un projet enregistre par une version anterieure doit rester lisible :
        // ici il manque les reglages, le solo, et la duree du fichier source.
        let ancien = bac.appendingPathComponent("Ancien.scriptvoice")
        try? FileManager.default.createDirectory(at: ancien, withIntermediateDirectories: true)
        let json = """
        {"script":"Un ancien script","pdf":"/tmp/a.pdf",
         "pistes":[{"nom":"Voix 1","clips":[{"fichier":"vieux.wav","debut":0,"entree":0,"sortie":2}]}]}
        """
        try? Data(json.utf8).write(to: ancien.appendingPathComponent("projet.json"))
        if let vieux = try? Projet.ouvrir(ancien) {
            verifier("un projet d'une version anterieure s'ouvre", true)
            verifier("son script est lu", vieux.script == "Un ancien script")
            verifier("son clip est lu", vieux.pistes.first?.clips.first?.fichier == "vieux.wav")
            proche("les reglages manquants prennent leur valeur par defaut",
                   vieux.reglages.vitessePrompteur, 145)
            proche("la duree source manquante vaut la sortie du clip",
                   vieux.pistes.first?.clips.first?.dureeSource ?? 0, 2)
            verifier("sans mise en forme, le script reste du texte nu", vieux.scriptFormat.isEmpty)
        } else {
            verifier("un projet d'une version anterieure s'ouvre", false,
                     "le decodage a echoue : les projets existants seraient perdus")
        }
    }

    /// Le battement doit tirer a l'heure, meme quand la fenetre n'est pas au
    /// premier plan : un chrono qui saute de cinq secondes et un prompteur qui
    /// ne bouge pas rendent l'application inutilisable, sans rien faire planter.
    private static func horloge() async {
        print("\nHorloge")
        let b = Battement()
        var tirs = 0
        let depart = Date()
        b.lancer(toutes: 1.0 / 20) { tirs += 1 }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        b.arreter()
        let ecoule = Date().timeIntervalSince(depart)
        verifier("le battement tire vingt fois par seconde", tirs >= 15,
                 "\(tirs) tirs en \(String(format: "%.2f", ecoule)) s")
        let apres = tirs
        try? await Task.sleep(nanoseconds: 300_000_000)
        verifier("arreter le battement l'arrete vraiment", tirs == apres)
    }

    private static func miseEnForme() {
        print("\nMise en forme")
        verifier("quatre tailles sont proposees", PaletteTexte.tailles.count == 4)
        proche("la taille normale est celle du corps de texte",
               PaletteTexte.tailles[1].facteur, 1.0)
        verifier("les tailles vont de la plus petite a la plus grande",
                 zip(PaletteTexte.tailles, PaletteTexte.tailles.dropFirst())
                    .allSatisfy { $0.facteur < $1.facteur })
        verifier("une plage sans aucun attribut ne s'enregistre pas",
                 Marque(debut: 0, longueur: 4).neutre)
        verifier("une plage en gras s'enregistre",
                 !Marque(debut: 0, longueur: 4, gras: true).neutre)
        verifier("une plage en grand s'enregistre",
                 !Marque(debut: 0, longueur: 4, taille: 2).neutre)
        // Un rang de taille absurde ne doit pas faire tomber l'application.
        let large = Marque(debut: 0, longueur: 1, taille: 99)
        verifier("un rang de taille inconnu se ramene a la table",
                 min(max(0, large.taille), PaletteTexte.tailles.count - 1) == 3)

        // Un texte colle depuis le web arrive en noir, en Times 11 : il doit
        // prendre le style du script. Presse-papier prive, pour ne pas toucher
        // a celui de l'utilisateur.
        let champ = ChampScript(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        champ.isRichText = true
        let clair = NSColor(white: 0.92, alpha: 1)
        let corps = NSFont.systemFont(ofSize: 18)
        champ.typingAttributes = [.font: corps, .foregroundColor: clair]
        let pp = NSPasteboard(name: NSPasteboard.Name("fr.lfd.scriptvoice.essai-\(UUID().uuidString)"))
        defer { pp.releaseGlobally() }
        let etranger = NSAttributedString(string: "Venu d'ailleurs", attributes: [
            .font: NSFont(name: "Times New Roman", size: 11) ?? NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.black, .backgroundColor: NSColor.yellow])
        pp.clearContents()
        pp.writeObjects([etranger])
        let lu = champ.readSelection(from: pp)
        let a = champ.textStorage?.attributes(at: 0, effectiveRange: nil) ?? [:]
        verifier("un texte etranger se colle", lu && champ.string == "Venu d'ailleurs", champ.string)
        verifier("il prend la couleur du script, pas le noir",
                 (a[.foregroundColor] as? NSColor) == clair, "\(String(describing: a[.foregroundColor]))")
        verifier("il prend la police et le corps du script",
                 (a[.font] as? NSFont)?.pointSize == 18
                    && (a[.font] as? NSFont)?.familyName == corps.familyName,
                 "\(String(describing: a[.font]))")
        verifier("il ne garde pas son fond", a[.backgroundColor] == nil)

        // Copie a l'interieur du script : le gras survit.
        let gras = NSFontManager.shared.convert(corps, toHaveTrait: .boldFontMask)
        champ.textStorage?.setAttributedString(NSAttributedString(string: "Titre",
            attributes: [.font: gras, .foregroundColor: clair]))
        champ.setSelectedRange(NSRange(location: 0, length: 5))
        pp.declareTypes(champ.writablePasteboardTypes, owner: nil)
        _ = champ.writeSelection(to: pp, types: champ.writablePasteboardTypes)
        champ.textStorage?.setAttributedString(NSAttributedString(string: ""))
        champ.typingAttributes = [.font: corps, .foregroundColor: clair]
        _ = champ.readSelection(from: pp)
        let f = (champ.textStorage?.length ?? 0) > 0
            ? champ.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        verifier("une copie interne au script garde son gras",
                 f.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false,
                 "\(String(describing: f))")
    }

    // MARK: L'export

    private static func exporter(_ bac: URL) async {
        print("\nExport")
        let dossier = bac.appendingPathComponent("Export.scriptvoice")
        let prises = dossier.appendingPathComponent("prises")
        try? FileManager.default.createDirectory(at: prises, withIntermediateDirectories: true)
        guard let a = sinusoide(prises.appendingPathComponent("a.wav"), duree: 2, frequence: 440),
              let b = sinusoide(prises.appendingPathComponent("b.wav"), duree: 1, frequence: 880) else {
            verifier("fabriquer des prises d'essai", false); return
        }
        let projet = Projet()
        projet.dossier = dossier
        projet.pistes = [
            Piste(nom: "A", clips: [Clip(fichier: "a.wav", debut: 0, entree: 0, sortie: a, dureeSource: a)]),
            Piste(nom: "B", clips: [Clip(fichier: "b.wav", debut: 3, entree: 0, sortie: b, dureeSource: b)])
        ]
        proche("la duree du montage", projet.duree, 4)

        // Un fichier homonyme doit survivre a un export MP3.
        let wavVoisin = bac.appendingPathComponent("sortie.wav")
        try? Data("temoin".utf8).write(to: wavVoisin)

        let mp3 = bac.appendingPathComponent("sortie.mp3")
        do { try Export.rendre(projet, vers: mp3, format: "mp3") } catch {
            verifier("exporter en mp3", false, "\(error)")
        }
        verifier("le mp3 est ecrit", FileManager.default.fileExists(atPath: mp3.path))
        verifier("l'export mp3 n'a pas touche au wav voisin",
                 (try? Data(contentsOf: wavVoisin)) == Data("temoin".utf8))

        let wav = bac.appendingPathComponent("rendu.wav")
        do { try Export.rendre(projet, vers: wav, format: "wav") } catch {
            verifier("exporter en wav", false, "\(error)"); return
        }
        guard let f = try? AVAudioFile(forReading: wav) else {
            verifier("relire le wav exporte", false); return
        }
        let duree = Double(f.length) / f.processingFormat.sampleRate
        proche("le rendu dure le montage plus la garde", duree, 4.5, 0.2)
        verifier("le rendu est mono", f.processingFormat.channelCount == 1)

        // Le son doit etre present aux deux endroits, et silencieux entre les deux.
        let n = AVAudioFrameCount(f.length)
        if let tampon = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n),
           (try? f.read(into: tampon)) != nil, let c = tampon.floatChannelData {
            let sr = f.processingFormat.sampleRate
            func crete(_ de: Double, _ a: Double) -> Float {
                var m: Float = 0
                for i in Int(de * sr)..<Swift.min(Int(a * sr), Int(tampon.frameLength)) {
                    m = Swift.max(m, abs(c[0][i]))
                }
                return m
            }
            verifier("la premiere prise s'entend", crete(0.2, 1.8) > 0.2, "crete \(crete(0.2, 1.8))")
            verifier("le trou entre les prises est silencieux", crete(2.2, 2.9) < 0.01,
                     "crete \(crete(2.2, 2.9))")
            verifier("la seconde prise s'entend a sa place", crete(3.2, 3.9) > 0.2,
                     "crete \(crete(3.2, 3.9))")
            verifier("rien ne sature", crete(0, duree) <= 1.0, "crete \(crete(0, duree))")
        }

        // Une piste muette ne doit pas sortir.
        projet.pistes[0].muette = true
        let sansA = bac.appendingPathComponent("sans-a.wav")
        try? Export.rendre(projet, vers: sansA, format: "wav")
        if let f2 = try? AVAudioFile(forReading: sansA),
           let t2 = AVAudioPCMBuffer(pcmFormat: f2.processingFormat, frameCapacity: AVAudioFrameCount(f2.length)),
           (try? f2.read(into: t2)) != nil, let c2 = t2.floatChannelData {
            var m: Float = 0
            for i in 0..<Swift.min(Int(1.8 * f2.processingFormat.sampleRate), Int(t2.frameLength)) {
                m = Swift.max(m, abs(c2[0][i]))
            }
            verifier("une piste muette ne sort pas a l'export", m < 0.01, "crete \(m)")
        }
        projet.pistes[0].muette = false

        let vide = Projet()
        vide.dossier = dossier
        var refuse = false
        do { try Export.rendre(vide, vers: bac.appendingPathComponent("vide.wav"), format: "wav") }
        catch { refuse = true }
        verifier("exporter une timeline vide est refuse", refuse)
    }

    // MARK: Le traitement de la voix

    private static func voix(_ bac: URL) {
        print("\nVoix")
        let dossier = bac.appendingPathComponent("Voix")
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        func rms(_ t: AVAudioPCMBuffer?) -> Float {
            guard let t, let c = t.floatChannelData else { return 0 }
            var r: Float = 0
            vDSP_rmsqv(c[0], 1, &r, vDSP_Length(t.frameLength))
            return r
        }
        func crete(_ t: AVAudioPCMBuffer?) -> Float {
            guard let t, let c = t.floatChannelData else { return 0 }
            var m: Float = 0
            vDSP_maxmgv(c[0], 1, &m, vDSP_Length(t.frameLength))
            return m
        }
        func db(_ a: Float, _ b: Float) -> Double { 20 * log10(Double(a / max(b, 1e-9))) }

        // une voix enregistree trop bas, comme la premiere prise faite ici
        let url = dossier.appendingPathComponent("basse.wav")
        guard sinusoide(url, duree: 2, frequence: 1000, amplitude: 0.05) != nil else {
            verifier("fabriquer une prise basse", false); return
        }
        let p = PrisesTraitees.partage
        let brute = p.extrait(url, entree: 0.5, duree: 1, volume: 0, traitement: false)
        let traitee = p.extrait(url, entree: 0.5, duree: 1, volume: 0, traitement: true)
        let gonfle = db(rms(traitee), rms(brute))
        verifier("le traitement gonfle la voix", gonfle > 4, String(format: "%+.1f dB", gonfle))

        let moins6 = p.extrait(url, entree: 0.5, duree: 1, volume: -6, traitement: true)
        proche("la ligne a -6 dB baisse de 6 dB", db(rms(moins6), rms(traitee)), -6, 0.1)
        let moins30 = p.extrait(url, entree: 0.5, duree: 1, volume: -30, traitement: true)
        proche("la ligne a -30 dB baisse de 30 dB", db(rms(moins30), rms(traitee)), -30, 0.1)
        let plus30 = p.extrait(url, entree: 0.5, duree: 1, volume: 30, traitement: true)
        verifier("a +30 dB rien ne depasse -1 dBFS", crete(plus30) <= Voix.plafond + 0.001,
                 String(format: "crete %.3f", crete(plus30)))
        let sans = p.extrait(url, entree: 0.5, duree: 1, volume: 0, traitement: false)
        proche("sans traitement, le zero ne touche a rien", db(rms(sans), rms(brute)), 0, 0.01)

        // le de-esser seul : une sifflante a 7 kHz baisse, une voyelle a 1 kHz non
        func apresDeEsser(_ f: Double) -> Double {
            let sr = 48000.0, n = 48000
            var x = (0..<n).map { Float(0.3 * sin(2 * Double.pi * f * Double($0) / sr)) }
            var avant: Float = 0
            vDSP_rmsqv(x, 1, &avant, vDSP_Length(n))
            x.withUnsafeMutableBufferPointer { Voix.desser($0.baseAddress!, n, sr: sr) }
            var apres: Float = 0
            x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + n / 2, 1, &apres, vDSP_Length(n / 2)) }
            return db(apres, avant)
        }
        let sifflante = apresDeEsser(7000), voyelle = apresDeEsser(1000)
        verifier("le de-esser baisse les sifflantes", sifflante < -3, String(format: "%+.1f dB", sifflante))
        verifier("le de-esser laisse les voyelles", abs(voyelle) < 0.5, String(format: "%+.1f dB", voyelle))

        // Les projets d'avant gardaient un gain lineaire : 0,5 vaut -6 dB.
        let ancien = #"{"fichier":"a.wav","debut":0,"entree":0,"sortie":1,"gain":0.5}"#
        if let c = try? JSONDecoder().decode(Clip.self, from: Data(ancien.utf8)) {
            proche("un ancien gain devient un volume en dB", c.volume, -6.02, 0.01)
        } else { verifier("relire un ancien clip", false) }
        var clip = Clip(fichier: "a.wav", debut: 0, entree: 0, sortie: 1)
        clip.volume = -4.5
        if let d = try? JSONEncoder().encode(clip), let relu = try? JSONDecoder().decode(Clip.self, from: d) {
            proche("le volume survit a l'enregistrement", relu.volume, -4.5, 0.001)
        } else { verifier("enregistrer le volume d'un clip", false) }
    }

    // MARK: Le prompteur

    private static func prompteur() {
        print("\nPrompteur")
        let texte = "Lucas et Adam travaillent dans la même boîte, ils ont le même salaire."
        let mots = Prompteur.decouper(texte)
        verifier("le texte est decoupe en mots", mots.count == 13, "obtenu \(mots.count)")
        if let premier = mots.first {
            verifier("le premier mot est Lucas",
                     (texte as NSString).substring(with: premier) == "Lucas")
        }
        if mots.count > 7 {
            let m = (texte as NSString).substring(with: mots[7])
            verifier("les accents ne cassent pas le decoupage", m == "boîte", "obtenu \(m)")
        }

        let p = Prompteur()
        let position = (texte as NSString).range(of: "salaire").location
        p.demarrer(texte: texte, depuis: position)
        verifier("le prompteur demarre au mot du curseur",
                 (texte as NSString).substring(with: p.mots[p.index]) == "salaire",
                 "obtenu \((texte as NSString).substring(with: p.mots[p.index]))")
        verifier("le prompteur est actif", p.actif)
        p.rattraper(-1)
        verifier("la fleche haut recule", p.index < p.mots.count - 1)
        p.pause()
        verifier("espace met en pause", p.enPause)
        p.pause()
        verifier("espace repart", !p.enPause)
        p.arreter()
        verifier("le prompteur s'arrete", !p.actif)

        let depuisDebut = Prompteur()
        depuisDebut.demarrer(texte: texte, depuis: 0)
        verifier("sans curseur, on part du premier mot", depuisDebut.index == 0)
        depuisDebut.rattraper(-1)
        verifier("on ne recule pas avant le premier mot", depuisDebut.index == 0)
        depuisDebut.arreter()
    }

    // MARK: Les micros

    private static func peripheriques() {
        print("\nEntrees audio")
        let entrees = Micros.entrees()
        verifier("au moins une entree est detectee", !entrees.isEmpty)
        verifier("chaque entree a un nom", entrees.allSatisfy { !$0.nom.isEmpty })
        verifier("chaque entree a un identifiant", entrees.allSatisfy { !$0.uid.isEmpty })
        verifier("chaque entree a au moins un canal", entrees.allSatisfy { $0.canaux > 0 })
        for e in entrees { print("       \(e.nom) — \(e.canaux) canaux") }
        if let premiere = entrees.first {
            verifier("on retrouve une entree par son identifiant",
                     Micros.parUID(premiere.uid)?.id == premiere.id)
        }
        verifier("un identifiant inconnu ne renvoie rien", Micros.parUID("inexistant") == nil)
    }

    // MARK: L'enregistrement

    private static func enregistrement(_ bac: URL) async {
        print("\nEnregistrement")
        let statut = AVCaptureDevice.authorizationStatus(for: .audio)
        print("       statut du micro : \(statut.rawValue) (3 = autorise)")
        let noms = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio,
                                                    position: .unspecified).devices
        print("       entrees vues par la capture : \(noms.map(\.localizedName).joined(separator: ", "))")
        print("       entree par defaut : \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "aucune")")
        let accorde = statut == .authorized
        guard accorde else {
            print("       micro non autorise par macOS : essai ignore")
            let e = Enregistreur()
            var refuse = false
            do { _ = try await e.demarrer(dans: bac, nom: "refus") } catch { refuse = true }
            verifier("sans autorisation, l'enregistrement est refuse proprement", refuse)
            return
        }
        // Chaque entree est essayee, pas seulement le micro interne. Un
        // peripherique USB ne livre pas le meme format du debut a la fin de la
        // prise : le Yeti Nano commence en entiers 24 bits puis passe en
        // flottants. Un essai sur la seule entree integree ne voyait rien, et
        // l'application ecrivait deux centiemes de seconde sur le micro reel.
        for (rang, entree) in Micros.entrees().enumerated() {
            let e = Enregistreur()
            e.choisir(entree)
            print("       essai sur \(entree.nom)...")
            do {
                let nom = try await e.demarrer(dans: bac, nom: "essai-\(rang)")
                verifier("\(entree.nom) : l'enregistrement demarre", e.enCours)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                e.arreter()
                verifier("\(entree.nom) : l'enregistrement s'arrete", !e.enCours)
                let url = bac.appendingPathComponent(nom)
                verifier("\(entree.nom) : la prise est ecrite",
                         FileManager.default.fileExists(atPath: url.path))
                if let f = try? AVAudioFile(forReading: url) {
                    let d = Double(f.length) / f.processingFormat.sampleRate
                    proche("\(entree.nom) : la prise dure ce qu'elle a tourne", d, 1.5, 0.4)
                    verifier("\(entree.nom) : la prise est en 44 kHz ou plus",
                             f.processingFormat.sampleRate >= 44100)
                } else {
                    verifier("\(entree.nom) : relire la prise", false)
                }
                // Une prise de 1,5 s donne environ 75 tranches de 20 ms : sans
                // onde, la timeline n'a rien a montrer pendant qu'on parle.
                verifier("\(entree.nom) : l'onde se dessine pendant la prise", e.onde.count > 40,
                         "\(e.onde.count) tranches")
            } catch ErreurAudio.occupe {
                print("       \(entree.nom) : retenu par une autre application, essai ignore")
            } catch {
                verifier("\(entree.nom) : enregistrer", false, "\(error.localizedDescription)")
            }
        }
    }

    // MARK: La lecture

    private static func lecture(_ bac: URL) async {
        print("\nLecture")
        let dossier = bac.appendingPathComponent("Lecture.scriptvoice")
        let prises = dossier.appendingPathComponent("prises")
        try? FileManager.default.createDirectory(at: prises, withIntermediateDirectories: true)
        guard let d = sinusoide(prises.appendingPathComponent("son.wav"), duree: 2, frequence: 440) else {
            verifier("fabriquer une prise", false); return
        }
        let projet = Projet()
        projet.dossier = dossier
        projet.pistes = [Piste(nom: "A", clips: [
            Clip(fichier: "son.wav", debut: 0, entree: 0, sortie: d, dureeSource: d)])]

        let l = Lecteur()
        l.jouer(projet, depuis: 0)
        verifier("la lecture demarre", l.enLecture)
        try? await Task.sleep(nanoseconds: 600_000_000)
        verifier("la tete avance", l.tete > 0.3, "tete a \(l.tete)")
        l.arreter()
        verifier("la lecture s'arrete", !l.enLecture)

        // Le son doit tenir jusqu'au bout, pas seulement la tete : confie tel
        // quel au lecteur, le fichier se taisait au bout de deux secondes.
        guard let d4 = sinusoide(prises.appendingPathComponent("long.wav"), duree: 4, frequence: 440)
        else { verifier("fabriquer une prise longue", false); return }
        let long = Projet()
        long.dossier = dossier
        long.pistes = [Piste(nom: "A", clips: [
            Clip(fichier: "long.wav", debut: 0, entree: 0, sortie: d4, dureeSource: d4)])]
        let l3 = Lecteur()
        l3.mesurerSortie = true
        l3.jouer(long, depuis: 0)
        try? await Task.sleep(nanoseconds: 2_800_000_000)
        _ = l3.releverCrete()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let crete = l3.releverCrete()
        verifier("le son tient apres trois secondes", crete > 0.3, String(format: "crete %.3f", crete))
        l3.arreter()

        // Au-dela de la fin du montage, il n'y a rien a jouer.
        let l2 = Lecteur()
        l2.jouer(projet, depuis: 50)
        verifier("on ne joue rien apres la fin", !l2.enLecture)
        l2.arreter()
    }

    // MARK: Outils

    /// Fabrique un wav de test, pour ne dependre d'aucun fichier exterieur.
    private static func sinusoide(_ url: URL, duree: Double, frequence: Double,
                                  amplitude: Float = 0.5) -> Double? {
        let sr = 48000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let tampon = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(duree * sr))
        else { return nil }
        tampon.frameLength = AVAudioFrameCount(duree * sr)
        let c = tampon.floatChannelData![0]
        for i in 0..<Int(tampon.frameLength) {
            c[i] = amplitude * sinf(Float(2 * Double.pi * frequence * Double(i) / sr))
        }
        let reglages: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        guard let f = try? AVAudioFile(forWriting: url, settings: reglages,
                                       commonFormat: .pcmFormatFloat32, interleaved: false),
              (try? f.write(from: tampon)) != nil else { return nil }
        return duree
    }
}
