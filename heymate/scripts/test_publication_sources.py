#!/usr/bin/env python3
"""Exercise release gate in isolated fixtures; never modify the real inventory."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class PublicationGateTests(unittest.TestCase):
    def run_gate(self, inventory):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'scripts').mkdir()
            script = root / 'scripts/check_publication_sources.py'
            shutil.copyfile(Path(__file__).with_name(script.name), script)
            if inventory is not None:
                (root / 'publication-sources.json').write_text(json.dumps(inventory))
            return subprocess.run(['python3', str(script)], capture_output=True, text=True)

    def test_missing_inventory_blocks_release(self):
        self.assertNotEqual(self.run_gate(None).returncode, 0)

    def test_unresolved_sources_block_even_when_marked_approved(self):
        result = self.run_gate({'schema': 1, 'reviewStatus': 'approved',
                                'unresolved': [{'path': 'fixture.js', 'status': 'pending'}],
                                'reviewEvidence': ['fixture review']})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('fixture.js', result.stderr)

    def test_review_requires_recorded_evidence(self):
        result = self.run_gate({'schema': 1, 'reviewStatus': 'approved', 'unresolved': []})
        self.assertNotEqual(result.returncode, 0)

    def test_completed_fixture_review_passes(self):
        result = self.run_gate({'schema': 1, 'reviewStatus': 'approved', 'unresolved': [],
                                'reviewEvidence': ['Fixture only; not a production clearance.']})
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
