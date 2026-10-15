import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// Tout ce qui touche au son : la liste des micros, l'enregistrement, la lecture
/// du montage et l'export.
///
/// AVAudioEngine ne sait pas, seul, choisir un peripherique d'entree sur macOS :
/// il faut descendre dans CoreAudio et poser l'identifiant sur l'unite audio de
/// l'entree. C'est la seule facon de viser le Yeti plutot que le micro interne.

struct Peripherique: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let nom: String
    let canaux: Int
}

enum Micros {
    /// Les entrees disponibles, dans l'ordre ou le systeme les donne.
    static func entrees() -> [Peripherique] {
        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var taille: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &adresse, 0, nil, &taille) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(taille) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &adresse, 0, nil, &taille, &ids) == noErr else { return [] }

        return ids.compactMap { id -> Peripherique? in
            let canaux = nombreDeCanaux(id)
            guard canaux > 0 else { return nil }            // sans entree, ce n'est pas un micro
            guard let nom = chaine(id, kAudioObjectPropertyName),
                  let uid = chaine(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Peripherique(id: id, uid: uid, nom: Micros.nommer(nom, uid), canaux: canaux)
        }
    }

    static func parUID(_ uid: String) -> Peripherique? { entrees().first { $0.uid == uid } }

    /// Un micro peut se presenter deux fois, une par pilote installe : le nom seul
    /// ne permet alors pas de choisir. On ajoute donc l'origine entre parentheses.
    static func nommer(_ nom: String, _ uid: String) -> String {
        guard let pilote = uid.split(separator: ":").first, pilote.contains("Audio") else { return nom }
        if pilote.hasPrefix("AppleUSB") { return "\(nom) (USB)" }
        if pilote.hasPrefix("Logi")     { return "\(nom) (Logitech)" }
        if pilote.hasPrefix("BuiltIn")  { return nom }
        return "\(nom) (\(pilote))"
    }

    private static func nombreDeCanaux(_ id: AudioDeviceID) -> Int {
        var adresse = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var taille: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &adresse, 0, nil, &taille) == noErr, taille > 0
        else { return 0 }
        let liste = UnsafeMutableRawPointer.allocate(byteCount: Int(taille), alignment: 16)
        defer { liste.deallocate() }
        guard AudioObjectGetPropertyData(id, &adresse, 0, nil, &taille, liste) == noErr
        else { return 0 }
        let buffers = liste.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(buffers).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func chaine(_ id: AudioDeviceID, _ selecteur: AudioObjectPropertySelector) -> String? {
        var adresse = AudioObjectPropertyAddress(mSelector: selecteur,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var taille = UInt32(MemoryLayout<CFString?>.size)
        var valeur: CFString? = nil
        let ok = withUnsafeMutablePointer(to: &valeur) {
            AudioObjectGetPropertyData(id, &adresse, 0, nil, &taille, $0) == noErr
        }
        return ok ? valeur as String? : nil
    }
}

// MARK: - L'enregistreur

/// L'enregistreur.
///
/// Il passe par AVCaptureSession et non par AVAudioEngine. Sur cette machine,
/// lire `AVAudioEngine.inputNode` n'en revient jamais : l'appel attend une file
/// interne de CoreAudio, et fige le fil appelant — y compris en dehors du fil
/// principal. Le meme micro s'ouvre en vingt millisecondes avec une session de
/// capture, qui a en prime le bon gout de designer son peripherique directement,
/// sans toucher au reglage systeme.
///
/// La prise est ecrite en mono : une voix off n'a pas besoin de deux canaux, et
/// cela evite de doubler le poids des fichiers pour un signal identique.
@MainActor
final class Enregistreur: NSObject, ObservableObject {
    @Published var enCours = false
    @Published var niveau: Float = 0          // 0 a 1, pour le vumetre
    @Published var crete: Float = 0
    @Published var duree: Double = 0
    @Published var message: String?
    /// La prise telle qu'elle s'ecrit : une crete toutes les 20 ms, comme le
    /// cache des ondes, pour que la timeline montre le son pendant qu'il entre.
    @Published var onde: [Float] = []
    /// Ou se pose la prise en cours sur la timeline, et sur quelle piste.
    @Published var debutTimeline: Double = 0
    @Published var pisteTimeline = 0

