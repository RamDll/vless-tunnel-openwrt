#!/bin/sh
# install.sh — установка vless-tunnel на OpenWrt
#
# Использование:
#   sh install.sh [whitelist|proxy|dns] ["vless://..."]
#
#   whitelist — в туннель только domains/subnets (по умолчанию при первой
#               установке); решение принимает Xray по TLS SNI/HTTP Host
#   proxy     — в туннель весь веб, кроме RU-доменов/адресов и
#               direct-domains; заодно скачивает geoip.dat (~16 МБ)
#   dns       — в туннель domains/subnets, решение по DNS в nftables;
#               ставит dnsmasq-full (обычный собран без nftset)
#
# Без режима повторный запуск (обновление) оставляет режим прежним. Ссылку
# можно передать и единственным аргументом, как раньше: sh install.sh "vless://..."
# Удаление: vless-tunnel uninstall [--purge]
#
# Ищет рядом с собой файлы проекта (см. FILES). Если их нет — скачивает с
# $VLESS_TUNNEL_BASE_URL вместе с sha256sums и проверяет суммы, прежде чем
# что-либо трогать на диске (см. HANDOFF.md, архитектурное решение 4:
# распространение — установочный скрипт, не .apk).
#
# Ничего не переустанавливает вслепую при повторном запуске: пакеты через
# apk идемпотентны, nft-правила собирает `vless-tunnel _apply-nft` одной
# транзакцией (destroy + объявление заново, без задвоения правил),
# существующие /etc/config/vless-tunnel и списки не трогаются.
#
# DoH (https-dns-proxy) по умолчанию не ставится — только с VLESS_TUNNEL_DOH=1
# (см. HANDOFF.md, «DNS роутера в сторону апстрима»).

set -e

FILES="vless-tunnel vless-tunnel.init vless-tunnel.config 10-vless-tunnel.nft 10-vless-tunnel-dns.nft vless-tunnel-web vless-tunnel-redirect.html domains subnets"
WORK_DIR="/tmp/vless-tunnel-install.$$"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SHARE_DIR=/usr/share/vless-tunnel

log()  { echo "vless-tunnel install: $*"; }
die()  { echo "vless-tunnel install: ошибка: $*" >&2; exit 1; }
# Если установка оборвалась посреди замены dnsmasq — вернуть резолвер.
cleanup() {
	[ -f "$WORK_DIR/resolv.conf" ] && cat "$WORK_DIR/resolv.conf" > /etc/resolv.conf
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

VARIANT=
case "$1" in
	whitelist|proxy|dns) VARIANT=$1; shift ;;
esac
LINK=$1

[ "$(id -u)" = "0" ] || die "нужен root"
command -v apk   >/dev/null 2>&1 || die "нужен apk — установщик не для opkg-роутеров"
command -v fw4   >/dev/null 2>&1 || die "нужен fw4 (firewall4)"
command -v ucode >/dev/null 2>&1 || die "нужен ucode"

if [ -z "$VARIANT" ]; then
	VARIANT=$(uci -q get vless-tunnel.main.mode || true)
	# Прежний install-dns.sh режим в UCI не писал — узнаём его по nft-файлу.
	[ -z "$VARIANT" ] && grep -q vless4_dns /etc/nftables.d/10-vless-tunnel.nft 2>/dev/null && VARIANT=dns
	case "$VARIANT" in whitelist|proxy|dns) : ;; *) VARIANT=whitelist ;; esac
fi
log "режим: $VARIANT"

if [ -r /etc/openwrt_release ]; then
	. /etc/openwrt_release
	case "$DISTRIB_ARCH" in
		aarch64*) : ;;
		*) log "предупреждение: собрано и проверено на aarch64_cortex-a53, здесь ${DISTRIB_ARCH:-неизвестно}" ;;
	esac
fi

mkdir -p "$WORK_DIR"

# --- этап 1: собрать файлы проекта в $WORK_DIR, проверенными -------------

stage_local() {
	for f in $FILES; do [ -f "$SELF_DIR/$f" ] || return 1; done
	for f in $FILES; do cp "$SELF_DIR/$f" "$WORK_DIR/$f"; done
	log "файлы взяты из $SELF_DIR"
}

