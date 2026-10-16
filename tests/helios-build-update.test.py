"""Real local Git integration tests; Docker is replaced by a build-start marker."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build-helios.sh"


class BuildUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="winboat-build-update-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.origin = self.root / "origin.git"
        self.seed = self.root / "seed"
        self.checkout = self.root / "checkout"
        self.git(self.root, "init", "--bare", str(self.origin))
        self.git(self.root, "init", "--initial-branch=work", str(self.seed))
        (self.seed / "scripts").mkdir()
        shutil.copyfile(SCRIPT, self.seed / "scripts/build-helios.sh")
        (self.seed / "example.txt").write_text("original\n")
        self.commit(self.seed)
        self.git(self.seed, "remote", "add", "origin", str(self.origin))
        self.git(self.seed, "push", "origin", "work")
        self.git(self.root, "clone", "--branch", "work", str(self.origin), str(self.checkout))
        binaries = self.root / "bin"
        binaries.mkdir()
        docker = binaries / "docker"
        docker.write_text('#!/bin/sh\nprintf "%s\\n" "$*" > "$WINBOAT_TEST_DOCKER_MARKER"\nexit 1\n')
        docker.chmod(0o755)
        self.marker = self.root / "docker-started"
        self.environment = {**os.environ, "LC_ALL": "C", "PATH": f"{binaries}:{os.environ['PATH']}",
                            "BUILDX_CONFIG": str(self.root / "buildx"),
                            "WINBOAT_TEST_DOCKER_MARKER": str(self.marker)}

    def git(self, directory, *args):
        return subprocess.run(["git", "-C", str(directory), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, directory):
        self.git(directory, "add", ".")
        self.git(directory, "-c", "user.name=Build test", "-c", "user.email=build@example.invalid",
                 "commit", "-m", "Fixture update")

    def publish(self):
        self.commit(self.seed)
        self.git(self.seed, "push", "origin", "work")

    def build(self, *args):
        return subprocess.run(["bash", str(self.checkout / "scripts/build-helios.sh"), *args],
                              env=self.environment, capture_output=True, text=True, timeout=20)

    def assert_stopped(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists(), result.stdout + result.stderr)

    def test_up_to_date_still_pulls_before_docker(self):
        result = self.build("--skip-host")
        self.assertIn("Already up to date", result.stdout)
        self.assertEqual(self.marker.read_text(), "info\n")

    def test_fast_forward_uses_updated_script_and_preserves_options(self):
        script = self.seed / "scripts/build-helios.sh"
        script.write_text(script.read_text().replace("set -euo pipefail\n",
                          'set -euo pipefail\necho "UPDATED_SCRIPT_ARGS=$*"\n', 1))
        self.publish()
        result = self.build("--skip-host", "--all-packages")
        self.assertIn("UPDATED_SCRIPT_ARGS=--skip-host --all-packages", result.stdout)
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"),
                         self.git(self.seed, "rev-parse", "HEAD"))
        self.assertTrue(self.marker.exists())

    def test_divergence_stops_without_resetting_local_commit(self):
        (self.checkout / "local.txt").write_text("keep this\n")
        self.commit(self.checkout)
        before = self.git(self.checkout, "rev-parse", "HEAD")
        (self.seed / "remote.txt").write_text("remote\n")
        self.publish()
        self.assert_stopped(self.build())
        self.assertEqual(self.git(self.checkout, "rev-parse", "HEAD"), before)
        self.assertEqual((self.checkout / "local.txt").read_text(), "keep this\n")

    def test_conflicting_uncommitted_edits_are_preserved(self):
        (self.checkout / "example.txt").write_text("local edit\n")
        (self.seed / "example.txt").write_text("remote edit\n")
        self.publish()
        self.assert_stopped(self.build())
        self.assertEqual((self.checkout / "example.txt").read_text(), "local edit\n")
        self.assertEqual(self.git(self.checkout, "stash", "list"), "")

    def test_other_branch_and_detached_head_are_not_changed(self):
        self.git(self.checkout, "checkout", "-b", "another-branch")
        self.assert_stopped(self.build())
        self.assertEqual(self.git(self.checkout, "branch", "--show-current"), "another-branch")
        self.git(self.checkout, "checkout", "--detach")
        self.assert_stopped(self.build())
        self.assertEqual(self.git(self.checkout, "branch", "--show-current"), "")

    def test_unreachable_origin_stops_before_docker(self):
        self.git(self.checkout, "remote", "set-url", "origin", str(self.root / "missing.git"))
        self.assert_stopped(self.build())

    def test_help_does_not_pull_or_start_docker(self):
        self.git(self.checkout, "remote", "set-url", "origin", str(self.root / "missing.git"))
        result = self.build("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage:", result.stdout)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
