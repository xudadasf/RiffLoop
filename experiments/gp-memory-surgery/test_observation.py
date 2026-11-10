"""Check the local importer adapter only against the repository fixture."""

from copy import deepcopy
import base64
import hashlib
from io import BytesIO
from pathlib import Path
import sys
import subprocess
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'experiments/gp-semantic-probe'))
import semantic
from observation import observe, observe_semantic, semantic_observation
from archive_edit import UnsafeArchive
sys.path.insert(0, str(ROOT / 'experiments/gp-fixture-layout'))
from layout_probe import SCENARIOS, synthetic_archive
sys.path.pop(0)


class ImporterObservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = ROOT / 'RiffLoopTests/Fixtures/transport.gp'
        cls.source = cls.fixture.read_bytes()
        cls.first, cls.second = observe(cls.source, cls.source)
        with ZipFile(BytesIO(cls.source)) as source:
            cls.digest = hashlib.sha256(source.read('Content/score.gpif')).hexdigest()

    def test_local_repeated_read_and_source_are_identical(self):
        self.assertEqual(self.first, self.second)
        self.assertEqual(self.fixture.read_bytes(), self.source)
        result = semantic_observation(self.first, semantic, self.digest)
        self.assertEqual(result.gpif_sha256, self.digest)
        view, bound = observe_semantic(self.source, semantic)
        self.assertEqual(view, self.first)
        self.assertEqual(bound.gpif_sha256, self.digest)
        self.assertEqual((result.track_count, result.staff_count), (1, 1))
        self.assertEqual(result.tuning_high_to_low, (64, 59, 55, 50, 45, 40))
        self.assertEqual((result.capo, result.actual_transposition, result.display_transposition), (0, 0, -12))
        self.assertEqual(len(result.beats), 16)
        self.assertEqual(result.beats[(0, 0, 0)], (semantic.ImportedNote(string=4, fret=3, real_value=58),))

    def test_multiple_tracks_or_staves_are_not_silently_discarded(self):
        extra_track = deepcopy(self.first)
        extra_track['tracks'].append(deepcopy(extra_track['tracks'][0]))
        with self.assertRaises(ValueError):
            semantic_observation(extra_track, semantic, self.digest)
        extra_staff = deepcopy(self.first)
        extra_staff['tracks'][0]['staves'].append(deepcopy(extra_staff['tracks'][0]['staves'][0]))
        with self.assertRaises(ValueError):
            semantic_observation(extra_staff, semantic, self.digest)

    def test_malformed_binding_is_rejected(self):
        for digest in ('', 'a' * 63, 'G' * 64, 'A' * 64, None):
            with self.subTest(digest=digest), self.assertRaises(ValueError):
                semantic_observation(self.first, semantic, digest)

    def test_bound_observation_cannot_be_used_with_different_gpif_bytes(self):
        _, bound = observe_semantic(self.source, semantic)
        with ZipFile(BytesIO(self.source)) as source:
            altered = source.read('Content/score.gpif') + b' '
        with self.assertRaisesRegex(semantic.Unsupported, 'does not match'):
            semantic.candidates(altered, bound)

    def test_nonstandard_descriptor_requires_explicit_opt_in(self):
        archive = synthetic_archive(*next(case for case in SCENARIOS if case[0] == 'reversed'))
        with self.assertRaises(UnsafeArchive):
            observe_semantic(archive, semantic)
        _, bound = observe_semantic(archive, semantic, allow_reversed_descriptor=True)
        with ZipFile(BytesIO(archive)) as source:
            self.assertEqual(bound.gpif_sha256, hashlib.sha256(source.read('Content/score.gpif')).hexdigest())

    def test_local_importer_decodes_unicode_metadata_as_utf8(self):
        # Generated entirely in memory. No user score, path or metadata is sent
        # to the subprocess or printed to logs.
        script = r"""
const alpha = require('./RiffLoop/Resources/GpWeb/alphaTab.min.js');
const { createDraft } = require('./experiments/gp-draft-editor/draft-core.js');
const title = '\u6d4b\u8bd5\u8c31\ud83c\udfb8';
const bytes = createDraft(alpha, {title, tempo: 90, bars: [[{string: 1, fret: 0, duration: 1}]]}).exportGp();
process.stdout.write(Buffer.from(bytes).toString('base64'));
"""
        encoded = subprocess.run(['node', '-e', script], cwd=ROOT, check=True, capture_output=True,
                                 encoding='utf-8', timeout=30).stdout
        archive = base64.b64decode(encoded, validate=True)
        view, = observe(archive)
        self.assertEqual(view['metadata']['title'], '\u6d4b\u8bd5\u8c31\U0001f3b8')


if __name__ == '__main__':
    unittest.main()
