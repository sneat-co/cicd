#!/usr/bin/env python3
"""Exercise the real option guard and the reusable-job wiring."""
import os
from pathlib import Path
import re
import subprocess
import unittest
ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/go-storage-driver-boundary.yml'
def jobs(text):
    blocks = re.split(r'^  ([a-z-]+):\n', text.split('\njobs:\n', 1)[1], flags=re.M)
    return dict(zip(blocks[1::2], blocks[2::2]))
def validate(text):
    j = jobs(text)
    assert {'options', 'storage-boundary', 'native-sites'} <= j.keys()
    assert 'needs: options' in j['storage-boundary']
    assert 'if: ${{ !inputs.native-sites-only }}' in j['storage-boundary']
    assert 'check-go-storage-driver-boundary.sh' in j['storage-boundary']
    n = j['native-sites']
    for required in ['needs: options', 'if: ${{ inputs.native-sites }}',
                     'repository: sneat-co/cicd', 'ref: ${{ inputs.policy-ref }}',
                     'working-directory: .cicd', "GOWORK: 'off'",
                     'git -C .cicd rev-parse HEAD', 'git -C source rev-parse HEAD',
                     'go build -mod=readonly', './cmd/check-go-native-firestore-sites',
                     'TARGET_REPOSITORY: ${{ github.repository }}',
                     '--root "$GITHUB_WORKSPACE/source"', '--manifest "$MANIFEST"']:
        assert required in n, required
    assert 'secrets:' not in n
    assert text.count('default: false') >= 2
    assert 'dependency-layer validation is NOT run' in j['options']
class WorkflowContract(unittest.TestCase):
    def test_real_workflow(self):
        validate(WORKFLOW.read_text())
    def test_missing_job_or_guard_fails(self):
        text = WORKFLOW.read_text()
        for changed in [text.replace('  native-sites:\n', '  missing:\n'),
                        text.replace('    needs: options\n', ''),
                        text.replace('--root "$GITHUB_WORKSPACE/source"', '--root .'),
                        text.replace('repository: sneat-co/cicd', 'repository: attacker/code')]:
            with self.assertRaises(AssertionError):
                validate(changed)
    def test_actual_option_script(self):
        block = jobs(WORKFLOW.read_text())['options']
        script = block.split('        run: |\n', 1)[1]
        script = '\n'.join(line[10:] for line in script.splitlines())
        for native, only, manifest, expected in [
            ('false', 'false', '', 0), ('true', 'false', 'sites.json', 0),
            ('true', 'true', 'sites.json', 0), ('true', 'false', '', 1),
            ('true', 'true', '', 1), ('false', 'true', 'sites.json', 1),
            ('false', 'false', 'sites.json', 1), ('false', 'true', '', 1)]:
            result = subprocess.run(['bash', '-c', script], env={**os.environ,
                'NATIVE_SITES': native, 'NATIVE_ONLY': only, 'MANIFEST': manifest},
                capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            if native == only == 'true' and expected == 0:
                self.assertIn('dependency-layer validation is NOT run', result.stdout)
if __name__ == '__main__':
    unittest.main()
