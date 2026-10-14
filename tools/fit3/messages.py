"""Mensagens SAMessageData (camada acima do transporte SAP) usadas pelo Galaxy Fit3.

Formato confirmado em com.samsung.wearable.hostmanager.message.SAMessageData:
  byte 0  = formato << 7 | tipo << 6 | id   (formato 0 fixo / 1 variável; tipo 0 pedido / 1 resposta)
  formato variável: byte 1 = número de parâmetros
  parâmetro = id + valor; inteiros little-endian (byte 1, short 2, int 4, long 8);
  string = 1 byte de tamanho + UTF-8 (máx. 255)
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import datetime, timezone

FORMAT_FIXED, FORMAT_VARIABLE = 0, 1
TYPE_REQUEST, TYPE_RESPONSE = 0, 1


def header(fmt: int, typ: int, msg_id: int) -> int:
    return (fmt << 7) | (typ << 6) | msg_id


@dataclass(frozen=True)
class Header:
    fmt: int
    typ: int
    id: int


def parse_header(message: bytes) -> Header | None:
    if not message:
        return None
    b = message[0]
    return Header((b >> 7) & 1, (b >> 6) & 1, b & 0x3F)


def p_byte(pid: int, value: int) -> bytes:
    return bytes([pid, value & 0xFF])


def p_short(pid: int, value: int) -> bytes:
    return bytes([pid]) + (value & 0xFFFF).to_bytes(2, "little")


def p_int(pid: int, value: int) -> bytes:
    return bytes([pid]) + (value & 0xFFFFFFFF).to_bytes(4, "little")


def p_long(pid: int, value: int) -> bytes:
    return bytes([pid]) + (value & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "little")


def utf8_prefix(text: str, max_bytes: int) -> bytes:
    """Trunca em no máximo max_bytes de UTF-8 sem cortar um caractere ao meio."""
    out = bytearray()
    for ch in text:
        enc = ch.encode("utf-8")
        if len(out) + len(enc) > max_bytes:
            break
        out += enc
    return bytes(out)


def p_str(pid: int, text: str, max_bytes: int = 255) -> bytes:
    raw = utf8_prefix(text, min(max_bytes, 255))
    return bytes([pid, len(raw)]) + raw


def now_millis() -> int:
    return int(time.time() * 1000)


# --- Serviço 1: OOBE (configuração inicial / hora) ---

class Oobe:
    WATCH_INFO = bytes([0x01, 0x04, 0x02, 0, 0, 0, 0x05, 0, 0x0E])
    DEVICE_STATUS = bytes([0x02, 0x01, 0x00])
    USER_AGREEMENT = bytes([0x84, 0x01, 0x01])

    @staticmethod
    def init_settings(locale_id: int, when: datetime | None = None, hour24: bool = True) -> bytes:
        """Mensagem 3: idioma, roaming, hora (epoch ASCII), fuso, formato 24h. Também sincroniza a hora."""
        when = when or datetime.now().astimezone()
        offset = int(when.utcoffset().total_seconds()) if when.utcoffset() else 0
        epoch = str(int(when.timestamp())).encode("ascii")
        return (bytes([0x83]) + p_short(1, locale_id) + p_byte(2, 0)
                + bytes([3, len(epoch)]) + epoch
                + bytes([4, 1 if offset < 0 else 0]) + abs(offset).to_bytes(2, "little")
                + p_byte(5, 1 if hour24 else 0))

    @staticmethod
    def response_id(message: bytes) -> int | None:
        return message[0] & 0x3F if message and 0x41 <= message[0] <= 0x44 else None


def find_firmware(message: bytes) -> str | None:
    import re
    m = re.search(rb"R390[A-Z0-9]{7,12}", message)
    return m.group().decode() if m else None


# --- Serviço 11: configurações completas (bateria, idioma) ---

class Settings:
    BATTERY_REQUEST = bytes([0x02])

    @staticmethod
    def language(locale_id: int) -> bytes:
        return bytes([0x01]) + p_short(4, locale_id)

    @staticmethod
    def parse_battery(message: bytes) -> tuple[int, bool] | None:
        h = parse_header(message)
        if not h or h.typ != TYPE_RESPONSE or h.id != 2:
            return None
        level = charging = None
        # Parâmetros de 1 byte em pares (id, valor): 5 = nível 0-100, 6 = modo de carga 0-3.
        for i in range(1, len(message) - 1, 2):
            if message[i] == 5 and message[i + 1] <= 100:
                level = message[i + 1]
            elif message[i] == 6 and message[i + 1] <= 3:
                charging = message[i + 1]
        if level is None or charging is None:
            # Ressincroniza se algum campo extra tiver largura diferente.
            for i in range(1, len(message) - 1):
                if message[i] == 5 and message[i + 1] <= 100 and level is None:
                    level = message[i + 1]
                elif message[i] == 6 and message[i + 1] <= 3 and charging is None:
                    charging = message[i + 1]
        return (level, charging != 0) if level is not None and charging is not None else None


# --- Serviço 7: notificações ---

class Notification:
    NEW_POPUP, DELETE_FROM_MOBILE, DELETE_FROM_BAND = 0, 1, 2
    SHOW_ON_PHONE, NEW_SILENT, CLEAR_ALL_FROM_MOBILE, CLEAR_ALL_FROM_BAND = 4, 5, 8, 9
    ICON_CAPABILITY_REQUEST = bytes([0x0D])

    @staticmethod
    def new(seq: int, title: str, body: str, app_name: str, package: str, app_id: int,
            millis: int | None = None, popup: bool = True, category: str | None = None) -> bytes:
        if seq <= 0:
            raise ValueError("sequência precisa ser > 0")
        body_raw = utf8_prefix(body, 100)
        params = [
            p_byte(0, 1),                                  # tipo: normal
            p_int(1, seq),                                 # sequência
            p_str(6, str(app_id)),                         # id do app (texto)
            p_long(2, millis if millis is not None else now_millis()),
            p_str(3, title, 60),
            bytes([4]) + len(body_raw).to_bytes(2, "little") + body_raw,  # corpo: tamanho de 2 bytes
            p_str(14, app_name, 60),
            p_byte(15, 1),
            p_byte(16, 0),
        ]
        if category:
            params.append(p_str(12, category, 60))
        params.append(p_str(18, package, 60))
        return bytes([0x80 | (Notification.NEW_POPUP if popup else Notification.NEW_SILENT),
                      len(params)]) + b"".join(params)

    @staticmethod
    def delete(seq: int) -> bytes:
        return bytes([Notification.DELETE_FROM_MOBILE]) + p_int(1, seq)

    @staticmethod
    def parse_ack(message: bytes) -> tuple[int, bool] | None:
        if len(message) == 8 and message[0] == 0x40 and message[1] == 1 and message[6] == 11:
            return int.from_bytes(message[2:6], "little", signed=True), message[7] == 1
        return None


# --- Serviço 3: chamadas (com.samsung.wearable.providers.sacall.message.CallPacketConstructor) ---

class Call:
    IDLE, RINGING, OFFHOOK = 0, 1, 2
    AGENT_NAME = "com.samsung.android.providers.sacall.SACallHandlerService"
    BAND_ACTIONS = {1: "silenciar", 4: "mostrar no celular", 5: "rejeitar", 9: "sincronizar perdidas",
                    13: "retornar ligação", 14: "rejeitar com mensagem", 15: "limpar perdidas"}

    @staticmethod
    def enable_notification(on: bool = True) -> bytes:
        return bytes([0x08, 1 if on else 0])

    @staticmethod
    def state(value: int) -> bytes:
        return bytes([0x03, value])

    @staticmethod
    def contact(name: str, number: str, millis: int | None = None, video: bool = False,
                dnd_exception: bool = False) -> bytes:
        if name == number:
            name = ""
        return (bytes([0x82, 7])
                + p_byte(0, 0 if video else 1)
                + p_int(7, 1)
                + p_str(5, Call.AGENT_NAME)
                + p_long(6, millis if millis is not None else now_millis())
                + p_str(4, name, 127)
                + p_str(3, number, 127)
                + p_byte(9, 1 if dnd_exception else 0))

    @staticmethod
    def missed(name: str, number: str, millis: int | None = None, alert: bool = True) -> bytes:
        if name == number:
            name = ""
        return (bytes([0x80 | (6 if alert else 10), 3])
                + p_str(4, name, 127) + p_str(3, number, 127)
                + p_long(6, millis if millis is not None else now_millis()))


# --- Serviço 9: música (com.samsung.wearable.providers.samusic.message.SMediaMessageContracts) ---

class Media:
    # pulseira -> celular
    REQ_MEDIA_CHANGED, REQ_METADATA, REQ_PLAYBACK_STATE, REQ_REMOTE_CONTROL = 1, 2, 3, 4
    REQ_CAPABILITY, REQ_VOLUME_INFO, REQ_VOLUME_CONTROL, REQ_APP_INFO, REQ_QUEUE = 5, 6, 7, 8, 9
    REQ_SKIP_TO_ITEM = 16
    # celular -> pulseira
    RSP_METADATA, RSP_PLAYBACK_STATE, RSP_CAPABILITY, RSP_VOLUME_INFO = 17, 18, 20, 21
    RSP_APP_INFO, RSP_MEDIA_CHANGED, RSP_APP_COUNT, RSP_QUEUE = 22, 23, 24, 25

    STOPPED, PAUSED, PLAYING = 1, 2, 3
    REMOTE_ACTIONS = {1: "stop", 2: "play_pause", 3: "previous", 4: "next"}
    VOLUME_ACTIONS = {1: "set", 2: "up", 3: "down", 4: "mute_on", 5: "mute_off"}
    KEY_RELEASED, KEY_PRESSED = 1, 2

    @staticmethod
    def request_id(message: bytes) -> int | None:
        h = parse_header(message)
        return h.id if h and h.typ == TYPE_REQUEST else None

    @staticmethod
    def parse_remote(message: bytes) -> tuple[str, bool] | None:
        """(ação, pressionado). Um toque gera 'solto' e 'pressionado': só aja no pressionado."""
        if Media.request_id(message) != Media.REQ_REMOTE_CONTROL:
            return None
        action, key = None, Media.KEY_PRESSED
        for i in range(1, len(message) - 1, 2):
            if message[i] == 1:
                action = Media.REMOTE_ACTIONS.get(message[i + 1])
            elif message[i] == 2:
                key = message[i + 1]
        return (action, key == Media.KEY_PRESSED) if action else None

    @staticmethod
    def parse_volume(message: bytes) -> tuple[str, int | None] | None:
        if (Media.request_id(message) != Media.REQ_VOLUME_CONTROL or len(message) < 3
                or message[1] != 1 or message[2] not in Media.VOLUME_ACTIONS):
            return None
        value = None
        i = 3
        while i + 1 < len(message):
            if message[i] == 2:  # valor opcional: int32 LE, ou 1 byte em pacotes curtos
                value = (int.from_bytes(message[i + 1:i + 5], "little") if i + 5 <= len(message)
                         else message[i + 1])
                break
            i += 2
        return Media.VOLUME_ACTIONS[message[2]], value

    @staticmethod
    def screen_state(message: bytes) -> int | None:
        """Tela de música da pulseira: 0 fechada, 1 visível, 2 always-on."""
        if Media.request_id(message) != Media.REQ_MEDIA_CHANGED or len(message) < 3 or message[1] != 1:
            return None
        return message[2] if message[2] <= 2 else None

    @staticmethod
    def requested_app_id(message: bytes) -> str | None:
        h = parse_header(message)
        if not h or h.typ != TYPE_REQUEST:
            return None
        off = 2 if h.fmt == FORMAT_VARIABLE else 1
        if len(message) < off + 2 or message[off] != 1 or off + 2 + message[off + 1] > len(message):
            return None
        return message[off + 2:off + 2 + message[off + 1]].decode("utf-8", "replace")

    # As respostas "fixas" do agente 9 levam o número de parâmetros (igual ao Builder da Samsung).
    @staticmethod
    def _fixed(msg_id: int, *params: bytes) -> bytes:
        return bytes([header(FORMAT_FIXED, TYPE_RESPONSE, msg_id), len(params)]) + b"".join(params)

    @staticmethod
    def _variable(msg_id: int, *params: bytes) -> bytes:
        return bytes([header(FORMAT_VARIABLE, TYPE_RESPONSE, msg_id), len(params)]) + b"".join(params)

    @staticmethod
    def capability(max_volume: int, warning_volume: int) -> bytes:
        return Media._fixed(Media.RSP_CAPABILITY, p_int(1, max_volume), p_int(2, warning_volume))

    @staticmethod
    def volume_info(volume: int, headset: bool = True) -> bytes:
        return Media._fixed(Media.RSP_VOLUME_INFO, p_int(1, volume), p_byte(2, 2 if headset else 1))

    @staticmethod
    def media_changed(screen_state: int) -> bytes:
        return Media._fixed(Media.RSP_MEDIA_CHANGED, p_byte(1, screen_state))

    @staticmethod
    def app_count(app_id: str) -> bytes:
        """Anuncia se há um player ativo (antes dos metadados, senão a pulseira ignora a faixa)."""
        return Media._variable(Media.RSP_APP_COUNT, p_byte(1, 1 if app_id else 0), p_str(2, app_id))

    @staticmethod
    def metadata(title: str, artist: str, duration_ms: int, app_id: str, artwork: str = "") -> bytes:
        return Media._variable(Media.RSP_METADATA, p_long(1, duration_ms), p_str(2, title, 100),
                               p_str(3, artist, 100), p_str(4, artwork), p_str(5, app_id))

    @staticmethod
    def playback_state(state: int, position_ms: int, app_id: str, active_item: int = -1) -> bytes:
        return Media._variable(Media.RSP_PLAYBACK_STATE, p_byte(1, state), p_long(2, position_ms),
                               p_long(4, active_item), p_str(3, app_id))

    @staticmethod
    def app_info(app_id: str, title: str, icon: str = "") -> bytes:
        return Media._variable(Media.RSP_APP_INFO, p_str(1, app_id), p_str(2, title, 100), p_str(3, icon))

    @staticmethod
    def empty_queue(app_id: str, title: str) -> bytes:
        return Media._variable(Media.RSP_QUEUE, p_str(1, app_id), p_str(2, title, 100),
                               p_int(3, 0), p_str(4, ""))


# --- IDs de idioma da pulseira (com.samsung.wearable.hostmanager.utils.LocaleUtils) ---

BAND_LOCALES = {
    "ar": 0, "az-AZ": 2, "bg": 4, "bs": 7, "ca": 8, "cs": 9, "da": 10, "de": 11, "el": 12,
    "en": 13, "en-US": 100, "en-CA": 77, "en-PH": 78, "es-ES": 14, "es-US": 83, "es-MX": 83,
    "fi": 18, "fr": 20, "fr-CA": 84, "hi": 24, "hr": 25, "hu": 26, "id": 28, "it": 30,
    "he": 31, "ja": 32, "ko": 37, "lt": 40, "lv": 41, "nb": 49, "nl": 51, "pl": 54,
    "pt-BR": 82, "pt-PT": 55, "ro": 56, "ru": 57, "sk": 59, "sl": 60, "sr": 62, "sv": 63,
    "th": 68, "tr": 69, "uk": 71, "vi": 73, "zh-CN": 96, "zh-HK": 80, "zh-TW": 81,
}


def band_locale_id(tag: str) -> int:
    parts = tag.replace("_", "-").split("-")
    lang = parts[0].lower()
    if len(parts) > 1 and f"{lang}-{parts[-1].upper()}" in BAND_LOCALES:
        return BAND_LOCALES[f"{lang}-{parts[-1].upper()}"]
    if lang in BAND_LOCALES:
        return BAND_LOCALES[lang]
    for key in sorted(BAND_LOCALES):
        if key.startswith(lang + "-"):
            return BAND_LOCALES[key]
    return BAND_LOCALES["en"]


def utc_datetime(epoch: int, offset_seconds: int) -> datetime:
    from datetime import timedelta
    return datetime.fromtimestamp(epoch, timezone(timedelta(seconds=offset_seconds)))
