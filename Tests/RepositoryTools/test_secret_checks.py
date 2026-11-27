import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("gitleaks"), "Install Gitleaks to test repository hooks.")
class SecretCheckTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="dbdbdeep-hook-test-")
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Repository Hook Test")
        self.git("config", "user.email", "hook-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        for name in [".gitignore", ".gitleaks.toml", ".githooks/pre-commit", "scripts/check-secrets.py", "scripts/install-git-hooks.sh"]:
            destination = self.repo / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, destination)
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "Initialize isolated fixture")
        self.run_command(["sh", "scripts/install-git-hooks.sh"], success=True)

    def git(self, *arguments):
        return self.run_command(["git", *arguments], success=True)

    def run_command(self, arguments, success=False, env=None):
        result = subprocess.run(arguments, cwd=self.repo, capture_output=True, text=True, env=env)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def write(self, name, text):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def scan(self, env=None):
        return self.run_command([sys.executable, "scripts/check-secrets.py"], env=env)

    def token(self):
        return "gh" + "p_" + hashlib.sha256(b"isolated fake token fixture").hexdigest()[:36]

    def test_ignore_policy_keeps_examples_and_blocks_personal_files(self):
        for name in [".env", "config/.env.production", "config/connections.json", "profile/workspace-backup.json", "profile/ConsoleDrafts/current.json", "certs/client.pem", ".ssh/id_ed25519"]:
            self.assertEqual(self.run_command(["git", "check-ignore", "-q", name]).returncode, 0, name)
        self.assertNotEqual(self.run_command(["git", "check-ignore", "-q", ".env.example"]).returncode, 0)

    def test_real_commit_hook_blocks_force_added_connection_settings(self):
        self.write("config/connections.json", "{}")
        self.git("add", "-f", "config/connections.json")
        result = self.run_command(["git", "commit", "-qm", "Must be blocked"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config/connections.json", result.stderr)
        self.assertEqual(self.git("rev-list", "--count", "HEAD").stdout.strip(), "1")

    def test_placeholder_example_can_be_committed_but_real_value_is_blocked(self):
        self.write(".env.example", "DB_PASSWORD=CHANGE_ME\n")
        self.git("add", ".env.example")
        self.git("commit", "-qm", "Keep a placeholder template")
        value = hashlib.sha256(b"fake password fixture").hexdigest()
        self.write(".env.example", "DB_PASSWORD=" + value + "\n")
        self.git("add", ".env.example")
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(value, result.stdout + result.stderr)

    def test_staged_secret_is_blocked_even_when_working_copy_is_clean(self):
        value = self.token()
        self.write("query.swift", 'let credential = "' + value + '"\n')
        self.git("add", "query.swift")
        self.write("query.swift", "let credential = readFromKeychain()\n")
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn("query.swift:1", result.stderr)
        self.assertNotIn(value, result.stdout + result.stderr)

    def test_unstaged_secret_does_not_change_the_index_snapshot_check(self):
        self.write("query.swift", "let credential = readFromKeychain()\n")
        self.git("add", "query.swift")
        self.write("query.swift", 'let credential = "' + self.token() + '"\n')
        self.assertEqual(self.scan().returncode, 0)

    def test_archive_contents_are_scanned_without_printing_the_token(self):
        value = self.token()
        with zipfile.ZipFile(self.repo / "fixture.zip", "w") as archive:
            archive.writestr("query.swift", 'let credential = "' + value + '"\n')
        self.git("add", "fixture.zip")
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(value, result.stdout + result.stderr)

    def test_full_file_check_catches_a_secret_on_unchanged_lines(self):
        self.write("fixture.swift", 'let credential = "' + self.token() + '"\n')
        self.git("add", "fixture.swift")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "Seed synthetic baseline")
        self.git("mv", "fixture.swift", "renamed.swift")
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn("renamed.swift", result.stderr)

    def test_test_fixture_exception_is_not_a_blanket_test_directory_exclusion(self):
        name = "Tests/DBDeepCoreTests/MongoDatabaseTests.swift"
        self.write(name, 'connect(password: "local-test-secret")\n')
        self.git("add", name)
        self.assertEqual(self.scan().returncode, 0)
        value = hashlib.sha256(b"unexpected fake password").hexdigest()
        self.write(name, 'connect(password: "' + value + '")\n')
        self.git("add", name)
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(value, result.stdout + result.stderr)

    def test_invalid_scanner_config_fails_closed(self):
        self.write("note.txt", "safe content\n")
        self.git("add", "note.txt")
        self.write(".gitleaks.toml", "[invalid")
        self.assertEqual(self.scan().returncode, 2)

    def test_missing_scanner_fails_closed(self):
        self.write("note.txt", "safe content\n")
        self.git("add", "note.txt")
        commands = self.repo / "test-bin"
        commands.mkdir()
        (commands / "git").symlink_to(shutil.which("git"))
        environment = dict(os.environ, PATH=str(commands))
        self.assertEqual(self.scan(env=environment).returncode, 2)

    def test_installer_preserves_an_existing_hook_configuration(self):
        self.git("config", "core.hooksPath", "existing-hooks")
        result = self.run_command(["sh", "scripts/install-git-hooks.sh"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("config", "--get", "core.hooksPath").stdout.strip(), "existing-hooks")


if __name__ == "__main__":
    unittest.main()
