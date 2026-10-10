"""A purpose-limited credential for the independent dashboard web service."""
import hashlib
import hmac


def display_key(runtime_key):
    if not isinstance(runtime_key, str) or len(runtime_key) < 32:
        return ""
    return hmac.new(runtime_key.encode(), b"nodivra.dashboard-display.v1", hashlib.sha256).hexdigest()


def display_request(path, method):
    # The router validates IDs; this boundary never grants draft or automation access.
    prefix = "/api/v1/dashboard-display/"
    if not path.startswith(prefix):
        return False
    parts = path[len(prefix):].split("/")
    if method == "GET":
        return parts == ["status"] or parts == ["published"] or (
            len(parts) in (2, 3, 4) and parts[0] == "published" and
            (len(parts) == 2 or len(parts) == 3 and parts[2] == "values" or
             len(parts) == 4 and parts[2] == "camera"))
    return method == "POST" and len(parts) == 3 and parts[0] == "published" and parts[2] == "actions"
