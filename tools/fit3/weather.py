"""Serviço 5: clima. Pacote no formato de SAWeatherMessageData.buildMSGData(WEATHER_INFO),
mapeado por yuriyurin/Fit3-App; dados do Open-Meteo (grátis, sem chave).

Peculiaridades confirmadas em pulseira real: o número de parâmetros vai em 2 bytes big-endian,
medidas de 16 bits em little-endian e horários de 32 bits em big-endian.
"""
from __future__ import annotations

import json
import math
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

from .messages import TYPE_REQUEST, parse_header, utf8_prefix


@dataclass
class Hour:
    time: int            # Unix (s)
    temperature: float
    code: int            # código WMO
    is_day: bool
    rain_percent: int


@dataclass
class Day:
    time: int
    high: float
    low: float
    code: int


@dataclass
class Forecast:
    city: str
    region: str
    country: str
    timezone: str
    updated_at: int      # ms
    temperature: float
    feels_like: float
    high: float
    low: float
    yesterday_high: float
    yesterday_low: float
    humidity: int
    wind_kmh: float
    uv_index: float
    code: int
    is_day: bool
    sunrise: int
    sunset: int
    hours: list[Hour] = field(default_factory=list)
    days: list[Day] = field(default_factory=list)


def request_kind(message: bytes) -> int | None:
    """0 = pulseira abriu o clima / pediu local; 1 = pediu atualização."""
    h = parse_header(message)
    if not h or h.typ != TYPE_REQUEST:
        return None
    if h.id == 0:
        return 0
    if h.id == 1 and len(message) >= 3 and message[2] == 1:
        return 1
    return None


def samsung_icon(wmo: int, is_day: bool = True) -> int:
    """Código WMO (Open-Meteo) -> índice de ícone da Samsung."""
    if wmo == 0:
        return 0
    if wmo in (1, 2):
        return 1
    if wmo == 3:
        return 2
    if wmo in (45, 48):
        return 3
    if wmo in (51, 53, 55, 56, 57, 61, 63, 80, 81):
        return 5
    if wmo in (65, 82):
        return 21
    if wmo in (66, 67):
        return 16
    if wmo in (71, 73, 75, 77, 85, 86):
        return 13
    if wmo in (95, 96, 99):
        return 8
    return 2


UV_LABELS = {
    "pt": ["Baixo", "Moderado", "Alto", "Muito alto", "Extremo"],
    "en": ["Low", "Moderate", "High", "Very high", "Extreme"],
}


def uv_description(index: float, language: str = "pt") -> str:
    level = 0 if index < 3 else 1 if index < 6 else 2 if index < 8 else 3 if index < 11 else 4
    return UV_LABELS.get(language.split("-")[0], UV_LABELS["en"])[level]


def _round(x: float) -> int:
    return math.floor(x + 0.5)


def response(fc: Forecast, language: str = "pt") -> bytes:
    out = bytearray([0xC1, 0, 0])  # variável, resposta, WEATHER_INFO(1); contagem preenchida no fim
    count = 0

    def one(pid: int, v: int) -> None:
        nonlocal count
        out.extend((pid, v & 0xFF))
        count += 1

    def word(pid: int, v: int) -> None:          # 16 bits little-endian
        nonlocal count
        out.extend((pid, v & 0xFF, (v >> 8) & 0xFF))
        count += 1

    def dword(pid: int, v: int) -> None:         # 32 bits big-endian
        nonlocal count
        out.append(pid)
        out.extend((v >> s) & 0xFF for s in (24, 16, 8, 0))
        count += 1

    def text(pid: int, s: str) -> None:
        nonlocal count
        raw = utf8_prefix(s, 80)
        out.extend((pid, len(raw)))
        out.extend(raw)
        count += 1

    for pid, v in ((8, 0), (6, 0), (9, 0), (10, 1), (7, 1), (11, 1), (12, 0), (18, 1)):
        one(pid, v)   # índices TWC, Celsius, sem aviso de local, local ativo, 1 cidade, cidade atual
    text(13, fc.city)
    text(14, fc.region)
    text(15, fc.country)
    one(16, samsung_icon(fc.code, fc.is_day))
    dword(19, fc.updated_at // 1000)
    for pid, v in ((20, fc.temperature), (21, fc.high), (22, fc.low), (23, fc.feels_like),
                   (24, fc.yesterday_high), (25, fc.yesterday_low)):
        word(pid, _round(v))
    dword(26, fc.sunrise)
    dword(27, fc.sunset)
    text(28, fc.timezone)
    one(17, 1 if fc.is_day else 0)
    hours = fc.hours[:24]
    one(29, len(hours))
    for i, h in enumerate(hours):
        one(30, i)
        one(34, 1 if h.is_day else 0)
        dword(31, h.time)
        one(32, samsung_icon(h.code, h.is_day))
        word(33, _round(h.temperature))
        one(35, max(0, min(100, h.rain_percent)))
    days = fc.days[:6]
    one(36, len(days))
    for i, d in enumerate(days):
        one(37, i)
        dword(38, d.time)
        one(39, samsung_icon(d.code, True))
        one(40, samsung_icon(d.code, True))
        one(41, samsung_icon(d.code, False))
        word(42, _round(d.high))
        word(43, _round(d.low))
    for pid in range(44, 50):   # qualidade do ar: indisponível
        word(pid, 0)
    word(50, _round(fc.uv_index))
    text(51, uv_description(fc.uv_index, language))
    word(52, _round(fc.wind_kmh))
    text(53, "")
    word(54, max(0, min(100, fc.humidity)))
    if len(out) > 980:
        raise ValueError(f"pacote de clima grande demais: {len(out)}")
    out[1], out[2] = (count >> 8) & 0xFF, count & 0xFF
    return bytes(out)


# --- Open-Meteo ---

def _get_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=15) as resp:  # noqa: S310 — URL fixa https
        return json.load(resp)


