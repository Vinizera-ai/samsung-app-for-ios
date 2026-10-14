// Mesmos vetores de tools/tests/test_weather.py.
import XCTest
@testable import Fit3Kit

final class WeatherTests: XCTestCase {
    func sample() -> BandWeather.Forecast {
        BandWeather.Forecast(
            city: "São Paulo", region: "SP", country: "Brasil", timezone: "America/Sao_Paulo",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), temperature: -3, feelsLike: -6,
            high: 1, low: -7, yesterdayHigh: 0, yesterdayLow: -5, humidity: 80, windKmh: 12, uvIndex: 1,
            code: 71, isDay: false, sunrise: 1_700_000_000, sunset: 1_700_040_000,
            hours: [BandWeather.Hour(time: 1_700_000_000, temperature: -3, code: 71, isDay: false, rainPercent: 60)],
            days: [BandWeather.Day(time: 1_700_080_000, high: 1, low: -5, code: 3)])
    }

    func testMatchesSamsungShape() throws {
        let pkt = BandWeather.response(sample())
        XCTAssertEqual(pkt[0], 0xC1)
        let paramCount = Int(pkt[1]) << 8 | Int(pkt[2])
        XCTAssertEqual(paramCount, 49)   // 23 fixos + 1 + 6 (1 hora) + 1 + 7 (1 dia) + 11 finais
        XCTAssertEqual(pkt[3], 8)
        let t = try XCTUnwrap(pkt.firstIndex(of: 19))
        XCTAssertEqual(Array(pkt[(t + 1)...(t + 4)]), [0x65, 0x53, 0xF1, 0x00])   // horário big-endian
        XCTAssertEqual(Array(pkt[(t + 5)...(t + 7)]), [20, 0xFD, 0xFF])            // -3 °C little-endian
        XCTAssertTrue(pkt.hex.contains(Array("São Paulo".utf8).hex))
        XCTAssertTrue(pkt.hex.contains(Array("Baixo".utf8).hex))
        XCTAssertLessThan(pkt.count, 980)
        XCTAssertGreaterThan(try Sap.encode(service: 5, message: pkt, mtu: 64).count, 1)
    }

    func testFullForecastFits() {
        var fc = sample()
        fc.hours = (0..<30).map { BandWeather.Hour(time: 1_700_000_000 + Int64($0) * 3600, temperature: 20.5,
                                                   code: 3, isDay: true, rainPercent: 10) }
        fc.days = (0..<9).map { BandWeather.Day(time: 1_700_000_000 + Int64($0) * 86400, high: 25, low: 15, code: 61) }
        let pkt = BandWeather.response(fc)
        XCTAssertLessThan(pkt.count, 980)
        XCTAssertEqual(pkt[pkt.firstIndex(of: 29)! + 1], 24)
    }

    func testRequestsIconsAndUV() {
        XCTAssertEqual(BandWeather.requestKind([0]), 0)
        XCTAssertEqual(BandWeather.requestKind([1, 0, 1]), 1)
        XCTAssertNil(BandWeather.requestKind([1, 0, 0]))
        XCTAssertNil(BandWeather.requestKind([0x40]))
        XCTAssertEqual([0, 2, 3, 45, 61, 65, 66, 71, 95, 999].map { BandWeather.samsungIcon($0) },
                       [0, 1, 2, 3, 5, 21, 16, 13, 8, 2])
        XCTAssertEqual([0, 3, 6, 8, 11].map { BandWeather.uvDescription(Double($0)) },
                       ["Baixo", "Moderado", "Alto", "Muito alto", "Extremo"])
    }

    func testParseOpenMeteoWithNulls() throws {
        let json = """
        {"timezone":"America/Sao_Paulo",
         "current":{"time":1000,"temperature_2m":22.4,"relative_humidity_2m":70,"apparent_temperature":23.0,
                    "is_day":1,"weather_code":2,"wind_speed_10m":9.5},
         "hourly":{"time":[0,1000,4600],"temperature_2m":[20,22,null],"precipitation_probability":[null,10,30],
                   "weather_code":[1,2,61],"is_day":[1,1,0]},
         "daily":{"time":[-86400,0,86400],"temperature_2m_max":[25,27,26],"temperature_2m_min":[15,16,17],
                  "weather_code":[1,2,61],"sunrise":[1,2,3],"sunset":[4,5,6],"uv_index_max":[5,7,null]}}
        """
        let fc = try BandWeather.parseOpenMeteo(Data(json.utf8), city: "Campinas", region: "SP", country: "Brasil",
                                                now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual([fc.high, fc.low, fc.yesterdayHigh, fc.uvIndex], [27, 16, 25, 7])
        XCTAssertEqual(fc.sunrise, 2)
        XCTAssertEqual(fc.hours.map(\.time), [0, 1000, 4600])
        XCTAssertEqual(fc.hours[2].temperature, 0)
        XCTAssertEqual(fc.days.map(\.time), [0, 86400])
        XCTAssertEqual(fc.timezone, "America/Sao_Paulo")
        XCTAssertFalse(BandWeather.response(fc).isEmpty)

        let place = try BandWeather.parsePlace(Data(#"{"results":[{"name":"Campinas","latitude":-22.9,"longitude":-47.06,"admin1":"São Paulo","country":"Brasil"}]}"#.utf8))
        XCTAssertEqual(place?.name, "Campinas")
        XCTAssertNil(try BandWeather.parsePlace(Data("{}".utf8)))
    }
}
