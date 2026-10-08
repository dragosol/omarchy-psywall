"""Shared Hue bridge code for psywall-hue and psywall-hue-setup.

Credentials: ~/.config/psywall/hue.json, mode 0600 in a 0700 directory:
  bridge      the bridge's address ("192.168.1.20", or "host:port" for a test bridge)
  username    the application key the bridge issued at pairing
  clientkey   the 16-byte entertainment key (hex) the bridge issued at pairing
  bridgeid    the bridge's own id, from its unauthenticated config
  fingerprint sha256 of the bridge's TLS certificate, pinned at pairing
  area        the entertainment area to stream to (its id)
  positions   {light id: {x, y}} for lights outside the area (the bridge keeps
              no place for them); the area's own lights keep theirs on the bridge

Secrets never leave this process except to the pinned bridge: they are not
passed on any command line (other accounts can read /proc/<pid>/cmdline), not
logged, and not written anywhere but the 0600 file. DTLS runs in-process
through libssl, so the PSK goes from this file to OpenSSL's memory and
nowhere else.
"""

import ctypes
import ctypes.util
import errno
import hashlib
import http.client
import ipaddress
import json
import os
import select
import socket
import ssl
import time

CONF_DIR = os.environ.get("PSYWALL_CONFIG_DIR") or os.path.expanduser("~/.config/psywall")
CONF = os.path.join(CONF_DIR, "hue.json")
LIGHTS = os.path.join(CONF_DIR, "lights.json")


# ---- credentials ---------------------------------------------------------------

def load_conf(path=CONF):
    with open(path) as f:
        conf = json.load(f)
    if not isinstance(conf, dict):
        raise ValueError("not an object")
    for key in ("bridge", "username", "clientkey"):
        if not isinstance(conf.get(key), str) or not conf[key]:
            raise ValueError("missing %s" % key)
    return conf


def save_conf(conf, path=CONF):
    save_json(conf, path)


def save_json(obj, path):
    """Atomically, in the 0700 config directory: the temporary file is
    created 0600 (O_EXCL, never widened afterwards) and os.replace keeps that
    mode, so no other account can read it at any moment."""
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)   # makedirs leaves an existing directory's mode alone
    tmp = path + ".tmp"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


# The paired room, with nothing secret in it, so the bar widget can draw every
# paired light (even before anything streams) without touching hue.json:
#   {"bridge": {"name", "model", "addr", "id"}, "area": id, "areaName": str,
#    "lights": [{"id", "name", "room", "x", "y", "mode": "beat" | "glow"}]}
# "beat" lights are the entertainment area's (streamed, up to 10); "glow"
# lights get slow fades over the regular API.

def load_lights(path=LIGHTS):
    try:
        with open(path) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def save_lights(d, path=LIGHTS):
    save_json(d, path)


# ---- addresses -----------------------------------------------------------------

def split_host(addr):
    """"192.168.1.20" -> ("192.168.1.20", 443); "10.0.0.5:8443" -> (.., 8443)."""
    addr = addr.strip()
    if addr.startswith("["):                       # [v6]:port
        host, _, rest = addr[1:].partition("]")
        return host, int(rest[1:]) if rest.startswith(":") else 443
    if addr.count(":") == 1:
        host, port = addr.split(":")
        return host, int(port)
    return addr, 443


def local_address(host):
    """Only literal addresses on the local network are ever contacted: no
    hostnames (nothing to re-resolve between a check and a connect), nothing
    public. A Hue bridge lives on the LAN; anything else is refused."""
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip.is_private or ip.is_link_local or ip.is_loopback


# ---- HTTPS to the bridge -------------------------------------------------------
#
# Bridges carry a certificate from Signify's own CA (older ones a self-signed
# one), issued to the bridge id rather than to an address, so ordinary
# hostname verification can't work. Instead the certificate is pinned: its
# fingerprint is recorded at pairing (when the user is pressing the link
# button on that very bridge) and every later connection must present the
# same one, or nothing is sent — not the application key, not a request.

MAX_BODY = 8 << 20   # no real bridge answers with more; a fake one can't flood memory


class Unpinned(RuntimeError):
    """A saved pairing without a certificate fingerprint (made before pinning
    existed). Its key is never sent anywhere: the user pairs again, once."""


