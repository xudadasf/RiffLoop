import json
from pathlib import Path
import unittest

from confidence_reference import reference


class ConfidenceReferenceTests(unittest.TestCase):
    def test_frozen_cases_match_actual_desktop_decoder(self):
        fixture = Path(__file__).with_name('confidence_reference.json')
        with fixture.open(encoding='utf-8') as source:
            self.assertEqual(json.load(source), reference())


if __name__ == '__main__':
    unittest.main()
