import PDFKit
import SwiftUI

/// Le support de voix off, pose a cote du script. PDFKit fait tout le travail :
/// defilement, zoom, recherche. On ne garde que les commandes utiles au micro.
/// PDFView calcule la disposition de ses pages au moment ou on lui donne un
/// document. Dans SwiftUI, la vue n'a pas encore de taille a cet instant : avec
/// un seul feuillet le resultat passe inapercu, mais un document de plusieurs
/// pages reste invisible. On redemande donc la mise en page des que la vue
/// recoit enfin ses dimensions.
final class VuePDF: PDFView {
    private var posee = false

    override func layout() {
        super.layout()
        guard !posee, document != nil, bounds.width > 50 else { return }
        posee = true
        autoScales = true
        layoutDocumentView()
        if let page = document?.page(at: 0) { go(to: page) }
    }

    func documentAChange() { posee = false; needsLayout = true }
}

struct VisionneusePDF: NSViewRepresentable {
    let chemin: String
    @Binding var zoom: Double

    func makeNSView(context: Context) -> VuePDF {
        let vue = VuePDF()
        vue.autoScales = true
        vue.displayMode = .singlePageContinuous
        vue.displayDirection = .vertical
        vue.backgroundColor = NSColor(white: 0.13, alpha: 1)
        context.coordinator.charger(chemin, dans: vue, zoom: zoom)
        return vue
    }

    func updateNSView(_ vue: VuePDF, context: Context) {
        context.coordinator.charger(chemin, dans: vue, zoom: zoom)
        if zoom > 0, abs(vue.scaleFactor - CGFloat(zoom)) > 0.01 {
            vue.autoScales = false
            vue.scaleFactor = CGFloat(zoom)
        }
    }

    func makeCoordinator() -> Coordinateur { Coordinateur() }

    /// Un document de plusieurs mega-octets met une seconde ou deux a s'ouvrir.
    /// Fait sur le fil principal, ce temps-la fige toute l'application : la
    /// lecture se fait donc a cote, et la vue recoit le document quand il est pret.
    @MainActor final class Coordinateur {
        private var charge = ""

        func charger(_ chemin: String, dans vue: VuePDF, zoom: Double) {
            guard chemin != charge else { return }
            charge = chemin
            guard !chemin.isEmpty else { vue.document = nil; return }
            let url = URL(fileURLWithPath: chemin)
            guard FileManager.default.fileExists(atPath: chemin) else {
                vue.document = nil; charge = ""; return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let doc = PDFDocument(url: url)
                DispatchQueue.main.async {
                    // On ne force jamais l'echelle ici : tant que la vue n'a pas
                    // sa taille definitive, `scaleFactorForSizeToFit` vaut zero,
                    // et la page devient invisible. `autoScales` s'en charge seul
                    // des que la vue est posee.
                    vue.document = doc
                    vue.documentAChange()
                    vue.needsDisplay = true
                }
            }
        }
    }
}

/// Fermer le support : un carre sombre pose sur le coin de la page, la croix
/// s'eclaire au survol. Fermer laisse la place a un autre PDF.
struct BoutonFermerPDF: View {
    let fermer: () -> Void
    @State private var survol = false

    var body: some View {
        Button(action: fermer) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(white: survol ? 0.95 : 0.7))
                .frame(width: 22, height: 22)
                .background(Color(white: 0.13).opacity(survol ? 0.95 : 0.8))
                .overlay(Rectangle().stroke(Color(white: survol ? 0.4 : 0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { survol = $0 }
        .help("Fermer le PDF")
    }
}

/// L'etat vide : sans PDF, la colonne dit quoi faire plutot que de rester noire.
struct PDFAbsent: View {
    let ouvrir: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Color(white: 0.4))
            Text("Aucun support ouvert")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.55))
            Button("Ouvrir un PDF", action: ouvrir)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(red: 0.41, green: 0.81, blue: 0.59))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.13))
    }
}
