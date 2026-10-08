import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'craig'

class AutomationTest(unittest.TestCase):
    def run_pipeline(self, fail='', args=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Substitute stage boundaries; exercise the real dispatcher and shared lock.
            stubs = '''
record() {
  [[ -d "$work/operation.lock" ]] || exit 99
  printf '%s\\n' "$1" >> "$root/stages"
  [[ "${FAIL_STAGE:-}" != "$1" ]] || return 42
}
preflight() { record preflight; }
fetch() { record fetch; }
build() { record build; }
reset_deploy() { record reset; }
status() { record status; }
'''
            script = root / 'craig'
            script.write_text(SCRIPT.read_text().replace('operation=${1:-}', stubs+'\noperation=${1:-}'))
            result = subprocess.run(['bash', str(script)]+(args or ['deploy', '--discard-test-data']), env={**os.environ, 'FAIL_STAGE': fail}, capture_output=True, text=True)
            stages = (root/'stages').read_text().splitlines() if (root/'stages').exists() else []
            self.assertFalse((root/'.work/operation.lock').exists())
            return result.returncode, stages

    def test_complete_sequence(self):
        code, stages = self.run_pipeline()
        self.assertEqual(code, 0)
        self.assertEqual(stages, ['preflight','fetch','build','reset','status'])

    def test_failures_never_reach_later_stages(self):
        order = ['preflight','fetch','build','reset','status']
        for i, stage in enumerate(order):
            code, stages = self.run_pipeline(stage)
            self.assertEqual(code, 42)
            self.assertEqual(stages, order[:i+1])

    def test_explicit_reset_flag_required(self):
        code, stages = self.run_pipeline(args=['deploy'])
        self.assertEqual(code, 2)
        self.assertEqual(stages, [])

if __name__ == '__main__':
    unittest.main()
