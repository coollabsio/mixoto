import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import wave

spec = importlib.util.spec_from_file_location("delay", Path(__file__).with_name("measure-delay.py"))
delay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delay)


class DelayTests(unittest.TestCase):
    def recording(self, path, offset=1800, missing=False, silent=False):
        rate = 48000
        samples = [0] * (rate * 7 * 2)
        if not silent:
            for i in range(1, 7):
                samples[i * rate * 2] = 16000
                if not (missing and i == 4):
                    samples[(i * rate + offset) * 2 + 1] = 10000
        with wave.open(str(path), "wb") as output:
            output.setparams((2, 2, rate, 0, "NONE", "not compressed"))
            output.writeframes(struct.pack(f"<{len(samples)}h", *samples))

    def test_known_delay(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.wav"
            self.recording(path)
            result = delay.measure(path)
            self.assertEqual(result["median_ms"], 37.5)
            self.assertEqual(result["p95_ms"], 37.5)
            self.assertEqual(result["pulse_count"], 6)

    def test_reject_missing_return(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.wav"
            self.recording(path, missing=True)
            with self.assertRaises(ValueError):
                delay.measure(path)

    def test_reject_silence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.wav"
            self.recording(path, silent=True)
            with self.assertRaises(ValueError):
                delay.measure(path)

    def test_reject_negative_delay(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.wav"
            self.recording(path, offset=-200)
            with self.assertRaises(ValueError):
                delay.measure(path)


if __name__ == "__main__":
    unittest.main()
