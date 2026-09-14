#!/bin/sh
# install.sh — установка vless-tunnel на OpenWrt
#
# Использование:
#   sh install.sh                  установить, ссылку сервера задать потом
#   sh install.sh "vless://..."    установить и сразу задать ссылку
#
# Ищет рядом с собой файлы проекта (vless-tunnel, vless-tunnel.init,
# vless-tunnel.config, 10-vless-tunnel.nft, vless-tunnel-web). Если их
# нет — скачивает с
# $VLESS_TUNNEL_BASE_URL вместе с sha256sums и проверяет суммы, прежде
# чем что-либо трогать на диске (см. HANDOFF.md, архитектурное решение 4:
# распространение — установочный скрипт, не .apk).
#
# Ничего не переустанавливает вслепую при повторном запуске: пакеты через
# apk идемпотентны, свои nftables chain/set пересобираются без задвоения
# правил (nft list добавляет правила в chain заново при каждом nft -f —
# поэтому chain удаляется и создаётся заново, а не просто дополняется),
# существующий /etc/config/vless-tunnel не трогается.
#
# dnsmasq-full НЕ ставим и не трогаем: домен из списка распознаётся
# sniffing'ом внутри Xray (TLS SNI/HTTP Host самого соединения), а не по
# DNS-ответу — dnsmasq тут больше ни при чём.
#
# Есть независимый альтернативный установщик — install-dns.sh (архитектура
# «решение в nftables по DNS-наблюдению», offload лучше, но уязвима к
# DNS-over-HTTPS на клиенте — см. HANDOFF.md, «Эволюция архитектуры»).
# Ставится в те же системные пути, поэтому активен всегда только один из
# двух — установка одного варианта аккуратно вытесняет другой.
#
# Ставит снэпшот domains/subnets (если их там ещё нет) и по возможности —
# https-dns-proxy для DoH-резолва самого роутера (см. HANDOFF.md).

set -e

FILES="vless-tunnel vless-tunnel.init vless-tunnel.config 10-vless-tunnel.nft vless-tunnel-web vless-tunnel-redirect.html domains subnets"
WORK_DIR="/tmp/vless-tunnel-install.$$"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

log()  { echo "vless-tunnel install: $*"; }
die()  { echo "vless-tunnel install: ошибка: $*" >&2; exit 1; }
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

[ "$(id -u)" = "0" ] || die "нужен root"
command -v apk   >/dev/null 2>&1 || die "нужен apk — установщик не для opkg-роутеров"
command -v fw4   >/dev/null 2>&1 || die "нужен fw4 (firewall4)"
command -v ucode >/dev/null 2>&1 || die "нужен ucode"

if [ -r /etc/openwrt_release ]; then
	. /etc/openwrt_release
	case "$OPENWRT_ARCH" in
		aarch64*) : ;;
		*) log "предупреждение: собрано и проверено на aarch64_cortex-a53, здесь $OPENWRT_ARCH" ;;
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

# dnsmasq-full/confdir раньше требовались — решение "туннель или
# напрямую" принималось по членству IP в nftables-сете, который заполнял
# dnsmasq через директиву nftset= при резолве. С переходом на sniffing
# внутри Xray (домен берётся из TLS SNI/HTTP Host самого соединения, а не
# из DNS-ответа) это больше не нужно — dnsmasq не трогаем вовсе.

# Если рядом остались следы старой (dnsmasq-based) установки — подчистим,
# иначе dnsmasq будет пытаться писать в сеты, которых больше нет. Сами
# сеты vless4/vless4_dns удаляются позже (этап 4), после того как старая
# chain, которая на них ссылается, будет снесена и пересоздана.
if [ -f /tmp/dnsmasq.d/vless-tunnel.conf ]; then
	log "убираю остаток старой установки (nftset в dnsmasq больше не нужен)"
	rm -f /tmp/dnsmasq.d/vless-tunnel.conf
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi

# --- этап 3: файлы проекта -------------------------------------------------

log "устанавливаю файлы"
cp "$WORK_DIR/vless-tunnel.init" /etc/init.d/vless-tunnel
chmod 0755 /etc/init.d/vless-tunnel
cp "$WORK_DIR/vless-tunnel" /usr/bin/vless-tunnel
chmod 0755 /usr/bin/vless-tunnel

if [ -f /etc/config/vless-tunnel ]; then
	log "/etc/config/vless-tunnel уже существует — не трогаю"
else
	cp "$WORK_DIR/vless-tunnel.config" /etc/config/vless-tunnel
fi

