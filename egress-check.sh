#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║          EGRESS ISP / ASN CHECKER  —  Enhanced Edition          ║
# ║   Traces routes · Identifies public hops · Visualizes ISPs      ║
# ╚══════════════════════════════════════════════════════════════════╝

TMP_STAT=$(mktemp); TMP_ALL=$(mktemp)
trap 'rm -f "$TMP_STAT" "$TMP_ALL"; tput cnorm 2>/dev/null; echo ""' EXIT
tput civis 2>/dev/null || true

# ─── ANSI palette ─────────────────────────────────────────────────────────────
R=$'\e[0m'
BOLD=$'\e[1m'; DIM=$'\e[2m'

r=$'\e[31m'; g=$'\e[32m'; y=$'\e[33m'; b=$'\e[34m'; m=$'\e[35m'; c=$'\e[36m'; w=$'\e[37m'
RR=$'\e[91m'; GG=$'\e[92m'; YY=$'\e[93m'; BB=$'\e[94m'; MM=$'\e[95m'; CC=$'\e[96m'; WW=$'\e[97m'
K=$'\e[90m'

fg256() { printf '\e[38;5;%sm' "$1"; }
bg256() { printf '\e[48;5;%sm' "$1"; }

# ─── Terminal width ───────────────────────────────────────────────────────────
TW=$(tput cols 2>/dev/null || echo 100)
[[ $TW -lt 80 ]] && TW=80

rep() {
    local char="$1" n="$2" s=""
    for ((i=0;i<n;i++)); do s+="$char"; done
    printf '%s' "$s"
}

# ─── Auto-install ──────────────────────────────────────────────────────────────
install_dep() {
    local p=$1
    printf "  ${YY}⚙${R}  Installing ${BOLD}%s${R}...\n" "$p"
    if   command -v apt-get &>/dev/null; then apt-get update -yqq && DEBIAN_FRONTEND=noninteractive apt-get install -yqq "$p" &>/dev/null
    elif command -v apk     &>/dev/null; then apk add --no-cache "$p" &>/dev/null
    elif command -v yum     &>/dev/null; then yum install -yq "$p" &>/dev/null
    elif command -v dnf     &>/dev/null; then dnf install -yq "$p" &>/dev/null
    elif command -v pacman  &>/dev/null; then pacman -Sy --noconfirm "$p" &>/dev/null
    else printf "  ${RR}✗  Cannot install '%s'. Please install manually.${R}\n" "$p"; exit 1
    fi
}
command -v curl &>/dev/null || install_dep curl
command -v mtr  &>/dev/null || install_dep mtr
command -v bc   &>/dev/null || install_dep bc

# ─── Spinner ───────────────────────────────────────────────────────────────────
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_PID=0

spinner_start() {
    local msg="$1"
    ( local i=0
      while true; do
          printf "\r  $(fg256 87)%s${R}  ${K}%s${R}   " "${SPIN_FRAMES[$((i % 10))]}" "$msg"
          (( i++ )); sleep 0.08
      done ) &
    SPIN_PID=$!
}

spinner_stop() {
    if [[ $SPIN_PID -ne 0 ]]; then
        kill "$SPIN_PID" 2>/dev/null
        wait "$SPIN_PID" 2>/dev/null || true
        SPIN_PID=0
        printf "\r\e[2K"
    fi
}

# ─── Drawing helpers ───────────────────────────────────────────────────────────
thin_rule()  { printf "${K}$(rep '─' "$TW")${R}\n"; }
thick_rule() { printf "$(fg256 240)$(rep '━' "$TW")${R}\n"; }
double_rule(){ printf "$(fg256 33)$(rep '═' "$TW")${R}\n"; }