    private nonisolated let session = AVCaptureSession()
    private nonisolated let sortie = AVCaptureAudioDataOutput()
    /// Deux files, et pas une seule : la session livre ses echantillons sur la
    /// file du delegue, et `startRunning()` attend cette premiere livraison. Les
    /// deux sur la meme file, et le demarrage s'attend lui-meme indefiniment.
    private nonisolated let pilotage = DispatchQueue(label: "fr.lfd.scriptvoice.audio.pilotage")
    private nonisolated let file = DispatchQueue(label: "fr.lfd.scriptvoice.audio.prises")

    // tout ce qui suit n'est touche que sur `file`
    private nonisolated(unsafe) var fichier: AVAudioFile?
    private nonisolated(unsafe) var destination: URL?
    private nonisolated(unsafe) var convertisseur: AVAudioConverter?
    private nonisolated(unsafe) var formatEntreeCourant: AVAudioFormat?
    private nonisolated(unsafe) var formatSortie: AVAudioFormat?
    private nonisolated(unsafe) var uidVoulu: String?
    private nonisolated(unsafe) var gainInterne: Float = 1.0
    // Compteurs de diagnostic : sans eux, une prise muette ne dit pas ou elle s'arrete.
    private nonisolated let verrouOnde = NSLock()
    private nonisolated(unsafe) var picsEnAttente: [Float] = []
    private nonisolated(unsafe) var creteTranche: Float = 0
    private nonisolated(unsafe) var framesTranche: Double = 0
    private nonisolated(unsafe) var recus = 0
    private nonisolated(unsafe) var ecrits = 0
    private nonisolated(unsafe) var rejets: [String: Int] = [:]

    private var debut: Date?
    private let battement = Battement()
    private let vigilance = Vigilance()

    var gain: Float {
        get { gainInterne }
        set { gainInterne = newValue }
    }

    override init() {
        super.init()
        sortie.setSampleBufferDelegate(self, queue: file)
    }

    static func demanderAcces() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var autorise: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func choisir(_ peripherique: Peripherique?) {
        let uid = peripherique?.uid
        pilotage.async { self.uidVoulu = uid }
    }

    /// Demarre une prise et renvoie le nom du fichier ecrit.
    func demarrer(dans dossier: URL, nom: String) async throws -> String {
        guard Enregistreur.autorise else { throw ErreurAudio.accesRefuse }
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        let fichierNom = "\(nom).wav"
        let url = dossier.appendingPathComponent(fichierNom)

        // Ouvrir une entree audio peut ne jamais repondre : il suffit qu'un pilote
        // tiers ou une autre application tienne le peripherique. On n'attend donc
        // pas indefiniment, on explique.
        let reponse = UneSeuleFois()
        try await withCheckedThrowingContinuation { (suite: CheckedContinuation<Void, Error>) in
            pilotage.async {
                do { try self.preparer(url); reponse.reprendre(suite, nil) }
                catch { reponse.reprendre(suite, error) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                reponse.reprendre(suite, ErreurAudio.occupe)
            }
        }
        debut = Date()
        enCours = true
        crete = 0
        onde = []
        vigilance.tenir("enregistrement en cours")
        battement.lancer(toutes: 0.05) { [weak self] in
            guard let self, let d = self.debut else { return }
            self.duree = Date().timeIntervalSince(d)
            let neufs = self.ramasserPics()
            if !neufs.isEmpty { self.onde.append(contentsOf: neufs) }
        }
        return fichierNom
    }

    func arreter() {
        battement.arreter()
        vigilance.relacher()
        enCours = false
        niveau = 0
        debut = nil
        pilotage.sync { self.session.stopRunning() }
        // Fermer le fichier sur la file du delegue : ailleurs, on le libere
        // pendant qu'une ecriture est en cours.
        file.sync {
            Journal.ecrire("bilan de la prise : \(self.recus) tampons recus, \(self.ecrits) ecrits"
                         + (self.rejets.isEmpty ? "" : ", rejets \(self.rejets)"))
            self.fichier = nil
            self.convertisseur = nil
            self.formatEntreeCourant = nil
            self.formatSortie = nil
            self.destination = nil
        }
    }

    // MARK: Sur la file audio uniquement

    private nonisolated func preparer(_ url: URL) throws {
        destination = url
        fichier = nil
        convertisseur = nil
        formatEntreeCourant = nil
        formatSortie = nil
        recus = 0; ecrits = 0; rejets = [:]
        verrouOnde.lock(); picsEnAttente = []; creteTranche = 0; framesTranche = 0; verrouOnde.unlock()

        session.beginConfiguration()
        for entree in session.inputs { session.removeInput(entree) }
        let appareil = peripheriqueVoulu()
        guard let appareil else { session.commitConfiguration(); throw ErreurAudio.pasDEntree }
        do {
            let entree = try AVCaptureDeviceInput(device: appareil)
            guard session.canAddInput(entree) else {
                session.commitConfiguration(); throw ErreurAudio.pasDEntree
            }
            session.addInput(entree)
        } catch {
            session.commitConfiguration()
            throw ErreurAudio.pasDEntree
        }
        if !session.outputs.contains(sortie) {
            guard session.canAddOutput(sortie) else {
                session.commitConfiguration(); throw ErreurAudio.pasDEntree
            }
            session.addOutput(sortie)
        }
        session.commitConfiguration()
        session.startRunning()
        guard session.isRunning else { throw ErreurAudio.pasDEntree }
        Journal.ecrire("session de capture lancee sur \(appareil.localizedName)")
    }

    /// Le micro choisi, ou l'entree par defaut du systeme a defaut.
    private nonisolated func peripheriqueVoulu() -> AVCaptureDevice? {
        let tous = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone],
                                                    mediaType: .audio,
                                                    position: .unspecified).devices
        if let uid = uidVoulu, let d = tous.first(where: { $0.uniqueID == uid }) { return d }
        return AVCaptureDevice.default(for: .audio) ?? tous.first
    }
}

