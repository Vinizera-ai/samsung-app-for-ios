"""fit3ctl — controla um Samsung Galaxy Fit3 direto do PC via Bluetooth LE.

Serve para validar o protocolo com a sua pulseira antes de instalar o app no iPhone,
e para continuar a engenharia reversa (comandos `gatt`, `sniff` e `raw`).

Exemplos:
  python fit3ctl.py scan
  python fit3ctl.py info AA:BB:CC:DD:EE:FF
  python fit3ctl.py notify AA:BB:CC:DD:EE:FF --title "Olá" --body "Teste do PC"
  python fit3ctl.py call AA:BB:CC:DD:EE:FF --name "Maria" --number "+55 11 99999-0000"
  python fit3ctl.py sniff AA:BB:CC:DD:EE:FF --seconds 120 --log captura.txt
"""
from __future__ import annotations

import argparse
import asyncio
import locale
import re
import sys
import time
from typing import Callable

try:
    from bleak import BleakClient, BleakScanner
except ImportError:  # pragma: no cover
    sys.exit("Instale as dependências: pip install -r requirements.txt")

from fit3 import sap
from fit3.messages import (Call, Notification, Oobe, Settings, band_locale_id, find_firmware,
                           parse_header)

Agent = sap.Agent
BAND_NAME = re.compile(r"fit3|galaxy fit|r390", re.IGNORECASE)


class Fit3Session:
    """Sessão SAP sobre uma conexão BLE já aberta."""

    def __init__(self, client: BleakClient, log_path: str | None = None, verbose: bool = True):
        self.client = client
        self.verbose = verbose
        self.mtu: int | None = None
        self.write_with_response = False
        self._ready = asyncio.Event()
        self._reassembler = sap.Reassembler()
        self._waiters: list[tuple[Callable[[int, bytes], bool], asyncio.Future]] = []
        self._log = open(log_path, "a", encoding="utf-8") if log_path else None
        self.on_message: Callable[[int, bytes], None] | None = None

    # --- log ---

    def _trace(self, direction: str, text: str) -> None:
        line = f"{time.strftime('%H:%M:%S')} {direction} {text}"
        if self.verbose:
            print(line)
        if self._log:
            self._log.write(line + "\n")
            self._log.flush()

    @staticmethod
    def describe(service: int, message: bytes) -> str:
        try:
            name = Agent(service).name
        except ValueError:
            name = f"SVC{service}"
        h = parse_header(message)
        kind = "?" if not h else ("resp" if h.typ else "req") + f" id={h.id}"
        return f"[{name} {kind}] {message.hex()}"

    # --- conexão ---

    async def start(self, timeout: float = 15) -> None:
        service = self.client.services.get_service(sap.SERVICE_UUID)
        if service is None:
            raise RuntimeError("Serviço SAP 0x1A1A não encontrado — é mesmo um Galaxy Fit3?")
        write = service.get_characteristic(sap.WRITE_UUID)
        notify = service.get_characteristic(sap.NOTIFY_UUID)
        if write is None or notify is None:
            raise RuntimeError("Características SAP ausentes")
        self.write_with_response = "write" in write.properties
        self._trace("--", f"ATT MTU {self.client.mtu_size}, escrita "
                          f"{'com' if self.write_with_response else 'sem'} resposta")
        await self.client.start_notify(notify, self._on_notify)
        self._trace("--", "inscrito; aguardando handshake da pulseira…")
        try:
            await asyncio.wait_for(self._ready.wait(), timeout)
        except asyncio.TimeoutError:
            raise RuntimeError(
                "A pulseira não enviou o handshake. Ela pode estar conectada a outro celular — "
                "desligue o Bluetooth do outro aparelho ou resete a pulseira.") from None

    async def _write_raw(self, data: bytes) -> None:
        self._trace("TX", data.hex())
        await self.client.write_gatt_char(sap.WRITE_UUID, data, response=self.write_with_response)
        if not self.write_with_response:
            await asyncio.sleep(0.02)

    def _on_notify(self, _char, data: bytearray) -> None:
        data = bytes(data)
        if sap.is_capability_request(data):
            self.mtu = sap.transport_mtu(data)
            self._trace("RX", f"[CAPABILITY] mtu de transporte={self.mtu}")
            asyncio.get_running_loop().create_task(self._answer_capability(data))
            return
        try:
            message = self._reassembler.push(sap.decode_frame(data))
        except sap.SapError as e:
            self._trace("RX", f"(quadro inválido: {e}) {data.hex()}")
            return
        if message is None:
            return
        service, payload = message
        self._trace("RX", self.describe(service, payload))
        for pred, fut in list(self._waiters):
            if not fut.done() and pred(service, payload):
                fut.set_result(payload)
                self._waiters.remove((pred, fut))
                return
        if self.on_message:
            self.on_message(service, payload)

    async def _answer_capability(self, request: bytes) -> None:
        await self._write_raw(sap.capability_response(request))
        self._ready.set()

    # --- mensagens ---

    async def send(self, service: int, message: bytes) -> None:
        if self.mtu is None:
            raise RuntimeError("sessão SAP não iniciada")
        max_frame = max(23, self.client.mtu_size - 3)
        self._trace("..", f"enviando {self.describe(service, message)}")
        for frame in sap.encode_message(service, message, self.mtu, max_frame=max_frame):
            await self._write_raw(frame)

    async def request(self, service: int, message: bytes, expect: Callable[[int, bytes], bool],
                      timeout: float = 5) -> bytes | None:
        fut = asyncio.get_running_loop().create_future()
        self._waiters.append((expect, fut))
        await self.send(service, message)
        try:
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError:
            self._trace("!!", f"sem resposta para {self.describe(service, message)}")
            return None

    async def setup(self, locale_id: int) -> dict:
        """Sequência OOBE do plugin oficial; feita a cada conexão (também acerta a hora)."""
        def oobe(n: int):
            return lambda s, m: s == Agent.OOBE and Oobe.response_id(m) == n

        info = await self.request(Agent.OOBE, Oobe.WATCH_INFO, oobe(1))
        await self.request(Agent.OOBE, Oobe.DEVICE_STATUS, oobe(2))
        await self.request(Agent.OOBE, Oobe.init_settings(locale_id), oobe(3))
        await self.request(Agent.OOBE, Oobe.USER_AGREEMENT, oobe(4))
        await self.request(Agent.NOTIFICATION, Notification.ICON_CAPABILITY_REQUEST,
                           lambda s, m: s == Agent.NOTIFICATION and (m[0] & 0x3F) == 13)
        await self.send(Agent.CALL, Call.enable_notification(True))
        return {"firmware": find_firmware(info) if info else None}

    async def battery(self) -> tuple[int, bool] | None:
        reply = await self.request(Agent.FULL_SETTINGS, Settings.BATTERY_REQUEST,
                                   lambda s, m: s == Agent.FULL_SETTINGS
                                   and Settings.parse_battery(m) is not None)
        return Settings.parse_battery(reply) if reply else None

    def close(self) -> None:
        if self._log:
            self._log.close()


