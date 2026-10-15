import Accelerate
import AVFoundation
import Foundation

/// Joue le montage. Chaque clip a son lecteur ; a chaque demarrage on replanifie
/// les clips qui tombent apres la tete de lecture.
///
/// Rien n'est pre-mixe : on peut donc couper un clip pendant la lecture et
/// relancer sans rien recalculer.
///
/// Les prises sont lues en memoire avant d'etre confiees aux lecteurs. Confier
/// directement le fichier (`scheduleSegment`) laisse le lecteur le lire lui-meme
/// au fil de l'eau, et sur cette machine il s'arrete au bout de deux secondes :
/// le moteur tourne, la tete avance, mais il ne sort plus que du silence. Mesure
/// avec un son de synthese, en 16 bits, 24 bits et flottants, hors de
/// l'application comme dedans.
@MainActor
final class Lecteur: ObservableObject {
    @Published var enLecture = false
    @Published var tete: Double = 0          // position en secondes

    private let moteur = AVAudioEngine()
    private var lecteurs: [AVAudioPlayerNode] = []
    private var depart: Double = 0           // tete au moment du demarrage
    private var horloge: Date?
    private var fin: Double = 0
    private let battement = Battement()
    private let vigilance = Vigilance()

    func jouer(_ projet: Projet, depuis t: Double) {
        arreter(gardantPosition: true)
        guard let dossier = projet.dossierPrises else { return }
        depart = t

        let solos = projet.pistes.contains { $0.solo }

        for piste in projet.pistes {
            if piste.muette || (solos && !piste.solo) { continue }
            for clip in piste.clips where clip.fin > t && clip.actif {
                // Si la tete tombe au milieu d'un clip, on entre dedans.
                let decalage = max(0, t - clip.debut)
                let duree = clip.duree - decalage
                guard duree > 0.01 else { continue }
                let url = dossier.appendingPathComponent(clip.fichier)
                guard let tampon = PrisesTraitees.partage.extrait(
                    url, entree: clip.entree + decalage, duree: duree,
                    volume: clip.volume, traitement: projet.reglages.voixJenaate && clip.voix,
                    fondus: .init(entree: clip.fonduEntree, sortie: clip.fonduSortie,
                                  depuis: decalage, total: clip.duree))
                else {
                    Journal.attention("lecture : prise illisible, \(clip.fichier)")
                    continue
                }
                let format = tampon.format
                let sr = format.sampleRate

                let lecteur = AVAudioPlayerNode()
                moteur.attach(lecteur)
                moteur.connect(lecteur, to: moteur.mainMixerNode, format: format)
                let quand = max(0, clip.debut - t)
                lecteur.scheduleBuffer(tampon,
                                       at: AVAudioTime(sampleTime: AVAudioFramePosition(quand * sr),
                                                       atRate: sr))
                lecteurs.append(lecteur)
            }
        }

        guard !lecteurs.isEmpty else { return }
        fin = projet.duree
        do {
            if mesurerSortie {
                let melangeur = moteur.mainMixerNode
                melangeur.removeTap(onBus: 0)
                melangeur.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] b, _ in
                    guard let self, let c = b.floatChannelData else { return }
                    var m: Float = 0
                    vDSP_maxmgv(c[0], 1, &m, vDSP_Length(b.frameLength))
                    self.crete = max(self.crete, m)
                }
            }
            moteur.prepare()
            try moteur.start()
            // Tous les lecteurs partent au meme instant, un peu dans le futur :
            // demarres l'un apres l'autre, les pistes se decaleraient.
            let top = AVAudioTime(hostTime: mach_absolute_time()
                                  + AVAudioTime.hostTime(forSeconds: 0.05))
            lecteurs.forEach { $0.play(at: top) }
            horloge = Date().addingTimeInterval(0.05)
            enLecture = true
            suivreLaTete()
        } catch {
            Journal.erreur("lecture : le moteur audio refuse de demarrer", error)
            arreter()
        }
    }

    /// Ce que le son a reellement joue, d'apres le premier lecteur : sert au
    /// diagnostic, pour distinguer une tete qui avance d'un son qui s'est tu.
    var positionAudio: Double? {
        guard let l = lecteurs.first, let rendu = l.lastRenderTime,
              let t = l.playerTime(forNodeTime: rendu) else { return nil }
        return Double(t.sampleTime) / t.sampleRate
    }

    var moteurEnMarche: Bool { moteur.isRunning }

    /// Niveau crete de ce qui sort du melangeur depuis la derniere lecture de
    /// cette valeur. Mesure seulement pendant un essai de lecture.
    nonisolated(unsafe) private var crete: Float = 0
    var mesurerSortie = false
    func releverCrete() -> Float { let c = crete; crete = 0; return c }

    func arreter(gardantPosition: Bool = false) {
        battement.arreter()
        vigilance.relacher()
        lecteurs.forEach { $0.stop(); moteur.detach($0) }
        lecteurs.removeAll()
        moteur.stop()
        horloge = nil
        enLecture = false
    }

    /// La tete suit une horloge, pas un lecteur : une piste sans clip a cet
    /// instant ne renvoie aucun temps, et la tete resterait figee.
    private func suivreLaTete() {
        vigilance.tenir("lecture du montage")
        battement.lancer(toutes: 1.0 / 30) { [weak self] in
            guard let self, let debut = self.horloge else { return }
            let t = self.depart + max(0, Date().timeIntervalSince(debut))
            self.tete = t
            if t >= self.fin + 0.15 {              // le montage est fini
                self.arreter()
                self.tete = self.fin
            }
        }
    }
}