extension Enregistreur: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        recus += 1
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let brut = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { rejeter("format"); return }
        var asbd = brut.pointee
        guard let formatEntree = AVAudioFormat(streamDescription: &asbd) else { rejeter("format"); return }
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard n > 0, let entree = AVAudioPCMBuffer(pcmFormat: formatEntree, frameCapacity: n)
        else { rejeter("tampon"); return }
        entree.frameLength = n
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer, at: 0, frameCount: Int32(n),
                into: entree.mutableAudioBufferList) == noErr else { rejeter("copie"); return }

        // Un seul canal, en virgule flottante. Le format de sortie est fige au
        // premier tampon : c'est lui qui donne son taux au fichier.
        if formatSortie == nil {
            formatSortie = AVAudioFormat(standardFormatWithSampleRate: formatEntree.sampleRate, channels: 1)
        }
        guard let mono = formatSortie else { rejeter("sortie"); return }

        // Un peripherique USB ne livre pas toujours le meme format du debut a la
        // fin : le Yeti Nano commence en mono puis passe en stereo au bout de
        // quelques dizaines de millisecondes. Un convertisseur batti une fois
        // pour toutes refuse alors tout le reste de la prise — paramErr, -50,
        // et un fichier de deux centiemes de seconde. On le refait a chaque
        // changement de format.
        if convertisseur == nil || formatEntreeCourant != formatEntree {
            guard let c = AVAudioConverter(from: formatEntree, to: mono) else {
                rejeter("convertisseur"); return
            }
            if let avant = formatEntreeCourant {
                Journal.ecrire("le micro a change de format en cours de prise : "
                             + "\(avant) devient \(formatEntree)")
            }
            formatEntreeCourant = formatEntree
            convertisseur = c
        }
        guard let conv = convertisseur else { rejeter("convertisseur"); return }

        // La capacite tient compte d'un reechantillonnage eventuel, et le bloc
        // d'entree est la seule forme de conversion qui le supporte.
        let capacite = AVAudioFrameCount(Double(n) * mono.sampleRate / formatEntree.sampleRate) + 32
        guard let tampon = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacite) else {
            rejeter("sortie"); return
        }
        var fourni = false
        var souci: NSError?
        conv.convert(to: tampon, error: &souci) { _, statut in
            if fourni { statut.pointee = .noDataNow; return nil }
            fourni = true
            statut.pointee = .haveData
            return entree
        }
        if let souci {
            if rejets["conversion"] == nil {
                Journal.attention("conversion refusee (\(formatEntree)) vers (\(mono)) : \(souci)")
            }
            rejeter("conversion"); return
        }
        guard tampon.frameLength > 0 else { rejeter("vide"); return }

        appliquerGain(tampon)
        accumuler(tampon, taux: mono.sampleRate)

        if fichier == nil, let url = destination {
            let reglages: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: mono.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            fichier = try? AVAudioFile(forWriting: url, settings: reglages,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        do { try fichier?.write(from: tampon); ecrits += 1 } catch { rejeter("ecriture") }

        let niveauMesure = Enregistreur.mesurer(tampon)
        Task { @MainActor in
            self.niveau = niveauMesure
            self.crete = max(self.crete * 0.92, niveauMesure)
        }
    }

    /// Reprend les cretes accumulees par la file audio depuis le dernier passage.
    private nonisolated func ramasserPics() -> [Float] {
        verrouOnde.lock()
        defer { picsEnAttente = []; verrouOnde.unlock() }
        return picsEnAttente
    }

    /// Accumule une tranche de 20 ms : le tampon audio en fait la moitie, et un
    /// pic par tampon donnerait une onde deux fois trop dense.
    private nonisolated func accumuler(_ buf: AVAudioPCMBuffer, taux: Double) {
        guard let canaux = buf.floatChannelData, buf.frameLength > 0 else { return }
        var m: Float = 0
        vDSP_maxmgv(canaux[0], 1, &m, vDSP_Length(buf.frameLength))
        verrouOnde.lock()
        creteTranche = max(creteTranche, m)
        framesTranche += Double(buf.frameLength)
        if framesTranche >= taux * 0.02 {
            picsEnAttente.append(creteTranche)
            creteTranche = 0
            framesTranche = 0
        }
        verrouOnde.unlock()
    }

    private nonisolated func rejeter(_ raison: String) {
        rejets[raison, default: 0] += 1
    }

    private nonisolated func appliquerGain(_ buf: AVAudioPCMBuffer) {
        var g = gainInterne
        guard g != 1.0, let canaux = buf.floatChannelData else { return }
        vDSP_vsmul(canaux[0], 1, &g, canaux[0], 1, vDSP_Length(buf.frameLength))
    }

    /// Niveau efficace du buffer, ramene entre 0 et 1 sur une echelle en decibels :
    /// une echelle lineaire ne montrerait presque rien dans le haut du vumetre.
    nonisolated static func mesurer(_ buf: AVAudioPCMBuffer) -> Float {
        guard let canaux = buf.floatChannelData, buf.frameLength > 0 else { return 0 }
        var somme: Float = 0
        vDSP_measqv(canaux[0], 1, &somme, vDSP_Length(buf.frameLength))
        let db = 10 * log10f(max(somme, 1e-9))
        return max(0, min(1, (db + 60) / 60))
    }
}

