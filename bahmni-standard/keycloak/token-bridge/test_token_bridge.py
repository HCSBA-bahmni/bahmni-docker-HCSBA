import unittest
from unittest.mock import MagicMock, patch

from token_bridge import BridgeHandler, upstream_headers


class UpstreamHeadersTest(unittest.TestCase):
    def test_replaces_basic_auth_and_hop_by_hop_headers(self):
        result = upstream_headers(
            [
                ("Authorization", "Basic unsafe"),
                ("Connection", "keep-alive"),
                ("Host", "connector"),
                ("Content-Type", "application/json"),
            ],
            "openmrs.internal",
            "access-token",
            12,
        )

        self.assertEqual("Bearer access-token", result["Authorization"])
        self.assertEqual("openmrs.internal", result["Host"])
        self.assertEqual("12", result["Content-Length"])
        self.assertNotIn("Connection", result)

    def test_reuses_the_same_request_body_for_the_single_401_retry(self):
        handler = object.__new__(BridgeHandler)
        handler.headers = {"Content-Length": "7"}
        handler.rfile = MagicMock()
        handler.rfile.read.return_value = b"payload"
        handler.command = "POST"
        handler.send_response = MagicMock()
        handler.send_header = MagicMock()
        handler.end_headers = MagicMock()
        handler.wfile = MagicMock()
        handler._request_upstream = MagicMock(side_effect=[
            (401, "Unauthorized", [], b""),
            (200, "OK", [], b"accepted"),
        ])

        with patch("token_bridge.TOKENS") as tokens:
            tokens.get.side_effect = ["expired-token", "fresh-token"]
            handler._proxy()

        handler.rfile.read.assert_called_once_with(7)
        handler._request_upstream.assert_any_call("expired-token", b"payload")
        handler._request_upstream.assert_any_call("fresh-token", b"payload")
        tokens.invalidate.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
