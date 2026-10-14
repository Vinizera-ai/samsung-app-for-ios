import Fit3Kit
import Foundation

/// Medição pontual (batimentos, oxigênio, estresse).
struct HealthPoint: Codable, Equatable {
    var start: Date
    var end: Date
    var value: Int
    var min: Int?
    var max: Int?
}

struct SleepEpisode: Codable, Equatable {
    var id: String
    var start: Date
    var end: Date
    var score: Int?
}

/// Resumo exibido no app.
struct HealthToday: Equatable {
    var steps = 0
    var distanceMeters = 0.0
    var calories = 0.0
    var heartRate: HealthPoint?
    var spo2: HealthPoint?
    var stress: HealthPoint?
    var sleepMinutes: Int?
    var sleepScore: Int?
}

/// Histórico local de 30 dias (Application Support/health.json). Chaves estáveis evitam duplicatas
/// quando a pulseira reenvia o mesmo lote.
struct HealthArchive: Codable {
    var steps: [String: BandHealth.StepBin] = [:]
    var heartRate: [String: HealthPoint] = [:]
    var spo2: [String: HealthPoint] = [:]
    var stress: [String: HealthPoint] = [:]
    var sleep: [String: SleepEpisode] = [:]
    var stages: [String: BandHealth.SleepStage] = [:]
    /// Id de sincronização -> versão já enviada ao Apple Saúde.
    var exported: [String: Int] = [:]

    static func key(_ d: Date) -> String { String(Int64(d.timeIntervalSince1970)) }
    static func stageKey(_ s: BandHealth.SleepStage) -> String { "\(s.sleepId).\(key(s.start)).\(key(s.end))" }

    static let retention: TimeInterval = 30 * 86400

    /// Junta um pacote da pulseira. Devolve true se algo novo entrou.
    mutating func ingest(_ message: [UInt8], now: Date = Date()) -> Bool {
        var changed = false
        let oldest = now.addingTimeInterval(-Self.retention)
        let future = now.addingTimeInterval(300)
        func valid(_ d: Date) -> Bool { d >= oldest && d <= future }

        for bin in BandHealth.parseStepBins(message) ?? [] where valid(bin.start) {
            let k = Self.key(bin.start)
            if steps[k] != bin {
                steps[k] = bin
                changed = true
            }
        }
        for v in BandHealth.parseVitals(message) ?? [] {
            if v.type == BandHealth.dataSleep {
                guard let s = v.start, let e = v.end, e > s, e.timeIntervalSince(s) <= 36 * 3600, valid(e) else { continue }
                let ep = SleepEpisode(id: v.uuid ?? "\(Self.key(s))-\(Self.key(e))", start: s, end: e, score: v.score)
                if sleep[ep.id] != ep {
                    sleep[ep.id] = ep
                    changed = true
                }
                continue
            }
            guard let value = v.value, let at = v.measuredAt, valid(at) else { continue }
            let start = v.start ?? at
            let point = HealthPoint(start: min(start, at), end: at, value: value, min: v.min, max: v.max)
            let k = Self.key(at)
            switch v.type {
            case BandHealth.dataHeartRate where (25...250).contains(value):
                if heartRate[k] != point { heartRate[k] = point; changed = true }
            case BandHealth.dataSpO2 where (50...100).contains(value):
                if spo2[k] != point { spo2[k] = point; changed = true }
            case BandHealth.dataStress where (0...100).contains(value):
                if stress[k] != point { stress[k] = point; changed = true }
            default:
                break
            }
        }
        for st in BandHealth.parseSleepStages(message) ?? []
        where st.end > st.start && st.end.timeIntervalSince(st.start) <= 36 * 3600 && valid(st.end) {
            let k = Self.stageKey(st)
            if stages[k] == nil {
                stages[k] = st
                changed = true
            }
        }
        return changed
    }

    mutating func prune(now: Date = Date()) {
        let oldest = now.addingTimeInterval(-Self.retention)
        steps = steps.filter { $0.value.start >= oldest }
        heartRate = heartRate.filter { $0.value.end >= oldest }
        spo2 = spo2.filter { $0.value.end >= oldest }
        stress = stress.filter { $0.value.end >= oldest }
        sleep = sleep.filter { $0.value.end >= oldest }
        stages = stages.filter { $0.value.end >= oldest }
        var live = Set<String>()
        for k in steps.keys {
            live.insert("fit3.steps.\(k)")
            live.insert("fit3.distance.\(k)")
            live.insert("fit3.energy.\(k)")
        }
        for k in heartRate.keys { live.insert("fit3.hr.\(k)") }
        for k in spo2.keys { live.insert("fit3.spo2.\(k)") }
        for k in sleep.keys {
            live.insert("fit3.sleep.\(k).bed")
            live.insert("fit3.sleep.\(k).asleep")
        }
        for k in stages.keys { live.insert("fit3.stage.\(k)") }
        exported = exported.filter { live.contains($0.key) }
    }

    // MARK: Sono

    func stagesFor(_ ep: SleepEpisode) -> [BandHealth.SleepStage] {
        stages.values
            .filter { $0.sleepId == ep.id && $0.start < ep.end && $0.end > ep.start }
            .map { BandHealth.SleepStage(sleepId: $0.sleepId, start: max($0.start, ep.start),
                                         end: min($0.end, ep.end), kind: $0.kind) }
            .sorted { $0.start < $1.start }
    }

    static func union(_ intervals: [(Date, Date)]) -> TimeInterval {
        var total: TimeInterval = 0
        var end = Date.distantPast
        for (a, b) in intervals.filter({ $0.1 > $0.0 }).sorted(by: { $0.0 < $1.0 }) {
            total += max(0, b.timeIntervalSince(max(a, end)))
            end = max(end, b)
        }
        return total
    }

    /// Tempo dormindo: desconta "acordado" só quando os estágios cobrem o episódio inteiro.
    func asleepSeconds(_ ep: SleepEpisode) -> TimeInterval {
        let rows = stagesFor(ep)
        let complete = !rows.isEmpty
            && rows.allSatisfy { (BandHealth.sleepAwake...BandHealth.sleepREM).contains($0.kind) }
            && abs(Self.union(rows.map { ($0.start, $0.end) }) - ep.end.timeIntervalSince(ep.start)) < 1
        guard complete else { return ep.end.timeIntervalSince(ep.start) }
        return Self.union(rows.filter { $0.kind != BandHealth.sleepAwake }.map { ($0.start, $0.end) })
    }

    // MARK: Resumo de hoje

    func today(now: Date = Date(), calendar: Calendar = .current) -> HealthToday {
        var t = HealthToday()
        let dayStart = calendar.startOfDay(for: now)
        for bin in steps.values where bin.start >= dayStart {
            t.steps += bin.count
            t.distanceMeters += bin.distanceMeters
            t.calories += bin.calories
        }
        let recent = now.addingTimeInterval(-86400)
        t.heartRate = heartRate.values.filter { $0.end >= recent }.max { $0.end < $1.end }
        t.spo2 = spo2.values.filter { $0.end >= recent }.max { $0.end < $1.end }
        t.stress = stress.values.filter { $0.end >= recent }.max { $0.end < $1.end }
        let nights = sleep.values.filter { $0.end >= dayStart }
        if !nights.isEmpty {
            t.sleepMinutes = Int(nights.map(asleepSeconds).reduce(0, +) / 60)
            t.sleepScore = nights.max { $0.end < $1.end }?.score
        }
        return t
    }
}
