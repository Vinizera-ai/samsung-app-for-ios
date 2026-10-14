"""Vetores de pulseiras AZA3 reais (via Fit3-App) e regras do plugin oficial."""
import struct
import unittest
from datetime import date, datetime, timezone

from fit3 import health as H
from fit3 import sap


def le4(v: int) -> bytes:
    return struct.pack("<i", v)


def band_ts(ms: int) -> bytes:
    return le4(ms // 1000 - H.EPOCH_1990)


def iso_ms(s: str) -> int:
    return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000)


def vital_packet(data_type: int, *fields: bytes) -> bytes:
    record = b"".join(fields)
    return bytes([0x82, 3, 0xE0, 1, 0, data_type, 0]) + le4(len(record)) + record + bytes([5, 0])


def field(fid: int, value: bytes) -> bytes:
    return bytes([fid]) + value


CAPTURED_STEPS = bytes.fromhex(
    "82 03 E0 19 27 07 01 "
    "05 30 8F 19 45 01 F4 8E 19 45 02 30 8F 19 45 03 80 C8 A4 00 "
    "10 08 00 00 00 11 E0 16 F2 40 12 67 67 EB 3E 13 F2 19 E0 3E "
    "14 00 00 00 00 15 08 00 00 00 16 C8 1B 00 00 17 03 00 "
    "05 E4 8F 19 45 01 A8 8F 19 45 02 E4 8F 19 45 03 80 C8 A4 00 "
    "10 15 00 00 00 11 E0 A6 67 41 12 C3 02 EE 3F 13 13 50 A4 3F "
    "14 00 00 00 00 15 15 00 00 00 16 E0 38 00 00 17 03 00".replace(" ", ""))

BETA15_STEPS = bytes.fromhex((
    "82 03 E0 33 27 07 01 05 30 8F 19 45 01 F4 8E 19 45 02 30 8F 19 45 03 80 "
    "CB A4 00 10 0B 00 00 00 11 50 16 F2 40 12 57 67 E8 3E 13 F2 19 E0 3E 14 "
    "00 00 00 00 15 0B 00 00 00 16 58 1B 00 00 17 03 01 05 E4 8F 19 45 01 A8 "
    "8F 19 45 02 E4 8F 19 45 03 80 CB A4 00 10 15 00 00 00 11 E0 A6 67 41 12 "
    "C3 62 5E 3F 13 13 50 44 3F 14 00 00 00 00 15 15 00 00 00 16 B0 36 00 00 "
    "17 03 01 05 24 9B 19 45 01 E8 9A 19 45 02 24 9B 19 45 03 80 CB A4 00 10 "
    "0B 00 00 00 11 0F 0D 07 41 12 23 A6 01 3F 13 CA 60 C7 3E 14 00 00 00 00 "
    "15 0B 00 00 00 16 58 1B 00 00 17 03 00 05 D4 9F 19 45 01 98 9F 19 45 02 "
    "D4 9F 19 45 03 80 CB A4 00 10 18 00 00 00 11 45 9A 88 41 12 76 23 83 3F "
    "13 6B 4E 64 3F 14 00 00 00 00 15 18 00 00 00 16 80 3E 00 00 17 03 05 19 "
    "01 19 02 4C 27 03 05 03 04 66 A8 19 45 05 DB A8 19 45 06 DB A8 19 45 07 00").replace(" ", ""))


