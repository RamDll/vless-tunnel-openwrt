# vless-tunnel-openwrt

Минимальный клиент выборочной маршрутизации VLESS для OpenWrt на Xray-core.
Ядро только Xray (нужны XHTTP и VLESS Encryption `mlkem768x25519plus`).

Требования: OpenWrt 25.12+, `apk`, `fw4`/`ucode` (входят по умолчанию).
Проверено на Cudy WR3000S (MT7981, aarch64) и на Docker-стенде.

## Установка: три варианта

Один установщик, режим — первым аргументом. Ставится всегда один режим;
повторный запуск с другим режимом аккуратно переключает (или
`vless-tunnel mode …` уже после установки). Веб-интерфейс и CLI одинаковы.

| | `whitelist` | `proxy` | `dns` |
|---|---|---|---|
| что в туннель | `domains`/`subnets` | весь веб, кроме RU и `direct-domains` | `domains`/`subnets` |
| кто решает | Xray по TLS SNI / HTTP Host | Xray по SNI + `geoip:ru` | nftables по DNS-ответу (dnsmasq `nftset=`) |
| клиент с DoH в обход роутера | работает | работает | мимо списка |
| прямой трафик | через Xray роутера | через Xray роутера | ядром, без userspace |
| ставит дополнительно | — | `geoip.dat` (~16 МБ) | `dnsmasq-full` |

**whitelist** — в туннель только то, что в списках. Рекомендуется для начала.

```sh
wget -qO /tmp/install.sh https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main/install.sh && VLESS_TUNNEL_BASE_URL=https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main sh /tmp/install.sh whitelist
```

**proxy** — новые заблокированные сайты вписывать не нужно: всё зарубежное
идёт в туннель само.

```sh
wget -qO /tmp/install.sh https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main/install.sh && VLESS_TUNNEL_BASE_URL=https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main sh /tmp/install.sh proxy
```

**dns** — прямой трафик вообще не трогает userspace, но клиент с
DNS-over-HTTPS в обход роутера идёт мимо списка.

```sh
wget -qO /tmp/install.sh https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main/install.sh && VLESS_TUNNEL_BASE_URL=https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main sh /tmp/install.sh dns
```

Ссылку сервера можно сразу передать вторым аргументом:
`sh /tmp/install.sh proxy "vless://..."`. Без неё — потом
`vless-tunnel set-link "vless://..."`. Дальше `vless-tunnel on`.

Установщик сам скачивает остальные файлы и сверяет `sha256sums`, ставит
`xray-core` и модули `kmod-nft-tproxy`/`kmod-nf-tproxy`. Повторный запуск
без режима — обновление: режим, ссылка и списки остаются как были.

Без GitHub: `local-deploy/vless-tunnel-local.tar.gz` — те же файлы одним
архивом. Скопировать на роутер, распаковать в пустой каталог и запустить
`sh install.sh <режим>` оттуда.

Если только что запушили изменения и сразу ставите — `raw.githubusercontent.com`
кеширует файлы на 5 минут независимо друг от друга; «контрольные суммы не
сошлись» в этом окне обычно означает не подмену, а то, что часть файлов
отдалась из кеша, а часть — уже свежая. Подождите пару минут и повторите.

## Удаление

```sh
vless-tunnel uninstall            # всё, кроме пакета xray-core
vless-tunnel uninstall --purge    # и xray-core тоже
```

Убирает службу, nft-правила, DNS-файл dnsmasq, конфигурацию, списки,
веб-страницу и сам `vless-tunnel`. Flow offloading возвращается в то
состояние, что было до установки. `dnsmasq-full` (режим `dns`) остаётся —
он работает как обычный dnsmasq.

## Что делается во всех режимах

**DNS доменов из списка — через туннель.** dnsmasq отправляет запросы к
доменам из `domains` не провайдеру, а через туннель на `1.1.1.1` (запрос
уходит уже с сервера). Провайдерский DNS подменяет часть заблокированных
доменов (Ростелеком: `instagram.com` → `127.0.0.1`, и такое соединение до
роутера вообще не доходит), а прямой запрос к `1.1.1.1` из дома для
`youtube.com`/`www.facebook.com` получает поддельный NXDOMAIN. Остальной DNS
идёт как обычно, через провайдера. Выключить: `uci set
vless-tunnel.main.tunnel_dns=0`.