class PinMismatch(ssl.SSLError):
    pass


def _ctx():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE   # replaced by the fingerprint pin below
    return ctx


def cert_fingerprint(sock):
    der = sock.getpeercert(binary_form=True)
    return hashlib.sha256(der).hexdigest() if der else ""


class Conn(http.client.HTTPSConnection):
    """One kept-alive HTTPS connection that checks the pin on every connect,
    before a byte of the request goes out."""

    def __init__(self, addr, pin, timeout=5, anonymous=False):
        """pin: the fingerprint every connection must present. Only an
        anonymous connection (the discovery probe, the pairing request: no
        credential is sent on either) may go without one."""
        host, port = split_host(addr)
        if not local_address(host):
            raise ValueError("%s is not an address on the local network" % host)
        if not pin and not anonymous:
            raise Unpinned("no pinned certificate for this bridge")
        super().__init__(host, port, context=_ctx(), timeout=timeout)
        self.pin = pin
        self.seen = ""

    def connect(self):
        super().connect()
        self.seen = cert_fingerprint(self.sock)
        if self.pin and self.seen != self.pin:
            self.sock.close()
            self.sock = None
            raise PinMismatch("the bridge's certificate changed since pairing")


class Bridge:
    def __init__(self, conf):
        self.addr = conf["bridge"]
        self.host, self.port = split_host(self.addr)
        self.user = conf["username"]
        self.key = conf["clientkey"]
        self.pin = conf.get("fingerprint", "")
        if not self.pin:
            # Never "pin on first use" here: that first use would already
            # carry the key, to whatever answers at the saved address.
            raise Unpinned("no pinned certificate for this bridge; pair again")
        self.conn = None
        self.headers = None   # the last response's headers

    def raw(self, method, path, body=None, timeout=5, auth=True):
        """One request on the kept-alive connection (reopened once if the
        bridge dropped it). Returns (status, parsed JSON)."""
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Content-Type": "application/json"}
        if auth:
            headers["hue-application-key"] = self.user
        for attempt in (0, 1):
            if self.conn is None:
                self.conn = Conn(self.addr, self.pin, timeout)
            try:
                self.conn.timeout = timeout
                self.conn.request(method, path, body=data, headers=headers)
                resp = self.conn.getresponse()
                payload = resp.read(MAX_BODY + 1)
                self.headers = resp.headers
                if len(payload) > MAX_BODY:
                    raise BridgeError(resp.status, "the bridge's answer was too large")
                break
            except PinMismatch:
                self.close()
                raise
            except (OSError, http.client.HTTPException):
                self.close()
                if attempt:
                    raise
        try:
            return resp.status, json.loads(payload or b"null")
        except ValueError:
            return resp.status, None

    def application_id(self):
        """The DTLS identity: this pairing's application id (GET /auth/v1, over
        the pinned connection). Unlike the application key it is no secret,
        and a DTLS identity crosses the network in the clear."""
        status, _ = self.raw("GET", "/auth/v1")
        app_id = (self.headers or {}).get("hue-application-id", "") if status < 400 else ""
        if not app_id:
            raise BridgeError(status, "the bridge didn't give an application id (needs a current bridge firmware)")
        return app_id

    def req(self, method, path, body=None, timeout=5):
        """A CLIP v2 resource request; raises on an HTTP or bridge error."""
        status, out = self.raw(method, "/clip/v2/resource/" + path, body, timeout)
        if status >= 400 or not isinstance(out, dict):
            errs = (out or {}).get("errors") if isinstance(out, dict) else None
            msg = "; ".join(e.get("description", "") for e in errs or []) or "HTTP %d" % status
            raise BridgeError(status, msg)
        return out

    def close(self):
        if self.conn is not None:
            try:
                self.conn.close()
            except Exception:
                pass
            self.conn = None


class BridgeError(RuntimeError):
    def __init__(self, status, msg):
        super().__init__(msg)
        self.status = status


# ---- DTLS (the Entertainment API) ----------------------------------------------
#
# libssl through ctypes, so nothing secret is handed to another process.
# DTLS 1.2, PSK-AES128-GCM-SHA256, identity = the application id (not the
# key), PSK = the clientkey, port 2100 — the Hue Entertainment API's scheme.

_ssl = None

