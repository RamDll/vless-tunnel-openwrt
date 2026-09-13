# vless-tunnel-openwrt

Минимальный клиент выборочной маршрутизации VLESS для OpenWrt на Xray-core:
нужные домены/подсети — в туннель, всё остальное — напрямую. Ядро только
Xray (нужны XHTTP и VLESS Encryption `mlkem768x25519plus`).

Требования: OpenWrt 25.12+, `apk`, `fw4`/`ucode` (входят по умолчанию).
Проверено на Cudy WR3000S (MT7981, aarch64).

## Установка

Два независимых варианта — ставится всегда только один, второй аккуратно
вытесняет первый при переустановке. Веб-интерфейс и CLI-команды одинаковы
у обоих.

**Вариант A — sniffing (рекомендуется).** Решение «туннель или напрямую»
принимает Xray по TLS SNI / HTTP Host самого соединения. Устойчив к
DNS-over-HTTPS на клиенте.

```sh
wget -qO /tmp/install.sh https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main/install.sh && VLESS_TUNNEL_BASE_URL=https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main sh /tmp/install.sh "vless://..."
```

**Вариант B — DNS (`-dns`).** Решение принимает nftables по членству IP
в сете, который наполняет dnsmasq. Прямой трафик не трогает userspace
(полный offload), но уязвим к DoH на клиенте.

```sh
wget -qO /tmp/install-dns.sh https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main/install-dns.sh && VLESS_TUNNEL_BASE_URL=https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main sh /tmp/install-dns.sh "vless://..."
```

Ссылку `vless://...` можно не указывать и задать потом через
`vless-tunnel set-link "vless://..."`. Оба скрипта сами скачивают
остальные файлы и сверяют `sha256sums`, ставят `xray-core` и (по
возможности) `https-dns-proxy` для DoH-резолва самого роутера.

## Использование

```sh
vless-tunnel status          # текущее состояние
vless-tunnel on / off        # включить / выключить туннель
vless-tunnel test            # проверить связь с сервером
vless-tunnel doctor          # диагностика окружения
vless-tunnel add-domain <d>  # добавить домен в список
vless-tunnel remove-domain <d>
```

Веб-интерфейс: `http://192.168.1.1/t.html` (без пароля, только LAN; замените на IP своего роутера, если он другой).

Подробности архитектуры, найденные баги и решения — в [HANDOFF.md](HANDOFF.md).
