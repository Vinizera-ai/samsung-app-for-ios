// Serviço 5: clima. Mesma lógica de tools/fit3/weather.py.
// Contagem de parâmetros em 2 bytes big-endian, medidas de 16 bits LE, horários de 32 bits BE.
import Foundation

public enum BandWeather {
    public struct Hour: Codable, Equatable {
        public var time: Int64          // Unix (s)
        public var temperature: Double
        public var code: Int            // código WMO
        public var isDay: Bool
        public var rainPercent: Int
    }

    public struct Day: Codable, Equatable {
        public var time: Int64
        public var high: Double
        public var low: Double
        public var code: Int
    }

    public struct Forecast: Codable, Equatable {
        public var city: String
        public var region: String
        public var country: String
        public var timezone: String
        public var updatedAt: Date
        public var temperature: Double
        public var feelsLike: Double
        public var high: Double
        public var low: Double
        public var yesterdayHigh: Double
        public var yesterdayLow: Double
        public var humidity: Int
        public var windKmh: Double
        public var uvIndex: Double
        public var code: Int
        public var isDay: Bool
        public var sunrise: Int64
        public var sunset: Int64
        public var hours: [Hour]
        public var days: [Day]
    }

    /// 0 = pulseira abriu o clima / pediu local; 1 = pediu atualização.
    public static func requestKind(_ m: [UInt8]) -> Int? {
        guard let h = SAMessage.parseHeader(m), !h.isResponse else { return nil }
        if h.id == 0 { return 0 }
        if h.id == 1, m.count >= 3, m[2] == 1 { return 1 }
        return nil
    }

    /// Código WMO (Open-Meteo) -> índice de ícone da Samsung.
    public static func samsungIcon(_ wmo: Int, isDay: Bool = true) -> Int {
        switch wmo {
        case 0: return 0
        case 1, 2: return 1
        case 3: return 2
        case 45, 48: return 3
        case 51, 53, 55, 56, 57, 61, 63, 80, 81: return 5
        case 65, 82: return 21
        case 66, 67: return 16
        case 71, 73, 75, 77, 85, 86: return 13
        case 95, 96, 99: return 8
        default: return 2
        }
    }

    public static func uvDescription(_ index: Double) -> String {
        let labels = ["Baixo", "Moderado", "Alto", "Muito alto", "Extremo"]
        let level = index < 3 ? 0 : index < 6 ? 1 : index < 8 ? 2 : index < 11 ? 3 : 4
        return labels[level]
    }

    static func round(_ x: Double) -> Int { x.isFinite ? Int((x + 0.5).rounded(.down)) : 0 }

