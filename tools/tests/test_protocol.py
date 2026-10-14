"""Testes com vetores reais capturados da pulseira e regras do código oficial da Samsung."""
import unittest
from datetime import datetime, timedelta, timezone

from fit3 import sap
from fit3.messages import Call, Notification, Oobe, Settings, band_locale_id, find_firmware


class CrcTest(unittest.TestCase):
    def test_crc16_arc_check_value(self):
        # Valor de verificação padrão do CRC-16/ARC.
        self.assertEqual(sap.crc16(b"123456789"), 0xBB3D)

    def test_matches_samsung_table_head(self):
        # Primeiras entradas de SAFrameworkUtils.CHECKSUM_TABLE: 0, 49345, 49537, 320.
        self.assertEqual([sap.crc16(bytes([i])) for i in range(4)], [0, 49345, 49537, 320])


class FrameTest(unittest.TestCase):
    def test_watch_info_frame_matches_live_vector(self):
        frames = sap.encode_message(sap.Agent.OOBE, Oobe.WATCH_INFO, mtu=500)
        self.assertEqual(frames, [bytes.fromhex("000dc5c10040010101040200000005000e60ea")])
        frag = sap.decode_frame(frames[0])
        self.assertEqual((frag.kind, frag.service, frag.payload), (0, 1, Oobe.WATCH_INFO))

    def test_short_prefix_below_256(self):
        frame = sap.encode_message(11, Settings.BATTERY_REQUEST, mtu=200)[0]
        self.assertEqual(frame[:2], bytes([5, 5]))
        self.assertEqual(sap.decode_frame(frame).payload, Settings.BATTERY_REQUEST)

    def test_bad_crc_rejected(self):
        frame = bytearray(sap.encode_message(6, b"\x02", mtu=500)[0])
        frame[-1] ^= 1
        with self.assertRaises(sap.SapError):
            sap.decode_frame(bytes(frame))

    def test_fragmentation_roundtrip(self):
        message = bytes(range(256)) * 4
        for mtu, max_frame in ((500, None), (500, 182), (200, None)):
            frames = sap.encode_message(7, message, mtu=mtu, max_frame=max_frame)
            self.assertGreater(len(frames), 1)
            self.assertTrue(all(len(f) <= (max_frame or mtu) for f in frames))
            r = sap.Reassembler()
            results = [r.push(sap.decode_frame(f)) for f in frames]
            self.assertTrue(all(x is None for x in results[:-1]))
            self.assertEqual(results[-1], (7, message))

    def test_out_of_order_fragment_dropped(self):
        frames = sap.encode_message(7, bytes(900), mtu=500, max_frame=182)
        r = sap.Reassembler()
        r.push(sap.decode_frame(frames[0]))
        self.assertIsNone(r.push(sap.decode_frame(frames[2])))
        self.assertIsNone(r.push(sap.decode_frame(frames[-1])))


class HandshakeTest(unittest.TestCase):
    def test_capability_reply_only_changes_opcode(self):
        req = bytearray(105)
        req[0], req[1], req[0x2C], req[0x2D] = 104, 0x14, 0x01, 0xF4
        self.assertTrue(sap.is_capability_request(bytes(req)))
        self.assertEqual(sap.transport_mtu(bytes(req)), 500)
        resp = sap.capability_response(bytes(req))
        self.assertEqual(resp[1], 0x15)
        self.assertEqual(resp[:1] + resp[2:], bytes(req[:1] + req[2:]))


class MessageTest(unittest.TestCase):
    def test_init_settings_vector(self):
        # 2023-11-14 22:13:20Z, Moscou (UTC+3), idioma 57.
        when = datetime(2023, 11, 15, 1, 13, 20, tzinfo=timezone(timedelta(hours=3)))
        self.assertEqual(Oobe.init_settings(57, when).hex(),
                         "830139000200030a313730303030303030300400302a0501")

    def test_negative_offset(self):
        when = datetime(2023, 11, 14, 19, 13, 20, tzinfo=timezone(timedelta(hours=-3)))
        msg = Oobe.init_settings(82, when)
        self.assertEqual(msg[1:4], bytes([1, 82, 0]))
        self.assertEqual(msg[-6:-2], bytes([4, 1, 0x30, 0x2A]))

    def test_battery(self):
        self.assertEqual(Settings.parse_battery(bytes.fromhex("42053a0600")), (58, False))
        self.assertEqual(Settings.parse_battery(bytes.fromhex("4205640601")), (100, True))
        self.assertIsNone(Settings.parse_battery(bytes.fromhex("02053a0600")))

    def test_notification_layout(self):
        msg = Notification.new(7, "Oi", "Mensagem", "Teste", "com.example", 20, millis=1, category="msg")
        self.assertEqual(msg[:2], bytes([0x80, 11]))
        self.assertIn(bytes([4, 8, 0]) + b"Mensagem", msg)          # corpo com tamanho de 2 bytes
        self.assertIn(bytes([1, 7, 0, 0, 0]), msg)                   # sequência int32 LE
        self.assertTrue(msg.endswith(bytes([18, 11]) + b"com.example"))
        self.assertEqual(Notification.parse_ack(bytes.fromhex("400107000000" "0b01")), (7, True))

    def test_utf8_truncation_keeps_whole_chars(self):
        msg = Notification.new(1, "ç" * 40, "x", "a", "p", 20, millis=0)
        title = msg[msg.index(bytes([3])) + 2:]
        self.assertEqual(msg[msg.index(bytes([3])) + 1], 60)
        self.assertTrue(title[:60].decode("utf-8"))

    def test_call_contact_matches_official_builder(self):
        agent = Call.AGENT_NAME.encode()
        expected = (bytes([0x82, 7, 0, 1, 7, 1, 0, 0, 0, 5, len(agent)]) + agent
                    + bytes([6]) + (1700000000000).to_bytes(8, "little")
                    + bytes([4, 3]) + b"Ana" + bytes([3, 4]) + b"1234" + bytes([9, 0]))
        self.assertEqual(Call.contact("Ana", "1234", millis=1700000000000), expected)
        # Nome igual ao número é enviado vazio (igual ao plugin oficial).
        self.assertIn(bytes([4, 0, 3, 4]) + b"1234", Call.contact("1234", "1234", millis=0))

    def test_call_state_and_missed(self):
        self.assertEqual(Call.state(Call.RINGING), bytes([3, 1]))
        self.assertEqual(Call.enable_notification(), bytes([8, 1]))
        self.assertEqual(Call.missed("", "99", millis=0)[:2], bytes([0x86, 3]))

    def test_locale_ids(self):
        self.assertEqual(band_locale_id("pt-BR"), 82)
        self.assertEqual(band_locale_id("pt_BR"), 82)
        self.assertEqual(band_locale_id("en-GB"), 13)
        self.assertEqual(band_locale_id("xx"), 13)

    def test_firmware_string(self):
        self.assertEqual(find_firmware(b"\x41\x01..R390XXU0AZA3\x00"), "R390XXU0AZA3")


if __name__ == "__main__":
    unittest.main()