stage_remote() {
	[ -n "$VLESS_TUNNEL_BASE_URL" ] ||
		die "рядом со скриптом нет файлов проекта, а \$VLESS_TUNNEL_BASE_URL не задан"
	log "скачиваю с $VLESS_TUNNEL_BASE_URL"
	wget -qO "$WORK_DIR/sha256sums.all" "$VLESS_TUNNEL_BASE_URL/sha256sums" ||
		die "не удалось скачать sha256sums"
	: > "$WORK_DIR/sha256sums"
	for f in $FILES; do
		grep -- "  $f\$" "$WORK_DIR/sha256sums.all" >> "$WORK_DIR/sha256sums" ||
			die "в sha256sums нет записи для $f — не устанавливаю"
		wget -qO "$WORK_DIR/$f" "$VLESS_TUNNEL_BASE_URL/$f" ||
			die "не удалось скачать $f"
	done
	( cd "$WORK_DIR" && sha256sum -c sha256sums ) ||
		die "контрольные суммы не сошлись — файлы повреждены или подменены (или просто попали в окно 5-минутного кеша raw.githubusercontent.com сразу после обновления репозитория — подождите пару минут и повторите)"
}

stage_local || stage_remote
for f in $FILES; do [ -s "$WORK_DIR/$f" ] || die "файл $f пуст"; done

# --- этап 2: пакеты -------------------------------------------------------

log "обновляю индекс пакетов"
apk update || log "предупреждение: часть фидов недоступна, продолжаю с тем, что есть"

if apk info -e xray-core >/dev/null 2>&1; then
	log "xray-core уже установлен"
else
	log "устанавливаю xray-core"
	apk add xray-core || die "не удалось установить xray-core"
fi

# Явно, не полагаясь на то, что их кто-то другой затянет транзитивно —
# так уже было на реальном роутере: модули стояли только как зависимость
# стороннего сервиса (форкоп), и после его удаления пропали бы при
# следующей перезагрузке, хотя работают именно нашему TPROXY.
if apk info -e kmod-nft-tproxy >/dev/null 2>&1 && apk info -e kmod-nf-tproxy >/dev/null 2>&1; then
	log "модули ядра для TPROXY уже установлены"
else
	log "устанавливаю модули ядра для TPROXY"
	apk add kmod-nft-tproxy kmod-nf-tproxy || die "не удалось установить kmod-nft-tproxy/kmod-nf-tproxy"
fi

# Режиму dns нужен dnsmasq-full: домены тегируются в nftables-сет
# директивой nftset=, а штатный dnsmasq на OpenWrt собран без неё.
#
# Замена опасна: apk сначала удаляет dnsmasq и только потом качает
# остальное, а резолвер самого роутера (/etc/resolv.conf → 127.0.0.1) — это
# и есть dnsmasq. Скачивание падало, и роутер оставался без DNS и DHCP на
# весь LAN (воспроизведено на стенде). Поэтому: --cache-predownload качает
# все пакеты ДО начала транзакции, а на время замены роутер резолвит
# напрямую через DNS провайдера. Если dnsmasq после этого всё-таки нет —
# ставим обратно обычный, пока резолвер ещё прямой.
need_dnsmasq_full() {
	DM_VER=$(dnsmasq --version 2>&1 || true)
	echo "$DM_VER" | grep -q 'no-nftset' && return 0
	echo "$DM_VER" | grep -q ' nftset' && return 1
	return 0
}

swap_dnsmasq() {
	log "меняю dnsmasq на dnsmasq-full — DNS и DHCP пропадут на несколько секунд"
	cat /etc/resolv.conf > "$WORK_DIR/resolv.conf"
	{ grep '^nameserver' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null || echo 'nameserver 1.1.1.1'; } > /etc/resolv.conf
	mkdir -p "$WORK_DIR/apk-cache"
	rc=0
	apk add --cache-dir "$WORK_DIR/apk-cache" --cache-predownload dnsmasq-full || rc=$?
	if ! command -v dnsmasq >/dev/null 2>&1; then
		log "dnsmasq пропал — возвращаю обычный"
		apk add dnsmasq || true
	fi
	cat "$WORK_DIR/resolv.conf" > /etc/resolv.conf
	rm -f "$WORK_DIR/resolv.conf"
	/etc/init.d/dnsmasq enable >/dev/null 2>&1 || true
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	[ "$rc" = "0" ] || die "не удалось установить dnsmasq-full (DNS роутера восстановлен)"
	need_dnsmasq_full && die "dnsmasq-full установлен, но dnsmasq по-прежнему без nftset"
	log "dnsmasq-full установлен"
}

if [ "$VARIANT" = "dns" ]; then
	if need_dnsmasq_full; then swap_dnsmasq; else log "dnsmasq уже с поддержкой nftset"; fi
