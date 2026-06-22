#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  asn-block — блокировка подключений по ASN через ipset
#  Snow VPN — https://t.me/SnowfallVPN_bot
#
#  Использование:
#    bash asn-block.sh install   — установить
#    bash asn-block.sh update    — обновить префиксы
#    bash asn-block.sh stats     — статистика попыток по ASN
#    bash asn-block.sh reset     — сбросить счётчики
#    bash asn-block.sh status    — статус
#    bash asn-block.sh remove    — удалить
# ═══════════════════════════════════════════════════════════
set -Eeuo pipefail

# ───────────────────────────────────────────────────────────
#  НАСТРОЙКИ
# ───────────────────────────────────────────────────────────

# Порты VPN на которых блокировать (через пробел)
PORTS="${PORTS:-443}"

# ASN для блокировки (хостинги, датацентры, даблпрокси)
BLOCKED_ASNS=(
    AS13335   # Cloudflare
    AS24940   # Hetzner
    AS51167   # Contabo
    AS16276   # OVH
    AS12876   # Scaleway
    AS14061   # DigitalOcean
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
MAPPING_FILE="${CONFIG_DIR}/mapping.txt"   # формат: "1.2.3.0/24 AS13335"
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

    # Пробуем bgp.tools
    local result
    result=$(curl -sf --max-time 15 \
        "https://bgp.tools/prefix?asn=${asn_num}" \
        -H "User-Agent: asn-block/1.0 Snow-VPN" 2>/dev/null \
        | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' || true)

    # Fallback: whois RIPE/RADb
    if [[ -z "$result" ]]; then
        result=$(whois -h whois.radb.net -- "-i origin ${asn}" 2>/dev/null \
            | grep -oP 'route:\s+\K[\d./]+' || true)
    fi

    echo "$result"
}

# ───────────────────────────────────────────────────────────
#  ОБНОВИТЬ ПРЕФИКСЫ + MAPPING
# ───────────────────────────────────────────────────────────
update_prefixes() {
    info "Загружаю префиксы для ${#BLOCKED_ASNS[@]} ASN..."
    mkdir -p "$CONFIG_DIR"

    printf '%s\n' "${BLOCKED_ASNS[@]}" > "$ASN_FILE"

    local tmp_prefixes tmp_mapping
    tmp_prefixes=$(mktemp)
    tmp_mapping=$(mktemp)
    local failed=0

    for asn in "${BLOCKED_ASNS[@]}"; do
        info "  ${asn}..."
        local prefixes
        prefixes=$(fetch_prefixes_for_asn "$asn") || true
        if [[ -n "$prefixes" ]]; then
            local count
            count=$(echo "$prefixes" | wc -l)
            echo "$prefixes" >> "$tmp_prefixes"
            # сохраняем mapping prefix -> asn
            while IFS= read -r prefix; do
                [[ -z "$prefix" ]] && continue
                echo "${prefix} ${asn}" >> "$tmp_mapping"
            done <<< "$prefixes"
            log "  ${asn}: ${count} префиксов"
        else
            warn "  ${asn}: не удалось получить префиксы"
            failed=$(( failed + 1 ))
        fi
    done

    # дедупликация префиксов
    sort -u "$tmp_prefixes" | grep -Pv '^\s*$' | \
        grep -P '^\d+\.\d+\.\d+\.\d+/\d+$' > "$PREFIXES_FILE" || true

    # дедупликация маппинга — если префикс встречается в нескольких ASN, берём первый
    sort -u "$tmp_mapping" | grep -P '^\d+\.\d+\.\d+\.\d+/\d+\s+AS\d+$' \
        | awk '!seen[$1]++' > "$MAPPING_FILE" || true

    rm -f "$tmp_prefixes" "$tmp_mapping"

    local final
    final=$(wc -l < "$PREFIXES_FILE")
    log "Итого префиксов: $final (ASN с ошибками: $failed)"
}

# ───────────────────────────────────────────────────────────
#  ПРИМЕНИТЬ IPSET (с counters и сохранением счётчиков)
# ───────────────────────────────────────────────────────────
apply_ipset() {
    info "Применяю ipset ${IPSET_NAME}..."

    # Сохраняем существующие счётчики (если ipset уже есть)
    local counters_backup
    counters_backup=$(mktemp)
    local has_old=0
    if ipset list "$IPSET_NAME" &>/dev/null; then
        has_old=1
        ipset save "$IPSET_NAME" 2>/dev/null \
            | grep -P '^add\s+\S+\s+\d+\.\d+\.\d+\.\d+/\d+\s+packets\s+\d+\s+bytes\s+\d+' \
            > "$counters_backup" || true
    fi

    # Создаём временный set с включёнными counters
    local tmp_set="${IPSET_NAME}_tmp"
    ipset destroy "$tmp_set" 2>/dev/null || true
    ipset create "$tmp_set" hash:net maxelem 1000000 counters

    # Заливаем префиксы
    local loaded=0
    while IFS= read -r prefix; do
        [[ -z "$prefix" ]] && continue
        ipset add "$tmp_set" "$prefix" 2>/dev/null && loaded=$(( loaded + 1 )) || true
    done < "$PREFIXES_FILE"

    # Восстанавливаем счётчики для префиксов, которые остались
    local restored=0
    if [[ -s "$counters_backup" ]]; then
        while IFS= read -r line; do
            # формат: "add asn_block 1.2.3.0/24 packets 42 bytes 5040"
            local prefix pkt byt
            prefix=$(awk '{print $3}' <<< "$line")
            pkt=$(awk '{print $5}' <<< "$line")
            byt=$(awk '{print $7}' <<< "$line")
            [[ -z "$prefix" ]] && continue
            [[ "${pkt:-0}" -eq 0 ]] && continue
            if ipset test "$tmp_set" "$prefix" 2>/dev/null; then
                # перезаписываем с задаными counters
                ipset del "$tmp_set" "$prefix" 2>/dev/null || true
                ipset add "$tmp_set" "$prefix" packets "$pkt" bytes "$byt" 2>/dev/null \
                    && restored=$(( restored + 1 )) || true
            fi
        done < "$counters_backup"
    fi
    rm -f "$counters_backup"

    # Атомарный swap
    if [[ $has_old -eq 1 ]]; then
        # Проверяем что у старого ipset тоже есть counters (иначе swap не пройдёт)
        if ipset list "$IPSET_NAME" -terse 2>/dev/null | grep -q 'counters'; then
            ipset swap "$tmp_set" "$IPSET_NAME"
            ipset destroy "$tmp_set"
        else
            # старый без counters — пересоздаём с нуля
            warn "старый ipset без counters, пересоздаю"
            # нужно сначала отвязать iptables, иначе destroy не сработает
            for chain in INPUT FORWARD DOCKER-USER; do
                for port in $PORTS; do
                    iptables -D "$chain" -p tcp --dport "$port" -j "$CHAIN_NAME" 2>/dev/null || true
                done
            done
            iptables -F "$CHAIN_NAME" 2>/dev/null || true
            ipset destroy "$IPSET_NAME"
            ipset rename "$tmp_set" "$IPSET_NAME"
        fi
    else
        ipset rename "$tmp_set" "$IPSET_NAME"
    fi

    log "ipset ${IPSET_NAME}: загружено ${loaded} записей, восстановлено счётчиков: ${restored}"
}

# ───────────────────────────────────────────────────────────
#  ПРИМЕНИТЬ IPTABLES
# ───────────────────────────────────────────────────────────
apply_iptables() {
    info "Настраиваю iptables цепочку ${CHAIN_NAME}..."

    iptables -N "$CHAIN_NAME" 2>/dev/null || true
    iptables -F "$CHAIN_NAME" 2>/dev/null || true

    iptables -A "$CHAIN_NAME" \
        -m set --match-set "$IPSET_NAME" src \
        -j DROP

    for chain in INPUT FORWARD; do
        for port in $PORTS; do
            iptables -D "$chain" \
                -p tcp --dport "$port" \
                -j "$CHAIN_NAME" 2>/dev/null || true
            iptables -I "$chain" 1 \
                -p tcp --dport "$port" \
                -j "$CHAIN_NAME"
        done
    done

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
#  СТАТИСТИКА: попытки подключения по ASN
# ───────────────────────────────────────────────────────────
stats() {
    if ! ipset list "$IPSET_NAME" &>/dev/null; then
        err "ipset ${IPSET_NAME} не найден. Сначала: bash asn-block.sh install"
    fi
    if [[ ! -f "$MAPPING_FILE" ]]; then
        err "Файл маппинга не найден: $MAPPING_FILE. Запусти: bash asn-block.sh update"
    fi

    # Загружаем prefix -> ASN маппинг
    declare -A prefix_to_asn
    while IFS=' ' read -r prefix asn; do
        [[ -z "$prefix" ]] && continue
        prefix_to_asn[$prefix]=$asn
    done < "$MAPPING_FILE"

    # Парсим ipset list, собираем агрегат по ASN
    declare -A asn_packets
    declare -A asn_bytes
    declare -A asn_prefixes_hit
    local total_packets=0
    local total_bytes=0
    local unknown_packets=0

    while read -r prefix _ packets _ bytes; do
        [[ -z "$prefix" ]] && continue
        [[ "$prefix" != */* ]] && continue
        [[ "${packets:-0}" -eq 0 ]] && continue
        local asn="${prefix_to_asn[$prefix]:-UNKNOWN}"
        if [[ "$asn" == "UNKNOWN" ]]; then
            unknown_packets=$(( unknown_packets + packets ))
        fi
        asn_packets[$asn]=$(( ${asn_packets[$asn]:-0} + packets ))
        asn_bytes[$asn]=$(( ${asn_bytes[$asn]:-0} + bytes ))
        asn_prefixes_hit[$asn]=$(( ${asn_prefixes_hit[$asn]:-0} + 1 ))
        total_packets=$(( total_packets + packets ))
        total_bytes=$(( total_bytes + bytes ))
    done < <(ipset list "$IPSET_NAME" 2>/dev/null \
        | grep -P '^\d+\.\d+\.\d+\.\d+/\d+\s+packets\s+\d+\s+bytes\s+\d+')

    echo ""
    echo -e "${CYAN}${BOLD}═══ ASN Block — статистика попыток подключения ═══${NC}"
    echo ""

    if [[ ${#asn_packets[@]} -eq 0 ]]; then
        warn "Попыток подключения с заблокированных ASN ещё не было"
        echo ""
        echo "Подсказка: счётчики обнуляются при пересоздании ipset (например, при ребуте до восстановления)."
        echo "Если правила только что применены — подожди трафика и запусти снова."
        echo ""
        return
    fi

    # Заголовок таблицы
    printf "%-12s %14s %18s %11s\n" "ASN" "Пакетов" "Байт" "Префиксов"
    echo "──────────────────────────────────────────────────────────"

    # Сортировка по packets desc
    {
        for asn in "${!asn_packets[@]}"; do
            printf "%s\t%d\t%d\t%d\n" \
                "$asn" \
                "${asn_packets[$asn]}" \
                "${asn_bytes[$asn]}" \
                "${asn_prefixes_hit[$asn]}"
        done
    } | sort -k2,2 -t $'\t' -nr | while IFS=$'\t' read -r asn pkt byt pfx; do
        # человекочитаемые байты
        local hbyt
        hbyt=$(numfmt --to=iec --suffix=B "$byt" 2>/dev/null || echo "${byt}B")
        printf "%-12s %14d %18s %11d\n" "$asn" "$pkt" "$hbyt" "$pfx"
    done

    echo "──────────────────────────────────────────────────────────"
    local hbyt_total
    hbyt_total=$(numfmt --to=iec --suffix=B "$total_bytes" 2>/dev/null || echo "${total_bytes}B")
    printf "%-12s %14d %18s\n" "ИТОГО" "$total_packets" "$hbyt_total"

    if [[ $unknown_packets -gt 0 ]]; then
        echo ""
        warn "UNKNOWN — пакеты от префиксов, которых нет в текущем маппинге"
        warn "(вероятно, ASN был убран из списка, или префикс отозван — счётчик остался)"
    fi
    echo ""
}

# ───────────────────────────────────────────────────────────
#  СБРОС СЧЁТЧИКОВ
# ───────────────────────────────────────────────────────────
reset_counters() {
    info "Сброс счётчиков ipset ${IPSET_NAME}..."
    if ! ipset list "$IPSET_NAME" &>/dev/null; then
        err "ipset ${IPSET_NAME} не найден"
    fi
    if [[ ! -f "$PREFIXES_FILE" ]]; then
        err "Файл префиксов не найден"
    fi
    # flush + перезаливка обнуляет все счётчики
    ipset flush "$IPSET_NAME"
    local loaded=0
    while IFS= read -r prefix; do
        [[ -z "$prefix" ]] && continue
        ipset add "$IPSET_NAME" "$prefix" 2>/dev/null && loaded=$(( loaded + 1 )) || true
    done < "$PREFIXES_FILE"
    log "Счётчики сброшены, ${loaded} записей перезалито"
}

# ───────────────────────────────────────────────────────────
#  УСТАНОВИТЬ SYSTEMD
# ───────────────────────────────────────────────────────────
install_systemd() {
    info "Устанавливаю systemd unit..."

    cat > /usr/local/sbin/asn-block-update.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
exec bash /opt/asn-block/asn-block.sh update_apply
SCRIPT
    chmod +x /usr/local/sbin/asn-block-update.sh

    cp "$(realpath "$0")" /opt/asn-block/asn-block.sh
    chmod +x /opt/asn-block/asn-block.sh

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

    cat > /etc/systemd/system/asn-block-update.service << 'UNIT'
[Unit]
Description=ASN Block — update prefixes
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/asn-block/asn-block.sh update_apply
UNIT

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

    for chain in INPUT FORWARD DOCKER-USER; do
        for port in $PORTS; do
            iptables -D "$chain" \
                -p tcp --dport "$port" \
                -j "$CHAIN_NAME" 2>/dev/null || true
        done
    done
    iptables -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -X "$CHAIN_NAME" 2>/dev/null || true

    ipset destroy "$IPSET_NAME" 2>/dev/null || true

    rm -rf /opt/asn-block
    rm -f /usr/local/sbin/asn-block-update.sh

    log "asn-block удалён"
}

# ───────────────────────────────────────────────────────────
#  СТАТУС (краткий — детальная stats в отдельной команде)
# ───────────────────────────────────────────────────────────
status() {
    echo ""
    echo -e "${CYAN}${BOLD}═══ ASN Block Status ═══${NC}"
    echo ""

    echo "▸ ipset:"
    if ipset list "$IPSET_NAME" &>/dev/null; then
        local cnt
        cnt=$(ipset list "$IPSET_NAME" | grep -cP '^\d+\.\d+\.\d+\.\d+/\d+' || true)
        local has_counters
        has_counters=$(ipset list "$IPSET_NAME" -terse 2>/dev/null | grep -c 'counters' || true)
        echo "  ${IPSET_NAME}: ${cnt} записей (counters: $([ "$has_counters" -gt 0 ] && echo on || echo off))"
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

    # Краткая сводка top-5 ASN
    if ipset list "$IPSET_NAME" &>/dev/null && [[ -f "$MAPPING_FILE" ]]; then
        echo ""
        echo "▸ Топ-5 ASN по попыткам (подробно: bash asn-block.sh stats):"
        declare -A prefix_to_asn
        while IFS=' ' read -r prefix asn; do
            [[ -z "$prefix" ]] && continue
            prefix_to_asn[$prefix]=$asn
        done < "$MAPPING_FILE"

        declare -A asn_packets_status
        while read -r prefix _ packets _ _; do
            [[ -z "$prefix" ]] && continue
            [[ "${packets:-0}" -eq 0 ]] && continue
            local a="${prefix_to_asn[$prefix]:-UNKNOWN}"
            asn_packets_status[$a]=$(( ${asn_packets_status[$a]:-0} + packets ))
        done < <(ipset list "$IPSET_NAME" 2>/dev/null \
            | grep -P '^\d+\.\d+\.\d+\.\d+/\d+\s+packets\s+\d+')

        if [[ ${#asn_packets_status[@]} -eq 0 ]]; then
            echo "  (попыток ещё не было)"
        else
            for a in "${!asn_packets_status[@]}"; do
                printf "%s\t%d\n" "$a" "${asn_packets_status[$a]}"
            done | sort -k2 -nr | head -5 | while read -r a p; do
                printf "  %-12s %d пакетов\n" "$a" "$p"
            done
        fi
    fi

    echo ""
    echo "▸ Список ASN ($(wc -l < "$ASN_FILE" 2>/dev/null || echo 0) шт):"
    head -10 "$ASN_FILE" 2>/dev/null | sed 's/^/  /' || echo "  файл не найден"
    [[ -f "$ASN_FILE" && $(wc -l < "$ASN_FILE") -gt 10 ]] && echo "  ..."
    echo ""
}

# ───────────────────────────────────────────────────────────
#  ТОЧКА ВХОДА
# ───────────────────────────────────────────────────────────
ACTION="${1:-install}"

echo -e "${CYAN}${BOLD}"
echo "╔═══════════════════════════════════════════════╗"
echo "║       asn-block — Snow VPN ASN blocker        ║"
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
        log "Статистика: bash asn-block.sh stats"
        ;;
    update)
        install_deps
        update_prefixes
        ;;
    update_apply)
        apply_ipset
        apply_iptables
        ;;
    stats)
        stats
        ;;
    reset)
        reset_counters
        ;;
    remove)
        remove
        ;;
    status)
        status
        ;;
    *)
        err "Неизвестное действие: $ACTION. Используй: install | update | stats | reset | status | remove"
        ;;
esac
