#!/usr/bin/env bash
set -u

# net-quality.sh
# Usage:
#   ./net-quality.sh example.com
#   ./net-quality.sh https://example.com/path
#   ./net-quality.sh https://example.com -n 20

RUNS=10
CONNECT_TIMEOUT=15
MAX_TIME=45

usage() {
  echo "Usage: $0 <site-or-url> [-n runs]"
  echo
  echo "Examples:"
  echo "  $0 google.com"
  echo "  $0 https://github.com -n 20"
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

now_ms() {
  if have python3; then
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
  elif have python; then
    python - <<'PY'
import time
print(int(time.time() * 1000))
PY
  elif have perl; then
    perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
  else
    date +%s | awk '{print $1 * 1000}'
  fi
}

normalize_url() {
  case "$1" in
    http://*|https://*) echo "$1" ;;
    *) echo "https://$1" ;;
  esac
}

get_scheme() {
  echo "$1" | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*)://.*#\1#'
}

get_hostport() {
  echo "$1" |
    sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' |
    sed -E 's#/.*$##' |
    sed -E 's#@##'
}

get_host() {
  local hp="$1"

  if echo "$hp" | grep -q '^\['; then
    echo "$hp" | sed -E 's#^\[([^]]+)\].*#\1#'
  else
    echo "$hp" | sed -E 's#:([0-9]+)$##'
  fi
}

get_port() {
  local scheme="$1"
  local hp="$2"

  if echo "$hp" | grep -q '^\[.*\]:[0-9]\+$'; then
    echo "$hp" | sed -E 's#^\[[^]]+\]:([0-9]+)$#\1#'
  elif echo "$hp" | grep -q ':[0-9]\+$' && ! echo "$hp" | grep -q '::'; then
    echo "$hp" | sed -E 's#.*:([0-9]+)$#\1#'
  else
    case "$scheme" in
      http) echo 80 ;;
      https) echo 443 ;;
      *) echo 443 ;;
    esac
  fi
}

percentile_index() {
  awk -v n="$1" -v p="$2" 'BEGIN {
    if (n <= 0) { print 0; exit }
    idx = int((p / 100.0) * n + 0.999999)
    if (idx < 1) idx = 1
    if (idx > n) idx = n
    print idx
  }'
}

print_rule() {
  printf '%*s\n' 97 '' | tr ' ' '-'
}

shorten() {
  # args: max_len string...
  local max="$1"
  shift
  local s="$*"

  if [ "${#s}" -gt "$max" ]; then
    printf '%s...\n' "${s:0:$((max - 3))}"
  else
    printf '%s\n' "$s"
  fi
}

print_stats() {
  # args: title file column_number unit
  local title="$1"
  local file="$2"
  local col="$3"
  local unit="$4"

  local values count p50i p95i p99i

  values="$(awk -v c="$col" '$c != "" && $c != "-" && $c >= 0 {
    print $c
  }' "$file" | sort -n)"

  count="$(echo "$values" | awk 'NF { n++ } END { print n + 0 }')"

  if [ "$count" -eq 0 ]; then
    printf "  %-8s no data\n" "$title"
    return
  fi

  p50i="$(percentile_index "$count" 50)"
  p95i="$(percentile_index "$count" 95)"
  p99i="$(percentile_index "$count" 99)"

  echo "$values" | awk \
    -v title="$title" \
    -v unit="$unit" \
    -v p50i="$p50i" \
    -v p95i="$p95i" \
    -v p99i="$p99i" '
    {
      n++
      a[n] = $1
      sum += $1
    }
    END {
      min = a[1]
      max = a[n]
      avg = sum / n
      p50 = a[p50i]
      p95 = a[p95i]
      p99 = a[p99i]

      printf "  %-8s min=%6.3f%s avg=%6.3f%s p50=%6.3f%s\n",
        title, min, unit, avg, unit, p50, unit

      printf "  %-8s p95=%6.3f%s p99=%6.3f%s max=%6.3f%s\n",
        "", p95, unit, p99, unit, max, unit
    }'
}

