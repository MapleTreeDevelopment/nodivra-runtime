"""Bounded, revocable browser pairing. No Runtime credentials leave the gateway."""
import hashlib
import hmac
import json
import secrets
import time
from collections import deque
from pathlib import Path

class BrowserAccess:
    cookie = "nodivra_dashboard_session"
    def __init__(self, path=None):
        self.path = Path(path) if path else None
        self.codes = {}
        self.sessions = {}
        self.attempts = deque(maxlen=30)
        if self.path and self.path.exists():
            try:
                data = json.loads(self.path.read_text())
                now = time.time()
                self.sessions = {k:v for k,v in data.items() if isinstance(k,str) and len(k)==64 and isinstance(v,dict) and isinstance(v.get('user'),str) and type(v.get('expires')) in (int,float) and v['expires'] > now}
            except (ValueError, OSError, AttributeError, TypeError):
                self.sessions = {}
        self.prune()
    @staticmethod
    def digest(value): return hashlib.sha256(value.encode()).hexdigest()
    def prune(self):
        now = time.time()
        self.codes = {k:v for k,v in self.codes.items() if v['expires'] > now}
        self.sessions = dict(list((k,v) for k,v in self.sessions.items() if v['expires'] > now)[-64:])
    def save(self):
        if self.path:
            temporary = self.path.with_suffix('.new')
            temporary.write_text(json.dumps(self.sessions))
            temporary.chmod(0o600)
            temporary.replace(self.path)
    def issue(self, user):
        self.prune()
        if not user: raise ValueError('user required')
        # One pending code per administrator, at most 16 total.
        self.codes = {k:v for k,v in self.codes.items() if v['user'] != user}
        if len(self.codes) >= 16: self.codes.pop(next(iter(self.codes)))
        code = f'{secrets.randbelow(10**10):010d}'
        self.codes[self.digest(code)] = {'user':user, 'expires':time.time()+300}
        return code
    def redeem(self, code):
        self.prune()
        now = time.time()
        while self.attempts and now-self.attempts[0] > 60: self.attempts.popleft()
        if len(self.attempts) >= 10: return None
        self.attempts.append(now)
        if not isinstance(code,str) or not code.isascii() or not code.isdigit() or len(code)!=10: return None
        digest = self.digest(code)
        found = next((k for k in self.codes if hmac.compare_digest(k,digest)), None)
        if found is None: return None
        user = self.codes.pop(found)['user']
        token = secrets.token_urlsafe(32)
        self.sessions[self.digest(token)] = {'user':user, 'expires':now+30*86400}
        self.prune()
        try: self.save()
        except OSError:
            self.sessions.pop(self.digest(token), None)
            return None
        return token
    def user(self, token):
        self.prune()
        if not isinstance(token,str) or len(token)>100: return None
        return self.sessions.get(self.digest(token),{}).get('user')
    def logout(self, token):
        self.sessions.pop(self.digest(token or ''),None)
        self.save()
    def revoke(self):
        self.sessions.clear(); self.codes.clear(); self.save()
