import AppKit
import Foundation
import SwiftUI

/// Le journal de bord de l'application.
///
/// Tout ce qui compte y passe : les lancements, les ouvertures de projet, les
/// prises, les exports, et surtout les erreurs et les plantages. Le fichier vit
/// dans `~/Library/Logs/Script Voice/journal.txt` et survit aux redemarrages,
/// ce qui permet de savoir ce qui s'est passe meme quand l'application a disparu
/// sans rien dire.
///
/// Les plantages sont rattrapes au vol : un signal fatal ou une exception non
/// interceptee ecrit sa pile d'appels avant que le processus ne meure.
enum Journal {
    static let dossier: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Script Voice")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static let fichier = dossier.appendingPathComponent("journal.txt")

    private static let file = DispatchQueue(label: "fr.lfd.scriptvoice.journal")
    private static let horodatage: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    enum Niveau: String {
        case info = "   ", attention = " ! ", erreur = "!!!"
    }

    /// A appeler une fois au lancement : pose les gardes et ouvre une entree.
    static func demarrer() {
        tourner()
        poserLesGardes()
        let sys = ProcessInfo.processInfo.operatingSystemVersionString
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        ecrire("--- Script Voice \(version) demarre — macOS \(sys), \(architecture()) ---")
    }

    static func ecrire(_ message: String, _ niveau: Niveau = .info) {
        let ligne = "\(horodatage.string(from: Date())) \(niveau.rawValue) \(message)\n"
        file.async {
            guard let data = ligne.data(using: .utf8) else { return }
            if let tuyau = try? FileHandle(forWritingTo: fichier) {
                tuyau.seekToEndOfFile()
                tuyau.write(data)
                try? tuyau.close()
            } else {
                try? data.write(to: fichier)
            }
        }
    }

    static func attention(_ message: String) { ecrire(message, .attention) }

    static func erreur(_ message: String, _ e: Error? = nil) {
        if let e { ecrire("\(message) : \(e.localizedDescription)", .erreur) }
        else { ecrire(message, .erreur) }
    }

    /// Tout ce qu'il faut pour comprendre un probleme, en un seul bloc a coller.
    static func diagnostic() -> String {
        var t = "Script Voice — diagnostic\n"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        t += "version \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        t += "machine \(reglageMachine()), \(architecture())\n"
        t += "entrees audio :\n"
        for m in Micros.entrees() {
            t += "  \(m.nom) — \(m.canaux) canaux — \(m.uid)\n"
        }
        t += "\nDernieres lignes du journal :\n"
        t += dernieresLignes(80)
        return t
    }

    static func dernieresLignes(_ combien: Int) -> String {
        guard let contenu = try? String(contentsOf: fichier, encoding: .utf8) else {
            return "(journal vide)"
        }
        let lignes = contenu.split(separator: "\n", omittingEmptySubsequences: false)
        return lignes.suffix(combien).joined(separator: "\n")
    }

    static func vider() {
        try? FileManager.default.removeItem(at: fichier)
        ecrire("--- journal vide a la demande ---")
    }

