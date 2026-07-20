# Лимит скорости для всех протоколов (Стадия 3)

## Зачем

Kernel-лимит скорости (`hy2-limit`, tc HTB+fq_codel, `lib/perf.sh`) шейпил ТОЛЬКО
`udp + порт Hysteria`. VLESS/SS/Trojan (Xray, TCP) и TUIC (sing-box, UDP др.
порт) шли **мимо** лимита — ни глобальный потолок, ни персональный тариф на них
не действовали.

## Что сделано

Введён список **`SHAPE`** — `protonum:port` всех шейпимых протоколов
(`17`=udp, `6`=tcp), строится `_klimit_shape_ports` из включённых протоколов:
Hysteria (udp, `get_port`), TUIC (udp, `proto_tuic_port`), SS (tcp+udp,
`proto_ss_port`), VLESS (tcp, `proto_vless_port`), Trojan (tcp,
`proto_trojan_port`). Пример: `17:38268 17:2053 6:8443 6:8444`.

По `SHAPE` строятся:
- **catch-all** (prio 2, весь туннель → глобальный класс `1:1`) — `build_dev`;
- **ingress-зеркало** на IFB (для шейпинга отдачи) — `setup_ifb`;
- **пер-IP фильтры** (prio 1, IP → тарифный класс) — `_reconcile_dev`.

Каждый — по фильтру на каждый `(proto,port)`. `SHAPE` пишется в `klimit.conf` и
запекается в сгенерированный `klimit.sh`. Тариф по-прежнему назначается **по IP**
(источник `AUTHMAP_FILE`+`IPS_FILE`), поэтому трафик клиента на ЛЮБОМ протоколе с
известного IP режется его тарифом.

## Совместимость / безопасность

`SHAPE` пуст (старый `klimit.conf` без него) → фолбэк `17:$PORT` = прежнее
поведение (только Hysteria). Поэтому cron `klimit_reconcile` не меняет живой
шейпинг, пока `klimit_apply` не перегенерирует конфиг/скрипт с `SHAPE`.
Активация — вызовом `klimit_apply` (меню лимита скорости) или перезапуском лимита.

## Ограничения

- Шейпинг **пер-IP**, не пер-user: на общем CGNAT-IP несколько юзеров делят класс
  (берётся максимальный тариф) — существующее поведение, теперь и для доп.
  протоколов.
- IP, ни разу не виденный Hysteria/подпиской, не попадёт в раскладку тарифов →
  такой трафик идёт в глобальный класс `1:1` (глобальный лимит всё равно
  действует). TUIC-only IP-адреса — типичный случай (см.
  tuic-no-per-user-attribution); их пер-тариф не гарантирован, глобальный — да.
- IPv6-клиенты не шейпятся tc (идут в глобальный класс) — как и раньше.

## Файлы
- `lib/perf.sh` — `_klimit_shape_ports`, `SHAPE` в `klimit_apply`/`klimit.conf`,
  `_klimit_write_script` (запекает SHAPE), `build_dev`/`setup_ifb` (цикл по SHAPE
  в генерируемом скрипте), `_reconcile_dev`/`klimit_reconcile` (пер-IP по SHAPE).

## Проверка
- `tc filter show dev <dev>` — фильтры на все порты SHAPE (udp+tcp).
- Speedtest под тарифом на каждом протоколе (VLESS/TUIC/Trojan) — режется по тарифу.
- `tc -s class show dev <dev>` — трафик идёт в тарифный класс IP.
