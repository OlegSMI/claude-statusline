#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Colors (tuned for dark theme) ───────────────────────
green='\033[38;2;120;200;120m'
gray='\033[38;2;150;150;150m'
white='\033[38;2;220;220;220m'
red='\033[38;2;255;95;95m'
yellow='\033[38;2;235;205;70m'
orange='\033[38;2;255;176;85m'
dim='\033[2m'
reset='\033[0m'

# ── Helpers ─────────────────────────────────────────────
color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
    fi
}

# Bracketed bar: [████░░░░]
build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="█"; done
    for ((i=0; i<empty; i++)); do empty_str+="░"; done

    printf "${dim}[${reset}${gray}${filled_str}${dim}${empty_str}${reset}${dim}]${reset}"
}

# Time remaining until an epoch, formatted like "<1m", "6d22h", "3h40m"
time_until() {
    local target=$1
    [ -z "$target" ] || [ "$target" = "null" ] || [ "$target" = "0" ] && return

    local now diff
    now=$(date +%s)
    diff=$(( target - now ))
    [ "$diff" -lt 0 ] && diff=0

    local days=$(( diff / 86400 ))
    local hours=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))

    if [ "$days" -gt 0 ]; then
        printf "%dd%dh" "$days" "$hours"
    elif [ "$hours" -gt 0 ]; then
        printf "%dh%dm" "$hours" "$mins"
    elif [ "$mins" -gt 0 ]; then
        printf "%dm" "$mins"
    else
        printf "<1m"
    fi
}

iso_to_epoch() {
    local iso_str="$1"
    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then echo "$epoch"; return 0; fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(env TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        [ -z "$epoch" ] && epoch=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi
    [ -n "$epoch" ] && echo "$epoch" && return 0
    return 1
}

# ── Model + context % ───────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

if [ "$size" -gt 0 ]; then
    ctx_pct=$(( current * 100 / size ))
else
    ctx_pct=0
fi
ctx_color=$(color_for_pct "$ctx_pct")

# ── Rate limits from stdin (primary) ───────────────────
has_stdin_rates=false
five_pct=""; five_reset=""
seven_pct=""; seven_reset=""

stdin_five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$stdin_five" ]; then
    has_stdin_rates=true
    five_pct=$(printf "%.0f" "$stdin_five")
    five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
    seven_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | awk '{printf "%.0f", $1}')
    seven_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
fi

# ── Fallback: API call (cached) ────────────────────────
cache_file="/tmp/claude/statusline-usage-cache.json"
cache_max_age=60
mkdir -p /tmp/claude
usage_data=""

if ! $has_stdin_rates; then
    needs_refresh=true
    if [ -f "$cache_file" ]; then
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
        now=$(date +%s)
        if [ "$(( now - cache_mtime ))" -lt "$cache_max_age" ]; then
            needs_refresh=false
            usage_data=$(cat "$cache_file" 2>/dev/null)
        fi
    fi

    if $needs_refresh; then
        token=""
        if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
            token="$CLAUDE_CODE_OAUTH_TOKEN"
        elif command -v security >/dev/null 2>&1; then
            blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
            [ -n "$blob" ] && token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
        fi
        if [ -z "$token" ] || [ "$token" = "null" ]; then
            creds_file="${HOME}/.claude/.credentials.json"
            [ -f "$creds_file" ] && token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        fi

        if [ -n "$token" ] && [ "$token" != "null" ]; then
            response=$(curl -s --max-time 5 \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $token" \
                -H "anthropic-beta: oauth-2025-04-20" \
                -H "User-Agent: claude-code/2.1.34" \
                "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
            if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
                usage_data="$response"
                echo "$response" > "$cache_file"
            fi
        fi
        [ -z "$usage_data" ] && [ -f "$cache_file" ] && usage_data=$(cat "$cache_file" 2>/dev/null)
    fi

    if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
        five_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
        five_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
        five_reset=$(iso_to_epoch "$five_reset_iso")
        seven_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
        seven_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
        seven_reset=$(iso_to_epoch "$seven_reset_iso")
    fi
fi

# Normalize resets to epoch (stdin gives ISO, fallback already epoch)
norm_epoch() {
    local v="$1"
    [ -z "$v" ] && return
    case "$v" in
        *[!0-9]*) iso_to_epoch "$v" ;;   # contains non-digit → ISO
        *) echo "$v" ;;                   # already epoch
    esac
}
five_reset_epoch=$(norm_epoch "$five_reset")
seven_reset_epoch=$(norm_epoch "$seven_reset")

# ── Build single-line output ────────────────────────────
bar_width=8
line="${green}${model_name}${reset}"
line+="  ${gray}ctx:${reset}${ctx_color}${ctx_pct}%${reset}"

if [ -n "$five_pct" ]; then
    bar=$(build_bar "$five_pct" "$bar_width")
    pc=$(color_for_pct "$five_pct")
    line+="  ${gray}5h:${reset}${bar} ${pc}${five_pct}%${reset}"
    rem=$(time_until "$five_reset_epoch")
    [ -n "$rem" ] && line+=" ${dim}${rem}${reset}"
fi

if [ -n "$seven_pct" ]; then
    bar=$(build_bar "$seven_pct" "$bar_width")
    pc=$(color_for_pct "$seven_pct")
    line+="  ${gray}7d:${reset}${bar} ${pc}${seven_pct}%${reset}"
    rem=$(time_until "$seven_reset_epoch")
    [ -n "$rem" ] && line+=" ${dim}${rem}${reset}"
fi

printf "%b" "$line"
exit 0
