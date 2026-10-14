"""Formato do pacote de clima (vetor do Fit3-App, conferido em pulseira) e parsing do Open-Meteo."""
import unittest

from fit3 import sap
from fit3 import weather as W


def sample() -> W.Forecast:
    return W.Forecast(
        city="São Paulo", region="SP", country="Brasil", timezone="America/Sao_Paulo",
        updated_at=1_700_000_000_000, temperature=-3.0, feels_like=-6.0, high=1.0, low=-7.0,
        yesterday_high=0.0, yesterday_low=-5.0, humidity=80, wind_kmh=12.0, uv_index=1.0,
        code=71, is_day=False, sunrise=1_700_000_000, sunset=1_700_040_000,
        hours=[W.Hour(1_700_000_000, -3.0, 71, False, 60)],
        days=[W.Day(1_700_080_000, 1.0, -5.0, 3)])


class WeatherPacketTest(unittest.TestCase):
    def test_matches_samsung_shape(self):
        pkt = W.response(sample())
        self.assertEqual(pkt[0], 0xC1)
        self.assertEqual((pkt[1] << 8) | pkt[2], 6 + 17 + 1 + 6 + 1 + 7 + 11)   # contagem big-endian
        self.assertEqual(pkt[3], 8)
        t = pkt.index(19)
        self.assertEqual(pkt[t + 1:t + 5], bytes.fromhex("6553f100"))      # horário big-endian
        self.assertEqual(pkt[t + 5:t + 8], bytes([20, 0xFD, 0xFF]))          # -3 °C little-endian
        self.assertIn("São Paulo".encode(), pkt)
        self.assertIn("Baixo".encode(), pkt)
        self.assertLess(len(pkt), 980)
        self.assertGreater(len(sap.encode_message(5, pkt, 64)), 1)

    def test_full_day_fits(self):
        fc = sample()
        fc.hours = [W.Hour(1_700_000_000 + i * 3600, 20.5, 3, True, 10) for i in range(30)]
        fc.days = [W.Day(1_700_000_000 + i * 86400, 25, 15, 61) for i in range(9)]
        pkt = W.response(fc)
        self.assertLess(len(pkt), 980)
        self.assertEqual(pkt[pkt.index(29) + 1], 24)    # no máximo 24 horas

    def test_requests(self):
        self.assertEqual(W.request_kind(bytes([0])), 0)
        self.assertEqual(W.request_kind(bytes([1, 0, 1])), 1)
        self.assertIsNone(W.request_kind(bytes([1, 0, 0])))
        self.assertIsNone(W.request_kind(bytes([0x40])))

    def test_icons_and_uv(self):
        self.assertEqual([W.samsung_icon(c) for c in (0, 2, 3, 45, 61, 65, 66, 71, 95, 999)],
                         [0, 1, 2, 3, 5, 21, 16, 13, 8, 2])
        self.assertEqual([W.uv_description(x) for x in (0, 3, 6, 8, 11)],
                         ["Baixo", "Moderado", "Alto", "Muito alto", "Extremo"])


class OpenMeteoTest(unittest.TestCase):
    def test_parse_with_nulls(self):
        root = {
            "timezone": "America/Sao_Paulo",
            "current": {"time": 1000, "temperature_2m": 22.4, "relative_humidity_2m": 70,
                        "apparent_temperature": 23.0, "is_day": 1, "weather_code": 2, "wind_speed_10m": 9.5},
            "hourly": {"time": [0, 1000, 4600], "temperature_2m": [20, 22, None],
                       "precipitation_probability": [None, 10, 30], "weather_code": [1, 2, 61], "is_day": [1, 1, 0]},
            "daily": {"time": [-86400, 0, 86400], "temperature_2m_max": [25, 27, 26],
                      "temperature_2m_min": [15, 16, 17], "weather_code": [1, 2, 61],
                      "sunrise": [1, 2, 3], "sunset": [4, 5, 6], "uv_index_max": [5, 7, None]},
        }
        fc = W.from_open_meteo(root, "Campinas", "SP", "Brasil", now_ms=5)
        self.assertEqual((fc.high, fc.low, fc.yesterday_high, fc.uv_index, fc.sunrise), (27, 16, 25, 7, 2))
        self.assertEqual([h.time for h in fc.hours], [0, 1000, 4600])
        self.assertEqual(fc.hours[2].temperature, 0.0)
        self.assertEqual([d.time for d in fc.days], [0, 86400])
        self.assertEqual(fc.timezone, "America/Sao_Paulo")
        self.assertTrue(W.response(fc))


if __name__ == "__main__":
    unittest.main()
