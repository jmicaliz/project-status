"""Verify Cloudflare Access JWTs (RS256) with the standard library alone."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import threading
import time
import urllib.request
from typing import Callable

SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")
LEEWAY = 60
KEYS_TTL = 3600
REFETCH_AFTER = 60


class AccessError(Exception):
    pass


def b64url(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def b64url_int(part: str) -> int:
    return int.from_bytes(b64url(part), "big")


def rs256_valid(signing_input: bytes, signature: bytes, n: int, e: int) -> bool:
    """Check an RSASSA-PKCS1-v1_5 SHA-256 signature."""
    size = (n.bit_length() + 7) // 8
    digest_info = SHA256_DIGEST_INFO + hashlib.sha256(signing_input).digest()
    if len(signature) != size or size < len(digest_info) + 11:
        return False
    s = int.from_bytes(signature, "big")
    if s >= n:
        return False
    expected = b"\x00\x01" + b"\xff" * (size - len(digest_info) - 3) + b"\x00" + digest_info
    return hmac.compare_digest(pow(s, e, n).to_bytes(size, "big"), expected)


class Verifier:
    def __init__(
        self,
        team_domain: str,
        aud: str,
        fetch: Callable[[], dict] | None = None,
        clock: Callable[[], float] = time.time,
    ):
        self.issuer = f"https://{team_domain}"
        self.certs_url = f"{self.issuer}/cdn-cgi/access/certs"
        self.aud = aud
        self.fetch = fetch or self.fetch_certs
        self.clock = clock
        self.keys: dict[str, tuple[int, int]] = {}
        self.fetched_at: float | None = None
        self.lock = threading.Lock()

    def fetch_certs(self) -> dict:
        with urllib.request.urlopen(self.certs_url, timeout=10) as response:
            return json.load(response)

    def key(self, kid: object) -> tuple[int, int] | None:
        with self.lock:
            age = None if self.fetched_at is None else self.clock() - self.fetched_at
            if age is None or age > KEYS_TTL or (kid not in self.keys and age >= REFETCH_AFTER):
                self.keys = {
                    k["kid"]: (b64url_int(k["n"]), b64url_int(k["e"]))
                    for k in self.fetch().get("keys", [])
                    if k.get("kty") == "RSA" and "kid" in k
                }
                self.fetched_at = self.clock()
            return self.keys.get(kid) if isinstance(kid, str) else None

    def verify(self, token: str) -> dict:
        try:
            header_b64, payload_b64, signature_b64 = token.split(".")
            header = json.loads(b64url(header_b64))
            claims = json.loads(b64url(payload_b64))
            signature = b64url(signature_b64)
        except ValueError as exc:
            raise AccessError("malformed token") from exc
        if not isinstance(header, dict) or header.get("alg") != "RS256":
            raise AccessError("unsupported algorithm")
        key = self.key(header.get("kid"))
        if key is None:
            raise AccessError("unknown signing key")
        if not rs256_valid(f"{header_b64}.{payload_b64}".encode(), signature, *key):
            raise AccessError("bad signature")
        if not isinstance(claims, dict):
            raise AccessError("malformed claims")
        now = self.clock()
        exp = claims.get("exp")
        if not isinstance(exp, (int, float)) or exp + LEEWAY < now:
            raise AccessError("expired")
        nbf = claims.get("nbf")
        if isinstance(nbf, (int, float)) and nbf - LEEWAY > now:
            raise AccessError("not yet valid")
        if claims.get("iss") != self.issuer:
            raise AccessError("wrong issuer")
        aud = claims.get("aud")
        if self.aud not in (aud if isinstance(aud, list) else [aud]):
            raise AccessError("wrong audience")
        return claims