fi

# --- этап 3: файлы проекта -------------------------------------------------

log "устанавливаю файлы"
cp "$WORK_DIR/vless-tunnel.init" /etc/init.d/vless-tunnel
chmod 0755 /etc/init.d/vless-tunnel
cp "$WORK_DIR/vless-tunnel" /usr/bin/vless-tunnel
chmod 0755 /usr/bin/vless-tunnel
# Шаблоны nft-правил обоих семейств: из них `vless-tunnel _apply-nft`
# собирает /etc/nftables.d/10-vless-tunnel.nft под текущий режим — и
# здесь, и при `vless-tunnel mode`.
mkdir -p "$SHARE_DIR"
cp "$WORK_DIR/10-vless-tunnel.nft" "$WORK_DIR/10-vless-tunnel-dns.nft" "$SHARE_DIR/"

if [ -f /etc/config/vless-tunnel ]; then
	log "/etc/config/vless-tunnel уже существует — не трогаю"
else
	cp "$WORK_DIR/vless-tunnel.config" /etc/config/vless-tunnel
fi

# Снэпшот доменов/подсетей (itdoginfo/allow-domains на момент сборки
# этого install.sh) — тоже не трогаем, если список уже свой, набранный
# руками поверх/вместо снэпшота.
mkdir -p /etc/vless-tunnel
if [ -f /etc/vless-tunnel/domains ]; then
	log "/etc/vless-tunnel/domains уже существует — не трогаю"
else
	cp "$WORK_DIR/domains" /etc/vless-tunnel/domains
fi
if [ -f /etc/vless-tunnel/subnets ]; then
	log "/etc/vless-tunnel/subnets уже существует — не трогаю"
else
	cp "$WORK_DIR/subnets" /etc/vless-tunnel/subnets
fi

if [ -d /www/cgi-bin ]; then
	cp "$WORK_DIR/vless-tunnel-web" /www/cgi-bin/vless-tunnel
	chmod 0755 /www/cgi-bin/vless-tunnel
	cp "$WORK_DIR/vless-tunnel-redirect.html" /www/t.html
	log "веб-страница: http://<роутер>/t.html (без пароля, только LAN)"
else
	log "предупреждение: /www/cgi-bin не найден (нет uhttpd?) — веб-страница не установлена"
fi

/etc/init.d/vless-tunnel enable

# setup создаёт секцию main и пустые списки, которых ещё нет; режим —
# до сборки nft-правил, они от него зависят.
vless-tunnel setup >/dev/null
uci set vless-tunnel.main.mode="$VARIANT"
uci commit vless-tunnel

# --- этап 3.5: flow offloading (несовместим с TPROXY) ----------------------
#
# На MT7981 fw4 (или LuCI) может быть включён software/hardware flow
# offload. Offload уводит установленные потоки мимо netfilter, а значит и
# мимо TPROXY: часть соединений уходит напрямую, с российским IP, хотя
# должна была идти в туннель. Симптом — «на компьютере через прокси
# открывается, а приложение на телефоне говорит, что страна не
# поддерживается». Выключаем оба вида; что было до установки, запоминаем —
# `vless-tunnel uninstall` вернёт как было.
OFF_SW=$(uci -q get firewall.@defaults[0].flow_offloading || true)
OFF_HW=$(uci -q get firewall.@defaults[0].flow_offloading_hw || true)
if [ -z "$(uci -q get vless-tunnel.main.saved_offload_sw || true)" ]; then
	uci set vless-tunnel.main.saved_offload_sw="${OFF_SW:-0}"
	uci set vless-tunnel.main.saved_offload_hw="${OFF_HW:-0}"
	uci commit vless-tunnel
fi
if [ "$OFF_SW" = "1" ] || [ "$OFF_HW" = "1" ]; then
	log "отключаю flow offloading (TPROXY с ним несовместим)"
	uci set firewall.@defaults[0].flow_offloading='0'
	uci set firewall.@defaults[0].flow_offloading_hw='0'
	uci commit firewall
	fw4 reload || /etc/init.d/firewall restart || true
fi

# --- этап 4: nftables-правила без fw4 reload -------------------------------
#
# fw4 инклюдит /etc/nftables.d/*.nft сам при следующем reload/restart сети/
# перезагрузке (архитектурное решение 2). Но включаем правила сразу и
# точечно: если рядом крутится другой сервис со своими nft-правилами мимо
# /etc/nftables.d, полный `fw4 reload` для него небезопасен.

