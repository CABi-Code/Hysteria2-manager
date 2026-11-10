#!/usr/bin/env python3
"""Солёный хэш IP-адресов клиентов — единственная его реализация в менеджере.

Адрес клиента не хранится и не уходит соседям в открытом виде: вместо него —
«h» + 16 hex от HMAC-SHA256(соль, адрес). Совпадение хэшей = совпадение адресов,
поэтому счёт устройств, анти-абуз и «чужое устройство» работают как раньше, а
сам адрес из хэша не восстановить без соли. Соль общая на кластер и меняется
раз в месяц (ip_salt_sync в lib/ip_tracking.sh), см. docs/guide/DATA-RETENTION.md.

Режимы (соль — путь к файлу «эпоха соль»):
  scrub SALT_FILE   stdin → stdout построчно: каждый IPv4/IPv6 заменить хэшем.
                    Годится и как фильтр вывода демона перед journald.
  map SALT_FILE     stdin: по адресу на строку → «адрес<TAB>хэш».
  derive SECRET_FILE EPOCH   печатает соль эпохи, выведенную из секрета кластера.

Без соли (файла нет, пустой) адрес заменяется на «?» — «адрес неизвестен»:
открытым он не уходит никогда, а онлайн считает такую сессию одним устройством.
"""
import hashlib
import hmac
import ipaddress
import os
import re
import sys
import time

# Кандидаты: IPv4 и всё, что похоже на IPv6 (две и больше «:»). Проверку делает
# ipaddress — «04:21:30» и прочие времена кандидатами быть могут, но не пройдут.
_CAND = re.compile(r"(?<![\w.:])(\d{1,3}(?:\.\d{1,3}){3}|[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?::\d{1,3}(?:\.\d{1,3}){3})?)(?![\w.])")
SALT_RELOAD_SEC = 30


def _addr(tok):
    try:
        a = ipaddress.ip_address(tok)
    except ValueError:
        return None
    if a.version == 6 and a.ipv4_mapped:
        a = a.ipv4_mapped
    return a


class Hasher:
    def __init__(self, salt_file):
        self.salt_file = salt_file
        self.salt = None
        self.checked = 0
        self.mtime = None

    def _load(self):
        now = time.monotonic()
        if self.salt is not None and now - self.checked < SALT_RELOAD_SEC:
            return
        self.checked = now
        try:
            st = os.stat(self.salt_file)
            if st.st_mtime == self.mtime and self.salt is not None:
                return
            with open(self.salt_file) as f:
                parts = f.read().split()
            self.salt = parts[1].encode() if len(parts) >= 2 else None
            self.mtime = st.st_mtime
        except OSError:
            self.salt = None

    def hash(self, tok):
        a = _addr(tok)
        if a is None:
            return None
        if a.is_loopback or a.is_unspecified:
            return str(a)          # 127.0.0.1 и 0.0.0.0 — не клиенты, по ним фильтруют
        self._load()
        if not self.salt:
            return "?"
        return "h" + hmac.new(self.salt, str(a).encode(), hashlib.sha256).hexdigest()[:16]

    def scrub(self, line):
        def sub(m):
            h = self.hash(m.group(1))
            return h if h is not None else m.group(0)
        return _CAND.sub(sub, line)


def main(argv):
    if len(argv) >= 3 and argv[1] == "derive":
        with open(argv[2]) as f:
            secret = f.read().strip().encode()
        print(hmac.new(secret, ("hy2-ipsalt|" + argv[3]).encode(), hashlib.sha256).hexdigest())
        return 0
    if len(argv) < 3 or argv[1] not in ("scrub", "map"):
        sys.stderr.write(__doc__)
        return 2
    h = Hasher(argv[2])
    out = sys.stdout
    # readline, а не итерация по stdin: фильтр журнала обязан отдавать строку
    # сразу, а не копить буфер, пока демон не напишет ещё.
    while True:
        line = sys.stdin.readline()
        if not line:
            return 0
        if argv[1] == "map":
            ip = line.strip()
            v = h.hash(ip) if ip else None
            if v is not None:
                out.write("%s\t%s\n" % (ip, v))
        else:
            out.write(h.scrub(line))
        out.flush()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(0)