// MARK: - Export

enum Export {
    /// Melange la timeline dans un seul fichier. On additionne echantillon par
    /// echantillon : c'est une voix off, il n'y a pas d'effets a appliquer, et
    /// ca evite de dependre du moteur temps reel pour un rendu hors ligne.
    static func rendre(_ projet: Projet, vers url: URL, format: String) throws {
        guard let dossier = projet.dossierPrises, projet.duree > 0 else {
            throw ErreurAudio.fichierIllisible
        }
        // On reste a la frequence des prises : rechantillonner une voix off pour
        // rien introduirait de l'aliasing sans aucun benefice.
        var sr = 48000.0
        if let premier = projet.pistes.flatMap(\.clips).first,
           let f = try? AVAudioFile(forReading: dossier.appendingPathComponent(premier.fichier)) {
            sr = f.processingFormat.sampleRate
        }
        let total = AVAudioFrameCount((projet.duree + 0.5) * sr)
        guard let sortie = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let melange = AVAudioPCMBuffer(pcmFormat: sortie, frameCapacity: total)
        else { throw ErreurAudio.fichierIllisible }
        melange.frameLength = total
        let dest = melange.floatChannelData![0]
        memset(dest, 0, Int(total) * MemoryLayout<Float>.size)

        let solos = projet.pistes.contains { $0.solo }
        for piste in projet.pistes {
            if piste.muette || (solos && !piste.solo) { continue }
            for clip in piste.clips where clip.actif {
                guard let tampon = PrisesTraitees.partage.extrait(
                    dossier.appendingPathComponent(clip.fichier), entree: clip.entree,
                    duree: clip.duree, volume: clip.volume,
                    traitement: projet.reglages.voixJenaate && clip.voix,
                    fondus: .init(entree: clip.fonduEntree, sortie: clip.fonduSortie,
                                  depuis: 0, total: clip.duree))
                else { continue }
                let srSource = tampon.format.sampleRate

                // ramene en mono a la frequence de sortie, au plus simple
                guard let source = tampon.floatChannelData else { continue }
                let canaux = Int(tampon.format.channelCount)
                let ratio = srSource / sr
                let depuis = Int(clip.debut * sr)
                let n = Int(Double(tampon.frameLength) / ratio)
                for i in 0..<n {
                    let j = Int(Double(i) * ratio)
                    guard j < Int(tampon.frameLength), depuis + i < Int(total) else { break }
                    var v: Float = 0
                    for c in 0..<canaux { v += source[c][j] }
                    dest[depuis + i] += v / Float(canaux)
                }
            }
        }

        // ecretage doux : un depassement sur une addition de prises est vite arrive
        var max: Float = 0
        vDSP_maxmgv(dest, 1, &max, vDSP_Length(total))
        if max > 1 {
            var facteur = 0.98 / max
            vDSP_vsmul(dest, 1, &facteur, dest, 1, vDSP_Length(total))
        }

        // L'intermediaire va dans un dossier temporaire : ecrire a cote de la
        // cible ecraserait, puis effacerait, un export precedent du meme nom.
        let wav = format == "wav"
            ? url
            : FileManager.default.temporaryDirectory
                .appendingPathComponent("scriptvoice-\(UUID().uuidString).wav")
        let reglages: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let fichier = try AVAudioFile(forWriting: wav, settings: reglages,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        try fichier.write(from: melange)

        if format != "wav" { try convertir(wav, vers: url, format: format) }
    }

    /// MP3 et M4A passent par les outils deja presents sur la machine.
    private static func convertir(_ source: URL, vers url: URL, format: String) throws {
        let outils = ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let ffmpeg = outils.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return }                       // sans ffmpeg, le wav reste, et c'est deja utilisable
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        var args = ["-y", "-i", source.path]
        if format == "mp3" { args += ["-codec:a", "libmp3lame", "-b:a", "192k"] }
        else               { args += ["-codec:a", "aac", "-b:a", "256k"] }
        args.append(url.path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if source != url { try? FileManager.default.removeItem(at: source) }
    }
}
