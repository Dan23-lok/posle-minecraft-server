"""Every both-side server mod must be present in the downloadable client pack."""

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ClientServerSyncTest(unittest.TestCase):
    def test_required_server_mods_are_pinned_for_client(self):
        server = json.loads((ROOT / "server" / "mods-lock.json").read_text(encoding="utf-8-sig"))
        client = json.loads((ROOT / "client-pack" / "client-modpack.json").read_text(encoding="utf-8-sig"))
        client_mods = [entry for entry in client["files"] if entry["folder"] == "mods"]
        filenames = [entry["filename"] for entry in client_mods]
        self.assertEqual(len(filenames), len(set(filenames)), "duplicate client filename")
        by_filename = {entry["filename"]: entry for entry in client_mods}

        for mod in server["mods"]:
            if mod["client_side"] != "required":
                continue
            with self.subTest(mod=mod["name"]):
                self.assertTrue(mod["filename"] in by_filename, f"missing client mod: {mod['name']}")
                item = by_filename[mod["filename"]]
                self.assertEqual(mod["download_url"], item["url"])
                if item["hash_algorithm"] == "SHA512":
                    self.assertEqual(mod["sha512"].lower(), item["hash"].lower())


if __name__ == "__main__":
    unittest.main()