# --- comandos ---

async def cmd_scan(args) -> None:
    print(f"Procurando dispositivos BLE por {args.timeout}s…")
    found = await BleakScanner.discover(timeout=args.timeout, return_adv=True)
    rows = []
    for address, (device, adv) in found.items():
        name = adv.local_name or device.name or ""
        has_sap = any(u.lower() == sap.SERVICE_UUID for u in adv.service_uuids)
        if args.all or has_sap or BAND_NAME.search(name):
            rows.append((adv.rssi, address, name, has_sap))
    if not rows:
        print("Nenhum Galaxy Fit3 encontrado. Dicas: deixe a pulseira perto, desconecte-a de outros "
              "celulares, ou use --all para listar tudo.")
        return
    for rssi, address, name, has_sap in sorted(rows, reverse=True):
        print(f"{address}  {rssi:>4} dBm  {name or '(sem nome)'}{'  [SAP 0x1A1A]' if has_sap else ''}")


async def cmd_gatt(args) -> None:
    async with BleakClient(args.address, timeout=args.timeout) as client:
        if args.pair:
            await client.pair()
        print(f"Conectado. ATT MTU = {client.mtu_size}")
        for service in client.services:
            print(f"\nServiço {service.uuid}  ({service.description})")
            for ch in service.characteristics:
                print(f"  Característica {ch.uuid}  [{', '.join(ch.properties)}]  handle={ch.handle}")
                for d in ch.descriptors:
                    print(f"    Descritor {d.uuid}  handle={d.handle}")


async def with_session(args, action) -> None:
    locale_id = band_locale_id(args.locale)
    print(f"Conectando a {args.address}…")
    async with BleakClient(args.address, timeout=args.timeout) as client:
        if args.pair:
            print("Pareando…")
            await client.pair()
        session = Fit3Session(client, log_path=args.log, verbose=not args.quiet)
        try:
            await session.start()
            print(f"Handshake OK (MTU de transporte {session.mtu}). Configurando…")
            info = await session.setup(locale_id)
            if info["firmware"]:
                print(f"Firmware: {info['firmware']}")
            await action(session)
        finally:
            session.close()


async def cmd_info(args) -> None:
    async def run(s: Fit3Session):
        bat = await s.battery()
        print(f"Bateria: {bat[0]}%{' (carregando)' if bat[1] else ''}" if bat else "Bateria: sem resposta")
    await with_session(args, run)


async def cmd_time(args) -> None:
    async def run(_s: Fit3Session):
        print("Hora e idioma sincronizados (enviados no setup).")
    await with_session(args, run)