center_line() {
    local text="$1"
    local clean; clean=$(printf '%b' "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local len=${#clean}
    local lpad=$(( (TW - len) / 2 ))
    [[ $lpad -lt 0 ]] && lpad=0
    printf "%*s%b\n" "$lpad" "" "$text"
}

# ─── Gradient text (256-color) ────────────────────────────────────────────────
gradient_line() {
    local text="$1"
    local -a palette=( 196 202 208 214 220 226 190 154 118 82 46 47 48 49 50 51 45 39 33 27 21 57 93 129 165 201 200 199 198 197 )
    local len=${#text}
    local nc=${#palette[@]}
    local out=""
    for ((i=0;i<len;i++)); do
        local ci=$(( i * (nc-1) / ( len > 1 ? len-1 : 1 ) ))
        out+="$(fg256 "${palette[$ci]}")${text:$i:1}"
    done
    printf '%b%b' "$out" "$R"
}

# ─── Category helpers ─────────────────────────────────────────────────────────
cat_color() {
    case "$1" in
        "Search/AI")  printf '%b' "$(fg256 213)" ;;
        "Social")     printf '%b' "$(fg256 75)"  ;;
        "Streaming")  printf '%b' "$(fg256 203)" ;;
        "Crypto")     printf '%b' "$(fg256 220)" ;;
        "General")    printf '%b' "$(fg256 120)" ;;
        "IP Test")    printf '%b' "$(fg256 87)"  ;;
        "Shopping")   printf '%b' "$(fg256 214)" ;;
        *)            printf '%b' "${WW}"         ;;
    esac
}

cat_dot() {
    case "$1" in
        "Search/AI")  printf "$(fg256 213)●${R}" ;;
        "Social")     printf "$(fg256 75)●${R}"  ;;
        "Streaming")  printf "$(fg256 203)●${R}" ;;
        "Crypto")     printf "$(fg256 220)●${R}" ;;
        "General")    printf "$(fg256 120)●${R}" ;;
        "IP Test")    printf "$(fg256 87)●${R}"  ;;
        "Shopping")   printf "$(fg256 214)●${R}" ;;
        *)            printf "${K}●${R}"          ;;
    esac
}

# ─── Private IP ────────────────────────────────────────────────────────────────
is_private() {
    local ip=$1
    [[ "$ip" =~ ^10\.                                             ]] && return 0
    [[ "$ip" =~ ^192\.168\.                                       ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\.                   ]] && return 0
    [[ "$ip" =~ ^127\.                                            ]] && return 0
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]] && return 0
    [[ "$ip" =~ ^169\.254\.                                       ]] && return 0
    [[ "$ip" =~ ^0\.                                              ]] && return 0
    return 1
}

# ─── Counters ──────────────────────────────────────────────────────────────────
TOTAL=0; OK_COUNT=0; FAIL_COUNT=0; ROW_NUM=0

