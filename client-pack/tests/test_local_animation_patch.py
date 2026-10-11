"""Windows integration tests for the locally generated Born in Chaos fix.

The fixture JAR is synthetic: no creator-owned animation data is stored here.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


PACK_DIR = Path(__file__).resolve().parents[1]
PATCH_NAME = "BornInChaosAnimationFix-local.zip"
MOD_NAME = "born_in_chaos_[Forge]1.20.1_1.7.5.jar"
FRESH_NAME = "FreshAnimations_v1.10.4.zip"
ANIMATIONS = {
    "babyskeleton.animation.json": ("idle", "tail", "4.0", 1),
    "babyskeletondeamon.animation.json": ("idle", "tail", "4.0", 1),
    "boneimp.animation.json": ("idle", "tail", "4.0", 1),
    "scarletpersecutor.animation.json": ("attack", "right_arm", "0.8333", 0),
}


def sha512(path):
    return hashlib.sha512(path.read_bytes()).hexdigest()


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


@unittest.skipUnless(os.name == "nt", "installer is a Windows PowerShell script")
class LocalAnimationPatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.client = self.root / "client"
        (self.client / "mods").mkdir(parents=True)
        (self.client / "resourcepacks").mkdir()
        self.source.mkdir()
        for script in ("Install-HorrorClient.ps1", "Uninstall-HorrorClient.ps1", "Forge-ClientReadiness.ps1"):
            shutil.copy2(PACK_DIR / script, self.source)
        generator = PACK_DIR / "Build-BornInChaosAnimationFix.ps1"
        if generator.exists():
            shutil.copy2(generator, self.source)

        self.jar = self.client / "mods" / MOD_NAME
        self.source_assets = {}
        with zipfile.ZipFile(self.jar, "w") as archive:
            for filename, (animation, bone, time, index) in ANIMATIONS.items():
                vector = [0, 0, 0]
                vector[index] = "-"
                data = {"animations": {animation: {"bones": {bone: {"rotation": {time: {"vector": vector}}}}}}}
                if filename == "scarletpersecutor.animation.json":
                    data["animations"]["attack"]["bones"]["left_arm"] = {
                        "rotation": {"0.8333": {"vector": ["-", 0, 0]}}
                    }
                path = "assets/born_in_chaos_v1/animations/" + filename
                raw = json.dumps(data, separators=(",", ":")).encode("utf-8")
                self.source_assets[path] = raw
                archive.writestr(path, raw)
            archive.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\n")

        self.fresh = self.client / "resourcepacks" / FRESH_NAME
        with zipfile.ZipFile(self.fresh, "w") as archive:
            archive.writestr("pack.mcmeta", '{"pack":{"pack_format":15,"description":"fixture"}}')
        (self.client / "resourcepacks" / "MyOwnPack.zip").write_bytes(b"user-owned")
        (self.client / "options.txt").write_text('resourcePacks:["file/MyOwnPack.zip"]\nrenderDistance:12\n')

        self.mod_entry = {
            "project": "born-in-chaos", "version": "1.7.5", "filename": MOD_NAME,
            "url": "https://cdn.modrinth.com/data/fixture/born.jar", "hash_algorithm": "SHA512",
            "hash": sha512(self.jar), "folder": "mods",
        }
        self.fresh_entry = {
            "project": "fresh-animations", "version": "1.10.4", "filename": FRESH_NAME,
            "url": "https://cdn.modrinth.com/data/fixture/fresh.zip", "hash_algorithm": "SHA512",
            "hash": sha512(self.fresh), "folder": "resourcepacks", "default_enabled": True,
        }
        self.manifest = {
            "pack": "POSLE fixture", "pack_version": "2026.10.11.7", "minecraft_version": "1.20.1",
            "forge_version": "47.4.10", "java_major": 17, "server_address": "example.invalid",
            "java_runtime": {
                "java_exe_sha256": "1E1BE5FB92E33218323825B284C16377BDF10F7ED5CB4D30323F6B596EA45E5F"
            },
            "local_animation_patch": {"kind": "born-in-chaos-1.7.5", "revision": 1},
            "files": [self.mod_entry, self.fresh_entry],
        }
        (self.source / "client-modpack.json").write_text(json.dumps(self.manifest), encoding="utf-8")
        historical = {**self.manifest, "pack_version": "2026.10.11.4"}
        (self.source / "historical").mkdir()
        (self.source / "historical" / "client-modpack-2026.10.11.4.json").write_text(
            json.dumps(historical), encoding="utf-8"
        )

    def run_powershell(self, script, *args):
        env = dict(os.environ)
        program_files = env.get("ProgramFiles") or env.get("PROGRAMFILES") or r"C:\Program Files"
        system_root = env.get("SystemRoot") or env.get("SYSTEMROOT") or r"C:\Windows"
        env["PSModulePath"] = os.pathsep.join([
            str(Path(env["USERPROFILE"]) / "Documents" / "WindowsPowerShell" / "Modules"),
            str(Path(program_files) / "WindowsPowerShell" / "Modules"),
            str(Path(system_root) / "System32" / "WindowsPowerShell" / "v1.0" / "Modules"),
        ])
        return subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(self.source / script), *map(str, args)],
            cwd=self.root, env=env, text=True, capture_output=True,
        )

    def run_installer(self, *args):
        return self.run_powershell(
            "Install-HorrorClient.ps1", "-MinecraftDirectory", self.client,
            "-SkipForge", "-GraphicsProfile", "Low", *args,
        )

    def selected_packs(self):
        options = (self.client / "options.txt").read_text(encoding="utf-8")
        line = next(line for line in options.splitlines() if line.startswith("resourcePacks:"))
        return json.loads(line.removeprefix("resourcePacks:"))

    def receipt(self):
        return json.loads((self.client / "horror-apocalypse-install.json").read_text(encoding="utf-8-sig"))

    def test_generator_changes_only_five_invalid_coordinates_and_keeps_source_intact(self):
        output = self.root / PATCH_NAME
        before = sha512(self.jar)
        result = self.run_powershell(
            "Build-BornInChaosAnimationFix.ps1", "-BornJarPath", self.jar,
            "-OutputZip", output, "-ExpectedSha512", before,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with zipfile.ZipFile(output) as pack:
            self.assertEqual(set(pack.namelist()), {"pack.mcmeta", *self.source_assets})
            self.assertEqual(json.loads(pack.read("pack.mcmeta"))["pack"]["pack_format"], 15)
            for name, raw in self.source_assets.items():
                self.assertEqual(pack.read(name), raw.replace(b'"-"', b"0"))
        self.assertEqual(sha512(self.jar), before)
        second = self.root / "second.zip"
        again = self.run_powershell(
            "Build-BornInChaosAnimationFix.ps1", "-BornJarPath", self.jar,
            "-OutputZip", second, "-ExpectedSha512", before,
        )
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(sha256(second), sha256(output), "generated pack must be stable across runs")

    def test_generator_rejects_junction_output_directory(self):
        outside = self.root / "outside"
        outside.mkdir()
        junction = self.root / "linked-resourcepacks"
        made = subprocess.run(
            ["cmd.exe", "/c", "mklink", "/J", str(junction), str(outside)],
            text=True, capture_output=True,
        )
        if made.returncode != 0:
            self.skipTest("Windows did not allow a disposable directory junction")
        attempted = self.run_powershell(
            "Build-BornInChaosAnimationFix.ps1", "-BornJarPath", self.jar,
            "-OutputZip", junction / PATCH_NAME, "-ExpectedSha512", sha512(self.jar),
        )
        self.assertNotEqual(attempted.returncode, 0)
        self.assertIn("symlink or junction", attempted.stdout + attempted.stderr)
        self.assertFalse((outside / PATCH_NAME).exists())

    def test_fresh_install_tracks_and_enables_locally_generated_pack(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        patch = self.client / "resourcepacks" / PATCH_NAME
        self.assertTrue(patch.is_file())
        self.assertEqual(self.selected_packs(), ["file/MyOwnPack.zip", "file/FreshAnimations_v1.10.4.zip", "file/" + PATCH_NAME])
        managed = {entry["filename"]: entry for entry in self.receipt()["managed_files"]}
        self.assertEqual(managed[PATCH_NAME]["hash_algorithm"], "SHA256")
        self.assertEqual(managed[PATCH_NAME]["hash"].lower(), sha256(patch))
        self.assertTrue(managed[PATCH_NAME]["default_enabled"])
        self.assertTrue(managed[PATCH_NAME]["created_by_posle"])
        self.assertTrue(managed[PATCH_NAME]["generated_locally"])

    def test_update_from_old_receipt_and_no_resource_pack_keeps_essential_fix(self):
        prior = {
            "pack": "POSLE fixture", "pack_version": "2026.10.11.4", "graphics_profile": "Low",
            "minecraft_directory": str(self.client),
            "managed_files": [
                {**self.mod_entry, "default_enabled": False},
                {**self.fresh_entry, "default_enabled": True},
            ],
        }
        (self.client / "horror-apocalypse-install.json").write_text(json.dumps(prior), encoding="utf-8")
        (self.client / "options.txt").write_text('resourcePacks:["file/MyOwnPack.zip","file/FreshAnimations_v1.10.4.zip"]\n')
        upgraded = self.run_installer()
        self.assertEqual(upgraded.returncode, 0, upgraded.stdout + upgraded.stderr)
        self.assertIn("file/" + PATCH_NAME, self.selected_packs())
        reduced = self.run_installer("-NoResourcePack")
        self.assertEqual(reduced.returncode, 0, reduced.stdout + reduced.stderr)
        self.assertEqual(self.selected_packs(), ["file/MyOwnPack.zip", "file/" + PATCH_NAME])
        # The v4 receipt does not prove the installer created Fresh Animations.
        self.assertTrue(self.fresh.exists())
        self.assertTrue((self.client / "resourcepacks" / "MyOwnPack.zip").exists())
        self.assertTrue((self.client / "resourcepacks" / PATCH_NAME).exists())

    def test_reinstall_refuses_to_overwrite_modified_generated_pack(self):
        first = self.run_installer()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        patch = self.client / "resourcepacks" / PATCH_NAME
        with patch.open("ab") as output:
            output.write(b"user edit")
        modified_hash = sha256(patch)
        again = self.run_installer()
        self.assertNotEqual(again.returncode, 0)
        self.assertEqual(sha256(patch), modified_hash)

    def test_failed_install_rolls_back_generated_pack_and_player_settings(self):
        options = self.client / "options.txt"
        original = b'resourcePacks:not-json\nrenderDistance:12\n'
        options.write_bytes(original)
        failed = self.run_installer()
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse((self.client / "resourcepacks" / PATCH_NAME).exists())
        self.assertFalse((self.client / "horror-apocalypse-install.json").exists())
        self.assertEqual(options.read_bytes(), original)
        self.assertTrue((self.client / "resourcepacks" / "MyOwnPack.zip").exists())

    def test_uninstaller_rejects_forged_animation_patch_ownership(self):
        installed = self.run_installer()
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        receipt_path = self.client / "horror-apocalypse-install.json"
        receipt = self.receipt()
        for entry in receipt["managed_files"]:
            if entry["filename"] == PATCH_NAME:
                entry["created_by_posle"] = False
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        checked = self.run_powershell(
            "Uninstall-HorrorClient.ps1", "-MinecraftDirectory", self.client, "-WhatIf"
        )
        self.assertNotEqual(checked.returncode, 0)
        self.assertTrue((self.client / "resourcepacks" / PATCH_NAME).exists())

    def test_verified_source_update_rebuilds_local_animation_pack(self):
        first = self.run_installer()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        changed = {}
        for name, raw in self.source_assets.items():
            if name.endswith("babyskeleton.animation.json"):
                data = json.loads(raw)
                data["animations"]["idle"]["animation_length"] = 4
                raw = json.dumps(data, separators=(",", ":")).encode("utf-8")
            changed[name] = raw
        with zipfile.ZipFile(self.jar, "w") as archive:
            for name, raw in changed.items():
                archive.writestr(name, raw)
        self.manifest["files"][0]["hash"] = sha512(self.jar)
        (self.source / "client-modpack.json").write_text(json.dumps(self.manifest), encoding="utf-8")

        updated = self.run_installer()
        self.assertEqual(updated.returncode, 0, updated.stdout + updated.stderr)
        with zipfile.ZipFile(self.client / "resourcepacks" / PATCH_NAME) as patch:
            name = "assets/born_in_chaos_v1/animations/babyskeleton.animation.json"
            self.assertEqual(json.loads(patch.read(name))["animations"]["idle"].get("animation_length"), 4)
        self.assertEqual(self.receipt()["animation_patch_source_sha512"].lower(), sha512(self.jar))

    def test_failed_source_update_restores_previous_generated_pack(self):
        first = self.run_installer()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        patch = self.client / "resourcepacks" / PATCH_NAME
        old_patch_hash = sha256(patch)
        old_receipt = self.receipt()
        with zipfile.ZipFile(self.jar, "w") as archive:
            for name, raw in self.source_assets.items():
                if name.endswith("boneimp.animation.json"):
                    data = json.loads(raw)
                    data["animations"]["idle"]["animation_length"] = 4
                    raw = json.dumps(data, separators=(",", ":")).encode("utf-8")
                archive.writestr(name, raw)
        self.manifest["files"][0]["hash"] = sha512(self.jar)
        (self.source / "client-modpack.json").write_text(json.dumps(self.manifest), encoding="utf-8")
        options = self.client / "options.txt"
        options.write_text("resourcePacks:not-json\n", encoding="utf-8")
        failed = self.run_installer()
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(sha256(patch), old_patch_hash)
        self.assertEqual(self.receipt()["animation_patch_source_sha512"], old_receipt["animation_patch_source_sha512"])

    def test_uninstaller_removes_owned_patch_but_preserves_unrelated_pack(self):
        installed = self.run_installer()
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        env = dict(os.environ)
        system_root = env.get("SystemRoot") or env.get("SYSTEMROOT") or r"C:\Windows"
        env["PSModulePath"] = os.pathsep.join([
            str(Path(env["USERPROFILE"]) / "Documents" / "WindowsPowerShell" / "Modules"),
            str(Path(env.get("ProgramFiles") or r"C:\Program Files") / "WindowsPowerShell" / "Modules"),
            str(Path(system_root) / "System32" / "WindowsPowerShell" / "v1.0" / "Modules"),
        ])
        removed = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
             f"& '{self.source / 'Uninstall-HorrorClient.ps1'}' -MinecraftDirectory '{self.client}' -Confirm:$false"],
            cwd=self.root, env=env, text=True, capture_output=True,
        )
        self.assertEqual(removed.returncode, 0, removed.stdout + removed.stderr)
        self.assertFalse((self.client / "resourcepacks" / PATCH_NAME).exists())
        self.assertTrue((self.client / "resourcepacks" / "MyOwnPack.zip").exists())


if __name__ == "__main__":
    unittest.main()
