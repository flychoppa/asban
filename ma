#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  asn-block — блокировка подключений по ASN через ipset
#  Snow VPN — https://t.me/SnowfallVPN_bot
#
#  Использование:
#    bash asn-block.sh install   — установить
#    bash asn-block.sh update    — обновить префиксы
#    bash asn-block.sh remove    — удалить
#    bash asn-block.sh status    — проверить статус
# ═══════════════════════════════════════════════════════════
set -Eeuo pipefail

# ───────────────────────────────────────────────────────────
#  НАСТРОЙКИ — редактируй здесь
# ───────────────────────────────────────────────────────────

# Порты VPN на которых блокировать (через пробел)
PORTS="${PORTS:-443}"

# ASN для блокировки (хостинги, датацентры, даблпрокси)
BLOCKED_ASNS=(
    AS13335
    AS24940   # Hetzner
    AS51167   # Contabo
    AS16276   # OVH
    AS12876   # Scaleway
    AS14061   # DigitalOcean
    AS13335   # Cloudflare
    AS20473   # Vultr
    AS9009    # M247
    AS8100    # QuadraNet
    AS59253   # Leaseweb
    AS28753   # Leaseweb DE
    AS60781   # Leaseweb NL
    AS30083   # Leaseweb USA
    AS394711  # Limenet
    AS136907  # Huawei Cloud
    AS45102   # Alibaba Cloud
    AS37963   # Alibaba Cloud CN
    AS55960   # Alibaba Cloud SG
    AS8075    # Microsoft Azure
    AS16509   # Amazon AWS
    AS14618   # Amazon AWS
    AS15169   # Google Cloud
    AS396982  # Google Cloud
    AS19527   # Google Cloud
    AS32934   # Meta (Facebook)
    AS63949   # Linode/Akamai
    AS6939    # Hurricane Electric
    AS209103  # AEZA Group
    AS216071  # AEZA Group
)

# ───────────────────────────────────────────────────────────
#  КОНСТАНТЫ
# ───────────────────────────────────────────────────────────
IPSET_NAME="asn_block"
CHAIN_NAME="ASN_BLOCK"
CONFIG_DIR="/opt/asn-block"
PREFIXES_FILE="${CONFIG_DIR}/prefixes.txt"
ASN_FILE="${CONFIG_DIR}/asns.conf"
BGP_TABLE_URL="https://bgp.tools/table.txt"
BGPTOOLS_AS_URL="https://bgp.tools/prefix"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[--]${NC} $1"; }

# ───────────────────────────────────────────────────────────
#  ЗАВИСИМОСТИ
# ───────────────────────────────────────────────────────────
install_deps() {
    local pkgs=()
    command -v ipset  &>/dev/null || pkgs+=(ipset)
    command -v curl   &>/dev/null || pkgs+=(curl)
    command -v whois  &>/dev/null || pkgs+=(whois)
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        info "Устанавливаю: ${pkgs[*]}"
        apt-get update -qq
        apt-get install -y -qq "${pkgs[@]}"
    fi
}

