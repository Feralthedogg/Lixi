import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import youtube_media


class MediaBoundaryTest(unittest.TestCase):
    def test_rejects_foreign_urls_before_starting_extractor(self):
        with patch.object(youtube_media, "execute") as execute:
            with self.assertRaises(ValueError):
                youtube_media.playlist(Path("unused"), "https://example.com/playlist?list=abc")
            execute.assert_not_called()

    def test_existing_media_is_preserved(self):
        root = Path(__file__).resolve().parents[2] / "test/tmp"
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as directory:
            target = Path(directory) / "2KPEHohJMuw.webm"
            target.write_bytes(b"existing user file")
            with self.assertRaises(ValueError):
                youtube_media.download(Path("unused"), "https://www.youtube.com/watch?v=2KPEHohJMuw", Path(directory))
            self.assertEqual(target.read_bytes(), b"existing user file")

    def test_failed_acquisition_removes_only_its_partial_output(self):
        root = Path(__file__).resolve().parents[2] / "test/tmp"
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as directory:
            target = Path(directory) / "2KPEHohJMuw.webm"
            unrelated = Path(directory) / "keep.txt"
            unrelated.write_text("user data")

            def failed_download(_, arguments, __):
                Path(arguments[arguments.index("--output") + 1]).write_bytes(b"partial")
                raise RuntimeError("timeout")

            with patch.object(youtube_media, "execute", side_effect=failed_download):
                with self.assertRaises(RuntimeError):
                    youtube_media.download(Path("unused"), "https://www.youtube.com/watch?v=2KPEHohJMuw", Path(directory))
            self.assertFalse(target.exists())
            self.assertEqual(unrelated.read_text(), "user data")

    def test_refuses_silently_truncated_playlists(self):
        output = json.dumps({"entries": [{"id": "2KPEHohJMuw"}] * 1001}).encode()
        with patch.object(youtube_media, "execute", return_value=output):
            with self.assertRaises(ValueError):
                youtube_media.playlist(Path("unused"), "https://www.youtube.com/playlist?list=abc")


if __name__ == "__main__":
    unittest.main()
