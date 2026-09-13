#!/bin/sh
# install-dns.sh — установка vless-tunnel на OpenWrt, вариант "-dns"
#
# Независимый альтернативный установщик: архитектура «решение туннель/
# напрямую принимает nftables по DNS-наблюдению» (домен резолвится через
# dnsmasq, который тегирует IP в nftables-сет директивой nftset=), а не
# «Xray решает через sniffing TLS SNI/HTTP Host», как в основном install.sh.
# Устойчивость к DNS-over-HTTPS на клиенте хуже, зато прямой (не из списков)
# трафик никогда не трогает userspace — полный offload ядра. См. HANDOFF.md,
# «Эволюция архитектуры».
#
# Ставится в ТЕ ЖЕ системные пути, что и основной вариант — install.sh и
# install-dns.sh нельзя иметь оба активными одновременно, установка одного
# аккуратно вытесняет другой (нужные сеты/chain пересоздаются, лишние —
# снимаются). Веб-страница (vless-tunnel-web) общая для обоих: CLI-команды
# и формат `status` у /usr/bin/vless-tunnel одинаковы независимо от того,
# какой из двух вариантов установлен.
#
# Использование:
#   sh install-dns.sh                  установить, ссылку задать потом
#   sh install-dns.sh "vless://..."    установить и сразу задать ссылку
#
# Ставит снэпшот domains/subnets (если их там ещё нет) и по возможности —
# https-dns-proxy для DoH-резолва самого роутера (см. HANDOFF.md).

set -e

FILES="vless-tunnel-dns vless-tunnel-dns.init vless-tunnel-dns.config 10-vless-tunnel-dns.nft vless-tunnel-web vless-tunnel-redirect.html domains subnets"
WORK_DIR="/tmp/vless-tunnel-install.$$"
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

log()  { echo "vless-tunnel-dns install: $*"; }
die()  { echo "vless-tunnel-dns install: ошибка: $*" >&2; exit 1; }
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
		die "контрольные суммы не сошлись — файлы повреждены или подменены"
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

# Этому варианту dnsmasq-full нужен по-настоящему: домен из списка
# тегируется в nftables-сет директивой nftset=, а штатный (не -full)
# dnsmasq на OpenWrt собран без поддержки nftset.
DM_VER=$(dnsmasq --version 2>&1 || true)
if echo "$DM_VER" | grep -q 'no-nftset'; then
	NEED_FULL=1
elif echo "$DM_VER" | grep -q ' nftset'; then
	NEED_FULL=0
else
	NEED_FULL=1
fi
if [ "$NEED_FULL" = "1" ]; then
	log "меняю dnsmasq на dnsmasq-full (обычный собран без nftset) —" \
		"apk делает это одной транзакцией, DNS пропадёт на несколько секунд"
	apk add dnsmasq-full || die "не удалось установить dnsmasq-full"
else
	log "dnsmasq уже с поддержкой nftset"
fi

CONFDIR=$(uci -q get dhcp.@dnsmasq[0].confdir || true)
if [ -z "$CONFDIR" ]; then
	log "настраиваю dhcp.@dnsmasq[0].confdir=/tmp/dnsmasq.d (нужно, чтобы dnsmasq подхватывал списки доменов)"
	uci set dhcp.@dnsmasq[0].confdir=/tmp/dnsmasq.d
	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi

# --- этап 3: файлы проекта -------------------------------------------------

log "устанавливаю файлы"
cp "$WORK_DIR/10-vless-tunnel-dns.nft" /etc/nftables.d/10-vless-tunnel.nft
cp "$WORK_DIR/vless-tunnel-dns.init" /etc/init.d/vless-tunnel
chmod 0755 /etc/init.d/vless-tunnel
cp "$WORK_DIR/vless-tunnel-dns" /usr/bin/vless-tunnel
chmod 0755 /usr/bin/vless-tunnel

if [ -f /etc/config/vless-tunnel ]; then
	log "/etc/config/vless-tunnel уже существует — не трогаю"
else
	cp "$WORK_DIR/vless-tunnel-dns.config" /etc/config/vless-tunnel
fi

# Снэпшот доменов/подсетей (itdoginfo/allow-domains на момент сборки
# этого install-dns.sh) — тоже не трогаем, если список уже свой, набранный
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
# Та же осторожность, что и в основном install.sh: не fw4 reload (рядом
# может быть другой сервис со своими nft-правилами мимо /etc/nftables.d,
# как форкоп на этом роутере), а точечный nft -f. Chain пересоздаются
# заново (nft иначе задваивает в них правила при повторном запуске);
# имена chain — те же, что и у основного варианта (vless_prerouting[6]),
# поэтому переключение между вариантами их просто заменяет.

log "подключаю nftables-правила"
nft delete chain inet fw4 vless_prerouting 2>/dev/null || true
nft delete chain inet fw4 vless_prerouting6 2>/dev/null || true
nft delete chain inet fw4 vless_forward6 2>/dev/null || true
{
	echo 'table inet fw4 {'
	cat /etc/nftables.d/10-vless-tunnel.nft
	echo '}'
} > "$WORK_DIR/wrapped.nft"
nft -c -f "$WORK_DIR/wrapped.nft" || die "nft-правила не проходят проверку"
nft -f "$WORK_DIR/wrapped.nft" || die "не удалось применить nft-правила"

# --- этап 5: первичная настройка -------------------------------------------

vless-tunnel setup "$1"

# Если служба уже была включена (переустановка/переключение с другого
# варианта) — перезапускаем сразу, чтобы dns_up()/sets_load() отработали
# по новым спискам, а не по тому, что было заведено предыдущим вариантом.
if [ "$(uci -q get vless-tunnel.main.enabled)" = "1" ]; then
	log "служба была включена — перезапускаю"
	/etc/init.d/vless-tunnel restart
fi

# --- этап 6: DoH для DNS самого роутера (по возможности) -------------------
#
# Апстрим-резолв самого роутера (dnsmasq -> провайдерский DNS) переводим
# на DNS-over-HTTPS через https-dns-proxy. В этом варианте dnsmasq и так
# в центре схемы (nftset=) — DoH тут ортогонален: меняет только то, куда
# сам dnsmasq стучится за ответом, `nftset=`-тегирование срабатывает на
# forward-ответе так же, как и с обычным upstream. Мягко: если пакет не
# встал (например, конфликт с forkop — apk объявляет `breaks` между ними),
# не валим всю установку — см. HANDOFF.md, "DNS роутера в сторону
# апстрима".
if apk info -e https-dns-proxy >/dev/null 2>&1; then
	log "https-dns-proxy уже установлен — не трогаю"
elif apk add https-dns-proxy >/tmp/vless-tunnel-doh-install.log 2>&1; then
	log "https-dns-proxy установлен — настраиваю (Cloudflare, без force_dns)"
	uci -q delete https-dns-proxy.@https-dns-proxy[1]
	uci set https-dns-proxy.config.force_dns='0'
	uci commit https-dns-proxy
	uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'
	uci -q del_list dhcp.@dnsmasq[0].doh_server='127.0.0.1#5054'
	uci -q del_list dhcp.@dnsmasq[0].doh_backup_server='127.0.0.1#5054'
	uci commit dhcp
	/etc/init.d/https-dns-proxy enable
	/etc/init.d/https-dns-proxy restart
	/etc/init.d/dnsmasq restart
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
