"""Camada de transporte SAP (Samsung Accessory Protocol) do Galaxy Fit3 sobre BLE GATT.

Constantes confirmadas no código descompilado da Samsung:
  - UUIDs GATT: com.samsung.accessory.connectivity.ble.SABleConstants (DPS_SERVICE/READ/WRITE)
  - CRC-16/ARC: com.samsung.accessory.utils.SAFrameworkUtils.CHECKSUM_TABLE
  - IDs de agente: com.samsung.wearable.hostmanager.sharedlib.connection.ConnectionConstants

Formato de um quadro (uma escrita/notificação BLE == um quadro):
  quadro  = prefixo | corpo | crc16(corpo) big-endian
  prefixo = [len, len]                     se MTU de transporte < 256
          = [lenHi, lenLo, crc16(len) BE]  caso contrário
  corpo   = [flags, seq, svc, svc, payload...]  quadro único ou PRIMEIRO fragmento
          = [flags, seq, payload...]            CONTINUAÇÃO / ÚLTIMO fragmento
  flags bits 1..2 = tipo (0 único, 1 primeiro, 2 continuação, 3 último)
  seq: nibble baixo = número do fragmento, bits 5..7 = stream
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum

SERVICE_UUID = "00001a1a-0000-1000-8000-00805f9b34fb"
NOTIFY_UUID = "797ae4e9-2e58-4fe8-b48d-b5c79599fb9b"  # pulseira -> celular
WRITE_UUID = "63e30bad-4206-4596-839f-e47cbf7a4b5d"  # celular -> pulseira

CAPABILITY_LEN = 105
CAPABILITY_REQUEST = 0x14
CAPABILITY_RESPONSE = 0x15

MAX_MESSAGE = 4096
MAX_FRAGMENTS = 16

KIND_SINGLE, KIND_FIRST, KIND_CONTINUE, KIND_LAST = 0, 1, 2, 3


class Agent(IntEnum):
    """ID de serviço SAP == "agent id" da Samsung."""

    OOBE = 1
    CALL = 3
    LOCATION = 4
    WEATHER = 5
    BAND_FACE = 6
    NOTIFICATION = 7
    CALENDAR = 8
    MEDIA = 9
    HEALTH = 10
    FULL_SETTINGS = 11
    DEBUG = 12
    REMINDER = 14
    WIDGETS = 15
    QUICK_MESSAGE = 18
    QUICK_PANEL = 19
    APPS = 24
    SHARED_INFO = 26
    OTA_TRANSFER = 30


class SapError(ValueError):
    pass


def crc16(data: bytes) -> int:
    """CRC-16/ARC (polinômio 0xA001 refletido, valor inicial 0)."""
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def _crc_bytes(data: bytes) -> bytes:
    return crc16(data).to_bytes(2, "big")


# --- Handshake de capacidades (pulseira -> celular, 105 bytes, sem quadro SAP) ---

def is_capability_request(data: bytes) -> bool:
    return len(data) == CAPABILITY_LEN and data[1] == CAPABILITY_REQUEST


def capability_response(request: bytes) -> bytes:
    """A resposta é o mesmo pacote com o opcode trocado de 0x14 para 0x15."""
    if len(request) != CAPABILITY_LEN or request[0] != CAPABILITY_LEN - 1:
        raise SapError("pedido de capacidade com tamanho inválido")
    if request[1] != CAPABILITY_REQUEST:
        raise SapError("não é um pedido de capacidade")
    return request[:1] + bytes([CAPABILITY_RESPONSE]) + request[2:]


def transport_mtu(request: bytes) -> int:
    """MTU de transporte SAP anunciado pela pulseira (bytes 0x2c..0x2d, big-endian)."""
    if len(request) != CAPABILITY_LEN:
        raise SapError("pedido de capacidade com tamanho inválido")
    return (request[0x2C] << 8) | request[0x2D]


# --- Codificação ---

def _encode_body(body: bytes, mtu: int) -> bytes:
    if mtu < 256:
        if len(body) > 255:
            raise SapError("corpo grande demais para prefixo curto")
        prefix = bytes([len(body), len(body)])
    else:
        length = len(body).to_bytes(2, "big")
        prefix = length + _crc_bytes(length)
    return prefix + body + _crc_bytes(body)


def encode_message(service: int, message: bytes, mtu: int, max_frame: int | None = None,
                   stream: int = 0) -> list[bytes]:
    """Codifica uma mensagem SAP em um ou mais quadros.

    mtu: MTU de transporte anunciado pela pulseira (define o layout do prefixo).
    max_frame: maior escrita GATT possível (ATT MTU - 3); por padrão igual a mtu.
    """
    if not 1 <= service <= 31 or not message:
        raise SapError("serviço ou mensagem inválidos")
    if not 15 <= mtu <= 500:
        raise SapError(f"MTU de transporte inválido: {mtu}")
    if not 0 <= stream <= 7:
        raise SapError("stream inválido")
    limit = min(max_frame or mtu, mtu)

    prefix_size = 2 if mtu < 256 else 4
    if prefix_size + 4 + len(message) + 2 <= limit:
        return [_encode_body(bytes([0, 0x40, service, service]) + message, mtu)]

    first_cap = limit - prefix_size - 2 - 4
    cont_cap = limit - prefix_size - 2 - 2
    if first_cap <= 0 or cont_cap <= 0:
        raise SapError("MTU pequeno demais")

    frames = [_encode_body(bytes([KIND_FIRST << 1, stream << 5, service, service])
                           + message[:first_cap], mtu)]
    offset, seq = first_cap, 1
    while offset < len(message):
        if seq >= MAX_FRAGMENTS:
            raise SapError("mensagem precisa de mais de 16 fragmentos")
        chunk = message[offset:offset + cont_cap]
        offset += len(chunk)
        kind = KIND_LAST if offset >= len(message) else KIND_CONTINUE
        frames.append(_encode_body(bytes([kind << 1, (stream << 5) | seq]) + chunk, mtu))
        seq += 1
    return frames


# --- Decodificação ---

@dataclass(frozen=True)
class Fragment:
    kind: int
    sequence: int
    stream: int
    service: int | None
    payload: bytes


def decode_frame(frame: bytes) -> Fragment:
    if len(frame) < 8:
        raise SapError("quadro curto demais")
    short_ok = frame[0] == frame[1] and frame[0] + 4 == len(frame)
    long_len = (frame[0] << 8) | frame[1]
    long_ok = len(frame) >= 10 and long_len + 6 == len(frame) and frame[2:4] == _crc_bytes(frame[:2])
    if short_ok:
        prefix = 2
    elif long_ok:
        prefix = 4
    else:
        raise SapError("prefixo de quadro SAP inválido")

    body = frame[prefix:-2]
    if frame[-2:] != _crc_bytes(body):
        raise SapError("CRC do quadro SAP inválido")
    if len(body) < 2:
        raise SapError("corpo curto demais")
    flags = body[0]
    if flags >> 6:
        raise SapError("quadro de controle SAP não suportado")
    kind = (flags >> 1) & 3
    first = kind in (KIND_SINGLE, KIND_FIRST)
    if first and (len(body) < 4 or body[2] != body[3]):
        raise SapError("cabeçalho de serviço inválido")
    return Fragment(kind=kind, sequence=body[1] & 0x0F, stream=body[1] >> 5,
                    service=body[2] if first else None, payload=bytes(body[4 if first else 2:]))


class Reassembler:
    """Remonta uma mensagem SAP por vez; continuações fora de ordem são descartadas."""

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self._service: int | None = None
        self._stream = -1
        self._next = 0
        self._data = bytearray()

    def push(self, frag: Fragment) -> tuple[int, bytes] | None:
        if frag.kind == KIND_SINGLE:
            self.reset()
            return (frag.service, frag.payload) if frag.service is not None else None
        if frag.kind == KIND_FIRST:
            self.reset()
            if frag.sequence != 0 or frag.service is None:
                return None
            self._service, self._stream, self._next = frag.service, frag.stream, 1
            self._data += frag.payload
            return None
        if (self._service is None or frag.stream != self._stream or frag.sequence != self._next
                or len(self._data) + len(frag.payload) > MAX_MESSAGE):
            self.reset()
            return None
        self._data += frag.payload
        self._next += 1
        if frag.kind != KIND_LAST:
            return None
        result = (self._service, bytes(self._data))
        self.reset()
        return result