# ─── ASN lookup + print row ───────────────────────────────────────────────────
get_asn_info() {
    local ip="$1" domain="$2" cat="$3"
    (( TOTAL++ )) || true; (( ROW_NUM++ )) || true

    # Alternating row tint
    local dim_row=""
    [[ $(( ROW_NUM % 2 )) -eq 0 ]] && dim_row="${DIM}"

    if [[ -z "$ip" ]]; then
        (( FAIL_COUNT++ )) || true
        printf "${dim_row}  ${RR}✗${R}${dim_row}  %-28s  %s  %-17s  ${RR}%-30s${R}${dim_row}  %-13s  %s${R}\n" \
            "$domain" "$(cat_dot "$cat")" "—" "Timeout / Blocked" "—" "—"
        printf 'FAIL|%s|%s||||\n' "$domain" "$cat" >> "$TMP_ALL"
        printf 'Timeout\n' >> "$TMP_STAT"
        return
    fi

    local info country isp asn
    info=$(curl -s --max-time 6 "http://ip-api.com/line/$ip?fields=country,isp,as" 2>/dev/null || true)
    country=$(printf '%s' "$info" | sed -n '1p')
    isp=$(printf '%s'     "$info" | sed -n '2p')
    asn=$(printf '%s'     "$info" | sed -n '3p')

    [[ -z "$isp" ]]     && isp="Unknown"
    [[ -z "$asn" ]]     && asn="N/A"
    [[ -z "$country" ]] && country="N/A"

    local isp_s="$isp"; [[ ${#isp_s} -gt 30 ]] && isp_s="${isp_s:0:28}.."
    local asn_s="$asn"; [[ ${#asn_s} -gt 13 ]] && asn_s="${asn_s:0:11}.."

    (( OK_COUNT++ )) || true

    printf "${dim_row}  ${GG}✓${R}${dim_row}  %-28s  %s  $(fg256 87)%-17s${R}${dim_row}  $(fg256 220)%-30s${R}${dim_row}  $(fg256 75)%-13s${R}${dim_row}  $(fg256 213)%s${R}\n" \
        "$domain" "$(cat_dot "$cat")" "$ip" "$isp_s" "$asn_s" "$country"

    printf '%s\n'                             "$isp"    >> "$TMP_STAT"
    printf 'OK|%s|%s|%s|%s|%s|%s\n' "$domain" "$cat" "$ip" "$isp" "$asn" "$country" >> "$TMP_ALL"
}

# ─── Route trace ───────────────────────────────────────────────────────────────
check() {
    local domain="$1" cat="$2"
    spinner_start "$domain"
    local output="" first_public=""

    if command -v mtr &>/dev/null; then
        output=$(mtr -r -n -c 1 --max-ttl 15 "$domain" 2>/dev/null || true)
    else
        output=$(traceroute -n -m 15 -w 2 -q 1 "$domain" 2>/dev/null || true)
    fi

    local ips
    ips=$(printf '%s\n' "$output" | grep -E '^[[:space:]]*[0-9]+' \
        | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' || true)
    for ip in $ips; do
        is_private "$ip" && continue
        first_public="$ip"; break
    done

    spinner_stop
    get_asn_info "$first_public" "$domain" "$cat"
}

# ─── Section header ────────────────────────────────────────────────────────────
section() {
    local title="$1" color_code="$2"
    echo ""
    printf "  ${BOLD}%b%s${R}\n" "$color_code" "$title"
    printf "  ${K}%-28s  %-3s  %-17s  %-30s  %-13s  %s${R}\n" \
        "Domain" "Cat" "First Public IP" "ISP" "ASN" "Country"
    thin_rule
    ROW_NUM=0
}

# ─── Bar chart ─────────────────────────────────────────────────────────────────
BAR_W=35

draw_bars() {
    declare -A counts
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "Timeout" ]] && continue
        counts["$line"]=$(( ${counts["$line"]:-0} + 1 ))
    done < "$TMP_STAT"

    [[ ${#counts[@]} -eq 0 ]] && printf "  ${K}No data.${R}\n" && return

    local sorted
    sorted=$(for k in "${!counts[@]}"; do printf '%d\t%s\n' "${counts[$k]}" "$k"; done | sort -rn)

    local max_c=0
    while IFS=$'\t' read -r cnt _; do
        [[ $cnt -gt $max_c ]] && max_c=$cnt
    done <<< "$sorted"

    # Bar color gradient from gold → blue depending on rank
    local bar_colors=( 226 220 214 208 75 69 63 57 51 45 )
    local rank=0

    while IFS=$'\t' read -r cnt name; do
        [[ -z "$name" ]] && continue
        (( rank++ )) || true

        local filled=1
        [[ $max_c -gt 0 ]] && filled=$(echo "scale=0; $cnt * $BAR_W / $max_c" | bc)
        [[ $filled -lt 1 ]] && filled=1
        local empty=$(( BAR_W - filled ))

        local cidx=$(( rank - 1 ))
        [[ $cidx -ge ${#bar_colors[@]} ]] && cidx=$(( ${#bar_colors[@]} - 1 ))
        local bar_col; bar_col=$(fg256 "${bar_colors[$cidx]}")

        local pct=0
        [[ $TOTAL -gt 0 ]] && pct=$(echo "scale=0; $cnt * 100 / $TOTAL" | bc)

        local name_s="$name"
        [[ ${#name_s} -gt 28 ]] && name_s="${name_s:0:26}.."

        local medal="   "
        [[ $rank -eq 1 ]] && medal="${YY}#1${R}"
        [[ $rank -eq 2 ]] && medal="${K}#2${R}"
        [[ $rank -eq 3 ]] && medal="$(fg256 172)#3${R}"

        printf "  %s  ${K}%-28s${R}  %b%s${K}%s${R}  ${BOLD}%2d${R}${K} (%3d%%)${R}\n" \
            "$medal" "$name_s" \
            "$bar_col" "$(rep '█' "$filled")" "$(rep '░' "$empty")" \
            "$cnt" "$pct"
    done <<< "$sorted"
}

# ─── Category breakdown ────────────────────────────────────────────────────────
draw_category_breakdown() {
    declare -A cat_ok cat_total
    while IFS='|' read -r status _ cat _; do
        cat_total["$cat"]=$(( ${cat_total["$cat"]:-0} + 1 ))
        [[ "$status" == "OK" ]] && cat_ok["$cat"]=$(( ${cat_ok["$cat"]:-0} + 1 ))
    done < "$TMP_ALL"

    local MINI_W=16
    for cat in "Search/AI" "Social" "Streaming" "Crypto" "Shopping" "General" "IP Test"; do
        local lok=${cat_ok["$cat"]:-0}
        local ltot=${cat_total["$cat"]:-0}
        [[ $ltot -eq 0 ]] && continue
        local lpct=0; [[ $ltot -gt 0 ]] && lpct=$(echo "scale=0; $lok * 100 / $ltot" | bc)
        local filled=$(echo "scale=0; $lok * $MINI_W / $ltot" | bc)
        [[ $filled -lt 0 ]] && filled=0
        local empty=$(( MINI_W - filled ))

        printf "  %s  %-12s  ${GG}%s${K}%s${R}  ${BOLD}%2d${R}${K}/%d${R}  %3d%%\n" \
            "$(cat_dot "$cat")" "$cat" \
            "$(rep '▮' "$filled")" "$(rep '▯' "$empty")" \
            "$lok" "$ltot" "$lpct"
    done
}

# ─── Country summary ───────────────────────────────────────────────────────────
draw_countries() {
    declare -A cc
    while IFS='|' read -r status _ _ _ _ _ country; do
        [[ "$status" != "OK" ]] && continue
        [[ -z "$country" || "$country" == "N/A" ]] && continue
        cc["$country"]=$(( ${cc["$country"]:-0} + 1 ))
    done < "$TMP_ALL"

    [[ ${#cc[@]} -eq 0 ]] && return

    local sorted
    sorted=$(for k in "${!cc[@]}"; do printf '%d\t%s\n' "${cc[$k]}" "$k"; done | sort -rn | head -12)

    local i=0 cols=2
    local -a items=()
    while IFS= read -r line; do items+=("$line"); done <<< "$sorted"
    local total_items=${#items[@]}

    for ((i=0; i<total_items; i+=cols)); do
        printf "  "
        for ((j=0; j<cols; j++)); do
            local idx=$(( i + j ))
            [[ $idx -ge $total_items ]] && break
            local cnt cname
            IFS=$'\t' read -r cnt cname <<< "${items[$idx]}"
            printf "$(fg256 46)●${R}  ${BOLD}%-22s${R}  $(fg256 87)%2d${R}  ${K}site(s)${R}    " "$cname" "$cnt"
        done
        printf '\n'
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
clear
printf '\n'
double_rule
center_line "$(gradient_line "  E G R E S S   I S P  /  A S N   C H E C K E R  ")"
center_line "${K}Route tracing  ·  ISP lookup  ·  Visual analytics${R}"
center_line "${K}$(date '+%Y-%m-%d  %H:%M:%S  %Z')${R}"
double_rule
printf '\n'

section "$(fg256 213)🤖  Search & AI${R}"         "$(fg256 213)"
check "google.com"          "Search/AI"
check "chatgpt.com"         "Search/AI"
check "claude.ai"           "Search/AI"
check "gemini.google.com"   "Search/AI"
check "bing.com"            "Search/AI"

section "$(fg256 75)💬  Social Media & Messaging${R}" "$(fg256 75)"
check "facebook.com"        "Social"
check "instagram.com"       "Social"
check "x.com"               "Social"
check "tiktok.com"          "Social"
check "telegram.org"        "Social"
check "discord.com"         "Social"
check "linkedin.com"        "Social"

section "$(fg256 203)▶   Streaming${R}"             "$(fg256 203)"
check "youtube.com"         "Streaming"
check "netflix.com"         "Streaming"
check "disneyplus.com"      "Streaming"
check "spotify.com"         "Streaming"
check "twitch.tv"           "Streaming"

section "$(fg256 220)₿   Crypto Exchanges${R}"      "$(fg256 220)"
check "www.binance.com"     "Crypto"
check "www.bybit.com"       "Crypto"
check "www.okx.com"         "Crypto"
check "www.coinbase.com"    "Crypto"
check "www.kraken.com"      "Crypto"

section "$(fg256 214)🛒  E-Commerce & Shopping${R}"   "$(fg256 214)"
check "shopee.com"          "Shopping"
check "lazada.com"          "Shopping"
check "tokopedia.com"       "Shopping"
check "amazon.com"          "Shopping"
check "ebay.com"            "Shopping"
check "aliexpress.com"      "Shopping"
check "taobao.com"          "Shopping"
check "jd.com"              "Shopping"
check "rakuten.com"         "Shopping"
check "etsy.com"            "Shopping"
check "zalora.com"          "Shopping"
check "shein.com"           "Shopping"

section "$(fg256 120)🌐  General / Control Group${R}" "$(fg256 120)"
check "microsoft.com"       "General"
check "wikipedia.org"       "General"
check "apple.com"           "General"
check "reddit.com"          "General"
check "github.com"          "General"
check "cloudflare.com"      "General"

section "$(fg256 87)🔍  IP Test Sites${R}"           "$(fg256 87)"
check "ip.sb"               "IP Test"
check "ipinfo.io"           "IP Test"
check "ifconfig.me"         "IP Test"
check "api.ipify.org"       "IP Test"

# ─── Dashboard ────────────────────────────────────────────────────────────────
printf '\n'
double_rule
center_line "$(gradient_line "  S U M M A R Y   D A S H B O A R D  ")"
double_rule
printf '\n'

# Stats pills
UNIQ_ISP=$(sort -u "$TMP_STAT" | grep -cv "Timeout" 2>/dev/null || echo 0)
AVG_OK=0; [[ $TOTAL -gt 0 ]] && AVG_OK=$(echo "scale=0; $OK_COUNT * 100 / $TOTAL" | bc)

center_line "$(
    printf '%b' \
        "$(bg256 22)$(fg256 156) ${BOLD} TOTAL ${R}" \
        "$(fg256 156)  ${BOLD}${TOTAL}${R}   " \
        "$(bg256 22)$(fg256 156) ${BOLD} OK ${R}" \
        "$(fg256 156)  ${BOLD}${OK_COUNT}${R}   " \
        "$(bg256 52)$(fg256 203) ${BOLD} FAIL ${R}" \
        "$(fg256 203)  ${BOLD}${FAIL_COUNT}${R}   " \
        "$(bg256 18)$(fg256 117) ${BOLD} ISPs ${R}" \
        "$(fg256 117)  ${BOLD}${UNIQ_ISP}${R}   " \
        "$(bg256 56)$(fg256 225) ${BOLD} SUCCESS ${R}" \
        "$(fg256 225)  ${BOLD}${AVG_OK}%${R}"
)"

printf '\n'
thin_rule
printf '\n'

printf "  ${BOLD}$(fg256 220)▸  ISP Distribution${R}  ${K}(sites routed per provider)${R}\n\n"
draw_bars

printf '\n'
thin_rule
printf '\n'

printf "  ${BOLD}$(fg256 87)▸  Top Countries  ${R}${K}(by edge server location)${R}\n\n"
draw_countries

printf '\n'
thin_rule
printf '\n'

printf "  ${BOLD}$(fg256 213)▸  Category Breakdown${R}\n\n"
draw_category_breakdown

printf '\n'
double_rule
printf "  ${K}ip-api.com  ·  mtr  ·  egress-check.sh${R}\n"
double_rule
printf '\n'

tput cnorm 2>/dev/null || true