# nft-файл — шаблон: __LAN_IFACE__/__FWMARK__/__TPROXY_PORT__ подставляются
# из UCI (те же значения, что читает vless-tunnel.init для `ip rule` и сам
# Xray для listen-порта) — иначе при смене этих настроек nft-правила молча
# расходятся с тем, что реально слушает/маркирует остальная система.
LAN_IFACE=$(uci -q get vless-tunnel.main.lan || true); LAN_IFACE=${LAN_IFACE:-br-lan}
FWMARK=$(uci -q get vless-tunnel.main.fwmark || true); FWMARK=${FWMARK:-0x1e5}
TPROXY_PORT=$(uci -q get vless-tunnel.main.tproxy_port || true); TPROXY_PORT=${TPROXY_PORT:-12345}
sed -e "s/__LAN_IFACE__/$LAN_IFACE/g" -e "s/__FWMARK__/$FWMARK/g" -e "s/__TPROXY_PORT__/$TPROXY_PORT/g" \
	"$WORK_DIR/10-vless-tunnel.nft" > /etc/nftables.d/10-vless-tunnel.nft

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

# --- этап 4: nftables-правила без fw4 reload -------------------------------
#
# fw4 инклюдит /etc/nftables.d/*.nft сам при следующем reload/restart сети/
# перезагрузке (архитектурное решение 2) — файл уже на месте и подхватится.
# Но если на роутере рядом уже крутится другой сервис со своими nft-
# правилами мимо /etc/nftables.d (как в этом проекте — форк podkop), сам
# `fw4 reload` для него небезопасен: он пересобирает весь ruleset с нуля.
# Поэтому включаем правила сразу, но точечно: chain удаляется и создаётся
# заново (nft иначе продублирует в нём правила при повторном запуске),
# а не просто накатывается поверх всего живого ruleset.

log "подключаю nftables-правила"
nft delete chain inet fw4 vless_prerouting 2>/dev/null || true
nft delete chain inet fw4 vless_prerouting6 2>/dev/null || true
# Остатки варианта "-dns" (install-dns.sh): сеты можно снести только
# после того, как ссылавшаяся на них chain уже удалена выше.
nft delete set inet fw4 vless4 2>/dev/null || true
nft delete set inet fw4 vless4_dns 2>/dev/null || true
nft delete set inet fw4 vless6 2>/dev/null || true
nft delete set inet fw4 vless6_dns 2>/dev/null || true
{
	echo 'table inet fw4 {'
	cat /etc/nftables.d/10-vless-tunnel.nft
	echo '}'
} > "$WORK_DIR/wrapped.nft"
nft -c -f "$WORK_DIR/wrapped.nft" || die "nft-правила не проходят проверку"
nft -f "$WORK_DIR/wrapped.nft" || die "не удалось применить nft-правила"

# --- этап 5: первичная настройка -------------------------------------------
#
# Невалидная ссылка (например, скопированный из README буквально плейсхолдер
# "vless://...") не должна ронять всю установку — пакеты и правила уже на
# месте, дальше просто попросим задать нормальную ссылку отдельной командой.

if ! vless-tunnel setup "$1"; then
	log "предупреждение: ссылка не распознана, установка продолжается без неё"
	log "задайте её отдельно: vless-tunnel set-link \"vless://...\""
	set -- ""
fi

# Если служба уже была включена (переустановка/апгрейд) — перезапускаем
# сразу. Иначе между "новые nft-правила уже перехватывают всё" и
# "config.json ещё старый" был бы реальный зазор: старый config.json (без
# routing/direct-фолбэка) под новой blanket-цепочкой отправил бы В ТУННЕЛЬ
# абсолютно весь трафик, а не только домены из списка.
if [ "$(uci -q get vless-tunnel.main.enabled)" = "1" ]; then
	log "служба была включена — перезапускаю с новым config.json"
	/etc/init.d/vless-tunnel restart
fi

# --- этап 6: DoH для DNS самого роутера (по возможности) -------------------
#
# Апстрим-резолв самого роутера (dnsmasq -> провайдерский DNS) переводим
# на DNS-over-HTTPS через https-dns-proxy — иначе провайдер видит в
# открытую, какие домены роутер резолвит, даже если итоговый трафик уже
# в туннеле. Мягко: если пакет не встал (например, конфликт с forkop —
# apk объявляет `breaks` между ними, и оба сразу стоять не могут), не
# валим всю установку, просто предупреждаем — см. HANDOFF.md, "DNS
# роутера в сторону апстрима".
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
	# конфиг уже применён выше, а служба и так поднята постинстом). Не
	# валим весь install ради этого — DoH в любом случае уже настроен.
	/etc/init.d/https-dns-proxy enable || true
	/etc/init.d/https-dns-proxy restart || log "предупреждение: https-dns-proxy restart вернул ошибку (гонка с post-install), служба и так должна быть поднята"
	/etc/init.d/dnsmasq restart || log "предупреждение: dnsmasq restart вернул ошибку, перезапустите вручную при необходимости"
else
	log "предупреждение: https-dns-proxy не встал (см. /tmp/vless-tunnel-doh-install.log," \
		"возможно конфликт с forkop) — DNS роутера остаётся как есть, можно настроить позже вручную"
fi

log "готово."
echo
if [ -z "$1" ]; then
	echo "Дальше:  vless-tunnel set-link \"vless://...\""
fi
echo "         vless-tunnel test      — проверить связь с сервером"
echo "         vless-tunnel on        — включить туннель"
echo "         vless-tunnel doctor    — диагностика окружения"
