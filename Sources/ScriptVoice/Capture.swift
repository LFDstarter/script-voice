import AppKit
import SwiftUI

/// Mode de controle visuel : `ScriptVoice --capture /chemin/image.png`.
///
/// macOS refuse a un script de photographier une fenetre sans autorisation
/// d'enregistrement d'ecran. L'application, elle, a toujours le droit de se
/// dessiner elle-meme : c'est ainsi qu'on relit une mise en page sans rien
/// demander au systeme.
enum Capture {
    static var demandee: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var delai: Double {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture"), i + 2 < args.count,
              let d = Double(args[i + 2]) else { return 2.5 }
        return d
    }

    /// Essaie jusqu'a ce qu'une fenetre existe : selon la machine, SwiftUI met
    /// plus ou moins de temps a monter la premiere vue.
    static func programmer(_ chemin: String, apres delai: Double = Capture.delai) {
        // On attend d'abord le delai demande — c'est tout l'interet : photographier
        // l'application en cours de fonctionnement, et non a la seconde ou sa
        // fenetre apparait.
        DispatchQueue.main.asyncAfter(deadline: .now() + delai) {
            essayer(chemin, reste: 20)
        }
    }

    /// Les palettes flottantes et les feuilles (les reglages) sont des fenetres
    /// a part : sans ce report, une capture montre l'application sans l'outil
    /// qu'on veut justement verifier.
    private static func composerLesPanneaux(de fenetre: NSWindow, sur rep: NSBitmapImageRep) {
        let enfants = (fenetre.childWindows ?? []) + [fenetre.attachedSheet].compactMap { $0 }
        guard !enfants.isEmpty,
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        for enfant in enfants where enfant.isVisible {
            guard let vue = enfant.contentView,
                  let r = vue.bitmapImageRepForCachingDisplay(in: vue.bounds) else { continue }
            vue.cacheDisplay(in: vue.bounds, to: r)
            let cadre = enfant.frame
            let dans = fenetre.convertPoint(fromScreen: cadre.origin)
            r.draw(in: NSRect(x: dans.x, y: dans.y, width: cadre.width, height: cadre.height))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func essayer(_ chemin: String, reste: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                let fenetres = NSApp.windows.filter { $0.isVisible }
                // la plus grande : une feuille ouverte est elle aussi une fenetre
                if let fenetre = fenetres.filter({ $0.sheetParent == nil })
                    .max(by: { $0.frame.width < $1.frame.width }),
                   fenetre.frame.width > 200,
                   let vue = fenetre.contentView,
                   let rep = vue.bitmapImageRepForCachingDisplay(in: vue.bounds) {
                    vue.cacheDisplay(in: vue.bounds, to: rep)
                    composerLesPanneaux(de: fenetre, sur: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: chemin))
                        Journal.ecrire("capture ecrite : \((chemin as NSString).lastPathComponent)")
                        // une feuille ouverte refuserait la fermeture
                        if let f = fenetre.attachedSheet { fenetre.endSheet(f) }
                        NSApp.terminate(nil)
                        // si une feuille SwiftUI retient encore l'application,
                        // une instance d'essai ne doit pas rester en vie
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
                        return
                    }
                }
                if reste <= 0 { NSApp.terminate(nil) } else { essayer(chemin, reste: reste - 1) }
            }
        }
    }
}
