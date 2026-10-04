from __future__ import annotations

import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "update_lms_plugins_repo.py"
SPEC = importlib.util.spec_from_file_location("update_lms_plugins_repo", MODULE_PATH)
assert SPEC and SPEC.loader
UPDATER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATER)


class UpdateRepositoryFeedTest(unittest.TestCase):
    def test_platform_packages_are_distinct_and_unrelated_plugins_survive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo_xml = Path(directory) / "repo.xml"
            repo_xml.write_text(
                """<?xml version='1.0' encoding='utf-8'?>
<extensions><plugins>
  <plugin name="Other" version="1"><url>other.zip</url></plugin>
  <plugin name="LastFmGuidance" version="old"><url>old.zip</url></plugin>
</plugins></extensions>
""",
                encoding="utf-8",
            )
            packages = (
                ("unix", "https://example/linux.zip", "linux-sha"),
                ("mac", "https://example/mac.zip", "mac-sha"),
                ("windows", "https://example/windows.zip", "windows-sha"),
            )

            UPDATER.update(repo_xml, "0.2.0", packages)
            first_result = repo_xml.read_bytes()
            UPDATER.update(repo_xml, "0.2.0", packages)

            self.assertEqual(repo_xml.read_bytes(), first_result)
            plugins = ET.parse(repo_xml).getroot().find("plugins")
            self.assertIsNotNone(plugins)
            entries = plugins.findall("plugin")
            self.assertEqual(
                [entry.get("name") for entry in entries],
                ["Other", "LastFmGuidance", "LastFmGuidance", "LastFmGuidance"],
            )
            lastfm = entries[1:]
            self.assertEqual(
                [entry.findtext("target") for entry in lastfm],
                ["unix", "mac", "windows"],
            )
            self.assertEqual(
                [entry.findtext("url") for entry in lastfm],
                [package[1] for package in packages],
            )
            self.assertEqual(
                [entry.findtext("sha") for entry in lastfm],
                [package[2] for package in packages],
            )
            self.assertTrue(all(entry.get("version") == "0.2.0" for entry in lastfm))
            self.assertTrue(
                all(
                    entry.findtext("title") == "Bliss Guidance: Last.fm"
                    for entry in lastfm
                )
            )


if __name__ == "__main__":
    unittest.main()
