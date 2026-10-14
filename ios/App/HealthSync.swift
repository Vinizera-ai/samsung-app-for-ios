import Fit3Kit
import Foundation

/// Conduz a sessão de saúde (serviço 10) fingindo ser o Samsung Health:
///   pulseira A2 -> responde E2; celular 34 -> pulseira A0 -> responde E0; celular 03 (pedir dados);
///   pulseira 82 (às vezes em blocos 3F) -> salva no histórico e só então confirma 42 (e 3E).
/// Sem a confirmação com a sequência certa, a pulseira reenvia os mesmos dados.
final class HealthSync: ObservableObject {
    static let shared = HealthSync()

    @Published private(set) var today = HealthToday()
    @Published private(set) var lastSync: Date?
    @Published private(set) var appleHealthStatus: String?

    /// Envio de mensagens SAP (ligado pelo BandManager).
    var send: ((Agent, [UInt8]) -> Void)?

    var appleHealthEnabled: Bool { UserDefaults.standard.bool(forKey: "health.appleHealth") }

    private var archive = HealthArchive()
    private let large = LargeDataReceiver()
    private var sequence = 10000
    private var capabilityReady = false
    private var probed = false
    private var lastRequest: Date?
    private var generation = 0
    private var exporting = false
    private let log = Logbook.shared

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("health.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(HealthArchive.self, from: data) {
            archive = saved
        }
        lastSync = UserDefaults.standard.object(forKey: "health.lastSync") as? Date
        today = archive.today()
    }

    // MARK: Ciclo da conexão

    func reset() {
        generation += 1
        capabilityReady = false
        probed = false
        lastRequest = nil
        large.reset()
    }

    /// Pulseira pronta: se ela não iniciar a sessão de saúde em 3 s, o celular inicia.
    func connected() {
        today = archive.today()
        exportToAppleHealth()  // tenta de novo o que falhou (ex.: iPhone estava bloqueado)
        after(3) { [weak self] in
            guard let self, !self.probed else { return }
            self.probe()
        }
    }

    func requestSync() {
        if capabilityReady { requestData() } else { probe() }
    }

    private func probe() {
        probed = true
        send?(.health, BandHealth.mobileCapabilityRequest)
    }

    private func requestData() {
        if let last = lastRequest, Date().timeIntervalSince(last) < 20 { return }  // um pedido por vez
        lastRequest = Date()
        sequence = sequence >= 0xFFFF ? 1 : sequence + 1
        send?(.health, BandHealth.requestData(sequence: sequence))
    }

    private func after(_ seconds: Double, _ body: @escaping () -> Void) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == gen else { return }
            body()
        }
    }

    // MARK: Mensagens da pulseira

    func handle(_ message: [UInt8]) {
        var payload = message
        var chunkAck: [UInt8]?
        if let chunk = large.accept(message) {
            guard let full = chunk.payload else {
                if let ack = chunk.ack { send?(.health, ack) }   // bloco intermediário ou recusado
                return
            }
            payload = full
            chunkAck = chunk.ack
        }

        let (event, reply) = BandHealth.reply(for: payload)
        if event == .syncData {
            if archive.ingest(payload) {
                archive.prune()
                save()
                today = archive.today()
                exportToAppleHealth()
            }
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "health.lastSync")
        }
        // Confirma o bloco e depois o lote, nesta ordem (como o receptor da Samsung).
        if let chunkAck { send?(.health, chunkAck) }
        if let reply { send?(.health, reply) }

        switch event {
        case .gmCapability where !probed:
            probed = true
            after(0.65) { [weak self] in self?.send?(.health, BandHealth.mobileCapabilityRequest) }
        case .wearableCapability:
            capabilityReady = true
            log.add("Saúde: sessão aberta, pedindo os dados")
            after(0.25) { [weak self] in self?.requestData() }
        default:
            break
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(archive).write(to: fileURL, options: .atomic)
        } catch {
            log.add("⚠️ Saúde: falha ao salvar o histórico: \(error.localizedDescription)")
        }
    }

    // MARK: Apple Saúde

    func enableAppleHealth() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error = await HealthKitExporter.shared.requestAccess() {
                self.appleHealthStatus = "Apple Saúde indisponível: \(error). Se você instalou o Fit3Link.ipa, " +
                    "instale o Fit3Link-Saude.ipa (veja docs/INSTALACAO.md)."
                return
            }
            self.appleHealthStatus = nil
            self.exportToAppleHealth()
        }
    }

    func exportToAppleHealth() {
        guard appleHealthEnabled, !exporting else { return }
        exporting = true
        let snapshot = archive
        let firmware = BandManager.shared.firmware
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.exporting = false }
            do {
                let accepted = try await HealthKitExporter.shared.export(snapshot, firmware: firmware)
                guard !accepted.isEmpty else { return }
                for (id, version) in accepted {
                    self.archive.exported[id] = max(self.archive.exported[id] ?? 0, version)
                }
                self.save()
                self.appleHealthStatus = "Enviado ao Apple Saúde: \(accepted.count) registros"
                self.log.add("Saúde: \(accepted.count) registros enviados ao Apple Saúde")
            } catch {
                // Ex.: iPhone bloqueado (o Saúde fica protegido). Tenta de novo na próxima sincronização.
                self.appleHealthStatus = "Apple Saúde: \(error.localizedDescription)"
            }
        }
    }
}
