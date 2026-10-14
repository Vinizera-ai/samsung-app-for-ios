import Fit3Kit
import Foundation
import HealthKit

/// Envia ao Apple Saúde os dados do histórico. Cada amostra leva HKMetadataKeySyncIdentifier,
/// então reenviar a mesma medição atualiza em vez de duplicar.
///
/// Precisa do entitlement do HealthKit (Fit3Link-Saude.ipa). Sem ele, o pedido de permissão falha
/// e o app continua mostrando os dados só na própria tela.
final class HealthKitExporter {
    static let shared = HealthKitExporter()

    private let store = HKHealthStore()

    private let stepType = HKQuantityType(.stepCount)
    private let distanceType = HKQuantityType(.distanceWalkingRunning)
    private let energyType = HKQuantityType(.activeEnergyBurned)
    private let heartType = HKQuantityType(.heartRate)
    private let oxygenType = HKQuantityType(.oxygenSaturation)
    private let sleepType = HKCategoryType(.sleepAnalysis)

    private var allTypes: Set<HKSampleType> {
        [stepType, distanceType, energyType, heartType, oxygenType, sleepType]
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// nil = permissão pedida com sucesso; senão, o motivo da falha.
    func requestAccess() async -> String? {
        guard isAvailable else { return "O Apple Saúde não está disponível neste aparelho." }
        do {
            try await store.requestAuthorization(toShare: allTypes, read: [])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func authorized(_ type: HKObjectType) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    private static func sleepValue(_ kind: Int) -> HKCategoryValueSleepAnalysis {
        switch kind {
        case BandHealth.sleepAwake: return .awake
        case BandHealth.sleepLight: return .asleepCore
        case BandHealth.sleepDeep: return .asleepDeep
        case BandHealth.sleepREM: return .asleepREM
        default: return .asleepUnspecified
        }
    }

    /// Envia o que ainda não foi enviado. Devolve id de sincronização -> versão aceitos.
    func export(_ archive: HealthArchive, firmware: String?, now: Date = Date()) async throws -> [String: Int] {
        let device = HKDevice(name: "Galaxy Fit3", manufacturer: "Samsung", model: "SM-R390",
                              hardwareVersion: nil, firmwareVersion: firmware, softwareVersion: nil,
                              localIdentifier: nil, udiDeviceIdentifier: nil)
        var pending: [(id: String, version: Int, sample: HKSample)] = []

        func meta(_ id: String, _ version: Int) -> [String: Any] {
            [HKMetadataKeySyncIdentifier: id, HKMetadataKeySyncVersion: version]
        }
        func needs(_ id: String, _ version: Int) -> Bool { (archive.exported[id] ?? 0) < version }
        func quantity(_ type: HKQuantityType, _ id: String, _ version: Int, _ unit: HKUnit, _ value: Double,
                      _ start: Date, _ end: Date) {
            guard authorized(type), needs(id, version) else { return }
            let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                                          start: start, end: max(start, end), device: device,
                                          metadata: meta(id, version))
            pending.append((id: id, version: version, sample: sample as HKSample))
        }
        func sleepSample(_ id: String, _ value: HKCategoryValueSleepAnalysis, _ start: Date, _ end: Date) {
            guard authorized(sleepType), needs(id, 1), end > start else { return }
            let sample = HKCategorySample(type: sleepType, value: value.rawValue, start: start, end: end,
                                          device: device, metadata: meta(id, 1))
            pending.append((id: id, version: 1, sample: sample as HKSample))
        }

        // Passos, distância e calorias por intervalo de 1 minuto; a versão sobe se a contagem aumentar.
        for (key, bin) in archive.steps where bin.count > 0 {
            quantity(stepType, "fit3.steps.\(key)", bin.count, .count(), Double(bin.count), bin.start, bin.end)
            if bin.distanceMeters > 0 {
                quantity(distanceType, "fit3.distance.\(key)", bin.count, .meter(), bin.distanceMeters, bin.start, bin.end)
            }
            if bin.calories > 0 {
                quantity(energyType, "fit3.energy.\(key)", bin.count, .kilocalorie(), bin.calories, bin.start, bin.end)
            }
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        for (key, p) in archive.heartRate {
            quantity(heartType, "fit3.hr.\(key)", 1, bpm, Double(p.value), p.start, p.end)
        }
        for (key, p) in archive.spo2 {
            quantity(oxygenType, "fit3.spo2.\(key)", 1, .percent(), Double(p.value) / 100, p.start, p.end)
        }
        // Sono: "na cama" para o episódio + estágios; sem estágios, "dormindo" depois de 3 h do fim.
        for (key, ep) in archive.sleep {
            sleepSample("fit3.sleep.\(key).bed", .inBed, ep.start, ep.end)
            // Usa a chave guardada no histórico (horários originais), recortando só a amostra.
            let stages = archive.stages.filter {
                $0.value.sleepId == ep.id && $0.value.start < ep.end && $0.value.end > ep.start
            }
            if stages.isEmpty {
                if ep.end < now.addingTimeInterval(-3 * 3600) {
                    sleepSample("fit3.sleep.\(key).asleep", .asleepUnspecified, ep.start, ep.end)
                }
            } else {
                for (stageKey, st) in stages {
                    sleepSample("fit3.stage.\(stageKey)", Self.sleepValue(st.kind), max(st.start, ep.start), min(st.end, ep.end))
                }
            }
        }

        var accepted: [String: Int] = [:]
        var index = 0
        while index < pending.count {
            let batch = Array(pending[index..<min(index + 400, pending.count)])
            try await store.save(batch.map(\.sample))
            for item in batch { accepted[item.id] = max(accepted[item.id] ?? 0, item.version) }
            index += batch.count
        }
        return accepted
    }
}
