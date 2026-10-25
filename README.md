# vless-tunnel-openwrt

Минимальный клиент выборочной маршрутизации VLESS для OpenWrt на Xray-core.
Ядро только Xray (нужны XHTTP и VLESS Encryption `mlkem768x25519plus`).

Два режима маршрутизации:

- **whitelist** (по умолчанию) — в туннель только `domains`/`subnets`,
  остальное напрямую. Обратная совместимость с прежним поведением.
- **proxy** — в туннель весь веб (TCP 80/443/8443, UDP 443), кроме
  RU-доменов/адресов и `direct-domains`. Новые заблокированные сайты
  (`xda-developers.com`, `wow.aethus.pl`, что угодно ещё) не нужно вписывать
  руками: они зарубежные — значит, в туннель.

Требования: OpenWrt 25.12+, `apk`, `fw4`/`ucode` (входят по умолчанию).
Проверено на Cudy WR3000S (MT7981, aarch64) и на Docker-стенде.

Установщик сам выключает software/hardware **flow offloading**: с TPROXY он
несовместим — offload уводит часть соединений мимо netfilter/туннеля, и
они выходят напрямую. Если включить его позже вручную, `doctor` покажет
FAIL с командой исправления.

Трафик LAN к **самому серверу туннеля** идёт мимо Xray роутера: IP из
ссылки при каждом старте службы попадает в nft-сеты `vless4_server`/
`vless6_server`. Поэтому десктопный VLESS-клиент или VPN-приложение на
телефоне с той же ссылкой работают и за роутером — без этого роутер
заворачивал их в свой туннель, и они не работали вовсе.

## Установка

Два независимых варианта — ставится всегда только один, второй аккуратно
вытесняет первый при переустановке. Веб-интерфейс и CLI-команды одинаковы
у обоих.

**Вариант A — sniffing (рекомендуется).** Решение «туннель или напрямую»
принимает Xray по TLS SNI / HTTP Host самого соединения. Устойчив к
DNS-over-HTTPS на клиенте. Только у этого варианта есть режим `proxy`.

```sh
wget -qO /tmp/install.sh https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main/install.sh && VLESS_TUNNEL_BASE_URL=https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main sh /tmp/install.sh
```

Или сразу со ссылкой сервера — вторым аргументом:

```sh
wget -qO /tmp/install.sh https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main/install.sh && VLESS_TUNNEL_BASE_URL=https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main sh /tmp/install.sh "vless://..."
```

**Вариант B — DNS (`-dns`).** Решение принимает nftables по членству IP
в сете, который наполняет dnsmasq. Прямой трафик не трогает userspace
(полный offload), но уязвим к DoH на клиенте.

```sh
wget -qO /tmp/install-dns.sh https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main/install-dns.sh && VLESS_TUNNEL_BASE_URL=https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main sh /tmp/install-dns.sh
```

Или сразу со ссылкой сервера:

```sh
wget -qO /tmp/install-dns.sh https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main/install-dns.sh && VLESS_TUNNEL_BASE_URL=https://raw.githubusercontent.com/RamDll/vless-tunnel-openwrt/main sh /tmp/install-dns.sh "vless://..."
```

Оба скрипта сами скачивают остальные файлы и сверяют `sha256sums`,
ставят `xray-core` и модули `kmod-nft-tproxy`/`kmod-nf-tproxy`.

**DoH (`https-dns-proxy`) по умолчанию не ставится.** Глобальный DoH
периодически сам создаёт проблемы: резолверы режут/троттлят, а Cloudflare
без ECS отдаёт не те CDN-плечи. Для этой архитектуры он и не нужен — SNI
всё равно виден провайдеру. Если DoH всё-таки нужен:

```sh
VLESS_TUNNEL_DOH=1 sh /tmp/install.sh
```

Если только что запушили изменения и сразу ставите — `raw.githubusercontent.com`
кеширует файлы на 5 минут независимо друг от друга; «контрольные суммы не
сошлись» в этом окне обычно означает не подмену, а то, что часть файлов
отдалась из кеша, а часть — уже свежая. Подождите пару минут и повторите.

## Режим proxy

Включается одной командой, обратимо:

```sh
vless-tunnel update-geo      # один раз: скачать geoip.dat (~16 МБ)
vless-tunnel mode proxy
```

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

Вернуться к прежнему поведению: `vless-tunnel mode whitelist`.

`geoip.dat` — статический снимок, не подписка; обновляется вручную
`vless-tunnel update-geo` (старый файл сохраняется как `.bak`). Без него
режим `proxy` работает, но RU-адреса на `.com` (например, `vk.com`) уйдут
в туннель — `doctor` об этом предупредит.

Тонкость: если провайдер подменяет DNS-ответы, можно поставить
`route_only=0` в `/etc/config/vless-tunnel` — тогда домен резолвит сервер.
Но у sniffed-трафика пропадает IP назначения, и правило `geoip:ru`
перестаёт срабатывать: RU-сайты на `.com` придётся вписать в
`direct-domains`.

## Использование

```sh
vless-tunnel status            # текущее состояние и режим
vless-tunnel on / off          # включить / выключить туннель
vless-tunnel test              # проверить связь с сервером
vless-tunnel doctor            # диагностика окружения
vless-tunnel mode [proxy|whitelist]
vless-tunnel update-geo        # обновить geoip.dat (для mode=proxy)
vless-tunnel add-domain <d>    # домен в туннель (приоритетнее режима)
vless-tunnel remove-domain <d>
vless-tunnel add-direct <d>    # домен всегда напрямую
vless-tunnel remove-direct <d>
vless-tunnel help              # список всех команд
```

Веб-интерфейс: `http://192.168.1.1/t.html` (без пароля, только LAN; замените
на IP своего роутера, если он другой). Не выносите его в гостевую сеть/VLAN —
без пароля он рассчитан именно на доверенный LAN.

DoH шифрует DNS-запрос, но не ECH — SNI остаётся видимым. Для сервисов,
которым важно спрятать и это, полагайтесь не на список доменов, а на IP
в `subnets`.

Подробности архитектуры, найденные баги и решения — в [HANDOFF.md](HANDOFF.md).