curl_one() {
  local url="$1"
  local family_flag="${2:-}"

  # Important: keep this as ONE single --write-out.
  # Fields:
  #   1 namelookup
  #   2 connect
  #   3 appconnect
  #   4 starttransfer
  #   5 total
  #   6 http_code
  #   7 remote_ip
  curl $family_flag \
    --silent \
    --show-error \
    --output /dev/null \
    --http1.1 \
    --no-keepalive \
    --header 'Connection: close' \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    --write-out '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{http_code} %{remote_ip}\n' \
    "$url" 2>/dev/null
}

curl_parse_store() {
  # stdin: raw curl_one line
  awk '
    NF >= 7 {
      dns=$1
      tcp=$2-$1
      tls=$3-$2
      ttfb=$4-$3
      total=$5
      code=$6
      ip=$7

      if (tcp < 0) tcp = 0
      if (tls < 0) tls = 0
      if (ttfb < 0) ttfb = 0

      printf "%.6f %.6f %.6f %.6f %.6f %s %s\n",
        dns, tcp, tls, ttfb, total, code, ip
    }'
}

curl_parse_pretty() {
  # args: i runs
  local i="$1"
  local runs="$2"

  awk -v i="$i" -v runs="$runs" '
    NF >= 7 {
      dns=$1
      tcp=$2-$1
      tls=$3-$2
      ttfb=$4-$3
      total=$5
      code=$6
      ip=$7

      if (tcp < 0) tcp = 0
      if (tls < 0) tls = 0
      if (ttfb < 0) ttfb = 0
      if (length(ip) > 24) ip = substr(ip, 1, 21) "..."

      printf "  curl %2d/%-2d dns=%.3fs tcp=%.3fs tls=%.3fs ttfb=%.3fs total=%.3fs\n",
        i, runs, dns, tcp, tls, ttfb, total

      printf "             code=%-3s ip=%s\n", code, ip
    }'
}

curl_quick_pretty() {
  # stdin: raw curl_one line
  awk '
    NF >= 7 {
      ip=$7
      if (length(ip) > 24) ip = substr(ip, 1, 21) "..."

      printf "total=%ss code=%s ip=%s", $5, $6, ip
    }'
}

nc_connect_once() {
  local host="$1"
  local port="$2"
  local start end rc

  start="$(now_ms)"

  if nc -z -w "$CONNECT_TIMEOUT" "$host" "$port" >/dev/null 2>&1; then
    rc=0
  elif nc -z -G "$CONNECT_TIMEOUT" "$host" "$port" >/dev/null 2>&1; then
    rc=0
  else
    rc=1
  fi

  end="$(now_ms)"

  if [ "$rc" -eq 0 ]; then
    awk -v ms="$((end - start))" 'BEGIN { printf "%.3f\n", ms / 1000.0 }'
  else
    echo "-"
  fi
}

dns_once() {
  local host="$1"
  local start end

  start="$(now_ms)"

  if have dig; then
    dig +time="$CONNECT_TIMEOUT" +tries=1 "$host" A >/dev/null 2>&1 || return 1
  elif have nslookup; then
    nslookup "$host" >/dev/null 2>&1 || return 1
  else
    return 2
  fi

  end="$(now_ms)"
  awk -v ms="$((end - start))" 'BEGIN { printf "%.3f\n", ms / 1000.0 }'
}

TARGET="${1:-}"
[ -z "$TARGET" ] && usage
shift || true

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--runs)
      RUNS="${2:-}"
      [ -z "$RUNS" ] && usage
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

if ! have curl; then
  echo "Error: curl is required."
  exit 1
fi

URL="$(normalize_url "$TARGET")"
SCHEME="$(get_scheme "$URL")"
HOSTPORT="$(get_hostport "$URL")"
HOST="$(get_host "$HOSTPORT")"
PORT="$(get_port "$SCHEME" "$HOSTPORT")"

TMPDIR="${TMPDIR:-/tmp}"
CURL_FILE="$(mktemp "$TMPDIR/netq-curl.XXXXXX")"
NC_FILE="$(mktemp "$TMPDIR/netq-nc.XXXXXX")"
DNS_FILE="$(mktemp "$TMPDIR/netq-dns.XXXXXX")"

cleanup() {
  rm -f "$CURL_FILE" "$NC_FILE" "$DNS_FILE"
}
trap cleanup EXIT