async def cmd_notify(args) -> None:
    async def run(s: Fit3Session):
        seq = int(time.time()) & 0x7FFFFFFF
        msg = Notification.new(seq, args.title, args.body, args.app, "com.fit3link.pc", app_id=20,
                               category=args.category)
        ack = await s.request(Agent.NOTIFICATION, msg,
                              lambda sv, m: sv == Agent.NOTIFICATION and Notification.parse_ack(m) is not None)
        result = Notification.parse_ack(ack) if ack else None
        print("Notificação aceita pela pulseira." if result and result[1]
              else f"Resposta da pulseira: {result}")
        await asyncio.sleep(1)
    await with_session(args, run)


async def cmd_call(args) -> None:
    async def run(s: Fit3Session):
        await s.send(Agent.CALL, Call.enable_notification(True))
        await s.send(Agent.CALL, Call.contact(args.name, args.number))
        await s.send(Agent.CALL, Call.state(Call.RINGING))
        print(f"Tocando por {args.seconds}s… (botões da pulseira aparecem no log)")
        s.on_message = lambda sv, m: sv == Agent.CALL and print(
            f"Pulseira pediu: {Call.BAND_ACTIONS.get(m[0] & 0x3F, m.hex())}")
        await asyncio.sleep(args.seconds)
        await s.send(Agent.CALL, Call.state(Call.IDLE))
        await asyncio.sleep(2)
        await s.send(Agent.CALL, Call.missed(args.name, args.number))
        print("Chamada encerrada e registrada como perdida.")
        await asyncio.sleep(1)
    await with_session(args, run)


async def cmd_sniff(args) -> None:
    async def run(s: Fit3Session):
        print(f"Registrando tudo que a pulseira enviar por {args.seconds}s (mexa na pulseira)…")
        await asyncio.sleep(args.seconds)
    await with_session(args, run)


async def cmd_raw(args) -> None:
    async def run(s: Fit3Session):
        await s.send(args.service, bytes.fromhex(args.hex))
        await asyncio.sleep(args.wait)
    await with_session(args, run)


def default_locale() -> str:
    tag = (locale.getlocale()[0] or "pt_BR")
    return "pt-BR" if tag.lower().startswith("portuguese_brazil") else tag


def main() -> None:
    p = argparse.ArgumentParser(description="Controle do Galaxy Fit3 via Bluetooth LE (PC)")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="procura a pulseira")
    s.add_argument("--all", action="store_true", help="lista todos os dispositivos BLE")
    s.add_argument("--timeout", type=float, default=10, help="duração do scan (s)")
    s.set_defaults(func=cmd_scan)

    def connected(name: str, help_text: str, func):
        c = sub.add_parser(name, help=help_text)
        c.add_argument("address", help="endereço Bluetooth (veja `scan`)")
        c.add_argument("--pair", action="store_true", help="pede pareamento antes (Windows)")
        c.add_argument("--locale", default=default_locale(), help="idioma da pulseira, ex.: pt-BR")
        c.add_argument("--log", help="grava TX/RX em arquivo")
        c.add_argument("--quiet", action="store_true", help="não mostra os pacotes")
        c.add_argument("--timeout", type=float, default=20, help="timeout de conexão (s)")
        c.set_defaults(func=func)
        return c

    g = sub.add_parser("gatt", help="lista serviços e características (exploração)")
    g.add_argument("address")
    g.add_argument("--pair", action="store_true")
    g.add_argument("--timeout", type=float, default=20)
    g.set_defaults(func=cmd_gatt)

    connected("info", "handshake, firmware e bateria", cmd_info)
    connected("time", "sincroniza hora e idioma", cmd_time)
    n = connected("notify", "envia uma notificação", cmd_notify)
    n.add_argument("--title", default="Fit3 Link")
    n.add_argument("--body", default="Notificação de teste enviada do PC")
    n.add_argument("--app", default="Fit3 Link")
    n.add_argument("--category", default="msg")
    c = connected("call", "simula uma chamada recebida", cmd_call)
    c.add_argument("--name", default="Chamada de teste")
    c.add_argument("--number", default="+55 11 90000-0000")
    c.add_argument("--seconds", type=float, default=10)
    sn = connected("sniff", "registra mensagens da pulseira", cmd_sniff)
    sn.add_argument("--seconds", type=float, default=60)
    r = connected("raw", "envia uma mensagem SAP crua", cmd_raw)
    r.add_argument("service", type=int, help="id do serviço/agente (ex.: 11)")
    r.add_argument("hex", help="mensagem SAMessage em hexadecimal (ex.: 02)")
    r.add_argument("--wait", type=float, default=3)

    args = p.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    try:
        asyncio.run(args.func(args))
    except KeyboardInterrupt:
        pass
    except Exception as e:  # noqa: BLE001 — mensagem amigável na linha de comando
        sys.exit(f"Erro: {e}")


if __name__ == "__main__":
    main()