_PSK_CB = ctypes.CFUNCTYPE(ctypes.c_uint, ctypes.c_void_p, ctypes.c_char_p,
                           ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p, ctypes.c_uint)

SSL_ERROR_WANT_READ = 2
SSL_ERROR_WANT_WRITE = 3
SSL_ERROR_SYSCALL = 5
SSL_ERROR_ZERO_RETURN = 6
SSL_CTRL_SET_MIN_PROTO_VERSION = 123
SSL_CTRL_SET_MAX_PROTO_VERSION = 124
DTLS1_2_VERSION = 0xFEFD
DTLS_CTRL_GET_TIMEOUT = 73
DTLS_CTRL_HANDLE_TIMEOUT = 74
BIO_CTRL_DGRAM_SET_CONNECTED = 32
BIO_NOCLOSE = 0


class _Timeval(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_usec", ctypes.c_long)]


def _lib():
    global _ssl
    if _ssl is not None:
        return _ssl
    name = ctypes.util.find_library("ssl") or "libssl.so.3"
    L = ctypes.CDLL(name, use_errno=True)
    vp, ci, cl = ctypes.c_void_p, ctypes.c_int, ctypes.c_long
    sig = {
        "DTLS_client_method": (vp, []),
        "SSL_CTX_new": (vp, [vp]),
        "SSL_CTX_free": (None, [vp]),
        "SSL_CTX_set_cipher_list": (ci, [vp, ctypes.c_char_p]),
        "SSL_CTX_set_psk_client_callback": (None, [vp, _PSK_CB]),
        "SSL_CTX_ctrl": (cl, [vp, ci, cl, vp]),
        "SSL_new": (vp, [vp]),
        "SSL_free": (None, [vp]),
        "SSL_set_bio": (None, [vp, vp, vp]),
        "SSL_connect": (ci, [vp]),
        "SSL_write": (ci, [vp, ctypes.c_char_p, ci]),
        "SSL_read": (ci, [vp, ctypes.c_char_p, ci]),
        "SSL_shutdown": (ci, [vp]),
        "SSL_get_error": (ci, [vp, ci]),
        "SSL_ctrl": (cl, [vp, ci, cl, vp]),
        "BIO_new_dgram": (vp, [ci, ci]),
        "BIO_ctrl": (cl, [vp, ci, cl, vp]),
        "BIO_ADDR_new": (vp, []),
        "BIO_ADDR_free": (None, [vp]),
        "BIO_ADDR_rawmake": (ci, [vp, ci, vp, ctypes.c_size_t, ctypes.c_ushort]),
        "ERR_clear_error": (None, []),
    }
    for fn, (res, args) in sig.items():
        f = getattr(L, fn)
        f.restype = res
        f.argtypes = args
    _ssl = L
    return L


class DTLSError(RuntimeError):
    pass


class DTLSStream:
    """A connected DTLS 1.2 PSK client: handshake(), send(frame), closed(),
    close(). Non-blocking underneath, so a dead bridge can't hang the show."""

    def __init__(self, host, identity, psk_hex, port=2100):
        self.L = _lib()
        self.identity = identity.encode()
        self.psk = bytes.fromhex(psk_hex)
        if not self.identity or not self.psk:
            raise DTLSError("missing streaming credentials")
        self.host, self.port = host, port
        self.ctx = self.ssl = self.sock = None
        self.ok = False
        self._cb = _PSK_CB(self._psk_cb)   # kept referenced for the session's life

    def _psk_cb(self, ssl_, hint, identity, max_id, psk, max_psk):
        if len(self.identity) + 1 > max_id or len(self.psk) > max_psk:
            return 0
        ctypes.memmove(identity, self.identity + b"\0", len(self.identity) + 1)
        ctypes.memmove(psk, self.psk, len(self.psk))
        return len(self.psk)

    def handshake(self, deadline=5.0):
        L = self.L
        L.ERR_clear_error()
        self.ctx = L.SSL_CTX_new(L.DTLS_client_method())
        if not self.ctx:
            raise DTLSError("SSL_CTX_new failed")
        L.SSL_CTX_ctrl(self.ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, DTLS1_2_VERSION, None)
        L.SSL_CTX_ctrl(self.ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, DTLS1_2_VERSION, None)
        if L.SSL_CTX_set_cipher_list(self.ctx, b"PSK-AES128-GCM-SHA256") != 1:
            raise DTLSError("this OpenSSL has no PSK-AES128-GCM-SHA256")
        L.SSL_CTX_set_psk_client_callback(self.ctx, self._cb)

        family = socket.AF_INET6 if ":" in self.host else socket.AF_INET
        self.sock = socket.socket(family, socket.SOCK_DGRAM)
        self.sock.connect((self.host, self.port))
        self.sock.setblocking(False)

        self.ssl = L.SSL_new(self.ctx)
        bio = L.BIO_new_dgram(self.sock.fileno(), BIO_NOCLOSE)
        addr = L.BIO_ADDR_new()
        raw = socket.inet_pton(family, self.host)
        buf = ctypes.create_string_buffer(raw, len(raw))
        L.BIO_ADDR_rawmake(addr, family, buf, len(raw), socket.htons(self.port))
        L.BIO_ctrl(bio, BIO_CTRL_DGRAM_SET_CONNECTED, 0, addr)
        L.BIO_ADDR_free(addr)
        L.SSL_set_bio(self.ssl, bio, bio)

        end = time.monotonic() + deadline
        while True:
            r = L.SSL_connect(self.ssl)
            if r == 1:
                self.ok = True
                # A refusal queued from before the port opened isn't news now.
                self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                return
            err = L.SSL_get_error(self.ssl, r)
            left = end - time.monotonic()
            if err == SSL_ERROR_SYSCALL and ctypes.get_errno() == errno.ECONNREFUSED and left > 0:
                # The bridge opens its DTLS port a moment after "start":
                # nothing listened yet. Clear the error and send again.
                self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
                L.ERR_clear_error()
                time.sleep(0.1)
                L.SSL_ctrl(self.ssl, DTLS_CTRL_HANDLE_TIMEOUT, 0, None)
                continue
            if err not in (SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE) or left <= 0:
                why = "timed out" if left <= 0 else "failed (ssl error %d, %s)" % (
                    err, os.strerror(ctypes.get_errno()) if ctypes.get_errno() else "rejected")
                self.close()
                raise DTLSError("DTLS handshake " + why)
            tv = _Timeval()
            wait = left
            if L.SSL_ctrl(self.ssl, DTLS_CTRL_GET_TIMEOUT, 0, ctypes.byref(tv)) == 1:
                wait = min(wait, tv.tv_sec + tv.tv_usec / 1e6)
            ready, _, _ = select.select([self.sock], [], [], max(0.0, wait))
            if not ready:
                L.SSL_ctrl(self.ssl, DTLS_CTRL_HANDLE_TIMEOUT, 0, None)   # retransmit

    def send(self, data):
        """One frame = one record = one datagram. A full socket buffer drops
        the frame (the next one is 20 ms away); a dead session raises."""
        if not self.ok:
            raise DTLSError("DTLS session not established")
        r = self.L.SSL_write(self.ssl, data, len(data))
        if r > 0:
            return True
        err = self.L.SSL_get_error(self.ssl, r)
        if err in (SSL_ERROR_WANT_WRITE, SSL_ERROR_WANT_READ):
            return False
        e = ctypes.get_errno()
        raise DTLSError("DTLS session ended (%s)" % (os.strerror(e) if e else "ssl error %d" % err))

    def closed(self):
        """True once the bridge has sent an alert / close_notify, or the
        socket reports the port unreachable."""
        if not self.ok:
            return True
        if not select.select([self.sock], [], [], 0)[0]:
            return False
        buf = ctypes.create_string_buffer(512)
        r = self.L.SSL_read(self.ssl, buf, 512)
        if r > 0:
            return False
        err = self.L.SSL_get_error(self.ssl, r)
        if err == SSL_ERROR_WANT_READ:
            return False
        if err == SSL_ERROR_SYSCALL and ctypes.get_errno() in (0, errno.EAGAIN):
            return False
        return True

    def close(self):
        L = self.L
        if self.ssl:
            if self.ok:
                L.SSL_shutdown(self.ssl)
            L.SSL_free(self.ssl)   # frees the BIO too
            self.ssl = None
        if self.ctx:
            L.SSL_CTX_free(self.ctx)
            self.ctx = None
        if self.sock is not None:
            self.sock.close()
            self.sock = None
        self.ok = False
