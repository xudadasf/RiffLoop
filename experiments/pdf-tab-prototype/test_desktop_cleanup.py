import json
from pathlib import Path
import tempfile
import unittest

from desktop_cleanup import clean_intermediates, register_intermediates


class CleanupTests(unittest.TestCase):
    def setup_folder(self,root):
        source=root/'original.png'
        source.write_bytes(b'original')
        result={'source':str(source),'folder':str(root),'status':'草稿已生成','message':'test','draft':str(root/'score.draft.gp')}
        (root/'result.json').write_text(json.dumps(result),encoding='utf-8')
        (root/'recognized.json').write_text('{"systems": []}',encoding='utf-8')
        (root/'score.draft.gp').write_bytes(b'manually corrected GP')
        (root/'score.draft.gp.review.md').write_text('review')
        cache=root/'digit-ocr'
        cache.mkdir()
        (cache/'page-1.png').write_bytes(b'generated image')
        (cache/'p1-s1-bands.json').write_text('{}')
        (cache/'my-corrected.gp').write_bytes(b'user work')
        (root/'worker.log').write_text('log')
        return cache

    def test_preserves_source_corrected_gp_and_unrecognized_user_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();cache=self.setup_folder(root)
            register_intermediates(root)
            result=clean_intermediates(root)
            self.assertEqual(len(result['removed']),3)
            self.assertFalse((cache/'page-1.png').exists())
            self.assertEqual((root/'score.draft.gp').read_bytes(),b'manually corrected GP')
            self.assertTrue((cache/'my-corrected.gp').exists())
            self.assertTrue((root/'original.png').exists())
            self.assertTrue((root/'score.draft.gp.review.md').exists())
            self.assertEqual(clean_intermediates(root)['bytes_freed'],0)

    def test_modified_generated_image_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();cache=self.setup_folder(root)
            register_intermediates(root)
            (cache/'page-1.png').write_bytes(b'user changed this image')
            result=clean_intermediates(root)
            self.assertIn('digit-ocr/page-1.png',result['kept_modified_or_unowned'])
            self.assertEqual((cache/'page-1.png').read_bytes(),b'user changed this image')

    def test_older_result_without_manifest_keeps_source_even_with_cache_filename(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();cache=self.setup_folder(root)
            result=json.loads((root/'result.json').read_text(encoding='utf-8'))
            result['source']=str(cache/'page-1.png')
            (root/'result.json').write_text(json.dumps(result),encoding='utf-8')
            clean_intermediates(root)
            self.assertTrue((cache/'page-1.png').exists())
            self.assertTrue((root/'score.draft.gp').exists())
            self.assertFalse((root/'worker.log').exists())

    def test_record_must_match_directory_and_manifest_cannot_escape(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();self.setup_folder(root)
            manifest=register_intermediates(root)
            manifest['files'].append({'path':'../outside.png','sha256':'x','bytes':1})
            (root/'cleanup-manifest.json').write_text(json.dumps(manifest),encoding='utf-8')
            self.assertIn('../outside.png',clean_intermediates(root)['kept_modified_or_unowned'])
            data=json.loads((root/'result.json').read_text(encoding='utf-8'));data['folder']=str(root/'other')
            (root/'result.json').write_text(json.dumps(data),encoding='utf-8')
            with self.assertRaisesRegex(ValueError,'不一致'):
                clean_intermediates(root)


if __name__=='__main__':
    unittest.main()