log "подключаю nftables-правила"
vless-tunnel _apply-nft || die "nft-правила не применились"
# Служба выключена — DNS-файл прежней версии (у -dns-варианта он
# оставался в /tmp/dnsmasq.d) убираем сразу; включённую перезапустим ниже.
[ "$(uci -q get vless-tunnel.main.enabled)" = "1" ] || vless-tunnel _dns-down

# --- этап 5: первичная настройка -------------------------------------------
#
# Невалидная ссылка (например, скопированный из README буквально плейсхолдер
# "vless://...") не должна ронять всю установку — пакеты и правила уже на
# месте, дальше просто попросим задать нормальную ссылку отдельной командой.

if [ -n "$LINK" ] && ! vless-tunnel set-link "$LINK"; then
	log "предупреждение: ссылка не распознана, установка продолжается без неё"
	log "задайте её отдельно: vless-tunnel set-link \"vless://...\""
	LINK=
fi

if [ "$VARIANT" = "proxy" ] && [ ! -f /etc/vless-tunnel/geoip.dat ]; then
	log "скачиваю geoip.dat для режима proxy"
	vless-tunnel update-geo ||
		log "предупреждение: geoip.dat не скачался — RU-адреса на .com пойдут в туннель; повторите: vless-tunnel update-geo"
fi

# Если служба уже была включена (переустановка/апгрейд/смена режима) —
# перезапускаем сразу. Иначе между "новые nft-правила уже перехватывают
# всё" и "config.json ещё старый" был бы реальный зазор: старый config.json
# под новой blanket-цепочкой отправил бы В ТУННЕЛЬ абсолютно весь трафик.
if [ "$(uci -q get vless-tunnel.main.enabled)" = "1" ]; then
	log "служба была включена — перезапускаю с новым config.json"
	/etc/init.d/vless-tunnel restart
fi

# --- этап 6: DoH для DNS самого роутера (opt-in) ---------------------------
#
# Апстрим-резолв самого роутера (dnsmasq -> провайдерский DNS) можно
# перевести на DNS-over-HTTPS через https-dns-proxy. По умолчанию выключено:
# глобальный DoH периодически ломал резолв (в РФ его режут/троттлят, а
# Cloudflare без ECS отдаёт не те CDN-плечи), а домены из списка и так
# резолвятся через туннель. Включается явно: VLESS_TUNNEL_DOH=1 sh install.sh
if [ "${VLESS_TUNNEL_DOH:-0}" = "1" ]; then
	if apk info -e https-dns-proxy >/dev/null 2>&1; then
		log "https-dns-proxy уже установлен — не трогаю"
	elif apk add https-dns-proxy >/tmp/vless-tunnel-doh-install.log 2>&1; then
		log "https-dns-proxy установлен — настраиваю (Cloudflare, без force_dns)"
		uci -q delete https-dns-proxy.@https-dns-proxy[1] || true
		uci set https-dns-proxy.config.force_dns='0'
		uci commit https-dns-proxy
		uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#5054' || true
		uci -q del_list dhcp.@dnsmasq[0].doh_server='127.0.0.1#5054' || true
		uci -q del_list dhcp.@dnsmasq[0].doh_backup_server='127.0.0.1#5054' || true
		uci commit dhcp
		# apk add у https-dns-proxy сам стартует службу через post-install —
		# следующие restart иногда ловят гонку за procd-локом с этим уже
		# идущим стартом и возвращают ошибку (не зависают, но нефатально:
		# конфиг уже применён выше, а служба и так поднята постинстом).
		/etc/init.d/https-dns-proxy enable || true
		/etc/init.d/https-dns-proxy restart || log "предупреждение: https-dns-proxy restart вернул ошибку (гонка с post-install), служба и так должна быть поднята"
		/etc/init.d/dnsmasq restart || log "предупреждение: dnsmasq restart вернул ошибку, перезапустите вручную при необходимости"
	else
		log "предупреждение: https-dns-proxy не встал (см. /tmp/vless-tunnel-doh-install.log) — DNS роутера остаётся как есть"
	fi
fi

log "готово (режим $VARIANT)."
echo
if [ -z "$LINK" ] && [ -z "$(uci -q get vless-tunnel.main.link)" ]; then
	echo "Дальше:  vless-tunnel set-link \"vless://...\""
fi
echo "         vless-tunnel test      — проверить связь с сервером"
echo "         vless-tunnel on        — включить туннель"
echo "         vless-tunnel doctor    — диагностика окружения"
echo "Удалить: vless-tunnel uninstall"