short_url="$(shorten 86 "$URL")"
short_host="$(shorten 86 "$HOST")"

echo "Target: $short_url"
echo "Host:   $short_host"
echo "Port:   $PORT"
echo "Runs:   $RUNS"
echo

echo "Running curl fresh-connection tests..."
i=1
while [ "$i" -le "$RUNS" ]; do
  line="$(curl_one "$URL" "")"

  if echo "$line" | awk 'NF >= 7 { ok=1 } END { exit ok ? 0 : 1 }'; then
    echo "$line" | curl_parse_store >> "$CURL_FILE"
    echo "$line" | curl_parse_pretty "$i" "$RUNS"
  else
    printf "  curl %2d/%-2d failed\n" "$i" "$RUNS"
  fi

  i=$((i + 1))
done

echo

if have nc; then
  echo "Running nc TCP connect tests..."
  i=1
  while [ "$i" -le "$RUNS" ]; do
    value="$(nc_connect_once "$HOST" "$PORT")"
    echo "$value" >> "$NC_FILE"
    printf "  nc   %2d/%-2d tcp=%ss\n" "$i" "$RUNS" "$value"
    i=$((i + 1))
  done
else
  echo "Skipping nc tests: nc not found."
fi

echo

if have dig || have nslookup; then
  echo "Running standalone DNS lookup tests..."
  i=1
  while [ "$i" -le "$RUNS" ]; do
    value="$(dns_once "$HOST" || echo "-")"
    echo "$value" >> "$DNS_FILE"
    printf "  dns  %2d/%-2d lookup=%ss\n" "$i" "$RUNS" "$value"
    i=$((i + 1))
  done
else
  echo "Skipping standalone DNS tests: neither dig nor nslookup found."
fi

echo
print_rule
echo "Aggregated stats"
print_rule
echo

echo "curl phase timings:"
print_stats "DNS" "$CURL_FILE" 1 "s"
print_stats "TCP" "$CURL_FILE" 2 "s"
print_stats "TLS" "$CURL_FILE" 3 "s"
print_stats "TTFB" "$CURL_FILE" 4 "s"
print_stats "Total" "$CURL_FILE" 5 "s"

echo
echo "nc TCP connect:"
if [ -s "$NC_FILE" ]; then
  print_stats "TCP" "$NC_FILE" 1 "s"
else
  echo "  no data"
fi

echo
echo "standalone DNS:"
if [ -s "$DNS_FILE" ]; then
  print_stats "DNS" "$DNS_FILE" 1 "s"
else
  echo "  no data"
fi

echo
echo "HTTP status codes:"
if [ -s "$CURL_FILE" ]; then
  awk '{ c[$6]++ } END { for (k in c) print "  " k ": " c[k] }' "$CURL_FILE" |
    sort
else
  echo "  no data"
fi

echo
echo "Remote IPs:"
if [ -s "$CURL_FILE" ]; then
  awk '{ c[$7]++ } END { for (k in c) print "  " k ": " c[k] }' "$CURL_FILE" |
    sort |
    awk '{
      if (length($0) > 97) {
        print substr($0, 1, 94) "..."
      } else {
        print
      }
    }'
else
  echo "  no data"
fi

echo
echo "IPv4 / IPv6 quick check:"

v4_raw="$(curl_one "$URL" "-4")"
v4="$(echo "$v4_raw" | curl_quick_pretty)"
if [ -n "$v4" ]; then
  echo "  IPv4: $v4"
else
  echo "  IPv4: failed or unavailable"
fi

v6_raw="$(curl_one "$URL" "-6")"
v6="$(echo "$v6_raw" | curl_quick_pretty)"
if [ -n "$v6" ]; then
  echo "  IPv6: $v6"
else
  echo "  IPv6: failed or unavailable"
fi

echo
echo "Hints:"
echo "  High DNS     -> resolver, router, ISP DNS, DoH/DoT issue"
echo "  High TCP     -> loss, routing, firewall, NAT, broken IPv6 fallback"
echo "  High TLS     -> loss, MTU, DPI/proxy, TLS interception, bad route"
echo "  High TTFB    -> remote server, CDN, backend delay"
echo "  High p95/p99 -> intermittent stalls hidden by average speed tests"
