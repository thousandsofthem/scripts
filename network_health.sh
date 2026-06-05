#!/usr/bin/env bash
set -u

PING_TARGETS=("1.1.1.1" "8.8.8.8")
DNS_NAMES=("google.com" "cloudflare.com" "github.com")
HTTP_URLS=("https://www.google.com/generate_204" "https://cloudflare.com")
PING_COUNT=5
TIMEOUT_SECONDS=8

usage() {
  cat <<'EOF'
Usage: network_health.sh [options]

Analyze current network conditions: link status, routing, latency, packet loss,
DNS behavior, and basic HTTPS reachability.

Options:
  -p, --ping-target HOST   Add ping target. Can be used multiple times.
  -d, --dns-name NAME      Add DNS name. Can be used multiple times.
  -u, --url URL            Add HTTP(S) URL. Can be used multiple times.
  -c, --count N            Ping count per target. Default: 5.
  -t, --timeout N          Network operation timeout in seconds. Default: 8.
  -h, --help               Show this help.

Examples:
  ./network_health.sh
  ./network_health.sh -p 192.168.1.1 -d example.com -u https://example.com
EOF
}

have() {
  command -v "$1" >/dev/null 2>&1
}

section() {
  printf '\n== %s ==\n' "$1"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

reset_defaults_if_custom() {
  local kind="$1"
  case "$kind" in
    ping) [[ ${CUSTOM_PING:-0} -eq 0 ]] && PING_TARGETS=() && CUSTOM_PING=1 ;;
    dns) [[ ${CUSTOM_DNS:-0} -eq 0 ]] && DNS_NAMES=() && CUSTOM_DNS=1 ;;
    url) [[ ${CUSTOM_URL:-0} -eq 0 ]] && HTTP_URLS=() && CUSTOM_URL=1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--ping-target)
      [[ $# -lt 2 ]] && warn "missing value for $1" && exit 2
      reset_defaults_if_custom ping
      PING_TARGETS+=("$2")
      shift 2
      ;;
    -d|--dns-name)
      [[ $# -lt 2 ]] && warn "missing value for $1" && exit 2
      reset_defaults_if_custom dns
      DNS_NAMES+=("$2")
      shift 2
      ;;
    -u|--url)
      [[ $# -lt 2 ]] && warn "missing value for $1" && exit 2
      reset_defaults_if_custom url
      HTTP_URLS+=("$2")
      shift 2
      ;;
    -c|--count)
      [[ $# -lt 2 ]] && warn "missing value for $1" && exit 2
      PING_COUNT="$2"
      shift 2
      ;;
    -t|--timeout)
      [[ $# -lt 2 ]] && warn "missing value for $1" && exit 2
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      warn "unknown option: $1"
      usage
      exit 2
      ;;
  esac
done

if ! [[ "$PING_COUNT" =~ ^[0-9]+$ ]] || [[ "$PING_COUNT" -lt 1 ]]; then
  warn "ping count must be a positive integer"
  exit 2
fi

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECONDS" -lt 1 ]]; then
  warn "timeout must be a positive integer"
  exit 2
fi

SCORE=100
ISSUES=()

penalize() {
  local points="$1"
  local reason="$2"
  SCORE=$((SCORE - points))
  ISSUES+=("-${points}: ${reason}")
}

print_kv() {
  printf '%-22s %s\n' "$1:" "$2"
}

default_route() {
  if have ip; then
    ip route show default 2>/dev/null | head -n 1
  elif have netstat; then
    netstat -rn 2>/dev/null | awk '$1 == "default" || $1 == "0.0.0.0" { print; exit }'
  elif have route; then
    route -n get default 2>/dev/null | awk '
      /gateway:/ { gateway=$2 }
      /interface:/ { iface=$2 }
      END {
        if (gateway || iface) {
          printf("default via %s dev %s\n", gateway ? gateway : "unknown", iface ? iface : "unknown")
        }
      }'
  fi
}

active_interfaces() {
  if have ip; then
    ip -brief addr 2>/dev/null | awk '$2 == "UP" { print $1, $3 }'
  elif have ifconfig; then
    ifconfig 2>/dev/null | awk '
      /^[a-zA-Z0-9_.:-]+: / {
        iface=$1
        sub(/:$/, "", iface)
        up=index($0, "UP") > 0
      }
      up && /inet / && $2 != "127.0.0.1" {
        print iface, $2
      }'
  fi
}

dns_servers() {
  local servers

  if have scutil; then
    servers="$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/ { print $3 }' | sort -u)"
    if [[ -n "$servers" ]]; then
      printf '%s\n' "$servers"
      return
    fi
  fi

  if have networksetup; then
    servers="$(networksetup -listallnetworkservices 2>/dev/null |
      sed '/^\*/d' |
      while IFS= read -r service; do
        networksetup -getdnsservers "$service" 2>/dev/null
      done |
      awk '/^[0-9a-fA-F:.]+$/ { print }' |
      sort -u)"
    if [[ -n "$servers" ]]; then
      printf '%s\n' "$servers"
      return
    fi
  fi

  if [[ -r /etc/resolv.conf ]]; then
    awk '/^nameserver / { print $2 }' /etc/resolv.conf | sort -u
  fi
}

run_ping_raw() {
  local target="$1"

  case "$(uname -s 2>/dev/null)" in
    Darwin|FreeBSD|OpenBSD|NetBSD)
      ping -c "$PING_COUNT" -W 1000 "$target" 2>&1
      ;;
    Linux)
      ping -c "$PING_COUNT" -w "$TIMEOUT_SECONDS" -W 1 "$target" 2>&1
      ;;
    *)
      ping -c "$PING_COUNT" "$target" 2>&1
      ;;
  esac
}

ping_target() {
  local target="$1"
  local tmp pid timer status loss loss_int avg max summary

  tmp="${TMPDIR:-/tmp}/network_health_ping.$$.$RANDOM"
  : > "$tmp" || {
    warn "cannot create temp file for ping output"
    penalize 30 "ping to ${target} could not be started"
    return
  }

  run_ping_raw "$target" >"$tmp" 2>&1 &
  pid=$!
  (
    sleep "$TIMEOUT_SECONDS"
    kill "$pid" 2>/dev/null
  ) &
  timer=$!

  wait "$pid" 2>/dev/null
  status=$?
  kill "$timer" 2>/dev/null
  wait "$timer" 2>/dev/null

  printf '\nTarget: %s\n' "$target"
  awk '/packets transmitted/ || /round-trip/ || /rtt / || /min\/avg\/max/ { print }' "$tmp"

  loss="$(sed -n 's/.* \([0-9][0-9.]*\)% packet loss.*/\1/p' "$tmp" | tail -n 1)"
  avg="$(awk '
    /round-trip/ || /rtt / {
      metrics=$0
      sub(/^.*= */, "", metrics)
      sub(/ .*/, "", metrics)
      split(metrics, values, "/")
      if (values[2] ~ /^[0-9.]+$/) {
        print values[2]
        exit
      }
    }' "$tmp")"
  max="$(awk '
    /round-trip/ || /rtt / {
      metrics=$0
      sub(/^.*= */, "", metrics)
      sub(/ .*/, "", metrics)
      split(metrics, values, "/")
      if (values[3] ~ /^[0-9.]+$/) {
        print values[3]
        exit
      }
    }' "$tmp")"

  rm -f "$tmp"

  if [[ -z "${loss:-}" ]]; then
    if [[ "$status" -gt 128 ]]; then
      penalize 30 "ping to ${target} exceeded ${TIMEOUT_SECONDS}s timeout"
    else
      penalize 30 "ping to ${target} failed or returned no packet-loss data"
    fi
    print_kv "assessment" "failed"
    return
  fi

  if [[ "$status" -gt 128 && "$loss" != "100.0" && "$loss" != "100" ]]; then
    penalize 10 "ping to ${target} timed out before all ${PING_COUNT} probes completed"
  fi

  loss_int="${loss%.*}"
  if [[ "$loss_int" -ge 50 ]]; then
    penalize 35 "severe packet loss to ${target}: ${loss}%"
  elif [[ "$loss_int" -ge 10 ]]; then
    penalize 20 "high packet loss to ${target}: ${loss}%"
  elif [[ "$loss_int" -gt 0 ]]; then
    penalize 8 "minor packet loss to ${target}: ${loss}%"
  fi

  if [[ -n "${avg:-}" ]]; then
    summary="avg ${avg} ms"
    awk -v avg="$avg" 'BEGIN { exit !(avg > 250) }' && penalize 18 "very high latency to ${target}: avg ${avg} ms"
    awk -v avg="$avg" 'BEGIN { exit !(avg > 100 && avg <= 250) }' && penalize 8 "elevated latency to ${target}: avg ${avg} ms"
  else
    summary="average latency unavailable"
  fi

  if [[ -n "${max:-}" ]]; then
    summary="${summary}, max ${max} ms"
    awk -v max="$max" 'BEGIN { exit !(max > 600) }' && penalize 10 "large latency spike to ${target}: max ${max} ms"
  fi

  print_kv "assessment" "$summary, loss ${loss}%"
}

dns_lookup() {
  local name="$1"
  local output status elapsed server answer

  printf '\nName: %s\n' "$name"
  if have dig; then
    output="$(dig +tries=1 +time="$TIMEOUT_SECONDS" "$name" A 2>&1)"
    status="$(printf '%s\n' "$output" | awk '
      /status:/ {
        for (i = 1; i <= NF; i++) {
          if ($i == "status:") {
            gsub(/,/, "", $(i + 1))
            print $(i + 1)
            exit
          }
        }
      }')"
    elapsed="$(printf '%s\n' "$output" | awk '/Query time:/ { print $4; exit }')"
    server="$(printf '%s\n' "$output" | awk '/SERVER:/ { print $3; exit }')"
    answer="$(printf '%s\n' "$output" | awk '$4 == "A" { print $5; exit }')"

    print_kv "status" "${status:-unknown}"
    print_kv "query time" "${elapsed:-unknown} ms"
    print_kv "server" "${server:-unknown}"
    print_kv "first answer" "${answer:-none}"

    if [[ "${status:-}" != "NOERROR" || -z "${answer:-}" ]]; then
      penalize 18 "DNS lookup failed for ${name}"
    elif [[ -n "${elapsed:-}" ]]; then
      if [[ "$elapsed" -gt 500 ]]; then
        penalize 12 "slow DNS lookup for ${name}: ${elapsed} ms"
      elif [[ "$elapsed" -gt 150 ]]; then
        penalize 5 "elevated DNS lookup time for ${name}: ${elapsed} ms"
      fi
    fi
  elif have nslookup; then
    output="$(nslookup "$name" 2>&1)"
    printf '%s\n' "$output" | sed -n '1,8p'
    if ! printf '%s\n' "$output" | grep -Eq 'Address:|addresses:'; then
      penalize 18 "DNS lookup failed for ${name}"
    fi
  else
    warn "neither dig nor nslookup is available; skipping DNS lookup"
    return 1
  fi
}

http_check() {
  local url="$1"
  local result code namelookup connect tls starttransfer total

  printf '\nURL: %s\n' "$url"
  if ! have curl; then
    warn "curl is unavailable; skipping HTTP checks"
    return 1
  fi

  result="$(curl -L -o /dev/null -sS --max-time "$TIMEOUT_SECONDS" \
    -w 'code=%{http_code} namelookup=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} starttransfer=%{time_starttransfer} total=%{time_total}\n' \
    "$url" 2>&1)"

  printf '%s\n' "$result"
  code="$(printf '%s\n' "$result" | awk -F'[ =]' '/code=/ { for (i=1; i<=NF; i++) if ($i == "code") print $(i+1) }')"
  namelookup="$(printf '%s\n' "$result" | awk -F'[ =]' '/namelookup=/ { for (i=1; i<=NF; i++) if ($i == "namelookup") print $(i+1) }')"
  connect="$(printf '%s\n' "$result" | awk -F'[ =]' '/connect=/ { for (i=1; i<=NF; i++) if ($i == "connect") print $(i+1) }')"
  tls="$(printf '%s\n' "$result" | awk -F'[ =]' '/tls=/ { for (i=1; i<=NF; i++) if ($i == "tls") print $(i+1) }')"
  starttransfer="$(printf '%s\n' "$result" | awk -F'[ =]' '/starttransfer=/ { for (i=1; i<=NF; i++) if ($i == "starttransfer") print $(i+1) }')"
  total="$(printf '%s\n' "$result" | awk -F'[ =]' '/total=/ { for (i=1; i<=NF; i++) if ($i == "total") print $(i+1) }')"

  if [[ -z "${code:-}" || "$code" == "000" ]]; then
    penalize 25 "HTTPS request failed for ${url}"
    return
  fi

  if [[ "$code" -ge 500 ]]; then
    penalize 8 "server returned HTTP ${code} for ${url}"
  fi

  awk -v total="${total:-0}" 'BEGIN { exit !(total > 5) }' && penalize 12 "very slow HTTP total time for ${url}: ${total}s"
  awk -v total="${total:-0}" 'BEGIN { exit !(total > 2 && total <= 5) }' && penalize 5 "elevated HTTP total time for ${url}: ${total}s"
  awk -v st="${starttransfer:-0}" 'BEGIN { exit !(st > 2) }' && penalize 5 "slow time to first byte for ${url}: ${starttransfer}s"
  awk -v conn="${connect:-0}" 'BEGIN { exit !(conn > 1) }' && penalize 5 "slow TCP connect for ${url}: ${connect}s"
  awk -v dns="${namelookup:-0}" 'BEGIN { exit !(dns > 0.5) }' && penalize 5 "slow curl DNS phase for ${url}: ${namelookup}s"
  awk -v tls="${tls:-0}" 'BEGIN { exit !(tls > 1.5) }' && penalize 4 "slow TLS handshake for ${url}: ${tls}s"
}

quality_label() {
  if [[ "$SCORE" -ge 90 ]]; then
    printf 'excellent'
  elif [[ "$SCORE" -ge 75 ]]; then
    printf 'good'
  elif [[ "$SCORE" -ge 55 ]]; then
    printf 'degraded'
  elif [[ "$SCORE" -ge 35 ]]; then
    printf 'bad'
  else
    printf 'severe'
  fi
}

section "System"
print_kv "date" "$(date)"
print_kv "hostname" "$(hostname 2>/dev/null || printf unknown)"
print_kv "os" "$(uname -srm 2>/dev/null || printf unknown)"

section "Interfaces"
interfaces="$(active_interfaces)"
if [[ -n "${interfaces:-}" ]]; then
  printf '%s\n' "$interfaces"
else
  print_kv "active interfaces" "none detected"
  penalize 25 "no active non-loopback interface detected"
fi

section "Routing"
route_info="$(default_route)"
if [[ -n "${route_info:-}" ]]; then
  print_kv "default route" "$route_info"
else
  print_kv "default route" "not found"
  penalize 25 "no default route detected"
fi

section "DNS Servers"
servers="$(dns_servers)"
if [[ -n "${servers:-}" ]]; then
  printf '%s\n' "$servers"
else
  print_kv "dns servers" "not found"
  penalize 10 "no DNS servers detected"
fi

section "Latency And Packet Loss"
if have ping; then
  for target in "${PING_TARGETS[@]}"; do
    ping_target "$target"
  done
else
  print_kv "ping" "not available"
  penalize 20 "ping command is unavailable"
fi

section "DNS Resolution"
for name in "${DNS_NAMES[@]}"; do
  dns_lookup "$name"
done

section "HTTP Reachability"
for url in "${HTTP_URLS[@]}"; do
  http_check "$url"
done

section "Summary"
[[ "$SCORE" -lt 0 ]] && SCORE=0
label="$(quality_label)"
print_kv "score" "${SCORE}/100"
print_kv "condition" "$label"

if [[ ${#ISSUES[@]} -eq 0 ]]; then
  print_kv "issues" "none detected by these checks"
else
  printf 'issues:\n'
  printf '  %s\n' "${ISSUES[@]}"
fi

case "$label" in
  excellent|good) exit 0 ;;
  degraded) exit 1 ;;
  bad|severe) exit 2 ;;
esac