/// Garantit qu'une continuation n'est reprise qu'une fois, meme si la reponse
/// et le delai d'attente arrivent ensemble.
final class UneSeuleFois: @unchecked Sendable {
    private let verrou = NSLock()
    private var fait = false

    func reprendre(_ suite: CheckedContinuation<Void, Error>, _ erreur: Error?) {
        verrou.lock()
        defer { verrou.unlock() }
        guard !fait else { return }
        fait = true
        if let erreur { suite.resume(throwing: erreur) } else { suite.resume() }
    }
}

enum ErreurAudio: LocalizedError {
    case pasDEntree, fichierIllisible, accesRefuse, occupe
    var errorDescription: String? {
        switch self {
        case .pasDEntree:       return "Aucune entrée audio active. Vérifiez le micro choisi."
        case .fichierIllisible: return "Prise introuvable ou illisible."
        case .accesRefuse:
            return "macOS n'a pas encore autorisé le micro. Réglages Système, "
                 + "Confidentialité et sécurité, Microphone, puis cochez Script Voice."
        case .occupe:
            return "Le micro ne répond pas. Une autre application le retient, "
                 + "souvent un logiciel de montage avec sa fenêtre d'enregistrement ouverte, "
                 + "ou le pilote Logitech G HUB. Fermez-la et réessayez."
        }
    }
}