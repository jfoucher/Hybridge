#!/usr/bin/env python3
"""Fetch the secret authentication keys for your Fossil / Skagen / Citizen
hybrid watches from the vendor's cloud API.

The Hybrid HR family encrypts its file protocol with a per-watch 16-byte key.
The watch never gives this key out over Bluetooth; it only ever lived in the
official app and on the vendor's servers. This script logs in to that server
with *your own* account credentials and prints the keys for the watches
registered to your account — the same keys the official app downloaded when
you first set the watch up. Paste the 32-hex-character key for your watch into
Hybridge's "Auth key" screen.

Nothing here is Fossil's code: it is a plain HTTPS client for a documented-by-
reverse-engineering REST endpoint. It only ever sees your account and your
watches. It does not work for the older non-HR Q hybrids (e.g. the Q Grant) —
those are unencrypted and need no key at all.

Usage:
    python3 fetch_keys.py                 # prompts for email + password
    python3 fetch_keys.py --brand skagen  # pick a different vendor
    FOSSIL_EMAIL=you@example.com python3 fetch_keys.py   # email from env

Your password is read with getpass (never echoed, never stored). Prefer typing
it at the prompt over passing it any other way, so it does not end up in your
shell history or environment.

Dependencies: none. Run this only on a computer you control. Keys are redacted
unless --show-keys is passed explicitly.
"""
import argparse
import base64
import getpass
import http.cookiejar
import json
import os
import sys
import urllib.error
import urllib.request

# The login/keys endpoints are the same shape across the Fossil-built brands;
# only the host differs. Pick with --brand.
BRANDS = {
    "fossil": "https://api.fossil.linkplatforms.com/v2/",
    "fossil-legacy": "https://c.fossil.com/v2.1/",
    "skagen": "https://api.skagen.linkplatforms.com/v2.1/",
    "citizen": "https://api.citizen.linkplatforms.com/v2.1/",
}

# A browser-like UA is usually all Cloudflare wants from this JSON API.
USER_AGENT = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
)


class CloudflareChallenge(Exception):
    """Raised when the server answers with a 403 that looks like a JS challenge."""


class StdlibTransport:
    """Zero-dependency HTTP over urllib, with a cookie jar so the Cloudflare
    clearance cookie set on the first request carries to the second."""

    def __init__(self):
        jar = http.cookiejar.CookieJar()
        self._opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    def request(self, method, url, *, headers=None, json_body=None):
        data = json.dumps(json_body).encode() if json_body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("User-Agent", USER_AGENT)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        for key, value in (headers or {}).items():
            req.add_header(key, value)
        try:
            with self._opener.open(req, timeout=30) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as err:
            body = err.read().decode("utf-8", "replace")
            if err.code == 403:
                # Cloudflare's managed challenge is served as a 403 HTML page.
                raise CloudflareChallenge(body) from None
            return err.code, body


def fetch_keys(transport, base_url, email, password):
    status, body = transport.request(
        "POST", base_url + "rpc/auth/login", json_body={"email": email, "password": password}
    )
    if status >= 300:
        sys.exit(f"Login failed (HTTP {status}). Check the email/password and --brand.")
    token = json.loads(body)["accessToken"]

    status, body = transport.request(
        "GET",
        base_url + "users/me/device-secret-keys",
        headers={"Authorization": "Bearer " + token},
    )
    if status >= 300:
        sys.exit(f"Could not fetch keys (HTTP {status}): {body}")
    return json.loads(body).get("_items", [])


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Print the per-watch auth keys registered to your Fossil-family account."
    )
    parser.add_argument(
        "--brand",
        choices=sorted(BRANDS),
        default="fossil",
        help="which vendor's cloud to log in to (default: fossil)",
    )
    parser.add_argument(
        "--show-keys",
        action="store_true",
        help="explicitly print authentication keys to this terminal",
    )
    parser.add_argument(
        "--email",
        default=os.environ.get("FOSSIL_EMAIL"),
        help="account email (or set FOSSIL_EMAIL; otherwise you'll be prompted)",
    )
    args = parser.parse_args()

    base_url = BRANDS[args.brand]
    email = args.email or input("Account email: ").strip()
    password = os.environ.get("FOSSIL_PASSWORD") or getpass.getpass("Password (hidden): ")

    try:
        items = fetch_keys(StdlibTransport(), base_url, email, password)
    except CloudflareChallenge:
        sys.exit("Cloudflare served a browser-only challenge; no credentials were sent to a fallback service.")

    if not items:
        print("No watches registered to this account.")
        return 0

    print(f"\n{'device id':<28} auth key (paste into Hybridge)")
    print("-" * 62)
    for item in items:
        secret = item.get("secretKey")
        # The API returns 32 raw bytes base64-encoded; the watch key is the
        # first 16 (32 hex chars). Some entries have no key (non-HR watches).
        key = base64.b64decode(secret).hex()[:32] if secret else "(none — not an HR watch)"
        print(f"{item['id']:<28} {key if args.show_keys else '(redacted; use --show-keys)'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