class HandshakeTest(unittest.TestCase):
    def test_gm_capability_from_real_band(self):
        event, reply = H.reply_for(bytes([0xA2, 0x02, 0xE0, 0x17, 0x27, 0xE1, 0x2D, 0x01]))
        self.assertEqual(event, "gm_capability")
        self.assertEqual(reply[:2], bytes([0xE2, 6]))
        self.assertTrue(reply.endswith(bytes([0xE0, 0x17, 0x27, 0xE1, 0x2D, 0x01])))  # eco seq e proto 301

    def test_wearable_capability_echoes_sequence_and_needs_fragmentation(self):
        event, reply = H.reply_for(bytes([0xA0, 0x17, 0xE0, 0x3A, 0x27, 0xA0, 0x01, 0xA1, 0x04, 0x33, 0xA3, 0x11]))
        self.assertEqual(event, "wearable_capability")
        self.assertEqual(reply[0], 0xE0)
        self.assertEqual(reply[2:5], bytes([0xE0, 0x3A, 0x27]))
        self.assertGreater(len(reply), 500)
        self.assertGreater(len(sap.encode_message(10, reply, 500, max_frame=182)), 1)
        for _, text in H._CAPABILITY_STRINGS:          # cada JSON cabe no tamanho de 1 byte
            self.assertLessEqual(len(text.encode()), 255)

    def test_host_capability_probe(self):
        self.assertEqual(H.MOBILE_CAPABILITY_REQUEST, bytes([0x34]))

    def test_acks_preserve_sequence(self):
        for seq in (0, 255, 256, 65535):
            lo, hi = seq & 0xFF, seq >> 8
            self.assertEqual(H.reply_for(bytes([0x82, 1, 0xE0, lo, hi]))[1],
                             bytes([0x42, 2, 0xE0, lo, hi, 4, 2, 1, 1]))
            self.assertEqual(H.reply_for(bytes([3, 0xE0, lo, hi]))[1],
                             bytes([0x43, 0xE0, lo, hi, 4, 2, 1, 1]))
        self.assertIsNone(H.reply_for(bytes([0x82]))[1])
        self.assertIsNone(H.reply_for(bytes([0x03]))[1])

    def test_request_data_matches_stock_31_bytes(self):
        now = (H.EPOCH_1990 + 1_234_567) * 1000
        req = H.request_data(10001, now)
        self.assertEqual(len(req), 31)
        self.assertEqual(list(req[:14]), [3, 0xE0, 0x11, 0x27, 5, 25, 1, 0, 2, 0, 0, 3, 4, 51])
        self.assertEqual(struct.unpack_from("<i", req, 25)[0], 1_234_567)
        self.assertEqual(H.sequence(req), 10001)

    def test_check_status_and_wearable_msg(self):
        self.assertEqual(H.reply_for(bytes([0x01]))[1], bytes([0x41]))
        self.assertEqual(H.reply_for(bytes([0x04]))[1], bytes([0x44]))


class StepsTest(unittest.TestCase):
    def test_captured_intervals(self):
        bins = H.parse_step_bins(CAPTURED_STEPS)
        self.assertEqual([b.count for b in bins], [8, 21])
        self.assertEqual(sum(b.walk for b in bins), 29)
        self.assertEqual(bins[0].end - bins[0].start, 60_000)        # intervalos de 1 minuto
        self.assertAlmostEqual(bins[0].distance_m, 7.565, places=2)

    def test_beta15_trace_across_midnight(self):
        bins = H.parse_step_bins(BETA15_STEPS)
        self.assertEqual([b.count for b in bins], [11, 21, 11, 24])
        moscow = H.local_tz(3)
        self.assertEqual(H.steps_for_day(bins, date(2026, 9, 27), moscow), 35)

    def test_large_data_two_chunks_118_steps(self):
        times = ["2026-09-27T21:53:00Z", "2026-09-27T21:54:00Z", "2026-09-27T21:55:00Z", "2026-09-27T22:32:00Z"]
        payload = bytearray([0x82, 3, 0xE0, 0x6D, 0x28, 7])
        for i, steps in enumerate([23, 39, 30, 26]):
            t = iso_ms(times[i]) // 1000 - H.EPOCH_1990
            payload.append(0 if i == 3 else 1)
            for fid, v in ((5, t), (1, t), (2, t), (3, 0), (16, steps)):
                payload += field(fid, le4(v))
            payload += field(17, struct.pack("<f", steps * 0.6))
            for fid, v in ((18, 0), (19, 0), (20, 0), (21, steps), (22, 60_000)):
                payload += field(fid, le4(v))
            payload += bytes([23, 3])
        payload += bytes([0x93, 0x12, 0x68, 0x31, 0, 0])   # lixo que parece resumo: deve ser ignorado
        payload = bytes(payload)

        rx = H.LargeDataReceiver()
        chunk = lambda flag, n, body: bytes([0x3F, 0x08 | flag, n, 0, 0, 0]) + body  # noqa: E731
        self.assertEqual(rx.accept(chunk(0, 0, payload[:90])), (None, None))
        full, ack = rx.accept(chunk(2, 1, payload[90:]))
        self.assertEqual(full, payload)
        self.assertEqual(ack, bytes([0x3E, 0x09, 2, 0, 0, 0]))
        self.assertEqual(sum(b.count for b in H.parse_step_bins(full)), 118)
        self.assertEqual(H.reply_for(full)[1], bytes([0x42, 2, 0xE0, 0x6D, 0x28, 4, 2, 1, 1]))

    def test_missing_chunk_is_rejected(self):
        rx = H.LargeDataReceiver()
        rx.accept(bytes([0x3F, 0x08, 0, 0, 0, 0, 1, 2]))
        self.assertEqual(rx.accept(bytes([0x3F, 0x0A, 2, 0, 0, 0, 3])), (None, bytes([0x3E, 0x08, 2, 0, 0, 0])))


