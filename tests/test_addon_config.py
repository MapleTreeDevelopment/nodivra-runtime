"""Deployment contract: HA appends ingress_entry to its session URL."""
import re
import unittest
from pathlib import Path


class AddonConfigTests(unittest.TestCase):
    def test_ingress_entry_is_relative_to_the_home_assistant_session(self):
        root = Path(__file__).resolve().parents[2]
        config = root / "Runtime" / "addon" / "config.yaml"
        if not config.exists():
            config = Path(__file__).resolve().parents[1] / "nodivra_runtime" / "config.yaml"
        match = re.search(r"^ingress_entry:\s*(\S+)", config.read_text(), re.MULTILINE)
        self.assertIsNotNone(match)
        entry = match.group(1).strip("\"'")
        self.assertFalse(entry.startswith("/"))
        self.assertNotIn("//", "/api/hassio_ingress/session/" + entry)