    /// Le journal entier, diagnostic en tete, dans un fichier au nom parlant.
    /// Le fichier est mis dans le presse-papier, comme un fichier copie dans le
    /// Finder : Commande V dans WhatsApp, Messages ou Mail le joint tel quel.
    /// Celui qui teste n'a pas a chercher le dossier de la bibliotheque.
    static func envoyer(presse: NSPasteboard = .general) {
        let jour = DateFormatter()
        jour.dateFormat = "yyyy-MM-dd HH'h'mm"
        let nom = "Journal Script Voice \(Host.current().localizedName ?? "Mac") \(jour.string(from: Date())).txt"
        let bac = FileManager.default.temporaryDirectory.appendingPathComponent("Journal a envoyer")
        try? FileManager.default.removeItem(at: bac)
        try? FileManager.default.createDirectory(at: bac, withIntermediateDirectories: true)
        let sortie = bac.appendingPathComponent(nom)
        var texte = diagnostic().components(separatedBy: "\nDernieres lignes du journal :")[0]
        texte += "\nJournal complet :\n"
        texte += (try? String(contentsOf: fichier, encoding: .utf8)) ?? "(journal vide)"
        do {
            try texte.write(to: sortie, atomically: true, encoding: .utf8)
        } catch {
            erreur("journal non prepare pour l'envoi", error)
            return
        }
        presse.clearContents()
        let copie = presse.writeObjects([sortie as NSURL])
        let ko = max(1, texte.utf8.count / 1024)
        ecrire("journal pret a envoyer : \(nom), \(ko) Ko, presse-papier \(copie ? "oui" : "non")")

        guard let fenetre = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView?.premierTexte() != nil })
        else { NSWorkspace.shared.activateFileViewerSelecting([sortie]); return }
        let feuille = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        feuille.contentViewController = NSHostingController(rootView: VueJournalPret(
            nom: nom, ko: ko,
            finder: { NSWorkspace.shared.activateFileViewerSelecting([sortie]) },
            fermer: { [weak fenetre, weak feuille] in
                if let feuille { fenetre?.endSheet(feuille) }
            }))
        fenetre.beginSheet(feuille)
    }

    static func ouvrirDansLeFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fichier])
    }

    // MARK: Plantages

    /// Les signaux fatals et les exceptions ecrivent leur pile avant de mourir.
    private static func poserLesGardes() {
        NSSetUncaughtExceptionHandler { exception in
            let pile = exception.callStackSymbols.prefix(25).joined(separator: "\n    ")
            Journal.ecrireTouteSuite("PLANTAGE : \(exception.name.rawValue) — "
                                     + "\(exception.reason ?? "sans raison")\n    \(pile)")
        }
        for signal in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            Darwin.signal(signal) { numero in
                let pile = Thread.callStackSymbols.prefix(25).joined(separator: "\n    ")
                Journal.ecrireTouteSuite("PLANTAGE : signal \(numero)\n    \(pile)")
                Darwin.signal(numero, SIG_DFL)
                raise(numero)
            }
        }
    }

    /// Ecriture synchrone : pendant un plantage, la file asynchrone n'aurait pas
    /// le temps de vider sa reserve.
    static func ecrireTouteSuite(_ message: String) {
        let ligne = "\(horodatage.string(from: Date())) !!! \(message)\n"
        guard let data = ligne.data(using: .utf8) else { return }
        if let tuyau = try? FileHandle(forWritingTo: fichier) {
            tuyau.seekToEndOfFile(); tuyau.write(data); try? tuyau.close()
        } else {
            try? data.write(to: fichier)
        }
    }

    /// Au-dela d'un mega-octet, le journal repart a neuf et garde l'ancien.
    private static func tourner() {
        guard let taille = try? FileManager.default.attributesOfItem(atPath: fichier.path)[.size]
                as? Int, taille > 1_000_000 else { return }
        let ancien = dossier.appendingPathComponent("journal-precedent.txt")
        try? FileManager.default.removeItem(at: ancien)
        try? FileManager.default.moveItem(at: fichier, to: ancien)
    }

    /// « puce Apple (arm64) », « Intel (x86_64) » ou « Intel sous Rosetta »
    static func architecture() -> String {
        #if arch(arm64)
        return "puce Apple (arm64)"
        #else
        var traduit: Int32 = 0
        var taille = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &traduit, &taille, nil, 0) == 0, traduit == 1 {
            return "x86_64 sous Rosetta, sur puce Apple"
        }
        return "Intel (x86_64)"
        #endif
    }

    private static func reglageMachine() -> String {
        var taille = 0
        sysctlbyname("hw.model", nil, &taille, nil, 0)
        var modele = [CChar](repeating: 0, count: taille)
        sysctlbyname("hw.model", &modele, &taille, nil, 0)
        return String(cString: modele)
    }
}

/// La feuille qui suit Aide › Envoyer le journal. Meme dessin que celle de la
/// reprise : un surtitre vert, le nom du fichier, et le geste a faire derriere
/// un liseré, puisque c'est la seule chose a retenir.
struct VueJournalPret: View {
    let nom: String
    let ko: Int
    let finder: () -> Void
    let fermer: () -> Void

    private let vert = Color(red: 0.41, green: 0.81, blue: 0.59)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("JOURNAL PRÊT À ENVOYER")
                    .font(.system(size: 10, weight: .bold)).tracking(1.4)
                    .foregroundColor(vert)
                Text(nom)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(ko) Ko · copié dans le presse-papier")
                    .font(.system(size: 11)).foregroundColor(Color(white: 0.55))
            }

            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(vert).frame(width: 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ouvrez la conversation dans WhatsApp, Messages ou Mail, puis faites Commande V : le fichier se joint au message.")
                    Text("Ou glissez-le depuis le Finder.")
                        .foregroundColor(Color(white: 0.55))
                }
                .font(.system(size: 12))
                .foregroundColor(Color(white: 0.82))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Montrer dans le Finder", action: finder)
                Button("OK", action: fermer).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
        // fond plein : le fond translucide d'une feuille ne se dessine pas partout
        .background(Color(white: 0.13))
        .preferredColorScheme(.dark)
    }
}
