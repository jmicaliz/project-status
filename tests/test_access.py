"""Exercise scripts/access.py against a throwaway RSA key."""

import base64
import hashlib
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from access import SHA256_DIGEST_INFO, AccessError, Verifier  # noqa: E402

TEAM = "team.cloudflareaccess.com"
AUD = "aud-tag"
NOW = 1_800_000_000


def probable_prime(bits: int, rng: random.Random) -> int:
    while True:
        candidate = rng.getrandbits(bits) | (1 << (bits - 1)) | 1
        if all(candidate % p for p in (3, 5, 7, 11, 13, 17, 19, 23, 29, 31)) and miller_rabin(candidate, rng):
            return candidate


def miller_rabin(n: int, rng: random.Random) -> bool:
    d, r = n - 1, 0
    while d % 2 == 0:
        d, r = d // 2, r + 1
    for _ in range(20):
        x = pow(rng.randrange(2, n - 1), d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def keypair(seed: int) -> tuple[int, int, int]:
    rng = random.Random(seed)
    e = 65537
    while True:
        p, q = probable_prime(512, rng), probable_prime(512, rng)
        phi = (p - 1) * (q - 1)
        if p != q and phi % e:
            return p * q, e, pow(e, -1, phi)


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64_int(value: int) -> str:
    return b64(value.to_bytes((value.bit_length() + 7) // 8, "big"))


def sign(key: tuple[int, int, int], claims: dict, kid: str = "k1", alg: str = "RS256") -> str:
    n, _, d = key
    head = b64(json.dumps({"alg": alg, "kid": kid}).encode()) + "." + b64(json.dumps(claims).encode())
    size = (n.bit_length() + 7) // 8
    digest_info = SHA256_DIGEST_INFO + hashlib.sha256(head.encode()).digest()
    padded = b"\x00\x01" + b"\xff" * (size - len(digest_info) - 3) + b"\x00" + digest_info
    return head + "." + b64(pow(int.from_bytes(padded, "big"), d, n).to_bytes(size, "big"))


KEY = keypair(1)
OTHER = keypair(2)
GOOD = {"aud": [AUD], "iss": f"https://{TEAM}", "exp": NOW + 300, "email": "me@example.com"}
fetches = []


def certs() -> dict:
    fetches.append(1)
    n, e, _ = KEY
    return {"keys": [{"kty": "RSA", "kid": "k1", "n": b64_int(n), "e": b64_int(e)}]}


verifier = Verifier(TEAM, AUD, fetch=certs, clock=lambda: NOW)


def rejected(token: str) -> bool:
    try:
        verifier.verify(token)
    except AccessError:
        return True
    return False


cases = {
    "accepts a valid token": verifier.verify(sign(KEY, GOOD))["email"] == "me@example.com",
    "accepts a string aud": verifier.verify(sign(KEY, {**GOOD, "aud": AUD}))["aud"] == AUD,
    "rejects an empty token": rejected(""),
    "rejects garbage": rejected("not.a.jwt"),
    "rejects a token signed by another key": rejected(sign(OTHER, GOOD)),
    "rejects a tampered payload": rejected(
        sign(KEY, GOOD).split(".")[0] + "." + b64(json.dumps({**GOOD, "email": "x"}).encode()) + "." + sign(KEY, GOOD).split(".")[2]
    ),
    "rejects alg none": rejected(sign(KEY, GOOD, alg="none")),
    "rejects an expired token": rejected(sign(KEY, {**GOOD, "exp": NOW - 120})),
    "rejects a missing exp": rejected(sign(KEY, {k: v for k, v in GOOD.items() if k != "exp"})),
    "rejects a future nbf": rejected(sign(KEY, {**GOOD, "nbf": NOW + 600})),
    "rejects the wrong issuer": rejected(sign(KEY, {**GOOD, "iss": "https://evil.cloudflareaccess.com"})),
    "rejects the wrong audience": rejected(sign(KEY, {**GOOD, "aud": ["other"]})),
    "rejects an unknown kid": rejected(sign(KEY, GOOD, kid="k9")),
    "fetches the keys once inside the refetch window": len(fetches) == 1,
}

failed = [name for name, ok in cases.items() if not ok]
for name, ok in cases.items():
    print(("ok   " if ok else "FAIL ") + "access: " + name)
sys.exit(1 if failed else 0)