class VitalsTest(unittest.TestCase):
    now = iso_ms("2026-09-27T08:00:00Z")

    def test_heart_rate(self):
        v = H.parse_vitals(vital_packet(10, field(1, band_ts(self.now - 120_000)), field(2, band_ts(self.now - 60_000)),
                                        field(32, bytes([75])), field(33, bytes([60])), field(34, bytes([90]))))[0]
        self.assertEqual((v.value, v.min, v.max, v.measured_at), (75, 60, 90, self.now - 60_000))

    def test_stress_and_spo2(self):
        stress = H.parse_vitals(vital_packet(19, field(1, band_ts(self.now)), field(96, bytes([42])),
                                             field(102, bytes([20])), field(103, bytes([70]))))[0]
        spo2 = H.parse_vitals(vital_packet(112, field(1, band_ts(self.now)), field(169, bytes([97])),
                                           field(170, bytes([78]))))[0]
        self.assertEqual((stress.value, stress.min, spo2.value), (42, 20, 97))

    def test_sleep_episode_and_score(self):
        end = self.now - 60_000
        v = H.parse_vitals(vital_packet(16, field(1, band_ts(end - 440 * 60_000)), field(2, band_ts(end)),
                                        field(83, bytes([82]))))[0]
        self.assertEqual(((v.end - v.start) // 60_000, v.score), (440, 82))

    def test_malformed_length_rejected(self):
        pkt = bytearray(vital_packet(112, field(1, band_ts(self.now)), field(169, bytes([98]))))
        pkt[7] = 0x7F
        self.assertIsNone(H.parse_vitals(bytes(pkt)))

    def test_sleep_stages(self):
        start, end = iso_ms("2026-10-02T23:00:00Z"), iso_ms("2026-10-03T07:00:00Z")
        pkt = (bytes([0x82, 3, 0xE0, 1, 0, 17, 0]) + field(1, band_ts(start)) + field(2, band_ts(end))
               + field(3, le4(0)) + field(5, band_ts(end)) + field(82, le4(H.SLEEP_DEEP))
               + field(85, bytes([1] * 16)) + field(151, le4(1)) + field(153, le4(1)))
        stage = H.parse_sleep_stages(pkt)[0]
        self.assertEqual((stage.start, stage.end, stage.kind, stage.sleep_id), (start, end, H.SLEEP_DEEP, "01" * 16))
        self.assertIsNone(H.parse_sleep_stages(pkt[:-1]))
        bad = bytearray(pkt)
        bad[7] = 99
        self.assertIsNone(H.parse_sleep_stages(bytes(bad)))


if __name__ == "__main__":
    unittest.main()
