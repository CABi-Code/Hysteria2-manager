#!/bin/bash
# Потолок на неудачную аутентификацию Web API (P-140, webapi/wa_core.py):
# источник блокируется после AUTH_FAIL_MAX отказов, чужие источники не задеты,
# окно истекает.
cd "$(dirname "$0")/../webapi" || exit 1
HY2M_DATA_DIR=$(mktemp -d) python3 - <<'PY' || { echo "FAIL: test-webapi-authlimit"; exit 1; }
import wa_core as c
assert not c.auth_blocked("1.2.3.4")
for _ in range(c.AUTH_FAIL_MAX - 1):
    c.auth_failed("1.2.3.4")
assert not c.auth_blocked("1.2.3.4"), "заблокирован раньше потолка"
c.auth_failed("1.2.3.4")
assert c.auth_blocked("1.2.3.4"), "не заблокирован на потолке"
assert not c.auth_blocked("5.6.7.8"), "задет чужой источник"
c._auth_fail["1.2.3.4"][1] -= c.AUTH_FAIL_WINDOW + 1
assert not c.auth_blocked("1.2.3.4"), "окно не истекло"
PY
echo "OK: test-webapi-authlimit"
