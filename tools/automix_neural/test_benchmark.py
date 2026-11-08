import os
import pathlib
import tempfile
import unittest

import numpy as np
import benchmark


class BenchTests(unittest.TestCase):
    def test_peaks_and_plateau(self):
        self.assertEqual(benchmark.peaks(np.array([-2, -1, 2, 2, -1, -2, -3, -2, 4, -1])), [0.05, 0.16])
        self.assertEqual(benchmark.peaks(np.array([-1., 0., -1.])), [])

    def test_scoring_does_not_double_count(self):
        result = benchmark.score([1.0, 2.0], [1.01, 1.02, 3.0])
        self.assertEqual((result['matched'], result['false_positives'], result['misses']), (1, 2, 1))

    def test_input_validation_and_model_integrity(self):
        with self.assertRaises(ValueError):
            benchmark.predict(np.array([np.nan], dtype=np.float32), None, None)
        with tempfile.TemporaryDirectory() as directory:
            (pathlib.Path(directory) / 'mel_spectrogram.onnx').write_bytes(b'wrong')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                benchmark.load_models(directory)

    @unittest.skipUnless(os.environ.get('AUTOMIX_BEAT_MODEL_DIR'), 'optional ONNX models not supplied')
    def test_model_synthetic_smoke(self):
        models = benchmark.load_models(os.environ['AUTOMIX_BEAT_MODEL_DIR'])
        samples, beats, downbeats = benchmark.click_track()
        found_beats, found_downbeats = benchmark.predict(samples, *models)
        self.assertGreaterEqual(benchmark.score(beats, found_beats)['matched'], 20)
        # This deliberately catches known over-detection, not model quality on music.
        self.assertGreaterEqual(benchmark.score(downbeats, found_downbeats)['false_positives'], 6)
        self.assertEqual(benchmark.predict(np.zeros(12*benchmark.RATE, dtype=np.float32), *models), ([], []))


if __name__ == '__main__':
    unittest.main()
