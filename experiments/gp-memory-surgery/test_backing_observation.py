"""Synthetic in-memory backing assets; no user audio is read or logged."""

import hashlib
from io import BytesIO
from pathlib import Path
import unittest
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from archive_edit import SCORE, verify_resources
from observation import observe


FIXTURE = Path(__file__).resolve().parents[2] / 'RiffLoopTests/Fixtures/transport.gp'
ASSET_A = b'synthetic-audio-one'
ASSET_B = b'synthetic-audio-two'


def archive_with_backing(asset_id):
    source = FIXTURE.read_bytes()
    with ZipFile(BytesIO(source)) as fixture:
        entries = [(info.filename, fixture.read(info)) for info in fixture.infolist()]
    output = BytesIO()
    with ZipFile(output, 'w', compression=ZIP_DEFLATED) as archive:
        for name, data in entries:
            if name == SCORE:
                assert data.count(b'</GPIF>') == 1
                backing = b'' if asset_id is None else (
                    b'<BackingTrack><Enabled>true</Enabled><Source>Local</Source><AssetId>' +
                    asset_id.encode('ascii') + b'</AssetId></BackingTrack>'
                )
                assets = (b'<Assets><Asset id="a"><EmbeddedFilePath>Content/a.bin</EmbeddedFilePath></Asset>'
                          b'<Asset id="b"><EmbeddedFilePath>Content/b.bin</EmbeddedFilePath></Asset></Assets>')
                data = data.replace(b'</GPIF>', backing + assets + b'</GPIF>')
            archive.writestr(ZipInfo(name, (2020, 1, 1, 0, 0, 0)), data,
                             compress_type=ZIP_DEFLATED)
        for name, data in (('Content/a.bin', ASSET_A), ('Content/b.bin', ASSET_B)):
            archive.writestr(ZipInfo(name, (2020, 1, 1, 0, 0, 0)), data,
                             compress_type=ZIP_DEFLATED)
    return output.getvalue()


class BackingObservationTests(unittest.TestCase):
    def test_same_resources_but_changed_reference_is_observed(self):
        first, second = archive_with_backing('a'), archive_with_backing('b')
        # Resources are byte-identical: this check alone cannot identify which
        # resource the changed GPIF actually associates with the backing track.
        verify_resources(first, second)
        before, after = observe(first, second)
        self.assertEqual(before['backingTrack']['audio'], {
            'length': len(ASSET_A), 'sha256': hashlib.sha256(ASSET_A).hexdigest()})
        self.assertEqual(after['backingTrack']['audio'], {
            'length': len(ASSET_B), 'sha256': hashlib.sha256(ASSET_B).hexdigest()})
        self.assertNotEqual(before['backingTrack'], after['backingTrack'])

    def test_absent_and_unresolved_backing_are_distinct(self):
        no_backing, unresolved = observe(archive_with_backing(None), archive_with_backing('missing'))
        self.assertIsNone(no_backing['backingTrack'])
        self.assertEqual(unresolved['backingTrack'], {'audio': None})


if __name__ == '__main__':
    unittest.main()
