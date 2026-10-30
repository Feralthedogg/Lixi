from contextlib import closing
import http.client
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import HTTPServer

SPEC = importlib.util.spec_from_file_location("lixi_control", Path(__file__).with_name("control.py"))
control = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(control)


class ControlTest(unittest.TestCase):
    def directory(self):
        root = Path(__file__).resolve().parents[2] / "test/tmp"
        root.mkdir(parents=True, exist_ok=True)
        return tempfile.TemporaryDirectory(dir=root)

    def test_settings_are_strict_and_private_atomic_files_are_preserved(self):
        with self.directory() as directory:
            path = Path(directory) / "swapping.json"
            control.save_settings(path, dict(control.DEFAULTS))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(control.read_json(path, {}), control.DEFAULTS)
            for body in ({"soundCheck": 1, "autoMix": True}, {"soundCheck": False}, []):
                with self.assertRaises(ValueError):
                    control.save_settings(path, body)
            self.assertEqual(control.read_json(path, {}), control.DEFAULTS)
            pending = path.with_suffix(".pending")
            pending.write_text("preserve existing unknown file")
            with self.assertRaises(FileExistsError):
                control.save_settings(path, dict(control.DEFAULTS))
            self.assertEqual(pending.read_text(), "preserve existing unknown file")

    def test_host_origin_csrf_guards_and_no_credentials_in_html_or_state(self):
        with self.directory() as directory:
            env_path = Path(directory) / ".env"
            env_path.write_text("LIXI_PASSWORD=private-password\nDISCORD_BOT_TOKEN=private-bot-token\n")
            client = control.Control(env_path)
            server = HTTPServer(("127.0.0.1", 0), control.handler(client, 0))
            port = server.server_port
            server.RequestHandlerClass = control.handler(client, port)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(server.server_close)
            self.addCleanup(thread.join)
            self.addCleanup(server.shutdown)

            def request(method, path, body=None, headers=None):
                with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=2)) as connection:
                    connection.request(method, path, body=body, headers=headers or {})
                    response = connection.getresponse()
                    return response.status, response.read().decode()

            status, html = request("GET", "/")
            self.assertEqual(status, 200)
            self.assertIn("사운드 자동 조절", html)
            self.assertNotIn("private-password", html)
            self.assertNotIn("private-bot-token", html)
            self.assertEqual(request("GET", "/api/state", headers={"Host": "evil.example"})[0], 403)
            payload = json.dumps({"soundCheck": False, "autoMix": True})
            headers = {"Origin": f"http://127.0.0.1:{port}", "Content-Type": "application/json"}
            self.assertEqual(request("POST", "/api/settings", payload, headers)[0], 403)
            headers["X-Lixi-Control"] = client.csrf
            headers["Origin"] = "https://evil.example"
            self.assertEqual(request("POST", "/api/settings", payload, headers)[0], 403)
            headers["Origin"] = f"http://127.0.0.1:{port}"
            self.assertEqual(request("POST", "/api/settings", payload, headers)[0], 200)
            status, body = request("GET", "/api/state")
            self.assertEqual(status, 200)
            self.assertFalse(json.loads(body)["desired"]["soundCheck"])
            self.assertNotIn("private-password", body)
            self.assertNotIn("private-bot-token", body)

    def test_controls_reject_nonloopback_credential_targets(self):
        with self.directory() as directory:
            path = Path(directory) / ".env"
            path.write_text("LIXI_URL=https://example.com\nLIXI_PASSWORD=secret\n")
            with self.assertRaises(ValueError):
                control.Control(path)


if __name__ == "__main__":
    unittest.main()
