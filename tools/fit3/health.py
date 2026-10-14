"""Serviço 10: saúde. O celular se apresenta como Samsung Health e a pulseira envia os dados.

Comandos e IDs de campo vêm do plugin oficial (HealthDataManager, ModenConstant,
ConsolidatedSyncDataParser), mapeados por yuriyurin/Fit3-App e testados em pulseiras AZA3.

Fluxo:
  pulseira  A2 (GM_REQUEST_CAPABILITY)  ->  celular responde E2 (Samsung Health "instalado")
  celular   34 (capacidade do host)     ->  pulseira A0 (WEARABLE_REQUEST_CAPABILITY)
  celular   E0 (capacidade 4.51)        ->  celular 03 (REQUEST_DATA)
  pulseira  82 (SYNC_DATA, às vezes em blocos 3F) -> celular confirma 42 … (e 3E por bloco)
Sem a confirmação com a sequência certa, a pulseira reenvia os mesmos dados.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from .messages import FORMAT_VARIABLE, TYPE_REQUEST, TYPE_RESPONSE, header, parse_header

EPOCH_1990 = 631_152_000  # a pulseira conta segundos a partir de 1990-01-01 UTC

CMD_CHECK_STATUS = 1
CMD_SYNC_DATA = 2
CMD_REQUEST_DATA = 3
CMD_WEARABLE_MSG = 4
CMD_PEDOMETER_BACK_SYNC = 7
CMD_WEARABLE_REQUEST_CAPABILITY = 32
CMD_MOBILE_REQUEST_CAPABILITY = 33
CMD_GM_REQUEST_CAPABILITY = 34
CMD_GM_CAPABILITY_NOTI = 35
CMD_HOST_CAPABILITY = 52
LARGE_DATA_CHUNK = 63
LARGE_DATA_ACK = 62

DATA_STEPS = 7
DATA_HEART_RATE = 10
DATA_SLEEP = 16
DATA_SLEEP_STAGE = 17
DATA_STRESS = 19
DATA_SPO2 = 112

SEQ = 0xE0
PROTO = 0xE1

SLEEP_AWAKE, SLEEP_LIGHT, SLEEP_DEEP, SLEEP_REM = 40001, 40002, 40003, 40004

MOBILE_CAPABILITY_REQUEST = bytes([CMD_HOST_CAPABILITY])
CHECK_STATUS_RESPONSE = bytes([header(0, TYPE_RESPONSE, CMD_CHECK_STATUS)])
WEARABLE_MSG_RESPONSE = bytes([header(0, TYPE_RESPONSE, CMD_WEARABLE_MSG)])

# Samsung Health 7.0.6.011 emulado; 6.04 é a versão mínima aceita para a Fit3.
EMULATED_SHEALTH_VERSION = 7_006_011
FIT3_MIN_SHEALTH_VERSION = 6_040_000


def _le16(b: bytes, off: int) -> int | None:
    return b[off] | (b[off + 1] << 8) if off + 2 <= len(b) else None


def _le32(b: bytes, off: int) -> int:
    return struct.unpack_from("<i", b, off)[0]


def band_time(raw: bytes) -> int:
    """Tempo da pulseira (u32 LE, segundos desde 1990) -> milissegundos Unix."""
    return ((struct.unpack_from("<I", raw, 0)[0]) + EPOCH_1990) * 1000


def sequence(message: bytes) -> int | None:
    h = parse_header(message)
    if not h:
        return None
    off = 1 if h.id == CMD_PEDOMETER_BACK_SYNC else (
        2 if h.id == CMD_SYNC_DATA or h.fmt == FORMAT_VARIABLE else 1)
    if len(message) <= off or message[off] != SEQ:
        return None
    return _le16(message, off + 1)


# --- pedidos e respostas do celular ---

def request_data(seq: int, now_ms: int) -> bytes:
    """REQUEST_DATA com o DeviceInfo de 25 bytes do plugin (cursor zero = troca completa)."""
    end = max(0, min(now_ms // 1000 - EPOCH_1990, 0xFFFFFFFF))
    return (bytes([CMD_REQUEST_DATA, SEQ]) + seq.to_bytes(2, "little")
            + bytes([5, 25, 1, 0, 2, 0, 0, 3, 4, 51])
            + bytes([4]) + (0).to_bytes(4, "little")
            + bytes([5]) + (0).to_bytes(4, "little")
            + bytes([6]) + end.to_bytes(4, "little")
            + bytes([7, 1]))


def parse_gm_request(message: bytes) -> tuple[int, int] | None:
    """(sequência, versão do protocolo de saúde) de um A2 02 E0 xx xx E1 xx xx."""
    h = parse_header(message)
    if not h or h.id != CMD_GM_REQUEST_CAPABILITY or h.fmt != FORMAT_VARIABLE or len(message) < 2:
        return None
    seq = proto = None
    i = 2
    for _ in range(message[1]):
        if i >= len(message):
            break
        pid = message[i]
        i += 1
        if pid in (SEQ, PROTO):
            value = _le16(message, i)
            i += 2
            if pid == SEQ:
                seq = value
            else:
                proto = value
        elif pid in (0xD0, 0xD1):
            i += 1
        elif pid in (0xD2, 0xD3):
            i += 4
        else:
            break  # parâmetro desconhecido: não dá para saber a largura
    return (seq, proto) if seq is not None and proto is not None else None


def gm_capability_response(seq: int, proto: int) -> bytes:
    return (bytes([header(FORMAT_VARIABLE, TYPE_RESPONSE, CMD_GM_REQUEST_CAPABILITY), 6,
                   0xD0, 2,       # Samsung Health instalado
                   0xD1, 0])      # sucesso
            + bytes([0xD2]) + EMULATED_SHEALTH_VERSION.to_bytes(4, "little")
            + bytes([0xD3]) + FIT3_MIN_SHEALTH_VERSION.to_bytes(4, "little")
            + bytes([SEQ]) + seq.to_bytes(2, "little")
            + bytes([PROTO]) + proto.to_bytes(2, "little"))


def capability_sequence(message: bytes) -> int | None:
    if len(message) >= 5 and message[2] == SEQ:
        return _le16(message, 3)
    for i in range(2, len(message) - 2):
        if message[i] == SEQ:
            return _le16(message, i + 1)
    return None


_CAPABILITY_STRINGS = [
    (0xC0, "com.samsung.android.app.shealth.RESPONSE_CAPABILITY"),
    (0xC1, "shealth"),
    (0xC2, "wearable"),
    (0xAE, '{"pedometer":4}'),
    (0xAF, '{"wearable_messaging":true,"compression":true,"wm_chunk_size":10000,'
           '"sync_duration":30,"blob_compression":true}'),
    (0xB1, '{"common_sync":"com.samsung.android.app.shealth.wearable.syncmanager"}'),
    (0xB3, '{"pedometer_sync":{"support_wearable_all_step":true},'
           '"goal_support":{"pedometer":1,"floor":1,"water":0},'
           '"daily_activity":{"support":false},'
           '"dashboard_config_sync":{"version":1000,"is_support":true}}'),
    (0xAC, '{"os":"android","os_version":"16","country_iso":"","one_ui_version":-1}'),
    (0xC3, '{"message_version":5.18,"message_support":true,"message_compression":true,'
           '"message_compression_format":"gzip","message_size":10000}'),
    (0xAD, '{"support":false,"target_list":"settings.band.manage_exercises"}'),
]


def wearable_capability_response(seq: int) -> bytes:
    """Capacidade do Samsung Health 7.0.6 (protocolo 4.51), como o plugin oficial gera."""
    params = [bytes([SEQ]) + seq.to_bytes(2, "little"),
              bytes([0xA1, 4, 0x51]),
              bytes([0xA2]) + EMULATED_SHEALTH_VERSION.to_bytes(4, "little")]
    for pid, text in _CAPABILITY_STRINGS:
        raw = text.encode()
        params.append(bytes([pid, len(raw)]) + raw)
    return (bytes([header(FORMAT_VARIABLE, TYPE_RESPONSE, CMD_WEARABLE_REQUEST_CAPABILITY), len(params)])
            + b"".join(params))


_SUCCESS = bytes([0x04, 0x02, 0x01, 0x01])


def sync_data_success(request: bytes) -> bytes | None:
    """42 02 E0 <seq LE> 04 02 01 01 — confirma o lote exato recebido."""
    if len(request) < 5 or request[2] != SEQ:
        return None
    return bytes([0x42, 0x02, SEQ]) + request[3:5] + _SUCCESS


def request_data_success(request: bytes) -> bytes | None:
    """43 E0 <seq LE> 04 02 01 01 — 'não tenho dados para te mandar'."""
    if len(request) < 4 or request[1] != SEQ:
        return None
    return bytes([0x43, SEQ]) + request[2:4] + _SUCCESS


def reply_for(message: bytes) -> tuple[str, bytes | None]:
    """Classifica uma mensagem da pulseira e devolve (evento, resposta a enviar)."""
    h = parse_header(message)
    if not h:
        return "invalid", None
    req = h.typ == TYPE_REQUEST
    if h.id == CMD_GM_REQUEST_CAPABILITY:
        gm = parse_gm_request(message) if req else None
        return ("gm_capability", gm_capability_response(*gm)) if gm else ("capability", None)
    if h.id == CMD_WEARABLE_REQUEST_CAPABILITY:
        seq = capability_sequence(message) if req else None
        return ("wearable_capability", wearable_capability_response(seq)) if seq is not None \
            else ("capability", None)
    if h.id in (CMD_GM_CAPABILITY_NOTI, CMD_MOBILE_REQUEST_CAPABILITY, CMD_HOST_CAPABILITY):
        return "capability", None
    if h.id == CMD_CHECK_STATUS:
        return "check_status", CHECK_STATUS_RESPONSE if req else None
    if h.id == CMD_SYNC_DATA:
        return "sync_data", sync_data_success(message) if req else None
    if h.id == CMD_REQUEST_DATA:
        return "request_data", request_data_success(message) if req else None
    if h.id == CMD_WEARABLE_MSG:
        return "wearable_msg", WEARABLE_MSG_RESPONSE if req else None
    return f"cmd_{h.id}", None


# --- blocos grandes (id 63) ---

class LargeDataReceiver:
    """Remonta os blocos 3F e gera a confirmação 3E (09 aceito / 08 recusado)."""
    MAX_CHUNKS = 256
    MAX_BYTES = 1024 * 1024

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self._data = bytearray()
        self._next = 0

    @staticmethod
    def _ack(count: int, accepted: bool) -> bytes:
        return bytes([LARGE_DATA_ACK, 0x09 if accepted else 0x08]) + (count & 0xFFFFFFFF).to_bytes(4, "little")

    def accept(self, message: bytes) -> tuple[bytes | None, bytes | None] | None:
        """None se não for bloco; senão (payload completo ou None, confirmação ou None)."""
        if not message or (message[0] & 0x3F) != LARGE_DATA_CHUNK:
            return None
        if len(message) < 6:
            self.reset()
            return None, self._ack(0, False)
        flag = message[1] & 0x03
        number = struct.unpack_from("<I", message, 2)[0]
        if flag == 0 and number == 0:
            self.reset()
        if (flag > 2 or (flag == 0) != (number == 0) or number != self._next
                or self._next >= self.MAX_CHUNKS or len(self._data) + len(message) - 6 > self.MAX_BYTES):
            self.reset()
            return None, self._ack(number, False)
        self._data += message[6:]
        self._next += 1
        if flag != 2:
            return None, None
        payload, count = bytes(self._data), self._next
        self.reset()
        return payload, self._ack(count, True)


# --- dados ---

@dataclass(frozen=True)
class StepBin:
    start: int          # ms
    end: int            # ms
    count: int
    walk: int
    run: int
    distance_m: float
    calories: float
    duration_ms: int


@dataclass(frozen=True)
class Vital:
    type: int
    start: int | None
    end: int | None
    value: int | None
    min: int | None
    max: int | None
    score: int | None
    uuid: str | None

    @property
    def measured_at(self) -> int | None:
        return self.end if self.end is not None else self.start


@dataclass(frozen=True)
class SleepStage:
    sleep_id: str
    start: int
    end: int
    kind: int


def _is_sync(message: bytes, data_type: int) -> bool:
    return len(message) >= 6 and message[0] == 0x82 and message[2] == SEQ and message[5] == data_type


def parse_step_bins(message: bytes) -> list[StepBin] | None:
    """Tipo 7: byte 'tem mais' + 12 campos fixos por intervalo de 1 minuto."""
    if len(message) < 8 or not _is_sync(message, DATA_STEPS):
        return None
    out: list[StepBin] = []
    i = 6
    for _ in range(128):
        if i >= len(message):
            return out or None
        more = message[i]
        i += 1
        if more not in (0, 1):
            return None
        v: dict[int, bytes] = {}
        for fid in (5, 1, 2, 3, 16, 17, 18, 19, 20, 21, 22, 23):
            width = 1 if fid == 23 else 4
            if i >= len(message) or message[i] != fid or i + 1 + width > len(message):
                return None
            v[fid] = message[i + 1:i + 1 + width]
            i += 1 + width
        start, end = band_time(v[1]), band_time(v[2])
        count = _le32(v[16], 0)
        distance = struct.unpack("<f", v[17])[0]
        calories = struct.unpack("<f", v[19])[0]
        run, walk, duration = _le32(v[20], 0), _le32(v[21], 0), _le32(v[22], 0)
        if not (0 <= count <= 100_000 and 0 <= walk <= count and 0 <= run <= count
                and 0 <= distance <= 100_000 and 0 <= calories <= 10_000 and 0 <= duration <= 86_400_000):
            return None
        if not start < end <= start + 3_600_000:
            end = start + 60_000
        out.append(StepBin(start, end, count, walk, run, distance, calories, duration))
        if more == 0:
            return out
    return None


def _field_width(data_type: int, fid: int) -> int:
    """>0 largura fixa, -1 blob com tamanho de 4 bytes, 0 desconhecido (rejeita)."""
    if fid in (1, 2, 3, 5, 151, 153):
        return 4
    table = {
        DATA_HEART_RATE: {32: 1, 33: 1, 34: 1, 35: 1, 36: -1, 37: 2},
        DATA_STRESS: {96: 1, 102: 1, 103: 1, 97: 4, 98: -1},
        DATA_SPO2: {117: 16, 169: 1, 170: 1, 171: 1, 172: 1, 173: 2, 174: 4, 175: -1},
        DATA_SLEEP: {**{f: 2 for f in range(28, 38)}, 40: 4, 80: 4, 81: 1, 83: 1, 86: 1, 82: 16, 117: 16},
    }
    return table.get(data_type, {}).get(fid, 0)


def parse_vitals(message: bytes) -> list[Vital] | None:
    """Tipos 10 (FC), 16 (sono), 19 (estresse), 112 (SpO2): registros com tamanho de 4 bytes."""
    if len(message) < 12 or message[0] != 0x82 or message[2] != SEQ:
        return None
    data_type = message[5]
    if data_type not in (DATA_HEART_RATE, DATA_SLEEP, DATA_STRESS, DATA_SPO2):
        return None
    off, out = 6, []
    for _ in range(128):
        if off + 5 > len(message):
            return None
        more = message[off]
        off += 1
        if more not in (0, 1):
            return None
        length = _le32(message, off)
        off += 4
        if not 0 < length <= 65_536 or off + length > len(message):
            return None
        fields: dict[int, bytes] = {}
        p, end = off, off + length
        while p < end:
            fid = message[p]
            p += 1
            width = _field_width(data_type, fid)
            if width == 0:
                return None
            if width < 0:
                if p + 4 > end:
                    return None
                blob = _le32(message, p)
                p += 4
                if not 0 <= blob <= 65_536 or p + blob > end:
                    return None
                p += blob
            else:
                if p + width > end:
                    return None
                fields[fid] = message[p:p + width]
                p += width
        value_id, min_id, max_id = {DATA_HEART_RATE: (32, 33, 34), DATA_STRESS: (96, 102, 103),
                                    DATA_SPO2: (169, 171, 172)}.get(data_type, (None, None, None))
        byte = lambda fid: fields[fid][0] if fid in fields else None  # noqa: E731
        out.append(Vital(
            type=data_type,
            start=band_time(fields[1]) if 1 in fields else None,
            end=band_time(fields[2]) if 2 in fields else None,
            value=byte(value_id), min=byte(min_id), max=byte(max_id),
            score=byte(83) if data_type == DATA_SLEEP else None,
            uuid=fields[117].hex() if 117 in fields else None))
        off = end
        if more == 0:
            return out
    return None


def parse_sleep_stages(message: bytes) -> list[SleepStage] | None:
    """Tipo 17: oito campos fixos por estágio, sem tamanho prefixado."""
    if len(message) < 6 or not _is_sync(message, DATA_SLEEP_STAGE):
        return None
    off, out = 6, []
    for _ in range(10_000):
        if off >= len(message):
            return None
        more = message[off]
        off += 1
        if more not in (0, 1):
            return None
        fields: dict[int, bytes] = {}
        for _ in range(8):
            if off >= len(message):
                return None
            fid = message[off]
            off += 1
            width = {1: 4, 2: 4, 3: 4, 5: 4, 82: 4, 151: 4, 153: 4, 85: 16}.get(fid)
            if width is None or fid in fields or off + width > len(message):
                return None
            fields[fid] = message[off:off + width]
            off += width
        if not all(k in fields for k in (1, 2, 82, 85)):
            return None
        out.append(SleepStage(fields[85].hex(), band_time(fields[1]), band_time(fields[2]),
                              _le32(fields[82], 0)))
        if more == 0:
            return out
    return None


def steps_for_day(bins: list[StepBin], day, tz) -> int:
    """Soma os passos dos intervalos que começam no dia local `day` (datetime.date)."""
    return sum(b.count for b in bins
               if datetime.fromtimestamp(b.start / 1000, tz).date() == day)


def local_tz(offset_hours: float) -> timezone:
    return timezone(timedelta(hours=offset_hours))