# ───────────────────────────────────────────────────────────
#  ПОЛУЧИТЬ ПРЕФИКСЫ ДЛЯ ASN
# ───────────────────────────────────────────────────────────
fetch_prefixes_for_asn() {
    local asn="${1^^}"
    local asn_num="${asn#AS}"

    # Пробуем bgp.tools API
    local result
    result=$(curl -sf --max-time 15 \
        "https://bgp.tools/prefix?asn=${asn_num}" \
        -H "User-Agent: asn-block/1.0 Snow-VPN" 2>/dev/null \
        | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' || true)

    # Fallback: whois RIPE/ARIN
    if [[ -z "$result" ]]; then
        result=$(whois -h whois.radb.net -- "-i origin ${asn}" 2>/dev/null \
            | grep -oP 'route:\s+\K[\d./]+' || true)
    fi

    echo "$result"
}

# ───────────────────────────────────────────────────────────
#  ОБНОВИТЬ ПРЕФИКСЫ
# ───────────────────────────────────────────────────────────
update_prefixes() {
    info "Загружаю префиксы для ${#BLOCKED_ASNS[@]} ASN..."
    mkdir -p "$CONFIG_DIR"

    # Сохраняем список ASN
    printf '%s\n' "${BLOCKED_ASNS[@]}" > "$ASN_FILE"

    local tmp_file
    tmp_file=$(mktemp)
    local total=0
    local failed=0

    for asn in "${BLOCKED_ASNS[@]}"; do
        info "  ${asn}..."
        local prefixes
        prefixes=$(fetch_prefixes_for_asn "$asn") || true
        if [[ -n "$prefixes" ]]; then
            local count
            count=$(echo "$prefixes" | wc -l)
            echo "$prefixes" >> "$tmp_file"
            log "  ${asn}: ${count} префиксов"
            total=$(( total + count ))
        else
            warn "  ${asn}: не удалось получить префиксы"
            failed=$(( failed + 1 ))
        fi
    done

    # Дедупликация и валидация CIDR
    sort -u "$tmp_file" | grep -Pv '^\s*$' | \
        grep -P '^\d+\.\d+\.\d+\.\d+/\d+$' > "$PREFIXES_FILE" || true

    rm -f "$tmp_file"

    local final
    final=$(wc -l < "$PREFIXES_FILE")
    log "Итого префиксов: $final (ASN с ошибками: $failed)"
}

# ───────────────────────────────────────────────────────────
#  ПРИМЕНИТЬ IPSET
# ───────────────────────────────────────────────────────────
apply_ipset() {
    info "Применяю ipset ${IPSET_NAME}..."

    # Создаём временный ipset и заполняем
    local tmp_set="${IPSET_NAME}_tmp"
    ipset destroy "$tmp_set" 2>/dev/null || true
    ipset create "$tmp_set" hash:net maxelem 1000000

    local loaded=0
    while IFS= read -r prefix; do
        [[ -z "$prefix" ]] && continue
        ipset add "$tmp_set" "$prefix" 2>/dev/null && loaded=$(( loaded + 1 )) || true
    done < "$PREFIXES_FILE"

    # Атомарный swap
    if ipset list "$IPSET_NAME" &>/dev/null; then
        ipset swap "$tmp_set" "$IPSET_NAME"
        ipset destroy "$tmp_set"
    else
        ipset rename "$tmp_set" "$IPSET_NAME"
    fi

    log "ipset ${IPSET_NAME}: загружено ${loaded} записей"
}

# ───────────────────────────────────────────────────────────
#  ПРИМЕНИТЬ IPTABLES
# ───────────────────────────────────────────────────────────
apply_iptables() {
    info "Настраиваю iptables цепочку ${CHAIN_NAME}..."

    # Создаём цепочку если нет
    iptables -N "$CHAIN_NAME" 2>/dev/null || true

    # Очищаем цепочку
    iptables -F "$CHAIN_NAME" 2>/dev/null || true

    # Правило в цепочке: если IP в ipset — DROP
    iptables -A "$CHAIN_NAME" \
        -m set --match-set "$IPSET_NAME" src \
        -j DROP

    # Вставляем переход из INPUT и FORWARD (для Docker)
    for chain in INPUT FORWARD; do
        for port in $PORTS; do
            # Удаляем старые правила (если есть)
            iptables -D "$chain" \
                -p tcp --dport "$port" \
                -j "$CHAIN_NAME" 2>/dev/null || true
            # Вставляем в начало
            iptables -I "$chain" 1 \
                -p tcp --dport "$port" \
                -j "$CHAIN_NAME"
        done
    done

    # Docker-USER chain если есть
    if iptables -L DOCKER-USER &>/dev/null 2>&1; then
        for port in $PORTS; do
            iptables -D DOCKER-USER \
                -p tcp --dport "$port" \
                -j "$CHAIN_NAME" 2>/dev/null || true
            iptables -I DOCKER-USER 1 \
                -p tcp --dport "$port" \
                -j "$CHAIN_NAME"
        done
        log "DOCKER-USER: правила добавлены"
    fi

    log "iptables: цепочка ${CHAIN_NAME} настроена (порты: ${PORTS})"
}

# ───────────────────────────────────────────────────────────
#  УСТАНОВИТЬ SYSTEMD (персистентность)
# ───────────────────────────────────────────────────────────
install_systemd() {
    info "Устанавливаю systemd unit..."

    # Скрипт обновления
    cat > /usr/local/sbin/asn-block-update.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
exec bash /opt/asn-block/asn-block.sh update_apply
SCRIPT
    chmod +x /usr/local/sbin/asn-block-update.sh

    # Копируем основной скрипт
    cp "$(realpath "$0")" /opt/asn-block/asn-block.sh
    chmod +x /opt/asn-block/asn-block.sh

    # Apply сервис (применяет ipset+iptables при старте)
    cat > /etc/systemd/system/asn-block-apply.service << 'UNIT'
[Unit]
Description=ASN Block — apply ipset and iptables
After=network.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/asn-block-update.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

    # Update сервис (загружает свежие префиксы)
    cat > /etc/systemd/system/asn-block-update.service << 'UNIT'
[Unit]
Description=ASN Block — update prefixes
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/asn-block/asn-block.sh update_apply
UNIT

    # Таймер — обновление раз в сутки в 03:00
    cat > /etc/systemd/system/asn-block-update.timer << 'UNIT'
[Unit]
Description=ASN Block — daily update timer

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable --now asn-block-apply.service
    systemctl enable --now asn-block-update.timer

    log "systemd: asn-block-apply.service + asn-block-update.timer установлены"
}

# ───────────────────────────────────────────────────────────
#  УДАЛИТЬ
# ───────────────────────────────────────────────────────────
remove() {
    warn "Удаляю asn-block..."

    systemctl stop asn-block-apply.service asn-block-update.timer 2>/dev/null || true
    systemctl disable asn-block-apply.service asn-block-update.timer 2>/dev/null || true
    rm -f /etc/systemd/system/asn-block-apply.service
    rm -f /etc/systemd/system/asn-block-update.service
    rm -f /etc/systemd/system/asn-block-update.timer
    systemctl daemon-reload

    # Убираем iptables правила
    for chain in INPUT FORWARD DOCKER-USER; do
        for port in $PORTS; do
            iptables -D "$chain" \
                -p tcp --dport "$port" \
                -j "$CHAIN_NAME" 2>/dev/null || true
        done
    done
    iptables -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -X "$CHAIN_NAME" 2>/dev/null || true

    # Удаляем ipset
    ipset destroy "$IPSET_NAME" 2>/dev/null || true

    rm -rf /opt/asn-block
    rm -f /usr/local/sbin/asn-block-update.sh

    log "asn-block удалён"
}

# ───────────────────────────────────────────────────────────
#  СТАТУС
# ───────────────────────────────────────────────────────────
status() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ ASN Block Status ═══${NC}"
    echo ""

    echo "▸ ipset:"
    if ipset list "$IPSET_NAME" &>/dev/null; then
        local cnt
        cnt=$(ipset list "$IPSET_NAME" | grep -c '/' || true)
        echo "  ${IPSET_NAME}: ${cnt} записей"
    else
        echo "  ${IPSET_NAME}: не существует"
    fi

    echo ""
    echo "▸ iptables:"
    iptables -L "$CHAIN_NAME" -n -v --line-numbers 2>/dev/null || echo "  цепочка не найдена"

    echo ""
    echo "▸ systemd:"
    systemctl is-active asn-block-apply.service 2>/dev/null && \
        echo "  asn-block-apply.service: active" || \
        echo "  asn-block-apply.service: inactive"
    systemctl is-active asn-block-update.timer 2>/dev/null && \
        echo "  asn-block-update.timer: active" || \
        echo "  asn-block-update.timer: inactive"

    echo ""
    echo "▸ Список ASN:"
    cat "$ASN_FILE" 2>/dev/null | sed 's/^/  /' || echo "  файл не найден"
    echo ""
}

# ───────────────────────────────────────────────────────────
#  ТОЧКА ВХОДА
# ───────────────────────────────────────────────────────────
ACTION="${1:-install}"

echo -e "${CYAN}${BOLD}"
echo "╔═══════════════════════════════════════════════╗"
echo "║       asn-block — Snow VPN ASN blocker       ║"
echo "╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

[[ "$(id -u)" -ne 0 ]] && err "Запустите от root"

case "$ACTION" in
    install)
        install_deps
        update_prefixes
        apply_ipset
        apply_iptables
        install_systemd
        echo ""
        log "=== ✅ asn-block установлен ==="
        log "Порты     : ${PORTS}"
        log "ASN       : ${#BLOCKED_ASNS[@]} штук"
        log "Префиксов : $(wc -l < "$PREFIXES_FILE")"
        log "Обновление: ежедневно в 03:00"
        ;;
    update)
        install_deps
        update_prefixes
        ;;
    update_apply)
        apply_ipset
        apply_iptables
        ;;
    remove)
        remove
        ;;
    status)
        status
        ;;
    *)
        err "Неизвестное действие: $ACTION. Используй: install | update | remove | status"
        ;;
esac
