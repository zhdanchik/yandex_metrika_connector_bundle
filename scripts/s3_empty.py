#!/usr/bin/env python3
"""
Empty a Yandex Object Storage bucket using only the Python stdlib.

Reads AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY from the environment
and speaks the S3 v4-signed REST API to storage.yandexcloud.net.

Usage:
    s3_empty.py <bucket-name>
"""

import datetime as dt
import hashlib
import hmac
import os
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ENDPOINT = "storage.yandexcloud.net"
REGION = "ru-central1"
SERVICE = "s3"
NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, date_stamp: str) -> bytes:
    k_date    = _sign(("AWS4" + secret).encode("utf-8"), date_stamp)
    k_region  = _sign(k_date, REGION)
    k_service = _sign(k_region, SERVICE)
    return _sign(k_service, "aws4_request")


def _request(method: str, bucket: str, path: str, query: dict,
             body: bytes, access_key: str, secret_key: str,
             extra_headers: dict | None = None) -> tuple[int, bytes]:
    host = f"{bucket}.{ENDPOINT}"
    canonical_uri = path or "/"
    canonical_query = "&".join(
        f"{urllib.parse.quote(k, safe='')}={urllib.parse.quote(str(v), safe='')}"
        for k, v in sorted(query.items())
    )
    now = dt.datetime.now(dt.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()

    headers = {
        "host":                 host,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date":           amz_date,
    }
    if extra_headers:
        headers.update(extra_headers)

    signed_headers = ";".join(sorted(headers))
    canonical_headers = "".join(
        f"{k}:{headers[k].strip()}\n" for k in sorted(headers)
    )
    canonical_request = "\n".join([
        method, canonical_uri, canonical_query,
        canonical_headers, signed_headers, payload_hash,
    ])

    credential_scope = f"{date_stamp}/{REGION}/{SERVICE}/aws4_request"
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amz_date, credential_scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ])
    signature = hmac.new(
        _signing_key(secret_key, date_stamp),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()

    headers["authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    url = f"https://{host}{canonical_uri}"
    if canonical_query:
        url += f"?{canonical_query}"

    req = urllib.request.Request(url, data=body or None, method=method)
    for k, v in headers.items():
        req.add_header(k, v)

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def list_objects(bucket: str, ak: str, sk: str):
    """Yield (key, version_id|None) for every object (+ version) in bucket."""
    # versioned enumeration covers both versioned and non-versioned buckets
    marker: dict = {}
    while True:
        status, body = _request("GET", bucket, "/",
                                {"versions": "", **marker}, b"", ak, sk)
        if status != 200:
            raise RuntimeError(f"list versions failed: {status} {body[:500]!r}")
        root = ET.fromstring(body)
        for tag in ("Version", "DeleteMarker"):
            for el in root.findall(f"{NS}{tag}"):
                key = el.findtext(f"{NS}Key") or ""
                ver = el.findtext(f"{NS}VersionId") or None
                yield key, ver
        if (root.findtext(f"{NS}IsTruncated") or "false").lower() != "true":
            return
        next_key = root.findtext(f"{NS}NextKeyMarker") or ""
        next_ver = root.findtext(f"{NS}NextVersionIdMarker") or ""
        marker = {"key-marker": next_key}
        if next_ver:
            marker["version-id-marker"] = next_ver


def delete_object(bucket: str, key: str, version: str | None,
                  ak: str, sk: str) -> None:
    query = {"versionId": version} if version else {}
    status, body = _request("DELETE", bucket, "/" + urllib.parse.quote(key),
                            query, b"", ak, sk)
    if status not in (200, 204):
        raise RuntimeError(f"delete {key}@{version}: {status} {body[:500]!r}")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    bucket = sys.argv[1]
    ak = os.environ.get("AWS_ACCESS_KEY_ID")
    sk = os.environ.get("AWS_SECRET_ACCESS_KEY")
    if not ak or not sk:
        print("AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY not set",
              file=sys.stderr)
        return 2

    count = 0
    for key, ver in list_objects(bucket, ak, sk):
        delete_object(bucket, key, ver, ak, sk)
        print(f"  deleted {key}" + (f"@{ver}" if ver else ""), file=sys.stderr)
        count += 1
    print(f"emptied {count} object(s) from {bucket}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