**Fallback.** Xray раз в 30 с проверяет сервер через туннель. Если тот не
отвечает (VPS лёг, путь «дом ↔ VPS» режется), всё, что шло в туннель, идёт
напрямую, а DNS доменов из списка — на DNS провайдера, пока сервер не
вернётся. Заблокированное при этом не откроется, но остальной интернет у
квартиры не пропадает. Состояние видно в `vless-tunnel status` и на
веб-странице. Выключить: `uci set vless-tunnel.main.fallback=0`.

**Сервер туннеля — мимо Xray роутера.** IP из ссылки попадает в nft-сеты
`vless4_server`/`vless6_server`, поэтому десктопный VLESS-клиент или
VPN-приложение на телефоне с той же ссылкой работают и за роутером.

**Flow offloading выключается**: с TPROXY он несовместим — offload уводит
часть соединений мимо netfilter/туннеля. Если включить его позже вручную,
`doctor` покажет FAIL с командой исправления.

После `uci set …` — `uci commit vless-tunnel && /etc/init.d/vless-tunnel restart`.

## Режим proxy

Правила по порядку:

| # | Условие | Куда |
|---|---|---|
| 1 | домен в `direct-domains` | напрямую |
| 2 | домен в `domains` или IP в `subnets` | в туннель |
| 3 | домен `.ru` / `.su` / `.рф` | напрямую |
| 4 | IP из `geoip:ru` | напрямую |
| 5 | TCP 80/443/8443, UDP 443 | в туннель |
| 6 | всё остальное | напрямую |

Так `xda-developers.com` и `wow.aethus.pl` попадают в туннель автоматически,
а `vk.com` (RU-адрес) и `sberbank.ru` остаются прямыми. Торренты, игры и SSH
на нестандартных портах идут напрямую — но, как и весь TCP/UDP из LAN,
транзитом через Xray роутера (userspace), не в туннель.

Цена: весь иностранный веб идёт через туннель — это ~61 Мбит/с на
соединение и ~176 Мбит/с суммарно на этом железе. Если конкретный сервис
через VPN тормозит или показывает капчу — добавьте его в исключения:

```sh
vless-tunnel add-direct example.com
vless-tunnel remove-direct example.com
vless-tunnel direct-domains
```

`geoip.dat` — статический снимок, не подписка; `install.sh proxy` качает его
сам, обновляется вручную `vless-tunnel update-geo` (старый файл сохраняется
как `.bak`). Без него режим `proxy` работает, но RU-адреса на `.com`
(например, `vk.com`) уйдут в туннель — `doctor` об этом предупредит.

Тонкость: `route_only=0` в `/etc/config/vless-tunnel` отдаёт домен на резолв
серверу. Но у sniffed-трафика тогда пропадает IP назначения, и правило
`geoip:ru` перестаёт срабатывать: RU-сайты на `.com` придётся вписать в
`direct-domains`. С DNS через туннель это обычно не нужно.

## Использование

```sh
vless-tunnel status            # текущее состояние, режим, доступность сервера
vless-tunnel on / off          # включить / выключить туннель
vless-tunnel test              # проверить связь с сервером
vless-tunnel doctor            # диагностика окружения
vless-tunnel mode [whitelist|proxy|dns]
vless-tunnel update-geo        # обновить geoip.dat (для mode=proxy)
vless-tunnel add-domain <d>    # домен в туннель (приоритетнее режима)
vless-tunnel remove-domain <d>
vless-tunnel add-direct <d>    # домен всегда напрямую
vless-tunnel remove-direct <d>
vless-tunnel uninstall [--purge]
vless-tunnel help              # список всех команд
```

`mode dns` после установки в другом режиме требует `dnsmasq-full` — его
ставит только `sh install.sh dns` (замена dnsmasq — операция, которую
установщик делает аккуратно: пакеты качаются до удаления старого).

Веб-интерфейс: `http://192.168.1.1/t.html` (без пароля, только LAN; замените
на IP своего роутера, если он другой). Не выносите его в гостевую сеть/VLAN —
без пароля он рассчитан именно на доверенный LAN.

**DoH (`https-dns-proxy`) по умолчанию не ставится.** Глобальный DoH
периодически сам создаёт проблемы: резолверы режут/троттлят, а Cloudflare
без ECS отдаёт не те CDN-плечи, а домены из списка и так резолвятся через
туннель. Если нужен: `VLESS_TUNNEL_DOH=1 sh /tmp/install.sh <режим>`.
DoH шифрует DNS-запрос, но не ECH — SNI остаётся видимым.

Подробности архитектуры, найденные баги и решения — в [HANDOFF.md](HANDOFF.md).