def geocode(name: str, language: str = "pt") -> dict | None:
    q = urllib.parse.urlencode({"name": name, "count": 1, "language": language, "format": "json"})
    results = _get_json(f"https://geocoding-api.open-meteo.com/v1/search?{q}").get("results") or []
    return results[0] if results else None


def forecast_url(lat: float, lon: float) -> str:
    q = urllib.parse.urlencode({
        "latitude": f"{lat:.4f}", "longitude": f"{lon:.4f}",
        "current": "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code,wind_speed_10m",
        "hourly": "temperature_2m,precipitation_probability,weather_code,is_day",
        "daily": "temperature_2m_max,temperature_2m_min,weather_code,sunrise,sunset,uv_index_max",
        "timezone": "auto", "timeformat": "unixtime", "past_days": 1, "forecast_days": 7,
    })
    return f"https://api.open-meteo.com/v1/forecast?{q}"


def from_open_meteo(root: dict, city: str, region: str = "", country: str = "",
                    now_ms: int | None = None) -> Forecast:
    cur, hourly, daily = root["current"], root["hourly"], root["daily"]
    now = cur["time"]
    num = lambda v, d=0.0: d if v is None else v  # noqa: E731 — o Open-Meteo devolve null às vezes
    hours = [Hour(t, num(hourly["temperature_2m"][i]), int(num(hourly["weather_code"][i], 2)),
                  num(hourly["is_day"][i], 1) == 1, int(num(hourly["precipitation_probability"][i])))
             for i, t in enumerate(hourly["time"]) if t >= now - 3600][:24]
    if len(daily["time"]) < 2:
        raise ValueError("previsão diária incompleta")
    today = 1  # past_days=1: índice 0 é ontem
    days = [Day(daily["time"][i], num(daily["temperature_2m_max"][i]), num(daily["temperature_2m_min"][i]),
                int(num(daily["weather_code"][i], 2)))
            for i in range(today, len(daily["time"]))][:6]
    return Forecast(
        city=city, region=region, country=country, timezone=root.get("timezone", "UTC"),
        updated_at=now_ms if now_ms is not None else int(time.time() * 1000),
        temperature=num(cur["temperature_2m"]), feels_like=num(cur["apparent_temperature"]),
        high=num(daily["temperature_2m_max"][today]), low=num(daily["temperature_2m_min"][today]),
        yesterday_high=num(daily["temperature_2m_max"][0]), yesterday_low=num(daily["temperature_2m_min"][0]),
        humidity=int(num(cur["relative_humidity_2m"])), wind_kmh=num(cur["wind_speed_10m"]),
        uv_index=num(daily["uv_index_max"][today]), code=int(num(cur["weather_code"], 2)),
        is_day=num(cur["is_day"], 1) == 1,
        sunrise=int(num(daily["sunrise"][today])), sunset=int(num(daily["sunset"][today])),
        hours=hours, days=days)


def fetch(lat: float, lon: float, city: str, region: str = "", country: str = "") -> Forecast:
    return from_open_meteo(_get_json(forecast_url(lat, lon)), city, region, country)
