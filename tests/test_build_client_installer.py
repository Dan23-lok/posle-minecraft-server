"""The published client archive must carry installation and safe removal tools."""

import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
MODULE_PATH = PROJECT / "tools" / "build_client_installer.py"
SPEC = importlib.util.spec_from_file_location("build_client_installer", MODULE_PATH)
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class ClientInstallerArchiveTest(unittest.TestCase):
    def test_archive_contains_current_install_uninstall_and_migration_manifest(self):
        expected = [
            "Install-Client.cmd",
            "Install-HorrorClient.ps1",
            "Build-BornInChaosAnimationFix.ps1",
            "Forge-ClientReadiness.ps1",
            "Configure-WebsitePlay.ps1",
            "Invoke-LocalPlay.ps1",
            "POSLEProtocolHost.cs",
            "Register-PlayProtocol.ps1",
            "Unregister-PlayProtocol.ps1",
            "PlayProtocolShellNotify.ps1",
            "Uninstall-Client.cmd",
            "Uninstall-HorrorClient.ps1",
            "client-modpack.json",
            "historical/client-modpack-2026.10.11.4.json",
            "README-RU.md",
        ]
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "client.zip"
            result = builder.build(archive_path)
            with zipfile.ZipFile(archive_path) as archive:
                self.assertEqual(expected, archive.namelist())
                for name in expected:
                    self.assertEqual((PROJECT / "client-pack" / name).read_bytes(), archive.read(name))
            self.assertEqual(expected, result["entries"])


if __name__ == "__main__":
    unittest.main()
