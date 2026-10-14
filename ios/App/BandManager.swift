import CoreBluetooth
import Fit3Kit
import Foundation

struct DiscoveredBand: Identifiable {
    let id: UUID
    let name: String
    var rssi: Int
    let peripheral: CBPeripheral
}

enum BandPhase: Equatable {
    case bluetoothOff, unauthorized, noBand, scanning, connecting, discovering, handshake, settingUp, ready

    var label: String {
        switch self {
        case .bluetoothOff: return "Bluetooth desligado"
        case .unauthorized: return "Sem permissão de Bluetooth"
        case .noBand: return "Nenhuma pulseira escolhida"
        case .scanning: return "Procurando…"
        case .connecting: return "Aguardando a pulseira…"
        case .discovering: return "Conectando…"
        case .handshake: return "Handshake…"
        case .settingUp: return "Configurando…"
        case .ready: return "Conectada"
        }
    }
}

/// Dona da conexão CoreBluetooth; fala o protocolo SAP da Samsung com a Galaxy Fit3.
/// Tudo roda na fila principal (delegate do CoreBluetooth com `queue: nil`).
final class BandManager: NSObject, ObservableObject {
    static let shared = BandManager()

    @Published private(set) var phase: BandPhase = .bluetoothOff
    @Published private(set) var discovered: [DiscoveredBand] = []
    @Published private(set) var bandName: String?
    @Published private(set) var firmware: String?
    @Published private(set) var battery: BandSettings.Battery?

    var isReady: Bool { phase == .ready }
    var hasBand: Bool { savedId != nil }

    private let log = Logbook.shared
    private let defaults = UserDefaults.standard
    private let serviceUUID = CBUUID(string: BandUUID.service)
    private let notifyUUID = CBUUID(string: BandUUID.notify)
    private let writeUUID = CBUUID(string: BandUUID.write)

    private lazy var central = CBCentralManager(delegate: self, queue: nil, options: [
        CBCentralManagerOptionRestoreIdentifierKey: "Fit3LinkCentral",
        CBCentralManagerOptionShowPowerAlertKey: true,
    ])

    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var outbox: [Data] = []
    private var writeBusy = false

    private let reassembler = SapReassembler()
    private var transportMtu = 0
    private var sapReady = false
    private var assumedSession = false
    private var setupStep = 0
    private var subscribeAttempts = 0
    private var ringing = false
    /// Invalida temporizadores antigos a cada nova conexão.
    private var generation = 0
    /// Mensagens enviadas enquanto a pulseira estava desconectada.
    private var pending: [(Agent, [UInt8])] = []
    /// O que a pulseira já sabe sobre a música (evita reenviar sem mudança).
    private var announcedMusicApp: String?
    private var lastMusicIdentity: String?
    private var lastPlayback: BandMedia.Playback?
    /// Saúde e clima a cada 30 min enquanto o app estiver ativo.
    private var periodic: Timer?

