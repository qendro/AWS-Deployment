"""Finalizer/restore regression tests. Run in Docker; cloud and shutdown are mocked."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
POPULATION = '2026-10-14T00-00-00Z_ab12_run1'


class FinalizationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.env = dict(os.environ, DXNN_CONFIG_INITIALIZED='true',
                        POPULATION_ID=POPULATION, LINEAGE_ID='ab12', JOB_ID='',
                        S3_BUCKET='test-bucket', S3_PREFIX='test-prefix',
                        AUTO_TERMINATE='true', AUTO_TERMINATE_DEFAULT='false',
                        SAFE_MODE='', COMPLETION_STATUS='normal', EXIT_CODE='0',
                        LOG_FILE=str(self.directory / 'finalize.log'),
                        LINEAGE_FILE=str(self.directory / 'lineage_id'),
                        TEST_DIRECTORY=str(self.directory))

    def run_shell(self, script):
        result = subprocess.run(
            ['bash', '-c', 'source "$1/scripts/finalize_run.sh"\n' + script,
             'finalizer-test', str(ROOT)], env=self.env,
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_successful_upload_terminates_for_normal_and_crashed_runs(self):
        for status, code in [('normal', '0'), ('crash', '137')]:
            with self.subTest(status=status):
                self.env.update(COMPLETION_STATUS=status, EXIT_CODE=code)
                output = self.run_shell('''
finalize() { return 0; }
run_privileged() { echo "SHUTDOWN:$*"; }
sleep() { :; }
main
''')
                self.assertIn('SHUTDOWN:poweroff', output)

    def test_failed_upload_keeps_instance_and_returns_failure(self):
        output = self.run_shell('''
finalize() { return 1; }
run_privileged() { echo "UNEXPECTED_SHUTDOWN:$*"; }
if main; then exit 42; fi
''')
        self.assertNotIn('UNEXPECTED_SHUTDOWN', output)
        self.assertIn('keeping instance running for recovery', output)

    def test_safe_mode_and_explicit_false_prevent_shutdown(self):
        for settings in [dict(SAFE_MODE='true'), dict(AUTO_TERMINATE='false')]:
            with self.subTest(settings=settings):
                self.env.update(SAFE_MODE='', AUTO_TERMINATE='true')
                self.env.update(settings)
                output = self.run_shell('''
finalize() { return 0; }
run_privileged() { echo "UNEXPECTED_SHUTDOWN:$*"; }
main
''')
                self.assertNotIn('UNEXPECTED_SHUTDOWN', output)

    def test_crash_generates_and_persists_identifiers_with_pipefail(self):
        self.env.update(POPULATION_ID='unknown', LINEAGE_ID='', JOB_ID='')
        self.run_shell('''
[[ "$LINEAGE_ID" =~ ^[0-9a-f]{4}$ ]]
[[ "$(cat "$LINEAGE_FILE")" == "$LINEAGE_ID" ]]
[[ "$POPULATION_ID" == "${JOB_ID}_crash" ]]
''')

    def test_uploaded_checkpoint_restores_from_lineage_pointer_and_job_path(self):
        checkpoint = self.directory / 'checkpoint'
        (checkpoint / 'Mnesia.nonode@nohost').mkdir(parents=True)
        (checkpoint / 'logs').mkdir()
        (checkpoint / 'Mnesia.nonode@nohost' / 'schema.DAT').write_text('database')
        (checkpoint / 'logs' / 'run.log').write_text('training log')
        self.run_shell('''
upload_file_to_s3() {
    mkdir -p "$TEST_DIRECTORY/s3/$(dirname "$2")"
    cp "$1" "$TEST_DIRECTORY/s3/$2"
}
upload_checkpoint_to_s3 "$TEST_DIRECTORY/checkpoint" "$S3_PREFIX/$JOB_ID/$POPULATION_ID"
upload_manifest
update_latest_pointer
export RESTORE_FROM_S3=true RESTORE_DXNN_DIR="$TEST_DIRECTORY/restored"
source "$1/scripts/restore-from-s3.sh"
RESTORE_LOG="$TEST_DIRECTORY/restore.log"
aws_s3_cp() {
    local key="${1#s3://test-bucket/}"
    cp "$TEST_DIRECTORY/s3/$key" "$2"
}
resolve_population_id
[[ "$JOB_ID" == '2026-10-14T00-00-00Z_ab12' ]]
restore_manifest
cmp "$TEST_DIRECTORY/checkpoint/Mnesia.nonode@nohost/schema.DAT" "$DXNN_DIR/Mnesia.nonode@nohost/schema.DAT"
cmp "$TEST_DIRECTORY/checkpoint/logs/run.log" "$DXNN_DIR/logs/run.log"
''')

    def test_legacy_lineage_layout_still_restores(self):
        self.run_shell('''
export RESTORE_FROM_S3=true RESTORE_DXNN_DIR="$TEST_DIRECTORY/restored"
source "$1/scripts/restore-from-s3.sh"
RESTORE_LOG="$TEST_DIRECTORY/restore.log"
aws_s3_cp() {
    case "$1" in
        s3://test-bucket/test-prefix/ab12/_LATEST_RUN)
            printf '{"population_id":"old-run"}' > "$2" ;;
        s3://test-bucket/test-prefix/ab12/old-run/_MANIFEST)
            printf '644\\tlogs/run.log\\n' > "$2" ;;
        s3://test-bucket/test-prefix/ab12/old-run/logs/run.log)
            echo restored > "$2" ;;
        *) return 1 ;;
    esac
}
resolve_population_id
[[ -z "$JOB_ID" ]]
restore_manifest
[[ "$(cat "$DXNN_DIR/logs/run.log")" == restored ]]
''')

    def test_diagnostics_without_database_do_not_replace_latest_checkpoint(self):
        output = self.run_shell('''
CHECKPOINT_BASE_DIR="$TEST_DIRECTORY/checkpoints"
mkdir -p "$CHECKPOINT_BASE_DIR/checkpoint-1"
check_config() { :; }
check_s3_sentinel() { return 1; }
upload_checkpoint_to_s3() { return 0; }
upload_manifest() { return 0; }
create_s3_sentinel() { return 0; }
update_latest_pointer() { echo UNEXPECTED_POINTER; }
finalize
''')
        self.assertNotIn('UNEXPECTED_POINTER', output)


if __name__ == '__main__':
    unittest.main()