    public static func response(_ fc: Forecast) -> [UInt8] {
        var out: [UInt8] = [0xC1, 0, 0]
        var count = 0
        func one(_ id: UInt8, _ v: Int) {
            out += [id, UInt8(truncatingIfNeeded: v)]
            count += 1
        }
        func word(_ id: UInt8, _ v: Int) {
            out += [id, UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
            count += 1
        }
        func dword(_ id: UInt8, _ v: Int64) {
            out.append(id)
            for shift: Int64 in [24, 16, 8, 0] { out.append(UInt8(truncatingIfNeeded: v >> shift)) }
            count += 1
        }
        func text(_ id: UInt8, _ s: String) {
            let raw = SAMessage.utf8Prefix(s, maxBytes: 80)
            out.append(id)
            out.append(UInt8(raw.count))
            out.append(contentsOf: raw)
            count += 1
        }

        for (id, v) in [(8, 0), (6, 0), (9, 0), (10, 1), (7, 1), (11, 1), (12, 0), (18, 1)] as [(UInt8, Int)] {
            one(id, v)  // índices TWC, Celsius, sem aviso de local, local ativo, 1 cidade, cidade atual
        }
        text(13, fc.city)
        text(14, fc.region)
        text(15, fc.country)
        one(16, samsungIcon(fc.code, isDay: fc.isDay))
        dword(19, Int64(fc.updatedAt.timeIntervalSince1970))
        word(20, round(fc.temperature))
        word(21, round(fc.high))
        word(22, round(fc.low))
        word(23, round(fc.feelsLike))
        word(24, round(fc.yesterdayHigh))
        word(25, round(fc.yesterdayLow))
        dword(26, fc.sunrise)
        dword(27, fc.sunset)
        text(28, fc.timezone)
        one(17, fc.isDay ? 1 : 0)
        let hours = Array(fc.hours.prefix(24))
        one(29, hours.count)
        for (i, h) in hours.enumerated() {
            one(30, i)
            one(34, h.isDay ? 1 : 0)
            dword(31, h.time)
            one(32, samsungIcon(h.code, isDay: h.isDay))
            word(33, round(h.temperature))
            one(35, min(max(h.rainPercent, 0), 100))
        }
        let days = Array(fc.days.prefix(6))
        one(36, days.count)
        for (i, d) in days.enumerated() {
            one(37, i)
            dword(38, d.time)
            one(39, samsungIcon(d.code))
            one(40, samsungIcon(d.code))
            one(41, samsungIcon(d.code, isDay: false))
            word(42, round(d.high))
            word(43, round(d.low))
        }
        for id in UInt8(44)...UInt8(49) { word(id, 0) }   // qualidade do ar: indisponível
        word(50, round(fc.uvIndex))
        text(51, uvDescription(fc.uvIndex))
        word(52, round(fc.windKmh))
        text(53, "")
        word(54, min(max(fc.humidity, 0), 100))
        out[1] = UInt8(truncatingIfNeeded: count >> 8)
        out[2] = UInt8(truncatingIfNeeded: count)
        return out
    }

    // MARK: Open-Meteo

    public static func forecastURL(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,sunrise,sunset,uv_index_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "past_days", value: "1"),
            URLQueryItem(name: "forecast_days", value: "7"),
        ]
        return c.url!
    }

    public static func geocodeURL(name: String) -> URL {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "1"),
                        URLQueryItem(name: "language", value: "pt"), URLQueryItem(name: "format", value: "json")]
        return c.url!
    }

    public struct Place: Decodable, Equatable {
        public let name: String
        public let latitude: Double
        public let longitude: Double
        public let admin1: String?
        public let country: String?
    }

    public static func parsePlace(_ data: Data) throws -> Place? {
        struct Results: Decodable { let results: [Place]? }
        return try JSONDecoder().decode(Results.self, from: data).results?.first
    }

    struct OpenMeteo: Decodable {
        struct Current: Decodable {
            let time: Double
            let temperature_2m: Double?
            let relative_humidity_2m: Double?
            let apparent_temperature: Double?
            let is_day: Double?
            let weather_code: Double?
            let wind_speed_10m: Double?
        }
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]
            let precipitation_probability: [Double?]
            let weather_code: [Double?]
            let is_day: [Double?]
        }
        struct Daily: Decodable {
            let time: [Double]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let weather_code: [Double?]
            let sunrise: [Double?]
            let sunset: [Double?]
            let uv_index_max: [Double?]
        }
        let timezone: String?
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    public static func parseOpenMeteo(_ data: Data, city: String, region: String = "", country: String = "",
                                      now: Date = Date()) throws -> Forecast {
        let r = try JSONDecoder().decode(OpenMeteo.self, from: data)
        func at<T>(_ a: [T?], _ i: Int) -> T? { i < a.count ? a[i] : nil }
        let today = 1  // past_days=1: índice 0 é ontem
        guard r.daily.time.count >= 2 else { throw Fit3Error("Previsão diária incompleta") }
        let current = r.current.time
        var hours: [Hour] = []
        for (i, t) in r.hourly.time.enumerated() where t >= current - 3600 && hours.count < 24 {
            hours.append(Hour(time: Int64(t), temperature: at(r.hourly.temperature_2m, i) ?? 0,
                              code: Int(at(r.hourly.weather_code, i) ?? 2),
                              isDay: (at(r.hourly.is_day, i) ?? 1) == 1,
                              rainPercent: Int(at(r.hourly.precipitation_probability, i) ?? 0)))
        }
        let days = (today..<r.daily.time.count).prefix(6).map { i in
            Day(time: Int64(r.daily.time[i]), high: at(r.daily.temperature_2m_max, i) ?? 0,
                low: at(r.daily.temperature_2m_min, i) ?? 0, code: Int(at(r.daily.weather_code, i) ?? 2))
        }
        let c = r.current
        return Forecast(
            city: city, region: region, country: country, timezone: r.timezone ?? TimeZone.current.identifier,
            updatedAt: now,
            temperature: c.temperature_2m ?? 0, feelsLike: c.apparent_temperature ?? c.temperature_2m ?? 0,
            high: at(r.daily.temperature_2m_max, today) ?? 0, low: at(r.daily.temperature_2m_min, today) ?? 0,
            yesterdayHigh: at(r.daily.temperature_2m_max, 0) ?? 0, yesterdayLow: at(r.daily.temperature_2m_min, 0) ?? 0,
            humidity: Int(c.relative_humidity_2m ?? 0), windKmh: c.wind_speed_10m ?? 0,
            uvIndex: at(r.daily.uv_index_max, today) ?? 0, code: Int(c.weather_code ?? 2),
            isDay: (c.is_day ?? 1) == 1,
            sunrise: Int64(at(r.daily.sunrise, today) ?? 0), sunset: Int64(at(r.daily.sunset, today) ?? 0),
            hours: hours, days: days)
    }
}