    private var savedId: UUID? {
        get { defaults.string(forKey: "band.id").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "band.id") }
    }

    /// MTU de transporte da última sessão. Se o iOS restaurar o app com o link ainda ativo,
    /// a pulseira não repete o handshake e reaproveitamos este valor.
    private var storedMtu: Int {
        get { defaults.integer(forKey: "band.transportMtu") }
        set { defaults.set(newValue, forKey: "band.transportMtu") }
    }

    override init() {
        super.init()
        bandName = defaults.string(forKey: "band.name")
        MusicBridge.shared.onChange = { [weak self] in self?.syncMusic() }
        HealthSync.shared.send = { [weak self] agent, message in
            self?.send(agent, message, queueIfOffline: false)
        }
        _ = central
    }

    // MARK: - API pública

    func startScan() {
        guard central.state == .poweredOn else { return }
        discovered = []
        // Pulseira já conectada ao iPhone (pelo sistema) não anuncia: busca direto.
        for p in central.retrieveConnectedPeripherals(withServices: [serviceUUID]) {
            discovered.append(DiscoveredBand(id: p.identifier, name: p.name ?? "Galaxy Fit3", rssi: 0, peripheral: p))
        }
        central.scanForPeripherals(withServices: nil, options: nil)
        if phase == .noBand { phase = .scanning }
        log.add("Procurando pulseiras…")
    }

    func stopScan() {
        if central.isScanning { central.stopScan() }
        if phase == .scanning { phase = peripheral == nil ? .noBand : .connecting }
    }

    func choose(_ band: DiscoveredBand) {
        stopScan()
        disconnect()
        savedId = band.id
        storedMtu = 0
        bandName = band.name
        defaults.set(band.name, forKey: "band.name")
        connect(band.peripheral)
    }

    func forget() {
        disconnect()
        savedId = nil
        storedMtu = 0
        bandName = nil
        firmware = nil
        battery = nil
        pending = []
        defaults.removeObject(forKey: "band.name")
        phase = central.state == .poweredOn ? .noBand : .bluetoothOff
        log.add("Pulseira esquecida")
    }

    /// Derruba o link e conecta de novo, forçando um handshake novo.
    func reconnect() {
        guard let p = peripheral ?? savedPeripheral() else { return }
        storedMtu = 0
        if p.state == .disconnected {
            connect(p)
        } else {
            peripheral = p
            central.cancelPeripheralConnection(p) // didDisconnect reconecta
        }
    }

    @discardableResult
    func sendNotification(title: String, body: String, app: ForwardedApp = .test) -> Bool {
        let message = BandNotification.new(sequence: nextSequence(), title: title, body: body,
                                           appName: app.displayName, package: app.package,
                                           appId: app.appId, category: app.category)
        return send(.notification, message)
    }

    func syncTime() {
        send(.oobe, Oobe.initSettings(localeId: BandLocale.current))
    }

    func refreshBattery() {
        send(.fullSettings, BandSettings.batteryRequest)
    }

    /// Faz a pulseira tocar com a tela de chamada (agente de chamadas da Samsung, serviço 3).
    func startRinging(name: String, number: String) {
        ringing = true
        send(.call, BandCall.enableNotification(), queueIfOffline: false)
        send(.call, BandCall.contact(name: name, number: number), queueIfOffline: false)
        send(.call, BandCall.state(.ringing), queueIfOffline: false)
    }

    func callAnswered() {
        ringing = false
        send(.call, BandCall.state(.offhook), queueIfOffline: false)
    }

    func callEnded(missed: Bool, name: String, number: String) {
        ringing = false
        send(.call, BandCall.state(.idle), queueIfOffline: false)
        guard missed else { return }
        let date = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.send(.call, BandCall.missed(name: name, number: number, date: date))
        }
    }

    /// Usado pelo atalho (App Intent): o iOS pode ter acabado de abrir o app em segundo plano.
    @MainActor
    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isReady && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isReady
    }

    // MARK: - Envio

    @discardableResult
    func send(_ agent: Agent, _ message: [UInt8], queueIfOffline: Bool = true) -> Bool {
        guard sapReady, let p = peripheral, p.state == .connected else {
            if queueIfOffline {
                pending.append((agent, message))
                if pending.count > 20 { pending.removeFirst(pending.count - 20) }
                log.add("Na fila até reconectar: \(Agent.name(agent.rawValue))")
            }
            return false
        }
        let maxFrame = min(transportMtu, p.maximumWriteValueLength(for: writeType))
        do {
            let frames = try Sap.encode(service: agent.rawValue, message: message, mtu: transportMtu,
                                        maxFrame: maxFrame)
            log.add("→ \(Agent.name(agent.rawValue)) \(message.hex)")
            outbox += frames.map { Data($0) }
            pump()
            return true
        } catch {
            log.add("⚠️ Falha ao codificar: \(error)")
            return false
        }
    }

    private func pump() {
        guard let p = peripheral, let c = writeChar, !writeBusy else { return }
        if writeType == .withoutResponse {
            while !outbox.isEmpty && p.canSendWriteWithoutResponse {
                p.writeValue(outbox.removeFirst(), for: c, type: .withoutResponse)
            }
        } else if !outbox.isEmpty {
            writeBusy = true
            p.writeValue(outbox.removeFirst(), for: c, type: .withResponse)
        }
    }

    private func nextSequence() -> Int32 {
        var seq = defaults.integer(forKey: "notify.seq") + 1
        if seq <= 0 || seq >= Int(Int32.max) { seq = 1 }
        defaults.set(seq, forKey: "notify.seq")
        return Int32(seq)
    }

    // MARK: - Conexão

    private func savedPeripheral() -> CBPeripheral? {
        guard let id = savedId else { return nil }
        return central.retrievePeripherals(withIdentifiers: [id]).first
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        phase = .connecting
        log.add("Conectando a \(p.name ?? "pulseira")…")
        central.connect(p, options: nil) // sem timeout: completa quando a pulseira estiver ao alcance
    }

    private func disconnect() {
        guard let p = peripheral else { return }
        peripheral = nil
        resetSession()
        central.cancelPeripheralConnection(p)
    }

    private func resetSession() {
        generation += 1
        sapReady = false
        assumedSession = false
        transportMtu = 0
        setupStep = 0
        subscribeAttempts = 0
        outbox = []
        writeBusy = false
        writeChar = nil
        reassembler.reset()
        announcedMusicApp = nil
        lastMusicIdentity = nil
        lastPlayback = nil
        periodic?.invalidate()
        periodic = nil
        HealthSync.shared.reset()
    }

    private func after(_ seconds: Double, _ body: @escaping () -> Void) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == gen else { return }
            body()
        }
    }

    // MARK: - Sessão SAP

    private func handleIncoming(_ bytes: [UInt8]) {
        if Sap.isCapabilityRequest(bytes) {
            handleCapability(bytes)
            return
        }
        let fragment: Sap.Fragment
        do {
            fragment = try Sap.decode(bytes)
        } catch {
            log.add("← quadro inválido (\(error)): \(bytes.hex)")
            return
        }
        guard let msg = reassembler.push(fragment) else { return }
        log.add("← \(Agent.name(msg.service)) \(msg.message.hex)")
        handleMessage(service: msg.service, msg.message)
    }

    private func handleCapability(_ request: [UInt8]) {
        do {
            let reply = try Sap.capabilityReply(request)
            transportMtu = Sap.transportMtu(request)
            storedMtu = transportMtu
            log.add("Handshake recebido (MTU de transporte \(transportMtu))")
            reassembler.reset()
            outbox.append(Data(reply)) // resposta crua, fora de quadro SAP
            pump()
            sapReady = true
            assumedSession = false
            startSetup()
        } catch {
            log.add("⚠️ Handshake inválido: \(error)")
        }
    }

    private func assumeExistingSession() {
        guard !sapReady else { return }
        transportMtu = storedMtu
        sapReady = true
        assumedSession = true
        log.add("Reaproveitando a sessão existente (MTU \(transportMtu))")
        startSetup()
    }

    /// Sequência OOBE do plugin oficial, feita a cada conexão (também acerta hora e idioma).
    private func startSetup() {
        phase = .settingUp
        setupStep = 1
        runSetupStep()
    }

    private func runSetupStep() {
        let step = setupStep
        switch step {
        case 1: send(.oobe, Oobe.watchInfo)
        case 2: send(.oobe, Oobe.deviceStatus)
        case 3: send(.oobe, Oobe.initSettings(localeId: BandLocale.current))
        case 4: send(.oobe, Oobe.userAgreement)
        default:
            finishSetup()
            return
        }
        after(5) { [weak self] in
            guard let self, self.setupStep == step else { return }
            if step == 1 && self.assumedSession {
                self.log.add("A sessão antiga não respondeu; refazendo a conexão")
                self.reconnect()
                return
            }
            self.log.add("Sem resposta na etapa \(step) da configuração; seguindo")
            self.setupStep += 1
            self.runSetupStep()
        }
    }

    private func finishSetup() {
        setupStep = 0
        phase = .ready
        log.add("Pulseira pronta ✅")
        send(.notification, BandNotification.iconCapabilityRequest)
        send(.call, BandCall.enableNotification())
        send(.fullSettings, BandSettings.batteryRequest)
        syncMusic()
        HealthSync.shared.connected()
        after(1) { [weak self] in self?.sendWeather(force: false) }
        periodic = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            guard let self, self.isReady else { return }
            HealthSync.shared.requestSync()
            self.sendWeather(force: false)
        }
        let queued = pending
        pending = []
        for (agent, message) in queued { send(agent, message) }
    }

    // MARK: - Clima (serviço 5)

    /// Envia a previsão (do cache se tiver menos de 30 min, ou busca uma nova).
    func sendWeather(force: Bool) {
        let weather = WeatherService.shared
        guard weather.enabled else { return }
        Task { @MainActor [weak self] in
            guard let forecast = await weather.current(maxAge: force ? 0 : 30 * 60) else { return }
            self?.send(.weather, BandWeather.response(forecast), queueIfOffline: false)
        }
    }

    private func handleMessage(service: Int, _ m: [UInt8]) {
        switch Agent(rawValue: service) {
        case .oobe?:
            guard let id = Oobe.responseId(m) else { break }
            if id == 1, let fw = Oobe.firmware(in: m) { firmware = fw }
            if id == setupStep {
                setupStep += 1
                runSetupStep()
            }
        case .fullSettings?:
            if let b = BandSettings.parseBattery(m) { battery = b }
        case .notification?:
            if let ack = BandNotification.parseAck(m) {
                log.add(ack.accepted ? "Notificação \(ack.sequence) exibida"
                                     : "A pulseira recusou a notificação \(ack.sequence)")
            }
        case .call?:
            if let action = BandCall.parseBandAction(m) { handleCallAction(action) }
        case .media?:
            handleMedia(m)
        case .health?:
            HealthSync.shared.handle(m)
        case .weather?:
            if let kind = BandWeather.requestKind(m) { sendWeather(force: kind == 1) }
        default:
            break
        }
    }

    // MARK: - Música (serviço 9)

    /// Mantém a pulseira em dia com o Apple Music sem precisar reabrir a tela de música.
    func syncMusic() {
        guard isReady else { return }
        let music = MusicBridge.shared
        let appId = music.activeAppId
        if appId != announcedMusicApp {
            announcedMusicApp = appId
            send(.media, BandMedia.appCount(appId: appId), queueIfOffline: false)
        }
        let s = music.snapshot
        if s.identity != lastMusicIdentity {
            sendMusicMetadata(s)
            sendPlaybackState(s)
        } else if s.playback != lastPlayback {
            sendPlaybackState(s)
        }
    }

    private func handleMedia(_ m: [UInt8]) {
        let music = MusicBridge.shared
        if let remote = BandMedia.parseRemote(m) {
            // Um toque gera "solto" e "pressionado"; agir nos dois pularia duas faixas.
            guard remote.pressed else { return }
            log.add("Música: botão \(remote.action)")
            if !music.handle(remote.action) {
                log.add("Música: Apple Music indisponível (permissão negada ou desativado)")
            }
            // O Apple Music leva um instante para mudar de faixa/estado.
            let skipped = remote.action == .next || remote.action == .previous
            for delay in [0.3, 1.0] {
                after(delay) { [weak self] in
                    guard let self else { return }
                    let s = music.snapshot
                    if skipped { self.sendMusicMetadata(s) }
                    self.sendPlaybackState(s)
                }
            }
            return
        }
        if let volume = BandMedia.parseVolume(m) {
            music.handle(volume)
            after(0.3) { [weak self] in self?.sendVolumeInfo() }
            return
        }
        switch BandMedia.request(m) {
        case .mediaChanged?:
            send(.media, BandMedia.mediaChanged(screenState: BandMedia.screenState(m) ?? 1), queueIfOffline: false)
            syncMusic()
        case .metadata?:
            sendMusicMetadata(music.snapshot)
        case .playbackState?:
            sendPlaybackState(music.snapshot)
        case .capability?:
            send(.media, BandMedia.capability(maxVolume: MusicBridge.maxVolume,
                                              warningVolume: MusicBridge.maxVolume * 2 / 3), queueIfOffline: false)
        case .volumeInfo?:
            sendVolumeInfo()
        case .appInfo?:
            if let id = BandMedia.requestedAppId(m), !id.isEmpty, id == music.activeAppId {
                send(.media, BandMedia.appInfo(appId: id, title: MusicBridge.appTitle), queueIfOffline: false)
            }
        case .queue?:
            // O iOS não expõe a fila do Apple Music para outros apps: responde com fila vazia.
            if let id = BandMedia.requestedAppId(m), !id.isEmpty, id == music.activeAppId {
                send(.media, BandMedia.emptyQueue(appId: id, title: MusicBridge.appTitle), queueIfOffline: false)
            }
        default:
            break
        }
    }

    private func sendMusicMetadata(_ s: MusicBridge.Snapshot) {
        lastMusicIdentity = s.identity
        send(.media, BandMedia.metadata(title: s.title, artist: s.artist, durationMs: s.durationMs,
                                        appId: MusicBridge.shared.activeAppId), queueIfOffline: false)
    }

    private func sendPlaybackState(_ s: MusicBridge.Snapshot) {
        lastPlayback = s.playback
        send(.media, BandMedia.playbackState(s.playback, positionMs: s.positionMs,
                                             appId: MusicBridge.shared.activeAppId), queueIfOffline: false)
    }

    private func sendVolumeInfo() {
        let music = MusicBridge.shared
        send(.media, BandMedia.volumeInfo(music.volume, headset: music.headsetConnected), queueIfOffline: false)
    }

    private func handleCallAction(_ action: BandCall.BandAction) {
        switch action {
        case .silence, .reject, .rejectWithMessage:
            // O iOS não deixa apps silenciarem ou recusarem chamadas; só paramos a pulseira.
            log.add("Pulseira pediu para silenciar/recusar; parando de vibrar")
            if ringing {
                ringing = false
                send(.call, BandCall.state(.idle), queueIfOffline: false)
            }
        default:
            log.add("Ação de chamada vinda da pulseira: \(action)")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BandManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log.add("Restaurado pelo iOS (\(restored.count) periférico(s))")
        if let p = restored.first(where: { $0.identifier == savedId }) ?? restored.first {
            peripheral = p
            p.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log.add("Bluetooth ligado")
            if let p = peripheral {
                if p.state == .connected {
                    phase = .discovering
                    p.discoverServices([serviceUUID])
                } else {
                    connect(p)
                }
            } else if let p = savedPeripheral() {
                connect(p)
            } else {
                phase = .noBand
            }
        case .unauthorized:
            phase = .unauthorized
        default:
            resetSession()
            phase = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? ""
        let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let looksLikeBand = uuids.contains(serviceUUID)
            || name.range(of: "fit3|galaxy fit|r390", options: [.regularExpression, .caseInsensitive]) != nil
        guard looksLikeBand else { return }
        if let i = discovered.firstIndex(where: { $0.id == p.identifier }) {
            discovered[i].rssi = RSSI.intValue
        } else {
            discovered.append(DiscoveredBand(id: p.identifier, name: name.isEmpty ? "Galaxy Fit3" : name,
                                             rssi: RSSI.intValue, peripheral: p))
            log.add("Encontrada: \(name) (\(RSSI) dBm)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        log.add("BLE conectado")
        resetSession()
        phase = .discovering
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log.add("Falha ao conectar: \(error?.localizedDescription ?? "desconhecido")")
        resetSession()
        after(2) { [weak self] in
            guard let self, self.peripheral === p else { return }
            self.connect(p)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log.add("BLE desconectado" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        resetSession()
        guard peripheral === p else { return }
        connect(p) // conexão pendente: completa quando a pulseira voltar ao alcance
    }
}

// MARK: - CBPeripheralDelegate

extension BandManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log.add("Erro ao descobrir serviços: \(error.localizedDescription)")
            return
        }
        guard let service = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            log.add("⚠️ Serviço SAP 0x1A1A não encontrado — é mesmo uma Galaxy Fit3?")
            return
        }
        p.discoverCharacteristics([notifyUUID, writeUUID], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log.add("Erro ao descobrir características: \(error.localizedDescription)")
            return
        }
        let chars = service.characteristics ?? []
        guard let notify = chars.first(where: { $0.uuid == notifyUUID }),
              let write = chars.first(where: { $0.uuid == writeUUID }) else {
            log.add("⚠️ Características SAP ausentes")
            return
        }
        writeChar = write
        writeType = write.properties.contains(.write) ? .withResponse : .withoutResponse
        log.add("Escrita \(writeType == .withResponse ? "com" : "sem") resposta, " +
                "máx. \(p.maximumWriteValueLength(for: writeType)) bytes")
        if notify.isNotifying && storedMtu > 0 {
            assumeExistingSession()
        } else {
            phase = .handshake
            p.setNotifyValue(true, for: notify)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error {
            // "Criptografia insuficiente" costuma significar que o iOS está pedindo pareamento.
            log.add("Erro ao assinar notificações: \(error.localizedDescription)")
            subscribeAttempts += 1
            if subscribeAttempts <= 3 {
                after(3) { p.setNotifyValue(true, for: c) }
            }
            return
        }
        guard c.uuid == notifyUUID, c.isNotifying else { return }
        phase = .handshake
        log.add("Aguardando handshake da pulseira…")
        after(8) { [weak self] in
            guard let self, !self.sapReady else { return }
            if self.storedMtu > 0 {
                self.assumeExistingSession()
            } else {
                self.log.add("A pulseira não enviou o handshake; reconectando")
                self.reconnect()
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, c.uuid == notifyUUID, let value = c.value else { return }
        handleIncoming([UInt8](value))
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        writeBusy = false
        if let error { log.add("⚠️ Falha na escrita: \(error.localizedDescription)") }
        pump()
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        pump()
    }
}
