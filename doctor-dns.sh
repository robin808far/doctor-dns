#!/usr/bin/env bash
#
# Smart DNS installer - sanction-bypass DNS for Iran, in two halves.
#
#   relay  (inside Iran)  dnsmasq answers a list of blocked domains with its own
#                         address; nginx then carries those connections abroad
#   exit   (outside)      nginx reads the SNI and connects to the real host
#
# Run it on both machines, once each. It asks which side it is on and the
# address of the other. Safe to re-run: configs are backed up, and a step that
# would change nothing does nothing.
#
#   sudo bash doctor-dns.sh              install or update this machine
#   sudo bash doctor-dns.sh --uninstall  put the machine back as it was
#
# HTTPS for the panels is optional and asks for nothing but a domain name. A
# certificate is obtained and renewed automatically, proved over port 80 - so
# the name has to point at the machine and port 80 has to be reachable. On a
# relay that port is forwarded to the exit, so it is borrowed for the twenty
# seconds a challenge takes and given straight back; console downloads through
# it stall for that long and resume.
#
# PANEL_CERT and PANEL_KEY use a certificate you already have instead, and
# CF_API_TOKEN proves the domain over DNS without touching port 80. Neither is
# ever prompted for.
#
# Per-client access control ships with this but starts switched off. The relay
# counts each registered address's traffic from the moment it is installed and
# blocks nobody; `smartdns-acl enforce on` is what closes the door, and it is
# meant to be run once there is a way for users to register an address. Turning
# it on before then locks out everyone, including you.

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
STAMP="$(date +%Y%m%d-%H%M%S)"

# What this file is. Written to the machine once an install finishes, so the
# next run can tell whether it is an upgrade, a re-run, or somebody about to
# put an older version over a newer one by accident.
VERSION="0.5.4"

# What this install did, so uninstall can undo exactly that and nothing more.
# Without it, removal would be guesswork: whether dnsmasq was ours or already
# here, whether nginx.conf had a config worth putting back. Guessing wrong on a
# box that was doing something else first is how an uninstall does damage.
STATE_DIR="/var/lib/smart-dns"
STATE="$STATE_DIR/install-state"

# Backups go here, never beside the original. dnsmasq reads *every* file in
# /etc/dnsmasq.d, so a backup left there is loaded as a second copy of the same
# config and the service refuses to start on "illegal repeated keyword". Found
# the hard way: it took a working relay down on the second run.
BACKUP_DIR="/var/backups/smart-dns"

# ---------------------------------------------------------------- output
if [ -t 1 ]; then
    B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; RD=$'\033[31m'; N=$'\033[0m'
else
    B=""; G=""; Y=""; RD=""; N=""
fi
step() { printf '\n%s==>%s %s%s%s\n' "$G" "$N" "$B" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    %s%s%s\n' "$Y" "$*" "$N"; }
die()  { printf '\n%sERROR:%s %s\n\n' "$RD" "$N" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- payloads
# Configs live at the bottom of this file, after exit 0, between markers, with
# every line prefixed by '#' so the whole script stays valid bash. awk copies
# them out and strips that prefix - no shell expansion anywhere, so nginx's
# $variables and dnsmasq's syntax survive untouched.
payload() {
    awk -v name="$1" '
        $0 == "#__BEGIN_" name "__" { on = 1; next }
        $0 == "#__END_"   name "__" { on = 0 }
        on { sub(/^#/, ""); print }
    ' "$SELF"
}

backup_file() {
    [ -f "$1" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$1" "$BACKUP_DIR/$(basename "$1").$STAMP"
    info "backed up $1 -> $BACKUP_DIR"
}

# Write payload $1 to file $2, substituting the two addresses. Backs up whatever
# was there, and skips the write when the content is identical so re-runs do not
# churn files or trigger needless restarts. Returns 0 only if it changed.
install_payload() {
    local name="$1" dest="$2" tmp
    tmp="$(mktemp)"
    # MODULE_PATH is filled in here, not with a sed -i afterwards, so that what
    # we compare against the installed file is the finished article. Doing it
    # after the comparison meant every run saw a difference and rewrote
    # nginx.conf - the same needless-restart trap epic-pin fell into. MOD is
    # empty for the payloads written before it is discovered, and none of those
    # contain the placeholder.
    payload "$name" \
        | sed -e "s#__RELAY_IP__#${RELAY_IP}#g" \
              -e "s#__EXIT_IP__#${EXIT_IP}#g" \
              -e "s#__MODULE_PATH__#${MOD:-__MODULE_PATH__}#g" \
              -e "${NO_GOOGLE_V6:+/# google-v6 begin/,/# google-v6 end/d}" \
              -e "s#__EXIT_HTTPS__#${EXIT_HTTPS:-__EXIT_HTTPS__}#g" \
              -e "s#__EXIT_HTTP__#${EXIT_HTTP:-__EXIT_HTTP__}#g" \
              -e "${NO_TUNNEL:+/# tunnel begin/,/# tunnel end/d}" \
        > "$tmp"
    [ -s "$tmp" ] || die "payload $name is empty - is this file complete?"
    # Whether this file was ours or already here decides what uninstall does
    # with it: delete, or put the original back. Work it out before writing.
    note_file "$dest"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"; info "$dest unchanged"; return 1
    fi
    backup_file "$dest"
    mv "$tmp" "$dest"; chmod 644 "$dest"; info "wrote $dest"
    return 0
}
# The panels' font, served by the panels themselves: every font host worth
# using is blocked or slow from Iran. The one payload that is not text, so it
# travels as base64; its licence goes with it, as the licence asks.
install_font() {
    local dir=/usr/local/share/smart-dns tmp
    mkdir -p "$dir"
    tmp="$(mktemp)"
    if payload FONT | base64 -d > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        note_file "$dir/Vazirmatn.woff2"
        mv "$tmp" "$dir/Vazirmatn.woff2"; chmod 644 "$dir/Vazirmatn.woff2"
    else
        rm -f "$tmp"
        warn "the panel font could not be unpacked - the pages use the system font"
    fi
    note_file "$dir/Vazirmatn-OFL.txt"
    payload FONT_LICENSE > "$dir/Vazirmatn-OFL.txt"
    chmod 644 "$dir/Vazirmatn-OFL.txt"
}

# Set KEY=VALUE in a shell-style config file, replacing the line if it is
# already there and appending it if not. Used for the panel's config, which the
# operator is expected to edit by hand as well.
set_env_key() {
    local file="$1" key="$2" value="$3" tmp
    tmp="$(mktemp)"
    grep -v "^${key}=" "$file" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Record a fact about this install, one "key value" per line.
remember() { mkdir -p "$STATE_DIR"; printf '%s %s\n' "$1" "$2" >> "$STATE"; }
recall()   { [ -f "$STATE" ] && awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }' "$STATE"; }
# The same, on one line. The membership tests below look for a value with a
# space on either side, so a list separated by newlines would only ever match
# its first entry - which is exactly what went wrong: on the second run every
# file this script had created was reclassified as somebody else's.
recall_flat() { recall "$1" | tr '\n' ' '; }

# Enable a service, but only record it as ours if it was not already enabled.
# Uninstall stops what is on that list, and stopping an nginx that was serving
# somebody's website before we arrived would be a real outage caused by our
# cleanup. Restoring its config is ours to undo; its running state is not.
#
# The second argument names the package that provides the unit. Leave it out
# for units this script writes itself, which are ours by construction.
enable_service() {
    local svc="$1" pkg="${2:-}" was ours=no

    # A second run finds our own services already enabled, so the test at the
    # bottom would decide they belong to someone else and uninstall would leave
    # dnsmasq and coturn running for ever. What *this* run enabled is not the
    # question; what any run of this script enabled is.
    case " ${PREV_SERVICES:-} " in *" $svc "*) ours=yes ;; esac

    # Debian enables dnsmasq and coturn the moment they are unpacked, so by the
    # time we get here the "was it already enabled" test says yes even though
    # the package arrived thirty seconds ago on our own apt-get line. If we
    # installed the package, the service is ours.
    if [ -n "$pkg" ]; then
        case " ${NEW_PACKAGES:-} " in *" $pkg "*) ours=yes ;; esac
    else
        ours=yes
    fi

    was="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
    systemctl enable "$svc" >/dev/null 2>&1 || true
    { [ "$ours" = yes ] || [ "$was" != enabled ]; } && remember services-enabled "$svc"
    return 0
}

# ------------------------------------------------------------------ tunnel
# An optional tunnel between the relay and the exit, carried by BackPack - the
# work of Amin Mohammadi (github.com/AminMGMT/BackPack, AGPL-3.0). Its binary is
# fetched from his own releases when asked for and checked against the hashes
# pinned here - never copied into this project, and never a version nobody here
# has tried.
BACKPACK_VERSION="v1.8.0"
BACKPACK_SHA_amd64="0fca707e413c0ca051fac1bf47a8f5bc870bc54a67866415b75fd93fbd91f9b8"
BACKPACK_SHA_arm64="b93d4b1c76d44e2168a66f7e3e27173b07682d012b3cdf3917f768ea7064a764"
BACKPACK_BIN=/usr/local/lib/smart-dns/backpack
TUNNEL_DIR=/etc/smart-dns/tunnel
TUNNEL_NFT=/etc/nftables.d/40-smartdns-tunnel.conf
# The tunnel's end on the relay, on loopback only: nginx points here, and
# nothing outside the machine can reach either port.
TUNNEL_LOCAL_HTTPS=18443
TUNNEL_LOCAL_HTTP=18080
# Which transports each direction has. A direct tunnel has four; BackPack's
# spoofing carrier is a different kind of tunnel and is not offered.
TUNNEL_REVERSE_TRANSPORTS="stealth wss wssmux tcp tcpmux kcp pck quic ws wsmux xdi udp"
TUNNEL_DIRECT_TRANSPORTS="stealth wss tcp ws"

tunnel_transport_ok() {
    local list="$TUNNEL_REVERSE_TRANSPORTS"
    [ "$1" = direct ] && list="$TUNNEL_DIRECT_TRANSPORTS"
    case " $list " in *" $2 "*) return 0 ;; esac
    return 1
}

# Why a port cannot carry the tunnel, or nothing when it can. The same ports
# the admin panel may not take, and the relay's own besides.
tunnel_port_problem() {
    local p="$1" admin
    case "$p" in *[!0-9]*|"") echo "not a number"; return 0 ;; esac
    { [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; } || { echo "not a port"; return 0; }
    case "$p" in
        22) echo "ssh" ;;
        53) echo "dns" ;;
        80|443) echo "the proxy" ;;
        8443) echo "the sync API and the customer panel" ;;
        8446) echo "the exit's route to Google over IPv6" ;;
        8402) echo "where certificates are proved" ;;
        3478) echo "STUN on the relay" ;;
        "$TUNNEL_LOCAL_HTTPS"|"$TUNNEL_LOCAL_HTTP") echo "the tunnel's own end on the relay" ;;
    esac
    { [ "$p" -ge 5300 ] && [ "$p" -le 5399 ]; } && echo "the templates' resolvers on the relay"
    admin="$(sed -n 's/^ADMIN_PORT=//p' /etc/smart-dns/admin.env 2>/dev/null | head -1 || true)"
    [ -n "$admin" ] && [ "$p" = "$admin" ] && echo "the admin panel"
    return 0
}

# bp-stealth-8444-r: what the exit chose, carried to the relay inside the
# pairing token so the two ends are never set up differently.
parse_tunnel_spec() {
    local s="$1" d
    case "$s" in bp-*-*-[rd]) ;; *) return 1 ;; esac
    s="${s#bp-}"; d="${s##*-}"; s="${s%-*}"
    TUNNEL_PORT="${s##*-}"; TUNNEL_TRANSPORT="${s%-*}"
    if [ "$d" = r ]; then TUNNEL_DIRECTION=reverse; else TUNNEL_DIRECTION=direct; fi
    tunnel_transport_ok "$TUNNEL_DIRECTION" "$TUNNEL_TRANSPORT" || return 1
    [ -z "$(tunnel_port_problem "$TUNNEL_PORT")" ] || return 1
    TUNNEL=backpack
}

# Both ends derive the tunnel's token from the secret they already share, so
# there is nothing new to copy between them.
tunnel_token() { printf 'doctor-dns-tunnel:%s' "$1" | sha256sum | cut -c1-48; }

ask_tunnel() {
    local a list="" i=0 t note
    # What this machine has now, when there is one, is the answer enter gives:
    # asking again with --tunnel and changing only the port should take one
    # line typed, not four.
    local d1=1 d2=1 d3=1
    [ "${CUR_TUNNEL:-}" = backpack ] && d1=2
    [ "${CUR_DIRECTION:-}" = direct ] && d2=2
    printf '\n%sBetween the relay and this exit%s\n\n' "$B" "$N"
    if [ "${CUR_TUNNEL:-}" = backpack ]; then
        printf '  now: BackPack, %s, %s, port %s\n\n' "${CUR_TRANSPORT:-?}" "${CUR_DIRECTION:-?}" "${CUR_PORT:-?}"
    elif [ -n "${CUR_TUNNEL:-}" ]; then
        printf '  now: direct TCP\n\n'
    fi
    printf '  1) direct TCP        as it has always been - nothing extra installed\n'
    printf '  2) BackPack tunnel   hides the names of the sites from filtering on the way\n\n'
    read -r -p "  choice [$d1]: " a
    case "${a:-$d1}" in 1) TUNNEL=off; return 0 ;; 2) TUNNEL=backpack ;; *) die "answer 1 or 2" ;; esac
    printf '\n  Which end dials the other?\n\n'
    printf '  1) reverse   this exit dials the relay - BackPack'"'"'s usual way\n'
    printf '  2) direct    the relay dials this exit - for where connections into Iran do not\n'
    printf '               get through\n\n'
    read -r -p "  choice [$d2]: " a
    case "${a:-$d2}" in 1) TUNNEL_DIRECTION=reverse ;; 2) TUNNEL_DIRECTION=direct ;; *) die "answer 1 or 2" ;; esac
    # What each transport is. How one performs depends on the route, so that is
    # not said here; only the two that did not connect at all in our own test
    # say so.
    printf '\n  Transport:\n\n'
    while IFS='|' read -r t note; do
        tunnel_transport_ok "$TUNNEL_DIRECTION" "$t" || continue
        i=$((i + 1)); list="$list $t"
        [ "$t" = "${CUR_TRANSPORT:-}" ] && d3=$i
        printf '  %2d) %-8s %s\n' "$i" "$t" "$note"
    done <<'NOTES'
stealth|encrypted, looks like random bytes - recommended
wss|looks like an ordinary HTTPS website
wssmux|the same over a few pooled connections
wsmux|websocket, pooled - not encrypted: site names show
ws|websocket - not encrypted: site names show
tcp|plain - not encrypted: site names show
tcpmux|plain and pooled - not encrypted: site names show
kcp|over UDP, for a route that loses packets
pck|for a route where TCP connects, then dies
xdi|inside ping - for where only ping gets through
quic|over UDP - did not connect in our test
udp|raw datagrams, no reliability - did not connect in our test
NOTES
    printf '\n'
    read -r -p "  choice [$d3]: " a
    a="${a:-$d3}"
    case "$a" in *[!0-9]*) die "answer with the number" ;; esac
    # shellcheck disable=SC2086
    TUNNEL_TRANSPORT="$(echo $list | cut -d' ' -f"$a")"
    [ -n "$TUNNEL_TRANSPORT" ] || die "there is no transport number $a"
    while :; do
        read -r -p "  tunnel port [${CUR_PORT:-8444}]: " a
        a="${a:-${CUR_PORT:-8444}}"
        t="$(tunnel_port_problem "$a")"
        [ -z "$t" ] && { TUNNEL_PORT="$a"; break; }
        warn "port $a cannot carry the tunnel: $t - pick another"
    done
    if [ "$TUNNEL_DIRECTION" = reverse ]; then
        info "open port $TUNNEL_PORT to this exit in the relay's firewall, if it has one"
    else
        info "open port $TUNNEL_PORT to the relay in this exit's firewall, if it has one"
    fi
}

# Fetch the pinned BackPack, or take it from BACKPACK_TARBALL. Refuses anything
# whose hash does not match. Returns non-zero, having said why, on failure.
install_backpack() {
    local arch sha tmp
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) warn "BackPack has no build for $(uname -m) in this installer"; return 1 ;;
    esac
    eval "sha=\$BACKPACK_SHA_$arch"
    if [ -x "$BACKPACK_BIN" ] && [ "$(cat "$BACKPACK_BIN.version" 2>/dev/null)" = "$BACKPACK_VERSION $sha" ]; then
        info "BackPack $BACKPACK_VERSION already here"
        return 0
    fi
    tmp="$(mktemp -d)"
    if [ -n "${BACKPACK_TARBALL:-}" ]; then
        cp "$BACKPACK_TARBALL" "$tmp/bp.tgz" || { warn "cannot read $BACKPACK_TARBALL"; rm -rf "$tmp"; return 1; }
    elif ! curl -fsSL -m 300 -o "$tmp/bp.tgz" \
            "https://github.com/AminMGMT/BackPack/releases/download/$BACKPACK_VERSION/backpack_linux_$arch.tar.gz"; then
        warn "could not download BackPack from GitHub. Without internet, fetch"
        warn "backpack_linux_$arch.tar.gz ($BACKPACK_VERSION) elsewhere and run with"
        warn "    BACKPACK_TARBALL=/path/to/it"
        rm -rf "$tmp"; return 1
    fi
    if [ "$(sha256sum "$tmp/bp.tgz" | cut -d' ' -f1)" != "$sha" ]; then
        warn "that BackPack archive does not match the hash pinned for $BACKPACK_VERSION - not installing it"
        rm -rf "$tmp"; return 1
    fi
    tar -xzf "$tmp/bp.tgz" -C "$tmp" 2>/dev/null
    [ -f "$tmp/backpack" ] || { warn "no backpack binary in that archive"; rm -rf "$tmp"; return 1; }
    mkdir -p "$(dirname "$BACKPACK_BIN")"
    note_file "$BACKPACK_BIN"
    note_file "$BACKPACK_BIN.version"
    install -m 755 "$tmp/backpack" "$BACKPACK_BIN"
    printf '%s %s\n' "$BACKPACK_VERSION" "$sha" > "$BACKPACK_BIN.version"
    rm -rf "$tmp"
    info "BackPack $BACKPACK_VERSION installed, its hash checked"
    info "BackPack is the work of Amin Mohammadi - github.com/AminMGMT/BackPack (AGPL-3.0)"
}

# The tunnel's config for this end, on stdout.
tunnel_toml() {
    local token c="" k=""
    token="$(tunnel_token "$1")"
    # wss on the listening end wants a certificate: the machine's own if it has
    # a domain, a self-signed one if not. The other end does not verify it -
    # BackPack proves the token inside the TLS session instead.
    case "$TUNNEL_TRANSPORT" in wss|wssmux)
        if [ -n "${PANEL_DOMAIN:-}" ] && [ -f "/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem" ]; then
            c="/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem"; k="/etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem"
        else
            c="$TUNNEL_DIR/tls.crt"; k="$TUNNEL_DIR/tls.key"
            [ -f "$c" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
                -subj "/CN=${PANEL_DOMAIN:-localhost}" -keyout "$k" -out "$c" >/dev/null 2>&1 || true
        fi ;;
    esac
    printf '# written by the doctor dns installer - re-run it to change the tunnel\n'
    if [ "$TUNNEL_DIRECTION" = reverse ] && [ "$ROLE" = relay ]; then
        printf '[server]\nbind_addr = "0.0.0.0:%s"\n' "$TUNNEL_PORT"
        printf 'ports = ["127.0.0.1:%s=443", "127.0.0.1:%s=80"]\n' "$TUNNEL_LOCAL_HTTPS" "$TUNNEL_LOCAL_HTTP"
        [ -n "$c" ] && printf 'tls_cert = "%s"\ntls_key = "%s"\n' "$c" "$k"
    elif [ "$TUNNEL_DIRECTION" = reverse ]; then
        printf '[client]\nremote_addr = "%s:%s"\n' "$RELAY_IP" "$TUNNEL_PORT"
    elif [ "$ROLE" = relay ]; then
        printf '[direct]\nrole = "iran"\naddr = "%s:%s"\n' "$EXIT_IP" "$TUNNEL_PORT"
        printf 'ports = ["127.0.0.1:%s=443", "127.0.0.1:%s=80"]\n' "$TUNNEL_LOCAL_HTTPS" "$TUNNEL_LOCAL_HTTP"
    else
        printf '[direct]\nrole = "kharej"\naddr = "0.0.0.0:%s"\n' "$TUNNEL_PORT"
        [ -n "$c" ] && printf 'tls_cert = "%s"\ntls_key = "%s"\n' "$c" "$k"
    fi
    printf 'transport = "%s"\ntoken = "%s"\n' "$TUNNEL_TRANSPORT" "$token"
    # The reverse engine's own extras: no web panel, no kernel tuning of its
    # own, and a log at the level journald is read at.
    if [ "$TUNNEL_DIRECTION" = reverse ]; then
        printf 'web_port = 0\nskip_optz = true\nlog_level = "info"\n'
    fi
}

# Bring this end of the tunnel to what TUNNEL says, or take it down.
apply_tunnel() {
    local secret="$1" tmp changed=0 peer
    if [ "${TUNNEL:-off}" != backpack ]; then
        if [ -f /etc/systemd/system/smartdns-tunnel.service ]; then
            systemctl disable --now smartdns-tunnel.service >/dev/null 2>&1 || true
            info "no tunnel - the relay reaches the exit directly"
        fi
        # The whole directory: BackPack keeps its metrics beside the config.
        rm -f "$TUNNEL_NFT"
        rm -rf "$TUNNEL_DIR"
        nft delete table inet smartdns_tunnel >/dev/null 2>&1 || true
        return 0
    fi
    step "Tunnel: BackPack $BACKPACK_VERSION - $TUNNEL_TRANSPORT, $TUNNEL_DIRECTION, port $TUNNEL_PORT"
    if [ -z "$secret" ]; then
        warn "no pairing, so no tunnel - the relay reaches the exit directly"
        TUNNEL=off; return 0
    fi
    mkdir -p "$TUNNEL_DIR"; chmod 700 "$TUNNEL_DIR"
    note_file "$TUNNEL_DIR/tunnel.toml"
    tmp="$(mktemp)"
    tunnel_toml "$secret" > "$tmp"
    cmp -s "$tmp" "$TUNNEL_DIR/tunnel.toml" || changed=1
    install -m 600 "$tmp" "$TUNNEL_DIR/tunnel.toml"; rm -f "$tmp"
    # The end that listens lets the other machine in and nobody else. Loaded
    # by the service itself as well, so it holds on a machine whose nftables
    # service does not read /etc/nftables.d.
    if { [ "$ROLE" = relay ] && [ "$TUNNEL_DIRECTION" = reverse ]; } \
       || { [ "$ROLE" = exit ] && [ "$TUNNEL_DIRECTION" = direct ]; }; then
        if [ "$ROLE" = relay ]; then peer="$EXIT_IP"; else peer="$RELAY_IP"; fi
        mkdir -p /etc/nftables.d
        note_file "$TUNNEL_NFT"
        cat > "$TUNNEL_NFT" <<EOF
# written by the doctor dns installer: the tunnel's port answers $peer only
table inet smartdns_tunnel
delete table inet smartdns_tunnel
table inet smartdns_tunnel {
    chain input {
        type filter hook input priority -5 ; policy accept ;
        tcp dport $TUNNEL_PORT ip saddr != $peer drop
        udp dport $TUNNEL_PORT ip saddr != $peer drop
        meta nfproto ipv6 tcp dport $TUNNEL_PORT drop
        meta nfproto ipv6 udp dport $TUNNEL_PORT drop
    }
}
EOF
        if nft -f "$TUNNEL_NFT" 2>/dev/null; then info "port $TUNNEL_PORT answers $peer only"
        else warn "could not load the tunnel's firewall rule - port $TUNNEL_PORT is open to all"; fi
    else
        rm -f "$TUNNEL_NFT"
        nft delete table inet smartdns_tunnel >/dev/null 2>&1 || true
    fi
    install_payload TUNNEL_SERVICE /etc/systemd/system/smartdns-tunnel.service && changed=1 || true
    systemctl daemon-reload
    enable_service smartdns-tunnel.service
    if [ "$changed" = 1 ] || ! systemctl is-active --quiet smartdns-tunnel.service; then
        systemctl restart smartdns-tunnel.service
    fi
    sleep 2
    if systemctl is-active --quiet smartdns-tunnel.service; then info "tunnel service running"
    else warn "the tunnel service did not start - journalctl -u smartdns-tunnel"; fi
}

# Classify a file we are about to write. "replaced" means something was already
# there and uninstall should put it back; "created" means it is ours to delete.
# A re-run must not reclassify: once a file has been recorded as replaced, the
# original still belongs to whoever had it first, even though by now the file on
# disk is ours.
note_file() {
    local f="$1"
    case " $(recall_flat files-created) $(recall_flat files-replaced) " in
        *" $f "*) return 0 ;;
    esac
    case " ${PREV_REPLACED:-} " in
        *" $f "*) remember files-replaced "$f"; return 0 ;;
    esac
    # And a file an earlier run created is still ours to delete. Without this
    # the test below sees a file that exists, concludes it belongs to the
    # machine's owner, and uninstall then tries to restore a backup that was
    # never taken - leaving every config we wrote behind for good.
    case " ${PREV_CREATED:-} " in
        *" $f "*) remember files-created "$f"; return 0 ;;
    esac
    if [ -e "$f" ]; then remember files-replaced "$f"
    else remember files-created "$f"; fi
}

# --------------------------------------------------------------- questions?
# Answered before the preflight, because neither one touches the machine and
# neither has any business demanding root. Asking a script what version it is
# and being told to use sudo is the kind of small rudeness that makes people
# stop asking.
case "${1:-}" in
    --version|-V) printf '%s\n' "$VERSION"; exit 0 ;;
    --help|-h)
        printf 'doctor dns %s\n\n' "$VERSION"
        printf 'usage: sudo bash %s [--uninstall | --tunnel]\n\n' "$0"
        printf '  no arguments   install or update this machine\n'
        printf '  --uninstall    put it back as it was\n'
        printf '  --tunnel       choose the tunnel between relay and exit again, then update\n'
        printf '  --version      print the version of this file\n'
        printf '\nenvironment (sudo does not pass these, put them after it):\n'
        printf '  ASSUME_YES=1   take the default for every question\n'
        printf '  ENFORCE=no     leave a relay open to everyone\n'
        printf '  TUNNEL=backpack|off  TUNNEL_TRANSPORT=stealth  TUNNEL_DIRECTION=reverse|direct\n'
        printf '  TUNNEL_PORT=8444     the tunnel between relay and exit, asked on the exit\n'
        printf '  BACKPACK_TARBALL=/path/backpack_linux_amd64.tar.gz   BackPack without GitHub\n'
        exit 0 ;;
esac

# ---------------------------------------------------------------- preflight
[ "$(id -u)" = 0 ] || die "run as root:  sudo bash $0"
[ -r "$SELF" ] && [ -n "$(payload SYSCTL)" ] || die "cannot read my own payloads.
    Download this file and run it directly. Piping it into bash will not work,
    because the configs are stored inside the script itself."
# A download that stopped early is still a runnable script. Everything below
# `exit 0` is a comment, so bash parses half a file quite happily and would
# then set the machine up with configs silently missing - which is worse than
# not running at all. A whole one ends on one exact line the build writes after
# the last payload, and only an exact match will do: a cut that landed just
# after the terminator of a payload in the middle, or half way through one -
# "#__END_ACL_SAVE_S" - passed the looser test this used to be, and went on to
# install with twenty configs missing.
[ "$(tail -n 1 "$SELF")" = "#__DOCTOR_DNS_COMPLETE__" ] || die "this file is incomplete - the
    download stopped early. Fetch it again:
        curl -fsSLO https://raw.githubusercontent.com/mehdi047/doctor-dns/main/doctor-dns.sh"
command -v apt-get >/dev/null 2>&1 || die "this installer expects Debian or Ubuntu"

# ---------------------------------------------------------------- uninstall
# Undoes exactly what the state file says this script did, and nothing else.
# Anything it is unsure about is left alone and reported, because a leftover
# file is a nuisance while a wrongly deleted one is an outage.
uninstall() {
    [ -f "$STATE" ] || die "no record of an install at $STATE.
    Either this machine was never set up by this script, or the state file is
    gone. Refusing to guess what to remove."

    local role packages
    role="$(recall role)"
    packages="$(recall packages-installed)"

    printf '\n%sAbout to remove the smart DNS from this machine.%s\n\n' "$B" "$N"
    printf '    installed as : %s on %s\n' "$role" "$(recall installed-at)"
    printf '    will restore : nginx config, and stop the services set up here\n'
    printf '    will delete  : the config files, helper commands and timers added\n'
    if [ -n "$packages" ]; then
        printf '    will NOT remove these packages, in case something else needs them:\n'
        printf '                   %s\n' "$packages"
    fi
    printf '    backups kept : %s\n\n' "$BACKUP_DIR"
    if [ -z "${ASSUME_YES:-}" ]; then
        read -r -p "  proceed? [y/N]: " ok
        case "$ok" in y|Y|yes) ;; *) die "cancelled" ;; esac
    fi

    step "Stopping services"
    local svc
    for svc in $(recall services-enabled); do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
        info "stopped and disabled $svc"
    done

    step "Removing files this install created"
    local f
    for f in $(recall files-created); do
        if [ -e "$f" ]; then rm -f "$f"; info "removed $f"; fi
    done

    step "Restoring files this install replaced"
    for f in $(recall files-replaced); do
        # The oldest backup is the state the machine was in before we touched
        # it; later ones are just our own edits over time.
        local original
        # `|| true` is load-bearing. Under `set -e` with pipefail, a glob that
        # matches nothing makes ls exit non-zero and takes the whole uninstall
        # down without a word, halfway through - which is precisely how the
        # missing carry-over below first showed itself.
        original="$(ls -1 "$BACKUP_DIR/$(basename "$f")".* 2>/dev/null | head -1 || true)"
        if [ -n "$original" ] && [ -f "$original" ]; then
            cp -a "$original" "$f"; info "restored $f from $(basename "$original")"
        else
            warn "no backup found for $f - left as it is"
        fi
    done

    step "Swap"
    # Only a swap file this script created, and only if it is still the one
    # recorded - never a swap file that was already on the machine.
    if [ -n "$(recall swapfile)" ] && [ -f /swapfile ]; then
        swapoff /swapfile 2>/dev/null || true
        sed -i '\#^/swapfile #d' /etc/fstab 2>/dev/null || true
        rm -f /swapfile
        info "removed the swap file this installer created"
    fi

    step "Removing the firewall table"
    export PATH="$PATH:/usr/sbin"
    if nft list table inet smartdns >/dev/null 2>&1; then
        nft delete table inet smartdns; info "removed the nftables table"
    fi
    if nft list table inet smartdns_tunnel >/dev/null 2>&1; then
        nft delete table inet smartdns_tunnel; info "removed the tunnel's firewall table"
    fi
    if nft list table inet smartdns_api >/dev/null 2>&1; then
        nft delete table inet smartdns_api; info "removed the sync API's firewall table"
    fi
    # 10- is recorded in the state file and goes with the other created files.
    # 20- and 30- are not: smartdns-acl writes them at runtime, long after the
    # install, so nothing recorded them. The allowlist in 20- is worth keeping,
    # so it moves to the backups rather than being deleted - reinstalling and
    # discovering every customer's registered address is gone would be a poor
    # way to learn that uninstall is destructive.
    if [ -f /etc/nftables.d/20-smartdns-state.conf ]; then
        backup_file /etc/nftables.d/20-smartdns-state.conf
        rm -f /etc/nftables.d/20-smartdns-state.conf
        info "allowlist kept in $BACKUP_DIR"
    fi
    rm -f /etc/nftables.d/30-smartdns-enforce.conf
    rm -f /etc/nftables.d/smartdns.conf

    step "Panel"
    # /etc/smart-dns holds the bot token, the shared secret and the sync
    # certificate. Deleting them outright would mean re-pairing every relay
    # after an uninstall that was only meant to move things around, so they go
    # to the backups instead.
    if [ -d /etc/smart-dns ]; then
        mkdir -p "$BACKUP_DIR"
        cp -a /etc/smart-dns "$BACKUP_DIR/smart-dns-config.$STAMP"
        rm -rf /etc/smart-dns
        info "credentials moved to $BACKUP_DIR/smart-dns-config.$STAMP"
    fi
    # The database is the customers, their balances and their usage. It is
    # never deleted by an uninstall, and it is not moved either, so that
    # reinstalling on the same machine simply picks it up again.
    if [ -f "$STATE_DIR/panel.db" ]; then
        info "database left where it is: $STATE_DIR/panel.db"
    fi

    step "Restarting what is left"
    systemctl daemon-reload
    # nginx is only left running if it was already enabled before we arrived,
    # i.e. it is not on the list we just disabled. In that case it now has its
    # original config back and should be put back into service.
    case " $(recall_flat services-enabled) " in
        *" nginx "*) info "nginx was installed here by this script - left stopped" ;;
        *)
            if nginx -t >/dev/null 2>&1; then
                systemctl restart nginx; info "nginx restarted with its original config"
            else
                warn "the restored nginx config does not parse - nginx left alone"
            fi ;;
    esac

    rm -f "$STATE"
    # The version note goes with the state it describes. Left behind, it would
    # tell a later install that this machine already runs a version whose
    # files are no longer here, and that install would skip its own upgrade
    # question on the strength of it.
    rm -f "$STATE_DIR/version"
    # Only if nothing else put anything there; never blow away a
    # directory a later stage of this project may be using.
    rmdir "$STATE_DIR" 2>/dev/null || true
    printf '\n%sRemoved.%s Backups are still in %s if you want anything back.\n\n' "$G" "$N" "$BACKUP_DIR"
    if [ -n "$packages" ]; then
        printf '    To also remove the packages it installed:\n\n'
        printf '        apt-get purge %s\n\n' "$packages"
    fi
    exit 0
}

# --version and --help were answered above, before the preflight.
case "${1:-}" in
    --uninstall|-u|uninstall) uninstall ;;
    # Asked on the exit, carried to the relay by the pairing token - see the
    # tunnel section below.
    --tunnel|tunnel) ASK_TUNNEL=1 ;;
    "") ;;
    *) die "unknown argument: $1  (try --help)" ;;
esac

# ---------------------------------------------------------------- version
# Nothing below has touched the machine yet, and the answer here decides
# whether anything will. Two cases are worth stopping for: an upgrade, which
# the operator should know is happening rather than discover afterwards, and
# the reverse - an older file run over a newer install, which is nearly always
# somebody re-running a download they still had lying around.
VERSION_FILE="$STATE_DIR/version"
INSTALLED_VERSION=""
[ -f "$VERSION_FILE" ] && INSTALLED_VERSION="$(head -1 "$VERSION_FILE" | tr -d "[:space:]")" || true

# The customer database, the settings, the sync secret and any certificate all
# live outside the files this script writes, and every payload it does write is
# backed up before it is replaced. So an upgrade keeps them - but "keeps them"
# is a promise worth a copy behind it, taken before anything starts.
snapshot_db() {
    local db="$STATE_DIR/panel.db" out
    [ -f "$db" ] || return 0
    mkdir -p "$BACKUP_DIR"
    out="$BACKUP_DIR/panel.db.$STAMP"
    # VACUUM INTO, not cp: the panel keeps a write-ahead log beside the file,
    # so a plain copy of the file alone can be a database missing its newest
    # rows. Falls back to cp where sqlite is too old to know the statement.
    if python3 - "$db" "$out" <<'PY' 2>/dev/null
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("VACUUM INTO ?", (sys.argv[2],))
db.close()
PY
    then
        info "database copied to $out"
    elif cp -a "$db" "$out" 2>/dev/null; then
        warn "database copied to $out (plain copy - sqlite here is old)"
    else
        die "could not copy the database at $db. Fix that before upgrading."
    fi
}

if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" != "$VERSION" ]; then
    older="$(printf '%s\n%s\n' "$INSTALLED_VERSION" "$VERSION" | sort -V | head -1)"
    printf '\n%sVersion%s\n\n' "$B" "$N"
    info "installed on this machine:  $INSTALLED_VERSION"
    info "this file:                  $VERSION"
    printf '\n'
    if [ "$older" = "$VERSION" ]; then
        warn "this file is OLDER than what is installed."
        warn "installing it will put old configs over new ones, and this"
        warn "script has no way to undo what a later version did."
        warn "the newest is at github.com/mehdi047/doctor-dns/releases"
        answer=n
    else
        warn "this will upgrade this machine from $INSTALLED_VERSION to $VERSION."
        answer=y
    fi
    warn "your customers, settings, certificates and allowlist are kept."
    printf '\n'
    if [ -z "${ASSUME_YES:-}" ]; then
        read -r -p "  go ahead? [$answer]: " reply
        # An answer piped in from a file written on Windows arrives with
        # a carriage return attached, and a "y" with one glued on
        # matches nothing below.
        reply="$(printf '%s' "$reply" | tr -d '\r')"
        reply="${reply:-$answer}"
    else
        reply="$answer"
        info "ASSUME_YES - taking '$answer'"
    fi
    case "$reply" in
        y|Y|yes|YES) ;;
        *) printf '\n    Nothing was changed.\n\n'; exit 0 ;;
    esac
    snapshot_db
elif [ -n "$INSTALLED_VERSION" ]; then
    info "already at $VERSION - re-running to check and repair"
fi

# An upgrade asks nothing the machine already knows. Every answer the first
# install was given is still here: the state file records the role and both
# addresses on every run, and the domain sits in the config the panel serves
# from. So an upgrade reads them back, keeps the one-time choices - swap, BBR -
# exactly as they are, and the only question it has is the one above: whether
# to install this version at all. It used to walk the whole questionnaire
# again, addresses and all, as if the machine had never been set up.
UPGRADE=""
if [ -n "$INSTALLED_VERSION" ]; then
    UPGRADE=1
    was() { recall "$1" 2>/dev/null | tail -1 || true; }
    ROLE="${ROLE:-$(was role)}"
    if [ -z "$ROLE" ]; then
        if [ -f /etc/smart-dns/sync.env ]; then ROLE=relay
        elif [ -f /etc/smart-dns/panel.env ]; then ROLE=exit
        fi
    fi
    if [ "$ROLE" = relay ]; then
        PEER_IP="${PEER_IP:-$(was exit-ip)}"
        SELF_IP="${SELF_IP:-$(was relay-ip)}"
        # Older state files, or none: the relay's own config has both.
        [ -n "$PEER_IP" ] || PEER_IP="$(sed -n 's/^PANEL_HOST=//p' /etc/smart-dns/sync.env 2>/dev/null | head -1 || true)"
        [ -n "$SELF_IP" ] || SELF_IP="$(sed -n 's/^SELF_IP=//p' /etc/smart-dns/sync.env 2>/dev/null | head -1 || true)"
    elif [ "$ROLE" = exit ]; then
        PEER_IP="${PEER_IP:-$(was relay-ip)}"
        SELF_IP="${SELF_IP:-$(was exit-ip)}"
        # panel.env holds every relay this exit serves, comma separated. Any of
        # them will do here: it is already on the list, so nothing is added.
        [ -n "$PEER_IP" ] || PEER_IP="$(sed -n 's/^RELAY_IP=//p' /etc/smart-dns/panel.env 2>/dev/null | head -1 | cut -d, -f1 || true)"
    fi
    PANEL_DOMAIN="${PANEL_DOMAIN:-$(was panel-domain)}"
    info "upgrading this ${ROLE:-machine} in place - nothing to answer"
fi

# ---------------------------------------------------------------- questions
valid_ip() {
    local ip="$1" part
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a part <<< "$ip"
    for n in "${part[@]}"; do [ "$n" -le 255 ] || return 1; done
}

ROLE="${ROLE:-}"; PEER_IP="${PEER_IP:-}"; SELF_IP="${SELF_IP:-}"

if [ -z "$ROLE" ]; then
    printf '\n%sWhich side is this machine?%s\n\n' "$B" "$N"
    printf '  1) relay  - the server inside Iran, the one clients point their DNS at\n'
    printf '  2) exit   - the server abroad, which reaches the blocked sites\n\n'
    while :; do
        read -r -p "  choice [1/2]: " answer
        case "$answer" in
            1|relay) ROLE=relay; break ;;
            2|exit)  ROLE=exit;  break ;;
            *) warn "answer 1 or 2" ;;
        esac
    done
fi
[ "$ROLE" = relay ] || [ "$ROLE" = exit ] || die "ROLE must be relay or exit"

if [ -z "$PEER_IP" ]; then
    printf '\n'
    if [ "$ROLE" = relay ]; then
        read -r -p "  public address of the EXIT server abroad: " PEER_IP
    else
        read -r -p "  public address of the RELAY server in Iran: " PEER_IP
    fi
fi
valid_ip "$PEER_IP" || die "'$PEER_IP' is not an IPv4 address"

if [ -z "$SELF_IP" ]; then
    guess="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    printf '\n'
    read -r -p "  public address of THIS server [${guess}]: " SELF_IP
    SELF_IP="${SELF_IP:-$guess}"
fi
valid_ip "$SELF_IP" || die "'$SELF_IP' is not an IPv4 address"
[ "$SELF_IP" != "$PEER_IP" ] || die "both addresses are the same"

if [ "$ROLE" = relay ]; then
    RELAY_IP="$SELF_IP"; EXIT_IP="$PEER_IP"
else
    RELAY_IP="$PEER_IP"; EXIT_IP="$SELF_IP"
fi

# ------------------------------------------------------------------ panel
# The panel is optional. Someone who only wants the bypass can leave these
# blank and still get a working pair; the questions are asked here rather than
# halfway through the install so that the whole thing runs unattended after
# this point.
#
# The panel lives on the exit node: it holds the database every relay syncs to,
# and one database is what makes a customer's allowance mean the same thing on
# all of them. The exit builds it unasked; the relay asks for the pairing token
# the exit prints at the end of its own install.
if [ "$ROLE" = relay ] && [ -z "${SYNC_TOKEN:-}" ] && [ -z "${ASSUME_YES:-}" ] && [ -z "$UPGRADE" ]; then
    printf '\n%sPanel%s (optional - press enter to skip)\n\n' "$B" "$N"
    printf '  The exit server prints a pairing token at the end of its install.\n'
    read -r -p "  pairing token: " SYNC_TOKEN
fi
# ------------------------------------------------------------------- TLS
# Optional, like the panel. Without it the claim link is plain http, which
# works but sends the registration token in the clear - anyone on the path can
# take it and register their own address against the user's account.
if [ -z "${PANEL_DOMAIN:-}" ] && [ -z "${ASSUME_YES:-}" ] && [ -z "$UPGRADE" ]; then
    printf '\n%sHTTPS%s (optional - press enter to skip)\n\n' "$B" "$N"
    if [ "$ROLE" = relay ]; then
        printf '  A name pointing at this machine, for the page users open to\n'
        printf '  register their address.\n'
    else
        printf '  A name pointing at this machine, for the admin panel.\n'
    fi
    read -r -p "  domain: " PANEL_DOMAIN
    # Nothing else is asked. The certificate is obtained automatically and the
    # only thing that proves anything is the domain itself - no DNS token, no
    # account, nothing to hand over.
    if [ -n "$PANEL_DOMAIN" ]; then
        printf '\n  A certificate will be obtained for that name automatically.\n'
        printf '  Point the record at this machine first and leave port 80\n'
        printf '  reachable from the internet - that is how it is checked.\n'
    fi
fi

# ------------------------------------------------------------------ tunnel
# How the relay reaches the exit: straight, as it always has, or through a
# BackPack tunnel that hides the names of the sites from filtering on the way.
# The exit is asked, because it is installed first; the relay learns the
# answer from the pairing token, so the two ends cannot disagree. A re-run
# keeps whatever this machine was set up with.
TUNNEL="${TUNNEL:-}"
TUNNEL_SPEC=""
TUNNEL_OUT=""
env_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1 || true; }
# --tunnel: ask again on a machine that is already set up. The exit shows the
# menu with what it has now as the defaults; the relay asks for the exit's new
# pairing token, which carries the answer.
if [ -n "${ASK_TUNNEL:-}" ] && [ -z "$TUNNEL" ]; then
    if [ "$ROLE" = exit ]; then
        CUR_TUNNEL="$(env_get /etc/smart-dns/panel.env TUNNEL)"
        CUR_TRANSPORT="$(env_get /etc/smart-dns/panel.env TUNNEL_TRANSPORT)"
        CUR_DIRECTION="$(env_get /etc/smart-dns/panel.env TUNNEL_DIRECTION)"
        CUR_PORT="$(env_get /etc/smart-dns/panel.env TUNNEL_PORT)"
        ask_tunnel
    elif [ -z "${SYNC_TOKEN:-}" ]; then
        printf '\n%sTunnel%s\n\n' "$B" "$N"
        printf '  Run the installer with --tunnel on the exit first. It prints a new\n'
        printf '  pairing token that carries its answer: paste it here, or press enter\n'
        printf '  to keep the tunnel this relay has now.\n\n'
        read -r -p "  pairing token: " SYNC_TOKEN
    fi
fi
if [ -z "$TUNNEL" ]; then
    if [ "$ROLE" = exit ] && [ -n "$(env_get /etc/smart-dns/panel.env TUNNEL)" ]; then
        TUNNEL="$(env_get /etc/smart-dns/panel.env TUNNEL)"
        TUNNEL_TRANSPORT="${TUNNEL_TRANSPORT:-$(env_get /etc/smart-dns/panel.env TUNNEL_TRANSPORT)}"
        TUNNEL_DIRECTION="${TUNNEL_DIRECTION:-$(env_get /etc/smart-dns/panel.env TUNNEL_DIRECTION)}"
        TUNNEL_PORT="${TUNNEL_PORT:-$(env_get /etc/smart-dns/panel.env TUNNEL_PORT)}"
    elif [ "$ROLE" = relay ]; then
        spec="$(printf '%s' "${SYNC_TOKEN:-}" | cut -s -d. -f3)"
        if [ -n "$spec" ]; then
            parse_tunnel_spec "$spec" || die "the tunnel part of the pairing token, '$spec', is not one this installer knows.
    Install the exit and the relay from the same version of this file."
        elif [ -n "${SYNC_TOKEN:-}" ]; then
            TUNNEL=off          # a two-part token: the exit has no tunnel
        elif [ -n "$(env_get /etc/smart-dns/sync.env TUNNEL)" ]; then
            TUNNEL="$(env_get /etc/smart-dns/sync.env TUNNEL)"
            TUNNEL_TRANSPORT="${TUNNEL_TRANSPORT:-$(env_get /etc/smart-dns/sync.env TUNNEL_TRANSPORT)}"
            TUNNEL_DIRECTION="${TUNNEL_DIRECTION:-$(env_get /etc/smart-dns/sync.env TUNNEL_DIRECTION)}"
            TUNNEL_PORT="${TUNNEL_PORT:-$(env_get /etc/smart-dns/sync.env TUNNEL_PORT)}"
        fi
    fi
fi
if [ "$ROLE" = exit ] && [ -z "$TUNNEL" ] && [ -z "${ASSUME_YES:-}" ] && [ -z "$UPGRADE" ]; then
    ask_tunnel
fi
case "${TUNNEL:-off}" in
    off|no|direct|"") TUNNEL=off ;;
    backpack|on|yes) TUNNEL=backpack ;;
    *) die "TUNNEL must be backpack or off" ;;
esac
if [ "$TUNNEL" = backpack ]; then
    TUNNEL_DIRECTION="${TUNNEL_DIRECTION:-reverse}"
    TUNNEL_TRANSPORT="${TUNNEL_TRANSPORT:-stealth}"
    TUNNEL_PORT="${TUNNEL_PORT:-8444}"
    case "$TUNNEL_DIRECTION" in reverse|direct) ;; *) die "TUNNEL_DIRECTION must be reverse or direct" ;; esac
    tunnel_transport_ok "$TUNNEL_DIRECTION" "$TUNNEL_TRANSPORT" \
        || die "BackPack's $TUNNEL_DIRECTION tunnel has no transport called '$TUNNEL_TRANSPORT'"
    why="$(tunnel_port_problem "$TUNNEL_PORT")"
    [ -z "$why" ] || die "port $TUNNEL_PORT cannot carry the tunnel: $why"
    # The tunnel runs between this relay and its own exit, on a secret only
    # that exit knows - a relay whose panel is on another machine has none.
    if [ "$ROLE" = relay ] && [ -n "${PANEL_IP:-}" ] && [ "$PANEL_IP" != "$EXIT_IP" ]; then
        warn "the panel is on $PANEL_IP, not on this relay's exit - no tunnel"
        TUNNEL=off
    fi
fi
[ "$TUNNEL" = backpack ] && TUNNEL_SPEC="bp-$TUNNEL_TRANSPORT-$TUNNEL_PORT-$(printf '%.1s' "$TUNNEL_DIRECTION")"
if [ "$TUNNEL" = backpack ]; then
    TUNNEL_OUT="BackPack, $TUNNEL_TRANSPORT, $TUNNEL_DIRECTION, port $TUNNEL_PORT"
else
    TUNNEL_OUT="none - the relay reaches the exit directly"
fi

printf '\n%sAbout to configure:%s\n' "$B" "$N"
printf '    role   : %s\n    relay  : %s\n    exit   : %s\n    tunnel : %s\n\n' "$ROLE" "$RELAY_IP" "$EXIT_IP" "$TUNNEL_OUT"
if [ -z "${ASSUME_YES:-}" ] && [ -z "$UPGRADE" ]; then
    read -r -p "  proceed? [y/N]: " ok
    case "$ok" in y|Y|yes) ;; *) die "cancelled" ;; esac
fi

export DEBIAN_FRONTEND=noninteractive
NGINX_CHANGED=0
DNSMASQ_CHANGED=0

# What the run has to tell the operator at the end. Empty here so that the
# summary can read them plainly under `set -u`, whichever paths ran. One of
# these was left unset when the customer panel stopped being served without a
# certificate, and the install died on its very last line - after doing all of
# its work, and before recording that it had.
ADMIN_URL_OUT=""
ADMIN_PASS_OUT=""
SYNC_TOKEN_OUT=""
USER_PANEL_OUT=""
ENFORCE_OUT=""

# Start the record over, but keep what an earlier install already knew: which
# packages were new and which files existed before we ever touched them. Those
# facts are only true the first time, and losing them would make a later
# uninstall unable to tell "we added this" from "this was already here".
mkdir -p "$STATE_DIR"
# Everything an earlier run recorded, read before the state file is rewritten.
# The record has to survive re-installation: by the second run our own files
# exist and our own services are enabled, so a fresh look at the machine can no
# longer tell our work from the owner's.
PREV_PACKAGES="$(recall_flat packages-installed || true)"
PREV_REPLACED="$(recall_flat files-replaced || true)"
PREV_CREATED="$(recall_flat files-created || true)"
PREV_SERVICES="$(recall_flat services-enabled || true)"
: > "$STATE"
remember role "$ROLE"
remember relay-ip "$RELAY_IP"
remember exit-ip "$EXIT_IP"
remember installed-at "$(date -Is)"

# ---------------------------------------------------------------- packages
step "Installing packages"
if [ "$ROLE" = relay ]; then
    WANT="nginx libnginx-mod-stream dnsmasq coturn nftables dnsutils python3 curl"
else
    # nftables for the rule that keeps strangers off the sync API.
    WANT="nginx libnginx-mod-stream dnsutils curl python3 openssl nftables"
fi
# Note what was missing beforehand, so uninstall can name exactly what this
# script added rather than offering to purge nginx from a web server.
if [ -n "$PREV_PACKAGES" ]; then
    NEW_PACKAGES="$(echo "$PREV_PACKAGES" | xargs || true)"
else
    NEW_PACKAGES=""
    for pkg in $WANT; do
        dpkg -s "$pkg" >/dev/null 2>&1 || NEW_PACKAGES="$NEW_PACKAGES $pkg"
    done
    NEW_PACKAGES="$(echo "$NEW_PACKAGES" | xargs || true)"
fi
[ -n "$NEW_PACKAGES" ] && remember packages-installed "$NEW_PACKAGES"
# Only what is missing, and apt is not touched at all when nothing is. It used
# to run apt-get update and reinstall the whole list on every run, which made
# an upgrade slow and quietly upgraded the operator's nginx along the way -
# neither of which an upgrade of this service was asked to do. dpkg-query, not
# dpkg -s: a package removed but not purged still answers dpkg -s happily.
missing=""
for pkg in $WANT; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || missing="$missing $pkg"
done
if [ -n "$missing" ]; then
    apt-get update -qq
    # shellcheck disable=SC2086
    apt-get install -y -qq $missing >/dev/null
    info "installed:$missing"
else
    info "all present"
fi

# ---------------------------------------------------------------- kernel
# ------------------------------------------------------------------- swap
# Off unless asked for: SWAP_GB=2 on the command line, or answer the prompt.
# Worth having on a small box - nginx under a console download opens a lot of
# connections at once, and being killed for it is worse than being slow - but
# it is the operator's disk, so it is never created behind their back.
HAVE_SWAP="$(free -m | awk '/Swap/{print $2}')"
if [ -z "${SWAP_GB:-}" ] && [ -z "${ASSUME_YES:-}" ] && [ -z "$UPGRADE" ]; then
    if [ "${HAVE_SWAP:-0}" = 0 ]; then
        printf '\n%sThis machine has no swap.%s\n\n' "$B" "$N"
        read -r -p "  create a swap file? size in GB, or enter to skip: " SWAP_GB
    else
        # Say so rather than skipping in silence. An operator who expected a
        # question and got nothing cannot tell "already handled" from "the
        # installer forgot", and will go looking - which is exactly what
        # happened the first time somebody ran this on a machine that had swap.
        step "Swap"
        info "already has ${HAVE_SWAP} MB - leaving it alone"
    fi
fi
if [ -n "${SWAP_GB:-}" ] && [ "${SWAP_GB}" != 0 ]; then
    step "Swap file"
    case "$SWAP_GB" in
        *[!0-9]*|"") die "SWAP_GB must be a whole number of gigabytes" ;;
    esac
    if [ -f /swapfile ]; then
        info "/swapfile already exists - leaving it alone"
    else
        avail="$(df --output=avail -BG / | tail -1 | tr -dc '0-9')"
        [ "${avail:-0}" -gt "$((SWAP_GB + 2))" ] \
            || die "only ${avail}G free on / - not creating a ${SWAP_GB}G swap file"
        # fallocate can produce a sparse file, which the kernel refuses to swap
        # to. dd is slower and correct.
        dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024)) status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        note_file /swapfile
        grep -q '^/swapfile ' /etc/fstab 2>/dev/null \
            || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        remember swapfile "/swapfile"
        info "created and enabled ${SWAP_GB}G of swap"
    fi
fi

step "Kernel tuning for the long-RTT link"
install_payload SYSCTL /etc/sysctl.d/99-smartdns-tuning.conf || true
sysctl -p /etc/sysctl.d/99-smartdns-tuning.conf >/dev/null 2>&1 || true

BBR_FILE=/etc/sysctl.d/99-smartdns-bbr.conf
# Congestion control is machine-wide: it changes every connection on the box,
# including services that have nothing to do with this one. So it is asked for
# rather than assumed. On a non-interactive run the existing choice stands,
# which means an upgrade never silently changes how a working server behaves.
if [ -z "${ENABLE_BBR:-}" ]; then
    if [ -n "${ASSUME_YES:-}" ] || [ -n "$UPGRADE" ]; then
        # Keep whatever the machine is already doing. The running value matters
        # as much as the file: earlier versions set bbr from the main tuning
        # file, so on those machines there is no bbr file to find, and deciding
        # by the file alone would leave the kernel on bbr now and drop it at
        # the next reboot - a change nobody asked for, appearing days later.
        if [ -f "$BBR_FILE" ] || \
           [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]; then
            ENABLE_BBR=yes
        else
            ENABLE_BBR=no
        fi
    else
        printf '\n    %sBBR congestion control%s\n' "$B" "$N"
        printf '    Paces by measured bandwidth instead of backing off on loss.\n'
        printf '    On a %s ms link it is worth a great deal, but it affects every\n' "90"
        printf '    connection on this machine, not only this service.\n\n'
        read -r -p "    enable BBR? [Y/n]: " answer
        case "$answer" in n|N|no) ENABLE_BBR=no ;; *) ENABLE_BBR=yes ;; esac
    fi
fi
case "$ENABLE_BBR" in
    yes|y|1|true)
        install_payload SYSCTL_BBR "$BBR_FILE" || true
        sysctl -p "$BBR_FILE" >/dev/null 2>&1 || true
        ;;
    no|n|0|false)
        rm -f "$BBR_FILE"
        if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ]; then
            # Only fall back to the kernel default if nothing else on the
            # machine asks for bbr. Someone who set it themselves, in their own
            # file, keeps it - they did not ask this installer to decide.
            if grep -rqs 'tcp_congestion_control' /etc/sysctl.conf /etc/sysctl.d 2>/dev/null; then
                info "BBR left on - another config on this machine sets it"
            else
                sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
                sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
                info "BBR turned off"
            fi
        fi
        ;;
esac
info "congestion=$(sysctl -n net.ipv4.tcp_congestion_control) qdisc=$(sysctl -n net.core.default_qdisc)"

# ---------------------------------------------------------------- nginx
step "nginx"
MOD="$(find /usr/lib/nginx/modules -name ngx_stream_module.so 2>/dev/null | head -1)"
[ -n "$MOD" ] || die "the nginx stream module is missing - libnginx-mod-stream did not install"
info "stream module: $MOD"
# Google refuses Gemini and its other AI services to some exits' IPv4 addresses
# and serves the same pages to the same machine over IPv6, so where the exit
# has working IPv6, Google's own names leave over it. That needs a resolver
# that can be told to ask for AAAA records only, which nginx has from 1.23.1 -
# older, or without IPv6, the block is left out and nothing changes.
NO_GOOGLE_V6=1
if [ "$ROLE" = exit ]; then
    ngv="$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')"
    if [ "$(printf '%s\n%s\n' 1.23.1 "${ngv:-0}" | sort -V | head -1)" = 1.23.1 ] \
       && curl -6 -s -o /dev/null -m 10 https://www.google.com/ 2>/dev/null; then
        NO_GOOGLE_V6=""
        info "Google's own names leave over IPv6 (Gemini is refused to some exits' IPv4)"
    else
        info "no working IPv6 here, or nginx older than 1.23.1 - Google leaves over IPv4"
    fi
fi
# The tunnel's binary comes before nginx, so that a download that fails
# leaves this run on the direct path rather than with nginx pointed at a
# tunnel that will never be there.
if [ "$TUNNEL" = backpack ] && ! install_backpack; then
    warn "no tunnel this run - the relay reaches the exit directly"
    TUNNEL=off; TUNNEL_SPEC=""; TUNNEL_OUT="none - BackPack could not be installed"
fi
if [ "$ROLE" = relay ] && [ "$TUNNEL" = backpack ]; then
    NO_TUNNEL=""; EXIT_HTTPS=to_exit_https; EXIT_HTTP=to_exit_http
else
    NO_TUNNEL=1; EXIT_HTTPS="$EXIT_IP:443"; EXIT_HTTP="$EXIT_IP:80"
fi
if [ "$ROLE" = relay ]; then
    install_payload RELAY_NGINX /etc/nginx/nginx.conf && NGINX_CHANGED=1 || true
else
    install_payload EXIT_NGINX /etc/nginx/nginx.conf && NGINX_CHANGED=1 || true
fi
nginx -t || die "nginx rejected the config; the previous one is in $BACKUP_DIR"
enable_service nginx nginx

# ---------------------------------------------------------------- relay only
if [ "$ROLE" = relay ]; then

    step "dnsmasq: the routed domain list"
    note_file /etc/dnsmasq.d/smart-dns.conf
    tmp="$(mktemp)"
    {
        # No timestamp in here. It would make the file differ on every run, so
        # every run would rewrite it and restart dnsmasq for no reason.
        printf '# generated by the smart-dns installer - do not edit by hand\n'
        # No Google. 8.8.8.8 passes the asker's subnet on (ECS), and services
        # that refuse Iran in their DNS - Tencent's games answer 0.0.0.1 - saw
        # this relay's Iranian subnet and refused it. Neither of these two
        # sends it, and dnsmasq takes turns between them.
        printf 'no-resolv\nserver=1.1.1.1\nserver=9.9.9.9\n'
        printf 'cache-size=10000\ndomain-needed\nbogus-priv\nno-hosts\n'
        printf 'bind-interfaces\nlisten-address=127.0.0.1,%s\n\n' "$RELAY_IP"
        printf '# domains answered with this relay, so the traffic leaves via the exit\n'
        payload DOMAINS | while read -r d; do
            [ -n "$d" ] && printf 'address=/%s/%s\n' "$d" "$RELAY_IP"
        done
    } > "$tmp"
    if [ -f /etc/dnsmasq.d/smart-dns.conf ] && cmp -s "$tmp" /etc/dnsmasq.d/smart-dns.conf; then
        rm -f "$tmp"; info "unchanged ($(grep -c '^address=' /etc/dnsmasq.d/smart-dns.conf) domains)"
    else
        backup_file /etc/dnsmasq.d/smart-dns.conf
        mv "$tmp" /etc/dnsmasq.d/smart-dns.conf; chmod 644 /etc/dnsmasq.d/smart-dns.conf
        info "wrote $(grep -c '^address=' /etc/dnsmasq.d/smart-dns.conf) domains"
        DNSMASQ_CHANGED=1
    fi

    step "dnsmasq: names that must NOT be routed"
    install_payload BYPASS /etc/dnsmasq.d/bypass.conf && DNSMASQ_CHANGED=1 || true
    rm -f /etc/dnsmasq.d/ea-bypass.conf   # superseded filename from an earlier build

    step "dnsmasq: stop AAAA answers routing clients around us"
    install_payload NO_AAAA /etc/dnsmasq.d/no-aaaa.conf && DNSMASQ_CHANGED=1 || true

    dnsmasq --test -C /etc/dnsmasq.conf || die "dnsmasq rejected the config"
    enable_service dnsmasq dnsmasq

    step "STUN server, so consoles can still detect their NAT"
    install_payload TURNSERVER /etc/turnserver.conf || true
    grep -q '^TURNSERVER_ENABLED=1' /etc/default/coturn 2>/dev/null \
        || echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn
    enable_service coturn coturn
    systemctl restart coturn || warn "coturn did not start; STUN will be unavailable"

    step "Firewall: rate limit, access control and traffic accounting"
    export PATH="$PATH:/usr/sbin"
    mkdir -p /etc/nftables.d
    # An earlier version of this installer built the table with a series of
    # `nft add` commands and dumped the result here. That file is a complete
    # table definition, so leaving it in place would load a second copy of
    # every chain alongside the one below.
    if [ -f /etc/nftables.d/smartdns.conf ]; then
        backup_file /etc/nftables.d/smartdns.conf
        rm -f /etc/nftables.d/smartdns.conf
        info "removed the ruleset from the previous layout"
    fi
    grep -q 'nftables.d' /etc/nftables.conf 2>/dev/null \
        || echo 'include "/etc/nftables.d/*.conf"' >> /etc/nftables.conf

    install_payload NFTABLES /etc/nftables.d/10-smartdns.conf && NFT_CHANGED=1 || NFT_CHANGED=0
    # Reload only when the structure actually changed, or when the table is
    # missing entirely. Loading it on every run would append a duplicate of
    # every rule; rebuilding the table on every run would throw away the
    # allowlist and everybody's usage along with it.
    if [ "$NFT_CHANGED" = 1 ] || ! nft list table inet smartdns >/dev/null 2>&1; then
        [ -x /usr/local/bin/smartdns-acl ] && /usr/local/bin/smartdns-acl save 2>/dev/null
        nft delete table inet smartdns 2>/dev/null || true
        nft -f /etc/nftables.d/10-smartdns.conf || die "nft rejected the ruleset"
        # Structure first, then whoever was registered before it, then the
        # access rules if this machine had them switched on.
        [ -f /etc/nftables.d/20-smartdns-state.conf ] \
            && { nft -f /etc/nftables.d/20-smartdns-state.conf || warn "could not restore the allowlist"; }
        [ -f /etc/nftables.d/30-smartdns-enforce.conf ] \
            && { nft -f /etc/nftables.d/30-smartdns-enforce.conf || warn "could not restore the access rules"; }
        info "ruleset loaded"
    else
        info "ruleset already current"
    fi
    enable_service nftables nftables

    step "smartdns-acl command, for access control and usage"
    note_file /usr/local/bin/smartdns-acl
    payload SMARTDNS_ACL > /usr/local/bin/smartdns-acl
    chmod +x /usr/local/bin/smartdns-acl
    install_payload ACL_SAVE_SERVICE /etc/systemd/system/smartdns-acl-save.service || true
    install_payload ACL_SAVE_TIMER   /etc/systemd/system/smartdns-acl-save.timer   || true
    systemctl daemon-reload
    enable_service smartdns-acl-save.timer
    systemctl start smartdns-acl-save.timer 2>/dev/null || true
    # Counting starts now; blocking does not. Nobody has registered an address
    # yet, so switching enforcement on at this point would cut off every user
    # of the relay, including whoever is running this.
    info "counting usage - nothing is blocked yet"

    step "smartdns-shape command, for per-customer speed limits"
    note_file /usr/local/bin/smartdns-shape
    payload SMARTDNS_SHAPE > /usr/local/bin/smartdns-shape
    chmod +x /usr/local/bin/smartdns-shape
    # Nothing is shaped until a customer is actually given a limit; the sync
    # agent calls this when the panel says somebody has one.
    if ! modprobe sch_htb 2>/dev/null; then
        warn "this kernel has no htb - speed limits will not work here"
    fi
    info "no limits set - customers run at line rate until you set one"

    step "smartdns command"
    note_file /usr/local/bin/smartdns
    payload SMARTDNS | sed "s#__RELAY_IP__#${RELAY_IP}#g" > /usr/local/bin/smartdns
    chmod +x /usr/local/bin/smartdns
    info "try: smartdns status"

    step "smartdns-rules command, for what each template does with a domain"
    note_file /usr/local/bin/smartdns-rules
    payload SMARTDNS_RULES > /usr/local/bin/smartdns-rules
    chmod +x /usr/local/bin/smartdns-rules
    info "try: smartdns-rules check gemini.google.com"

    step "smartdns-watch command, for the names a customer asks for"
    note_file /usr/local/bin/smartdns-watch
    payload SMARTDNS_WATCH > /usr/local/bin/smartdns-watch
    chmod +x /usr/local/bin/smartdns-watch
    info "try: smartdns-watch <username or address>"

    step "epic-pin, keeping Epic's backend on addresses that answer from here"
    # epic-pins.conf is written later by epic-pin itself, but it is ours either
    # way and uninstall needs to know to take it with us.
    for f in /usr/local/bin/epic-pin \
             /etc/systemd/system/epic-pin.service \
             /etc/systemd/system/epic-pin.timer \
             /etc/dnsmasq.d/epic-pins.conf
    do
        note_file "$f"
    done
    payload EPIC_PIN > /usr/local/bin/epic-pin
    chmod +x /usr/local/bin/epic-pin
    payload EPIC_PIN_SERVICE > /etc/systemd/system/epic-pin.service
    payload EPIC_PIN_TIMER   > /etc/systemd/system/epic-pin.timer
    systemctl daemon-reload
    enable_service epic-pin.timer
    systemctl start epic-pin.timer  >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------- TLS
# A machine that already has a domain keeps it, even when this run was not
# told one. Everything below is gated on PANEL_DOMAIN - the certificate, its
# renewal timer, the admin panel and its restart - so an upgrade that did not
# repeat the domain skipped all of it and still ended by announcing a
# successful upgrade. The operator is then left on the previous version of the
# one page they actually use, with nothing said. That is not hypothetical: it
# happened here, and the symptom was an admin panel showing a stale service
# catalogue and a stale warning under every group in it.
#
# The state file is no help - it is truncated at the start of every run - so
# the answer has to come from something the machine keeps for its own sake.
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
if [ -z "$PANEL_DOMAIN" ]; then
    if [ -f /etc/smart-dns/sync.env ]; then
        PANEL_DOMAIN="$(sed -n 's/^PANEL_DOMAIN=//p' /etc/smart-dns/sync.env \
                        | head -1 || true)"
    fi
    # The exit keeps no sync.env. Its admin.env records where the certificate
    # is, and that path is /etc/letsencrypt/live/<domain>/fullchain.pem.
    if [ -z "$PANEL_DOMAIN" ] && [ -f /etc/smart-dns/admin.env ]; then
        PANEL_DOMAIN="$(sed -n \
            's#^ADMIN_CERT=/etc/letsencrypt/live/\([^/]*\)/.*#\1#p' \
            /etc/smart-dns/admin.env | head -1 || true)"
    fi
    if [ -n "$PANEL_DOMAIN" ]; then
        info "keeping the domain this machine already has: $PANEL_DOMAIN"
    fi
fi

# The helper goes on every machine, domain or no domain. Without one this run
# installs no certificate - but the summary at the end tells the operator to
# come back and run this command once they have a name, and a command that is
# only installed when it is not needed is not much of an instruction.
payload CERT > /usr/local/bin/smartdns-cert
chmod +x /usr/local/bin/smartdns-cert
note_file /usr/local/bin/smartdns-cert
payload SMARTDNS_LOGS > /usr/local/bin/smartdns-logs
chmod +x /usr/local/bin/smartdns-logs
note_file /usr/local/bin/smartdns-logs
payload SMARTDNS_RESTART > /usr/local/bin/smartdns-restart
chmod +x /usr/local/bin/smartdns-restart
note_file /usr/local/bin/smartdns-restart
# On either side, tunnel or none: status says there is none, which is itself
# the answer somebody asking wants.
payload SMARTDNS_TUNNEL > /usr/local/bin/smartdns-tunnel
chmod +x /usr/local/bin/smartdns-tunnel
note_file /usr/local/bin/smartdns-tunnel
payload SMARTDNS_MENU > /usr/local/bin/smartdns-menu
chmod +x /usr/local/bin/smartdns-menu
note_file /usr/local/bin/smartdns-menu
install_payload CERT_SERVICE /etc/systemd/system/smartdns-cert.service || true
install_payload CERT_TIMER   /etc/systemd/system/smartdns-cert.timer   || true
systemctl daemon-reload

if [ -n "${PANEL_DOMAIN:-}" ]; then
    step "HTTPS certificate for $PANEL_DOMAIN"
    CERT_PKGS="certbot"
    [ -f /etc/smart-dns/cloudflare.ini ] && CERT_PKGS="$CERT_PKGS python3-certbot-dns-cloudflare"
    for pkg in $([ -z "${PANEL_CERT:-}" ] && echo $CERT_PKGS); do
        dpkg -s "$pkg" >/dev/null 2>&1 || {
            apt-get install -y -qq "$pkg" >/dev/null 2>&1 || die "could not install $pkg"
            NEW_PACKAGES="$NEW_PACKAGES $pkg"
            remember packages-installed "$pkg"
        }
    done

    mkdir -p /etc/smart-dns; chmod 700 /etc/smart-dns

    # A certificate the operator obtained themselves. Recorded and used as-is;
    # keeping it renewed is then their business, which is the trade they made
    # by not handing over a DNS token.
    if [ -n "${PANEL_CERT:-}" ]; then
        [ -f "$PANEL_CERT" ] || die "no certificate at $PANEL_CERT"
        [ -f "${PANEL_KEY:-}" ] || die "no private key at ${PANEL_KEY:-<not given>}"
        CERT_PATH="$PANEL_CERT"; KEY_PATH="$PANEL_KEY"
        info "using the certificate you supplied"
        # Nothing here renews it, so say how long it has. A panel that stops
        # answering in two months with no warning is a bad way to find out.
        if openssl x509 -checkend $((30 * 86400)) -noout -in "$CERT_PATH" >/dev/null 2>&1; then
            info "valid until $(openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)"
        else
            warn "this certificate expires within 30 days - nothing here renews it"
        fi
    else
        # certbot's own. It proves the domain over port 80 by default, which
        # needs nothing from the operator but a record pointing here. A token
        # left in cloudflare.ini switches it to DNS instead, but nothing asks
        # for one and nothing needs one.
        if [ -n "${CF_API_TOKEN:-}" ]; then
            umask 077
            printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" \
                > /etc/smart-dns/cloudflare.ini
            umask 022
            chmod 600 /etc/smart-dns/cloudflare.ini
        fi
        CERT_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem"
        KEY_PATH="/etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem"
    fi

    if [ -z "${PANEL_CERT:-}" ]; then
        /usr/local/bin/smartdns-cert "$PANEL_DOMAIN" || die "could not get a certificate"
        # Only once there is something to renew. A timer running against no
        # certificate is a unit that wakes twice a day to do nothing.
        enable_service smartdns-cert.timer
        systemctl start smartdns-cert.timer 2>/dev/null || true
    fi
    [ -f "$CERT_PATH" ] || die "still no certificate at $CERT_PATH"
    remember panel-domain "$PANEL_DOMAIN"
fi

# ----------------------------------------------------------------- panel
if [ "$ROLE" = exit ]; then
    step "Panel: database and sync API"
    mkdir -p /etc/smart-dns; chmod 700 /etc/smart-dns

    # The relay authenticates this machine by the fingerprint of this
    # certificate, so it must survive re-runs: generating a new one would
    # silently break the pairing and the relay would refuse to talk.
    if [ ! -f /etc/smart-dns/sync.key ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=smartdns-sync" \
            -keyout /etc/smart-dns/sync.key -out /etc/smart-dns/sync.crt \
            >/dev/null 2>&1 || die "could not generate the sync certificate"
        chmod 600 /etc/smart-dns/sync.key
        info "generated the sync certificate"
    fi
    # Same for the shared secret. Re-running the installer must not unpair a
    # relay that is working.
    # `|| true` again: on the first install panel.env does not exist, sed exits
    # non-zero, and under `set -e` with pipefail that ends the installer right
    # here without printing anything.
    SYNC_SECRET="$(sed -n 's/^SYNC_SECRET=//p' /etc/smart-dns/panel.env 2>/dev/null | head -1 || true)"
    [ -n "$SYNC_SECRET" ] || SYNC_SECRET="$(openssl rand -hex 24)"

    umask 077
    if [ ! -f /etc/smart-dns/panel.env ]; then
        cat > /etc/smart-dns/panel.env <<EOF
# Secrets and panel settings. Not in git and not in the installer: this file is
# written at install time and is readable only by root.
SYNC_SECRET=$SYNC_SECRET
RELAY_IP=$RELAY_IP
EOF
    else
        # Merge rather than rewrite. An earlier version of this rewrote the
        # whole file on every run, which silently undid the operator's own
        # settings - a second relay added to RELAY_IP, a CLAIM_HOST - and the
        # only symptom was the other relay suddenly getting 401s.
        # RELAY_IP is a list, and this relay may already be on it or may be a
        # new one joining. Adding is right; replacing would unpair the others.
        current_relays="$(sed -n 's/^RELAY_IP=//p' /etc/smart-dns/panel.env | head -1 || true)"
        case ",${current_relays}," in
            *",$RELAY_IP,"*) ;;
            *) set_env_key /etc/smart-dns/panel.env RELAY_IP \
                   "${current_relays:+$current_relays,}$RELAY_IP"
               info "added $RELAY_IP to the relays this panel serves" ;;
        esac
    fi
    # What a re-run or an upgrade keeps, unasked.
    set_env_key /etc/smart-dns/panel.env TUNNEL "$TUNNEL"
    set_env_key /etc/smart-dns/panel.env TUNNEL_TRANSPORT "${TUNNEL_TRANSPORT:-}"
    set_env_key /etc/smart-dns/panel.env TUNNEL_DIRECTION "${TUNNEL_DIRECTION:-}"
    set_env_key /etc/smart-dns/panel.env TUNNEL_PORT "${TUNNEL_PORT:-}"
    umask 022
    chmod 600 /etc/smart-dns/panel.env

    payload PANEL > /usr/local/bin/smartdns-panel
    chmod +x /usr/local/bin/smartdns-panel
    note_file /usr/local/bin/smartdns-panel
    # The service catalogue: which brands exist, and which domains are in each
    # group. Shipped as a file so it is versioned with the code rather than
    # migrated into the database.
    mkdir -p /usr/local/share/smart-dns
    note_file /usr/local/share/smart-dns/services.json
    payload SERVICES > /usr/local/share/smart-dns/services.json
    # Only the relays reach the sync API. The panel's service runs this before
    # every start, so a relay added to RELAY_IP by hand is let in the next time
    # the panel restarts - exactly when the panel itself would let it in.
    note_file /usr/local/bin/smartdns-api-guard
    payload SMARTDNS_API_GUARD > /usr/local/bin/smartdns-api-guard
    chmod +x /usr/local/bin/smartdns-api-guard
    install_payload PANEL_SERVICE /etc/systemd/system/smartdns-panel.service || true
    systemctl daemon-reload
    enable_service smartdns-panel.service
    systemctl restart smartdns-panel.service
    sleep 2
    if systemctl is-active --quiet smartdns-panel.service; then
        info "sync API is up on :8443"
    else
        warn "the panel did not start - journalctl -u smartdns-panel"
    fi
    if nft list table inet smartdns_api >/dev/null 2>&1; then
        info "port 8443 answers the relays only: $(sed -n 's/^RELAY_IP=//p' /etc/smart-dns/panel.env | head -1)"
    else
        warn "port 8443 could not be closed to strangers - the panel still refuses them itself"
    fi

    # ---- admin web panel -------------------------------------------------
    if [ -n "${PANEL_DOMAIN:-}" ]; then
        step "Admin web panel"
        payload ADMIN > /usr/local/bin/smartdns-admin
        chmod +x /usr/local/bin/smartdns-admin
        note_file /usr/local/bin/smartdns-admin
        install_payload ADMIN_SERVICE /etc/systemd/system/smartdns-admin.service || true

        payload SMARTDNS_ACCESS > /usr/local/bin/smartdns-access
        chmod +x /usr/local/bin/smartdns-access
        note_file /usr/local/bin/smartdns-access

        # Generated once and kept. Regenerating on every run would move the URL
        # and change the password under the operator each time they upgraded.
        if [ ! -f /etc/smart-dns/admin.env ]; then
            # Asked for, not assumed. The port is the operator's firewall to
            # think about, and a password they chose is one they will still
            # have tomorrow - a generated one gets pasted somewhere careless
            # or lost. Both have answers, so pressing enter is fine.
            if [ -z "${ASSUME_YES:-}" ]; then
                printf '\n%sAdmin panel%s\n\n' "$B" "$N"
                if [ -z "${ADMIN_PORT:-}" ]; then
                    # Said before the question rather than after a rejected
                    # answer: an operator who has already typed 443 has
                    # usually also written it into a firewall rule.
                    warn "these ports are taken - do not pick one of them:"
                    warn "    22    ssh"
                    warn "    53    dns"
                    warn "    80    the proxy, and how certificates are proved"
                    warn "   443    the proxy"
                    warn "  8443    the sync API the relays connect to"
                    warn "  8446    the exit's own route to Google over IPv6"
                    warn "on a relay, 3478 is taken as well."
                    warn "pick anything else, and open it in your firewall."
                    printf '\n'
                    read -r -p "  port to serve it on [9443]: " ADMIN_PORT
                fi
                if [ -z "${ADMIN_PASS:-}" ]; then
                    printf '  password [enter for a generated one]: '
                    read -rs ADMIN_PASS; printf '\n'
                    if [ -n "$ADMIN_PASS" ]; then
                        printf '  again: '
                        read -rs ADMIN_PASS2; printf '\n'
                        [ "$ADMIN_PASS" = "$ADMIN_PASS2" ] \
                            || die "the two passwords did not match"
                        [ "${#ADMIN_PASS}" -ge 8 ] \
                            || die "use a password of 8 characters or more"
                    fi
                fi
            fi
            ADMIN_PORT="${ADMIN_PORT:-9443}"
            case "$ADMIN_PORT" in
                *[!0-9]*|"") die "the admin port must be a number" ;;
                22) die "port 22 is ssh" ;;
                8443) die "port 8443 is the sync API the relays connect to" ;;
                8446) die "port 8446 is the exit's own route to Google over IPv6" ;;
                53|80|443) die "port $ADMIN_PORT is the service's own - pick
    another. 22, 53, 80, 443, 8443 and 8446 are all taken." ;;
                "${TUNNEL_PORT:-none}") die "port $ADMIN_PORT carries the tunnel - pick another" ;;
            esac
            # The path stays generated. Nobody types it from memory, and an
            # operator asked to invent one invents a guessable one.
            [ -n "${ADMIN_PASS:-}" ] \
                || ADMIN_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
            ADMIN_SALT="$(openssl rand -hex 16)"
            ADMIN_HASH="$(ADMIN_PASS="$ADMIN_PASS" ADMIN_SALT="$ADMIN_SALT" python3 -c '
import hashlib, os
print(hashlib.pbkdf2_hmac("sha256", os.environ["ADMIN_PASS"].encode(),
                          bytes.fromhex(os.environ["ADMIN_SALT"]), 200000).hex())')"
            ADMIN_PATH_GEN="$(openssl rand -hex 12)"
            umask 077
            cat > /etc/smart-dns/admin.env <<EOF
# Written once at install. The password itself is not stored - only a salted
# hash - so a forgotten password is replaced, never recovered.
ADMIN_PORT=$ADMIN_PORT
ADMIN_PATH=$ADMIN_PATH_GEN
ADMIN_SALT=$ADMIN_SALT
ADMIN_HASH=$ADMIN_HASH
ADMIN_CERT=$CERT_PATH
ADMIN_KEY=$KEY_PATH
EOF
            umask 022
            chmod 600 /etc/smart-dns/admin.env
            ADMIN_URL_OUT="https://$PANEL_DOMAIN:$ADMIN_PORT/$ADMIN_PATH_GEN/"
            ADMIN_PASS_OUT="$ADMIN_PASS"
        else
            info "keeping the admin URL and password already set up here"
            info "change them with: smartdns-access"
        fi
        install_font
        # Which operator each customer's address is on, for the users page: a
        # daily list of the operators' own address blocks from RIPE, matched
        # here, so no customer's address is sent anywhere.
        for f in /usr/local/bin/smartdns-operators \
                 /etc/systemd/system/smartdns-operators.service \
                 /etc/systemd/system/smartdns-operators.timer; do
            note_file "$f"
        done
        payload OPERATORS > /usr/local/bin/smartdns-operators
        chmod +x /usr/local/bin/smartdns-operators
        payload OPERATORS_SERVICE > /etc/systemd/system/smartdns-operators.service
        payload OPERATORS_TIMER   > /etc/systemd/system/smartdns-operators.timer
        systemctl daemon-reload
        enable_service smartdns-admin.service
        enable_service smartdns-operators.timer
        systemctl start smartdns-operators.timer >/dev/null 2>&1 || true
        # The first list now, in the background, rather than at the timer's
        # first tick - so the users page has operators on it from the start.
        [ -s /var/lib/smart-dns/operators.json ] \
            || systemctl start --no-block smartdns-operators.service >/dev/null 2>&1 || true
        systemctl restart smartdns-admin.service
        sleep 2
        if systemctl is-active --quiet smartdns-admin.service; then
            info "admin panel running"
        else
            warn "the admin panel did not start - journalctl -u smartdns-admin"
        fi
    fi

    FP="$(openssl x509 -in /etc/smart-dns/sync.crt -noout -fingerprint -sha256 \
          | cut -d= -f2 | tr -d ':' | tr 'A-Z' 'a-z')"
    # A third part when there is a tunnel, so the relay sets up the same one.
    SYNC_TOKEN_OUT="$SYNC_SECRET.$FP${TUNNEL_SPEC:+.$TUNNEL_SPEC}"
fi

# A relay that is already paired keeps its pairing. Requiring the token again
# on every run meant an upgrade run without it skipped this whole section and
# silently left the old agent in place - the machine kept syncing, so nothing
# looked wrong, while the new code never arrived.
if [ "$ROLE" = relay ] && [ -z "${SYNC_TOKEN:-}" ] && [ -f /etc/smart-dns/sync.env ]; then
    SYNC_TOKEN="$(sed -n 's/^SYNC_SECRET=//p' /etc/smart-dns/sync.env | head -1 || true).$(sed -n 's/^SYNC_FINGERPRINT=//p' /etc/smart-dns/sync.env | head -1 || true)"
    PANEL_IP="${PANEL_IP:-$(sed -n 's/^PANEL_HOST=//p' /etc/smart-dns/sync.env | head -1 || true)}"
    KEEP_PAIRING=1
fi

if [ "$ROLE" = relay ] && [ -n "${SYNC_TOKEN:-}" ]; then
    step "Panel: sync agent and claim page"
    # secret.fingerprint - one string for the user to copy, carrying both the
    # shared secret and the certificate to pin. Splitting them into two
    # questions only creates a chance to paste one and forget the other.
    # The third part, when there is one, is the tunnel, read further up.
    SECRET="$(printf '%s' "$SYNC_TOKEN" | cut -d. -f1)"
    FINGER="$(printf '%s' "$SYNC_TOKEN" | cut -s -d. -f2)"
    [ -n "$SECRET" ] && [ -n "$FINGER" ] && [ "$SECRET" != "$FINGER" ] \
        || die "that does not look like a pairing token.
    It is the whole 'secret.fingerprint' line the exit server printed."
    case "$FINGER" in
        *[!0-9a-f]*|"") die "the fingerprint half of the token is not hexadecimal" ;;
    esac
    [ -n "${KEEP_PAIRING:-}" ] && info "keeping the pairing already on this machine"

    # Usually the panel lives on this relay's own exit, but it need not: one
    # database can serve several relay/exit pairs, and one database is what
    # makes a customer's allowance mean the same thing on all of them.
    # PANEL_IP names the machine running the panel when it is a different one.
    PANEL_HOST="${PANEL_IP:-$EXIT_IP}"
    valid_ip "$PANEL_HOST" || die "PANEL_IP '$PANEL_HOST' is not an IPv4 address"

    mkdir -p /etc/smart-dns; chmod 700 /etc/smart-dns
    # Recover the domain this relay already serves its panel on, if this run
    # was not told one. Without this, re-running the installer and pressing
    # enter at the domain prompt blanked PANEL_DOMAIN, and the customer panel
    # silently dropped from https to plain http - which also switches sign-up
    # off. The same trap that once rewrote panel.env on the exit.
    if [ -z "${PANEL_DOMAIN:-}" ] && [ -f /etc/smart-dns/sync.env ]; then
        PANEL_DOMAIN="$(sed -n 's/^PANEL_DOMAIN=//p' /etc/smart-dns/sync.env | head -1 || true)"
        [ -n "$PANEL_DOMAIN" ] && info "keeping the panel domain already set: $PANEL_DOMAIN"
    fi
    umask 077
    if [ ! -f /etc/smart-dns/sync.env ]; then
        cat > /etc/smart-dns/sync.env <<EOF
PANEL_HOST=$PANEL_HOST
SYNC_SECRET=$SECRET
SYNC_FINGERPRINT=$FINGER
SELF_IP=$RELAY_IP
PANEL_DOMAIN=${PANEL_DOMAIN:-}
EOF
    else
        # Merge, so anything the operator added by hand survives an upgrade.
        set_env_key /etc/smart-dns/sync.env PANEL_HOST "$PANEL_HOST"
        set_env_key /etc/smart-dns/sync.env SYNC_SECRET "$SECRET"
        set_env_key /etc/smart-dns/sync.env SYNC_FINGERPRINT "$FINGER"
        set_env_key /etc/smart-dns/sync.env SELF_IP "$RELAY_IP"
        set_env_key /etc/smart-dns/sync.env PANEL_DOMAIN "${PANEL_DOMAIN:-}"
    fi
    set_env_key /etc/smart-dns/sync.env TUNNEL "$TUNNEL"
    set_env_key /etc/smart-dns/sync.env TUNNEL_TRANSPORT "${TUNNEL_TRANSPORT:-}"
    set_env_key /etc/smart-dns/sync.env TUNNEL_DIRECTION "${TUNNEL_DIRECTION:-}"
    set_env_key /etc/smart-dns/sync.env TUNNEL_PORT "${TUNNEL_PORT:-}"
    umask 022
    chmod 600 /etc/smart-dns/sync.env

    payload SYNC > /usr/local/bin/smartdns-sync
    chmod +x /usr/local/bin/smartdns-sync
    note_file /usr/local/bin/smartdns-sync
    install_font
    # A systemd template, one instance per service profile. The instances
    # themselves are started and stopped by the sync agent as the panel adds
    # and retires templates, so nothing here is enabled.
    install_payload DNS_PROFILE_UNIT /etc/systemd/system/smartdns-dns@.service || true
    mkdir -p /etc/smartdns-profiles
    install_payload SYNC_SERVICE /etc/systemd/system/smartdns-sync.service || true
    systemctl daemon-reload
    enable_service smartdns-sync.service
    systemctl restart smartdns-sync.service
    sleep 3
    # Where the customer's panel ended up, for the summary at the end. It is
    # served over TLS or not at all - it asks for a password, and there is no
    # safe way to do that in the clear - so a relay with no certificate has no
    # panel and nothing to print. 8443 sits outside the gated ports on purpose,
    # so somebody whose address changed can still reach the page that fixes it.
    if [ -n "${PANEL_DOMAIN:-}" ]; then
        USER_PANEL_OUT="https://$PANEL_DOMAIN:8443/"
    fi
    # Closed from the moment it is installed. This used to wait for the first
    # customer to register before shutting the door, on the reasoning that
    # enforcing against an empty allowlist cuts everyone off - but on a fresh
    # relay there is nobody to cut off, and what "waiting" really means is a
    # relay that anybody who learns its address can use for free, for as long
    # as it takes somebody to notice.
    #
    # Nothing here is at risk from it. SSH is never gated, the customer panel
    # is on a port the gate does not touch, and the certificate challenge is
    # redirected in prerouting so it reaches certbot before the gate ever sees
    # a packet on 80.
    rm -f /etc/smart-dns/auto-enforce
    if [ "${ENFORCE:-yes}" = no ]; then
        info "ENFORCE=no - this relay is open to everyone until you close it:"
        info "    smartdns-acl enforce on"
    elif smartdns-acl enforce on --yes --allow-empty >/dev/null 2>&1; then
        ENFORCE_OUT=1
        info "access control is on - only registered addresses get through"
    else
        warn "could not switch access control on - this relay is open."
        warn "close it by hand once you have looked:  smartdns-acl enforce on"
    fi
    if systemctl is-active --quiet smartdns-sync.service; then
        info "syncing with the panel at $PANEL_HOST every 30s"
        if [ -n "$USER_PANEL_OUT" ]; then
            info "customer panel on $USER_PANEL_OUT"
        else
            warn "no certificate, so no customer panel - see the end of this run"
        fi
    else
        warn "the sync agent did not start - journalctl -u smartdns-sync"
    fi
fi

# ---------------------------------------------------------------- tunnel
if [ "$ROLE" = exit ]; then apply_tunnel "${SYNC_SECRET:-}"; else apply_tunnel "${SECRET:-}"; fi

# ---------------------------------------------------------------- start
step "Starting services"
if [ "$NGINX_CHANGED" = 1 ]; then systemctl restart nginx
else systemctl reload nginx 2>/dev/null || systemctl start nginx; fi
if [ "$ROLE" = relay ]; then
    if [ "$DNSMASQ_CHANGED" = 1 ]; then systemctl restart dnsmasq
    else systemctl start dnsmasq 2>/dev/null || true; fi
    /usr/local/bin/epic-pin || warn "epic-pin failed this run; the timer will retry"
fi

# ---------------------------------------------------------------- verify
step "Checking"
fail=0
check() {
    if [ "$2" = "$3" ]; then printf '    %s.%s %s\n' "$G" "$N" "$1"
    else printf '    %sx%s %s  (got: %s)\n' "$RD" "$N" "$1" "$2"; fail=1; fi
}
check "nginx running" "$(systemctl is-active nginx)" active
if [ "$ROLE" = relay ]; then
    check "dnsmasq running" "$(systemctl is-active dnsmasq)" active
    check "coturn running"  "$(systemctl is-active coturn)"  active
    check "a routed domain resolves to this relay" \
          "$(dig +short +time=3 @127.0.0.1 github.com A 2>/dev/null | tail -1)" "$RELAY_IP"
    check "no IPv6 answers leak around the relay" \
          "$(dig +short +time=3 @127.0.0.1 github.com AAAA 2>/dev/null | grep -c ':' || true)" "0"
    # Two things, not one. A domain we do not route has to answer, and has to
    # answer with somebody else's address. Counting its records was wrong:
    # example.com has more than one, and how many is not ours to assert.
    unrouted="$(dig +short +time=3 @127.0.0.1 example.com A 2>/dev/null)"
    check "an unrouted domain still resolves" \
          "$([ -n "$unrouted" ] && echo yes || echo no)" "yes"
    # example.com is the sentinel because it is stable and nobody needs it
    # bypassed - but an operator can add anything to their own routed list, so
    # a failure here is as likely to mean "you added this on purpose" as it is
    # to mean something is wrong. Say which name it used, so the answer is in
    # the message rather than in a debugging session.
    if [ "$(printf '%s\n' "$unrouted" | grep -c "^${RELAY_IP}$" || true)" != 0 ]; then
        warn "example.com resolves to this relay, so it is being routed."
        warn "That is only a problem if you did not mean it - check with:"
        warn "    grep -rn example.com /etc/dnsmasq.d/"
    fi
    check "an unrouted domain is not pointed at this relay" \
          "$(printf '%s\n' "$unrouted" | grep -c "^${RELAY_IP}$" || true)" "0"
    check "a site loads through the full chain" \
          "$(curl -sS -o /dev/null -m 25 --resolve "github.com:443:${RELAY_IP}" -w '%{http_code}' https://github.com/ 2>/dev/null || echo 000)" "200"
    # The API the relay syncs with, reached the way smartdns-sync reaches it -
    # by address, with a name in the handshake - but with a GET, which the API
    # refuses as 501 without looking at any secret, so this proves the path
    # and leaves no "wrong secret" warning in the exit's log. A relay whose
    # sync could not get through used to pass every check here and then fail
    # in the customer's panel instead.
    check "the exit's sync API answers this relay" \
          "$(curl -sk -o /dev/null -m 20 --resolve "${PANEL_DOMAIN:-sync.example.com}:8443:${EXIT_IP}" -w '%{http_code}' "https://${PANEL_DOMAIN:-sync.example.com}:8443/" 2>/dev/null || true)" "501"
fi
if [ "$TUNNEL" = backpack ]; then
    check "the tunnel service is running" "$(systemctl is-active smartdns-tunnel.service)" active
    if [ "$ROLE" = relay ]; then
        # Straight at the tunnel's own end, so that the fallback in nginx
        # cannot pass this for it. The far end may still be dialling in.
        tun=000
        for i in $(seq 1 20); do
            tun="$(curl -s -o /dev/null -m 8 --connect-to "github.com:443:127.0.0.1:$TUNNEL_LOCAL_HTTPS" \
                   -w '%{http_code}' https://github.com/ 2>/dev/null || true)"
            [ "$tun" = 200 ] && break
            sleep 3
        done
        check "a site loads through the tunnel" "$tun" 200
        [ "$tun" = 200 ] || warn "customers still get through - nginx falls back to the direct path -
    but the tunnel is not carrying them. Is port $TUNNEL_PORT open between the two
    machines? Or try another transport: re-run the installer on the exit."
    fi
fi

printf '\n'
if [ "$fail" = 0 ]; then
    # Written here and nowhere earlier: a run that died half way through has
    # not installed this version, and recording it would tell the next run
    # there was nothing left to do.
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$VERSION" > "$VERSION_FILE"
    printf '%s%s is installed and working, version %s.%s\n' \
           "$G" "$ROLE" "$VERSION" "$N"
else
    printf '%sSomething is off - see the failures above.%s\n' "$Y" "$N"
fi

if [ "$ROLE" = relay ]; then
    printf '
    Point your devices at this address for DNS:

        %s

    Set it as both primary and secondary. A different secondary is worse than
    none: the device will sometimes use it and quietly skip the bypass.

    Manage the list with:  smartdns status | list | add | del | bypass

' "$RELAY_IP"
else
    printf '
    This exit only accepts connections from %s, so it is not an open proxy.
    Run the installer on the relay next, if you have not already.

' "$RELAY_IP"
fi

if [ -n "$ENFORCE_OUT" ]; then
    printf '    %sAccess control is on%s - only addresses registered in the panel get
    DNS, HTTP and HTTPS through this relay. Nobody is registered yet, so right
    now that is nobody: sign a customer up, give them a plan, and let them
    register their address from the customer panel.

    SSH is never gated, and the customer panel is on a port the gate does not
    touch - so a wrong allowlist cannot lock you out of either.

        smartdns-acl list               who is allowed, and what they have used
        smartdns-acl enforce status     which way the door is
        smartdns-acl enforce off        open it to everyone

' "$B" "$N"
fi

if [ -n "$USER_PANEL_OUT" ]; then
    printf '    %sCustomer panel%s - where people sign up, register the address the
    service works on, see what is left of their allowance, and send a payment
    receipt. It also shows them the DNS address to enter.

        %s

' "$B" "$N" "$USER_PANEL_OUT"
fi

if [ "$ROLE" = relay ] && [ -z "${PANEL_DOMAIN:-}" ]; then
    printf '    %sThere is no customer panel on this relay%s, because it has no
    certificate. That page asks for a password, and nothing asks for a
    password over plain http here - so it is not served at all rather than
    served unsafely. Nobody can sign up or register an address until you
    give this machine a domain:

        smartdns-cert panel.example.com

    then put PANEL_DOMAIN in /etc/smart-dns/sync.env and restart
    smartdns-sync.

' "$Y" "$N"
fi

if [ -n "$ADMIN_URL_OUT" ]; then
    printf '    %sAdmin panel%s - shown once. Only a hash of the password is stored,
    so it can be replaced but never read back. Write it down now.

        %s
        password: %s

' "$B" "$N" "$ADMIN_URL_OUT" "$ADMIN_PASS_OUT"
fi

if [ "$TUNNEL" = backpack ]; then
    printf '    %sTunnel%s - %s. The relay'"'"'s nginx goes through it, and
    straight to the exit only while it is down. Its log is in smartdns-logs.

' "$B" "$N" "$TUNNEL_OUT"
fi

if [ -n "$SYNC_TOKEN_OUT" ]; then
    printf '    %sPairing token%s - run the installer on the relay and paste this when
    it asks. It carries both the shared secret and the fingerprint of this
    machine'"'"'s certificate, so the relay will talk to this server and no other.

        %s

' "$B" "$N" "$SYNC_TOKEN_OUT"
fi

# The tunnel was asked again here: the relay has not heard yet, and it will not
# until it is given the token above.
if [ -n "${ASK_TUNNEL:-}" ] && [ "$ROLE" = exit ]; then
    printf '    %sNow the relay%s: run the installer there with --tunnel and paste the\n' "$Y" "$N"
    printf '    pairing token above. Until then it goes straight to this exit.\n\n'
fi

printf '    Every command there is, in one menu:  %ssudo smartdns-menu%s\n\n' "$B" "$N"

exit 0

# ====================================================================
# Config payloads. Everything below is data, never executed.
# ====================================================================

#__BEGIN_SYSCTL__
## /etc/sysctl.d/99-smartdns-tuning.conf
##
## Tuning for a relay whose upstream leg is a 90 ms Iran -> Frankfurt hop.
## The RTT itself cannot be reduced - a traceroute shows one clean hop from the
## Iranian edge to DE-CIX Frankfurt at 89 ms, with 0% loss and 0.4 ms jitter,
## and every other exit region measured from this box is the same or worse
## (UAE 110 ms, Mumbai 203 ms). What is left to win is throughput, which the
## stock settings throttle badly at this bandwidth-delay product.
#
## Congestion control is NOT set here. BBR helps this workload a great deal, but
## it changes how every connection on the machine behaves, including services
## that have nothing to do with this one - so it is asked for rather than
## assumed, and lives in its own file the installer writes only on request.
#
## At 90 ms RTT a socket needs ~11 MB in flight to fill a 1 Gbit/s path. The
## stock 4 MB write buffer caps a single stream well below that.
#net.core.rmem_max = 33554432
#net.core.wmem_max = 33554432
#net.ipv4.tcp_rmem = 4096 131072 33554432
#net.ipv4.tcp_wmem = 4096 65536 33554432
#
## A relay's connections go idle between bursts. Restarting slow start each time
## costs several RTTs - at 90 ms that is very visible on page loads.
#net.ipv4.tcp_slow_start_after_idle = 0
#
## Find the real path MTU instead of stalling on a black-holed ICMP.
#net.ipv4.tcp_mtu_probing = 1
#
## Saves one full RTT on connection setup where both ends support it.
#net.ipv4.tcp_fastopen = 3
#
## Accept queues sized for many short-lived proxied connections.
#net.core.netdev_max_backlog = 16384
#net.core.somaxconn = 8192
#net.ipv4.tcp_max_syn_backlog = 8192
#net.ipv4.tcp_fin_timeout = 15
#net.ipv4.tcp_tw_reuse = 1
#__END_SYSCTL__

#__BEGIN_SYSCTL_BBR__
## /etc/sysctl.d/99-smartdns-bbr.conf
##
## Written only when the operator asks for it, because congestion control is
## machine-wide: it changes every connection on the box, not just this service's.
##
## For this workload it is the single most useful setting there is. The upstream
## leg is a 90 ms Iran -> Frankfurt hop, and the stock algorithm reads loss as
## congestion and backs off - on a long fat pipe that leaves most of the
## capacity unused. BBR paces by measured bandwidth instead, and fq is the
## queueing discipline it expects.
##
## Remove this file and reboot, or re-run the installer and answer no, to go
## back to the kernel default.
#net.core.default_qdisc = fq
#net.ipv4.tcp_congestion_control = bbr
#__END_SYSCTL_BBR__

#__BEGIN_BYPASS__
## /etc/dnsmasq.d/bypass.conf
##
## Names that must NOT be hijacked, even though a parent domain is routed.
## dnsmasq resolves by longest match, so these win over address=/<parent>/...
##
## Two separate reasons a name lands here. Both were found in real packet
## captures, and each cost a broken game before it was understood.
##
## 1. The service is not on TCP 443. The relay listens only on 80 and 443, so
##    pointing such a name at it makes the client fire SYNs into a void and retry
##    forever. EA's game stack is full of these:
##
##      gosredirector.ea.com   TCP 42130 / 42230   game-server redirector
##      blaze.ea.com           TCP 15000-15100     the actual game servers
##      gameservices.ea.com    TCP 10010, 11000    QoS coordinator, match stats
##      tnt-ea.com             TCP 8095            realtime messaging
##
## 2. The service is reachable from Iran anyway, and routing it costs something.
##    ps5.np.playstation.net is the console's STUN server as well as a PSN API
##    host, and it answers fine from an Iranian address - routing it sent NAT
##    detection to our own single-homed coturn instead of Sony's pair, which
##    cannot classify the NAT properly. Only gst.prod.dl.playstation.net actually
##    needs the exit (it does not complete TLS from Iran at all); the rest of
##    prod.dl and the playstation.com API stay routed with it.
##
##      np.playstation.net      ps5.np - STUN + PSN API
##      np.dl.playstation.net   envelope2, uef, gs-sec.ww
##
##    The same reasoning was tried for Epic's backend and reverted - see below -
##    so verify per-name rather than assuming the rule generalises.
##
##    Epic's game backend is the other case, and the important one. Fortnite gets
##    into a match when ol.epicgames.com and friends resolve directly, and does
##    not when they are routed - matchmaking has to come from the same address the
##    console later plays from, or the game server ignores the gameplay packets.
##
##    I reverted this once on the strength of a capture that seemed to disprove
##    it. The capture was confounded: the bypass had left the console on an Epic
##    address that is unreachable from Iran, so the test failed for an unrelated
##    reason. Epic round-robins each name across many addresses and a few are
##    dead from here - one in thirty-three when sampled - which is why Fortnite
##    worked on some attempts and not others. epic-pin handles that by probing
##    each address and pinning only the ones that answer.
##
##      ol.epicgames.com                   account, fortnite, datarouter, fngw
##      ogs.live.on.epicgames.com          habanero, discovery
##      edea.live.use1a.on.epicgames.com   prm-dialogue
##
##    Still routed on purpose: epicgames.com itself (www and store are 403 from
##    Iran), cdn2.unrealengine.com and cdn-0001.qstv.on.epicgames.com.
##
##    core.windows.net is a third kind again: routing it is *demonstrably* broken.
##    A ClientHello for any *.core.windows.net name arrives at the exit with the SNI
##    missing - nginx logged sni="-" and dropped it - while an equally long test
##    hostname and every other domain came through intact. Something on the
##    Iran->exit leg mangles those particular handshakes. The same host answers 400
##    when reached directly from the relay, so direct beats routed here.
##
## Add more with:  smartdns bypass <domain>
#
#server=/gosredirector.ea.com/1.1.1.1
#server=/gosredirector.ea.com/9.9.9.9
#server=/blaze.ea.com/1.1.1.1
#server=/blaze.ea.com/9.9.9.9
#server=/gameservices.ea.com/1.1.1.1
#server=/gameservices.ea.com/9.9.9.9
#server=/tnt-ea.com/1.1.1.1
#server=/tnt-ea.com/9.9.9.9
#server=/np.playstation.net/1.1.1.1
#server=/np.playstation.net/9.9.9.9
#server=/np.dl.playstation.net/1.1.1.1
#server=/np.dl.playstation.net/9.9.9.9
#server=/ol.epicgames.com/1.1.1.1
#server=/ol.epicgames.com/9.9.9.9
#server=/ogs.live.on.epicgames.com/1.1.1.1
#server=/ogs.live.on.epicgames.com/9.9.9.9
#server=/edea.live.use1a.on.epicgames.com/1.1.1.1
#server=/edea.live.use1a.on.epicgames.com/9.9.9.9
#server=/core.windows.net/1.1.1.1
#server=/core.windows.net/9.9.9.9
#__END_BYPASS__

#__BEGIN_NO_AAAA__
## /etc/dnsmasq.d/no-aaaa.conf
##
## The relay and the exit are IPv4-only: nginx proxies over IPv4 and every
## address= record is an IPv4 address. But dnsmasq's address= only answers A
## queries - AAAA is forwarded upstream untouched. A dual-stack client therefore
## asks AAAA, gets the service's real IPv6 address, and connects straight to it,
## walking around the proxy entirely. Every routed domain leaks this way.
##
## The Xbox found it. catalog.gamepass.com answered A with the relay and AAAA with
## real Akamai addresses (2a02:26f0:3500:...), so the console went over IPv6, never
## touched us, and its game library never loaded. Its DNS log showed the giveaway:
##
##   query[AAAA] titlestorage.xboxlive.com  -> forwarded to 1.1.1.1 -> CNAME
##   query[A]    titlestorage.xboxlive.com  -> config is <relay>
##
## Answering NODATA for AAAA makes clients fall back cleanly to IPv4, which is the
## only path this setup can carry. It is global rather than per-domain on purpose:
## any AAAA we hand out is a route around our own proxy, whatever the name.
#filter-AAAA
#__END_NO_AAAA__

#__BEGIN_EXIT_NGINX__
## Smart DNS exit node (abroad) - nginx.conf
## Based on https://github.com/rohammosalli/smart-dns/blob/master/nginx.conf
#worker_processes  auto;
#
## Each proxied stream connection holds two descriptors, client side and
## upstream side, so the effective ceiling is half this number. The default soft
## limit is 1024, which caps the box at ~500 concurrent connections no matter
## what worker_connections says - a PS5 game download opens far more than that in
## parallel and the surplus gets reset mid-transfer.
#worker_rlimit_nofile 65535;
#load_module /usr/lib/nginx/modules/ngx_stream_module.so;
#
#events {
#    worker_connections  15000;
#    multi_accept off;
#}
#
#http {
#    access_log off;
#    resolver 1.1.1.1 ipv6=off;
#    resolver_timeout 5s;
#
#    # Console download CDNs are served over plain HTTP. Both Sony and Microsoft
#    # put theirs on Akamai's HTTP-only network:
#    #
#    #   gst.prod.dl.playstation.net -> ... -> ...edgesuite.net
#    #   assets1.xboxlive.com        -> ... -> ...edgesuite.net
#    #
#    # Those edges answer port 443 with a generic a248.e.akamai.net certificate
#    # that names no console host at all. Redirecting port 80 to https, as this
#    # file used to, therefore sent the console to a certificate it correctly
#    # refused. On the PS5 that was eight TLS alerts and a dead download; on the
#    # Xbox it was a download that never started at all, with the console
#    # re-resolving assets1.xboxlive.com dozens of times a minute.
#    #
#    # Forward these over HTTP instead of redirecting. Scoped to the console
#    # domains deliberately: the relay's port 80 is open to the internet, and a
#    # forward proxy that accepted any Host would be an open proxy.
#    server {
#        listen 80;
#        listen [::]:80;
#        server_name ~^.*\.(playstation\.(net|com)|xboxlive\.com|gamepass\.com)$;
#        allow __RELAY_IP__;
#        # The tunnel, when there is one: its end on this machine hands each
#        # connection to nginx from loopback. Nothing else can arrive from here.
#        allow 127.0.0.1;
#        deny all;
#
#        location / {
#            proxy_pass http://$http_host$request_uri;
#            proxy_set_header Host $http_host;
#            proxy_http_version 1.1;
#            proxy_set_header Connection "";
#            # Game data is large and range-requested; buffering it here would
#            # add latency for no gain.
#            proxy_buffering off;
#            proxy_request_buffering off;
#            proxy_connect_timeout 10s;
#            proxy_send_timeout 10m;
#            proxy_read_timeout 10m;
#
#            # Not every host under these domains actually serves plain HTTP -
#            # packages.xboxlive.com does not, and proxying it produced a 504
#            # where it used to get a clean redirect. Fall back to the old
#            # behaviour when the upstream cannot be reached over HTTP, so this
#            # can only help and never takes something away.
#            proxy_intercept_errors on;
#            error_page 502 504 = @https_redirect;
#        }
#
#        location @https_redirect {
#            return 301 https://$http_host$request_uri;
#        }
#    }
#
#    # Everything else keeps the old behaviour.
#    server {
#        listen 80 default_server;
#        listen [::]:80 default_server;
#        server_name _;
#        return 301 https://$host$request_uri;
#    }
#}
#
#stream {
#    # A TLS client should never send a bare IP as SNI. When one does, blindly
#    # forwarding to $ssl_preread_server_name:443 sends the session straight back
#    # at the relay, which forwards it here again - an infinite loop that pins
#    # both boxes. Blackhole those, and empty SNI, into an unresolvable upstream
#    # so the session is dropped instead.
#    map $ssl_preread_server_name $target {
#        default                 $ssl_preread_server_name;
#        ""                      "";
#        ~^[0-9.]+$              "";
#        ~^\[?[0-9a-fA-F:]+\]?$  "";
#    }
#
#    # Where each name is sent from here. Everything leaves over IPv4, as it
#    # always has. A blackholed $target is still ":443", which nginx cannot
#    # resolve, so those sessions are still dropped rather than looped.
#    map $target $upstream {
#        default  $target:443;
#        # google-v6 begin
#        # Google's own names go to the hop below, which reaches them over IPv6.
#        # Google refuses Gemini, AI Studio, NotebookLM and Labs to some exits'
#        # IPv4 addresses: 403 over IPv4 and the real page over IPv6, from the
#        # same machine a second apart - most likely because it has come to
#        # place that address in a sanctioned country. Only Google's names,
#        # because most of the rest of the list has no IPv6 at all. The
#        # installer leaves this out on an exit without working IPv6.
#        ~(^|\.)(google\.com|googleapis\.com|gstatic\.com|googleusercontent\.com|google|withgoogle\.com|googlevideo\.com|ggpht\.com|gvt1\.com)$  127.0.0.1:8446;
#        # google-v6 end
#    }
#
#    # Only the Iran relay may use this proxy. Prevents open-proxy abuse.
#    server {
#        resolver 1.1.1.1 ipv6=off;
#        listen 443;
#        allow __RELAY_IP__;
#        # The tunnel, when there is one: its end on this machine hands each
#        # connection to nginx from loopback. Nothing else can arrive from here.
#        allow 127.0.0.1;
#        deny all;
#        ssl_preread on;
#        proxy_connect_timeout 10s;
#        proxy_pass $upstream;
#    }
#    # google-v6 begin
#
#    # The IPv6 hop: the same pass-through, asking the resolver for AAAA
#    # records only. On loopback, so nothing outside this machine reaches it;
#    # 8446 is on the list of ports the admin panel may not take.
#    server {
#        listen 127.0.0.1:8446;
#        resolver 1.1.1.1 ipv4=off;
#        ssl_preread on;
#        proxy_connect_timeout 10s;
#        proxy_pass $ssl_preread_server_name:443;
#    }
#    # google-v6 end
#}
#__END_EXIT_NGINX__

#__BEGIN_RELAY_NGINX__
## Smart DNS relay (inside Iran) -> exit node abroad
#worker_processes  auto;
#
## Each proxied stream connection holds two descriptors, client side and
## upstream side, so the effective ceiling is half this number. The default soft
## limit is 1024, which caps the box at ~500 concurrent connections no matter
## what worker_connections says - a PS5 game download opens far more than that in
## parallel and the surplus gets reset mid-transfer.
#worker_rlimit_nofile 65535;
#load_module __MODULE_PATH__;
#
#events {
#    worker_connections  15000;
#    multi_accept off;
#}
#
#stream {
#    # tunnel begin
#    # With a tunnel, its end on this machine is the way to the exit, and the
#    # exit's own address is only the fallback: nginx turns to a backup server
#    # when the first refuses, which is what the tunnel's local port does while
#    # the tunnel is down. Without one, this block is not here at all.
#    upstream to_exit_https {
#        server 127.0.0.1:18443;
#        server __EXIT_IP__:443 backup;
#    }
#    upstream to_exit_http {
#        server 127.0.0.1:18080;
#        server __EXIT_IP__:80 backup;
#    }
#    # tunnel end
#
#    server {
#        listen 443;
#        proxy_connect_timeout 10s;
#        proxy_timeout 10m;
#        proxy_pass __EXIT_HTTPS__;
#    }
#
#    # Port 80 is forwarded rather than answered. It used to return a 301 to
#    # https here, which broke PlayStation downloads: their CDN is HTTP-only and
#    # serves a mismatched certificate on 443, so the console followed our
#    # redirect straight into a TLS failure. The exit decides what to do with
#    # each Host now - proxying playstation traffic, redirecting the rest.
#    server {
#        listen 80;
#        proxy_connect_timeout 10s;
#        proxy_timeout 10m;
#        proxy_pass __EXIT_HTTP__;
#    }
#}
#__END_RELAY_NGINX__

#__BEGIN_TURNSERVER__
## /etc/turnserver.conf  -  STUN only, no TURN relaying
##
## Why this exists: the relay answers *.playstation.net with its own address, and
## ps5.np.playstation.net is the PS5's STUN server. A capture showed the console
## sending eight STUN Binding Requests to the relay and getting nothing back, so
## NAT type detection failed outright - which hurts FUT matchmaking more than any
## amount of ping tuning.
##
## The console sends those Binding Requests over UDP straight to the relay, not
## through the nginx proxy, so the relay genuinely observes the console's real
## public address and can answer correctly. Serving STUN here is the honest fix;
## it keeps PSN's HTTPS traffic on the routed path so sign-in still works.
##
## stun-only is the important line. Without it coturn would also offer TURN
## relaying, and with no-auth that is an open relay for anyone on the internet.
#
#listening-port=3478
#listening-ip=__RELAY_IP__
#external-ip=__RELAY_IP__
#
## Serve STUN Binding only. No allocations, ever.
#stun-only
#no-auth
#
## Nothing here needs TLS, and offering it only widens the surface.
#no-tls
#no-dtls
#no-cli
#
## No alt-listening-port: full RFC 3489 NAT classification needs a second public
## IP for the change-IP test, and this box has one. coturn will not bind the alt
## port on a single-homed host, so setting it just looks configured without being
## so. The console therefore learns its mapping but cannot classify the cone type,
## which lands it on NAT Type 2 (moderate) - the fix here is getting an answer at
## all instead of eight timeouts, and Type 2 plays online fine.
#
#no-multicast-peers
#no-loopback-peers
#fingerprint
#simple-log
#__END_TURNSERVER__

#__BEGIN_SMARTDNS__
##!/bin/bash
## smartdns - manage the sanction-bypass domain list
## usage: smartdns add|del|list|find|test|status [domain ...]
#set -euo pipefail
#
#CONF=/etc/dnsmasq.d/smart-dns.conf
#BYPASS=/etc/dnsmasq.d/bypass.conf
#IP=__RELAY_IP__
#
#need_root() { [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }; }
#
#case "${1:-}" in
#  add)
#    need_root; shift
#    [ $# -gt 0 ] || { echo "usage: smartdns add <domain> [domain ...]"; exit 1; }
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      if grep -qxF "address=/$d/$IP" "$CONF"; then
#        echo "already present: $d"
#      else
#        echo "address=/$d/$IP" >> "$CONF"
#        echo "added: $d"
#      fi
#    done
#    dnsmasq --test -C /etc/dnsmasq.conf && systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  del|rm)
#    need_root; shift
#    [ $# -gt 0 ] || { echo "usage: smartdns del <domain> [domain ...]"; exit 1; }
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      if grep -qxF "address=/$d/$IP" "$CONF"; then
#        sed -i "\#^address=/$d/$IP\$#d" "$CONF"
#        echo "removed: $d"
#      else
#        echo "not found: $d"
#      fi
#    done
#    systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  bypass)
#    # exclude a subdomain from the hijack - for services that do NOT run on 443
#    # (e.g. EA's gosredirector uses TCP 42130/42230, hijacking it kills FC 25)
#    need_root; shift
#    [ $# -gt 0 ] || { echo "usage: smartdns bypass <domain> [domain ...]"; exit 1; }
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      if grep -qxF "server=/$d/1.1.1.1" "$BYPASS"; then
#        echo "already bypassed: $d"
#      else
#        printf 'server=/%s/1.1.1.1
#server=/%s/9.9.9.9
#' "$d" "$d" >> "$BYPASS"
#        echo "bypassed (resolves to its real IP now): $d"
#      fi
#    done
#    dnsmasq --test -C /etc/dnsmasq.conf && systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  unbypass)
#    need_root; shift
#    for d in "$@"; do
#      d=$(echo "$d" | tr 'A-Z' 'a-z' | sed 's#^https\?://##; s#/.*##; s/^\.//')
#      sed -i "\#^server=/$d/#d" "$BYPASS" && echo "un-bypassed: $d"
#    done
#    systemctl restart dnsmasq && echo "dnsmasq reloaded"
#    ;;
#  list)
#    grep '^address=' "$CONF" | sed -E 's#^address=/([^/]+)/.*#\1#' | sort
#    ;;
#  find)
#    shift; grep -i "${1:-}" "$CONF" || echo "no match"
#    ;;
#  test)
#    shift
#    for d in "$@"; do
#      got=$(dig +short +time=5 @127.0.0.1 "$d" A | tr '\n' ' ')
#      if [ "$(echo "$got" | awk '{print $1}')" = "$IP" ]; then
#        printf "%-30s ROUTED   (%s)\n" "$d" "$got"
#      else
#        printf "%-30s direct   (%s)\n" "$d" "$got"
#      fi
#    done
#    ;;
#  status|"")
#    echo "domains routed : $(grep -c '^address=' "$CONF")"
#    echo "bypassed       : $(grep -c '^server=' "$BYPASS" 2>/dev/null || echo 0) rules"
#    echo "dnsmasq        : $(systemctl is-active dnsmasq) / $(systemctl is-enabled dnsmasq)"
#    echo "nginx          : $(systemctl is-active nginx) / $(systemctl is-enabled nginx)"
#    echo "relay target   : $(grep -oE 'proxy_pass [0-9.]+:443' /etc/nginx/nginx.conf | awk '{print $2}')"
#    echo
#    echo "listeners:"
#    ss -tulnp | grep -E ':53 |:80 |:443 ' | awk '{print "  " $1, $5, $NF}'
#    ;;
#  *)
#    echo "usage: smartdns {add|del|bypass|unbypass|list|find|test|status} [domain ...]"
#    exit 1
#    ;;
#esac
#__END_SMARTDNS__

#__BEGIN_NFTABLES__
## Smart DNS relay - access control and per-client traffic accounting.
##
## This file is the structure only: the table, its chains and its empty sets.
## The contents - which addresses are allowed and how much each has used - live
## in 20-smartdns-state.conf, written by `smartdns-acl save`. Keeping them apart
## means the installer can rewrite this file on every upgrade without losing
## anybody's allowance, and means a human can read the policy without wading
## through a few hundred counters.
##
## Nothing here blocks anything. Enforcement is a separate file again,
## 30-smartdns-enforce.conf, which exists only after `smartdns-acl enforce on`.
#
#table inet smartdns {
#    # The allowlist. Managed with `smartdns-acl add|del`, and from stage 2
#    # onwards by the panel's sync service. Each element carries the owner's
#    # name as an nftables comment, so the kernel's own copy is readable
#    # without consulting a database.
#    set allowed {
#        type ipv4_addr
#    }
#
#    # Per-client byte counters, one set per direction, both keyed on the
#    # client address.
#    #
#    # The update rules below match `ip saddr @allowed` first, so these sets
#    # only ever see addresses that are already registered. That is deliberate:
#    # a dynamic set that accepted every source would fill with the port scans
#    # this box gets around the clock, and the size cap would eventually start
#    # dropping real users' entries. Bounded by the customer count instead.
#    set up {
#        type ipv4_addr
#        flags dynamic
#        counter
#    }
#    set down {
#        type ipv4_addr
#        flags dynamic
#        counter
#    }
#
#    # Which shaping class each client belongs to, as a packet mark. Empty
#    # until somebody is given a speed limit; managed by `smartdns-shape`.
#    #
#    # The mark is the customer's account number, and tc has one class per
#    # mark. Marking here rather than matching addresses in tc keeps the
#    # address list in one place - this table - and makes the tc side a fixed
#    # set of rules that only changes when a customer's speed does.
#    map speed {
#        type ipv4_addr : mark
#    }
#
#    # Marks what we are about to send a client, so the queueing discipline on
#    # the way out can put it in that customer's class.
#    #
#    # The output hook, not postrouting: this box is a proxy, not a router, so
#    # every packet a customer receives is generated locally by nginx or
#    # dnsmasq. An address missing from the map is a lookup miss, which ends
#    # this rule and leaves the packet unmarked and unshaped.
#    chain shape {
#        type filter hook output priority mangle ; policy accept ;
#        meta mark set ip daddr map @speed
#    }
#
#    # Enforcement lands here. Empty unless `smartdns-acl enforce on` has been
#    # run. It sits at priority -10, ahead of the counting chains, so blocked
#    # packets are not billed to anyone.
#    chain gate {
#        type filter hook input priority -10 ; policy accept ;
#    }
#
#    # What the client sends us: DNS queries, and the TLS/HTTP requests it
#    # opens against the relay. Filtering on the service ports keeps our own
#    # SSH sessions and the box's housekeeping out of the customer's bill.
#    chain count_in {
#        type filter hook input priority 10 ; policy accept ;
#        ip saddr @allowed udp dport 53 update @up { ip saddr counter }
#        ip saddr @allowed tcp dport { 53, 80, 443 } update @up { ip saddr counter }
#    }
#
#    # What we send back. nginx talks to the exit node as a local process, from
#    # this same hook, but the exit's address is not in @allowed so that traffic
#    # is not counted - otherwise every byte would be billed twice.
#    chain count_out {
#        type filter hook output priority 10 ; policy accept ;
#        ip daddr @allowed udp sport 53 update @down { ip daddr counter }
#        ip daddr @allowed tcp sport { 53, 80, 443 } update @down { ip daddr counter }
#    }
#
#    # Amplification defence, unchanged. An open resolver is worth roughly its
#    # bandwidth to whoever finds it, and this box is easy to find.
#    chain input {
#        type filter hook input priority 0 ; policy accept ;
#        udp dport 53 meter dnsflood { ip saddr limit rate over 40/second burst 80 packets } drop
#    }
#}
#__END_NFTABLES__

#__BEGIN_SMARTDNS_ACL__
##!/bin/bash
## smartdns-acl - who may use this relay, and how much they have used
##
## usage: smartdns-acl add <ip> [name]     register an address
##        smartdns-acl del <ip>            unregister it
##        smartdns-acl list                everyone, with usage
##        smartdns-acl usage <ip>          one address
##        smartdns-acl reset <ip>|--all    zero the counters
##        smartdns-acl enforce on|off|status
##          --yes          do not ask for confirmation
##          --allow-empty  close it with nobody registered (the installer)
##        smartdns-acl save                persist to disk now
##
## Add --json to list or usage for output meant for the panel rather than a
## person. The panel will call this rather than touching nftables itself, so
## that there is one place where the rules about what is legal live.
#set -uo pipefail
#export PATH="$PATH:/usr/sbin:/sbin"
#
#TABLE="inet smartdns"
## Field separator for dump(). Deliberately not a tab: bash counts tabs as IFS
## whitespace, so a row whose name is empty collapses two separators into one
## and every column after it shifts left by one. That turned an unnamed address
## into a name of "0" and a byte count of "", which is how it was found.
#SEP=$'\x1f'
#STATE=/etc/nftables.d/20-smartdns-state.conf
#ENFORCE=/etc/nftables.d/30-smartdns-enforce.conf
## "Close this relay as soon as there is somebody to allow." The installer no
## longer writes it - it closes the relay itself - but relays installed before
## that still carry one, and the sync agent still acts on it, so `enforce off`
## has to keep clearing it. Opening a relay by hand and having a background
## agent shut it again half a minute later would be its own bug.
#AUTO=/etc/smart-dns/auto-enforce
#
#R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
#[ -t 1 ] || { R=; G=; Y=; N=; }
#
#die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
#root() { [ "$(id -u)" = 0 ] || die "run as root"; }
#
#have_table() { nft list table $TABLE >/dev/null 2>&1; }
#
#valid_ip() {
#    local ip="${1:-}" o n=0
#    case "$ip" in ""|*[!0-9.]*|*..*|.*|*.) return 1 ;; esac
#    for o in ${ip//./ }; do
#        [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] || return 1
#        n=$((n + 1))
#    done
#    [ "$n" = 4 ]
#}
#
## Everything that reads the ruleset goes through nft's JSON output and python,
## never through awk on the human-readable format. That format wraps long
## element lists at whatever width it feels like - which is exactly the sort of
## thing that works on a test box with three users and quietly mangles the
## fiftieth.
#dump() {
#    nft -j list table $TABLE 2>/dev/null | python3 -c '
#import json, sys
#
#def elements(doc, name):
#    for item in doc.get("nftables", []):
#        s = item.get("set")
#        if s and s.get("name") == name:
#            return s.get("elem", []) or []
#    return []
#
#def walk(elems):
#    # An element is a bare value until it carries a comment or a counter, at
#    # which point nft wraps it in {"elem": {...}}. Flatten both shapes.
#    out = {}
#    for e in elems:
#        val, comment, byts = e, "", 0
#        if isinstance(e, dict) and "elem" in e:
#            inner = e["elem"]
#            val = inner.get("val", "")
#            comment = inner.get("comment") or ""
#            byts = (inner.get("counter") or {}).get("bytes", 0)
#        if isinstance(val, dict):
#            val = val.get("prefix", {}).get("addr", "")
#        out[str(val)] = (comment, byts)
#    return out
#
#doc = json.load(sys.stdin)
#allowed = walk(elements(doc, "allowed"))
#up      = walk(elements(doc, "up"))
#down    = walk(elements(doc, "down"))
#for ip in sorted(allowed, key=lambda a: [int(p) for p in a.split(".")]):
#    print("%s\x1f%s\x1f%d\x1f%d" % (ip, allowed[ip][0],
#                                    up.get(ip, ("", 0))[1], down.get(ip, ("", 0))[1]))
#'
#}
#
#human() {
#    python3 -c '
#import sys
#n = float(sys.argv[1])
#for unit in ("B", "KB", "MB", "GB", "TB"):
#    if n < 1024 or unit == "TB":
#        print(("%d %s" if unit == "B" else "%.2f %s") % (n, unit))
#        break
#    n /= 1024
#' "$1"
#}
#
#save() {
#    root; have_table || die "the smartdns table is not loaded"
#    mkdir -p /etc/nftables.d
#    local tmp ip name u d
#    tmp="$(mktemp)"
#    {
#        echo "# Written by smartdns-acl. Do not edit by hand - it is"
#        echo "# regenerated from the running ruleset every few minutes."
#        echo "# Registered addresses and their usage as of $(date -Is)."
#        echo
#        while IFS="$SEP" read -r ip name u d; do
#            [ -n "$ip" ] || continue
#            if [ -n "$name" ]; then
#                printf 'add element inet smartdns allowed { %s comment "%s" }\n' "$ip" "$name"
#            else
#                printf 'add element inet smartdns allowed { %s }\n' "$ip"
#            fi
#            # Packet counts are not restored. Only bytes are billed, and
#            # carrying a packet count across a reboot buys nothing.
#            printf 'add element inet smartdns up { %s counter packets 0 bytes %s }\n' "$ip" "$u"
#            printf 'add element inet smartdns down { %s counter packets 0 bytes %s }\n' "$ip" "$d"
#        done < <(dump)
#    } > "$tmp"
#    # The sets already exist, so -c on a file of `add element` really does
#    # validate what we are about to leave behind for the next boot.
#    if nft -c -f "$tmp" >/dev/null 2>&1; then
#        mv "$tmp" "$STATE"; chmod 644 "$STATE"
#    else
#        rm -f "$tmp"; die "the generated state file does not parse - not saving"
#    fi
#}
#
#registered() { dump | cut -d"$SEP" -f1 | grep -qxF "$1"; }
#
#case "${1:-}" in
#
#add)
#    root; shift
#    ip="${1:-}"; name="${2:-}"
#    valid_ip "$ip" || die "not an IPv4 address: ${ip:-<missing>}"
#    have_table || die "the smartdns table is not loaded; run the installer"
#    case "$name" in *'"'*|*'\'*) die "a name cannot contain a quote or a backslash" ;; esac
#    registered "$ip" && die "$ip is already registered"
#    if [ -n "$name" ]; then
#        nft add element $TABLE allowed "{ $ip comment \"$name\" }" || die "nft refused the address"
#    else
#        nft add element $TABLE allowed "{ $ip }" || die "nft refused the address"
#    fi
#    # Seed both counters so the address appears in `list` before it has sent
#    # a single packet. Without this a freshly added user looks like a failure.
#    nft add element $TABLE up   "{ $ip counter packets 0 bytes 0 }" 2>/dev/null
#    nft add element $TABLE down "{ $ip counter packets 0 bytes 0 }" 2>/dev/null
#    save
#    printf '%sadded%s %s%s\n' "$G" "$N" "$ip" "${name:+  ($name)}"
#    ;;
#
#del|rm|remove)
#    root; shift
#    ip="${1:-}"
#    valid_ip "$ip" || die "not an IPv4 address: ${ip:-<missing>}"
#    have_table || die "the smartdns table is not loaded"
#    registered "$ip" || die "$ip is not registered"
#    nft delete element $TABLE allowed "{ $ip }" || die "nft refused the removal"
#    nft delete element $TABLE up   "{ $ip }" 2>/dev/null
#    nft delete element $TABLE down "{ $ip }" 2>/dev/null
#    save
#    printf '%sremoved%s %s\n' "$G" "$N" "$ip"
#    ;;
#
#list|ls)
#    have_table || die "the smartdns table is not loaded"
#    if [ "${2:-}" = --json ]; then
#        dump | python3 -c '
#import json, sys
#rows = []
#for line in sys.stdin:
#    if not line.strip():
#        continue
#    ip, name, u, d = line.rstrip("\n").split("\x1f")
#    rows.append({"ip": ip, "name": name, "up": int(u), "down": int(d),
#                 "total": int(u) + int(d)})
#print(json.dumps(rows))
#'
#        exit 0
#    fi
#    rows="$(dump)"
#    if [ -z "$rows" ]; then
#        echo "no addresses registered yet - add one with: smartdns-acl add <ip> [name]"
#        exit 0
#    fi
#    printf '%-16s %-16s %12s %12s %12s\n' ADDRESS NAME UP DOWN TOTAL
#    while IFS="$SEP" read -r ip name u d; do
#        printf '%-16s %-16s %12s %12s %12s\n' \
#            "$ip" "${name:--}" "$(human "$u")" "$(human "$d")" "$(human $((u + d)))"
#    done <<< "$rows"
#    ;;
#
#usage)
#    have_table || die "the smartdns table is not loaded"
#    ip="${2:-}"
#    valid_ip "$ip" || die "not an IPv4 address: ${ip:-<missing>}"
#    registered "$ip" || die "$ip is not registered"
#    # Field-exact, not a substring: grepping for "1.2.3.4" would also find
#    # the row belonging to 11.2.3.4.
#    IFS="$SEP" read -r _ name u d < <(dump | awk -F"$SEP" -v a="$ip" '$1 == a')
#    if [ "${3:-}" = --json ]; then
#        printf '{"ip":"%s","name":"%s","up":%s,"down":%s,"total":%s}\n' \
#            "$ip" "$name" "$u" "$d" "$((u + d))"
#    else
#        printf '%s%s\n' "$ip" "${name:+  ($name)}"
#        printf '    up    %s\n' "$(human "$u")"
#        printf '    down  %s\n' "$(human "$d")"
#        printf '    total %s\n' "$(human $((u + d)))"
#    fi
#    ;;
#
#reset)
#    root; shift
#    have_table || die "the smartdns table is not loaded"
#    if [ "${1:-}" = --all ]; then
#        targets="$(dump | cut -d"$SEP" -f1)"
#    else
#        valid_ip "${1:-}" || die "usage: smartdns-acl reset <ip>|--all"
#        registered "$1" || die "$1 is not registered"
#        targets="$1"
#    fi
#    for ip in $targets; do
#        for s in up down; do
#            nft delete element $TABLE "$s" "{ $ip }" 2>/dev/null
#            nft add element $TABLE "$s" "{ $ip counter packets 0 bytes 0 }" 2>/dev/null
#        done
#        printf '%sreset%s %s\n' "$G" "$N" "$ip"
#    done
#    save
#    ;;
#
#enforce)
#    have_table || die "the smartdns table is not loaded"
#    case "${2:-status}" in
#    on)
#        root
#        count="$(dump | grep -c . )"
#        yes=no; empty=no
#        for flag in "$@"; do
#            case "$flag" in
#                --yes) yes=yes ;;
#                --allow-empty) empty=yes ;;
#            esac
#        done
#        # Switching this on with an empty allowlist cuts off every user of the
#        # service at once. For somebody typing it at a terminal that is almost
#        # always a mistake, and one that feels irreversible from the far end of
#        # a broken connection - so it refuses.
#        #
#        # The installer passes --allow-empty, because there it is not a
#        # mistake: a relay being installed has no users to cut off, and the
#        # list being empty is exactly why it has to be closed. Left open, it is
#        # a relay anybody who learns its address can use for free.
#        if [ "$count" -eq 0 ] && [ "$empty" != yes ]; then
#            die "the allowlist is empty - everyone would be cut off.
#    Register at least your own address first:  smartdns-acl add <your ip> me"
#        fi
#        if [ "$yes" != yes ] && [ -t 0 ]; then
#            printf '%s%s address(es) registered.%s Everyone else loses DNS, HTTP\n' "$Y" "$count" "$N"
#            printf 'and HTTPS through this relay immediately. SSH is not affected.\n'
#            printf 'Continue? [y/N] '
#            read -r ans
#            case "$ans" in y|Y|yes) ;; *) echo "cancelled"; exit 1 ;; esac
#        fi
#        mkdir -p /etc/nftables.d
#        cat > "$ENFORCE" <<'RULES'
## Access control, switched on by `smartdns-acl enforce on`.
## Delete this file, or run `smartdns-acl enforce off`, to open the relay again.
## There is deliberately no rule for SSH: getting the allowlist wrong must never
## cost you access to the machine.
#
## The machine talks to its own resolver: epic-pin probes it every ten minutes,
## and the installer's checks query it directly. Neither is a customer and
## neither is in the allowlist, so without this line switching enforcement on
## would quietly break both.
#add rule inet smartdns gate iif "lo" accept
#
#add rule inet smartdns gate ip saddr != @allowed udp dport 53 drop
#add rule inet smartdns gate ip saddr != @allowed tcp dport { 53, 80, 443 } drop
#RULES
#        nft flush chain $TABLE gate
#        nft -f "$ENFORCE" || { rm -f "$ENFORCE"; die "nft refused the rules; nothing changed"; }
#        if [ "$count" -eq 0 ]; then
#            printf '%senforcing%s - nobody may use this relay yet.\n' "$G" "$N"
#            printf 'Addresses are let in as customers register them.\n'
#        else
#            printf '%senforcing%s - %s address(es) may use this relay\n' \
#                   "$G" "$N" "$count"
#        fi
#        ;;
#    off)
#        root
#        nft flush chain $TABLE gate
#        rm -f "$ENFORCE"
#        # Also cancel the installer's standing instruction to close the relay
#        # once somebody registers. Opening it by hand and having a background
#        # agent shut it again half a minute later would be its own bug.
#        if [ -f "$AUTO" ]; then
#            rm -f "$AUTO"
#            printf 'automatic enforcement cancelled too\n'
#        fi
#        printf '%sopen%s - nothing is being blocked\n' "$Y" "$N"
#        ;;
#    status)
#        if nft list chain $TABLE gate 2>/dev/null | grep -q drop; then
#            printf 'enforcing - %s address(es) allowed\n' "$(dump | grep -c .)"
#        else
#            printf 'open - counting only, nothing is blocked\n'
#        fi
#        ;;
#    *) die "usage: smartdns-acl enforce on|off|status" ;;
#    esac
#    ;;
#
#save)
#    save; echo "saved to $STATE"
#    ;;
#
#*)
#    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
#    exit 1
#    ;;
#esac
#__END_SMARTDNS_ACL__

#__BEGIN_SMARTDNS_SHAPE__
##!/usr/bin/env python3
#"""smartdns-shape - per-customer download speed limits on the relay.
#
#usage: smartdns-shape apply      read the wanted state as JSON on stdin
#       smartdns-shape list       show what is in force
#       smartdns-shape off        remove all shaping, leaving traffic alone
#
#The wanted state is a list of {"ip", "mark", "kbps"}. kbps is kilobits per
#second; a customer with no limit is simply absent from it.
#
#Why this shape and not another
#------------------------------
#Only the download direction is shaped - what the relay sends to the customer.
#That is the direction a customer notices, and on this box it is also the easy
#one: the relay is a proxy rather than a router, so every packet a customer
#receives is generated locally and leaves through one interface, where a
#queueing discipline can see it. Shaping the upload direction would mean
#policing on ingress through an ifb device, which drops rather than queues and
#buys very little for a service whose traffic is overwhelmingly inbound.
#
#htb, not a rate limit in nftables. nftables can drop above a rate, and drops
#are not shaping: TCP reacts to loss by collapsing its window, so a customer
#capped that way gets a connection that stalls and lurches rather than one that
#runs steadily a little slower. htb queues instead, and hands each class to
#fq_codel so a customer's own bulk download cannot drown out their own game.
#
#The address list stays in nftables, not here. nftables marks each packet with
#the customer's account number and tc matches the mark, so the tc side is a
#fixed set of rules that changes only when somebody's speed changes - and the
#question "which addresses does this box know about" keeps exactly one answer.
#"""
#import json
#import re
#import subprocess
#import sys
#
## Root class: the ceiling every customer class hangs under. Deliberately far
## above any real link speed, because it is not a limit - it is the parent htb
## needs, and setting it near the true line rate would cap customers who have
## no limit of their own.
#ROOT_RATE = "10gbit"
#
## Where unmarked traffic goes: everything that is not a shaped customer,
## including our own ssh session and the sync agent. Unshaped on purpose.
#DEFAULT_MINOR = 0xFFFF
#
## Customer classes live above this, never at it. The mark identifies the
## customer everywhere else - in the nftables map and as the fw filter's handle
## - but it cannot be the class minor as well, because minor 1 is the root
## class every customer class hangs under and 1: is the root qdisc's own
## handle. The first customer ever shaped has mark 1, so both collided at once:
## `tc qdisc replace ... parent 1:1 handle 1: fq_codel` was refused every
## thirty seconds, and the class that did get created replaced the root class,
## quietly capping the whole relay at that one customer's speed.
#CLASS_BASE = 0x100
#
## Marks are account numbers, and this one is taken by the default class.
#MAX_MARK = DEFAULT_MINOR - CLASS_BASE - 1
#
#TABLE = "inet smartdns"
#MAP = "speed"
#
#R = "\033[31m"; G = "\033[32m"; Y = "\033[33m"; N = "\033[0m"
#if not sys.stdout.isatty():
#    R = G = Y = N = ""
#
#
#def die(msg):
#    sys.stderr.write("%serror:%s %s\n" % (R, N, msg))
#    raise SystemExit(1)
#
#
#def run(*args, **kw):
#    return subprocess.run(list(args), capture_output=True, text=True,
#                          timeout=kw.get("timeout", 30))
#
#
#def tc(*args, check=True):
#    r = run("tc", *args)
#    if check and r.returncode != 0:
#        die("tc %s: %s" % (" ".join(args), r.stderr.strip()))
#    return r
#
#
#def nft(*args, check=True):
#    r = run("nft", *args)
#    if check and r.returncode != 0:
#        die("nft %s: %s" % (" ".join(args), r.stderr.strip()))
#    return r
#
#
#def wan():
#    """The interface customer traffic leaves by - the default route's."""
#    r = run("ip", "-o", "route", "get", "1.1.1.1")
#    if r.returncode != 0:
#        die("cannot work out which interface to shape: %s" % r.stderr.strip())
#    fields = r.stdout.split()
#    if "dev" not in fields:
#        die("no device in: %s" % r.stdout.strip())
#    return fields[fields.index("dev") + 1]
#
#
## ------------------------------------------------------------------- state
#RATE_RE = re.compile(r"\brate\s+(\d+(?:\.\d+)?)([KMGT]?)bit", re.I)
#CLASS_RE = re.compile(r"^class\s+htb\s+1:([0-9a-f]+)\b", re.I)
#SCALE = {"": 0.001, "K": 1, "M": 1000, "G": 1000000, "T": 1000000000}
#
#
#def current_classes(dev):
#    """{minor: rate in kbit} for the customer classes that exist now.
#
#    Two output formats, because `tc -j` is not honoured everywhere: iproute2
#    6.1 emits JSON for `qdisc show` but silently prints the plain text format
#    for `class show`, which json.loads then chokes on. Rather than pin a
#    version, read whichever came back - the text format has been stable for
#    twenty years and is trivial to parse.
#    """
#    r = tc("-j", "class", "show", "dev", dev, check=False)
#    if r.returncode != 0 or not r.stdout.strip():
#        return {}
#    out = {}
#    text = r.stdout.lstrip()
#    if text.startswith("["):
#        for c in json.loads(text):
#            handle = c.get("handle", "")
#            major, _, minor = handle.partition(":")
#            if major != "1" or not minor:
#                continue
#            m = int(minor, 16)
#            if m > CLASS_BASE and m != DEFAULT_MINOR:
#                # Keyed by mark, so the caller compares like with like.
#                out[m - CLASS_BASE] = int(c.get("rate", 0)) // 1000
#        return out
#    for line in text.splitlines():
#        hit = CLASS_RE.match(line.strip())
#        if not hit:
#            continue
#        m = int(hit.group(1), 16)
#        if m <= CLASS_BASE or m == DEFAULT_MINOR:
#            continue
#        rate = RATE_RE.search(line)
#        out[m - CLASS_BASE] = (int(float(rate.group(1)) * SCALE[rate.group(2).upper()])
#                               if rate else 0)
#    return out
#
#
#def ensure_root(dev):
#    """Put the htb root in place if it is not there already.
#
#    Replacing it when it already exists would throw away every customer class
#    on a run that was meant to change one of them, so this checks first.
#    """
#    r = tc("-j", "qdisc", "show", "dev", dev, check=False)
#    have_htb = False
#    if r.returncode == 0 and r.stdout.strip():
#        have_htb = any(q.get("kind") == "htb" and q.get("handle") == "1:"
#                       for q in json.loads(r.stdout))
#    if have_htb:
#        return False
#    tc("qdisc", "replace", "dev", dev, "root", "handle", "1:",
#       "htb", "default", format(DEFAULT_MINOR, "x"))
#    tc("class", "replace", "dev", dev, "parent", "1:", "classid", "1:1",
#       "htb", "rate", ROOT_RATE, "ceil", ROOT_RATE)
#    tc("class", "replace", "dev", dev, "parent", "1:1",
#       "classid", "1:%x" % DEFAULT_MINOR,
#       "htb", "rate", ROOT_RATE, "ceil", ROOT_RATE)
#    tc("qdisc", "replace", "dev", dev, "parent", "1:%x" % DEFAULT_MINOR,
#       "handle", "%x:" % DEFAULT_MINOR, "fq_codel")
#    return True
#
#
#def minor_for(mark):
#    """The class minor a mark gets. Never 1, never DEFAULT_MINOR."""
#    return CLASS_BASE + mark
#
#
#def add_class(dev, mark, kbps):
#    rate = "%dkbit" % kbps
#    minor = minor_for(mark)
#    tc("class", "replace", "dev", dev, "parent", "1:1",
#       "classid", "1:%x" % minor, "htb", "rate", rate, "ceil", rate,
#       # A burst of roughly a tenth of a second, so a limit reads as a steady
#       # speed rather than as a stutter, without letting a customer bank
#       # seconds of idle time into a spike the operator pays for.
#       "burst", "%dkbit" % max(15, kbps // 10))
#    tc("qdisc", "replace", "dev", dev, "parent", "1:%x" % minor,
#       "handle", "%x:" % minor, "fq_codel")
#    # The filter is keyed on the mark, so re-adding an identical one would
#    # stack duplicates. Delete first, ignore the failure when there is none.
#    tc("filter", "del", "dev", dev, "parent", "1:", "protocol", "ip",
#       "prio", "1", "handle", str(mark), "fw", check=False)
#    tc("filter", "add", "dev", dev, "parent", "1:", "protocol", "ip",
#       "prio", "1", "handle", str(mark), "fw", "flowid", "1:%x" % minor)
#
#
#def drop_class(dev, mark):
#    minor = minor_for(mark)
#    tc("filter", "del", "dev", dev, "parent", "1:", "protocol", "ip",
#       "prio", "1", "handle", str(mark), "fw", check=False)
#    tc("qdisc", "del", "dev", dev, "parent", "1:%x" % minor, check=False)
#    tc("class", "del", "dev", dev, "parent", "1:1",
#       "classid", "1:%x" % minor, check=False)
#
#
#def set_map(wanted):
#    """Replace the address-to-mark map in one step.
#
#    Flush and refill rather than working out the difference: the map is at
#    most a few hundred entries, and a customer must never be briefly missing
#    from it because their speed changed.
#    """
#    nft("flush", "map", *TABLE.split(), MAP)
#    if not wanted:
#        return
#    elements = ", ".join("%s : %d" % (w["ip"], w["mark"]) for w in wanted)
#    nft("add", "element", *TABLE.split(), MAP, "{ %s }" % elements)
#
#
## ------------------------------------------------------------------ verbs
#def apply_wanted(wanted):
#    dev = wan()
#    seen = set()
#    clean = []
#    for w in wanted:
#        try:
#            mark, kbps = int(w["mark"]), int(w["kbps"])
#        except (KeyError, TypeError, ValueError):
#            die("bad entry: %r" % (w,))
#        if not 1 <= mark <= MAX_MARK:
#            die("mark %d is outside 1..%d" % (mark, MAX_MARK))
#        if mark in seen:
#            die("mark %d appears twice" % mark)
#        if kbps <= 0:
#            continue                     # no limit means no class
#        seen.add(mark)
#        clean.append({"ip": w["ip"], "mark": mark, "kbps": kbps})
#
#    if not clean:
#        # Nobody is limited, so leave the interface as the kernel set it up.
#        # htb replaces the multi-queue root, which costs a little throughput on
#        # a busy relay - not much, but not worth paying to shape nobody.
#        return teardown(dev, "no speed limits set")
#
#    built = ensure_root(dev)
#    have = current_classes(dev)
#    want = {w["mark"]: w["kbps"] for w in clean}
#
#    added = changed = removed = 0
#    for mark, kbps in sorted(want.items()):
#        if mark not in have:
#            added += 1
#        elif have[mark] != kbps:
#            changed += 1
#        else:
#            continue
#        add_class(dev, mark, kbps)
#    for mark in sorted(set(have) - set(want)):
#        drop_class(dev, mark)
#        removed += 1
#
#    set_map(clean)
#    if built or added or changed or removed:
#        print("shaping on %s: %d limited (+%d ~%d -%d)%s"
#              % (dev, len(clean), added, changed, removed,
#                 " [root created]" if built else ""))
#    return 0
#
#
#def show():
#    dev = wan()
#    have = current_classes(dev)
#    r = nft("-j", "list", "map", *TABLE.split(), MAP, check=False)
#    by_mark = {}
#    if r.returncode == 0 and r.stdout.strip():
#        for item in json.loads(r.stdout).get("nftables", []):
#            for e in (item.get("map", {}).get("elem") or []):
#                if isinstance(e, list) and len(e) == 2:
#                    by_mark[int(e[1])] = e[0]
#    if not have:
#        print("no speed limits in force on %s" % dev)
#        return 0
#    print("%-16s %-8s %s" % ("ADDRESS", "MARK", "LIMIT"))
#    for mark in sorted(have):
#        kbps = have[mark]
#        speed = ("%.1f Mbit/s" % (kbps / 1000.0)) if kbps >= 1000 \
#            else "%d kbit/s" % kbps
#        print("%-16s %-8d %s" % (by_mark.get(mark, "?"), mark, speed))
#    return 0
#
#
#def teardown(dev, why):
#    """Put the interface back the way the kernel had it.
#
#    Only says anything when there was something to remove, so the sync agent
#    calling this on a relay that has never shaped anybody stays quiet.
#    """
#    had = current_classes(dev)
#    for mark in had:
#        drop_class(dev, mark)
#    if had:
#        tc("qdisc", "del", "dev", dev, "root", check=False)
#    nft("flush", "map", *TABLE.split(), MAP, check=False)
#    if had:
#        print("%s on %s: %d class(es) removed" % (why, dev, len(had)))
#    return 0
#
#
#def off():
#    dev = wan()
#    teardown(dev, "shaping removed")
#    # Unconditionally here, unlike the reconciling path: `off` is a person
#    # asking for the root to go, whether or not any class is left.
#    tc("qdisc", "del", "dev", dev, "root", check=False)
#    print("shaping off on %s" % dev)
#    return 0
#
#
#def main():
#    verb = sys.argv[1] if len(sys.argv) > 1 else ""
#    if verb == "apply":
#        try:
#            wanted = json.loads(sys.stdin.read() or "[]")
#        except ValueError as e:
#            die("stdin is not valid json: %s" % e)
#        if not isinstance(wanted, list):
#            die("expected a list of {ip, mark, kbps}")
#        return apply_wanted(wanted)
#    if verb == "list":
#        return show()
#    if verb == "off":
#        return off()
#    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
#    return 1
#
#
#if __name__ == "__main__":
#    raise SystemExit(main())
#__END_SMARTDNS_SHAPE__

#__BEGIN_ACL_SAVE_SERVICE__
#[Unit]
#Description=Persist smart DNS allowlist and traffic counters
#After=nftables.service
#
#[Service]
## A plain oneshot on purpose. With RemainAfterExit=yes the unit would stay
## active after its first run and every later trigger from the timer would be
## silently skipped - the counters would then be written exactly once, at boot.
#Type=oneshot
#ExecStart=/usr/local/bin/smartdns-acl save
#__END_ACL_SAVE_SERVICE__

#__BEGIN_ACL_SAVE_TIMER__
#[Unit]
#Description=Persist smart DNS counters every few minutes
#
#[Timer]
## Counters live in the kernel. An unclean shutdown loses whatever has not
## been written out, so the window is kept short enough that nobody can burn
## a meaningful amount of quota inside it.
#OnBootSec=3min
#OnUnitActiveSec=5min
#
#[Install]
#WantedBy=timers.target
#__END_ACL_SAVE_TIMER__

#__BEGIN_PANEL__
##!/usr/bin/env python3
#"""smartdns-panel - the database behind the relays, and the API they sync to.
#
#This runs on the exit node, not on the relay. The relay connects out to this
#API every half minute to hand over per-address usage and collect the list of
#addresses it should allow, which resolver each is on, and what speed each is
#capped at. The relay always initiates: it is the machine in the harder network
#position, and this way it needs no new inbound port.
#
#One database serves every relay. That is what makes a customer's allowance
#mean one thing across the whole service rather than one thing per machine.
#
#There was a Telegram bot in this process. It is gone: almost every account was
#opened on the web panel and had no Telegram behind it, so the bot's commands
#had all grown web equivalents and its messages were reaching a shrinking
#minority. What it did for customers - registering an address, seeing an
#account, being warned before the allowance runs out - the panel on each relay
#now does for everybody.
#
#Only the standard library is used, so the installer stays a single file with
#no pip step.
#"""
#
#import base64
#import hashlib
#import hmac
#import html
#import http.server
#import json
#import os
#import re
#import secrets
#import signal
#import shutil
#import sqlite3
#import ssl
#import sys
#import threading
#import time
#import traceback
#import unicodedata
#import urllib.error
#import urllib.parse
#import urllib.request
#from datetime import datetime, timedelta, timezone
#
#CONFIG = "/etc/smart-dns/panel.env"
#DB = "/var/lib/smart-dns/panel.db"
#CERT = "/etc/smart-dns/sync.crt"
#KEY = "/etc/smart-dns/sync.key"
#API_PORT = 8443
#
#SCHEMA = """
#CREATE TABLE IF NOT EXISTS users (
#    id             INTEGER PRIMARY KEY,
#    -- Null for an account opened on the web panel. Telegram is one way in, not
#    -- the only one. UNIQUE still holds where it matters: sqlite allows many
#    -- nulls in a unique column, which is the behaviour wanted here.
#    telegram_id    INTEGER UNIQUE,
#    -- How a web account signs in. Nothing verifies it - there is no SMS
#    -- gateway - so it names an account and lets a card receipt be matched to
#    -- one. It is not evidence about who holds the line.
#    phone          TEXT UNIQUE,
#    password_hash  TEXT,
#    password_salt  TEXT,
#    username       TEXT,
#    first_name     TEXT,
#    created_at     TEXT NOT NULL,
#    status         TEXT NOT NULL DEFAULT 'active',
#    -- 0 means unlimited. Quota is counted in bytes, on the wire, both
#    -- directions, which is what the kernel counters actually measure.
#    quota_bytes    INTEGER NOT NULL DEFAULT 0,
#    quota_mode     TEXT NOT NULL DEFAULT 'monthly',
#    quota_reset_at TEXT,
#    used_bytes     INTEGER NOT NULL DEFAULT 0,
#    max_ips        INTEGER NOT NULL DEFAULT 1,
#    wallet         INTEGER NOT NULL DEFAULT 0,
#    -- Download limit in kilobits per second, 0 for no limit. The relay turns
#    -- this into one htb class per customer; the number lives here because the
#    -- relay must be able to be rebuilt from nothing but a sync.
#    speed_kbps     INTEGER NOT NULL DEFAULT 0,
#    -- When this account stops working regardless of how much is left. Set for
#    -- the trial; null for a paid account, which ends when its quota does.
#    expires_at     TEXT
#);
#
#-- One row per registered address. UNIQUE(ip) is deliberate: without it a
#-- second account could register an address someone else is already paying
#-- for and ride along free.
#CREATE TABLE IF NOT EXISTS ips (
#    id           INTEGER PRIMARY KEY,
#    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
#    ip           TEXT NOT NULL UNIQUE,
#    added_at     TEXT NOT NULL,
#    -- The last raw counter this address reported. Usage is the growth of that
#    -- number, so a user who changes address keeps the total they had built up.
#    last_counter INTEGER NOT NULL DEFAULT 0
#);
#
#-- A customer's claim that they paid, and the photograph of the slip.
#--
#-- The image is a blob rather than a file beside the database, so that one
#-- backup is the whole story and a restore brings the pending ones back with
#-- everything else. It does not grow without bound: the image is dropped the
#-- moment the operator decides, leaving the row as the record.
#CREATE TABLE IF NOT EXISTS transactions (
#    id           INTEGER PRIMARY KEY,
#    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
#    amount       INTEGER NOT NULL,
#    kind         TEXT NOT NULL,
#    receipt      TEXT,
#    receipt_blob BLOB,
#    receipt_type TEXT,
#    note         TEXT,
#    status       TEXT NOT NULL DEFAULT 'pending',
#    created_at   TEXT NOT NULL,
#    decided_at   TEXT
#);
#
#-- The operator's own browser sessions for the admin panel. In the database
#-- rather than in that process's memory, because it restarts on every upgrade
#-- and whenever its port or path changes - and being signed out by a restart
#-- left the operator staring at the same bare 404 a stranger gets.
#CREATE TABLE IF NOT EXISTS admin_sessions (
#    token      TEXT PRIMARY KEY,
#    expires_at TEXT NOT NULL
#);
#
#CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
#CREATE INDEX IF NOT EXISTS ips_user ON ips(user_id);
#
#-- A template is a named set of service groups that route through the relay.
#-- Customers are assigned one; they do not get an arbitrary per-customer
#-- combination, because each distinct combination costs a dnsmasq instance on
#-- every relay and the count has to stay small enough to run. Templates make
#-- that limit a product decision - how many plans do you sell - rather than an
#-- accident waiting to happen.
#CREATE TABLE IF NOT EXISTS templates (
#    id         INTEGER PRIMARY KEY,
#    name       TEXT UNIQUE NOT NULL,
#    is_default INTEGER NOT NULL DEFAULT 0,
#    created_at TEXT NOT NULL
#);
#
#-- One row per group the template routes. A group absent from here is bypassed
#-- for that template: resolved to its real address so the client reaches it
#-- directly, costing the operator nothing and the customer some speed.
#CREATE TABLE IF NOT EXISTS template_services (
#    template_id INTEGER NOT NULL REFERENCES templates(id) ON DELETE CASCADE,
#    service_key TEXT NOT NULL,
#    group_key   TEXT NOT NULL,
#    PRIMARY KEY (template_id, service_key, group_key)
#);
#
#-- Single domains switched off inside a group the template otherwise routes.
#--
#-- Recorded as exceptions rather than as the full list of what is routed, so
#-- that a group means "everything in this group" and keeps meaning it when the
#-- catalogue grows. A domain added to Spotify next month starts routing for
#-- every template that routes Spotify - which is what an operator who ticked
#-- Spotify asked for - while the handful they deliberately switched off stay
#-- off. No domain is in two groups, so the domain alone identifies the row.
#CREATE TABLE IF NOT EXISTS template_domains_off (
#    template_id INTEGER NOT NULL REFERENCES templates(id) ON DELETE CASCADE,
#    domain      TEXT NOT NULL,
#    PRIMARY KEY (template_id, domain)
#);
#
#-- Browser sessions for the user panel. The relay serves the pages but keeps
#-- no state: it holds the cookie and asks here who it belongs to, so a relay
#-- being rebuilt does not log everybody out, and a second relay serves the same
#-- session without anything being shared between them.
#CREATE TABLE IF NOT EXISTS panel_sessions (
#    token      TEXT PRIMARY KEY,
#    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
#    created_at TEXT NOT NULL,
#    expires_at TEXT NOT NULL
#);
#
#-- Where each address's counter stood at the last sync, per relay.
#--
#-- Per relay, not per address. Every relay reports its own counter for the same
#-- customer, and one shared figure makes them overwrite each other: the relay
#-- reporting the smaller number looks like a counter reset, the next relay's
#-- larger number then looks like fresh traffic, and the same bytes are charged
#-- again every cycle. Two relays turned 52 GB of real usage into 12.6 TB in a
#-- day. Invisible with a single relay, which is why it survived until there
#-- were two.
#CREATE TABLE IF NOT EXISTS ip_counters (
#    ip           TEXT NOT NULL,
#    relay        TEXT NOT NULL,
#    last_counter INTEGER NOT NULL DEFAULT 0,
#    PRIMARY KEY (ip, relay)
#);
#
#-- Domains the operator added themselves, on top of the list that ships with
#-- the installer. Kept here rather than edited on each relay so that one entry
#-- reaches every relay, and survives a relay being rebuilt from scratch.
#CREATE TABLE IF NOT EXISTS custom_domains (
#    domain   TEXT PRIMARY KEY,
#    note     TEXT,
#    added_at TEXT NOT NULL
#);
#
#-- Host health, one row per sample per machine. Written every thirty seconds
#-- by whatever reports it, and pruned to a day, which at that rate is a few
#-- thousand rows per host - small enough to keep in the same database rather
#-- than standing up something separate to hold it.
#CREATE TABLE IF NOT EXISTS metrics (
#    id         INTEGER PRIMARY KEY,
#    host       TEXT NOT NULL,
#    at         TEXT NOT NULL,
#    cpu        REAL,
#    load       REAL,
#    mem_used   INTEGER,
#    mem_total  INTEGER,
#    swap_used  INTEGER,
#    swap_total INTEGER,
#    disk_used  INTEGER,
#    disk_total INTEGER,
#    rx_bps     INTEGER,
#    tx_bps     INTEGER,
#    uptime     INTEGER
#);
#CREATE INDEX IF NOT EXISTS metrics_host_at ON metrics(host, at);
#"""
#
#METRIC_FIELDS = ("cpu", "load", "mem_used", "mem_total", "swap_used",
#                 "swap_total", "disk_used", "disk_total", "rx_bps", "tx_bps",
#                 "uptime")
#
## How long health samples are kept. A day is enough to answer "was it the
## server?" about something that happened this morning, and short enough that
## the table never becomes the largest thing in the database.
#METRICS_KEEP_HOURS = 24
#
## Columns added after the first release. sqlite has no ADD COLUMN IF NOT
## EXISTS, so these are applied only when the column is genuinely missing.
#MIGRATIONS = [
#    # Which warning thresholds this user has already been told about, so a
#    # sync every thirty seconds does not send the same warning a hundred times.
#    ("users", "warned", "INTEGER NOT NULL DEFAULT 0"),
#    # Null means the default template, so existing accounts keep working
#    # unchanged when this arrives.
#    ("users", "template_id", "INTEGER REFERENCES templates(id)"),
#    # Web signup. Added by ALTER on databases that predate it; the UNIQUE on
#    # phone lives in the index below, because ADD COLUMN cannot carry one.
#    ("users", "phone", "TEXT"),
#    ("users", "password_hash", "TEXT"),
#    ("users", "password_salt", "TEXT"),
#    # Download limit in kilobits per second; 0 means no limit, which is what
#    # every account that predates this gets.
#    ("users", "speed_kbps", "INTEGER NOT NULL DEFAULT 0"),
#    ("users", "expires_at", "TEXT"),
#    # Set when the operator hands out a temporary password: until the
#    # customer has chosen their own, that is all their account lets them do.
#    ("users", "must_change_password", "INTEGER NOT NULL DEFAULT 0"),
#    ("transactions", "receipt_blob", "BLOB"),
#    ("transactions", "receipt_type", "TEXT"),
#    ("transactions", "note", "TEXT"),
#]
#
## Indexes that have to exist whether the table was created by SCHEMA or grown
## by MIGRATIONS. A unique index and a UNIQUE column constraint are the same
## thing to sqlite, so this makes both paths end up identical.
#INDEXES = [
#    "CREATE UNIQUE INDEX IF NOT EXISTS users_phone ON users(phone)",
#    # What a customer signs in with. The column predates this - it held the
#    # Telegram handle - and sqlite cannot add UNIQUE to a column that is
#    # already there, so the constraint arrives as an index instead. Nulls do
#    # not collide in a unique index, which is what accounts that never had one
#    # need.
#    "CREATE UNIQUE INDEX IF NOT EXISTS users_username ON users(username)",
#]
#
## Where the installer puts the service catalogue - which brands exist, which
## groups each has, and which domains are in each group.
#SERVICES_FILE = "/usr/local/share/smart-dns/services.json"
#
## Ceiling on distinct templates actually in use. Each one is a dnsmasq
## instance on every relay, with its own cache and its own port, so this is a
## real resource limit rather than a preference. Eight plans is more than any
## of this is likely to need; the panel refuses to exceed it rather than
## quietly starting a ninth resolver on every machine.
#MAX_TEMPLATES = 8
#
#MB = 1024 ** 2
#GB = 1024 ** 3
#
## A photograph of a bank slip. Generous for a phone camera, small enough that
## a few pending ones cannot bloat the database or a backup.
#MAX_RECEIPT = 4 * MB
#
## What the service is called and what a new account gets. Kept in the database
## rather than in this file, so changing either is an edit in the admin panel
## rather than a redeploy to every machine.
#DEFAULT_SETTINGS = {
#    # No trial. A new account gets nothing until an operator gives it
#    # something - see create_web_user.
#    "plan_bytes": str(2 * GB),
#    "plan_days": "30",
#}
#
## Fractions of the quota at which the user is warned, and the bit each one
## sets in users.warned.
#THRESHOLDS = [(0.80, 1), (0.95, 2)]
#
#IPV4 = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
#
#
#class Throttle:
#    """Counts recent attempts per key, in memory.
#
#    The panel is one process, so a dict is the whole implementation. Losing the
#    counts on restart is acceptable: this exists to make guessing slow, and a
#    restart is not something an attacker can cause.
#    """
#
#    def __init__(self):
#        self.lock = threading.Lock()
#        self.hits = {}
#
#    def _prune(self, key, window):
#        cutoff = time.time() - window
#        kept = [t for t in self.hits.get(key, []) if t > cutoff]
#        if kept:
#            self.hits[key] = kept
#        else:
#            self.hits.pop(key, None)
#        return kept
#
#    def check(self, key, limit, window):
#        """(allowed, seconds until the oldest attempt falls out of the window)"""
#        with self.lock:
#            kept = self._prune(key, window)
#            if len(kept) < limit:
#                return True, 0
#            return False, int(window - (time.time() - kept[0])) + 1
#
#    def hit(self, key):
#        with self.lock:
#            self.hits.setdefault(key, []).append(time.time())
#
#    def clear(self, key):
#        with self.lock:
#            self.hits.pop(key, None)
#
#
#THROTTLE = Throttle()
#
#
#def now():
#    return datetime.now(timezone.utc).isoformat(timespec="seconds")
#
#
#def parse_ts(s):
#    """Parse a stored timestamp as an aware UTC datetime, or None.
#
#    Everything this program writes carries an offset, but the database is also
#    edited by hand and by admin scripts, and sqlite's own datetime() produces a
#    naive string. Comparing one of those against an aware value raises, which
#    is how the whole quota pass once died on every sync. Assume UTC when no
#    offset is given, since that is what every writer here means.
#    """
#    if not s:
#        return None
#    try:
#        t = datetime.fromisoformat(s)
#    except ValueError:
#        return None
#    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)
#
#
#def valid_ip(s):
#    m = IPV4.match(s or "")
#    return bool(m) and all(0 <= int(p) <= 255 for p in m.groups())
#
#
#def normal_phone(s):
#    """Reduce an Iranian mobile number to one canonical form, or return "".
#
#    People type the same number four ways - 0912…, 912…, +98912…, ۰۹۱۲… - and
#    all four have to collide, or one person ends up with four accounts and the
#    operator cannot match a card receipt to any of them.
#    """
#    digits = ""
#    for ch in (s or "").strip():
#        if ch.isdigit():
#            # Persian and Arabic-Indic digits: unicodedata.digit maps both.
#            digits += str(unicodedata.digit(ch))
#    if digits.startswith("0098"):
#        digits = digits[4:]
#    elif digits.startswith("98") and len(digits) == 12:
#        digits = digits[2:]
#    elif digits.startswith("0"):
#        digits = digits[1:]
#    # 9xxxxxxxxx - a mobile number without the leading zero.
#    if len(digits) == 10 and digits.startswith("9"):
#        return "0" + digits
#    return ""
#
#
#def normal_username(s):
#    """Reduce a username to one canonical form, or return "".
#
#    Lowercased, because somebody who signs up as Ali and comes back as ali is
#    the same person and must not be able to become two accounts - nor be told
#    their own name is taken. Letters, digits, dot, dash and underscore only:
#    this ends up in log lines and in the operator's panel, and a name carrying
#    spaces or control characters is a nuisance in both.
#    """
#    v = (s or "").strip().lower()
#    if not re.fullmatch(r"[a-z0-9._-]{3,32}", v):
#        return ""
#    # A name that is only punctuation is not a name.
#    if not any(c.isalnum() for c in v):
#        return ""
#    return v
#
#
#def hash_password(password, salt):
#    # Same cost as the admin panel: slow enough that a stolen database is not
#    # a list of passwords, fast enough that signing in is not noticeable.
#    return hashlib.pbkdf2_hmac(
#        "sha256", (password or "").encode(), bytes.fromhex(salt), 200_000).hex()
#
#
#def check_password(user, password):
#    if not user["password_hash"] or not user["password_salt"]:
#        return False
#    return hmac.compare_digest(
#        hash_password(password, user["password_salt"]), user["password_hash"])
#
#
#def human(n):
#    n = float(n)
#    for unit in ("B", "KB", "MB", "GB", "TB"):
#        if n < 1024 or unit == "TB":
#            return ("%d %s" if unit == "B" else "%.2f %s") % (n, unit)
#        n /= 1024
#
#
#DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+"
#                       r"[a-z]{2,63}$")
#
## Names that must never be routed to the relay. localhost and the internal
## suffixes would break name resolution on the machine itself. Telegram stays on
## the list because customers reach support through it and a relay answering for
## t.me would break that for everyone behind it.
#FORBIDDEN = ("localhost", "local", "internal", "arpa", "telegram.org",
#             "t.me", "telegram.me")
#
#
#def clean_domain(raw):
#    """Normalise what someone typed into a domain, or explain why it is not.
#
#    Accepts what people actually paste - a full URL, a trailing slash, capital
#    letters, a leading dot or www - because rejecting those teaches nothing and
#    just costs a round trip.
#    """
#    d = (raw or "").strip().lower()
#    d = re.sub(r"^[a-z]+://", "", d)      # scheme
#    d = d.split("/")[0].split("?")[0]     # path, query
#    d = d.split("@")[-1]                  # someone pasting an email
#    d = d.split(":")[0]                   # port
#    d = d.strip(".")
#    if not d:
#        raise ValueError("خالی است")
#    if not DOMAIN_RE.match(d):
#        raise ValueError("قالب دامنه درست نیست")
#    if any(d == f or d.endswith("." + f) for f in FORBIDDEN):
#        raise ValueError("این دامنه را نمی‌شود مسیر داد")
#    if d.count(".") == 1 and len(d.split(".")[0]) <= 2:
#        raise ValueError("خیلی کلی است - دامنهٔ کامل بدهید")
#    return d
#
#
#def inspect_backup(path):
#    """Check a file really is one of our backups, and say what is in it.
#
#    Raises rather than returning a verdict, because every caller wants to stop.
#    A file that opens as sqlite is not enough: someone's unrelated database
#    would pass that and then replace every customer with nothing.
#    """
#    db = sqlite3.connect(path)
#    try:
#        status = db.execute("PRAGMA integrity_check").fetchone()[0]
#        if status != "ok":
#            raise ValueError("integrity check failed: %s" % status)
#        have = {r[0] for r in db.execute(
#            "SELECT name FROM sqlite_master WHERE type = 'table'")}
#        missing = {"users", "ips", "templates", "settings"} - have
#        if missing:
#            raise ValueError("not a panel backup - missing %s"
#                             % ", ".join(sorted(missing)))
#        return {t: db.execute("SELECT count(*) FROM " + t).fetchone()[0]
#                for t in ("users", "ips", "templates", "transactions")}
#    finally:
#        db.close()
#
#
## The operator's own domains, presented as a service so a template can include
## or exclude them like any brand. Its domain list lives in the database rather
## than the catalogue file, so it is filled in at use rather than shipped.
#CUSTOM_SERVICE = {"key": "custom", "label": "دامنه‌های دلخواه شما",
#                  "groups": [{"key": "main", "label": "همه", "domains": []}]}
#
#
#def load_catalogue():
#    """The service catalogue the installer dropped alongside this script.
#
#    Shipped as a file rather than kept in the database so that it is versioned
#    with the code: adding a brand is an upgrade, not a migration, and every
#    relay and panel agrees on what "playstation.download" means.
#    """
#    try:
#        with io_open(SERVICES_FILE) as fh:
#            return json.load(fh).get("services", [])
#    except Exception as e:
#        log(ERROR, "no service catalogue at %s: %s" % (SERVICES_FILE, e))
#        return []
#
#
#def io_open(path):
#    return open(path, encoding="utf-8")
#
#
#def load_config():
#    cfg = {}
#    with open(CONFIG) as fh:
#        for line in fh:
#            line = line.strip()
#            if not line or line.startswith("#") or "=" not in line:
#                continue
#            k, v = line.split("=", 1)
#            cfg[k.strip()] = v.strip().strip('"').strip("'")
#    for required in ("SYNC_SECRET", "RELAY_IP"):
#        if not cfg.get(required):
#            sys.exit("%s: %s is missing" % (CONFIG, required))
#    return cfg
#
#
## --------------------------------------------------------------- database
#def relax_telegram_id(db, path):
#    """Drop the NOT NULL from users.telegram_id on databases that predate web
#    signup.
#
#    sqlite cannot alter a column constraint, so the table has to be rebuilt.
#    The new definition is not written out here - it is the existing one with
#    that one phrase removed - so any column added by a later MIGRATIONS entry
#    survives without this function knowing it exists.
#
#    A copy of the database is taken first. This runs at startup, before the bot
#    is polling and before any relay can reach the API, and if it goes wrong the
#    operator has the file it went wrong on.
#    """
#    row = db.execute("SELECT sql FROM sqlite_master"
#                     " WHERE type = 'table' AND name = 'users'").fetchone()
#    if not row:
#        return
#    old = row[0]
#    new = re.sub(r"(telegram_id\s+INTEGER\s+UNIQUE)\s+NOT\s+NULL", r"\1",
#                 old, flags=re.I)
#    if new == old:
#        return                      # already nullable, nothing to do
#
#    backup = "%s.pre-websignup" % path
#    db.commit()                     # VACUUM cannot run inside a transaction
#    if not os.path.exists(backup):
#        db.execute("VACUUM INTO ?", (backup,))
#    print("migrating users: telegram_id may now be null (backup: %s)" % backup,
#          flush=True)
#
#    new = re.sub(r"^\s*CREATE\s+TABLE\s+(IF\s+NOT\s+EXISTS\s+)?[\"'`\[]?users[\"'`\]]?",
#                 "CREATE TABLE users_new", new, count=1, flags=re.I)
#    cols = [r[1] for r in db.execute("PRAGMA table_info(users)")]
#    names = ", ".join('"%s"' % c for c in cols)
#
#    # Foreign keys off for the swap: ips, claims, transactions and
#    # panel_sessions all point at users(id), and dropping the table underneath
#    # them with enforcement on would either fail or take their rows with it.
#    # It cannot be toggled inside a transaction, hence the order here.
#    db.execute("PRAGMA foreign_keys = OFF")
#    try:
#        db.execute("BEGIN")
#        db.execute(new)
#        db.execute("INSERT INTO users_new (%s) SELECT %s FROM users" % (names, names))
#        db.execute("DROP TABLE users")
#        db.execute("ALTER TABLE users_new RENAME TO users")
#        db.execute("COMMIT")
#    except Exception:
#        db.execute("ROLLBACK")
#        db.execute("PRAGMA foreign_keys = ON")
#        raise
#    broken = db.execute("PRAGMA foreign_key_check").fetchall()
#    db.execute("PRAGMA foreign_keys = ON")
#    if broken:
#        raise RuntimeError("migration left %d dangling references - the "
#                           "database before it is at %s" % (len(broken), backup))
#
#
#class Store:
#    """All database access, with one lock around it.
#
#    Two threads touch the database - the Telegram loop and the sync API - and
#    sqlite3 connections are not safe to share across threads. One connection
#    guarded by a lock is simpler to reason about than a pool, and at this size
#    there is nothing to gain from the pool.
#    """
#
#    def __init__(self, path):
#        self.lock = threading.Lock()
#        self.db = sqlite3.connect(path, check_same_thread=False)
#        self.db.row_factory = sqlite3.Row
#        self.db.execute("PRAGMA foreign_keys = ON")
#        self.db.execute("PRAGMA journal_mode = WAL")
#        with self.lock:
#            self.db.executescript(SCHEMA)
#            relax_telegram_id(self.db, path)
#            for table, column, spec in MIGRATIONS:
#                have = {r[1] for r in self.db.execute("PRAGMA table_info(%s)" % table)}
#                if column not in have:
#                    self.db.execute(
#                        "ALTER TABLE %s ADD COLUMN %s %s" % (table, column, spec)
#                    )
#            for statement in INDEXES:
#                self.db.execute(statement)
#            for key, value in DEFAULT_SETTINGS.items():
#                self.db.execute(
#                    "INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)",
#                    (key, value),
#                )
#            self.db.commit()
#
#    def setting(self, key, default=""):
#        row = self.one("SELECT value FROM settings WHERE key = ?", (key,))
#        return row["value"] if row else default
#
#    def set_setting(self, key, value):
#        self.run(
#            "INSERT INTO settings (key, value) VALUES (?, ?)"
#            " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
#            (key, str(value)),
#        )
#
#    def q(self, sql, args=()):
#        with self.lock:
#            return self.db.execute(sql, args).fetchall()
#
#    def one(self, sql, args=()):
#        rows = self.q(sql, args)
#        return rows[0] if rows else None
#
#    def run(self, sql, args=()):
#        with self.lock:
#            cur = self.db.execute(sql, args)
#            self.db.commit()
#            return cur
#
#    def user_by_telegram(self, tg_id):
#        return self.one("SELECT * FROM users WHERE telegram_id = ?", (tg_id,))
#
#    # A new account starts with nothing and is not connected: 'pending' keeps
#    # it out of the allowed list, which is what "no trial" has to mean, and
#    # the operator turns it on by giving it a quota.
#    #
#    # Not quota_bytes = 0 on an active account, which is the trap here: zero
#    # means unlimited everywhere in this file, so the account that was meant
#    # to get nothing would get everything. The status is what decides.
#    def create_user(self, tg_id, username, first_name):
#        self.run(
#            "INSERT OR IGNORE INTO users"
#            " (telegram_id, username, first_name, created_at, status,"
#            "  quota_bytes, quota_mode, quota_reset_at, expires_at)"
#            " VALUES (?, ?, ?, ?, 'pending', 0, 'oneoff', NULL, NULL)",
#            (tg_id, username, first_name, now()),
#        )
#        return self.user_by_telegram(tg_id)
#
#    def user_by_phone(self, phone):
#        return self.one("SELECT * FROM users WHERE phone = ?", (phone,))
#
#    def user_by_username(self, username):
#        return self.one("SELECT * FROM users WHERE username = ?", (username,))
#
#    def create_web_user(self, username, first_name, password):
#        """Open an account from the web panel, with no Telegram behind it.
#
#        It starts with nothing, the same as one opened any other way - the way
#        in should not decide what you get. Signing up gets you an account, a
#        password and somewhere to send a receipt; it does not get you any
#        traffic until an operator says so.
#        """
#        salt = secrets.token_hex(16)
#        self.run(
#            "INSERT INTO users"
#            " (telegram_id, username, password_hash, password_salt, first_name,"
#            "  created_at, status, quota_bytes, quota_mode, quota_reset_at,"
#            "  expires_at)"
#            " VALUES (NULL, ?, ?, ?, ?, ?, 'pending', 0, 'oneoff', NULL, NULL)",
#            (username, hash_password(password, salt), salt, first_name, now()),
#        )
#        return self.user_by_username(username)
#
#    def set_password(self, user_id, password):
#        salt = secrets.token_hex(16)
#        # A password the customer set is their own, so any temporary one is
#        # over - whichever of the two forms it came through.
#        self.run("UPDATE users SET password_hash = ?, password_salt = ?,"
#                 " must_change_password = 0 WHERE id = ?",
#                 (hash_password(password, salt), salt, user_id))
#
#    def open_session(self, user_id, days=30):
#        token = secrets.token_urlsafe(32)
#        self.run(
#            "INSERT INTO panel_sessions (token, user_id, created_at, expires_at)"
#            " VALUES (?, ?, ?, ?)",
#            (token, user_id, now(),
#             (datetime.now(timezone.utc) + timedelta(days=days)).isoformat(
#                 timespec="seconds")))
#        return token
#
#    def user_ips(self, user_id):
#        return self.q("SELECT * FROM ips WHERE user_id = ? ORDER BY added_at", (user_id,))
#
#    def allowed(self):
#        return self.q(
#            "SELECT i.ip AS ip, u.id AS uid FROM ips i JOIN users u ON u.id = i.user_id"
#            " WHERE u.status = 'active'"
#        )
#
#    # ----------------------------------------------------------- templates
#    def ensure_default_template(self, catalogue):
#        """Create the all-services template if there is none.
#
#        Everything routes in it, which is exactly how the service behaved
#        before templates existed - so an upgrade changes nothing until an
#        admin decides otherwise.
#        """
#        row = self.one("SELECT * FROM templates WHERE is_default = 1")
#        if row:
#            return row
#        cur = self.run(
#            "INSERT INTO templates (name, is_default, created_at) VALUES (?, 1, ?)",
#            ("کامل", now()))
#        tid = cur.lastrowid
#        for svc in catalogue:
#            for grp in svc["groups"]:
#                # Opt-in groups are left out here too. The default template
#                # ignores these rows while it is the default, but it stops
#                # being special the moment somebody makes another one the
#                # default - and it should not carry a tick nobody made.
#                if grp.get("opt_in"):
#                    continue
#                self.run(
#                    "INSERT OR IGNORE INTO template_services"
#                    " (template_id, service_key, group_key) VALUES (?, ?, ?)",
#                    (tid, svc["key"], grp["key"]))
#        return self.one("SELECT * FROM templates WHERE id = ?", (tid,))
#
#    def template_groups(self, template_id):
#        return {(r["service_key"], r["group_key"]) for r in self.q(
#            "SELECT service_key, group_key FROM template_services WHERE template_id = ?",
#            (template_id,))}
#
#    def routed_for(self, template_id, catalogue):
#        """Domains this template DOES route, for the relay to hijack.
#
#        The relay writes these as address= rules in the profile's own
#        resolver, rather than inheriting the shared hijack list and taking
#        names back out of it with server= rules. Subtraction cannot work
#        here: both rules would name the same host, dnsmasq's longest match
#        ties, and address= wins - so every un-tick of an ordinary domain was
#        silently ignored. What a profile must not route, it must simply not
#        be told about.
#
#        The custom service is excluded: those domains reach the relay by a
#        different route, and apply_custom_domains writes them per profile.
#        """
#        routed = self.template_groups(template_id)
#        off = self.template_domains_off(template_id)
#        is_default = bool(self.one(
#            "SELECT is_default FROM templates WHERE id = ?",
#            (template_id,))["is_default"])
#        out = []
#        for svc in catalogue:
#            if svc["key"] == "custom":
#                continue
#            for grp in svc["groups"]:
#                # The default template means "everything, now and later", and
#                # the one exception is a group nobody has opted in to.
#                if is_default:
#                    if not grp.get("opt_in"):
#                        out.extend(grp["domains"])
#                    continue
#                # A locked group is never routed, whatever a template says:
#                # routing it can only break the thing it belongs to.
#                if (svc["key"], grp["key"]) in routed and not grp.get("locked"):
#                    out.extend(d for d in grp["domains"] if d not in off)
#        return sorted(set(out))
#
#    def bypass_for(self, template_id, catalogue):
#        """Domains this template does NOT route, so the relay resolves them
#        normally and the client goes straight to them."""
#        # The default template means "everything", and has to keep meaning it
#        # as the catalogue grows. Reading its rows would freeze it at whatever
#        # existed the day it was created, so a brand added in a later upgrade
#        # would silently stop routing for every customer on the default plan -
#        # a service quietly getting worse with no change anybody made.
#        #
#        # "Everything" stops at the opt-in groups. Those exist so an operator
#        # can see them and decide; routing one by default would be deciding
#        # for them, in the one direction that breaks something.
#        row = self.one("SELECT is_default FROM templates WHERE id = ?", (template_id,))
#        if row and row["is_default"]:
#            return sorted({d for svc in catalogue for grp in svc["groups"]
#                           if grp.get("opt_in") for d in grp["domains"]})
#        routed = self.template_groups(template_id)
#        off = self.template_domains_off(template_id)
#        out = []
#        for svc in catalogue:
#            # Custom domains are never bypassed by rule - see routes_custom.
#            if svc["key"] == "custom":
#                continue
#            for grp in svc["groups"]:
#                # A locked group is bypassed for every template - a tick left
#                # in the database from before the lock included.
#                if grp.get("locked") or (svc["key"], grp["key"]) not in routed:
#                    out.extend(grp["domains"])
#                else:
#                    # The group is routed, minus whatever was switched off
#                    # inside it one domain at a time.
#                    out.extend(d for d in grp["domains"] if d in off)
#        return sorted(set(out))
#
#    def template_domains_off(self, template_id):
#        return {r["domain"] for r in self.q(
#            "SELECT domain FROM template_domains_off WHERE template_id = ?",
#            (template_id,))}
#
#    def profiles(self, catalogue, default_id):
#        """The templates actually in use, and who is on each.
#
#        Only templates with at least one active registered address become
#        profiles: an unused template costs a resolver on every relay for
#        nobody's benefit.
#        """
#        rows = self.q(
#            "SELECT i.ip AS ip, u.id AS uid, u.speed_kbps AS kbps,"
#            " COALESCE(u.template_id, ?) AS tid,"
#            " COALESCE(u.username, '') AS uname"
#            " FROM ips i JOIN users u ON u.id = i.user_id"
#            " WHERE u.status = 'active'", (default_id,))
#        by_ip = {}
#        used = set()
#        for r in rows:
#            tid = r["tid"] if self.one(
#                "SELECT 1 FROM templates WHERE id = ?", (r["tid"],)) else default_id
#            # The username travels so smartdns-watch on a relay can take one
#            # where an address would do.
#            by_ip[r["ip"]] = {"uid": r["uid"], "tid": tid,
#                              "kbps": r["kbps"] or 0, "user": r["uname"]}
#            used.add(tid)
#        custom = self.custom_domains()
#        profiles = {}
#        for tid in used:
#            # The default routes everything, which is what the relay's main
#            # resolver already does - it needs no instance of its own.
#            if tid == default_id:
#                continue
#            profiles[str(tid)] = {
#                # What this template routes, said positively. The relay used
#                # to inherit the shared hijack list and subtract from it with
#                # server= rules, which dnsmasq resolved the other way whenever
#                # both named the same host - so an un-ticked service kept
#                # routing and nothing said otherwise.
#                "routed": self.routed_for(tid, catalogue),
#                # Still sent: names whose parent this template routes have to
#                # be taken back out, and there the subtraction does work,
#                # because the profile's rule is the longer one.
#                "bypass": self.bypass_for(tid, catalogue),
#                # Listed positively, not by omission: the relay writes these
#                # into this profile's own config, and a template that does not
#                # route them simply has no rule for them anywhere. One of them
#                # switched off inside the template is left out the same way.
#                "custom": [d for d in custom
#                           if d not in self.template_domains_off(tid)]
#                          if self.routes_custom(tid) else [],
#                # Whether this profile still wants epic-pin's work. Those pins
#                # name exact hosts, so they beat any rule that routes the
#                # parent domain - which means a template that has ticked the
#                # backend group would tick it and see nothing happen. The
#                # relay leaves the pins out of a profile that asked to route
#                # them, and keeps them everywhere else.
#                "pins": ("bypass", "epic") not in self.template_groups(tid),
#            }
#        return by_ip, profiles
#
#    def custom_domains(self):
#        return [r["domain"] for r in self.q(
#            "SELECT domain FROM custom_domains ORDER BY domain")]
#
#    def template_names(self):
#        """Every template's name by id, and which is the default - so the
#        relay's own tools can say "test" where its resolvers only know "2"."""
#        rows = self.q("SELECT id, name, is_default FROM templates")
#        return {"default": next((r["id"] for r in rows if r["is_default"]), None),
#                "names": {str(r["id"]): r["name"] for r in rows}}
#
#    def routes_custom(self, template_id):
#        """Whether this template routes the operator's own domains.
#
#        These cannot be handled the way catalogue services are. A service is
#        un-routed by adding a more specific `server=` rule that out-matches the
#        broad `address=` hijacking its parent - but a custom domain's two rules
#        name exactly the same host, and dnsmasq picks the address= one. Tested,
#        not assumed. So rather than un-routing them per template, they are
#        written only into the resolvers of templates that do route them.
#        """
#        row = self.one("SELECT is_default FROM templates WHERE id = ?", (template_id,))
#        if row and row["is_default"]:
#            return True
#        return ("custom", "main") in self.template_groups(template_id)
#
#    def backup(self):
#        """A consistent copy of the database, minus the metrics.
#
#        VACUUM INTO rather than copying the file: sqlite is in WAL mode, so the
#        file on disk is not the whole story and copying it while the bot is
#        writing can produce something that will not open. VACUUM INTO takes a
#        proper snapshot with the database still running.
#
#        Health samples are dropped from the copy. They are the bulk of the rows
#        and none of the value - what matters in a restore is who the customers
#        are, what they bought and what they have used.
#        """
#        path = "/tmp/smartdns-backup-%s.db" % datetime.now(timezone.utc).strftime(
#            "%Y%m%d-%H%M%S")
#        with self.lock:
#            self.db.execute("VACUUM INTO ?", (path,))
#        copy = sqlite3.connect(path)
#        copy.execute("DELETE FROM metrics")
#        copy.commit()
#        copy.execute("VACUUM")
#        copy.close()
#        return path
#
#    def restore(self, path):
#        """Put a checked backup in place of the live database.
#
#        The current database is kept, not deleted: a restore is exactly the
#        moment somebody discovers they restored the wrong file, and having the
#        previous state one move away is the difference between an inconvenience
#        and losing every customer.
#
#        The candidate has to be staged beside the database, not in /tmp.
#        rename() cannot cross a mount point, and the unit sets PrivateTmp, so
#        /tmp is one - a restore from there fails with EXDEV at the last step,
#        after the safety copy has been taken and the connection closed.
#        """
#        if os.path.dirname(os.path.abspath(path)) != os.path.dirname(DB):
#            staged = os.path.join(os.path.dirname(DB),
#                                  ".restore-%s.db" % secrets.token_hex(6))
#            shutil.copyfile(path, staged)
#            os.unlink(path)
#            path = staged
#        keep = "%s.before-restore-%s" % (
#            DB, datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"))
#        with self.lock:
#            self.db.execute("VACUUM INTO ?", (keep,))
#            self.db.close()
#        os.replace(path, DB)
#        # A stale write-ahead log next to a different database is how a restore
#        # turns into corruption. The backup is a complete snapshot, so there is
#        # nothing in these worth keeping.
#        for suffix in ("-wal", "-shm"):
#            try:
#                os.unlink(DB + suffix)
#            except OSError:
#                pass
#        return keep
#
#    def record_metrics(self, host, sample):
#        if not isinstance(sample, dict) or "error" in sample:
#            return
#        cols = [f for f in METRIC_FIELDS if sample.get(f) is not None]
#        # An empty sample builds "INSERT INTO metrics (host, at, ) VALUES ..",
#        # which sqlite rejects and which took the whole sync request down with
#        # it - a relay running an older agent sends no metrics at all, and that
#        # must not stop its usage being counted.
#        if not cols:
#            return
#        self.run(
#            "INSERT INTO metrics (host, at, %s) VALUES (?, ?, %s)"
#            % (", ".join(cols), ", ".join("?" * len(cols))),
#            [host, now()] + [sample[c] for c in cols],
#        )
#
#    def prune_metrics(self):
#        self.run(
#            "DELETE FROM metrics WHERE at < ?",
#            ((datetime.now(timezone.utc)
#              - timedelta(hours=METRICS_KEEP_HOURS)).isoformat(timespec="seconds"),))
#
#    def latest_metrics(self):
#        """Newest sample per host."""
#        return self.q(
#            "SELECT m.* FROM metrics m JOIN ("
#            "  SELECT host, MAX(at) AS at FROM metrics GROUP BY host"
#            ") last ON last.host = m.host AND last.at = m.at"
#        )
#
#    def fold_counters(self, relay, counters):
#        """Turn raw per-address counters into per-user usage.
#
#        The kernel counts bytes per address since the element was created. What
#        a bill needs is bytes per user, across whatever addresses they have had.
#        So take the growth since last time rather than the absolute number, and
#        add it to the user's running total.
#
#        The previous reading is kept per relay - see ip_counters. Sharing one
#        figure between relays bills the same bytes over and over.
#        """
#        touched = {}
#        with self.lock:
#            for ip, total in counters.items():
#                row = self.db.execute(
#                    "SELECT id, user_id FROM ips WHERE ip = ?", (ip,)).fetchone()
#                if row is None:
#                    continue
#                prev = self.db.execute(
#                    "SELECT last_counter FROM ip_counters WHERE ip = ? AND relay = ?",
#                    (ip, relay)).fetchone()
#                # A counter that went backwards means it was reset - a reboot
#                # restoring an older saved value, or the address being
#                # re-added. Whatever is there now is the growth.
#                delta = total - (prev["last_counter"] if prev else 0)
#                if delta < 0:
#                    delta = total
#                if delta:
#                    self.db.execute(
#                        "UPDATE users SET used_bytes = used_bytes + ? WHERE id = ?",
#                        (delta, row["user_id"]),
#                    )
#                    touched[row["user_id"]] = touched.get(row["user_id"], 0) + delta
#                self.db.execute(
#                    "INSERT INTO ip_counters (ip, relay, last_counter)"
#                    " VALUES (?, ?, ?) ON CONFLICT(ip, relay)"
#                    " DO UPDATE SET last_counter = excluded.last_counter",
#                    (ip, relay, total))
#            self.db.commit()
#        return touched
#
#
## ----------------------------------------------------------------- health
#class Health:
#    """This machine's own metrics, read straight out of /proc.
#
#    A near-copy of the same class in smartdns-sync. They are duplicated on
#    purpose: each program is extracted from the installer as a single
#    self-contained file, so a shared module would mean a third payload and a
#    third thing to keep in step.
#    """
#
#    def __init__(self):
#        self.cpu = None
#        self.net = None
#
#    @staticmethod
#    def _meminfo():
#        out = {}
#        with open("/proc/meminfo") as fh:
#            for line in fh:
#                k, _, v = line.partition(":")
#                out[k] = int(v.split()[0]) * 1024
#        return out
#
#    def _cpu_percent(self):
#        with open("/proc/stat") as fh:
#            parts = [int(x) for x in fh.readline().split()[1:]]
#        idle, total = parts[3] + parts[4], sum(parts)
#        prev, self.cpu = self.cpu, (idle, total)
#        if not prev:
#            return None
#        d_total = total - prev[1]
#        if d_total <= 0:
#            return None
#        return round(100.0 * (1 - (idle - prev[0]) / d_total), 1)
#
#    def _net_rates(self):
#        rx = tx = 0
#        with open("/proc/net/dev") as fh:
#            for line in fh.readlines()[2:]:
#                name, _, rest = line.partition(":")
#                if name.strip() == "lo":
#                    continue
#                f = rest.split()
#                rx += int(f[0]); tx += int(f[8])
#        stamp = time.time()
#        prev, self.net = self.net, (rx, tx, stamp)
#        if not prev:
#            return None, None
#        dt = stamp - prev[2]
#        if dt <= 0:
#            return None, None
#        return int((rx - prev[0]) / dt), int((tx - prev[1]) / dt)
#
#    def sample(self):
#        m = self._meminfo()
#        rx, tx = self._net_rates()
#        st = os.statvfs("/")
#        with open("/proc/uptime") as fh:
#            uptime = int(float(fh.readline().split()[0]))
#        with open("/proc/loadavg") as fh:
#            load = float(fh.readline().split()[0])
#        swap_total = m.get("SwapTotal", 0)
#        return {
#            "cpu": self._cpu_percent(),
#            "load": load,
#            "mem_total": m.get("MemTotal", 0),
#            "mem_used": m.get("MemTotal", 0) - m.get("MemAvailable", 0),
#            "swap_total": swap_total,
#            "swap_used": swap_total - m.get("SwapFree", 0) if swap_total else 0,
#            "disk_total": st.f_blocks * st.f_frsize,
#            "disk_used": (st.f_blocks - st.f_bfree) * st.f_frsize,
#            "rx_bps": rx,
#            "tx_bps": tx,
#            "uptime": uptime,
#        }
#
#
## ------------------------------------------------------------------ quota
#def enforce_quotas(store):
#    """Reset, warn and cut off. Called after every sync.
#
#    Cutting off is a status change and nothing more. The relay learns about it
#    on its next sync, when the address stops appearing in the allowed list and
#    smartdns-acl removes it from the kernel. Nothing here touches a firewall
#    directly - one place decides who may connect, and it is the database.
#
#    Nothing is sent anywhere either. The warning thresholds are recorded in
#    users.warned and the customer is told on their own panel page, which
#    reaches everybody - most accounts have no Telegram behind them and never
#    did, so a message was only ever going to some of them.
#    """
#    stamp = datetime.now(timezone.utc)
#    for u in store.q("SELECT * FROM users"):
#        quota, used = u["quota_bytes"], u["used_bytes"]
#
#        # A trial ends on its date whether or not the allowance ran out, so
#        # this comes before anything to do with bytes. Checked for every
#        # account, but only the trial sets a date - a paid account ends when
#        # its quota does.
#        due = parse_ts(u["expires_at"])
#        if due and stamp >= due:
#            if u["status"] == "active":
#                store.run("UPDATE users SET status = 'expired' WHERE id = ?",
#                          (u["id"],))
#                print("expired: user %d after %s" % (u["id"], human(used)),
#                      flush=True)
#            continue
#
#        # Monthly plans roll over on their own date rather than on the 1st, so
#        # a user who joins on the 20th gets a full month.
#        if u["quota_mode"] == "monthly" and u["quota_reset_at"]:
#            due = parse_ts(u["quota_reset_at"])
#            if due and stamp >= due:
#                days = int(store.setting("plan_days", "30") or 30)
#                store.run(
#                    "UPDATE users SET used_bytes = 0, warned = 0,"
#                    " status = CASE WHEN status = 'over_quota' THEN 'active' ELSE status END,"
#                    " quota_reset_at = ? WHERE id = ?",
#                    ((stamp + timedelta(days=days)).isoformat(timespec="seconds"), u["id"]),
#                )
#                continue
#
#        if not quota:            # unlimited
#            continue
#
#        if used >= quota and u["status"] == "active":
#            store.run("UPDATE users SET status = 'over_quota' WHERE id = ?", (u["id"],))
#            print("over quota: user %d at %s of %s"
#                  % (u["id"], human(used), human(quota)), flush=True)
#            continue
#
#        # Record each threshold as it is crossed, once. The bit is what makes
#        # it once - a sync runs every thirty seconds - and it is what the
#        # customer's own page reads to decide whether to warn them.
#        for fraction, bit in THRESHOLDS:
#            if used >= quota * fraction and not (u["warned"] & bit):
#                store.run("UPDATE users SET warned = warned | ? WHERE id = ?",
#                          (bit, u["id"]))
#
#
## ------------------------------------------------------------------ logging
## journald reads a leading <N> on a line as its syslog level. Warnings and
## errors carry one, so `journalctl -p warning` - which is what
## `smartdns-logs -e` runs - shows exactly the problems. Ordinary lines stay
## unmarked and land at info, as they always did. Before this everything
## landed at info, stderr included, and a failure looked like a heartbeat.
#INFO, WARN, ERROR = 6, 4, 3
## The visitor went away, or never finished saying hello. Not a fault here.
#GONE = (ConnectionError, TimeoutError, ssl.SSLError)
#
#
#def log(level, msg):
#    tag = "<%d>" % level if level < INFO else ""
#    for line in str(msg).splitlines() or [""]:
#        print(tag + line, flush=True)
#
#
#def log_exception(what):
#    """An error with its traceback, every line at error level. journald makes
#    each line its own entry, and at info all but the first would be lost
#    among the ordinary ones."""
#    log(ERROR, "%s\n%s" % (what, traceback.format_exc().rstrip()))
#
#
#def log_access(h, prefix, code, path, who=""):
#    """One line for one request: what was asked, the answer, how long it took
#    and who asked. Server errors at error level; everything else is info."""
#    try:
#        code = int(code)
#    except (TypeError, ValueError):
#        code = 0
#    ms = (time.monotonic() - getattr(h, "_t0", time.monotonic())) * 1000
#    # 501 is a scanner's GET to a POST-only port: the visitor's mistake.
#    log(ERROR if code >= 500 and code != 501 else INFO, "%s %s %s %d %dms from %s%s" % (
#        prefix, getattr(h, "command", None) or "-", path, code, ms,
#        h.client_address[0], " " + who if who else ""))
#
#
## How long a visitor may take over the TLS handshake, and then how long any one
## read or write may stall. Per operation, so a receipt crawling up from a
## relay that keeps moving is never cut off, while a quiet connection is let go.
#HANDSHAKE_TIMEOUT = 10
#IO_TIMEOUT = 30
#
#
#class TLSServer(http.server.ThreadingHTTPServer):
#    """TLS per connection, under a deadline - never on the listening socket.
#
#    Wrapping the listening socket runs every visitor's handshake inside
#    accept(), on the one thread that accepts for all of them and with no
#    timeout, so a single connection that opens and then says nothing freezes
#    the server for everybody until it goes away. The customer panel froze
#    exactly that way in production, and this server was built the same way -
#    here it would have been worse: this port is public, the relay check comes
#    after the handshake, and while it hung no relay could sync, so nobody new
#    was let in and nobody whose time ran out was cut off. Here accept() only
#    accepts; a stalled visitor stalls only its own thread.
#
#    ctx=None serves plain http. That is for tests - serve_api never does.
#    """
#    daemon_threads = True
#
#    def __init__(self, addr, handler, ctx):
#        self.ctx = ctx
#        super().__init__(addr, handler)
#
#    def finish_request(self, request, client_address):
#        if self.ctx is None:
#            return super().finish_request(request, client_address)
#        request.settimeout(HANDSHAKE_TIMEOUT)
#        try:
#            tls = self.ctx.wrap_socket(request, server_side=True)
#        except (ssl.SSLError, OSError):
#            return      # a scanner, or plain http to an https port
#        try:
#            tls.settimeout(IO_TIMEOUT)
#            self.RequestHandlerClass(tls, client_address, self)
#        except (ssl.SSLError, OSError):
#            pass
#        finally:
#            try:
#                tls.close()
#            except OSError:
#                pass
#
#    def handle_error(self, request, client_address):
#        # Whatever a handler did not catch, with its traceback, at error
#        # level. http.server's default prints it at info, where nobody looks.
#        if isinstance(sys.exc_info()[1], GONE):
#            return
#        log_exception("request from %s failed" % client_address[0])
#
#
## --------------------------------------------------------------- sync API
#class API(http.server.BaseHTTPRequestHandler):
#    server_version = "smartdns"
#    store = None
#    secret = None
#    relays = ()
#    tg = None
#
#    def log_message(self, fmt, *args):
#        # http.server's own notes - a malformed request, a timeout. The access
#        # line is log_request below.
#        log(INFO, "api %s from %s" % (fmt % args, self.client_address[0]))
#
#    def parse_request(self):
#        self._t0 = time.monotonic()
#        return super().parse_request()
#
#    def log_request(self, code="-", size="-"):
#        """One line per request, except the heartbeat: every relay syncs every
#        thirty seconds, and a line for each would bury everything else. A sync
#        is logged when it fails or crawls."""
#        path = urllib.parse.urlparse(getattr(self, "path", "") or "").path[:120]
#        took = time.monotonic() - getattr(self, "_t0", time.monotonic())
#        try:
#            fine = int(code) == 200
#        except (TypeError, ValueError):
#            fine = False
#        if path == "/sync" and fine and took < 2:
#            return
#        log_access(self, "api", code, path, getattr(self, "_who", ""))
#
#    def reply(self, code, obj):
#        body = json.dumps(obj).encode()
#        self.send_response(code)
#        self.send_header("Content-Type", "application/json")
#        self.send_header("Content-Length", str(len(body)))
#        self.end_headers()
#        self.wfile.write(body)
#
#    def authorised(self):
#        # This port is reachable from the whole internet, so the bearer token
#        # is not the only thing standing in front of the database. Only the
#        # relays this exit is paired with may talk to it at all - a scanner
#        # that finds the port gets nothing to guess against.
#        if self.client_address[0] not in self.relays:
#            return False
#        given = self.headers.get("Authorization", "")
#        want = "Bearer " + self.secret
#        # Constant time, so the comparison cannot be used to guess the secret
#        # one character at a time.
#        if hmac.compare_digest(given, want):
#            return True
#        # One of our own relays with the wrong secret is a broken pairing,
#        # not a scanner, and nothing works on that relay until it is fixed.
#        # Strangers get only their request line.
#        log(WARN, "api: %s is a paired relay but sent the wrong secret - its "
#            "SYNC_SECRET does not match this panel's" % self.client_address[0])
#        return False
#
#    def do_POST(self):
#        if not self.authorised():
#            return self.reply(401, {"error": "unauthorised"})
#        try:
#            length = int(self.headers.get("Content-Length", 0))
#            # Base64 inflates by a third, and the largest thing a relay sends
#            # is a receipt. Anything past that is refused unread rather than
#            # buffered.
#            if length > 8 * MB:
#                return self.reply(413, {"error": "too large"})
#            body = json.loads(self.rfile.read(length) or b"{}")
#        except Exception:
#            return self.reply(400, {"error": "bad json"})
#
#        if self.path == "/sync":
#            counters = body.get("counters") or {}
#            clean = {
#                ip: int(v) for ip, v in counters.items() if valid_ip(ip) and int(v) >= 0
#            }
#            self.store.fold_counters(self.client_address[0], clean)
#            # The relay names itself by the address it connected from, so a
#            # second relay appears on its own without any configuration.
#            self.store.record_metrics(self.client_address[0], body.get("host") or {})
#            # Quotas are evaluated here, on fresh numbers, so a user who runs
#            # out is off the list this relay is about to be handed.
#            try:
#                enforce_quotas(self.store)
#            except Exception as e:
#                log_exception("quota pass failed: %r" % e)
#            by_ip, profiles = self.store.profiles(CATALOGUE, DEFAULT_TEMPLATE[0])
#            # The label goes into the nftables element as a comment, so that
#            # `smartdns-acl list` on the relay is readable without the
#            # database in front of you. The profile tells the relay which
#            # resolver this address should be pointed at.
#            # uid travels as well as the label built from it: the relay uses
#            # it as the shaping mark, and parsing it back out of "u12" would
#            # be a second place that has to agree about the format.
#            allowed = [{"ip": ip, "name": "u%d" % v["uid"], "uid": v["uid"],
#                        "kbps": v["kbps"], "user": v.get("user", ""),
#                        "profile": str(v["tid"]) if str(v["tid"]) in profiles else ""}
#                       for ip, v in sorted(by_ip.items())]
#            extra = [r["domain"] for r in self.store.q(
#                "SELECT domain FROM custom_domains ORDER BY domain")]
#            return self.reply(200, {"allowed": allowed, "profiles": profiles,
#                                    "extra_domains": extra,
#                                    "templates": self.store.template_names(),
#                                    # Written under the sign-in form, for
#                                    # whoever has forgotten their password.
#                                    "support": self.store.setting("support_contact"),
#                                    })
#
#        # ---- user panel, served by the relay on the customer's behalf ----
#        if self.path == "/user-info":
#            return self.reply(200, self.do_user_info(body))
#        if self.path == "/user-claim":
#            return self.reply(200, self.do_user_claim(body))
#        if self.path == "/user-signup":
#            return self.reply(200, self.do_user_signup(body))
#        if self.path == "/user-password-login":
#            return self.reply(200, self.do_user_password_login(body))
#        if self.path == "/user-receipt":
#            return self.reply(200, self.do_user_receipt(body))
#        if self.path == "/user-password":
#            return self.reply(200, self.do_user_password(body))
#        if self.path == "/user-password-first":
#            return self.reply(200, self.do_user_password_first(body))
#
#        return self.reply(404, {"error": "no such endpoint"})
#
#    # ---- user panel ------------------------------------------------------
#    def _session_user(self, token):
#        row = self.store.one(
#            "SELECT u.* FROM panel_sessions s JOIN users u ON u.id = s.user_id"
#            " WHERE s.token = ? AND s.expires_at > ?", (token or "", now()))
#        if row:
#            # Named on the request line: which customer, never the session.
#            self._who = "user #%d" % row["id"]
#        return row
#
#    def do_user_signup(self, body):
#        """Open an account from the panel, with no Telegram in the way.
#
#        The address is not registered here. Signing up and pointing the service
#        at a connection are two different decisions - somebody may well sign up
#        on mobile data and only afterwards go and register the home line - so
#        the next page asks, showing the address it can see.
#        """
#        ip = body.get("ip", "")
#        ok, wait = THROTTLE.check("signup:%s" % ip, limit=4, window=3600)
#        if not ok:
#            return {"ok": False, "message":
#                    "تعداد ثبت‌نام از این اینترنت زیاد بوده. %d دقیقه دیگر."
#                    % max(1, wait // 60)}
#
#        username = normal_username(body.get("username"))
#        if not username:
#            return {"ok": False, "message":
#                    "نام کاربری باید ۳ تا ۳۲ نویسه باشد — حروف انگلیسی، عدد،"
#                    " و . _ -"}
#        password = body.get("password") or ""
#        if len(password) < 8:
#            return {"ok": False, "message": "رمز باید دست‌کم ۸ نویسه باشد"}
#        name = (body.get("name") or "").strip()[:60]
#
#        if self.store.user_by_username(username):
#            return {"ok": False,
#                    "message": "این نام کاربری قبلاً گرفته شده. یکی دیگر"
#                               " بنویسید یا وارد شوید"}
#        try:
#            user = self.store.create_web_user(username, name, password)
#        except sqlite3.IntegrityError:
#            # Two signups claiming the same name in the same instant. The
#            # unique index is what actually decides between them; this only
#            # turns its answer into a sentence.
#            return {"ok": False,
#                    "message": "این نام کاربری قبلاً گرفته شده. یکی دیگر"
#                               " بنویسید یا وارد شوید"}
#        THROTTLE.hit("signup:%s" % ip)
#        print("web signup: %s (#%d) from %s" % (username, user["id"], ip), flush=True)
#        return {"ok": True, "session": self.store.open_session(user["id"]),
#                "message": "حساب ساخته شد"}
#
#    def do_user_password_login(self, body):
#        ip = body.get("ip", "")
#        ok, wait = THROTTLE.check("login:%s" % ip, limit=8, window=900)
#        if not ok:
#            log(WARN, "api login throttled for %s: too many failed attempts" % ip)
#            return {"ok": False, "message":
#                    "تلاش زیاد بوده. %d دقیقه دیگر امتحان کنید."
#                    % max(1, wait // 60)}
#
#        username = normal_username(body.get("username"))
#        user = self.store.user_by_username(username) if username else None
#        # One message for an unknown name and a wrong password. Two different
#        # messages tell anybody who asks which names have accounts.
#        if not user or not check_password(user, body.get("password") or ""):
#            THROTTLE.hit("login:%s" % ip)
#            # The name tried and where from - enough to answer "I can't get
#            # in". Never the password.
#            log(INFO, "api login failed for %r from %s" % (username, ip))
#            return {"ok": False, "message": "نام کاربری یا رمز درست نیست"}
#        THROTTLE.clear("login:%s" % ip)
#        self._who = "user #%d" % user["id"]
#        log(INFO, "api login: user #%d (%s) from %s" % (user["id"], username, ip))
#        return {"ok": True, "session": self.store.open_session(user["id"]),
#                "must_change": bool(user["must_change_password"])}
#
#    def _must_choose(self, user):
#        """The refusal for an account still on a temporary password, or None."""
#        if user["must_change_password"]:
#            return {"ok": False, "message": "اول رمز خودتان را انتخاب کنید"}
#        return None
#
#    def do_user_password_first(self, body):
#        """Replace a temporary password with the customer's own.
#
#        Only for an account the operator has just given a temporary password.
#        The session came from signing in with it, which is the proof; asking
#        for it again would only mean typing it twice. Once the customer's own
#        is set, the temporary one is gone and this door is shut.
#        """
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#        if not user["must_change_password"]:
#            return {"ok": False, "message":
#                    "رمز شما قبلاً انتخاب شده؛ برای عوض کردنش از «تغییر رمز» استفاده کنید"}
#        new = body.get("new") or ""
#        if len(new) < 8:
#            return {"ok": False, "message": "رمز تازه باید دست‌کم ۸ نویسه باشد"}
#        if check_password(user, new):
#            return {"ok": False, "message": "رمز تازه نباید همان رمز موقت باشد"}
#        self.store.set_password(user["id"], new)
#        self.store.run(
#            "DELETE FROM panel_sessions WHERE user_id = ? AND token != ?",
#            (user["id"], body.get("session")))
#        log(INFO, "user #%d chose their own password" % user["id"])
#        return {"ok": True, "message": "رمز شما ذخیره شد"}
#
#    def do_user_password(self, body):
#        """Let a customer change their own password.
#
#        The current one is required even though the session already proves
#        who they are. A session can be a borrowed phone or a browser left
#        open; asking for the password again means possession of the session
#        is not enough to take the account away from its owner.
#        """
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#        if not user["password_hash"]:
#            return {"ok": False,
#                    "message": "این حساب رمز ندارد؛ با پشتیبانی تماس بگیرید"}
#        if not check_password(user, body.get("current") or ""):
#            # Same throttle as signing in: this is a password guess like any
#            # other, and a stolen session should not buy unlimited attempts.
#            ok, wait = THROTTLE.check("pw:%d" % user["id"], limit=8, window=900)
#            if not ok:
#                return {"ok": False, "message":
#                        "تلاش زیاد بوده. %d دقیقه دیگر." % max(1, wait // 60)}
#            THROTTLE.hit("pw:%d" % user["id"])
#            return {"ok": False, "message": "رمز فعلی درست نیست"}
#
#        new = body.get("new") or ""
#        if len(new) < 8:
#            return {"ok": False, "message": "رمز تازه باید دست‌کم ۸ نویسه باشد"}
#        if new == (body.get("current") or ""):
#            return {"ok": False, "message": "رمز تازه با رمز فعلی یکی است"}
#
#        self.store.set_password(user["id"], new)
#        THROTTLE.clear("pw:%d" % user["id"])
#        # Every other session ends. Changing a password is what somebody does
#        # when they think another person has their account, so leaving that
#        # person signed in would defeat the whole exercise.
#        kept = body.get("session")
#        self.store.run(
#            "DELETE FROM panel_sessions WHERE user_id = ? AND token != ?",
#            (user["id"], kept))
#        print("password changed for user %d" % user["id"], flush=True)
#        return {"ok": True,
#                "message": "رمز عوض شد. اگر جای دیگری وارد بودید، خارج شدید"}
#
#    def do_user_receipt(self, body):
#        """Store a photograph of a payment slip against the customer.
#
#        The relay reads the upload and passes the bytes here base64-encoded,
#        so the image lands in the same database as everything else and one
#        backup covers it. Nothing about the account changes: this records a
#        claim, and the operator decides what it is worth.
#        """
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#        if self._must_choose(user):
#            return self._must_choose(user)
#
#        kind = (body.get("content_type") or "").split(";")[0].strip().lower()
#        if kind not in ("image/jpeg", "image/png", "image/webp", "application/pdf"):
#            return {"ok": False,
#                    "message": "فقط عکس (JPG، PNG، WEBP) یا PDF قبول می‌شود"}
#        try:
#            blob = base64.b64decode(body.get("data") or "", validate=True)
#        except Exception:
#            return {"ok": False, "message": "فایل خراب بود، دوباره بفرستید"}
#        if not blob:
#            return {"ok": False, "message": "فایل خالی بود"}
#        if len(blob) > MAX_RECEIPT:
#            return {"ok": False, "message": "فایل بزرگ‌تر از %s است"
#                    % human(MAX_RECEIPT)}
#
#        # One pending receipt per customer. A second one replaces the first
#        # rather than queueing: somebody who sends three photographs of the
#        # same slip means the last one, and the operator should not have to
#        # work out which.
#        self.store.run(
#            "DELETE FROM transactions WHERE user_id = ? AND status = 'pending'",
#            (user["id"],))
#        try:
#            amount = max(0, int(body.get("amount") or 0))
#        except (TypeError, ValueError):
#            amount = 0
#        self.store.run(
#            "INSERT INTO transactions"
#            " (user_id, amount, kind, receipt_blob, receipt_type, note,"
#            "  status, created_at)"
#            " VALUES (?, ?, 'card', ?, ?, ?, 'pending', ?)",
#            (user["id"], amount, blob, kind,
#             (body.get("note") or "").strip()[:200], now()))
#        print("receipt from user %d: %s, %s"
#              % (user["id"], kind, human(len(blob))), flush=True)
#        return {"ok": True,
#                "message": "رسید فرستاده شد. پس از بررسی حسابتان شارژ می‌شود"}
#
#    def do_user_claim(self, body):
#        """Register the address the browser is coming from, for a user who is
#        already signed in - the 'my address changed' button."""
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#        if self._must_choose(user):
#            return self._must_choose(user)
#        ip = body.get("ip", "")
#        if not valid_ip(ip):
#            return {"ok": False, "message": "آی‌پی نامعتبر"}
#        return self.do_claim_register(user["id"], ip)
#
#    def do_claim_register(self, user_id, ip):
#        owner = self.store.one("SELECT user_id FROM ips WHERE ip = ?", (ip,))
#        if owner and owner["user_id"] != user_id:
#            return {"ok": False, "message": "این آی‌پی به حساب دیگری ثبت شده است"}
#        user = self.store.one("SELECT * FROM users WHERE id = ?", (user_id,))
#        existing = self.store.user_ips(user_id)
#        # One active address per account, with as many changes as they like.
#        # Replacing rather than adding is what makes that true.
#        if existing and len(existing) >= user["max_ips"]:
#            for old in existing[: len(existing) - user["max_ips"] + 1]:
#                self.store.run("DELETE FROM ips WHERE id = ?", (old["id"],))
#        self.store.run(
#            "INSERT OR REPLACE INTO ips (user_id, ip, added_at) VALUES (?, ?, ?)",
#            (user_id, ip, now()))
#        return {"ok": True, "message": "آی‌پی %s ثبت شد" % ip}
#
#    def do_user_info(self, body):
#        user = self._session_user(body.get("session"))
#        if not user:
#            return {"ok": False, "message": "نشست معتبر نیست"}
#        ips = self.store.user_ips(user["id"])
#        tpl = self.store.one("SELECT name FROM templates WHERE id = ?",
#                             (user["template_id"],)) if user["template_id"] else None
#        if not tpl:
#            tpl = self.store.one("SELECT name FROM templates WHERE is_default = 1")
#        return {
#            "ok": True,
#            "name": user["first_name"] or user["username"] or "",
#            "telegram_id": user["telegram_id"],
#            "ip": ips[0]["ip"] if ips else None,
#            "used": user["used_bytes"],
#            "quota": user["quota_bytes"],
#            "status": user["status"],
#            "wallet": user["wallet"],
#            "plan": tpl["name"] if tpl else "",
#            "renews": (user["quota_reset_at"] or "")[:10],
#            "expires": (user["expires_at"] or "")[:10],
#            "speed_kbps": user["speed_kbps"] or 0,
#            # Which warning thresholds this account has crossed. The relay's
#            # page turns this into the banner the bot used to send.
#            "warned": user["warned"] or 0,
#            "seen_ip": body.get("ip", ""),
#            "must_change": bool(user["must_change_password"]),
#        }
#
#
#def serve_api(cfg, store):
#    API.store = store
#    API.secret = cfg["SYNC_SECRET"]
#    # Comma separated, so one exit can serve several relays.
#    API.relays = tuple(x.strip() for x in cfg["RELAY_IP"].split(",") if x.strip())
#    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
#    ctx.load_cert_chain(CERT, KEY)
#    make_api_server(ctx).serve_forever()
#
#
#def make_api_server(ctx, port=None):
#    return TLSServer(("0.0.0.0", API_PORT if port is None else port), API, ctx)
#
#
#def watch_self(store):
#    """Sample this machine's own health.
#
#    The relays report theirs on the sync request, but nothing syncs *to* the
#    exit, so without this the machine running the panel would be the one host
#    missing from the panel.
#    """
#    health = Health()
#    while True:
#        try:
#            store.record_metrics("exit", health.sample())
#            store.prune_metrics()
#        except Exception as e:
#            log(WARN, "self health failed: %r" % e)
#        time.sleep(30)
#
#
#CATALOGUE = []
## A one-element list so the API thread sees updates without a global statement.
#DEFAULT_TEMPLATE = [0]
#
#
#def main():
#    global CATALOGUE
#    cfg = load_config()
#    os.makedirs(os.path.dirname(DB), exist_ok=True)
#    store = Store(DB)
#    CATALOGUE = load_catalogue() + [CUSTOM_SERVICE]
#    DEFAULT_TEMPLATE[0] = store.ensure_default_template(CATALOGUE)["id"]
#    print("catalogue: %d services, default template #%d"
#          % (len(CATALOGUE), DEFAULT_TEMPLATE[0]), flush=True)
#
#    threading.Thread(target=watch_self, args=(store,), daemon=True).start()
#
#    def bye(*_):
#        sys.exit(0)
#
#    signal.signal(signal.SIGTERM, bye)
#    signal.signal(signal.SIGINT, bye)
#    print("panel up: api on :%d" % API_PORT, flush=True)
#    # In the foreground now. The Telegram loop used to be what kept this
#    # process alive and the API rode along on a daemon thread behind it; with
#    # the bot gone the API is the whole job, so it holds the process itself.
#    serve_api(cfg, store)
#
#
#if __name__ == "__main__":
#    main()
#__END_PANEL__

#__BEGIN_PANEL_SERVICE__
#[Unit]
#Description=Smart DNS panel - database and sync API for the relays
#After=network-online.target
#Wants=network-online.target
#
#[Service]
#Type=simple
## Only the relays reach port 8443, from the RELAY_IP this panel reads. The +
## runs it outside the sandbox below, which firewall rules need; the - lets the
## panel start even where there is no nft.
#ExecStartPre=-+/usr/local/bin/smartdns-api-guard
#ExecStart=/usr/local/bin/smartdns-panel
#Restart=always
#RestartSec=10
## The bot token lives in panel.env, not in the unit and not in the script,
## because this repository is going to be public.
#EnvironmentFile=-/etc/smart-dns/panel.env
#NoNewPrivileges=yes
#ProtectSystem=strict
#ProtectHome=yes
#PrivateTmp=yes
#ReadWritePaths=/var/lib/smart-dns
#
#[Install]
#WantedBy=multi-user.target
#__END_PANEL_SERVICE__

#__BEGIN_SYNC__
##!/usr/bin/env python3
#"""smartdns-sync - the relay's half of the panel.
#
#Two jobs, one process:
#
#  * every 30 seconds, hand the exit node this relay's per-address byte
#    counters and take back who is allowed, on which resolver, at what speed
#  * serve the customer's panel - signing up, signing in, registering an
#    address, and seeing what is left of an allowance
#
#The panel has to live on the relay rather than on the exit, because the whole
#point of it is to learn the customer's address, and the only address that
#matters is the one they reach the service from. A page served in Frankfurt
#would see whatever their browser came out of.
#
#It listens outside the gated ports on purpose. The access control gate covers
#53, 80 and 443, so somebody whose address changed is cut off from the service
#but can still reach the one page that fixes it. Putting the panel on a gated
#port would have locked them out of the thing that unlocks them.
#
#The relay always dials out; nothing dials in. Standard library only.
#
#PANEL_HOST is not necessarily this relay's own exit node. The panel is a
#control plane: one database serves several relay/exit pairs, and each relay
#still carries its own traffic through its own exit.
#"""
#
#import base64
#import hashlib
#import hmac
#import html
#import http.client
#import http.cookies
#import http.server
#import ipaddress
#import json
#import os
#import re
#import ssl
#import subprocess
#import sys
#import threading
#import time
#import traceback
#import urllib.parse
#
#CONFIG = "/etc/smart-dns/sync.env"
#ACL = "/usr/local/bin/smartdns-acl"
#SHAPE = "/usr/local/bin/smartdns-shape"
#INTERVAL = 30
## The customer-facing panel, and the only port it is ever served on. Outside
## the gated ports (53, 80, 443) on purpose: somebody whose address changed is
## cut off from the service but must still be able to reach the one page that
## fixes it.
#PANEL_TLS_PORT = 8443
#
## A photograph of a bank slip, from a phone camera. The exit refuses anything
## past four megabytes, so there is no point carrying more than that up to it.
#MAX_RECEIPT = 4 * 1024 * 1024
#
#
#def load_config():
#    cfg = {}
#    with open(CONFIG) as fh:
#        for line in fh:
#            line = line.strip()
#            if not line or line.startswith("#") or "=" not in line:
#                continue
#            k, v = line.split("=", 1)
#            cfg[k.strip()] = v.strip().strip('"').strip("'")
#    for required in ("PANEL_HOST", "SYNC_SECRET", "SYNC_FINGERPRINT", "SELF_IP"):
#        if not cfg.get(required):
#            sys.exit("%s: %s is missing" % (CONFIG, required))
#    return cfg
#
#
#CFG = None
#
#
## ------------------------------------------------------------------ logging
## journald reads a leading <N> on a line as its syslog level. Warnings and
## errors carry one, so `journalctl -p warning` - which is what
## `smartdns-logs -e` runs - shows exactly the problems. Ordinary lines stay
## unmarked and land at info, as they always did. Before this everything
## landed at info, stderr included, and a failure looked like a heartbeat.
#INFO, WARN, ERROR = 6, 4, 3
## The visitor went away, or never finished saying hello. Not a fault here.
#GONE = (ConnectionError, TimeoutError, ssl.SSLError)
#
#
#def log(level, msg):
#    tag = "<%d>" % level if level < INFO else ""
#    for line in str(msg).splitlines() or [""]:
#        print(tag + line, flush=True)
#
#
#def log_exception(what):
#    """An error with its traceback, every line at error level. journald makes
#    each line its own entry, and at info all but the first would be lost
#    among the ordinary ones."""
#    log(ERROR, "%s\n%s" % (what, traceback.format_exc().rstrip()))
#
#
#def log_access(h, prefix, code, path, who=""):
#    """One line for one request: what was asked, the answer, how long it took
#    and who asked. Server errors at error level; everything else is info."""
#    try:
#        code = int(code)
#    except (TypeError, ValueError):
#        code = 0
#    ms = (time.monotonic() - getattr(h, "_t0", time.monotonic())) * 1000
#    # 501 is a scanner's GET to a POST-only port: the visitor's mistake.
#    log(ERROR if code >= 500 and code != 501 else INFO, "%s %s %s %d %dms from %s%s" % (
#        prefix, getattr(h, "command", None) or "-", path, code, ms,
#        h.client_address[0], " " + who if who else ""))
#
#
#def sync_sni():
#    """The name to put in the TLS handshake with the exit, which has none.
#
#    The relay dials the exit by address, and Python sends no name in TLS for
#    an address. Filtering between Iran and some exits resets exactly those
#    handshakes: measured from a live relay to a Hetzner exit, a handshake with
#    no name was reset every time, and one carrying any name at all - the
#    relay's own domain, sync.example.com, smartdns.invalid - got through every
#    time. From outside Iran both worked. Sync and the customer panel both went
#    down with "connection reset by peer" while the proxy on 443, which always
#    carries the customer's name, was fine.
#
#    The name decides nothing here: the exit's certificate is checked against
#    its fingerprint, not against a name. So it is the operator's own domain
#    when there is one, a harmless placeholder when there is not, and SYNC_SNI
#    in sync.env if a network ever needs something else.
#    """
#    return (CFG.get("SYNC_SNI") or CFG.get("PANEL_DOMAIN")
#            or "sync.example.com")
#
#
#class NamedHTTPS(http.client.HTTPSConnection):
#    """HTTPS to an address, with a name in the handshake anyway."""
#
#    def __init__(self, host, port, sni, **kw):
#        super().__init__(host, port, **kw)
#        self.sni = sni
#
#    def connect(self):
#        http.client.HTTPConnection.connect(self)       # the TCP part only
#        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.sni)
#
#
#def post(path, payload):
#    """POST JSON to the exit's API, pinned to its certificate.
#
#    The exit's certificate is self-signed - there is no domain on it and no CA
#    to check it against - so ordinary verification is turned off and replaced
#    with a fingerprint comparison. That is stricter than a public CA would be,
#    not weaker: exactly one certificate is accepted, and the secret is never
#    sent until it matches.
#    """
#    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
#    ctx.check_hostname = False
#    ctx.verify_mode = ssl.CERT_NONE
#    conn = NamedHTTPS(CFG["PANEL_HOST"], 8443, sync_sni(), timeout=25, context=ctx)
#    try:
#        conn.connect()
#        seen = hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest()
#        if not hmac.compare_digest(seen, CFG["SYNC_FINGERPRINT"].lower()):
#            raise RuntimeError(
#                "certificate fingerprint mismatch - refusing to send anything.\n"
#                "  expected %s\n  got      %s" % (CFG["SYNC_FINGERPRINT"], seen)
#            )
#        body = json.dumps(payload)
#        conn.request(
#            "POST", path, body,
#            {"Content-Type": "application/json",
#             "Authorization": "Bearer " + CFG["SYNC_SECRET"]},
#        )
#        res = conn.getresponse()
#        data = json.loads(res.read() or b"{}")
#        if res.status != 200:
#            raise RuntimeError("exit returned %d: %s" % (res.status, data))
#        return data
#    finally:
#        conn.close()
#
#
## ------------------------------------------------------------------ health
#class Health:
#    """Host metrics, read straight out of /proc.
#
#    CPU and network are rates, which means they only exist relative to a
#    previous reading - so the first sample after start reports no rate rather
#    than a meaningless one computed against zero. The sync loop runs every
#    thirty seconds, which is the interval these end up averaged over.
#    """
#
#    def __init__(self):
#        self.cpu = None
#        self.net = None
#
#    @staticmethod
#    def _meminfo():
#        out = {}
#        with open("/proc/meminfo") as fh:
#            for line in fh:
#                k, _, v = line.partition(":")
#                out[k] = int(v.split()[0]) * 1024      # kB -> bytes
#        return out
#
#    def _cpu_percent(self):
#        with open("/proc/stat") as fh:
#            parts = [int(x) for x in fh.readline().split()[1:]]
#        idle, total = parts[3] + parts[4], sum(parts)
#        prev, self.cpu = self.cpu, (idle, total)
#        if not prev:
#            return None
#        d_total = total - prev[1]
#        if d_total <= 0:
#            return None
#        return round(100.0 * (1 - (idle - prev[0]) / d_total), 1)
#
#    def _net_rates(self):
#        rx = tx = 0
#        with open("/proc/net/dev") as fh:
#            for line in fh.readlines()[2:]:
#                name, _, rest = line.partition(":")
#                if name.strip() == "lo":
#                    continue
#                f = rest.split()
#                rx += int(f[0]); tx += int(f[8])
#        now = time.time()
#        prev, self.net = self.net, (rx, tx, now)
#        if not prev:
#            return None, None
#        dt = now - prev[2]
#        if dt <= 0:
#            return None, None
#        return int((rx - prev[0]) / dt), int((tx - prev[1]) / dt)
#
#    def sample(self):
#        m = self._meminfo()
#        rx, tx = self._net_rates()
#        st = os.statvfs("/")
#        with open("/proc/uptime") as fh:
#            uptime = int(float(fh.readline().split()[0]))
#        with open("/proc/loadavg") as fh:
#            load = float(fh.readline().split()[0])
#        swap_total = m.get("SwapTotal", 0)
#        return {
#            "cpu": self._cpu_percent(),
#            "load": load,
#            "mem_total": m.get("MemTotal", 0),
#            # MemAvailable is what the kernel thinks is really obtainable, which
#            # is the number that matters; MemFree ignores reclaimable cache and
#            # makes a healthy box look nearly out of memory.
#            "mem_used": m.get("MemTotal", 0) - m.get("MemAvailable", 0),
#            # Reported as zero-total when the host has no swap, so the panel can
#            # leave the row out rather than drawing an empty gauge.
#            "swap_total": swap_total,
#            "swap_used": swap_total - m.get("SwapFree", 0) if swap_total else 0,
#            "disk_total": st.f_blocks * st.f_frsize,
#            "disk_used": (st.f_blocks - st.f_bfree) * st.f_frsize,
#            "rx_bps": rx,
#            "tx_bps": tx,
#            "uptime": uptime,
#        }
#
#
## ---------------------------------------------------------------- profiles
#PROFILE_DIR = "/etc/smartdns-profiles"
#PROFILE_BASE_PORT = 5300
#NAT_TABLE = "smartdns_nat"
#
#
#def sh(*args):
#    return subprocess.run(list(args), capture_output=True, text=True, timeout=60)
#
#
#def nft(*args):
#    return sh("/usr/sbin/nft", *args)
#
#
#CUSTOM_CONF = "/etc/dnsmasq.d/50-smartdns-custom.conf"
## The names the installer keeps out of the hijack: EA's game servers, the
## console STUN hosts, Epic's backend, core.windows.net. The main resolver
## reads this file and always will; the profiles must not, because whether
## each of those is routed is now a tick in a template, and a rule sitting in
## a shared file would outrank the tick.
#BYPASS_CONF = "/etc/dnsmasq.d/bypass.conf"
## The hijack list itself - every domain the service routes. The resolver on
## :53 reads it and always will: that one serves the default template, which
## means "everything". The profiles must not, because which of those names a
## template routes is a tick in the panel, and a rule in a file every resolver
## reads cannot be taken back by a rule in one that does not. Both would name
## the same host, dnsmasq's longest match would tie, and address= would win.
#HIJACK_CONF = "/etc/dnsmasq.d/smart-dns.conf"
## What the profile resolvers read instead of /etc/dnsmasq.d. Same files, minus
## the ones decided per template - a profile that does not route something must
## not find a rule for it at all.
#BASE_DIR = "/etc/smartdns-base"
## The main resolver's config directory. A name rather than a literal so a test
## can lay a relay out somewhere else.
#DNSMASQ_D = "/etc/dnsmasq.d"
#
#
#EPIC_PINS = "/etc/dnsmasq.d/epic-pins.conf"
#
## The templates' names, as the panel knows them. Only smartdns-rules reads this
## - the resolvers go by number - but "test" means something to an operator
## where "profile 2" does not.
#TEMPLATE_NAMES = "/var/lib/smart-dns/templates.json"
#
#
#def save_template_names(info):
#    """Keep the names the panel sent. Returns whether the file changed."""
#    if not isinstance(info, dict) or not isinstance(info.get("names"), dict):
#        return False      # an older panel, which does not send them
#    text = json.dumps({"default": info.get("default"), "names": info["names"]},
#                      ensure_ascii=False, sort_keys=True) + "\n"
#    try:
#        with open(TEMPLATE_NAMES, encoding="utf-8") as fh:
#            if fh.read() == text:
#                return False
#    except OSError:
#        pass
#    os.makedirs(os.path.dirname(TEMPLATE_NAMES), exist_ok=True)
#    tmp = TEMPLATE_NAMES + ".tmp"
#    with open(tmp, "w", encoding="utf-8") as fh:
#        fh.write(text)
#    os.replace(tmp, TEMPLATE_NAMES)
#    return True
#
#
## What the operator wants written under the sign-in form, so a customer who
## has forgotten their password knows whom to ask.
#SUPPORT_FILE = "/var/lib/smart-dns/support.json"
#
#
#def save_support(value):
#    """Keep the support contact the panel sent. Returns whether it changed."""
#    if value is None:
#        return False      # an older panel, which does not send one
#    text = json.dumps({"contact": str(value)[:64]}, ensure_ascii=False) + "\n"
#    try:
#        with open(SUPPORT_FILE, encoding="utf-8") as fh:
#            if fh.read() == text:
#                return False
#    except OSError:
#        pass
#    os.makedirs(os.path.dirname(SUPPORT_FILE), exist_ok=True)
#    tmp = SUPPORT_FILE + ".tmp"
#    with open(tmp, "w", encoding="utf-8") as fh:
#        fh.write(text)
#    os.replace(tmp, SUPPORT_FILE)
#    return True
#
#
#def support_contact():
#    try:
#        with open(SUPPORT_FILE, encoding="utf-8") as fh:
#            return str(json.load(fh).get("contact") or "")[:64]
#    except (OSError, ValueError, AttributeError):
#        return ""
#
#
## Who each allowed address belongs to, as the panel knows them. Only
## smartdns-watch reads it, to take a username where an address would do.
#USER_NAMES = "/var/lib/smart-dns/users.json"
#
#
#def save_user_names(allowed):
#    """Keep who each allowed address belongs to. Returns whether it changed.
#
#    Readable by root alone: it ties usernames to home addresses.
#    """
#    rows = {a["ip"]: {"label": a.get("name", ""), "user": a.get("user", "")}
#            for a in allowed or [] if isinstance(a, dict) and a.get("ip")}
#    text = json.dumps(rows, ensure_ascii=False, sort_keys=True) + "\n"
#    try:
#        with open(USER_NAMES, encoding="utf-8") as fh:
#            if fh.read() == text:
#                return False
#    except OSError:
#        pass
#    os.makedirs(os.path.dirname(USER_NAMES), exist_ok=True)
#    tmp = USER_NAMES + ".tmp"
#    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
#    with os.fdopen(fd, "w", encoding="utf-8") as fh:
#        fh.write(text)
#    os.replace(tmp, USER_NAMES)
#    return True
#
#
#def epic_pin_lines():
#    """epic-pin's rules, to be written into the profiles that still want them.
#
#    Read rather than symlinked, because they are the one thing a profile may
#    need to be without: they name exact hosts, so they outrank any rule that
#    routes the parent domain, and a template that has chosen to route Epic's
#    backend has to be able to actually do it.
#    """
#    try:
#        with open(EPIC_PINS) as fh:
#            return [l.rstrip("\n") for l in fh
#                    if l.startswith("address=") or l.startswith("server=")]
#    except OSError:
#        return []
#
#
#def sync_base_dir():
#    """Keep BASE_DIR mirroring /etc/dnsmasq.d, minus two files.
#
#    Symlinks rather than copies, so `smartdns add` still reaches every
#    resolver on the machine without knowing this directory exists. Three files
#    are left out - the operator's own domains, epic-pin's pins, and the
#    bypass list - because each is decided per template, and absence is the
#    only mechanism that works when the rules would otherwise name the same
#    host. The panel sends every bypass this profile needs, so nothing is lost
#    by not linking the file.
#    """
#    os.makedirs(BASE_DIR, exist_ok=True)
#    want = {f for f in os.listdir(DNSMASQ_D)
#            if f.endswith(".conf")
#            and f not in (os.path.basename(CUSTOM_CONF),
#                          os.path.basename(EPIC_PINS),
#                          os.path.basename(BYPASS_CONF),
#                          os.path.basename(HIJACK_CONF))}
#    have = set(os.listdir(BASE_DIR))
#    changed = False
#    for f in want - have:
#        os.symlink(os.path.join(DNSMASQ_D, f), os.path.join(BASE_DIR, f))
#        changed = True
#    for f in have - want:
#        os.unlink(os.path.join(BASE_DIR, f))
#        changed = True
#    return changed
#
#
#RULE_LINE = re.compile(r"^(address|server|local)=/(.+)/([^/]*)$")
#
#
#def base_settings():
#    """The main resolver's settings, less its rules, for the profiles to share.
#
#    They sit in the same file as the hijack list - the upstream servers,
#    no-resolv, the cache, the addresses to listen on - and that is a file the
#    profiles must not read. Leaving it out took the settings with it: a
#    template's resolver fell back to /etc/resolv.conf for its upstreams and to
#    dnsmasq's default cache of 150 names, over the slowest link there is. So
#    the settings are copied across and only the rules stay behind.
#    """
#    try:
#        with open(HIJACK_CONF) as fh:
#            lines = [l.strip() for l in fh]
#    except OSError:
#        return []
#    return [l for l in lines
#            if l and not l.startswith("#") and not RULE_LINE.match(l)]
#
#
#def rule_sets(text, me):
#    """What one resolver's config routes, bypasses and pins, as sets."""
#    out = {"routes": set(), "bypasses": set(), "pins": set()}
#    for line in (text or "").splitlines():
#        m = RULE_LINE.match(line.strip())
#        if not m:
#            continue
#        kind, domains, target = m.groups()
#        for d in filter(None, domains.split("/")):
#            if kind != "address":
#                out["bypasses"].add(d)
#            elif target == me:
#                out["routes"].add(d)
#            else:
#                # With its address, so a pin moving somewhere new shows up as
#                # the change it is rather than as nothing.
#                out["pins"].add("%s=%s" % (d, target))
#    return out
#
#
#def signed(names, sign, limit=15):
#    out = [sign + n for n in names[:limit]]
#    if len(names) > limit:
#        out.append("(%s%d more)" % (sign, len(names) - limit))
#    return out
#
#
#def describe_change(old_text, new_text, me):
#    """What changed between two versions of a resolver's rules, in one line:
#    each name that started or stopped being routed, bypassed or pinned.
#
#    This is the record of why a name went where it went. A count said that
#    something changed; it could not say that gemini.google.com stopped going
#    through the relay at 14:02, which is the question an operator is asking.
#    """
#    new = rule_sets(new_text, me)
#    if old_text is None:
#        return "routes %d, bypasses %d, pins %d" % (
#            len(new["routes"]), len(new["bypasses"]), len(new["pins"]))
#    old = rule_sets(old_text, me)
#    parts = []
#    for key in ("routes", "bypasses", "pins"):
#        plus, minus = sorted(new[key] - old[key]), sorted(old[key] - new[key])
#        if plus or minus:
#            parts.append("%s %s" % (key, " ".join(signed(plus, "+") + signed(minus, "-"))))
#    return "; ".join(parts) or "settings only"
#
#
#def template_label(key, names):
#    name = (names or {}).get(str(key))
#    return "template %s (%s)" % (key, name) if name else "template %s" % key
#
#
#def apply_custom_domains(domains):
#    """Route the domains the operator added in the panel.
#
#    Written into /etc/dnsmasq.d, which every resolver on this machine reads -
#    the main one and each profile - so one entry in the panel reaches every
#    plan. Returns whether anything changed, because dnsmasq cannot reload its
#    config: it has to be restarted, and restarting it on every sync would be a
#    DNS outage twice a minute.
#    """
#    self_ip = CFG.get("SELF_IP") or ""
#    body = ["# Domains added by the operator in the panel. Generated by",
#            "# smartdns-sync from the panel's database - edit it there, not here."]
#    body += ["address=/%s/%s" % (d, self_ip) for d in sorted(set(domains))]
#    text = "\n".join(body) + "\n"
#
#    current = None
#    if os.path.exists(CUSTOM_CONF):
#        with open(CUSTOM_CONF) as fh:
#            current = fh.read()
#    if current == text or (not domains and current is None):
#        return False
#
#    with open(CUSTOM_CONF, "w") as fh:
#        fh.write(text)
#    # Check before restarting. A bad line here takes DNS down for everyone on
#    # this relay, and dnsmasq refuses to start rather than skipping it.
#    if sh("/usr/sbin/dnsmasq", "--test", "-C", "/etc/dnsmasq.conf").returncode != 0:
#        if current is None:
#            os.unlink(CUSTOM_CONF)
#        else:
#            with open(CUSTOM_CONF, "w") as fh:
#                fh.write(current)
#        log(ERROR, "custom domains rejected by dnsmasq - reverted")
#        return False
#    sh("systemctl", "restart", "dnsmasq")
#    old, new = rule_sets(current, self_ip)["routes"], set(domains)
#    print("custom domains: %s (now %d)"
#          % (" ".join(signed(sorted(new - old), "+") + signed(sorted(old - new), "-"))
#             or "rewritten", len(new)), flush=True)
#    return True
#
#
#KNOWN_NAMES = {}
#
#
#def apply_profiles(profiles, assignment, restart=False, names=None):
#    """Give each template its own resolver, and point each address at one.
#
#    dnsmasq cannot answer differently per client, so the split is done with one
#    instance per profile on its own port plus an nftables redirect keyed on the
#    source address. Customers all use the same DNS address; the kernel decides
#    which instance actually answers them.
#
#    A profile whose template routes everything gets no instance: that is what
#    the main resolver on port 53 already does, and every address not named in a
#    redirect falls through to it.
#    """
#    # A name outlives its template in the log: one deleted in the panel is no
#    # longer in what the panel sends, but its retirement should still say which.
#    KNOWN_NAMES.update(names or {})
#    names = KNOWN_NAMES
#    os.makedirs(PROFILE_DIR, exist_ok=True)
#    if sync_base_dir():
#        restart = True
#    ports = {}
#    for i, key in enumerate(sorted(profiles)):
#        ports[key] = PROFILE_BASE_PORT + i
#
#    # Read once: every profile that wants them gets the same lines.
#    epic_pins = epic_pin_lines()
#    settings = base_settings()
#
#    wanted_units = set()
#    for key, spec in sorted(profiles.items()):
#        port = ports[key]
#        body = ["# generated by smartdns-sync - do not edit",
#                "port=%d" % port]
#        body += settings
#        # The operator's own domains, listed only for templates that route
#        # them. They cannot be un-routed by rule the way a service can: both
#        # rules would name the same host and dnsmasq prefers the address= one.
#        # So absence is the mechanism, which is why this resolver reads
#        # BASE_DIR rather than /etc/dnsmasq.d.
#        # What this template routes, written here rather than inherited.
#        # Everything not in this list simply has no rule in this resolver, so
#        # it resolves normally and the client goes straight to it - which is
#        # what an un-ticked service is supposed to mean.
#        me = CFG.get("SELF_IP") or ""
#        body += ["address=/%s/%s" % (d, me)
#                 for d in sorted(set(spec.get("routed") or []))]
#        body += ["address=/%s/%s" % (d, me)
#                 for d in sorted(set(spec.get("custom") or []))]
#        # Names whose parent this profile routes, that it must not route
#        # itself - gosredirector.ea.com under a routed ea.com, say. Here the
#        # subtraction does work: the profile's rule names a longer host than
#        # the one hijacking the parent, so longest match prefers it.
#        body += ["server=/%s/1.1.1.1" % d for d in spec.get("bypass", [])]
#        # Epic's pins, unless this template asked to route that backend. They
#        # come last and are address= rules, so where they appear they win -
#        # which is the point: a bypass sends the name to a public resolver,
#        # while a pin sends it to an address checked to answer from here.
#        if spec.get("pins", True):
#            body += epic_pins
#        conf = os.path.join(PROFILE_DIR, "%s.conf" % key)
#        text = "\n".join(body) + "\n"
#        old = None
#        if os.path.exists(conf):
#            with open(conf) as fh:
#                old = fh.read()
#        changed = old != text
#        if changed:
#            with open(conf, "w") as fh:
#                fh.write(text)
#        unit = "smartdns-dns@%s" % key
#        wanted_units.add(unit)
#        active = sh("systemctl", "is-active", unit).stdout.strip() == "active"
#        # `restart` is set when the shared /etc/dnsmasq.d changed underneath
#        # us: these instances read it too, and dnsmasq only picks up config at
#        # startup, so without this a new domain would reach the default plan
#        # and silently miss everybody on a template.
#        if changed or not active or restart:
#            sh("systemctl", "restart", unit)
#            why = (describe_change(old, text, me) if changed
#                   else "was not running" if not active
#                   else "shared config changed")
#            print("%s on port %d restarted - %s"
#                  % (template_label(key, names), port, why), flush=True)
#
#    # Stop resolvers for profiles nobody is on any more, and delete their
#    # config, so a template an admin removed does not linger as a process.
#    running = sh("systemctl", "list-units", "--no-legend", "--plain",
#                 "smartdns-dns@*.service").stdout
#    for line in running.splitlines():
#        unit = line.split()[0].replace(".service", "") if line.split() else ""
#        if unit and unit not in wanted_units:
#            sh("systemctl", "stop", unit)
#            key = unit.split("@", 1)[1]
#            try:
#                os.remove(os.path.join(PROFILE_DIR, "%s.conf" % key))
#            except OSError:
#                pass
#            print("%s retired - nobody is on it" % template_label(key, names),
#                  flush=True)
#
#    apply_redirects(ports, assignment, names)
#
#
## Who was on which template at the last sync, so a move is logged once rather
## than every thirty seconds. None until the first pass has looked.
#LAST_ASSIGNMENT = None
#
#
#def apply_redirects(ports, assignment, names=None):
#    """Point each address at its profile's resolver, with one nftables set per
#    profile and a redirect rule per set."""
#    global LAST_ASSIGNMENT
#    if nft("list", "table", "ip", NAT_TABLE).returncode != 0:
#        nft("add", "table", "ip", NAT_TABLE)
#    nft("add", "chain", "ip", NAT_TABLE, "pre",
#        "{ type nat hook prerouting priority dstnat ; policy accept ; }")
#    # Rebuilt from scratch each time rather than diffed: the whole chain is a
#    # handful of rules, and a rule left behind here would send a customer to
#    # the wrong resolver silently.
#    nft("flush", "chain", "ip", NAT_TABLE, "pre")
#
#    for key, port in sorted(ports.items()):
#        setname = "prof_%s" % key
#        nft("add", "set", "ip", NAT_TABLE, setname, "{ type ipv4_addr ; }")
#        nft("flush", "set", "ip", NAT_TABLE, setname)
#        members = [ip for ip, prof in assignment.items() if prof == key]
#        if members:
#            nft("add", "element", "ip", NAT_TABLE, setname,
#                "{ %s }" % ", ".join(members))
#            nft("add", "rule", "ip", NAT_TABLE, "pre",
#                "ip saddr @%s udp dport 53 redirect to :%d" % (setname, port))
#            nft("add", "rule", "ip", NAT_TABLE, "pre",
#                "ip saddr @%s tcp dport 53 redirect to :%d" % (setname, port))
#
#    # Sets no rule points at any more - a template that lost its last customer.
#    # Harmless left behind, but misleading: they go on listing addresses that
#    # the default resolver is really answering.
#    # The whole table, not `list sets ip <table>`: nft takes only a family
#    # there, refuses the table name, and the cleanup silently did nothing.
#    listed = nft("list", "table", "ip", NAT_TABLE)
#    for setname in re.findall(r"set (prof_\S+) \{", listed.stdout or ""):
#        if setname[len("prof_"):] not in ports:
#            nft("delete", "set", "ip", NAT_TABLE, setname)
#
#    now = {ip: prof for ip, prof in assignment.items() if prof in ports}
#    if LAST_ASSIGNMENT is not None:
#        for ip in sorted(set(now) | set(LAST_ASSIGNMENT)):
#            was, got = LAST_ASSIGNMENT.get(ip), now.get(ip)
#            if was == got:
#                continue
#            if got:
#                print("%s now on %s" % (ip, template_label(got, names)), flush=True)
#            else:
#                print("%s left %s" % (ip, template_label(was, names)), flush=True)
#    LAST_ASSIGNMENT = now
#
#
#def acl(*args):
#    return subprocess.run(
#        [ACL] + list(args), capture_output=True, text=True, timeout=30
#    )
#
#
#def current_state():
#    out = acl("list", "--json")
#    if out.returncode != 0:
#        raise RuntimeError("smartdns-acl list failed: %s" % out.stderr.strip())
#    return json.loads(out.stdout or "[]")
#
#
#HEALTH = Health()
#
## What the shaper was last told. Speeds change about as often as somebody buys
## a plan, and re-running tc every thirty seconds for no reason would be thirty
## subprocesses a minute to arrive at the state already in the kernel.
#SHAPED = None
#
#
#def apply_speeds(allowed):
#    """Hand the wanted speed limits to smartdns-shape, when they have changed.
#
#    A customer with no limit is left out entirely rather than sent as zero, so
#    the shaper's job is exactly "these are the limited ones" and an account
#    going back to unlimited removes its class rather than setting it huge.
#    """
#    global SHAPED
#    wanted = sorted(
#        ({"ip": a["ip"], "mark": int(a["uid"]), "kbps": int(a.get("kbps") or 0)}
#         for a in allowed if a.get("uid") and int(a.get("kbps") or 0) > 0),
#        key=lambda w: w["mark"])
#    if wanted == SHAPED:
#        return
#    if not os.path.exists(SHAPE):
#        # An older relay that has not been upgraded yet. Say so once rather
#        # than every half minute, and carry on - unshaped is the old
#        # behaviour, not a broken one.
#        if SHAPED is None:
#            log(WARN, "%s is missing - speed limits will not be applied" % SHAPE)
#        SHAPED = wanted
#        return
#    r = subprocess.run([SHAPE, "apply"], input=json.dumps(wanted),
#                       capture_output=True, text=True, timeout=60)
#    if r.returncode != 0:
#        # Leave SHAPED alone so the next pass tries again.
#        log(ERROR, "shaping failed: %s" % r.stderr.strip())
#        return
#    if r.stdout.strip():
#        print(r.stdout.strip(), flush=True)
#    SHAPED = wanted
#
#
#AUTO_ENFORCE = "/etc/smart-dns/auto-enforce"
#
#
#def close_relay_when_ready(allowed_count):
#    """Switch access control on once there is somebody to allow.
#
#    The installer cannot make this call itself: a relay is installed before it
#    has a single registered address, and enforcing against an empty allowlist
#    cuts off everyone including the operator. So the installer leaves a note
#    saying what it wants, and this closes the door at the first sync that
#    brings an address.
#
#    Runs once. `smartdns-acl enforce off` deletes the note, so an operator who
#    deliberately opens the relay does not find it shut again thirty seconds
#    later.
#    """
#    if allowed_count <= 0 or not os.path.exists(AUTO_ENFORCE):
#        return
#    state = subprocess.run([ACL, "enforce", "status"], capture_output=True,
#                           text=True, timeout=30)
#    if "enforcing" in (state.stdout or ""):
#        os.unlink(AUTO_ENFORCE)      # already closed; nothing left to do
#        return
#    r = subprocess.run([ACL, "enforce", "on", "--yes"], capture_output=True,
#                       text=True, timeout=30)
#    if r.returncode != 0:
#        # Most likely the allowlist is still empty in the kernel because this
#        # is the pass that is about to fill it. Leave the note and try again
#        # on the next sync rather than reporting a problem that is not one.
#        return
#    os.unlink(AUTO_ENFORCE)
#    print("access control on: %d address(es) may use this relay"
#          % allowed_count, flush=True)
#
#
#def sync_once():
#    rows = current_state()
#    counters = {r["ip"]: r["total"] for r in rows}
#    # Metrics ride along on a request that was happening anyway - no second
#    # connection, no second schedule, and they arrive stamped with the same
#    # moment as the usage they sit beside.
#    try:
#        host = HEALTH.sample()
#    except Exception as e:
#        host = {"error": str(e)}
#    answer = post("/sync", {"counters": counters, "host": host})
#    try:
#        save_template_names(answer.get("templates"))
#    except Exception as e:
#        log(WARN, "template names not saved: %s" % e)
#    try:
#        save_user_names(answer.get("allowed"))
#    except Exception as e:
#        log(WARN, "user names not saved: %s" % e)
#    try:
#        save_support(answer.get("support"))
#    except Exception as e:
#        log(WARN, "support contact not saved: %s" % e)
#
#    names = {a["ip"]: a.get("name", "") for a in answer.get("allowed", [])}
#    want = set(names)
#    have = {r["ip"] for r in rows}
#
#    # Which resolver each address should be answered by. Applied before the
#    # allowlist below, so an address is pointed at the right resolver no later
#    # than the moment it is let in.
#    try:
#        changed = apply_custom_domains(answer.get("extra_domains") or [])
#        assignment = {a["ip"]: a.get("profile", "")
#                      for a in answer.get("allowed", []) if a.get("profile")}
#        apply_profiles(answer.get("profiles") or {}, assignment, restart=changed,
#                       names=(answer.get("templates") or {}).get("names"))
#    except Exception as e:
#        log_exception("profiles failed: %s" % e)
#
#    try:
#        apply_speeds(answer.get("allowed") or [])
#    except Exception as e:
#        log_exception("speeds failed: %s" % e)
#
#    for ip in sorted(want - have):
#        r = acl("add", ip, names[ip]) if names[ip] else acl("add", ip)
#        log(INFO if r.returncode == 0 else ERROR, "added %s%s" % (
#            ip, "" if r.returncode == 0 else " FAILED: " + r.stderr.strip()))
#    for ip in sorted(have - want):
#        r = acl("del", ip)
#        log(INFO if r.returncode == 0 else ERROR, "removed %s%s" % (
#            ip, "" if r.returncode == 0 else " FAILED: " + r.stderr.strip()))
#
#    # After the set is filled, not before: enforcing while the kernel list is
#    # still empty is refused, and would leave the relay open for another cycle.
#    close_relay_when_ready(len(want))
#    return len(want), len(want - have), len(have - want)
#
#
#def sync_loop():
#    fails = 0
#    while True:
#        try:
#            total, added, removed = sync_once()
#            if added or removed:
#                print("sync: %d allowed (+%d -%d)" % (total, added, removed), flush=True)
#            fails = 0
#        except Exception as e:
#            fails += 1
#            # Noisy for the first few, then quiet: if the exit is down for an
#            # hour the journal should not be mostly this message. The allowlist
#            # already in the kernel keeps working throughout - a sync outage
#            # must never cut off paying users.
#            if fails <= 3 or fails % 20 == 0:
#                # A warning while it could be a blip on the link; an error
#                # once it has gone on long enough to be an outage.
#                log(WARN if fails < 3 else ERROR, "sync failed (%d): %s" % (fails, e))
#        time.sleep(INTERVAL)
#
#
## ------------------------------------------------------------- user panel
## Every colour is named once, here, with the admin panel's names and values.
## The light theme is the same names with other values, so no rule below can
## be left dark in one of them. Until the customer picks, their browser's own
## setting decides; the button in the corner overrides it for that browser.
#DARK = """color-scheme:dark;
# --bg:#0f1115;--card:#171a21;--line:#262b36;--line2:#30363d;--row:#1c2029;
# --track:#0f1115;--fg:#e6e8eb;--head:#c9d1d9;--muted:#8b949e;--dim:#9aa4b2;
# --faint:#6e7681;--accent:#7dd3a0;--accent2:#58a6ff;--btn:#238636;
# --btn-hover:#2ea043;--on-btn:#ffffff;--danger:#6e2c2c;--warn:#e3b341;
# --bad:#f85149;--good-bg:#12261a;--err-bg:#2b1416;--warn-bg:#2b2411;
# --warn-line:#6e5a2c;--sun:inline;--moon:none"""
#LIGHT = """color-scheme:light;
# --bg:#f6f8fa;--card:#ffffff;--line:#d0d7de;--line2:#afb8c1;--row:#eaeef2;
# --track:#eaeef2;--fg:#1f2328;--head:#24292f;--muted:#59636e;--dim:#57606a;
# --faint:#6e7781;--accent:#1a7f37;--accent2:#0969da;--btn:#1f883d;
# --btn-hover:#1a7f37;--on-btn:#ffffff;--danger:#cf222e;--warn:#9a6700;
# --bad:#cf222e;--good-bg:#dafbe1;--err-bg:#ffebe9;--warn-bg:#fff8c5;
# --warn-line:#d4a72c;--sun:none;--moon:inline"""
#THEME_CSS = (":root{%s}\n"
#             "@media (prefers-color-scheme: light){:root:not([data-theme=dark]){%s}}\n"
#             ":root[data-theme=light]{%s}\n" % (DARK, LIGHT, LIGHT))
## In <head>, so a page opens in the chosen theme instead of flashing the
## other one first. Only the two known values are taken from storage.
#THEME_HEAD = ("<script>try{var t=localStorage.getItem('theme');"
#              "if(t=='light'||t=='dark')document.documentElement"
#              ".setAttribute('data-theme',t)}catch(e){}</script>")
#THEME_BUTTON = (
#    "<button type='button' class='theme' title='روشن / تیره' aria-label='روشن / تیره'"
#    " onclick=\"(function(r){var c=r.getAttribute('data-theme')||"
#    "(matchMedia('(prefers-color-scheme: light)').matches?'light':'dark'),"
#    "n=c=='light'?'dark':'light';r.setAttribute('data-theme',n);"
#    "try{localStorage.setItem('theme',n)}catch(e){}})(document.documentElement)\">"
#    "<span class='sun'>☀️</span><span class='moon'>🌙</span></button>")
#
## Vazirmatn, served by this panel: every font host worth using is blocked or
## slow from Iran. swap: the page is readable in the system font at once, on a
## slow line, and changes over when the font arrives. The version goes in the
## address, so a browser's kept copy is never stale.
#FONT_FILE = "/usr/local/share/smart-dns/Vazirmatn.woff2"
#FONT_VERSION = "33.0.3"
#FONT_FACE = ("@font-face{font-family:Vazirmatn;font-weight:100 900;"
#             "font-display:swap;src:url('/vazirmatn.woff2?v=%s') format('woff2')}\n"
#             % FONT_VERSION)
#_FONT = []
#
#
#def font_bytes():
#    """The font file, read once; None while it is not there."""
#    if not _FONT:
#        try:
#            with open(FONT_FILE, "rb") as fh:
#                _FONT.append(fh.read())
#        except OSError:
#            return None
#    return _FONT[0]
#
#
#USER_CSS = THEME_CSS + FONT_FACE + """
#*{box-sizing:border-box}
#body{margin:0;background:var(--bg);color:var(--fg);
# font:15px/1.9 Vazirmatn,system-ui,'Segoe UI',Tahoma,sans-serif;position:relative;
# display:flex;align-items:center;justify-content:center;min-height:100vh;padding:20px}
#.card{background:var(--card);border:1px solid var(--line);border-radius:16px;
# padding:26px;max-width:440px;width:100%}
#h1{font-size:18px;margin:0 0 4px;font-weight:600}
#.sub{color:var(--muted);font-size:13px;margin-bottom:20px}
#.row{display:flex;justify-content:space-between;align-items:baseline;
# padding:11px 0;border-bottom:1px solid var(--row)}
#.row:last-of-type{border-bottom:0}
#.k{color:var(--muted);font-size:13px}
#.v{font-weight:600}
#code{background:var(--bg);padding:3px 9px;border-radius:6px;color:var(--accent);font-size:14px}
#.bar{height:8px;background:var(--track);border-radius:4px;overflow:hidden;margin-top:10px}
#.bar i{display:block;height:100%;background:var(--accent)}
#.bar i.warn{background:var(--warn)}
#.bar i.hot{background:var(--bad)}
#button,a.btn{display:block;width:100%;margin-top:18px;padding:13px;font:inherit;
# font-weight:600;text-align:center;text-decoration:none;
# background:var(--btn);color:var(--on-btn);border:0;border-radius:10px;cursor:pointer}
#button:hover,a.btn:hover{background:var(--btn-hover)}
#button.ghost,a.btn.ghost{background:transparent;border:1px solid var(--line2);
# color:var(--dim);font-weight:400}
#button.ghost:hover,a.btn.ghost:hover{background:var(--row)}
#label{display:block;color:var(--muted);font-size:12px;margin:14px 0 6px}
#input{width:100%;padding:12px;font:inherit;background:var(--bg);color:var(--fg);
# border:1px solid var(--line2);border-radius:10px}
#input:focus{outline:0;border-color:var(--btn)}
#.alt{text-align:center;margin-top:18px;font-size:13px;color:var(--muted)}
#.alt a{color:var(--accent)}
#.big{font-size:22px;font-weight:600;text-align:center;letter-spacing:.5px;
# background:var(--bg);border:1px solid var(--line);border-radius:12px;padding:18px;
# color:var(--accent);margin:6px 0 4px;direction:ltr}
#.note{color:var(--muted);font-size:12px;line-height:1.8;margin-top:16px}
#.msg{padding:11px 14px;border-radius:9px;margin-bottom:16px;font-size:13px}
#.msg.good{background:var(--good-bg);border:1px solid var(--btn)}
#.msg.err{background:var(--err-bg);border:1px solid var(--danger)}
#.msg.warnbox{background:var(--warn-bg);border:1px solid var(--warn-line)}
#.icon{font-size:40px;text-align:center;line-height:1;margin-bottom:12px}
#.dns{margin-top:20px;padding:16px;background:var(--bg);border:1px solid var(--line);
# border-radius:12px}
#.dns .k{color:var(--muted);font-size:12px;margin-bottom:8px}
#.dns .big{margin:0}
#.dns .note{margin-top:12px}
#.dns input[type=file]{width:100%;padding:10px;font-size:12px;
# border:1px dashed var(--line2);background:transparent;margin-bottom:4px}
#details.pw{margin-top:16px;border:1px solid var(--line);border-radius:12px;
# background:var(--bg)}
#details.pw>summary{padding:14px 16px;cursor:pointer;color:var(--dim);font-size:13px;
# list-style:none}
#details.pw>summary::-webkit-details-marker{display:none}
#details.pw>summary::before{content:'▸';margin-left:8px;font-size:11px}
#details.pw[open]>summary::before{content:'▾'}
#details.pw form{padding:0 16px 4px}
#details.pw .note{padding:0 16px 14px;margin-top:8px}
#.ok{color:var(--accent)}.bad{color:var(--bad)}.warn{color:var(--warn)}
#.shell{width:100%;max-width:440px}
#.brand{text-align:center;margin:0 0 18px;direction:ltr;line-height:1.15}
#.brand .mark{font-size:30px;vertical-align:middle;margin-right:8px}
#.brand .name{display:inline-block;vertical-align:middle;font-size:clamp(32px,10vw,42px);
# font-weight:800;letter-spacing:1.5px;color:var(--accent);
# background:linear-gradient(90deg,var(--accent),var(--accent2));-webkit-background-clip:text;
# background-clip:text;-webkit-text-fill-color:transparent}
#footer{text-align:center;color:var(--faint);font-size:12px;padding:16px 0 0;direction:ltr}
#.manual input{direction:ltr;text-align:center;letter-spacing:.5px}
#@media (max-width:480px){.brand{margin-top:40px}}
#button.theme{position:absolute;top:14px;left:14px;width:38px;height:38px;margin:0;
# padding:0;display:flex;align-items:center;justify-content:center;border-radius:50%;
# background:var(--card);border:1px solid var(--line2);color:var(--fg);
# font-size:17px;font-weight:400;line-height:1;cursor:pointer}
#button.theme:hover{background:var(--row)}
#.theme .sun{display:var(--sun)}.theme .moon{display:var(--moon)}
#"""
#
## Where the installer writes the version it installed. Read per page rather
## than once, so it can never disagree with what is on disk.
#VERSION_FILE = "/var/lib/smart-dns/version"
#
#
#def app_version():
#    try:
#        with open(VERSION_FILE) as fh:
#            return fh.read().strip()[:20]
#    except OSError:
#        return ""
#
#
#def brand_html():
#    return ("<div class='brand'><span class='mark'>🩺</span>"
#            "<span class='name'>doctor dns</span></div>")
#
#
#def footer_html():
#    v = app_version()
#    return "<footer>doctor dns%s</footer>" % (" v" + html.escape(v) if v else "")
#
#
#def brand():
#    """What to call the service on the customer's pages.
#
#    The domain they typed to get here. Nothing to configure, nothing that can
#    disagree with the address in the browser bar, and no second place to
#    rename the service and forget.
#    """
#    return (CFG or {}).get("PANEL_DOMAIN") or "سرویس"
#
#
#def user_page(inner):
#    return ("""<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
#<meta name="viewport" content="width=device-width,initial-scale=1">
#<title>%s</title>%s<style>%s</style></head><body>%s
#<div class="shell">%s<div class="card">%s</div>%s</div></body></html>"""
#            % (html.escape(brand()), THEME_HEAD, USER_CSS, THEME_BUTTON,
#               brand_html(), inner, footer_html()))
#
#
## A Persian keyboard types these, and the address box should not care.
#DIGITS = str.maketrans("۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩٫", "01234567890123456789.")
#
#
#def typed_ip(text):
#    """An address the customer typed by hand: (address, "") or ("", why).
#
#    The exit refuses one that belongs to another account, so what is left for
#    here is everything that could never be somebody's internet connection - a
#    private or reserved address, or one of this service's own two machines.
#    """
#    text = (text or "").translate(DIGITS).strip()
#    try:
#        addr = ipaddress.IPv4Address(text)
#    except ValueError:
#        return "", "این آی‌پی درست نیست — چهار عدد با نقطه، مثل 5.123.45.67"
#    if not addr.is_global or addr.is_multicast:
#        return "", ("این آی‌پی عمومی نیست. آی‌پی اینترنت خود را بنویسید، "
#                    "نه آی‌پی داخل شبکهٔ خانه (مثل 192.168...)")
#    if str(addr) in ((CFG or {}).get("SELF_IP"), (CFG or {}).get("PANEL_HOST")):
#        return "", "این آی‌پی مال سرورهای خود سرویس است"
#    return str(addr), ""
#
#
#def landing(banner=""):
#    return (banner +
#            "<div class='icon'>🌐</div><h1>%s</h1>"
#            "<p class='sub'>برای دیدن حساب و ثبت آی‌پی وارد شوید.</p>"
#            "<a class='btn' href='/login'>ورود</a>"
#            "<a class='btn ghost' href='/signup'>ثبت‌نام</a>"
#            "<p class='note'>از همان اینترنتی وارد شوید که می‌خواهید سرویس "
#            "روی آن کار کند — آی‌پی همان اتصال ثبت می‌شود.</p>"
#            % html.escape(brand()))
#
#
#def signup_form(banner=""):
#    return (banner +
#            "<h1>ثبت‌نام</h1><p class='sub'>%s</p>"
#            "<form method='post' action='/signup'>"
#            "<label>نام</label>"
#            "<input name='name' maxlength='60' autocomplete='name'>"
#            "<label>نام کاربری</label>"
#            "<input name='username' required minlength='3' maxlength='32' "
#            "pattern='[A-Za-z0-9._-]{3,32}' placeholder='ali_reza' "
#            "autocapitalize='none' spellcheck='false' "
#            "autocomplete='username'>"
#            "<label>رمز عبور (دست‌کم ۸ نویسه)</label>"
#            "<input name='password' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<label>تکرار رمز عبور</label>"
#            "<input name='password2' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<button>ساخت حساب</button></form>"
#            "<p class='note'>نام کاربری همان چیزی است که با آن وارد می‌شوید — "
#            "حروف انگلیسی، عدد، و . _ - ؛ بزرگ و کوچک فرقی ندارد. اگر قبلاً "
#            "کسی گرفته باشدش، پیغام می‌دهد.</p>"
#            "<p class='alt'>حساب دارید؟ <a href='/login'>وارد شوید</a></p>"
#            % html.escape(brand()))
#
#
#def login_form(banner=""):
#    return (banner +
#            "<h1>ورود</h1><p class='sub'>%s</p>"
#            "<form method='post' action='/login'>"
#            "<label>نام کاربری</label>"
#            "<input name='username' required maxlength='32' "
#            "autocapitalize='none' spellcheck='false' "
#            "autocomplete='username'>"
#            "<label>رمز عبور</label>"
#            "<input name='password' type='password' required "
#            "autocomplete='current-password'>"
#            "<button>ورود</button></form>%s"
#            "<p class='alt'>حساب ندارید؟ <a href='/signup'>ثبت‌نام کنید</a></p>"
#            % (html.escape(brand()), forgot_line()))
#
#
#def forgot_line():
#    contact = support_contact()
#    return ("<p class='alt'>رمز را فراموش کرده‌اید؟ به پشتیبانی پیام دهید%s</p>"
#            % ((": <b dir='ltr'>%s</b>" % html.escape(contact)) if contact else "."))
#
#
#def choose_password_page(banner=""):
#    """All an account on a temporary password is shown: somewhere to choose
#    its own. The panel refuses everything else until then."""
#    return (banner +
#            "<div class='icon'>🔑</div><h1>رمز خودتان را انتخاب کنید</h1>"
#            "<p class='sub'>با رمز موقت وارد شده‌اید. برای ادامه یک رمز تازه "
#            "بگذارید؛ بعد از آن رمز موقت دیگر کار نمی‌کند.</p>"
#            "<form method='post' action='/password-first'>"
#            "<label>رمز تازه (دست‌کم ۸ نویسه)</label>"
#            "<input name='new' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<label>تکرار رمز تازه</label>"
#            "<input name='again' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<button>ذخیرهٔ رمز</button></form>"
#            "<p class='alt'><a href='/logout'>خروج</a></p>")
#
#
#def register_ip_page(ip, banner=""):
#    """The step between signing up and having a working service.
#
#    It shows the address rather than registering it quietly, because this is
#    the one thing on the whole panel the customer has to get right: the address
#    seen here is the address that will work, and if they opened the page over
#    mobile data or a VPN it is the wrong one. Naming it gives them the chance
#    to notice.
#    """
#    return (banner +
#            "<div class='icon'>📍</div><h1>ثبت آی‌پی</h1>"
#            "<p class='sub'>سرویس روی همین آی‌پی باز می‌شود.</p>"
#            "<div class='big'>%s</div>"
#            "<form method='post' action='/register-ip'>"
#            "<button>همین آی‌پی را ثبت کن</button></form>"
#            "<p class='note'>اگر این آی‌پی اینترنت خانه یا موبایل شما "
#            "<b>نیست</b> — مثلاً وی‌پی‌ان روشن است یا از اینترنت دیگری وارد "
#            "شده‌اید — آن را ببندید، همین صفحه را تازه کنید و بعد ثبت کنید.</p>"
#            "<p class='note'>آی‌پی خانگی معمولاً ثابت نیست. اگر مودم را ریست "
#            "کردید و سرویس قطع شد، دوباره به همین صفحه بیایید و ثبت کنید.</p>"
#            % html.escape(ip)
#            + manual_ip_box() +
#            "<p class='alt'><a href='/'>فعلاً نه، برو به حساب</a></p>")
#
#
#def manual_ip_box(back=""):
#    """The box for typing an address by hand, here and on the account page.
#
#    Somebody on mobile data who wants the service at home would otherwise have
#    to go home before they could register it. `back` is where a refusal sends
#    them, so they land on the page they typed it on.
#    """
#    hidden = ("<input type='hidden' name='back' value='%s'>" % html.escape(back)
#              if back else "")
#    return ("<div class='dns manual'><div class='k'>ثبت دستی آی‌پی</div>"
#            "<p class='note' style='margin-top:0'>سرویس را برای اینترنت دیگری "
#            "می‌خواهید؟ مثلاً الان با موبایل آمده‌اید ولی سرویس را برای اینترنت "
#            "خانه لازم دارید. آی‌پی آن اینترنت را اینجا بنویسید؛ از صفحهٔ مودم "
#            "یا یک سایت «آی‌پی من چیست» روی همان اینترنت پیدایش می‌کنید.</p>"
#            "<form method='post' action='/register-ip'>%s"
#            "<input name='ip' required maxlength='40' inputmode='decimal' "
#            "placeholder='5.123.45.67' autocomplete='off' spellcheck='false'>"
#            "<button class='ghost'>ثبت این آی‌پی</button></form></div>" % hidden)
#
#
#def account_notice(info):
#    """The warning the bot used to send, on the page instead.
#
#    A message reached only the accounts that had a Telegram behind them, which
#    by the end was a minority. This reaches everybody, and it is on the screen
#    they open when something has stopped working - which is when they look.
#
#    Only the worst applicable one is shown. Three stacked warnings about the
#    same allowance is noise, and the reader stops reading.
#    """
#    status = info.get("status")
#    # First thing a new customer sees, so it says what to do rather than what
#    # is wrong. Nothing is wrong: they have an account, and it is waiting.
#    if status == "pending":
#        return ("<div class='msg warnbox'><b>حساب شما ساخته شد.</b> "
#                "برای فعال شدن سرویس، رسید پرداختتان را از پایین همین صفحه "
#                "بفرستید — بعد از تأیید، پلن برایتان ثبت می‌شود.</div>")
#    if status == "expired":
#        return ("<div class='msg err'><b>دورهٔ شما تمام شد.</b> "
#                "سرویس تا تمدید کار نمی‌کند.</div>")
#    if status == "over_quota":
#        return ("<div class='msg err'><b>سهمیهٔ شما تمام شد.</b> "
#                "سرویس تا شارژ مجدد قطع است.</div>")
#    if status != "active":
#        return "<div class='msg err'>حساب شما غیرفعال است.</div>"
#
#    quota, used = info.get("quota") or 0, info.get("used") or 0
#    if quota:
#        left = max(0, quota - used)
#        # The same thresholds the panel records, read back rather than
#        # recomputed, so the page and the database never disagree about
#        # whether somebody has been warned.
#        if info.get("warned", 0) & 2:
#            return ("<div class='msg err'>بیش از ۹۵٪ سهمیه‌تان مصرف شده — "
#                    "%s مانده.</div>" % human_fa(left))
#        if info.get("warned", 0) & 1:
#            return ("<div class='msg warnbox'>بیش از ۸۰٪ سهمیه‌تان مصرف شده — "
#                    "%s مانده.</div>" % human_fa(left))
#
#    ends = info.get("expires")
#    if ends:
#        return ("<div class='msg warnbox'>دورهٔ شما در <b>%s</b> "
#                "تمام می‌شود.</div>" % html.escape(ends))
#    return ""
#
#
#def dns_box():
#    """The address the customer has to type into their console or router.
#
#    Served by the relay, so it is this machine's own address - not something
#    configured twice and able to disagree. A customer on a second relay is
#    looking at that relay's page and gets that relay's address, which is the
#    one that will work for them.
#
#    Only the first is given. Consoles ask for two, and the honest answer is to
#    repeat this one: a second, different resolver would answer the sanctioned
#    names truthfully and the service would fail intermittently in a way nobody
#    could diagnose.
#    """
#    ip = (CFG or {}).get("SELF_IP", "")
#    if not ip:
#        return ""
#    return ("<div class='dns'><div class='k'>آدرس DNS</div>"
#            "<div class='big'>%s</div>"
#            "<p class='note'>این را در تنظیمات شبکهٔ کنسول، گوشی یا مودم "
#            "به‌عنوان <b>DNS اول</b> بگذارید. اگر DNS دوم هم می‌خواهد، "
#            "<b>همین آدرس</b> را دوباره بنویسید — آدرس دیگری آنجا باعث می‌شود "
#            "سرویس گاهی کار کند و گاهی نه.</p></div>" % html.escape(ip))
#
#
#def human_fa(n):
#    n = float(n or 0)
#    for unit in ("بایت", "کیلوبایت", "مگابایت", "گیگابایت", "ترابایت"):
#        if n < 1024 or unit == "ترابایت":
#            return ("%d %s" if unit == "بایت" else "%.2f %s") % (n, unit)
#        n /= 1024
#
#
#class UserPanel(http.server.BaseHTTPRequestHandler):
#    """The page a customer sees.
#
#    It keeps no state of its own. The cookie is handed to the panel on the exit
#    node, which says who it belongs to - so a relay rebuilt from scratch does
#    not log anybody out, and a second relay serves the same session without the
#    two needing to share anything.
#    """
#
#    server_version = "smartdns"
#    protocol_version = "HTTP/1.1"
#
#    def log_message(self, fmt, *args):
#        # http.server's own notes - a malformed request, a timeout. The access
#        # line is log_request below.
#        log(INFO, "panel %s from %s" % (fmt % args, self.client_address[0]))
#
#    def parse_request(self):
#        self._t0 = time.monotonic()
#        return super().parse_request()
#
#    def log_request(self, code="-", size="-"):
#        # The path only. The query carries nothing but the message shown after
#        # a form, and the cookie - the session - is never written anywhere.
#        log_access(self, "panel", code,
#                   urllib.parse.urlparse(getattr(self, "path", "") or "").path[:120])
#
#    def client_ip(self):
#        # The socket, never a header. Trusting X-Forwarded-For here would let
#        # anyone register any address by sending one.
#        return self.client_address[0]
#
#    def send_html(self, body, code=200, headers=None):
#        blob = user_page(body).encode("utf-8")
#        # See send(): a clean buffer, so a failed attempt cannot leave half a
#        # status line in front of this one.
#        self._headers_buffer = []
#        self.send_response(code)
#        self.send_header("Content-Type", "text/html; charset=utf-8")
#        self.send_header("Content-Length", str(len(blob)))
#        self.send_header("Cache-Control", "no-store")
#        self.send_header("X-Frame-Options", "DENY")
#        self.send_header("X-Content-Type-Options", "nosniff")
#        for k, v in (headers or {}).items():
#            self.send_header(k, v)
#        self.end_headers()
#        self.wfile.write(blob)
#
#    def session(self):
#        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
#        return cookie["sdu"].value if "sdu" in cookie else ""
#
#    def upload(self, field):
#        """Pull one file out of a multipart body: (bytes, content type).
#
#        Hand-written because cgi was removed in Python 3.13 and this installer
#        has no pip step. One field is all that is needed, so this only has to
#        find its part and hand back what sits between the blank line and the
#        next boundary.
#        """
#        ctype = self.headers.get("Content-Type") or ""
#        if "boundary=" not in ctype:
#            raise ValueError("فایلی فرستاده نشد")
#        boundary = ctype.split("boundary=", 1)[1].strip().strip('"')
#        want = ('name="%s"' % field).encode("latin-1")
#        for part in getattr(self, "raw_body", b"").split(b"--" + boundary.encode("latin-1")):
#            head, blank, data = part.partition(b"\r\n\r\n")
#            if not blank or want not in head:
#                continue
#            kind = ""
#            for line in head.split(b"\r\n"):
#                if line.lower().startswith(b"content-type:"):
#                    kind = line.split(b":", 1)[1].decode("latin-1").strip()
#            # The trailing CRLF belongs to the delimiter, not the file.
#            return (data[:-2] if data.endswith(b"\r\n") else data), kind
#        raise ValueError("فایلی انتخاب نشده بود")
#
#    def form(self):
#        """Read the POST body. Bounded, because this is a public port in Iran
#        and nothing stops somebody announcing a gigabyte.
#
#        A receipt arrives as multipart and is kept as raw bytes for upload()
#        to pick apart; everything else is a small urlencoded form.
#        """
#        try:
#            length = int(self.headers.get("Content-Length") or 0)
#        except ValueError:
#            return {}
#        if length <= 0:
#            return {}
#        if "multipart/form-data" in (self.headers.get("Content-Type") or ""):
#            if length > MAX_RECEIPT + 64 * 1024:      # the file plus its wrapper
#                self.raw_body = b""
#                return {"too_big": "1"}
#            self.raw_body = self.rfile.read(length)
#            return {}
#        if length > 8192:
#            return {}
#        raw = self.rfile.read(length).decode("utf-8", "replace")
#        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
#
#    def cookie_for(self, session):
#        return ("sdu=%s; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=%d"
#                % (session, 30 * 86400))
#
#    def redirect(self, where, message="", bad=False):
#        if message:
#            where += ("&" if "?" in where else "?") + "m=" + \
#                urllib.parse.quote(message) + ("&e=1" if bad else "")
#        return self.send("", 303, {"Location": where})
#
#    def banner(self):
#        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
#        msg = (q.get("m") or [""])[0]
#        if not msg:
#            return ""
#        return "<div class='msg %s'>%s</div>" % (
#            "err" if q.get("e") else "good", html.escape(msg[:200]))
#
#    def send_font(self):
#        """The one thing this panel lets a browser keep: the same file for
#        everybody, and a new version comes at a new address."""
#        blob = font_bytes()
#        if blob is None:
#            return self.send_html("<div class='icon'>❔</div><h1>صفحه پیدا نشد</h1>", 404)
#        self._headers_buffer = []
#        self.send_response(200)
#        self.send_header("Content-Type", "font/woff2")
#        self.send_header("Content-Length", str(len(blob)))
#        self.send_header("Cache-Control", "public, max-age=31536000, immutable")
#        self.send_header("X-Content-Type-Options", "nosniff")
#        self.end_headers()
#        self.wfile.write(blob)
#
#    def do_GET(self):
#        path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
#
#        if path == "/vazirmatn.woff2":
#            return self.send_font()
#
#        if path in ("/signup", "/login"):
#            # Whether a cookie is here decides only whether to offer a way back
#            # to the account, never whether to show the form. Bouncing on the
#            # cookie's mere existence trapped anyone holding an expired one:
#            # they were sent to a page that said their session had ended, on
#            # their way to the page that would have given them a new one.
#            back = ("<p class='alt'><a href='/'>برگشت به حساب</a></p>"
#                    if self.session() else "")
#            return self.send_html(
#                (signup_form(self.banner()) if path == "/signup"
#                 else login_form(self.banner())) + back)
#
#        if path == "/register-ip":
#            if not self.session():
#                return self.redirect("/")
#            return self.send_html(register_ip_page(self.client_ip(), self.banner()))
#
#        if path == "/logout":
#            return self.send("", 303, {"Location": "/",
#                                       "Set-Cookie": "sdu=; Path=/; Max-Age=0"})
#
#        if path != "/":
#            return self.send_html("<div class='icon'>❔</div><h1>صفحه پیدا نشد</h1>", 404)
#        return self.dashboard()
#
#    def send(self, body, code, headers):
#        blob = body.encode() if isinstance(body, str) else body
#        # Nothing reaches the socket until end_headers(), so a send() that
#        # raised part-way through leaves a half-written status line behind.
#        # Clearing the buffer keeps the next response from being appended to
#        # it and handed to the browser as one corrupt reply.
#        self._headers_buffer = []
#        self.send_response(code)
#        self.send_header("Content-Length", str(len(blob)))
#        for k, v in headers.items():
#            self.send_header(k, v)
#        self.end_headers()
#        self.wfile.write(blob)
#
#    def do_POST(self):
#        path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
#
#        if path in ("/signup", "/login"):
#            form = self.form()
#            endpoint = "/user-signup" if path == "/signup" else "/user-password-login"
#            payload = {"username": form.get("username", ""),
#                       "password": form.get("password", ""),
#                       "ip": self.client_ip()}
#            if path == "/signup":
#                payload["name"] = form.get("name", "")
#                if form.get("password") != form.get("password2"):
#                    return self.redirect("/signup", "دو رمز یکی نیستند", bad=True)
#            try:
#                res = post(endpoint, payload)
#            except Exception as e:
#                log(ERROR, "panel: %s failed: %s" % (endpoint, e))
#                return self.redirect(path, "الان نشد، چند دقیقه دیگر", bad=True)
#            if not res.get("ok"):
#                return self.redirect(path, res.get("message", "خطا"), bad=True)
#            # Straight to the address page either way. A new account has no
#            # address yet, and somebody signing in from a new connection is
#            # usually signing in precisely because the address changed.
#            # A temporary password goes to the one page it is good for.
#            return self.send("", 303, {
#                "Location": "/" if res.get("must_change") else "/register-ip",
#                "Set-Cookie": self.cookie_for(res["session"])})
#
#        if path == "/password-first":
#            if not self.session():
#                return self.redirect("/")
#            form = self.form()
#            if form.get("new") != form.get("again"):
#                return self.redirect("/", "دو رمز یکی نیستند", bad=True)
#            try:
#                res = post("/user-password-first", {
#                    "session": self.session(), "new": form.get("new", "")})
#            except Exception as e:
#                log(ERROR, "panel: choosing a password failed: %s" % e)
#                return self.redirect("/", "الان نشد، چند دقیقه دیگر", bad=True)
#            return self.redirect("/", res.get("message", ""),
#                                 bad=not res.get("ok"))
#
#        if path == "/password":
#            if not self.session():
#                return self.redirect("/")
#            form = self.form()
#            if form.get("new") != form.get("again"):
#                return self.redirect("/", "دو رمز تازه یکی نیستند", bad=True)
#            try:
#                res = post("/user-password", {
#                    "session": self.session(),
#                    "current": form.get("current", ""),
#                    "new": form.get("new", ""),
#                })
#            except Exception as e:
#                log(ERROR, "panel: password change failed: %s" % e)
#                return self.redirect("/", "الان نشد، چند دقیقه دیگر", bad=True)
#            return self.redirect("/", res.get("message", ""),
#                                 bad=not res.get("ok"))
#
#        if path == "/receipt":
#            if not self.session():
#                return self.redirect("/")
#            form = self.form()
#            if form.get("too_big"):
#                return self.redirect("/", "فایل خیلی بزرگ است", bad=True)
#            try:
#                blob, kind = self.upload("file")
#            except ValueError as e:
#                return self.redirect("/", str(e), bad=True)
#            try:
#                res = post("/user-receipt", {
#                    "session": self.session(),
#                    "content_type": kind,
#                    "data": base64.b64encode(blob).decode("ascii"),
#                })
#            except Exception as e:
#                log(ERROR, "panel: receipt failed: %s" % e)
#                return self.redirect("/", "الان نشد، چند دقیقه دیگر", bad=True)
#            return self.redirect("/", res.get("message", ""),
#                                 bad=not res.get("ok"))
#
#        if path != "/register-ip":
#            return self.send_html("<h1>404</h1>", 404)
#        # Nothing typed is the button: the address this page is opened from.
#        form = self.form()
#        typed = (form.get("ip") or "").strip()
#        # One of two pages of our own, whatever the form claims.
#        back = "/" if form.get("back") == "/" else "/register-ip"
#        if typed:
#            ip, why = typed_ip(typed)
#            if not ip:
#                return self.redirect(back, why, bad=True)
#            log(INFO, "panel: %s registered %s by hand" % (self.client_ip(), ip))
#        else:
#            ip = self.client_ip()
#        try:
#            res = post("/user-claim", {"session": self.session(), "ip": ip})
#        except Exception as e:
#            log(ERROR, "panel: user-claim failed: %s" % e)
#            res = {"ok": False, "message": "الان نشد"}
#        return self.redirect("/", res.get("message", ""), bad=not res.get("ok"))
#
#    def dashboard(self):
#        token = self.session()
#        if not token:
#            return self.send_html(landing(self.banner()))
#        try:
#            info = post("/user-info", {"session": token, "ip": self.client_ip()})
#        except Exception as e:
#            log(ERROR, "panel: user-info failed: %s" % e)
#            return self.send_html("<div class='icon'>⚠️</div><h1>الان نشد</h1>"
#                                  "<p class='sub'>چند دقیقه دیگر دوباره.</p>", 502)
#        if not info.get("ok"):
#            return self.send_html(
#                "<div class='icon'>🔑</div><h1>نشست منقضی شده</h1>"
#                "<p class='sub'>دوباره <a href='/login'>وارد شوید</a>.</p>",
#                200, {"Set-Cookie": "sdu=; Path=/; Max-Age=0"})
#        if info.get("must_change"):
#            return self.send_html(choose_password_page(self.banner()))
#
#        banner = self.banner()
#
#        used, quota = info["used"], info["quota"]
#        seen = info.get("seen_ip") or self.client_ip()
#        rows = [("پلن", html.escape(info.get("plan") or "-")),
#                ("آی‌پی ثبت‌شده", "<code>%s</code>" % html.escape(info["ip"] or "ثبت نشده")),
#                ("مصرف", human_fa(used))]
#        if quota:
#            rows.append(("سهمیه", human_fa(quota)))
#            rows.append(("باقی‌مانده", human_fa(max(0, quota - used))))
#        else:
#            rows.append(("سهمیه", "نامحدود"))
#        kbps = info.get("speed_kbps") or 0
#        rows.append(("سرعت", ("%g مگابیت بر ثانیه" % (kbps / 1000.0)) if kbps
#                     else "بدون محدودیت"))
#        if info.get("expires"):
#            rows.append(("پایان دوره", info["expires"]))
#        elif info.get("renews"):
#            rows.append(("تمدید", info["renews"]))
#        rows.append(("کیف پول", "%s تومان" % format(info.get("wallet") or 0, ",")))
#        state = {"active": "<span class='ok'>فعال</span>",
#                 "pending": "<span class='warn'>در انتظار فعال‌سازی</span>",
#                 "over_quota": "<span class='warn'>سهمیه تمام شده</span>",
#                 "expired": "<span class='warn'>دورهٔ شما تمام شد</span>"}.get(
#                     info["status"], "<span class='bad'>غیرفعال</span>")
#        rows.append(("وضعیت", state))
#
#        gauge = ""
#        if quota:
#            pct = min(100, int(100.0 * used / quota))
#            cls = "hot" if pct >= 90 else ("warn" if pct >= 75 else "")
#            gauge = ("<div class='bar'><i class='%s' style='width:%d%%'></i></div>"
#                     % (cls, pct))
#
#        body = ["<h1>%s</h1>" % html.escape(info.get("name") or "حساب شما"),
#                "<div class='sub'>%s</div>" % html.escape(brand()),
#                banner, account_notice(info)]
#        for k, v in rows:
#            body.append("<div class='row'><span class='k'>%s</span>"
#                        "<span class='v'>%s</span></div>" % (k, v))
#        body.append(gauge)
#        body.append(dns_box())
#
#        if not info["ip"]:
#            body.append(
#                "<a class='btn' href='/register-ip'>ثبت آی‌پی — سرویس هنوز "
#                "باز نشده</a>"
#                "<p class='note'>تا آی‌پی ثبت نشود سرویس روی اینترنت شما کار "
#                "نمی‌کند.</p>")
#        elif info["ip"] != seen:
#            body.append(
#                "<a class='btn' href='/register-ip'>ثبت آی‌پی فعلی (%s)</a>"
#                "<p class='note'>آی‌پی اینترنت شما با آنچه ثبت شده فرق دارد. "
#                "این دکمه آی‌پی فعلی را جایگزین می‌کند.</p>" % html.escape(seen))
#        else:
#            body.append(
#                "<a class='btn ghost' href='/register-ip'>"
#                "ثبت دوباره همین آی‌پی</a>"
#                "<p class='note'>آی‌پی شما درست ثبت شده. اگر مودم را ریست کردید و "
#                "سرویس قطع شد، همین صفحه را باز کنید و این دکمه را بزنید.</p>")
#        body.append(manual_ip_box("/"))
#        body.append(
#            "<div class='dns'><div class='k'>ارسال رسید پرداخت</div>"
#            "<p class='note' style='margin-top:0'>عکس فیش واریزی را بفرستید تا "
#            "مدیر بررسی کند و حسابتان شارژ شود. عکس یا PDF، حداکثر ۴ مگابایت. "
#            "اگر رسید تازه‌ای بفرستید، جای قبلی را می‌گیرد.</p>"
#            "<form method='post' action='/receipt' enctype='multipart/form-data'>"
#            "<input type='file' name='file' required "
#            "accept='image/jpeg,image/png,image/webp,application/pdf'>"
#            "<button class='ghost'>فرستادن رسید</button></form></div>")
#        body.append(
#            "<details class='pw'><summary>تغییر رمز عبور</summary>"
#            "<form method='post' action='/password'>"
#            "<label>رمز فعلی</label>"
#            "<input name='current' type='password' required "
#            "autocomplete='current-password'>"
#            "<label>رمز تازه (دست‌کم ۸ نویسه)</label>"
#            "<input name='new' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<label>تکرار رمز تازه</label>"
#            "<input name='again' type='password' required minlength='8' "
#            "autocomplete='new-password'>"
#            "<button class='ghost'>تغییر رمز</button></form>"
#            "<p class='note'>اگر جای دیگری وارد حسابتان باشید، با تغییر رمز "
#            "از آنجا خارج می‌شوید.</p></details>")
#        body.append("<p class='alt'><a href='/logout'>خروج از حساب</a></p>")
#        return self.send_html("".join(body))
#
#
#def main():
#    global CFG
#    CFG = load_config()
#    if not os.path.exists(ACL):
#        sys.exit("%s is missing - run the installer first" % ACL)
#    threading.Thread(target=sync_loop, daemon=True).start()
#
#    # Over TLS or not at all. This panel asks for a password and hands back a
#    # session cookie, and there is no version of that which is safe over plain
#    # http on an Iranian ISP. There used to be a second, plain listener that
#    # served a page explaining why the forms were switched off; a port that
#    # serves anything is a port that can be pointed at, so it is gone rather
#    # than harmless.
#    if CFG.get("PANEL_DOMAIN"):
#        serve_panel()
#    else:
#        print("sync up: every %ds to %s - no certificate, so no customer panel"
#              % (INTERVAL, CFG["PANEL_HOST"]), flush=True)
#        while True:
#            time.sleep(3600)
#
#
## How long a visitor may take to finish the TLS handshake, and then how long
## any one read or write may stall once it has. Per operation, not in total: a
## receipt crawling up a slow mobile link keeps making progress and is never
## cut off, while a connection that has simply gone quiet is let go.
#HANDSHAKE_TIMEOUT = 10
#IO_TIMEOUT = 30
#
#
#class PanelServer(http.server.ThreadingHTTPServer):
#    """The customer panel's server, with TLS done per connection.
#
#    It used to wrap the listening socket. That puts every visitor's TLS
#    handshake inside accept(), on the single thread that accepts for all of
#    them, with no timeout - so one phone whose connection dropped half way
#    through a handshake froze the panel for everybody until it went away,
#    which without a timeout could be never. On mobile networks in Iran that is
#    an ordinary event, and it was reported as "I sent my receipt and the page
#    stopped loading".
#
#    Here accept() only ever does accept(). The handshake happens in the
#    connection's own thread, under a deadline, so a stalled visitor stalls
#    only itself.
#    """
#    daemon_threads = True
#
#    def __init__(self, addr, handler, ctx):
#        self.ctx = ctx
#        super().__init__(addr, handler)
#
#    def finish_request(self, request, client_address):
#        if self.ctx is None:      # plain http, for tests only
#            return super().finish_request(request, client_address)
#        request.settimeout(HANDSHAKE_TIMEOUT)
#        try:
#            tls = self.ctx.wrap_socket(request, server_side=True)
#        except (ssl.SSLError, OSError):
#            # A scanner, a dropped phone, somebody speaking plain http to an
#            # https port. Nothing to answer, and nobody else is kept waiting.
#            return
#        try:
#            tls.settimeout(IO_TIMEOUT)
#            self.RequestHandlerClass(tls, client_address, self)
#        except (ssl.SSLError, OSError):
#            pass
#        finally:
#            try:
#                tls.close()
#            except OSError:
#                pass
#
#    def handle_error(self, request, client_address):
#        # Whatever a handler did not catch, with its traceback, at error
#        # level. http.server's default prints it at info, where nobody looks.
#        if isinstance(sys.exc_info()[1], GONE):
#            return
#        log_exception("request from %s failed" % client_address[0])
#
#
#def make_panel_server(ctx, port=None):
#    return PanelServer(("0.0.0.0", PANEL_TLS_PORT if port is None else port),
#                       UserPanel, ctx)
#
#
#def serve_panel():
#    cert = "/etc/letsencrypt/live/%s/fullchain.pem" % CFG["PANEL_DOMAIN"]
#    key = "/etc/letsencrypt/live/%s/privkey.pem" % CFG["PANEL_DOMAIN"]
#    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
#    ctx.load_cert_chain(cert, key)
#    httpd = make_panel_server(ctx)
#    print("sync up: every %ds to %s, panel on https://%s:%d/"
#          % (INTERVAL, CFG["PANEL_HOST"], CFG["PANEL_DOMAIN"], PANEL_TLS_PORT),
#          flush=True)
#    httpd.serve_forever()
#
#
#if __name__ == "__main__":
#    main()
#__END_SYNC__

#__BEGIN_SYNC_SERVICE__
#[Unit]
#Description=Smart DNS relay sync - usage out, allowlist in, claim page
#After=network-online.target nftables.service
#Wants=network-online.target
#
#[Service]
#Type=simple
#ExecStart=/usr/local/bin/smartdns-sync
#Restart=always
#RestartSec=10
## Needs root: it drives smartdns-acl, which talks to nftables.
#NoNewPrivileges=yes
#ProtectHome=yes
#PrivateTmp=yes
#
#[Install]
#WantedBy=multi-user.target
#__END_SYNC_SERVICE__

#__BEGIN_DNS_PROFILE_UNIT__
#[Unit]
#Description=Smart DNS resolver for service template %i
#After=network-online.target
#PartOf=smartdns-sync.service
#
#[Service]
#Type=simple
## /etc/smartdns-base mirrors /etc/dnsmasq.d by symlink, minus the operator's
## custom domains. Sharing by symlink means `smartdns add` and epic-pin still
## reach every resolver; leaving the custom file out is what lets a template
## not route those domains, since they cannot be un-routed by rule.
#ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/dev/null \
#    --conf-dir=/etc/smartdns-base --conf-file=/etc/smartdns-profiles/%i.conf
#Restart=always
#RestartSec=5
#
#[Install]
#WantedBy=multi-user.target
#__END_DNS_PROFILE_UNIT__

#__BEGIN_CERT__
##!/bin/bash
## smartdns-cert - obtain and renew the panel's TLS certificate.
##
## usage: smartdns-cert <domain>        get or renew a certificate
##        smartdns-cert --renew         renew everything due (the timer's job)
##
## Port 80 is the problem this script exists to work around. Let's Encrypt's
## HTTP-01 challenge needs it, and on a relay port 80 is forwarded whole to the
## exit node so that console downloads work: Sony and Microsoft serve game
## packages over plain HTTP from Akamai edges that answer 443 with a certificate
## naming no console host at all. Rebuilding nginx to terminate HTTP and answer
## the challenge itself would put an L7 proxy in the middle of the exact path
## that took a week to get right.
##
## So nginx is not touched. For the twenty seconds a challenge takes, an
## nftables rule sends port 80 to a local certbot instead, and the rule is
## removed afterwards - including when certbot fails, which is what the trap is
## for. A leftover rule would send every console download into a dead port.
##
## The cost is honest: console HTTP downloads stall for those twenty seconds, on
## the day a certificate is issued and again every sixty days. A download that
## stalls resumes; a certificate that expires takes the panel down until someone
## notices.
##
## If /etc/smart-dns/cloudflare.ini exists, DNS-01 is used instead and port 80
## is never touched at all. Nothing here asks for that token - it is only used
## when the operator has deliberately put it there.
#set -uo pipefail
#export PATH="$PATH:/usr/sbin:/sbin"
#
#CF_CONF=/etc/smart-dns/cloudflare.ini
#LIVE=/etc/letsencrypt/live
#ACME_PORT=8402
#NAT_TABLE=smartdns_acme
#
#R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
#[ -t 1 ] || { R=; G=; Y=; N=; }
#die() { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
#
#[ "$(id -u)" = 0 ] || die "run as root"
#
#open_port80() {
#    nft add table ip $NAT_TABLE 2>/dev/null
#    nft add chain ip $NAT_TABLE pre \
#        '{ type nat hook prerouting priority dstnat ; policy accept ; }' 2>/dev/null
#    nft add rule ip $NAT_TABLE pre tcp dport 80 redirect to :$ACME_PORT
#}
#
#close_port80() {
#    nft delete table ip $NAT_TABLE 2>/dev/null
#    return 0
#}
#
#issue() {
#    local domain="$1"
#    if [ -f "$CF_CONF" ]; then
#        # The operator supplied a DNS token, so prove it that way and leave
#        # port 80 alone entirely.
#        certbot certonly --dns-cloudflare \
#            --dns-cloudflare-credentials "$CF_CONF" \
#            --dns-cloudflare-propagation-seconds 30 \
#            --register-unsafely-without-email --agree-tos \
#            --non-interactive --quiet --cert-name "$domain" -d "$domain"
#        return $?
#    fi
#
#    # Always put port 80 back, whatever happens next.
#    trap close_port80 EXIT INT TERM
#    open_port80 || die "could not redirect port 80 for the challenge"
#    certbot certonly --standalone --http-01-port "$ACME_PORT" \
#        --register-unsafely-without-email --agree-tos \
#        --non-interactive --quiet --cert-name "$domain" -d "$domain"
#    local rc=$?
#    close_port80
#    trap - EXIT INT TERM
#    return $rc
#}
#
#case "${1:-}" in
#--renew)
#    # certbot decides what is due, so almost every run does nothing. The
#    # redirect is only opened when something actually needs renewing.
#    if certbot renew --dry-run >/dev/null 2>&1 || true; then :; fi
#    for path in "$LIVE"/*/; do
#        [ -d "$path" ] || continue
#        domain="$(basename "$path")"
#        openssl x509 -checkend $((30 * 86400)) -noout \
#            -in "$path/fullchain.pem" >/dev/null 2>&1 && continue
#        printf 'renewing %s\n' "$domain"
#        issue "$domain" && systemctl reload nginx 2>/dev/null
#    done
#    exit 0
#    ;;
#"")
#    die "usage: smartdns-cert <domain>" ;;
#esac
#
#DOMAIN="$1"
#
## A machine installed without a domain has this script but not certbot - the
## installer only pulls certbot in when it is about to issue something. Since
## the whole point of running this later is that there was no domain at install
## time, "certbot: not found" is the most likely first thing anybody sees here.
#if ! command -v certbot >/dev/null 2>&1; then
#    printf '    installing certbot\n'
#    export DEBIAN_FRONTEND=noninteractive
#    pkgs=certbot
#    [ -f "$CF_CONF" ] && pkgs="$pkgs python3-certbot-dns-cloudflare"
#    apt-get update -qq >/dev/null 2>&1
#    # shellcheck disable=SC2086
#    apt-get install -y -qq $pkgs >/dev/null 2>&1 \
#        || die "could not install certbot:  apt-get install -y $pkgs"
#fi
#
## Already have one with plenty of life left? Do nothing. Let's Encrypt limits
## issuance per domain per week, and re-issuing on every installer run would
## burn that allowance and then fail at the moment it mattered.
#if [ -d "$LIVE/$DOMAIN" ] && openssl x509 -checkend $((30 * 86400)) -noout \
#        -in "$LIVE/$DOMAIN/fullchain.pem" >/dev/null 2>&1; then
#    printf '    certificate for %s is current\n' "$DOMAIN"
#    exit 0
#fi
#
#if [ ! -f "$CF_CONF" ]; then
#    printf '    %sopening port 80 for about twenty seconds%s - console downloads\n' "$Y" "$N"
#    printf '    through this machine will stall until the challenge finishes\n'
#fi
#printf '    getting a certificate for %s\n' "$DOMAIN"
#issue "$DOMAIN" || die "certbot could not get a certificate for $DOMAIN.
#    The name must point at this machine and port 80 must be reachable from the
#    internet - that is how Let's Encrypt checks you control it."
#
#printf '%s    certificate installed:%s %s\n' "$G" "$N" "$LIVE/$DOMAIN/fullchain.pem"
#__END_CERT__

#__BEGIN_CERT_SERVICE__
#[Unit]
#Description=Renew the smart DNS panel certificates
#
#[Service]
#Type=oneshot
#ExecStart=/usr/local/bin/smartdns-cert --renew
#__END_CERT_SERVICE__

#__BEGIN_CERT_TIMER__
#[Unit]
#Description=Twice-daily certificate renewal check
#
#[Timer]
## Twice a day is what Let's Encrypt asks for. certbot itself decides what is
## actually due, so almost every run does nothing; the point is that a
## certificate never gets close to expiring unnoticed.
#OnCalendar=*-*-* 03,15:00:00
#RandomizedDelaySec=3h
#Persistent=true
#
#[Install]
#WantedBy=timers.target
#__END_CERT_TIMER__

#__BEGIN_ADMIN__
##!/usr/bin/env python3
#"""smartdns-admin - the operator's web panel.
#
#A separate process from smartdns-panel, sharing its database. Separate because
#the bot must not go down while this is being restarted, and because a bug in a
#web form should not take the thing that talks to customers with it. sqlite is
#in WAL mode, so two processes writing short transactions is fine.
#
#Three things stand in front of it, and none of them is sufficient alone:
#
#  a port nobody scans for   keeps it out of the way, nothing more
#  a random path prefix      an unguessable URL, not a credential
#  a password               the actual authentication
#
#Security by obscurity is not security, so the password is the real control and
#the other two only reduce how often anyone finds the door at all. Optional
#address locking is available and switched off by default: the operator's home
#address is dynamic, and locking to it would eventually shut them out.
#
#Standard library only, like everything else here, so the installer keeps
#needing no pip step. No CDN either - the pages are opened from Iran, and every
#font and stylesheet host worth using is either blocked or slow.
#"""
#
#import hashlib
#import hmac
#import html
#import http.cookies
#import http.server
#import ipaddress
#import json
#import os
#import re
#import secrets
#import sqlite3
#import ssl
#import subprocess
#import sys
#import threading
#import time
#import traceback
#import urllib.parse
#from datetime import datetime, timedelta, timezone
#
#CONFIG = "/etc/smart-dns/admin.env"
#DB = "/var/lib/smart-dns/panel.db"
#SERVICES_FILE = "/usr/local/share/smart-dns/services.json"
## Put there by the installer and served from here - see above about CDNs. The
## version goes in the font's address, so a browser's kept copy is never stale.
#FONT_FILE = "/usr/local/share/smart-dns/Vazirmatn.woff2"
#FONT_VERSION = "33.0.3"
## Written once a day by smartdns-operators.
#OPERATORS_FILE = "/var/lib/smart-dns/operators.json"
#
#GB = 1024 ** 3
#SESSION_HOURS = 12
## Failed logins allowed from one address before it is made to wait. A password
## is the real defence, so this only has to make guessing slow rather than
## impossible.
#MAX_TRIES = 8
#LOCKOUT_SECONDS = 900
## The database is small - a few hundred kilobytes - so this is a ceiling on
## nonsense rather than a real limit on backups.
#MAX_UPLOAD = 64 * 1024 * 1024
#
#
#def systemctl(*args):
#    """Nudge a unit, without letting a failure here become a traceback.
#
#    Used either side of a restore. If systemd is not reachable the restore
#    itself has still happened and the operator can restart by hand, so this
#    reports and carries on rather than raising.
#    """
#    try:
#        r = subprocess.run(["systemctl"] + list(args), capture_output=True,
#                           text=True, timeout=30)
#        if r.returncode != 0:
#            log(WARN, "systemctl %s: %s" % (" ".join(args), r.stderr.strip()))
#        return r.returncode == 0
#    except Exception as e:
#        log(WARN, "systemctl %s failed: %r" % (" ".join(args), e))
#        return False
#
#
#def now():
#    return datetime.now(timezone.utc).isoformat(timespec="seconds")
#
#
#def human(n):
#    n = float(n or 0)
#    for unit in ("B", "KB", "MB", "GB", "TB"):
#        if n < 1024 or unit == "TB":
#            return ("%d %s" if unit == "B" else "%.2f %s") % (n, unit)
#        n /= 1024
#
#
#def parse_ts(s):
#    if not s:
#        return None
#    try:
#        t = datetime.fromisoformat(s)
#    except ValueError:
#        return None
#    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)
#
#
#def panel_host():
#    """The name this panel is reachable by - whatever its certificate is for.
#
#    It listens on every address the machine has, but only this name matches
#    the certificate, so it is the only one worth printing back.
#    """
#    cert = CFG.get("ADMIN_CERT", "")
#    if cert.startswith("/etc/letsencrypt/live/"):
#        return cert.split("/")[4]
#    return "this-server"
#
#
## Ports that belong to the service itself. Moving the panel onto one of them
## takes down the thing it exists to administer.
#RESERVED_PORTS = {53: "DNS", 80: "HTTP", 443: "HTTPS",
#                  8443: "the relays' sync API",
#                  8446: "the exit's route to Google over IPv6", 22: "SSH"}
#
#
#def remaining_days(ts):
#    """Days left until `ts`, as placeholder text for the day field.
#
#    Shown greyed inside the input rather than as its value, so that saving a
#    row without touching the field does not silently reset the clock to
#    whatever it happened to say.
#    """
#    when = parse_ts(ts)
#    if not when:
#        return "بی‌نهایت"
#    left = (when - datetime.now(timezone.utc)).total_seconds() / 86400.0
#    if left <= 0:
#        return "تمام"
#    return "%d روز" % max(1, round(left))
#
#
#def load_config():
#    cfg = {}
#    with open(CONFIG) as fh:
#        for line in fh:
#            line = line.strip()
#            if not line or line.startswith("#") or "=" not in line:
#                continue
#            k, v = line.split("=", 1)
#            cfg[k.strip()] = v.strip().strip('"').strip("'")
#    for required in ("ADMIN_PATH", "ADMIN_HASH", "ADMIN_SALT", "ADMIN_PORT"):
#        if not cfg.get(required):
#            sys.exit("%s: %s is missing" % (CONFIG, required))
#    return cfg
#
#
#def hash_password(password, salt):
#    # 200k rounds: slow enough that guessing at scale is pointless, fast enough
#    # that a login is not noticeable.
#    return hashlib.pbkdf2_hmac(
#        "sha256", password.encode(), bytes.fromhex(salt), 200_000).hex()
#
#
## ------------------------------------------------------------------ storage
#class Store:
#    def __init__(self, path):
#        self.lock = threading.Lock()
#        self.db = sqlite3.connect(path, check_same_thread=False, timeout=15)
#        self.db.row_factory = sqlite3.Row
#        self.db.execute("PRAGMA foreign_keys = ON")
#        self.db.execute("PRAGMA journal_mode = WAL")
#
#        # Created here as well as in the panel's schema: this process can be
#        # the first to open the database on a machine where the panel has not
#        # started yet, and a missing table would mean nobody could sign in.
#        self.db.execute(
#            "CREATE TABLE IF NOT EXISTS admin_sessions ("
#            " token TEXT PRIMARY KEY, expires_at TEXT NOT NULL)")
#        self.db.commit()
#
#    def q(self, sql, args=()):
#        with self.lock:
#            return self.db.execute(sql, args).fetchall()
#
#    def one(self, sql, args=()):
#        rows = self.q(sql, args)
#        return rows[0] if rows else None
#
#    def run(self, sql, args=()):
#        with self.lock:
#            cur = self.db.execute(sql, args)
#            self.db.commit()
#            return cur
#
#    def delete_user(self, uid):
#        """Delete an account and everything that is only its; the addresses
#        it had, or None when there was no such account.
#
#        Its addresses, receipts and sign-ins go with it - the schema cascades
#        them. The usage readings are kept by address rather than by account,
#        so they are cleared here: whoever is given one of those addresses
#        next starts from nothing. One transaction, so a failure part-way
#        leaves the account exactly as it was.
#        """
#        with self.lock:
#            try:
#                ips = [r["ip"] for r in self.db.execute(
#                    "SELECT ip FROM ips WHERE user_id = ?", (uid,))]
#                if self.db.execute("DELETE FROM users WHERE id = ?",
#                                   (uid,)).rowcount == 0:
#                    self.db.rollback()
#                    return None
#                self.db.executemany("DELETE FROM ip_counters WHERE ip = ?",
#                                    [(ip,) for ip in ips])
#                self.db.commit()
#                return ips
#            except BaseException:
#                self.db.rollback()
#                raise
#
#    def reset_password(self, uid, password):
#        """Give an account a temporary password; False if there is no such
#        account, or it has no username to sign in with.
#
#        Every place it is signed in is closed in the same transaction, so
#        whoever might have had the old password is out by the time the new
#        one is on the screen. Its connection is not touched: the address stays
#        registered, and the service keeps working.
#        """
#        salt = secrets.token_hex(16)
#        with self.lock:
#            try:
#                if self.db.execute(
#                        "UPDATE users SET password_hash = ?, password_salt = ?,"
#                        " must_change_password = 1 WHERE id = ?"
#                        " AND COALESCE(username, '') != ''",
#                        (hash_password(password, salt), salt, uid)).rowcount == 0:
#                    self.db.rollback()
#                    return False
#                self.db.execute("DELETE FROM panel_sessions WHERE user_id = ?",
#                                (uid,))
#                self.db.commit()
#                return True
#            except BaseException:
#                self.db.rollback()
#                raise
#
#    # The same two reads smartdns-panel does, spelled the same way. This panel
#    # keeps its own connection rather than importing that one, so they are
#    # written twice on purpose - but they must agree, because one writes what
#    # the other turns into the relays' bypass lists.
#    def template_groups(self, template_id):
#        return {(r["service_key"], r["group_key"]) for r in self.q(
#            "SELECT service_key, group_key FROM template_services"
#            " WHERE template_id = ?", (template_id,))}
#
#    def template_domains_off(self, template_id):
#        return {r["domain"] for r in self.q(
#            "SELECT domain FROM template_domains_off WHERE template_id = ?",
#            (template_id,))}
#
#    def snapshot(self, path):
#        """A consistent copy of the database at `path`, minus the metrics.
#
#        VACUUM INTO rather than copying the file: sqlite is in WAL mode, so
#        what is on disk is not the whole story and a copy taken while the bot
#        is writing can produce something that will not open.
#
#        Health samples are dropped. They are the bulk of the rows and none of
#        the value - what matters in a restore is who the customers are, what
#        they bought and what they have used.
#        """
#        with self.lock:
#            self.db.execute("VACUUM INTO ?", (path,))
#        copy = sqlite3.connect(path)
#        try:
#            copy.execute("DELETE FROM metrics")
#            copy.commit()
#            copy.execute("VACUUM")
#        finally:
#            copy.close()
#        return path
#
#    def close(self):
#        with self.lock:
#            self.db.close()
#
#
#def inspect_backup(path):
#    """Check a file really is one of our backups, and say what is in it.
#
#    Raises rather than returning a verdict, because every caller wants to stop.
#    Opening as sqlite is not enough: somebody's unrelated database would pass
#    that and then replace every customer with nothing.
#    """
#    db = sqlite3.connect(path)
#    try:
#        status = db.execute("PRAGMA integrity_check").fetchone()[0]
#        if status != "ok":
#            raise ValueError("integrity check failed: %s" % status)
#        have = {r[0] for r in db.execute(
#            "SELECT name FROM sqlite_master WHERE type = 'table'")}
#        missing = {"users", "ips", "templates", "settings"} - have
#        if missing:
#            raise ValueError("not a panel backup - missing %s"
#                             % ", ".join(sorted(missing)))
#        return {t: db.execute("SELECT count(*) FROM " + t).fetchone()[0]
#                for t in ("users", "ips", "templates", "transactions")}
#    finally:
#        db.close()
#
#
#def parse_upload(body, content_type, field):
#    """Pull one file out of a multipart/form-data body.
#
#    Hand-written because the stdlib's cgi module was removed in Python 3.13
#    and this panel is not allowed a pip step. One field is all that is needed,
#    so the parser only has to find its part and hand back the bytes between
#    that part's blank line and the next boundary.
#    """
#    marker = "boundary="
#    if marker not in (content_type or ""):
#        raise ValueError("not a file upload")
#    boundary = content_type.split(marker, 1)[1].strip().strip('"')
#    sep = b"--" + boundary.encode("latin-1")
#    want = ('name="%s"' % field).encode("latin-1")
#    for part in body.split(sep):
#        head, blank, data = part.partition(b"\r\n\r\n")
#        if not blank or want not in head:
#            continue
#        # The bytes before the next boundary carry a trailing CRLF that
#        # belongs to the delimiter, not to the file.
#        return data[:-2] if data.endswith(b"\r\n") else data
#    raise ValueError("no file was chosen")
#
#
## A checked backup waiting for the operator to confirm. In memory on purpose:
## a pending restore should not survive a restart, because nobody would
## remember agreeing to it.
#PENDING = {}
#
#
#CATALOGUE = []
#
#
#def load_catalogue():
#    try:
#        with open(SERVICES_FILE, encoding="utf-8") as fh:
#            services = json.load(fh).get("services", [])
#    except Exception:
#        services = []
#    services.append({"key": "custom", "label": "دامنه‌های دلخواه شما",
#                     "groups": [{"key": "main", "label": "همه", "domains": []}]})
#    return services
#
#
#def catalogue_now():
#    """The catalogue with the operator's own domains filled in.
#
#    Those live in the database, not the catalogue file, so CATALOGUE carries
#    their service with an empty list - and the template page, drawn from it,
#    showed "your domains" as having none while the relay was routing them.
#    """
#    custom = [r["domain"] for r in STORE.q(
#        "SELECT domain FROM custom_domains ORDER BY domain")]
#    return [dict(svc, groups=[dict(g, domains=custom) for g in svc["groups"]])
#            if svc["key"] == "custom" else svc for svc in CATALOGUE]
#
#
## -------------------------------------------------------------------- pages
## Every colour is named once, here. The light theme is the same names with
## other values, so no rule below can be left dark in one of them. Until
## somebody picks, the browser's own setting decides; the button in the corner
## overrides it, and the choice is kept in that browser.
#DARK = """color-scheme:dark;
# --bg:#0f1115;--card:#171a21;--line:#262b36;--line2:#30363d;--row:#1c2029;
# --track:#0f1115;--fg:#e6e8eb;--head:#c9d1d9;--muted:#8b949e;--dim:#9aa4b2;
# --faint:#6e7681;--accent:#7dd3a0;--accent2:#58a6ff;--btn:#238636;
# --btn-hover:#2ea043;--on-btn:#ffffff;--danger:#6e2c2c;--warn:#e3b341;
# --bad:#f85149;--good-bg:#12261a;--err-bg:#2b1416;--warn-bg:#2b2411;
# --warn-line:#6e5a2c;--sun:inline;--moon:none"""
#LIGHT = """color-scheme:light;
# --bg:#f6f8fa;--card:#ffffff;--line:#d0d7de;--line2:#afb8c1;--row:#eaeef2;
# --track:#eaeef2;--fg:#1f2328;--head:#24292f;--muted:#59636e;--dim:#57606a;
# --faint:#6e7781;--accent:#1a7f37;--accent2:#0969da;--btn:#1f883d;
# --btn-hover:#1a7f37;--on-btn:#ffffff;--danger:#cf222e;--warn:#9a6700;
# --bad:#cf222e;--good-bg:#dafbe1;--err-bg:#ffebe9;--warn-bg:#fff8c5;
# --warn-line:#d4a72c;--sun:none;--moon:inline"""
#THEME_CSS = (":root{%s}\n"
#             "@media (prefers-color-scheme: light){:root:not([data-theme=dark]){%s}}\n"
#             ":root[data-theme=light]{%s}\n" % (DARK, LIGHT, LIGHT))
## In <head>, so a page opens in the chosen theme instead of flashing the
## other one first. Only the two known values are taken from storage.
#THEME_HEAD = ("<script>try{var t=localStorage.getItem('theme');"
#              "if(t=='light'||t=='dark')document.documentElement"
#              ".setAttribute('data-theme',t)}catch(e){}</script>")
#THEME_BUTTON = (
#    "<button type='button' class='theme' title='روشن / تیره' aria-label='روشن / تیره'"
#    " onclick=\"(function(r){var c=r.getAttribute('data-theme')||"
#    "(matchMedia('(prefers-color-scheme: light)').matches?'light':'dark'),"
#    "n=c=='light'?'dark':'light';r.setAttribute('data-theme',n);"
#    "try{localStorage.setItem('theme',n)}catch(e){}})(document.documentElement)\">"
#    "<span class='sun'>☀️</span><span class='moon'>🌙</span></button>")
#
#CSS = THEME_CSS + """
#*{box-sizing:border-box}
#body{margin:0;background:var(--bg);color:var(--fg);
# font:14px/1.7 Vazirmatn,system-ui,'Segoe UI',Tahoma,sans-serif;position:relative}
#a{color:var(--accent);text-decoration:none}
#.wrap{max-width:1000px;margin:0 auto;padding:24px}
#header{display:flex;align-items:center;justify-content:space-between;
# border-bottom:1px solid var(--line);padding-bottom:14px;margin-bottom:22px;flex-wrap:wrap;gap:12px}
#h1{font-size:18px;margin:0;font-weight:600}
#nav a{margin-left:16px;color:var(--dim);font-size:14px}
#nav a.on{color:var(--accent);font-weight:600}
#.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px;margin-bottom:16px}
#.card h2{font-size:15px;margin:0 0 14px;font-weight:600;color:var(--head)}
#table{width:100%;border-collapse:collapse;font-size:13px}
#th{text-align:right;color:var(--muted);font-weight:500;padding:8px 6px;border-bottom:1px solid var(--line)}
#td{padding:9px 6px;border-bottom:1px solid var(--row)}
#tr:last-child td{border-bottom:0}
#code{background:var(--bg);padding:2px 6px;border-radius:5px;color:var(--accent);font-size:12px}
#.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px}
#.stat{background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:14px}
#.stat .n{font-size:21px;font-weight:600}
#.stat .l{color:var(--muted);font-size:12px;margin-top:3px}
#.bar{height:6px;background:var(--track);border-radius:3px;overflow:hidden;margin-top:7px}
#.bar i{display:block;height:100%;background:var(--accent)}
#.bar i.warn{background:var(--warn)}
#.bar i.hot{background:var(--bad)}
#input,select,button,textarea{font:inherit;background:var(--bg);color:var(--fg);
# border:1px solid var(--line2);border-radius:7px;padding:8px 10px}
#button{background:var(--btn);border-color:var(--btn);color:var(--on-btn);cursor:pointer;font-weight:600}
#button:hover{background:var(--btn-hover)}
#button.danger{background:var(--danger);border-color:var(--danger)}
#button.ghost{background:transparent;border-color:var(--line2);color:var(--dim);font-weight:400}
#button.del{background:transparent;border-color:var(--bad);color:var(--bad);font-weight:400}
#button.del:hover{background:var(--err-bg)}
#.onetime code{display:inline-block;direction:ltr;font-size:22px;letter-spacing:1px;
# padding:8px 14px}
#form.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
#.muted{color:var(--muted);font-size:12px}
#.ok{color:var(--accent)}.bad{color:var(--bad)}.warn{color:var(--warn)}
#.msg{padding:11px 14px;border-radius:9px;margin-bottom:16px;font-size:13px}
#.msg.good{background:var(--good-bg);border:1px solid var(--btn)}
#.msg.err{background:var(--err-bg);border:1px solid var(--danger)}
#label{display:block;color:var(--muted);font-size:12px;margin-bottom:5px}
#.f{margin-bottom:12px}
#.login{max-width:340px;margin:14vh auto}
#.receipt{border:1px solid var(--line);border-radius:10px;padding:14px;
# margin-bottom:14px;background:var(--bg)}
#.receipt .who{font-size:14px;font-weight:600;margin-bottom:10px}
#.receipt img{max-width:100%;max-height:420px;border-radius:8px;
# border:1px solid var(--line);display:block}
#td.acts{white-space:nowrap}
#td.acts form{display:inline}
#td.acts button{padding:6px 10px;font-size:12px;margin-right:4px}
#a.dl{display:inline-block;background:var(--btn);color:var(--on-btn);font-weight:600;
# padding:9px 16px;border-radius:7px;text-decoration:none}
#a.dl:hover{background:var(--btn-hover)}
#.svc{display:inline-block;margin:0 0 8px 14px}
#.svc label{display:inline;color:var(--fg);font-size:13px}
#details.svc{display:block;margin:0 0 6px;border:1px solid var(--line);border-radius:9px;
# background:var(--bg)}
#details.svc>summary{padding:9px 12px;cursor:pointer;list-style:none;
# display:flex;align-items:center;gap:10px}
#details.svc>summary::-webkit-details-marker{display:none}
#details.svc>summary::before{content:'▸';color:var(--muted);font-size:11px;
# transition:transform .12s}
#details.svc[open]>summary::before{transform:rotate(-90deg)}
#details.svc[open]{border-color:var(--line2)}
#details.svc>summary label{flex:1}
#.doms{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));
# gap:2px 14px;padding:4px 30px 12px;border-top:1px solid var(--row);margin-top:2px}
#.doms label{display:flex;align-items:center;gap:7px;color:var(--dim);font-size:12px;
# font-family:ui-monospace,Consolas,monospace;margin:0;padding:2px 0}
#.doms label span{direction:ltr;overflow:hidden;text-overflow:ellipsis;
# white-space:nowrap}
#.doms input{margin:0}
#.optin{display:block;font-size:11px;color:var(--warn);font-weight:400;margin-top:2px}
#.pick{margin-right:auto;display:flex;gap:6px}
#.pick button{padding:3px 10px;font-size:11px;font-weight:400;
# background:transparent;border:1px solid var(--line2);color:var(--muted)}
#.pick button:hover{background:var(--row)}
#.brand{text-align:center;margin:4px 0 26px;direction:ltr;line-height:1.15}
#.brand .mark{font-size:clamp(28px,6vw,38px);vertical-align:middle;margin-right:10px}
#.brand .name{display:inline-block;vertical-align:middle;font-size:clamp(34px,8vw,50px);
# font-weight:800;letter-spacing:1.5px;color:var(--accent);
# background:linear-gradient(90deg,var(--accent),var(--accent2));-webkit-background-clip:text;
# background-clip:text;-webkit-text-fill-color:transparent}
#footer{text-align:center;color:var(--faint);font-size:12px;padding:26px 0 6px;direction:ltr}
#button.theme{position:absolute;top:14px;left:14px;width:38px;height:38px;margin:0;
# padding:0;display:flex;align-items:center;justify-content:center;border-radius:50%;
# background:var(--card);border:1px solid var(--line2);color:var(--fg);
# font-size:17px;font-weight:400;line-height:1;cursor:pointer}
#button.theme:hover{background:var(--row)}
#.theme .sun{display:var(--sun)}.theme .moon{display:var(--moon)}
#"""
#
## Where the installer writes the version it installed. Read per page rather
## than once, so it can never disagree with what is on disk.
#VERSION_FILE = "/var/lib/smart-dns/version"
#
#
#def app_version():
#    try:
#        with open(VERSION_FILE) as fh:
#            return fh.read().strip()[:20]
#    except OSError:
#        return ""
#
#
#def brand_html():
#    return ("<div class='brand'><span class='mark'>🩺</span>"
#            "<span class='name'>doctor dns</span></div>")
#
#
#def footer_html():
#    v = app_version()
#    return "<footer>doctor dns%s</footer>" % (" v" + html.escape(v) if v else "")
#
#
#def font_face(prefix):
#    """Vazirmatn, from this panel. swap: the page is readable in the system
#    font at once, on a slow line, and changes over when the font arrives."""
#    return ("@font-face{font-family:Vazirmatn;font-weight:100 900;"
#            "font-display:swap;src:url('%s/vazirmatn.woff2?v=%s') format('woff2')}\n"
#            % (prefix, FONT_VERSION))
#
#
#_FONT = []
#
#
#def font_bytes():
#    """The font file, read once. None while it is not there - an install
#    older than the font - and the pages fall back to the system font."""
#    if not _FONT:
#        try:
#            with open(FONT_FILE, "rb") as fh:
#                _FONT.append(fh.read())
#        except OSError:
#            return None
#    return _FONT[0]
#
#
#class Operators:
#    """Which operator an address is on, from smartdns-operators' daily file.
#
#    Read again only when the file changes. An address goes to the longest
#    block that holds it: one operator can announce a small block inside
#    another's larger one, and the smaller is what actually routes it.
#    """
#
#    def __init__(self, path):
#        self.path = path
#        self.state = (None, [], {})     # mtime, lengths longest first, tables
#
#    def _tables(self):
#        try:
#            mtime = os.stat(self.path).st_mtime
#        except OSError:
#            self.state = (None, [], {})
#            return self.state
#        if mtime == self.state[0]:
#            return self.state
#        try:
#            with open(self.path, encoding="utf-8") as fh:
#                ops = list(json.load(fh)["operators"].values())
#        except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
#            # Keep the last good list, and remember this file was seen, so
#            # it is reported once rather than once for every row of a page.
#            log(WARN, "%s unreadable, keeping the last list: %r" % (self.path, e))
#            self.state = (mtime,) + self.state[1:]
#            return self.state
#        tables = {}
#        for op in ops:
#            for p in op.get("prefixes") or ():
#                try:
#                    net = ipaddress.ip_network(p, strict=False)
#                except (TypeError, ValueError):
#                    continue
#                shift = net.max_prefixlen - net.prefixlen
#                tables.setdefault((net.version, net.prefixlen), {})[
#                    int(net.network_address) >> shift] = op.get("name") or ""
#        # One tuple, swapped in whole: a request thread reading it never sees
#        # the lengths of one file with the tables of another.
#        self.state = (mtime, sorted(tables, key=lambda k: -k[1]), tables)
#        return self.state
#
#    def name(self, ip):
#        """The operator's name; "" for none of them; None with no list yet."""
#        _, lengths, tables = self._tables()
#        if not tables:
#            return None
#        try:
#            addr = ipaddress.ip_address(ip)
#        except ValueError:
#            return None
#        for version, plen in lengths:
#            if version == addr.version:
#                hit = tables[(version, plen)].get(
#                    int(addr) >> (addr.max_prefixlen - plen))
#                if hit is not None:
#                    return hit
#        return ""
#
#
#OPERATORS = Operators(OPERATORS_FILE)
#
#
## Letters and digits nobody misreads when a password is read out or copied
## from a chat: no 0/o, no 1/l/i.
#TEMP_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
#
#
#def temp_password():
#    """Three groups of four - easy to pass on, and about 59 bits."""
#    return "-".join("".join(secrets.choice(TEMP_ALPHABET) for _ in range(4))
#                    for _ in range(3))
#
#
#def temp_password_card(name, password):
#    return ("<div class='card'><h2>رمز موقت «%s»</h2>"
#            "<p class='onetime'><code>%s</code></p>"
#            "<p>این رمز را برای مشتری بفرستید. فقط همین یک بار نشان داده می‌شود.</p>"
#            "<ul class='muted'>"
#            "<li>مشتری از همهٔ دستگاه‌ها بیرون آمد. اینترنتش قطع نشده.</li>"
#            "<li>با اولین ورود باید رمز خودش را انتخاب کند؛ بعد از آن این رمز "
#            "دیگر کار نمی‌کند.</li>"
#            "<li>این صفحه را رفرش نکنید: رفرش یک رمز تازهٔ دیگر می‌سازد.</li></ul>"
#            "<p><a href='/%s/users'>برگشت به کاربران</a></p></div>"
#            % (html.escape(name), html.escape(password),
#               html.escape(CFG["ADMIN_PATH"])))
#
#
#def operator_label(ip):
#    """The line under an address on the users page. "سایر" for an address
#    none of the listed operators announce; nothing at all while there is no
#    list yet - an empty line is honest, a guess is not."""
#    if not ip:
#        return ""
#    name = OPERATORS.name(ip)
#    if name is None:
#        return ""
#    return "<br><span class='muted'>%s</span>" % html.escape(name or "سایر")
#
#
#def page(title, body, cfg, active="", msg=None, msg_kind="good"):
#    nav = ""
#    for path, label in (("", "خانه"), ("users", "کاربران"), ("receipts", "رسیدها"),
#                        ("templates", "قالب‌ها"), ("domains", "دامنه‌ها"),
#                        ("settings", "تنظیمات"), ("logs", "لاگ")):
#        cls = " class='on'" if active == path else ""
#        nav += "<a href='/%s/%s'%s>%s</a>" % (cfg["ADMIN_PATH"], path, cls, label)
#    banner = ""
#    if msg:
#        banner = "<div class='msg %s'>%s</div>" % (msg_kind, html.escape(msg))
#    return ("""<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
#<meta name="viewport" content="width=device-width,initial-scale=1">
#<link rel="icon" href="data:,">
#<title>%s</title>%s<style>%s</style></head><body>%s<div class="wrap">%s
#<header><h1>%s</h1><nav>%s<a href='/%s/logout'>خروج</a></nav></header>
#%s%s%s</div></body></html>""" % (html.escape(title), THEME_HEAD,
#                                 font_face("/" + cfg["ADMIN_PATH"]) + CSS,
#                                 THEME_BUTTON, brand_html(),
#                                 html.escape(title), nav, cfg["ADMIN_PATH"],
#                                 banner, body, footer_html()))
#
#
#def login_page(cfg, error=None):
#    err = "<div class='msg err'>%s</div>" % html.escape(error) if error else ""
#    # The action is spelled out rather than left to default to the current
#    # URL. A form with no action posts wherever the browser happens to be,
#    # which after a bookmark to a page that has moved is not the panel.
#    return """<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
#<meta name="viewport" content="width=device-width,initial-scale=1">
#<link rel="icon" href="data:,">
#<title>ورود</title>%s<style>%s</style></head><body>%s<div class="wrap">%s
#<div class="login" style="margin-top:6vh">
#<div class="card"><h2>پنل مدیریت</h2>%s
#<form method="post" action="/%s/"><div class="f"><label>رمز عبور</label>
#<input type="password" name="password" autofocus style="width:100%%"></div>
#<button type="submit" style="width:100%%">ورود</button></form></div>
#</div>%s</div></body></html>""" % (THEME_HEAD,
#                                   font_face("/" + cfg["ADMIN_PATH"]) + CSS,
#                                   THEME_BUTTON, brand_html(),
#                                   err, cfg["ADMIN_PATH"], footer_html())
#
#
#def bar(used, total):
#    if not total:
#        return "<span class='muted'>-</span>"
#    pct = min(100, int(100.0 * used / total))
#    cls = "hot" if pct >= 90 else ("warn" if pct >= 75 else "")
#    return ("%d%% <span class='muted'>(%s از %s)</span>"
#            "<div class='bar'><i class='%s' style='width:%d%%'></i></div>"
#            % (pct, human(used), human(total), cls, pct))
#
#
## ----------------------------------------------------------------- handler
## Sessions live in the database, not in this process. They used to be a dict,
## which meant every restart signed the operator out - and this panel restarts
## whenever it is upgraded, whenever its port or path is changed, and after a
## restore. Being signed out is not only an annoyance: without a session, a
## visit to the bare address is answered with the same bare 404 a stranger
## gets, which is how "the panel 404s sometimes" was really happening.
##
## Failed attempts stay in memory. Losing that count on restart only makes
## guessing slightly easier for someone who cannot cause restarts anyway.
#ATTEMPTS = {}          # address -> [count, first_failure_time]
## ------------------------------------------------------------------ logging
## journald reads a leading <N> on a line as its syslog level. Warnings and
## errors carry one, so `journalctl -p warning` - which is what
## `smartdns-logs -e` runs - shows exactly the problems. Ordinary lines stay
## unmarked and land at info, as they always did. Before this everything
## landed at info, stderr included, and a failure looked like a heartbeat.
#INFO, WARN, ERROR = 6, 4, 3
## The visitor went away, or never finished saying hello. Not a fault here.
#GONE = (ConnectionError, TimeoutError, ssl.SSLError)
#
#
#def log(level, msg):
#    tag = "<%d>" % level if level < INFO else ""
#    for line in str(msg).splitlines() or [""]:
#        print(tag + line, flush=True)
#
#
#def log_exception(what):
#    """An error with its traceback, every line at error level. journald makes
#    each line its own entry, and at info all but the first would be lost
#    among the ordinary ones."""
#    log(ERROR, "%s\n%s" % (what, traceback.format_exc().rstrip()))
#
#
#def log_access(h, prefix, code, path, who=""):
#    """One line for one request: what was asked, the answer, how long it took
#    and who asked. Server errors at error level; everything else is info."""
#    try:
#        code = int(code)
#    except (TypeError, ValueError):
#        code = 0
#    ms = (time.monotonic() - getattr(h, "_t0", time.monotonic())) * 1000
#    # 501 is a scanner's GET to a POST-only port: the visitor's mistake.
#    log(ERROR if code >= 500 and code != 501 else INFO, "%s %s %s %d %dms from %s%s" % (
#        prefix, getattr(h, "command", None) or "-", path, code, ms,
#        h.client_address[0], " " + who if who else ""))
#
#
## Form fields never written to the journal, whatever the action.
#SECRET_FIELDS = re.compile(r"pass|token|secret|session|salt|hash", re.I)
#
#
#def describe(params):
#    """An action's form, fit for the journal: no passwords or tokens, and a
#    long list - a template's domains - as a count rather than every name."""
#    out = []
#    for k in sorted(params):
#        vals = [v for v in params[k] if v != ""]
#        if not vals:
#            continue
#        if SECRET_FIELDS.search(k):
#            out.append("%s=***" % k)
#        elif len(vals) > 4:
#            out.append("%s=[%d]" % (k, len(vals)))
#        else:
#            out.append("%s=%s" % (k, ",".join(v[:40] for v in vals)))
#    return " " + " ".join(out) if out else ""
#
#
## How long a visitor may take over the TLS handshake, and then how long any one
## read or write may stall. Per operation, so an upload that keeps moving is
## never cut off, while a connection that has gone quiet is let go.
#HANDSHAKE_TIMEOUT = 10
#IO_TIMEOUT = 30
#
#
#class TLSServer(http.server.ThreadingHTTPServer):
#    """TLS per connection, under a deadline - never on the listening socket.
#
#    Wrapping the listening socket runs every visitor's handshake inside
#    accept(), on the one thread that accepts for all of them and with no
#    timeout, so a single connection that opens and then says nothing freezes
#    the server for everybody until it goes away. The customer panel froze
#    exactly that way in production, and this server was built the same way.
#    Here accept() only accepts; a stalled visitor stalls only its own thread.
#
#    ctx=None serves plain http. That is for tests - main() refuses to.
#    """
#    daemon_threads = True
#
#    def __init__(self, addr, handler, ctx):
#        self.ctx = ctx
#        super().__init__(addr, handler)
#
#    def finish_request(self, request, client_address):
#        if self.ctx is None:
#            return super().finish_request(request, client_address)
#        request.settimeout(HANDSHAKE_TIMEOUT)
#        try:
#            tls = self.ctx.wrap_socket(request, server_side=True)
#        except (ssl.SSLError, OSError):
#            return      # a scanner, a dropped phone, plain http to an https port
#        try:
#            tls.settimeout(IO_TIMEOUT)
#            self.RequestHandlerClass(tls, client_address, self)
#        except (ssl.SSLError, OSError):
#            pass
#        finally:
#            try:
#                tls.close()
#            except OSError:
#                pass
#
#    def handle_error(self, request, client_address):
#        # Whatever a handler did not catch, with its traceback, at error
#        # level. http.server's default prints it at info, where nobody looks.
#        if isinstance(sys.exc_info()[1], GONE):
#            return
#        log_exception("request from %s failed" % client_address[0])
#
#
#STORE = None
#CFG = {}
#
#
#class Admin(http.server.BaseHTTPRequestHandler):
#    server_version = "smartdns"
#    protocol_version = "HTTP/1.1"
#
#    def log_message(self, fmt, *args):
#        # http.server's own notes - a malformed request, a timeout. They can
#        # quote the raw request line, so the secret path is masked here too.
#        msg = fmt % args
#        if CFG.get("ADMIN_PATH"):
#            msg = msg.replace(CFG["ADMIN_PATH"], "<admin>")
#        log(INFO, "admin %s from %s" % (msg, self.client_address[0]))
#
#    def parse_request(self):
#        self._t0 = time.monotonic()
#        return super().parse_request()
#
#    def log_request(self, code="-", size="-"):
#        log_access(self, "admin", code, self.shown_path())
#
#    def shown_path(self):
#        """The path for the journal, with the secret part shown as <admin>
#        and the query - only ever the message after an action - left off."""
#        path = urllib.parse.urlparse(getattr(self, "path", "") or "").path
#        secret = CFG.get("ADMIN_PATH") or ""
#        if secret and (path == "/" + secret or path.startswith("/" + secret + "/")):
#            path = "/<admin>" + path[len(secret) + 1:]
#        return path[:120]
#
#    # -- plumbing ---------------------------------------------------------
#    def send(self, body, code=200, headers=None):
#        blob = body.encode("utf-8") if isinstance(body, str) else body
#        # Start the header buffer clean. Nothing reaches the socket until
#        # end_headers(), so a send() that raised part-way through leaves a
#        # half-written status line behind; without this, the error page that
#        # follows is appended to it and the browser is handed two responses in
#        # one - which it reports as corrupted content rather than as an error.
#        self._headers_buffer = []
#        self.send_response(code)
#        self.send_header("Content-Type", "text/html; charset=utf-8")
#        self.send_header("Content-Length", str(len(blob)))
#        # This panel is only ever reached over TLS, and none of it should sit
#        # in a cache or be framed by anything.
#        self.send_header("Cache-Control", "no-store")
#        self.send_header("X-Frame-Options", "DENY")
#        self.send_header("X-Content-Type-Options", "nosniff")
#        self.send_header("Referrer-Policy", "no-referrer")
#        for k, v in (headers or {}).items():
#            self.send_header(k, v)
#        self.end_headers()
#        self.wfile.write(blob)
#
#    def send_font(self):
#        """The one thing this panel lets a browser keep: the same file for
#        everybody, and a new version comes at a new address."""
#        blob = font_bytes()
#        if blob is None:
#            return self.send("<h1>404</h1>", 404)
#        self._headers_buffer = []
#        self.send_response(200)
#        self.send_header("Content-Type", "font/woff2")
#        self.send_header("Content-Length", str(len(blob)))
#        self.send_header("Cache-Control", "public, max-age=31536000, immutable")
#        self.send_header("X-Content-Type-Options", "nosniff")
#        self.end_headers()
#        self.wfile.write(blob)
#
#    def redirect(self, path, headers=None):
#        """Redirect, percent-encoding anything that is not plain ascii.
#
#        Every message this panel shows after an action is Persian, and it
#        travels in the query string of a Location header. A header can only
#        carry latin-1, so an unencoded message makes send_header raise in the
#        middle of the response - which the browser reports as corrupted
#        content, after the action has already been carried out.
#        """
#        base, sep, query = path.lstrip("/").partition("?")
#        if sep:
#            fields = []
#            for item in query.split("&"):
#                key, _, value = item.partition("=")
#                # A message starting with ! is a refusal - a bad number, a
#                # name already taken. The request line cannot say which; this
#                # can.
#                if key == "m" and value.startswith("!"):
#                    log(WARN, "admin %s refused: %s"
#                        % (getattr(self, "_action", "-"), value[1:]))
#                fields.append("%s=%s" % (key, urllib.parse.quote(value, safe="")))
#            query = "?" + "&".join(fields)
#        h = {"Location": "/%s/%s%s" % (CFG["ADMIN_PATH"], base, query)}
#        h.update(headers or {})
#        self.send("", 303, h)
#
#    def body_params(self):
#        length = int(self.headers.get("Content-Length", 0) or 0)
#        # A file upload is read as bytes elsewhere; decoding a database as
#        # utf-8 and running it through parse_qs would be nonsense.
#        if "multipart/form-data" in (self.headers.get("Content-Type") or ""):
#            self.raw_body = self.rfile.read(min(length, MAX_UPLOAD))
#            return {}
#        raw = self.rfile.read(length).decode("utf-8", "replace") if length else ""
#        return urllib.parse.parse_qs(raw, keep_blank_values=True)
#
#    # -- backup and restore ----------------------------------------------
#    def send_backup(self):
#        stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
#        # Beside the database rather than in /tmp: the unit sets PrivateTmp, so
#        # /tmp is a mount point of its own, and the restore path below cannot
#        # rename across one.
#        path = os.path.join(os.path.dirname(DB), ".backup-%s.db" % stamp)
#        try:
#            STORE.snapshot(path)
#            with open(path, "rb") as fh:
#                blob = fh.read()
#        except Exception as e:
#            log_exception("backup failed: %r" % e)
#            return self.redirect("settings?m=!پشتیبان‌گیری نشد: %s" % e)
#        finally:
#            try:
#                os.unlink(path)
#            except OSError:
#                pass
#        return self.send(blob, 200, {
#            "Content-Type": "application/octet-stream",
#            "Content-Disposition":
#                'attachment; filename="smartdns-backup-%s.db"' % stamp})
#
#    # -- receipts ---------------------------------------------------------
#    def send_receipt(self, ident):
#        """Hand back the stored image itself, for the <img> on the page.
#
#        Served from here rather than inlined as a data URI: the page lists
#        every pending receipt, and inlining several megabytes of base64 into
#        the HTML would make the list slow to open over an Iranian connection
#        even when the operator only wants to glance at one.
#        """
#        row = STORE.one("SELECT receipt_blob, receipt_type FROM transactions"
#                        " WHERE id = ?", (int(ident) if ident.isdigit() else 0,))
#        if not row or not row["receipt_blob"]:
#            return self.send("<h1>404</h1>", 404)
#        return self.send(bytes(row["receipt_blob"]), 200, {
#            "Content-Type": row["receipt_type"] or "application/octet-stream",
#            # Not inline for a PDF: opening one in the panel's own origin is a
#            # needless way to run somebody else's file next to the session.
#            "Content-Disposition": "inline; filename=receipt-%s" % ident})
#
#    def receipts(self):
#        p = CFG["ADMIN_PATH"]
#        rows = STORE.q(
#            "SELECT t.*, u.first_name, u.username, u.phone, u.telegram_id,"
#            " length(t.receipt_blob) AS size"
#            " FROM transactions t JOIN users u ON u.id = t.user_id"
#            " ORDER BY CASE t.status WHEN 'pending' THEN 0 ELSE 1 END,"
#            " t.created_at DESC LIMIT 100")
#        pending = [r for r in rows if r["status"] == "pending"]
#        out = ["<div class='card'><h2>رسیدهای در انتظار (%d)</h2>" % len(pending)]
#        if not pending:
#            out.append("<p class='muted'>رسیدی نرسیده.</p>")
#        for r in pending:
#            who = (r["first_name"] or "") + " · " + (
#                r["username"] or r["phone"]
#                or str(r["telegram_id"] or "#%d" % r["user_id"]))
#            out.append(
#                "<div class='receipt'>"
#                "<div class='who'>%s<span class='muted'> · %s · %s</span></div>"
#                "<a href='/%s/receipt/%d' target='_blank'>"
#                "<img src='/%s/receipt/%d' alt='رسید'></a>"
#                "<div class='row' style='margin-top:10px'>"
#                "<form method='post' action='/%s/receipt-decide'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<input type='hidden' name='to' value='approved'>"
#                "<button>تأیید</button></form>"
#                "<form method='post' action='/%s/receipt-decide'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<input type='hidden' name='to' value='rejected'>"
#                "<button class='danger'>رد</button></form>"
#                "<a class='muted' href='/%s/users'>ویرایش حساب این کاربر ←</a>"
#                "</div></div>"
#                % (html.escape(who), html.escape(r["created_at"][:16]),
#                   human(r["size"] or 0),
#                   p, r["id"], p, r["id"], p, r["id"], p, r["id"], p))
#        out.append("<p class='muted'>تأیید یا رد فقط تصمیم را ثبت می‌کند و عکس "
#                   "را پاک می‌کند؛ سهمیه و زمان را خودتان در صفحهٔ کاربران "
#                   "می‌گذارید.</p></div>")
#
#        decided = [r for r in rows if r["status"] != "pending"]
#        if decided:
#            out.append("<div class='card'><h2>تصمیم‌های قبلی</h2>"
#                       "<table><tr><th>کاربر</th><th>رسید</th><th>تصمیم</th>"
#                       "<th>تاریخ</th></tr>")
#            for r in decided[:40]:
#                out.append("<tr><td>%s</td><td>%s</td><td class='%s'>%s</td>"
#                           "<td>%s</td></tr>"
#                           % (html.escape((r["first_name"] or "") + " · " +
#                                          (r["username"] or r["phone"] or "")),
#                              html.escape(r["created_at"][:16]),
#                              "ok" if r["status"] == "approved" else "bad",
#                              "تأیید شد" if r["status"] == "approved" else "رد شد",
#                              html.escape((r["decided_at"] or "")[:16])))
#            out.append("</table></div>")
#        return "".join(out)
#
#    def take_upload(self):
#        """Stage an uploaded file and describe it, or explain why it is no good."""
#        try:
#            blob = parse_upload(getattr(self, "raw_body", b""),
#                                self.headers.get("Content-Type"), "file")
#        except ValueError as e:
#            return self.redirect("settings?m=!%s" % e)
#        if not blob:
#            return self.redirect("settings?m=!فایل خالی بود")
#        if len(blob) >= MAX_UPLOAD:
#            return self.redirect("settings?m=!فایل خیلی بزرگ است")
#
#        path = os.path.join(os.path.dirname(DB),
#                            ".restore-%s.db" % secrets.token_hex(6))
#        with open(path, "wb") as fh:
#            fh.write(blob)
#        try:
#            counts = inspect_backup(path)
#        except Exception as e:
#            os.unlink(path)
#            return self.redirect("settings?m=!این فایل نسخهٔ پشتیبان سالمی نیست: %s" % e)
#
#        old = PENDING.pop("path", None)
#        if old and os.path.exists(old):
#            os.unlink(old)
#        PENDING.update({"path": path, "counts": counts, "size": len(blob)})
#        return self.redirect("restore")
#
#    def restore_page(self):
#        p = CFG["ADMIN_PATH"]
#        if not PENDING.get("path") or not os.path.exists(PENDING.get("path", "")):
#            return ("<div class='card'><h2>بازگردانی</h2><p class='muted'>فایلی "
#                    "برای بازگردانی منتظر نیست. از <a href='/%s/settings'>تنظیمات</a> "
#                    "یک نسخهٔ پشتیبان بفرستید.</p></div>" % p)
#        c = PENDING["counts"]
#        now_c = STORE.one(
#            "SELECT (SELECT count(*) FROM users) u, (SELECT count(*) FROM ips) i,"
#            " (SELECT count(*) FROM templates) t,"
#            " (SELECT count(*) FROM transactions) x")
#        rows = [("کاربران", c["users"], now_c["u"]),
#                ("آی‌پی‌های ثبت‌شده", c["ips"], now_c["i"]),
#                ("قالب‌ها", c["templates"], now_c["t"]),
#                ("تراکنش‌ها", c["transactions"], now_c["x"])]
#        body = ["<div class='card'><h2>این فایل جایگزین دیتابیس فعلی شود؟</h2>",
#                "<p class='muted'>حجم فایل: %s</p>" % human(PENDING["size"]),
#                "<table class='tbl'><tr><th></th><th>در فایل</th>"
#                "<th>الان در سرویس</th></tr>"]
#        for label, new, old in rows:
#            cls = "" if new == old else " class='warn'"
#            body.append("<tr><td>%s</td><td%s>%d</td><td>%d</td></tr>"
#                        % (label, cls, new, old))
#        body.append("</table>")
#        body.append(
#            "<div class='msg err' style='margin-top:18px'>بازگردانی، دیتابیس "
#            "فعلی را کامل جایگزین می‌کند. از وضعیت فعلی قبلش یک نسخه کنار "
#            "دیتابیس نگه داشته می‌شود، پس این کار برگشت‌پذیر است — ولی سرویس "
#            "چند ثانیه‌ای ری‌استارت می‌شود.</div>")
#        body.append(
#            "<form method='post' action='/%s/restore-apply' style='display:inline'>"
#            "<button class='danger'>بله، جایگزین کن</button></form> "
#            "<form method='post' action='/%s/restore-cancel' style='display:inline'>"
#            "<button class='ghost'>انصراف</button></form></div>" % (p, p))
#        return "".join(body)
#
#    def moving_to(self, port, path):
#        """Hand back the new address, then restart onto it.
#
#        A redirect would be wrong: the browser would follow it to the old
#        address, which is about to stop answering. So this is a page, with the
#        new address on it, and the restart happens a second later - by which
#        time the operator has the link in front of them.
#        """
#        url = "https://%s:%s/%s/" % (panel_host(), port, path)
#        self.send(page("آدرس تازه",
#                       "<div class='card'><h2>آدرس پنل عوض شد</h2>"
#                       "<p>از این به بعد اینجاست — همین حالا ذخیره‌اش کنید:</p>"
#                       "<p><code>%s</code></p>"
#                       "<p class='muted'>پنل تا چند ثانیهٔ دیگر روی آدرس تازه "
#                       "بالا می‌آید. اگر باز نشد، به احتمال زیاد فایروال یا "
#                       "security group سرور پورت را نمی‌گذارد رد شود؛ از روی "
#                       "خود سرور با <code>smartdns-access</code> برش گردانید."
#                       "</p></div>" % html.escape(url), CFG, "settings"),
#                  200, {"Refresh": "6; url=%s" % url})
#        try:
#            self.wfile.flush()
#        except Exception:
#            pass
#        print("panel moving to %s" % url, flush=True)
#        threading.Timer(1.0, os._exit, (0,)).start()
#
#    def apply_restore(self):
#        path = PENDING.get("path")
#        if not path or not os.path.exists(path):
#            return self.redirect("settings?m=!چیزی برای بازگردانی نیست")
#        keep = "%s.before-restore-%s" % (
#            DB, datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"))
#        try:
#            STORE.snapshot(keep)
#            # Stop the bot before the swap. It holds the old file open and
#            # keeps writing to the journal beside it; deleting that journal
#            # underneath a running process is how a restore becomes corruption.
#            systemctl("stop", "smartdns-panel")
#            STORE.close()
#            os.replace(path, DB)
#            for suffix in ("-wal", "-shm"):
#                try:
#                    os.unlink(DB + suffix)
#                except OSError:
#                    pass
#            systemctl("start", "smartdns-panel")
#        except Exception as e:
#            log_exception("restore failed: %r" % e)
#            systemctl("start", "smartdns-panel")
#            return self.redirect("settings?m=!بازگردانی نشد: %s" % e)
#        PENDING.clear()
#
#        p = CFG["ADMIN_PATH"]
#        self.send(page("بازگردانی شد",
#                       "<div class='card'><h2>بازگردانی شد</h2>"
#                       "<p>نسخهٔ قبلی اینجا نگه داشته شد:</p><p><code>%s</code></p>"
#                       "<p class='muted'>این پنل هم دارد ری‌استارت می‌شود تا "
#                       "دیتابیس تازه را باز کند. چند ثانیه دیگر خودش برمی‌گردد.</p>"
#                       "<p><a href='/%s/users'>رفتن به کاربران</a></p></div>"
#                       % (html.escape(keep), p),
#                       CFG, "settings"),
#                  200, {"Refresh": "16; url=/%s/users" % p})
#        try:
#            self.wfile.flush()
#        except Exception:
#            pass
#        # This process still has the replaced file open, so the only honest way
#        # to pick up the new one is to let systemd start us again.
#        print("restarting after restore", flush=True)
#        threading.Timer(1.0, os._exit, (0,)).start()
#
#    @staticmethod
#    def one(params, key, default=""):
#        return (params.get(key) or [default])[0].strip()
#
#    # -- auth -------------------------------------------------------------
#    def session_token(self):
#        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
#        return cookie["sdns"].value if "sdns" in cookie else ""
#
#    def session_ok(self):
#        token = self.session_token()
#        if not token:
#            return False
#        row = STORE.one("SELECT expires_at FROM admin_sessions WHERE token = ?",
#                        (token,))
#        if not row:
#            return False
#        if (parse_ts(row["expires_at"]) or datetime.now(timezone.utc))                 <= datetime.now(timezone.utc):
#            STORE.run("DELETE FROM admin_sessions WHERE token = ?", (token,))
#            return False
#        return True
#
#    def locked_out(self):
#        rec = ATTEMPTS.get(self.client_address[0])
#        if not rec:
#            return False
#        count, first = rec
#        if time.time() - first > LOCKOUT_SECONDS:
#            ATTEMPTS.pop(self.client_address[0], None)
#            return False
#        return count >= MAX_TRIES
#
#    def note_failure(self):
#        addr = self.client_address[0]
#        count, first = ATTEMPTS.get(addr, (0, time.time()))
#        ATTEMPTS[addr] = (count + 1, first)
#
#    # -- routing ----------------------------------------------------------
#    def route(self):
#        prefix = "/" + CFG["ADMIN_PATH"]
#        path = urllib.parse.urlparse(self.path).path
#        if not path.startswith(prefix):
#            return None
#        rest = path[len(prefix):].strip("/")
#        return rest
#
#    def lost(self):
#        """Answer a request that did not name the secret path.
#
#        A stranger gets a bare 404 and learns nothing - that is the whole
#        point of the path. Somebody already holding a valid session is not a
#        stranger: they have full access already, so sending them to the panel
#        reveals nothing and saves them from the commonest way to meet this
#        page, which is typing the host without the path, or following a
#        bookmark from before the path or port was changed.
#        """
#        if self.session_ok():
#            return self.redirect("")
#        # Its request line names the path and who asked, the secret part
#        # masked, so "it 404s sometimes" stays answerable.
#        return self.send("<h1>404</h1>", 404)
#
#    def do_GET(self):
#        rest = self.route()
#        if rest is None:
#            return self.lost()
#        # Ahead of the session check: the sign-in page is drawn in it too.
#        if rest == "vazirmatn.woff2":
#            return self.send_font()
#        if rest == "logout":
#            cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
#            if "sdns" in cookie:
#                STORE.run("DELETE FROM admin_sessions WHERE token = ?",
#                          (cookie["sdns"].value,))
#            return self.redirect("", {"Set-Cookie": "sdns=; Max-Age=0; Path=/"})
#        if not self.session_ok():
#            return self.send(login_page(CFG))
#        if rest == "backup.db":
#            return self.send_backup()
#        if rest.startswith("receipt/"):
#            return self.send_receipt(rest.split("/", 1)[1])
#        try:
#            return self.view(rest)
#        except Exception as e:
#            log_exception("admin GET %s failed" % rest)
#            return self.send(page("خطا", "<div class='card'>%s</div>"
#                                  % html.escape(str(e)), CFG), 500)
#
#    def do_POST(self):
#        rest = self.route()
#        if rest is None:
#            return self.lost()
#        params = self.body_params()
#        if not self.session_ok():
#            if self.locked_out():
#                log(WARN, "admin login refused from %s: too many failed attempts"
#                    % self.client_address[0])
#                return self.send(login_page(
#                    CFG, "تلاش‌های ناموفق زیاد. چند دقیقه صبر کنید."))
#            given = self.one(params, "password")
#            want = CFG["ADMIN_HASH"]
#            if given and hmac.compare_digest(
#                    hash_password(given, CFG["ADMIN_SALT"]), want):
#                token = secrets.token_urlsafe(32)
#                STORE.run(
#                    "INSERT OR REPLACE INTO admin_sessions (token, expires_at)"
#                    " VALUES (?, ?)",
#                    (token, (datetime.now(timezone.utc)
#                             + timedelta(hours=SESSION_HOURS)).isoformat(
#                                 timespec="seconds")))
#                # Tidy up whatever has run out, so the table cannot grow
#                # forever on a panel that is logged into daily.
#                STORE.run("DELETE FROM admin_sessions WHERE expires_at <= ?",
#                          (now(),))
#                ATTEMPTS.pop(self.client_address[0], None)
#                log(INFO, "admin login from %s" % self.client_address[0])
#                return self.redirect("", {
#                    "Set-Cookie": "sdns=%s; Path=/; HttpOnly; Secure; SameSite=Strict"
#                                  % token})
#            self.note_failure()
#            if given:
#                log(WARN, "admin login failed from %s (%d in a row)"
#                    % (self.client_address[0],
#                       ATTEMPTS.get(self.client_address[0], (0, 0))[0]))
#            return self.send(login_page(CFG, "رمز اشتباه است."))
#        # What was done, before doing it - so an action that then fails is
#        # still on the record, next to the error it caused.
#        self._action = rest
#        log(INFO, "admin action %s%s" % (rest, describe(params)))
#        try:
#            return self.action(rest, params)
#        except Exception as e:
#            log_exception("admin POST %s failed" % rest)
#            return self.send(page("خطا", "<div class='card'>%s</div>"
#                                  % html.escape(str(e)), CFG), 500)
#
#    # -- views ------------------------------------------------------------
#    def view(self, rest):
#        msg = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("m")
#        msg = msg[0] if msg else None
#        kind = "err" if (msg or "").startswith("!") else "good"
#        msg = msg.lstrip("!") if msg else None
#        pages = {"": ("پنل مدیریت", self.home), "index": ("پنل مدیریت", self.home),
#                 "users": ("کاربران", self.users),
#                 "receipts": ("رسیدها", self.receipts),
#                 "templates": ("قالب‌ها", self.templates),
#                 "domains": ("دامنه‌ها", self.domains),
#                 "settings": ("تنظیمات", self.settings),
#                 "restore": ("بازگردانی", self.restore_page),
#                 "logs": ("لاگ", self.logs)}
#        if rest not in pages:
#            return self.lost()
#        title, fn = pages[rest]
#        active = "" if rest == "index" else rest
#        return self.send(page(title, fn(), CFG, active, msg, kind))
#
#    def home(self):
#        u = STORE.one("SELECT count(*) c, COALESCE(sum(used_bytes),0) b FROM users")
#        act = STORE.one("SELECT count(*) c FROM users WHERE status = 'active'")
#        ips = STORE.one("SELECT count(*) c FROM ips")
#        out = ["<div class='card'><h2>خلاصه</h2><div class='grid'>"]
#        for n, l in ((u["c"], "کاربر"), (act["c"], "فعال"),
#                     (ips["c"], "آی‌پی ثبت‌شده"), (human(u["b"]), "مجموع مصرف")):
#            out.append("<div class='stat'><div class='n'>%s</div>"
#                       "<div class='l'>%s</div></div>" % (html.escape(str(n)), l))
#        out.append("</div></div>")
#
#        rows = STORE.q("SELECT m.* FROM metrics m JOIN (SELECT host, MAX(at) at"
#                       " FROM metrics GROUP BY host) l"
#                       " ON l.host = m.host AND l.at = m.at ORDER BY m.host")
#        out.append("<div class='card'><h2>سرورها</h2>")
#        if not rows:
#            out.append("<p class='muted'>هنوز آماری نرسیده.</p>")
#        else:
#            out.append("<table><tr><th>سرور</th><th>CPU</th><th>RAM</th>"
#                       "<th>SWAP</th><th>دیسک</th><th>شبکه</th><th>روشن</th></tr>")
#            for r in rows:
#                seen = parse_ts(r["at"])
#                stale = ""
#                if seen and (datetime.now(timezone.utc) - seen).total_seconds() > 120:
#                    stale = " <span class='bad'>قطع</span>"
#                swap = (bar(r["swap_used"], r["swap_total"]) if r["swap_total"]
#                        else "<span class='muted'>ندارد</span>")
#                out.append(
#                    "<tr><td><code>%s</code>%s</td><td>%s%%</td><td>%s</td>"
#                    "<td>%s</td><td>%s</td>"
#                    "<td class='muted'>↓%s/s ↑%s/s</td>"
#                    "<td class='muted'>%d روز</td></tr>"
#                    % (html.escape(r["host"]), stale, r["cpu"],
#                       bar(r["mem_used"], r["mem_total"]), swap,
#                       bar(r["disk_used"], r["disk_total"]),
#                       human(r["rx_bps"]), human(r["tx_bps"]),
#                       (r["uptime"] or 0) // 86400))
#            out.append("</table>")
#        out.append("</div>")
#        return "".join(out)
#
#    def users(self):
#        tpls = STORE.q("SELECT * FROM templates ORDER BY id")
#        default = STORE.one("SELECT id FROM templates WHERE is_default = 1")
#        did = default["id"] if default else 0
#        rows = STORE.q("SELECT u.*, (SELECT ip FROM ips WHERE user_id = u.id LIMIT 1)"
#                       " ip FROM users u ORDER BY u.created_at DESC")
#        out = ["<div class='card'><h2>کاربران (%d)</h2>" % len(rows)]
#        if not rows:
#            return "".join(out) + "<p class='muted'>هنوز کسی ثبت‌نام نکرده.</p></div>"
#        out.append("<table><tr><th>نام کاربری</th><th>آی‌پی</th><th>مصرف</th>"
#                   "<th>سهمیه (گیگ)</th><th>سرعت Mb/s</th><th>زمان (روز)</th>"
#                   "<th>قالب</th><th>وضعیت</th><th></th></tr>")
#        p = CFG["ADMIN_PATH"]
#        for r in rows:
#            tid = r["template_id"] or did
#            sel = "".join("<option value='%d'%s>%s</option>"
#                          % (t["id"], " selected" if t["id"] == tid else "",
#                             html.escape(t["name"])) for t in tpls)
#            # "pending" is amber, not red: nothing is wrong with the
#            # account, it is only waiting for somebody here to give it a plan.
#            cls = {"active": "ok", "over_quota": "warn",
#                   "pending": "warn"}.get(r["status"], "bad")
#            label = {"active": "فعال", "pending": "در انتظار پلن",
#                     "over_quota": "سهمیه تمام شده", "expired": "منقضی",
#                     "suspended": "مسدود"}.get(r["status"], r["status"])
#            quota_gb = ("%.0f" % (r["quota_bytes"] / GB)) if r["quota_bytes"] else "0"
#            kbps = r["speed_kbps"] or 0
#            speed_mb = ("%g" % (kbps / 1000.0)) if kbps else "0"
#            left = remaining_days(r["expires_at"] or r["quota_reset_at"])
#            who = str(r["username"] or r["phone"] or r["telegram_id"]
#                      or "#%d" % r["id"])
#            # Named in the question, so the wrong row is caught before it is
#            # gone. JSON makes it a safe JS string, escaping makes that a safe
#            # attribute - a name is whatever the customer typed.
#            ask = html.escape(json.dumps(
#                "«%s» برای همیشه حذف شود؟ آی‌پی‌ها و رسیدهایش هم پاک می‌شوند "
#                "و برنمی‌گردند." % who, ensure_ascii=False), quote=True)
#            # Only an account with a username signs in on the web, so only
#            # such an account has a password worth replacing.
#            reset = ""
#            if r["username"]:
#                reset = (
#                    "<form method='post' action='/%s/user-password-reset'"
#                    " onsubmit='return confirm(%s)'>"
#                    "<input type='hidden' name='id' value='%d'>"
#                    "<button class='ghost' title='ساختن رمز موقت برای این کاربر'>"
#                    "رمز تازه</button></form>"
#                    % (p, html.escape(json.dumps(
#                        "برای «%s» رمز تازه ساخته شود؟ از همهٔ دستگاه‌ها بیرون "
#                        "می‌آید." % who, ensure_ascii=False), quote=True), r["id"]))
#            out.append(
#                "<tr><td><code>%s</code><br><span class='muted'>%s</span></td>"
#                "<td><code>%s</code>%s</td><td>%s</td>"
#                "<td><form id='u%d' method='post' action='/%s/user-save'></form>"
#                "<input form='u%d' type='hidden' name='id' value='%d'>"
#                "<input form='u%d' name='quota_gb' value='%s' size='4'"
#                " title='گیگابایت، ۰=نامحدود'></td>"
#                "<td><input form='u%d' name='speed_mb' value='%s' size='4'"
#                " title='مگابیت بر ثانیه، ۰=بی‌حد'></td>"
#                "<td><input form='u%d' name='days' size='4' placeholder='%s'"
#                " title='از امروز چند روز دیگر'></td>"
#                "<td><form method='post' action='/%s/user-template'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<select name='template_id' onchange='this.form.submit()'>%s</select>"
#                "</form></td>"
#                "<td class='%s'>%s</td>"
#                "<td class='acts'><button form='u%d' title='ذخیره'>ثبت</button>"
#                "<form method='post' action='/%s/user-status'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<input type='hidden' name='to' value='%s'>"
#                "<button class='%s' title='%s'>%s</button></form>"
#                "<form method='post' action='/%s/user-reset'"
#                " onsubmit='return confirm(\"مصرف این کاربر صفر شود؟\")'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<button class='ghost' title='صفر کردن مصرف'>صفر</button></form>"
#                "%s"
#                "<form method='post' action='/%s/user-delete'"
#                " onsubmit='return confirm(%s)'>"
#                "<input type='hidden' name='id' value='%d'>"
#                "<button class='del' title='حذف همیشگی این کاربر'>حذف</button></form>"
#                "</td></tr>"
#                # What a customer signs in with. Accounts opened before this
#                # was a username have a phone number instead, and the ones
#                # that came through the bot have neither - so the column shows
#                # whichever this account actually has.
#                % (html.escape(who),
#                   html.escape(r["first_name"] or ""),
#                   html.escape(r["ip"] or "-"), operator_label(r["ip"]),
#                   human(r["used_bytes"]),
#                   r["id"], p, r["id"], r["id"], r["id"], quota_gb,
#                   r["id"], speed_mb, r["id"], left,
#                   p, r["id"], sel, cls, html.escape(label),
#                   r["id"],
#                   p, r["id"],
#                   "active" if r["status"] == "suspended" else "suspended",
#                   "ghost" if r["status"] == "suspended" else "danger",
#                   "برگرداندن" if r["status"] == "suspended" else "مسدود کردن",
#                   "فعال" if r["status"] == "suspended" else "مسدود",
#                   p, r["id"],
#                   reset,
#                   p, ask, r["id"]))
#        out.append("</table><p class='muted'>ثبت‌نام تازه با وضعیت «در انتظار "
#                   "پلن» می‌آید و تا وقتی برایش پلن ذخیره نکنید هیچ ترافیکی "
#                   "نمی‌گیرد؛ اولین ذخیرهٔ همین سطر فعالش می‌کند. "
#                   "صفر در سهمیه یا سرعت یعنی بی‌حد. "
#                   "«زمان» خالی یعنی بدون تغییر؛ عددی که بنویسید تاریخ پایان را "
#                   "از امروز همان‌قدر روز جلو می‌برد، و رنگ خاکستریِ داخلش روزهای "
#                   "باقی‌مانده است. سرعت فقط دانلود را محدود می‌کند و تا ۳۰ ثانیه "
#                   "دیگر روی رله‌ها اعمال می‌شود.</p></div>")
#        return "".join(out)
#
#    def templates(self):
#        """Two pages behind one path: the list, and one template's editor.
#
#        Editing is its own page because the editor carries a checkbox for every
#        domain in the catalogue - some five hundred of them. Rendering that
#        for every template at once would make a page several times the size,
#        opened over a connection from Iran, to show one template's detail.
#        """
#        wanted = urllib.parse.parse_qs(
#            urllib.parse.urlparse(self.path).query).get("t")
#        if wanted:
#            row = STORE.one("SELECT * FROM templates WHERE id = ?",
#                            (int(wanted[0]) if wanted[0].isdigit() else 0,))
#            if row:
#                return self.template_editor(row)
#        return self.template_list()
#
#    def template_list(self):
#        tpls = STORE.q("SELECT * FROM templates ORDER BY id")
#        default = STORE.one("SELECT id FROM templates WHERE is_default = 1")
#        did = default["id"] if default else 0
#        p = CFG["ADMIN_PATH"]
#        out = ["<div class='card'><h2>قالب‌ها</h2>"
#               "<table><tr><th>نام</th><th>کاربر</th><th>سرویس‌ها</th>"
#               "<th>دامنه‌ها</th><th></th></tr>"]
#        for t in tpls:
#            users = STORE.one("SELECT count(*) c FROM users"
#                              " WHERE COALESCE(template_id, ?) = ?",
#                              (did, t["id"]))["c"]
#            name = html.escape(t["name"])
#            if t["is_default"]:
#                out.append("<tr><td>%s <span class='muted'>(پیش‌فرض)</span></td>"
#                           "<td>%d</td><td colspan='2' class='muted'>همه، از جمله "
#                           "سرویس‌هایی که بعداً اضافه شوند</td><td></td></tr>"
#                           % (name, users))
#                continue
#            groups = STORE.template_groups(t["id"])
#            off = STORE.template_domains_off(t["id"])
#            n_groups = n_dom = total_dom = 0
#            for svc in catalogue_now():
#                for g in svc["groups"]:
#                    total_dom += len(g["domains"])
#                    if (svc["key"], g["key"]) in groups:
#                        n_groups += 1
#                        n_dom += sum(1 for d in g["domains"] if d not in off)
#            out.append("<tr><td>%s</td><td>%d</td><td>%d</td>"
#                       "<td>%d <span class='muted'>از %d</span></td>"
#                       "<td><a href='/%s/templates?t=%d'>ویرایش</a></td></tr>"
#                       % (name, users, n_groups, n_dom, total_dom, p, t["id"]))
#        out.append("</table></div>")
#        out.append("<div class='card'><h2>قالب تازه</h2>"
#                   "<form method='post' action='/%s/template-new' class='row'>"
#                   "<input name='name' placeholder='نام قالب'><button>ساختن</button>"
#                   "</form><p class='muted'>قالب تازه با همهٔ سرویس‌ها ساخته می‌شود؛ "
#                   "بعد تیک‌ها را بردارید. هر قالبِ در حال استفاده یک resolver روی هر "
#                   "رله است، پس حداکثر ۸ تا.</p></div>" % p)
#        return "".join(out)
#
#    def template_editor(self, t):
#        p = CFG["ADMIN_PATH"]
#        back = "<p><a href='/%s/templates'>‹ برگشت به فهرست قالب‌ها</a></p>" % p
#        if t["is_default"]:
#            return (back + "<div class='card'><h2>%s (پیش‌فرض)</h2>"
#                    "<p class='muted'>قالب پیش‌فرض همیشه همهٔ سرویس‌ها را از رله "
#                    "می‌برد، از جمله سرویس‌هایی که بعداً اضافه شوند. برای همین "
#                    "قابل ویرایش نیست — یک قالب تازه بسازید.</p>"
#                    "<p class='muted'>یک استثنا: گروه‌هایی که «پیش‌فرض خاموش» "
#                    "علامت خورده‌اند، حتی در این قالب هم مسیریابی نمی‌شوند. "
#                    "برای روشن کردنشان یک قالب تازه بسازید و آنجا تیکشان بزنید."
#                    "</p></div>"
#                    % html.escape(t["name"]))
#
#        groups = STORE.template_groups(t["id"])
#        off = STORE.template_domains_off(t["id"])
#        out = [back,
#               "<div class='card'><h2>%s</h2>" % html.escape(t["name"]),
#               "<p class='muted'>تیک سرویس یعنی همهٔ دامنه‌هایش از رله می‌رود — "
#               "از جمله دامنه‌هایی که بعداً به آن اضافه شوند. کشو را باز کنید تا "
#               "بین دامنه‌ها یکی‌یکی انتخاب کنید.</p>",
#               "<form method='post' action='/%s/template-save'>"
#               "<input type='hidden' name='id' value='%d'>" % (p, t["id"])]
#
#        for svc in catalogue_now():
#            for g in svc["groups"]:
#                # A locked group is not a choice: it is bypassed for every
#                # template, so it is not drawn where it could be ticked.
#                if g.get("locked"):
#                    continue
#                key = "%s.%s" % (svc["key"], g["key"])
#                on = (svc["key"], g["key"]) in groups
#                label = (svc["label"] if len(svc["groups"]) == 1
#                         else "%s — %s" % (svc["label"], g["label"]))
#                # An opt-in group is one where routing is the wrong default,
#                # not a matter of taste. Say why, next to the tick, rather
#                # than letting it look like every other box on the page.
#                if g.get("opt_in"):
#                    # The reason comes from the group, not from here. These
#                    # are switched off for four different reasons and only one
#                    # of them is matchmaking - a warning that says the same
#                    # thing about all of them is wrong about three.
#                    label += ("<span class='optin'>پیش‌فرض خاموش — %s</span>"
#                              % html.escape(g.get("note") or
#                                            "روشن کردنش چیزی را می‌شکند"))
#                kept = [d for d in g["domains"] if d not in off]
#                # Open the drawer when the operator has already been in here
#                # picking domains, so their exceptions are visible rather than
#                # hidden behind a summary that looks like every other one.
#                partial = on and len(kept) != len(g["domains"])
#                out.append(
#                    "<details class='svc'%s><summary>"
#                    "<label><input type='checkbox' name='g' value='%s'%s> %s</label>"
#                    "<span class='muted count'>%d از %d دامنه</span>"
#                    "<span class='pick'><button type='button' data-all='1'>همه</button>"
#                    "<button type='button' data-all='0'>هیچ‌کدام</button></span>"
#                    "</summary>"
#                    % (" open" if partial else "", html.escape(key),
#                       " checked" if on else "", label,
#                       len(kept) if on else 0, len(g["domains"])))
#                if not g["domains"]:
#                    out.append("<p class='muted'>دامنه‌ای ندارد.</p>")
#                out.append("<div class='doms'>")
#                for d in sorted(g["domains"]):
#                    # A tick on this page means "routed". Inside a group that
#                    # is switched off nothing is routed, so nothing there is
#                    # ticked - otherwise the drawer contradicts the summary
#                    # beside it, which already says 0 of however many.
#                    out.append("<label><input type='checkbox' name='d' value='%s'%s>"
#                               "<span>%s</span></label>"
#                               % (html.escape(d),
#                                  " checked" if on and d not in off else "",
#                                  html.escape(d)))
#                out.append("</div></details>")
#
#        out.append("<div style='margin-top:16px'><button>ذخیره</button> "
#                   "<button class='danger' formaction='/%s/template-delete' "
#                   "formnovalidate>حذف قالب</button></div></form></div>" % p)
#        # Convenience only. Every checkbox above is a plain form control, so
#        # the page works with this script blocked or broken - it just means
#        # ticking five hundred boxes by hand.
#        out.append("""<script>
#(function () {
#  function count(d) {
#    var boxes = d.querySelectorAll('.doms input');
#    var on = d.querySelectorAll('.doms input:checked').length;
#    var g = d.querySelector('summary input[name=g]');
#    var label = d.querySelector('.count');
#    if (label) label.textContent = (g.checked ? on : 0) + ' از ' + boxes.length + ' دامنه';
#  }
#  document.addEventListener('click', function (e) {
#    var b = e.target.closest('.pick button');
#    if (b) {
#      // Inside a <summary>, so the drawer would otherwise open and close
#      // under the operator every time they pressed one of these.
#      e.preventDefault();
#      e.stopPropagation();
#      var d = b.closest('details'), all = b.dataset.all === '1';
#      d.querySelectorAll('.doms input').forEach(function (i) { i.checked = all; });
#      // No domains and the service still ticked would be a tick that routes
#      // nothing, so the two move together.
#      d.querySelector('summary input[name=g]').checked = all;
#      return count(d);
#    }
#    if (e.target.matches('summary input[name=g]')) {
#      e.stopPropagation();
#      var d3 = e.target.closest('details');
#      var boxes = d3.querySelectorAll('.doms input');
#      // Ticking a service means all of it. The drawer is for taking things
#      // out afterwards, not for putting five hundred domains in by hand.
#      if (e.target.checked) {
#        var any = d3.querySelectorAll('.doms input:checked').length;
#        if (!any) boxes.forEach(function (i) { i.checked = true; });
#      } else {
#        boxes.forEach(function (i) { i.checked = false; });
#      }
#      return count(d3);
#    }
#    if (e.target.matches('.doms input')) {
#      var d2 = e.target.closest('details');
#      // Ticking a domain in a service that is switched off is a request for
#      // that service, so switch it on rather than silently ignoring it.
#      if (e.target.checked) d2.querySelector('summary input[name=g]').checked = true;
#      count(d2);
#    }
#  });
#})();
#</script>""")
#        return "".join(out)
#
#    def domains(self):
#        rows = STORE.q("SELECT * FROM custom_domains ORDER BY added_at DESC")
#        shipped = sum(len(g["domains"]) for s in CATALOGUE for g in s["groups"])
#        p = CFG["ADMIN_PATH"]
#        out = ["<div class='card'><h2>دامنه‌های شما (%d)</h2>" % len(rows),
#               "<form method='post' action='/%s/domain-add' class='row' "
#               "style='margin-bottom:14px'>"
#               "<input name='domain' placeholder='example.com' style='min-width:220px'>"
#               "<input name='note' placeholder='یادداشت (اختیاری)'>"
#               "<button>افزودن</button></form>" % p]
#        if rows:
#            out.append("<table><tr><th>دامنه</th><th>یادداشت</th><th>افزوده</th>"
#                       "<th></th></tr>")
#            for r in rows:
#                out.append("<tr><td><code>%s</code></td><td class='muted'>%s</td>"
#                           "<td class='muted'>%s</td>"
#                           "<td><form method='post' action='/%s/domain-del'>"
#                           "<input type='hidden' name='domain' value='%s'>"
#                           "<button class='danger'>حذف</button></form></td></tr>"
#                           % (html.escape(r["domain"]), html.escape(r["note"] or ""),
#                              (r["added_at"] or "")[:10], p, html.escape(r["domain"])))
#            out.append("</table>")
#        out.append("<p class='muted'>زیردامنه‌ها خودکار شامل می‌شوند. این‌ها در سرویس "
#                   "«دامنه‌های دلخواه» جمع می‌شوند، پس در هر قالب می‌شود تیکشان را "
#                   "برداشت. به‌علاوهٔ %d دامنه‌ای که با نصاب می‌آید.</p></div>" % shipped)
#        return "".join(out)
#
#    def settings(self):
#        p = CFG["ADMIN_PATH"]
#        out = []
#        out.append(
#            "<div class='card'><h2>نسخهٔ پشتیبان</h2>"
#            "<p class='muted'>یک فایل sqlite با همهٔ کاربران، آی‌پی‌ها، قالب‌ها، "
#            "تراکنش‌ها و تنظیمات. آمار سلامت سرورها داخلش نیست — حجم زیادی است "
#            "و ارزشی در بازگردانی ندارد.</p>"
#            "<p><a class='dl' href='/%s/backup.db'>دانلود نسخهٔ پشتیبان</a></p>"
#            "<h2 style='margin-top:22px'>بازگردانی</h2>"
#            "<form method='post' action='/%s/restore' enctype='multipart/form-data' "
#            "class='row'><input type='file' name='file' accept='.db' required>"
#            "<button class='ghost'>بررسی فایل</button></form>"
#            "<p class='muted'>فایل اول فقط بررسی و توصیف می‌شود؛ جایگزینی جدا "
#            "تأیید می‌خواهد.</p></div>" % (p, p))
#
#        support = STORE.one("SELECT value FROM settings WHERE key = 'support_contact'")
#        out.append("<div class='card'><h2>پشتیبانی</h2>"
#                   "<form method='post' action='/%s/support-save' class='row'>"
#                   "<input name='contact' value='%s' maxlength='64' "
#                   "placeholder='@your_support' style='min-width:240px;direction:ltr'>"
#                   "<button class='ghost'>ذخیره</button></form>"
#                   "<p class='muted'>زیر فرم ورود مشتری‌ها نوشته می‌شود: «رمز را "
#                   "فراموش کرده‌اید؟ به پشتیبانی پیام دهید» و بعد همین آیدی یا "
#                   "شماره. خالی باشد، همان جمله بدون آیدی می‌آید.</p></div>"
#                   % (p, html.escape(support["value"] if support else "",
#                                     quote=True)))
#
#        out.append("<div class='card'><h2>آدرس این پنل</h2>"
#                   "<p class='muted'>همین حالا: <code>https://%s:%s/%s/</code></p>"
#                   "<div class='f'><label>پورت</label>"
#                   "<form method='post' action='/%s/panel-port' class='row'>"
#                   "<input name='port' value='%s' size='6'>"
#                   "<button class='ghost'>تغییر پورت</button></form></div>"
#                   "<div class='f'><label>مسیر مخفی</label>"
#                   "<form method='post' action='/%s/panel-path' class='row'>"
#                   "<input name='path' value='%s' style='min-width:280px'>"
#                   "<button class='ghost'>تغییر مسیر</button>"
#                   "<button class='ghost' name='random' value='1'>مسیر تصادفی</button>"
#                   "</form></div>"
#                   "<div class='msg err'>پورت را که عوض کنید، پنل روی پورت تازه "
#                   "بالا می‌آید — ولی اگر سرور فایروال یا security group دارد "
#                   "(روی AWS، Hetzner و مانندش) باید پورت تازه را <b>اول</b> "
#                   "آنجا باز کنید، وگرنه از بیرون در دسترس نخواهد بود. اگر "
#                   "بیرون ماندید، از روی خود سرور: <code>smartdns-access port "
#                   "9443</code></div></div>"
#                   % (html.escape(panel_host()), html.escape(CFG["ADMIN_PORT"]),
#                      html.escape(CFG["ADMIN_PATH"]),
#                      p, html.escape(CFG["ADMIN_PORT"]),
#                      p, html.escape(CFG["ADMIN_PATH"])))
#
#        out.append("<div class='card'><h2>رمز این پنل</h2>"
#                   "<form method='post' action='/%s/password'>"
#                   "<div class='f'><label>رمز تازه (دست‌کم ۸ نویسه)</label>"
#                   "<input type='password' name='password' style='width:100%%'>"
#                   "</div>"
#                   "<div class='f'><label>تکرار رمز تازه</label>"
#                   "<input type='password' name='again' style='width:100%%'>"
#                   "</div><button>تغییر رمز</button></form>"
#                   "<p class='muted'>رمز ذخیره نمی‌شود، فقط هشش. با تغییر آن "
#                   "همهٔ نشست‌های دیگر بسته می‌شوند.</p></div>" % p)
#        return "".join(out)
#
#    def logs(self):
#        out = []
#        for unit in ("smartdns-panel", "smartdns-admin"):
#            try:
#                txt = subprocess.run(
#                    ["journalctl", "-u", unit, "-n", "60", "--no-pager",
#                     "--output=cat"], capture_output=True, text=True,
#                    timeout=20).stdout
#            except Exception as e:
#                txt = str(e)
#            out.append("<div class='card'><h2>%s</h2><pre style='overflow-x:auto;"
#                       "font-size:12px;color:var(--dim);white-space:pre-wrap'>%s</pre>"
#                       "</div>" % (unit, html.escape(txt or "(چیزی نیست)")))
#        return "".join(out)
#
#    # -- actions ----------------------------------------------------------
#    def action(self, rest, params):
#        one = lambda k, d="": self.one(params, k, d)
#
#        if rest == "user-save":
#            uid = int(one("id") or 0)
#            gb = one("quota_gb", "0")
#            days = one("days")
#            try:
#                quota = int(float(gb) * GB) if gb else 0
#            except ValueError:
#                return self.redirect("users?m=!عدد سهمیه درست نیست")
#            # Signing up gets an account, not traffic. Somebody has to decide
#            # this customer may connect, and this form - opening their row and
#            # giving them a plan - is that decision. Read the status before
#            # the writes below, because one of them can change it.
#            was = STORE.one("SELECT status FROM users WHERE id = ?", (uid,))
#            joining = bool(was) and was["status"] == "pending"
#            # Clearing the warning bits matters: a user raised above a
#            # threshold they had already crossed would otherwise never be
#            # warned again.
#            STORE.run("UPDATE users SET quota_bytes = ?, warned = 0,"
#                      " status = CASE WHEN status = 'over_quota' THEN 'active'"
#                      " ELSE status END WHERE id = ?", (quota, uid))
#            if "speed_mb" in params:
#                try:
#                    mb = float(one("speed_mb", "0") or 0)
#                except ValueError:
#                    return self.redirect("users?m=!عدد سرعت درست نیست")
#                if mb < 0:
#                    return self.redirect("users?m=!سرعت منفی نمی‌شود")
#                STORE.run("UPDATE users SET speed_kbps = ? WHERE id = ?",
#                          (int(mb * 1000), uid))
#            if days:
#                try:
#                    count = float(days)
#                except ValueError:
#                    return self.redirect("users?m=!تعداد روز درست نیست")
#                if count < 0:
#                    return self.redirect("users?m=!تعداد روز منفی نمی‌شود")
#                if count == 0:
#                    # No end date at all. The account then ends only when its
#                    # allowance does, which is what an operator means by
#                    # putting zero in a box that everywhere else on this page
#                    # means "no limit".
#                    STORE.run("UPDATE users SET expires_at = NULL,"
#                              " quota_reset_at = NULL, quota_mode = 'oneoff',"
#                              " status = CASE WHEN status = 'expired' THEN 'active'"
#                              " ELSE status END WHERE id = ?", (uid,))
#                    if joining:
#                        STORE.run("UPDATE users SET status = 'active'"
#                                  " WHERE id = ?", (uid,))
#                    return self.redirect(
#                        "users?m=ذخیره شد؛ بدون محدودیت زمانی"
#                        + ("؛ حساب فعال شد" if joining else ""))
#                when = datetime.now(timezone.utc) + timedelta(days=count)
#                stamp = when.isoformat(timespec="seconds")
#                row = STORE.one("SELECT quota_mode FROM users WHERE id = ?", (uid,))
#                if row and row["quota_mode"] == "monthly":
#                    # A renewing plan: the number moves its next reset rather
#                    # than ending it, which is what renewing means.
#                    STORE.run("UPDATE users SET quota_reset_at = ?"
#                              " WHERE id = ?", (stamp, uid))
#                else:
#                    # Everything else gets an end date that many days out, and
#                    # comes back if it had already run out - which is the whole
#                    # reason an operator types in this box. This used to key
#                    # off whether the account already had a date, which worked
#                    # only because every account started as a dated trial.
#                    STORE.run("UPDATE users SET expires_at = ?,"
#                              " status = CASE WHEN status = 'expired' THEN 'active'"
#                              " ELSE status END WHERE id = ?", (stamp, uid))
#            if joining:
#                STORE.run("UPDATE users SET status = 'active' WHERE id = ?",
#                          (uid,))
#                return self.redirect("users?m=ذخیره شد؛ حساب فعال شد")
#            return self.redirect("users?m=ذخیره شد")
#
#        if rest == "receipt-decide":
#            tid = int(one("id") or 0)
#            to = one("to")
#            if to not in ("approved", "rejected"):
#                return self.redirect("receipts?m=!تصمیم نامعتبر")
#            # The image goes with the decision. It was evidence for a judgement
#            # that has now been made, and keeping every customer's bank slip
#            # for ever is a liability rather than a record.
#            STORE.run("UPDATE transactions SET status = ?, decided_at = ?,"
#                      " receipt_blob = NULL WHERE id = ?", (to, now(), tid))
#            return self.redirect(
#                "receipts?m=%s" % ("رسید تأیید شد؛ حالا سهمیه و زمانش را بگذارید"
#                                   if to == "approved" else "رسید رد شد"))
#
#        if rest == "user-status":
#            uid = int(one("id") or 0)
#            to = one("to")
#            if to not in ("active", "suspended"):
#                return self.redirect("users?m=!وضعیت نامعتبر")
#            # Clearing the warning bits on the way back in: an account that
#            # crossed a threshold while blocked would otherwise never warn
#            # again once it is working.
#            STORE.run("UPDATE users SET status = ?, warned = CASE WHEN ? = 'active'"
#                      " THEN 0 ELSE warned END WHERE id = ?", (to, to, uid))
#            return self.redirect(
#                "users?m=%s" % ("کاربر مسدود شد؛ تا ۳۰ ثانیه دیگر قطع می‌شود"
#                                if to == "suspended" else "کاربر برگشت"))
#
#        if rest == "user-reset":
#            uid = int(one("id") or 0)
#            # The kernel counters on the relays are not touched. Usage here is
#            # the growth of those counters since the last sync, so zeroing the
#            # total is enough - the next sync adds only what has happened
#            # since, not the whole counter again.
#            STORE.run("UPDATE users SET used_bytes = 0, warned = 0,"
#                      " status = CASE WHEN status = 'over_quota' THEN 'active'"
#                      " ELSE status END WHERE id = ?", (uid,))
#            return self.redirect("users?m=مصرف صفر شد")
#
#        if rest == "user-delete":
#            uid = int(one("id") or 0)
#            ips = STORE.delete_user(uid)
#            if ips is None:
#                return self.redirect("users?m=!این کاربر پیدا نشد")
#            log(INFO, "deleted user #%d and its %d address(es)" % (uid, len(ips)))
#            # The relays learn it at their next sync, like a block does.
#            return self.redirect("users?m=کاربر حذف شد؛ تا ۳۰ ثانیه دیگر قطع می‌شود")
#
#        if rest == "user-template":
#            STORE.run("UPDATE users SET template_id = ? WHERE id = ?",
#                      (int(one("template_id") or 0), int(one("id") or 0)))
#            return self.redirect("users?m=قالب عوض شد؛ تا ۳۰ ثانیه دیگر روی رله‌ها اعمال می‌شود")
#
#        if rest == "template-new":
#            name = one("name")
#            if not name:
#                return self.redirect("templates?m=!نام لازم است")
#            count = STORE.one("SELECT count(*) c FROM templates")["c"]
#            if count >= 8:
#                return self.redirect("templates?m=!سقف ۸ قالب پر است؛ هر قالب یک "
#                                     "resolver روی هر رله است")
#            try:
#                cur = STORE.run("INSERT INTO templates (name, is_default, created_at)"
#                                " VALUES (?, 0, ?)", (name, now()))
#            except sqlite3.IntegrityError:
#                return self.redirect("templates?m=!قالبی با این نام هست")
#            # Everything except the opt-in groups. A new template starting
#            # with those already ticked would be the panel deciding something
#            # it just told the operator was theirs to decide.
#            skipped = 0
#            for svc in CATALOGUE:
#                for g in svc["groups"]:
#                    if g.get("opt_in"):
#                        skipped += 1
#                        continue
#                    STORE.run("INSERT OR IGNORE INTO template_services"
#                              " (template_id, service_key, group_key) VALUES (?,?,?)",
#                              (cur.lastrowid, svc["key"], g["key"]))
#            return self.redirect(
#                "templates?t=%d&m=قالب ساخته شد با همهٔ سرویس‌ها%s"
#                % (cur.lastrowid,
#                   "؛ %d گروهِ «پیش‌فرض خاموش» تیک نخورد" % skipped
#                   if skipped else ""))
#
#        if rest == "template-save":
#            tid = int(one("id") or 0)
#            if STORE.one("SELECT is_default FROM templates WHERE id = ?",
#                         (tid,))["is_default"]:
#                return self.redirect("templates?m=!قالب پیش‌فرض قابل تغییر نیست")
#            wanted = set(params.get("g") or [])
#            # Checkboxes only report what is ticked, so the off-list is worked
#            # out by subtraction: every domain in a routed group that did not
#            # come back.
#            keep = set(params.get("d") or [])
#            STORE.run("DELETE FROM template_services WHERE template_id = ?", (tid,))
#            STORE.run("DELETE FROM template_domains_off WHERE template_id = ?", (tid,))
#            for svc in catalogue_now():
#                for g in svc["groups"]:
#                    # A locked group cannot be ticked, even by a form that
#                    # sends it anyway.
#                    if g.get("locked"):
#                        continue
#                    if "%s.%s" % (svc["key"], g["key"]) not in wanted:
#                        continue
#                    STORE.run("INSERT OR IGNORE INTO template_services"
#                              " (template_id, service_key, group_key) VALUES (?,?,?)",
#                              (tid, svc["key"], g["key"]))
#                    # A ticked service with none of its domains ticked is a
#                    # tick that routes nothing, which nobody means. It is what
#                    # the form sends when the helper script is blocked, so
#                    # read it the only way it makes sense: all of them.
#                    picked = keep.intersection(g["domains"]) or set(g["domains"])
#                    for d in g["domains"]:
#                        if d not in picked:
#                            STORE.run("INSERT OR IGNORE INTO template_domains_off"
#                                      " (template_id, domain) VALUES (?, ?)", (tid, d))
#            return self.redirect("templates?t=%d&m=ذخیره شد؛ تا ۳۰ ثانیه دیگر روی "
#                                 "رله‌ها اعمال می‌شود" % tid)
#
#        if rest == "template-delete":
#            tid = int(one("id") or 0)
#            row = STORE.one("SELECT is_default FROM templates WHERE id = ?", (tid,))
#            if not row or row["is_default"]:
#                return self.redirect("templates?m=!قالب پیش‌فرض حذف نمی‌شود")
#            # Move anyone on it back to the default first, so nobody is left
#            # pointing at a template that no longer exists.
#            default = STORE.one("SELECT id FROM templates WHERE is_default = 1")
#            STORE.run("UPDATE users SET template_id = ? WHERE template_id = ?",
#                      (default["id"] if default else None, tid))
#            STORE.run("DELETE FROM template_services WHERE template_id = ?", (tid,))
#            STORE.run("DELETE FROM templates WHERE id = ?", (tid,))
#            return self.redirect("templates?m=قالب حذف شد و کاربرانش به پیش‌فرض برگشتند")
#
#        if rest == "domain-add":
#            raw = one("domain")
#            try:
#                domain = clean_domain(raw)
#            except ValueError as e:
#                return self.redirect("domains?m=!%s" % e)
#            for svc in CATALOGUE:
#                for grp in svc["groups"]:
#                    if domain in grp["domains"]:
#                        return self.redirect(
#                            "domains?m=!%s از قبل در سرویس %s هست"
#                            % (domain, svc["label"]))
#            if STORE.one("SELECT 1 FROM custom_domains WHERE domain = ?", (domain,)):
#                return self.redirect("domains?m=!%s از قبل اضافه شده" % domain)
#            STORE.run("INSERT INTO custom_domains (domain, note, added_at)"
#                      " VALUES (?, ?, ?)", (domain, one("note") or None, now()))
#            return self.redirect("domains?m=%s اضافه شد" % domain)
#
#        if rest == "domain-del":
#            STORE.run("DELETE FROM custom_domains WHERE domain = ?", (one("domain"),))
#            return self.redirect("domains?m=حذف شد")
#
#        if rest == "restore":
#            return self.take_upload()
#
#        if rest == "restore-apply":
#            return self.apply_restore()
#
#        if rest == "restore-cancel":
#            path = PENDING.pop("path", None)
#            PENDING.clear()
#            if path and os.path.exists(path):
#                os.unlink(path)
#            return self.redirect("settings?m=بازگردانی لغو شد")
#
#        if rest == "panel-port":
#            port = one("port")
#            if not port.isdigit() or not 1 <= int(port) <= 65535:
#                return self.redirect("settings?m=!پورت باید عددی بین ۱ تا ۶۵۵۳۵ باشد")
#            if int(port) in RESERVED_PORTS:
#                return self.redirect(
#                    "settings?m=!پورت %s برای %s است"
#                    % (port, RESERVED_PORTS[int(port)]))
#            if port == CFG["ADMIN_PORT"]:
#                return self.redirect("settings?m=همان پورت قبلی است")
#            set_config_key("ADMIN_PORT", port)
#            CFG["ADMIN_PORT"] = port
#            return self.moving_to(port, CFG["ADMIN_PATH"])
#
#        if rest == "panel-path":
#            new = secrets.token_hex(12) if one("random") else one("path")
#            if not re.match(r"^[A-Za-z0-9_-]{8,64}$", new):
#                return self.redirect(
#                    "settings?m=!مسیر باید ۸ تا ۶۴ نویسه از حروف، رقم، - و _ باشد")
#            if new == CFG["ADMIN_PATH"]:
#                return self.redirect("settings?m=همان مسیر قبلی است")
#            set_config_key("ADMIN_PATH", new)
#            CFG["ADMIN_PATH"] = new
#            return self.moving_to(CFG["ADMIN_PORT"], new)
#
#        if rest == "user-password-reset":
#            uid = int(one("id") or 0)
#            user = STORE.one("SELECT username FROM users WHERE id = ?", (uid,))
#            if not user:
#                return self.redirect("users?m=!این کاربر پیدا نشد")
#            if not user["username"]:
#                return self.redirect("users?m=!این حساب نام کاربری ندارد و از "
#                                     "پنل وارد نمی‌شود")
#            password = temp_password()
#            if not STORE.reset_password(uid, password):
#                return self.redirect("users?m=!نشد، دوباره امتحان کنید")
#            log(INFO, "temporary password for user #%d; its sign-ins closed" % uid)
#            # On this page and nowhere else. Not in a redirect: the message
#            # rides in the address, and the address stays in the history.
#            return self.send(page("رمز موقت",
#                                  temp_password_card(user["username"], password),
#                                  CFG, "users"))
#
#        if rest == "support-save":
#            contact = " ".join(one("contact").split())
#            if len(contact) > 64:
#                return self.redirect("settings?m=!حداکثر ۶۴ نویسه")
#            STORE.run("INSERT INTO settings (key, value) VALUES ('support_contact', ?)"
#                      " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
#                      (contact,))
#            return self.redirect("settings?m=ذخیره شد؛ تا ۳۰ ثانیه دیگر زیر "
#                                 "فرم ورود مشتری‌ها می‌آید")
#
#        if rest == "password":
#            new = one("password")
#            # Asked twice, because it cannot be read back to check afterwards
#            # and a typo here locks the operator out of their own panel.
#            if new != one("again"):
#                return self.redirect("settings?m=!دو رمز یکی نیستند")
#            if len(new) < 8:
#                return self.redirect("settings?m=!رمز باید حداقل ۸ نویسه باشد")
#            salt = secrets.token_hex(16)
#            digest = hash_password(new, salt)
#            set_config_key("ADMIN_SALT", salt)
#            set_config_key("ADMIN_HASH", digest)
#            CFG["ADMIN_SALT"], CFG["ADMIN_HASH"] = salt, digest
#            # Everyone else holding a session was authenticated with the old
#            # password; a password change should end those.
#            STORE.run("DELETE FROM admin_sessions WHERE token != ?",
#                      (self.session_token(),))
#            return self.redirect("settings?m=رمز عوض شد")
#
#        return self.lost()
#
#
#DOMAIN_RE = __import__("re").compile(
#    r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
#FORBIDDEN = ("localhost", "local", "internal", "arpa", "telegram.org",
#             "t.me", "telegram.me")
#
#
#def clean_domain(raw):
#    """Same normalisation the bot does, so a domain added here and one added
#    there end up identical rather than as two rows differing by a www."""
#    import re
#    d = (raw or "").strip().lower()
#    d = re.sub(r"^[a-z]+://", "", d)
#    d = d.split("/")[0].split("?")[0].split("@")[-1].split(":")[0].strip(".")
#    if not d:
#        raise ValueError("خالی است")
#    if not DOMAIN_RE.match(d):
#        raise ValueError("قالب دامنه درست نیست")
#    if any(d == f or d.endswith("." + f) for f in FORBIDDEN):
#        raise ValueError("این دامنه را نمی‌شود مسیر داد")
#    return d
#
#
#def set_config_key(key, value):
#    """Rewrite one key in admin.env, leaving the rest of the file alone."""
#    lines = []
#    if os.path.exists(CONFIG):
#        with open(CONFIG) as fh:
#            lines = [l for l in fh.read().split("\n") if not l.startswith(key + "=")]
#    lines = [l for l in lines if l.strip()]
#    lines.append("%s=%s" % (key, value))
#    tmp = CONFIG + ".tmp"
#    with open(tmp, "w") as fh:
#        fh.write("\n".join(lines) + "\n")
#    os.chmod(tmp, 0o600)
#    os.replace(tmp, CONFIG)
#
#
#def make_admin_server(ctx, port):
#    return TLSServer(("0.0.0.0", port), Admin, ctx)
#
#
#def main():
#    global STORE, CFG, CATALOGUE
#    CFG = load_config()
#    CATALOGUE = load_catalogue()
#    STORE = Store(DB)
#
#    port = int(CFG["ADMIN_PORT"])
#    cert = CFG.get("ADMIN_CERT")
#    key = CFG.get("ADMIN_KEY")
#    if cert and key and os.path.exists(cert):
#        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
#        ctx.load_cert_chain(cert, key)
#        httpd = make_admin_server(ctx, port)
#        scheme = "https"
#    else:
#        # Refuse rather than silently serve a login form in the clear: the
#        # password would cross the network readable by anyone on the path.
#        sys.exit("no certificate at %s - refusing to serve the panel over plain "
#                 "http" % cert)
#    print("admin panel up on %s://0.0.0.0:%d/%s/"
#          % (scheme, port, CFG["ADMIN_PATH"]), flush=True)
#    httpd.serve_forever()
#
#
#if __name__ == "__main__":
#    main()
#__END_ADMIN__

#__BEGIN_ADMIN_SERVICE__
#[Unit]
#Description=Smart DNS admin web panel
#After=network-online.target smartdns-panel.service
#
#[Service]
#Type=simple
#ExecStart=/usr/local/bin/smartdns-admin
#Restart=always
#RestartSec=10
## Reads the certificate and writes admin.env when the password changes, so it
## needs root - but nothing else on the box.
#NoNewPrivileges=yes
#ProtectHome=yes
#PrivateTmp=yes
#
#[Install]
#WantedBy=multi-user.target
#__END_ADMIN_SERVICE__

#__BEGIN_SMARTDNS_ACCESS__
##!/bin/bash
## smartdns-access - change how the admin panel is reached.
##
## usage: smartdns-access                    show the address it answers on
##        smartdns-access port <number>      move it to another port
##        smartdns-access path [new]         change the secret path, or roll one
##        smartdns-access password [new]     set a new password
##        smartdns-access rotate             new path and new password at once
##
## Three things stand in front of the panel and only one of them is a secret in
## the cryptographic sense:
##
##   the port    keeps it out of the way of casual scanning, nothing more
##   the path    an unguessable URL - it is a secret, but it travels in every
##               request line and lands in any proxy log along the way
##   the password the actual authentication
##
## So this can change all three, and the password is the one that matters. It
## is never stored: only a salted hash goes into admin.env, which is why a
## forgotten password is replaced rather than recovered.
#set -uo pipefail
#export PATH="$PATH:/usr/sbin:/sbin"
#
#CONF=/etc/smart-dns/admin.env
#UNIT=smartdns-admin.service
#
#R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
#[ -t 1 ] || { R=; G=; Y=; B=; N=; }
#die() { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
#
#[ "$(id -u)" = 0 ] || die "run as root"
#[ -f "$CONF" ] || die "$CONF is missing - this machine has no admin panel.
#    It is set up on the exit node, by the installer, once the machine has a
#    domain and a certificate."
#
#get() { sed -n "s/^$1=//p" "$CONF" | head -1; }
#
#set_key() {
#    local key="$1" value="$2" tmp
#    tmp="$(mktemp)"
#    grep -v "^${key}=" "$CONF" > "$tmp" 2>/dev/null || true
#    printf '%s=%s\n' "$key" "$value" >> "$tmp"
#    # Copy rather than move: the file is mode 600 and owned by root, and a
#    # move from /tmp would bring the temporary file's permissions with it.
#    cat "$tmp" > "$CONF"
#    rm -f "$tmp"
#    chmod 600 "$CONF"
#}
#
#hash_password() {
#    ADMIN_PASS="$1" ADMIN_SALT="$2" python3 -c '
#import hashlib, os
#print(hashlib.pbkdf2_hmac("sha256", os.environ["ADMIN_PASS"].encode(),
#                          bytes.fromhex(os.environ["ADMIN_SALT"]), 200000).hex())'
#}
#
#domain() {
#    # Whatever the certificate is for. The panel answers on any address the
#    # machine has, but only this name matches the certificate, so it is the
#    # only one worth printing.
#    local d
#    d="$(sed -n 's|^ADMIN_CERT=/etc/letsencrypt/live/\([^/]*\)/.*|\1|p' "$CONF" | head -1)"
#    [ -n "$d" ] || d="$(hostname -I 2>/dev/null | awk '{print $1}')"
#    printf '%s' "${d:-this-server}"
#}
#
#show() {
#    printf '\n    %sAdmin panel%s\n\n        https://%s:%s/%s/\n\n' \
#        "$B" "$N" "$(domain)" "$(get ADMIN_PORT)" "$(get ADMIN_PATH)"
#    printf '    The password is not stored, only a hash of it. If it is lost,\n'
#    printf '    set a new one:  smartdns-access password\n\n'
#}
#
#restart() {
#    systemctl restart "$UNIT" 2>/dev/null
#    sleep 2
#    if systemctl is-active --quiet "$UNIT"; then
#        printf '%s    panel restarted%s\n' "$G" "$N"
#    else
#        printf '%s    the panel did not come back - journalctl -u %s%s\n' \
#            "$Y" "$UNIT" "$N"
#    fi
#}
#
#case "${1:-show}" in
#show|"")
#    show
#    ;;
#
#port)
#    new="${2:-}"
#    case "$new" in
#        ""|*[!0-9]*) die "usage: smartdns-access port <number>" ;;
#    esac
#    [ "$new" -ge 1 ] && [ "$new" -le 65535 ] || die "a port is 1-65535"
#    # These belong to the service itself. Moving the panel onto one of them
#    # would take down the thing it is meant to administer.
#    case "$new" in
#        53|80|443) die "port $new is the service's own - pick another" ;;
#        8443) die "port 8443 is the sync API the relays talk to" ;;
#        8446) die "port 8446 is the exit's own route to Google over IPv6" ;;
#        22) die "port 22 is ssh" ;;
#    esac
#    old="$(get ADMIN_PORT)"
#    if [ "$new" != "$old" ] && ss -tlnH "sport = :$new" 2>/dev/null | grep -q .; then
#        die "something else is already listening on $new"
#    fi
#    set_key ADMIN_PORT "$new"
#    printf '    port %s -> %s\n' "$old" "$new"
#    restart
#    show
#    ;;
#
#path)
#    new="${2:-}"
#    if [ -z "$new" ]; then
#        new="$(openssl rand -hex 12)"
#    else
#        case "$new" in
#            */*|*' '*|*'?'*|*'#'*) die "a path is one segment: letters, digits, - and _" ;;
#            *[!A-Za-z0-9_-]*) die "use only letters, digits, - and _" ;;
#        esac
#        [ "${#new}" -ge 8 ] || die "too short to be unguessable - use 8 or more"
#    fi
#    set_key ADMIN_PATH "$new"
#    printf '    the old address stops working now.\n'
#    restart
#    show
#    ;;
#
#password)
#    new="${2:-}"
#    if [ -z "$new" ]; then
#        # -s so it is not echoed, and asked twice because it cannot be read
#        # back afterwards to check.
#        printf '  new password (8 or more, not shown as you type): '
#        read -rs new; printf '\n'
#        printf '  again: '
#        read -rs again; printf '\n'
#        [ "$new" = "$again" ] || die "they did not match - nothing changed"
#    fi
#    [ "${#new}" -ge 8 ] || die "use 8 characters or more"
#    salt="$(openssl rand -hex 16)"
#    hash="$(hash_password "$new" "$salt")" || die "could not hash the password"
#    [ -n "$hash" ] || die "could not hash the password"
#    set_key ADMIN_SALT "$salt"
#    set_key ADMIN_HASH "$hash"
#    printf '    password changed. Everyone signed in is signed out.\n'
#    # Sessions live in the panel's memory, so restarting is what ends them -
#    # which is the point of changing a password.
#    restart
#    ;;
#
#rotate)
#    "$0" path >/dev/null
#    "$0" password "${2:-}"
#    show
#    ;;
#
#*)
#    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
#    exit 1
#    ;;
#esac
#__END_SMARTDNS_ACCESS__

#__BEGIN_SMARTDNS_LOGS__
##!/bin/bash
## smartdns-logs - what this machine has been doing, all in one place.
##
## usage: smartdns-logs          recent logs of every part, and whether each runs
##        smartdns-logs -e       only warnings and errors
##        smartdns-logs -f       follow them live (ctrl-c to stop)
##        smartdns-logs -n 500   more lines per part (default 100)
##        smartdns-logs --report all of it in one file to send, secrets masked
#set -uo pipefail
#
## Where this machine's config lives. A variable only so a test can point it
## somewhere else; nothing else sets it.
#ETC="${SMARTDNS_ETC:-/etc/smart-dns}"
#
#n=100
#follow=no
#report=""
#errors=""
## journald's own level filter. The programs mark their warnings and errors
## with a syslog level, so this is exactly the problems and nothing else.
#prio=()
#while [ $# -gt 0 ]; do
#    case "$1" in
#        -e|--errors) errors=yes; prio=(-p warning) ;;
#        -f|--follow) follow=yes ;;
#        --report) report=yes ;;
#        -n) shift; n="${1:-}" ;;
#        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
#        *) echo "unknown option: $1  (try -h)" >&2; exit 1 ;;
#    esac
#    shift
#done
#case "$n" in ''|*[!0-9]*) echo "-n wants a number of lines" >&2; exit 1 ;; esac
#[ "$(id -u)" = 0 ] || { echo "run as root:  sudo smartdns-logs" >&2; exit 1; }
#
## Which side this is decides which parts it has. The timers are listed for
## their status - a oneshot service reads "inactive" between runs, which looks
## like a fault and is not - and the services for their logs.
#if [ -f "$ETC/sync.env" ]; then
#    role=relay
#    status="smartdns-sync dnsmasq nginx coturn epic-pin.timer smartdns-acl-save.timer"
#    logs="smartdns-sync dnsmasq nginx coturn epic-pin smartdns-acl-save"
#    for f in /etc/smartdns-profiles/*.conf; do
#        [ -e "$f" ] || continue
#        status="$status smartdns-dns@$(basename "$f" .conf)"
#        logs="$logs smartdns-dns@$(basename "$f" .conf)"
#    done
#elif [ -f "$ETC/panel.env" ]; then
#    role=exit
#    status="smartdns-panel smartdns-admin nginx smartdns-cert.timer"
#    logs="smartdns-panel smartdns-admin nginx smartdns-cert"
#    # Only where there is an admin panel to show operators on.
#    if [ -f /etc/systemd/system/smartdns-operators.timer ]; then
#        status="$status smartdns-operators.timer"
#        logs="$logs smartdns-operators"
#    fi
#else
#    echo "doctor dns is not installed on this machine" >&2
#    exit 1
#fi
## The tunnel, on either side, when the installer set one up.
#if [ -f /etc/systemd/system/smartdns-tunnel.service ]; then
#    status="$status smartdns-tunnel"
#    logs="$logs smartdns-tunnel"
#fi
#
## Every secret in this machine's config, replaced wherever it turns up in a
## report. None should ever reach a log, but a report is made to be handed to
## somebody else. Paths are left alone: they are where things are, not keys.
#MASK=$(cat <<'PY'
#import glob, re, sys
#found = set()
#for path in glob.glob(sys.argv[1] + "/*.env"):
#    try:
#        with open(path) as fh:
#            for line in fh:
#                key, _, value = line.strip().partition("=")
#                value = value.strip().strip("\"'")
#                if (re.search(r"SECRET|PATH|HASH|SALT|TOKEN|PASS", key)
#                        and len(value) >= 6 and not value.startswith("/")):
#                    found.add(value.encode())
#    except OSError:
#        pass
#data = sys.stdin.buffer.read()
#for value in sorted(found, key=len, reverse=True):
#    data = data.replace(value, b"<secret>")
#sys.stdout.buffer.write(data)
#PY
#)
#
## One file with everything worth sending when something is wrong - the state of
## each part, its warnings and errors, its recent logs - with the secrets masked.
## It still holds customers' addresses and usernames: those are what the logs
## are about, and the reader is told so.
#if [ -n "$report" ]; then
#    out="${SMARTDNS_REPORT_DIR:-/tmp}/doctor-dns-report-$role-$(date -u +%Y%m%d-%H%M%S).txt"
#    umask 077
#    {
#        echo "doctor dns report - $role - $(date -u '+%F %T') UTC"
#        echo "version  $(cat /var/lib/smart-dns/version 2>/dev/null || echo '?')"
#        echo "system   $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}"), kernel $(uname -r)"
#        echo "up       $(uptime -p 2>/dev/null || echo '?')"
#        # A clock that has drifted breaks TLS between the two machines and
#        # moves every expiry date, so it earns a line in any report.
#        echo "clock    $(timedatectl show -p NTPSynchronized --value 2>/dev/null \
#                         | sed 's/^yes$/synchronised/; s/^no$/NOT synchronised/')"
#        echo
#        echo "== disk and memory"
#        df -h / 2>/dev/null | tail -1
#        free -m 2>/dev/null | sed -n '1,2p'
#        if [ "$role" = relay ]; then
#            echo
#            echo "== routing"
#            smartdns-rules 2>&1
#            echo
#            echo "== access control"
#            smartdns-acl enforce status 2>&1 | head -3
#        fi
#        echo
#        echo "################ warnings and errors ################"
#        bash "$0" -e -n 300
#        echo
#        echo "################ recent logs ################"
#        bash "$0" -n 150
#    } 2>&1 | python3 -c "$MASK" "$ETC" > "$out"
#    echo "report written: $out ($(du -k "$out" | cut -f1) KB)"
#    echo "Secrets and the admin panel's address are masked. It does hold your"
#    echo "customers' IP addresses and usernames, from the logs - send it only"
#    echo "to someone you trust."
#    exit 0
#fi
#
#if [ "$follow" = yes ]; then
#    args=()
#    for u in $logs; do args+=(-u "$u"); done
#    exec journalctl "${args[@]}" ${prio[@]+"${prio[@]}"} -f -n 20 --no-pager -o short-iso
#fi
#
#printf 'doctor dns %s - %s\n' \
#       "$(cat /var/lib/smart-dns/version 2>/dev/null || echo '?')" "$role"
#echo
#echo "== services"
#for u in $status; do
#    printf '  %-26s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"
#done
#failed="$(systemctl list-units --state=failed --no-legend 2>/dev/null)"
#if [ -n "$failed" ]; then
#    echo
#    echo "== failed"
#    echo "$failed"
#fi
#for u in $logs; do
#    echo
#    echo "== $u"
#    journalctl -u "$u" ${prio[@]+"${prio[@]}"} -n "$n" --no-pager -o short-iso 2>/dev/null
#done
#if [ -s /var/log/nginx/error.log ]; then
#    echo
#    echo "== nginx errors"
#    if [ -n "$errors" ]; then
#        # "access forbidden by rule" is the exit turning away everyone but its
#        # relay - the gate doing its job, at nginx's error level. Not a problem.
#        grep -v 'access forbidden by rule' /var/log/nginx/error.log | tail -n "$n"
#    else
#        tail -n "$n" /var/log/nginx/error.log
#    fi
#fi
#__END_SMARTDNS_LOGS__

#__BEGIN_SMARTDNS_RULES__
##!/usr/bin/env python3
#"""smartdns-rules - what each template's resolver does with a domain.
#
#usage: smartdns-rules                  every resolver on this relay, and what it routes
#       smartdns-rules show [TEMPLATE]  what one template redirects, bypasses and pins
#       smartdns-rules check DOMAIN...  what every template does with these names
#
#Every template that has customers gets its own dnsmasq on this relay; the
#default template is the resolver on port 53. `check` answers from both sides:
#the rule that decides the name, read from that resolver's own files, and the
#answer the resolver actually gives when asked. A resolver still running on old
#config shows up as the two disagreeing.
#
#Nothing here reads a customer's traffic. It says where a name would go, not
#who asked for it.
#"""
#import collections
#import json
#import os
#import random
#import re
#import signal
#import socket
#import struct
#import subprocess
#import sys
#
#SYNC_ENV = "/etc/smart-dns/sync.env"
#DNSMASQ_D = "/etc/dnsmasq.d"
#BASE_DIR = "/etc/smartdns-base"
#PROFILE_DIR = "/etc/smartdns-profiles"
#TEMPLATE_NAMES = "/var/lib/smart-dns/templates.json"
#CUSTOM_CONF = "50-smartdns-custom.conf"
#ACL = "/usr/local/bin/smartdns-acl"
#NFT = "/usr/sbin/nft"
#NAT_TABLE = "smartdns_nat"
#MAIN_PORT = 53
#HOST = "127.0.0.1"
#TIMEOUT = 3.0
#
## address=/a.com/b.com/1.2.3.4, server=/a.com/1.1.1.1, local=/a.com/. A server=
## line with no slashes is an upstream, not a rule about any name.
#RULE_LINE = re.compile(r"^(address|server|local)=/(.+)/([^/]*)$")
#DOMAIN = re.compile(r"^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)*$")
#
#Rule = collections.namedtuple("Rule", "kind domain target source")
#
#
#def run(*args):
#    try:
#        return subprocess.run(list(args), capture_output=True, text=True,
#                              timeout=20)
#    except (OSError, subprocess.SubprocessError):
#        return None
#
#
#def self_ip():
#    try:
#        with open(SYNC_ENV) as fh:
#            for line in fh:
#                k, _, v = line.strip().partition("=")
#                if k.strip() == "SELF_IP":
#                    return v.strip().strip('"').strip("'")
#    except OSError:
#        pass
#    return None
#
#
## ------------------------------------------------------------------ reading
#def conf_dir_files(d):
#    """The files dnsmasq reads from a --conf-dir: all of them, less the ones
#    it skips itself and the package manager's leftovers."""
#    try:
#        names = sorted(os.listdir(d))
#    except OSError:
#        return []
#    out = []
#    for n in names:
#        if n.startswith(".") or n.endswith("~") or (n.startswith("#") and n.endswith("#")):
#            continue
#        if n.endswith((".dpkg-dist", ".dpkg-old", ".dpkg-new")):
#            continue
#        p = os.path.join(d, n)
#        if os.path.isfile(p):
#            out.append(p)
#    return out
#
#
#def read_rules(path):
#    rules = []
#    try:
#        fh = open(path, encoding="utf-8", errors="replace")
#    except OSError:
#        return rules
#    with fh:
#        for line in fh:
#            m = RULE_LINE.match(line.strip())
#            if not m:
#                continue
#            kind, domains, target = m.groups()
#            for d in domains.split("/"):
#                d = d.strip().lower().rstrip(".")
#                if d:
#                    rules.append(Rule(kind, d, target.strip(), os.path.basename(path)))
#    return rules
#
#
#def conf_port(path):
#    try:
#        with open(path) as fh:
#            for line in fh:
#                if line.startswith("port="):
#                    return int(line.split("=", 1)[1])
#    except (OSError, ValueError):
#        pass
#    return None
#
#
#def load_names():
#    """Template names by id, and the default's id, as the panel last sent them."""
#    try:
#        with open(TEMPLATE_NAMES, encoding="utf-8") as fh:
#            info = json.load(fh)
#        names = {str(k): str(v) for k, v in (info.get("names") or {}).items()}
#        return names, str(info.get("default") or "")
#    except (OSError, ValueError, AttributeError):
#        return {}, ""
#
#
#class Resolver:
#    def __init__(self, key, port, files, name=""):
#        self.key, self.port, self.files, self.name = key, port, files, name
#        self.rules = [r for f in files for r in read_rules(f)]
#
#    @property
#    def unit(self):
#        return "dnsmasq" if self.key == "main" else "smartdns-dns@%s" % self.key
#
#    def label(self):
#        if self.key == "main":
#            return "%s (default)" % self.name if self.name else "default template"
#        return self.name or "template %s" % self.key
#
#    def decide(self, name):
#        """The rule dnsmasq applies to `name`: the longest domain that covers
#        it, and at a tie address= over server= - which is how this dnsmasq
#        behaves, measured, and why a template cannot un-route a name that
#        another file it reads routes."""
#        best = key = None
#        for r in self.rules:
#            if r.domain == "#":
#                length = 0
#            elif name == r.domain or name.endswith("." + r.domain):
#                length = len(r.domain)
#            else:
#                continue
#            k = (length, 1 if r.kind == "address" else 0)
#            if key is None or k > key:
#                best, key = r, k
#        return best
#
#
#def resolvers():
#    names, default = load_names()
#    out = [Resolver("main", MAIN_PORT, conf_dir_files(DNSMASQ_D),
#                    names.get(default, ""))]
#    try:
#        confs = [f for f in os.listdir(PROFILE_DIR) if f.endswith(".conf")]
#    except OSError:
#        confs = []
#    for f in sorted(confs, key=lambda f: (len(f), f)):
#        path = os.path.join(PROFILE_DIR, f)
#        key = f[:-len(".conf")]
#        out.append(Resolver(key, conf_port(path), conf_dir_files(BASE_DIR) + [path],
#                            names.get(key, "")))
#    return out
#
#
#def meaning(rule, me):
#    """(where it goes, how to say it) for the rule deciding a name."""
#    if rule is None:
#        return "direct", "no rule"
#    shown = "%s=/%s/%s" % (rule.kind, rule.domain, rule.target)
#    if rule.kind == "address":
#        if rule.target == me:
#            return "relay", shown
#        if rule.target in ("", "#", "0.0.0.0", "::"):
#            return "blocked", shown
#        return "pinned", shown
#    if rule.kind == "server":
#        return "direct", shown
#    return "local", shown
#
#
## ------------------------------------------------------------------ asking
#def skip_name(buf, off):
#    while True:
#        n = buf[off]
#        if n == 0:
#            return off + 1
#        if n & 0xC0 == 0xC0:
#            return off + 2
#        off += 1 + n
#
#
#def ask(name, port, host=None, timeout=None):
#    """The A records a resolver gives for `name`: a list, empty when it
#    answered with none, or None when it did not answer at all."""
#    qid = random.randrange(65536)
#    packet = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
#    for label in name.encode("idna").split(b"."):
#        if label:
#            packet += bytes([len(label)]) + label
#    packet += b"\x00" + struct.pack(">HH", 1, 1)
#    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
#    s.settimeout(timeout or TIMEOUT)
#    try:
#        s.sendto(packet, (host or HOST, port))
#        while True:
#            data, _ = s.recvfrom(4096)
#            if len(data) >= 12 and struct.unpack(">H", data[:2])[0] == qid:
#                break
#    except OSError:
#        return None
#    finally:
#        s.close()
#    try:
#        qd, an = struct.unpack(">HH", data[4:8])
#        off = 12
#        for _ in range(qd):
#            off = skip_name(data, off) + 4
#        ips = []
#        for _ in range(an):
#            off = skip_name(data, off)
#            typ, _cls, _ttl, rdlen = struct.unpack(">HHIH", data[off:off + 10])
#            off += 10
#            if typ == 1 and rdlen == 4:
#                ips.append(socket.inet_ntoa(data[off:off + 4]))
#            off += rdlen
#        return ips
#    except (IndexError, struct.error):
#        return []
#
#
## --------------------------------------------------------------- customers
#def assignment():
#    """Registered addresses per resolver port, read off the redirect rules.
#
#    Not off the sets alone: a set no rule points at is a leftover, and the
#    addresses in it are really answered by the default resolver on 53.
#    """
#    r = run(NFT, "list", "chain", "ip", NAT_TABLE, "pre")
#    ports = {}
#    if r is not None and r.returncode == 0:
#        for m in re.finditer(r"ip saddr @(\S+) (?:udp|tcp) dport 53 redirect to :(\d+)",
#                             r.stdout):
#            ports[m.group(1)] = int(m.group(2))
#    by_port = {}
#    for setname, port in ports.items():
#        members = set()
#        r = run(NFT, "-j", "list", "set", "ip", NAT_TABLE, setname)
#        if r is not None and r.returncode == 0:
#            try:
#                for item in json.loads(r.stdout).get("nftables", []):
#                    for e in (item.get("set") or {}).get("elem") or []:
#                        if isinstance(e, dict):
#                            e = (e.get("elem") or {}).get("val", e)
#                        if isinstance(e, str):
#                            members.add(e)
#            except (ValueError, AttributeError):
#                pass
#        by_port.setdefault(port, set()).update(members)
#    return by_port
#
#
#def registered():
#    r = run(ACL, "list", "--json")
#    if r is None or r.returncode != 0:
#        return None
#    try:
#        return {row["ip"] for row in json.loads(r.stdout)}
#    except (ValueError, TypeError, KeyError):
#        return None
#
#
#def state(unit):
#    r = run("systemctl", "is-active", unit)
#    return (r.stdout.strip() or "unknown") if r is not None else "unknown"
#
#
## ---------------------------------------------------------------- commands
#def counts(res, me):
#    """Distinct names per kind. Not lines: every bypass is written twice, once
#    per public resolver, and would otherwise count double."""
#    seen = collections.defaultdict(set)
#    for r in res.rules:
#        seen[meaning(r, me)[0]].add(r.domain)
#    return collections.Counter({k: len(v) for k, v in seen.items()})
#
#
#def cmd_summary():
#    me = self_ip()
#    rs = resolvers()
#    regs = registered()
#    ports = assignment()
#    on_profile = set().union(*ports.values()) if ports else set()
#    print("doctor dns routing - this relay answers as %s" % (me or "?"))
#    print()
#    print("  %5s  %9s  %8s  %6s  %6s  %-9s %s"
#          % ("PORT", "CUSTOMERS", "REDIRECT", "BYPASS", "PINNED", "STATE", "TEMPLATE"))
#    for res in rs:
#        if res.key == "main":
#            n = len(regs - on_profile) if regs is not None else "?"
#        else:
#            n = len(ports.get(res.port, ())) if regs is not None or ports else 0
#        c = counts(res, me)
#        print("  %5s  %9s  %8d  %6d  %6d  %-9s %s"
#              % (res.port or "?", n, c["relay"], c["direct"], c["pinned"],
#                 state(res.unit), res.label()))
#    print()
#    print("A template with no customers has no resolver here, so is not listed.")
#    if regs is None:
#        print("(customers are counted from the firewall - run as root to see them)")
#    print("try: smartdns-rules check <domain>    smartdns-rules show <template>")
#    return 0
#
#
#def find(rs, arg):
#    if not arg or arg.lower() in ("main", "default"):
#        return rs[0]
#    for res in rs:
#        if res.key == arg or (res.name and res.name.casefold() == arg.casefold()):
#            return res
#    return None
#
#
#def cmd_show(arg):
#    me = self_ip()
#    rs = resolvers()
#    res = find(rs, arg)
#    if res is None:
#        names, _ = load_names()
#        if any(n.casefold() == arg.casefold() for n in names.values()) or arg in names:
#            print("template %s has no customers, so it has no resolver on this relay "
#                  "yet - it gets one when somebody is put on it." % arg)
#            return 0
#        print("no template %r here. There are: %s"
#              % (arg, ", ".join(r.name or r.key for r in rs)), file=sys.stderr)
#        return 1
#    custom = {r.domain for r in read_rules(os.path.join(DNSMASQ_D, CUSTOM_CONF))}
#    groups = collections.defaultdict(dict)
#    for r in res.rules:
#        kind = meaning(r, me)[0]
#        groups[kind].setdefault(r.domain, r)
#    print("%s - resolver on :%s" % (res.label(), res.port or "?"))
#    titles = (("relay", "redirected to this relay"),
#              ("direct", "bypassed - resolved elsewhere, the customer goes direct"),
#              ("pinned", "pinned to a fixed address"),
#              ("blocked", "answered with nothing"),
#              ("local", "answered locally"))
#    for kind, title in titles:
#        rows = groups.get(kind)
#        if not rows:
#            continue
#        print()
#        print("%s (%d):" % (title, len(rows)))
#        for d in sorted(rows):
#            r = rows[d]
#            tag = "  [custom]" if d in custom else ""
#            if kind in ("direct", "pinned"):
#                print("  %-44s %s%s" % (d, r.target, tag))
#            else:
#                print("  %s%s" % (d, tag))
#    print()
#    print("Anything not listed has no rule: it resolves normally and goes direct.")
#    return 0
#
#
#def clean(raw):
#    d = raw.strip().lower()
#    d = re.sub(r"^[a-z]+://", "", d).split("/")[0].split(":")[0].strip(".")
#    try:
#        d = d.encode("idna").decode("ascii")
#    except UnicodeError:
#        return None
#    return d if DOMAIN.match(d) else None
#
#
#def cmd_check(domains):
#    me = self_ip()
#    rs = resolvers()
#    trouble = 0
#    for raw in domains:
#        name = clean(raw)
#        if not name:
#            print("not a domain: %s" % raw)
#            trouble = 1
#            continue
#        print(name)
#        for res in rs:
#            rule = res.decide(name)
#            kind, shown = meaning(rule, me)
#            live = ask(name, res.port) if res.port else None
#            if live is None:
#                seen, agree = "no answer", False
#            elif not live:
#                seen, agree = "no address", kind not in ("relay", "pinned")
#            else:
#                seen = "answered " + " ".join(live[:2])
#                if kind == "relay":
#                    agree = me in live
#                elif kind == "pinned":
#                    agree = rule.target in live
#                else:
#                    agree = me not in live
#            # The rule and the file it came from share one column, so a long
#            # file name cannot push the answer out of line.
#            why = "%s  (%s)" % (shown, rule.source) if rule else shown
#            print("  :%-5s %-7s %-68s %-30s %s"
#                  % (res.port or "?", kind, why, seen, res.label()))
#            if not agree:
#                trouble = 1
#                if live is None:
#                    print("  ! the resolver did not answer - is %s running?" % res.unit)
#                else:
#                    print("  ! its rules say %s, but that is not what it answered - "
#                          "it may be running on old config: systemctl restart %s"
#                          % (kind, res.unit))
#    return trouble
#
#
#def main(argv):
#    try:
#        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
#    except Exception:
#        pass
#    # `smartdns-rules show | head` closes the pipe early; that is the reader
#    # being done, not an error worth a traceback.
#    if hasattr(signal, "SIGPIPE"):
#        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
#    usage = __doc__.split("\n\n")[1]
#    if not argv:
#        return cmd_summary()
#    cmd, rest = argv[0], argv[1:]
#    if cmd in ("-h", "--help", "help"):
#        print(usage)
#        return 0
#    if cmd == "show":
#        return cmd_show(" ".join(rest) if rest else None)
#    if cmd == "check" and rest:
#        return cmd_check(rest)
#    print(usage, file=sys.stderr)
#    return 2
#
#
#if __name__ == "__main__":
#    sys.exit(main(sys.argv[1:]))
#__END_SMARTDNS_RULES__

#__BEGIN_SMARTDNS_RESTART__
##!/bin/bash
## smartdns-restart - restart every part of doctor dns on this machine at once.
##
## usage: smartdns-restart      restart them all, then say which came back up
##        smartdns-restart -h   this help
#set -uo pipefail
#
## Where this machine's config lives, and its templates' resolvers. Variables
## only so a test can point them somewhere else; nothing else sets them.
#ETC="${SMARTDNS_ETC:-/etc/smart-dns}"
#PROFILES="${SMARTDNS_PROFILES:-/etc/smartdns-profiles}"
#
#case "${1:-}" in
#    "") ;;
#    -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
#    *) echo "unknown option: $1  (try -h)" >&2; exit 1 ;;
#esac
#[ "$(id -u)" = 0 ] || { echo "run as root:  sudo smartdns-restart" >&2; exit 1; }
#
## Services only. The timers are clocks with nothing to unstick, and nftables is
## left alone on purpose: restarting it reloads the rules from disk, which throws
## away the allowlist and the usage counted since the last save.
#if [ -f "$ETC/sync.env" ]; then
#    role=relay
#    resolvers=""
#    for f in "$PROFILES"/*.conf; do
#        [ -e "$f" ] || continue
#        resolvers="$resolvers smartdns-dns@$(basename "$f" .conf)"
#    done
#    units="smartdns-sync$resolvers dnsmasq coturn smartdns-tunnel nginx"
#elif [ -f "$ETC/panel.env" ]; then
#    role=exit
#    units="smartdns-panel smartdns-admin smartdns-tunnel nginx"
#else
#    echo "doctor dns is not installed on this machine" >&2
#    exit 1
#fi
#
#installed() { [ "$(systemctl show -p LoadState --value "$1" 2>/dev/null)" = loaded ]; }
#
## A service that failed too often in a row is refused a restart until its
## failures are forgotten - and that is exactly when somebody reaches for this.
#restart() {
#    systemctl reset-failed "$@" 2>/dev/null
#    systemctl restart "$@" 2>&1 | sed 's/^/    /'
#}
#
#echo "restarting doctor dns - $role"
#[ "$role" = relay ] && echo "customers' open connections drop for a moment and come straight back"
#echo
#
#skipped=""
#if [ "$role" = relay ]; then
#    # In one call, so systemd restarts each resolver once: they are PartOf the
#    # sync agent and would otherwise go down again with it.
#    restart smartdns-sync $resolvers
#    # A config that does not load would keep dnsmasq down after the restart,
#    # where right now it is at least running on the old one.
#    if out="$(dnsmasq --test -C /etc/dnsmasq.conf 2>&1)"; then
#        restart dnsmasq
#    else
#        echo "  dnsmasq's config does not load, so it was left running as it was:"
#        printf '%s\n' "$out" | sed 's/^/    /'
#        skipped="$skipped dnsmasq"
#    fi
#    restart coturn
#else
#    restart smartdns-panel
#    installed smartdns-admin && restart smartdns-admin
#fi
## The tunnel, when there is one, before nginx: nginx falls back to the direct
## path while it is down, so this order costs nobody a connection.
#installed smartdns-tunnel && restart smartdns-tunnel
## The same for nginx, which carries every customer's traffic.
#if out="$(nginx -t 2>&1)"; then
#    restart nginx
#else
#    echo "  nginx's config does not load, so it was left running as it was:"
#    printf '%s\n' "$out" | sed 's/^/    /'
#    skipped="$skipped nginx"
#fi
#
#sleep 2
#fail=0
#for u in $units; do
#    installed "$u" || continue
#    state="$(systemctl is-active "$u" 2>/dev/null)"
#    case " $skipped " in *" $u "*) state="$state (not restarted)"; fail=1 ;; esac
#    [ "${state%% *}" = active ] || fail=1
#    printf '  %-26s %s\n' "$u" "$state"
#done
#echo
#if [ "$fail" = 0 ]; then
#    echo "all of it is back up"
#else
#    echo "not everything came back - see why with:  sudo smartdns-logs -e"
#    exit 1
#fi
#__END_SMARTDNS_RESTART__

#__BEGIN_SMARTDNS_WATCH__
##!/usr/bin/env python3
#"""smartdns-watch - the names a customer asks for, live, and where each went.
#
#usage: smartdns-watch               everybody, each line naming who asked
#       smartdns-watch ali           one customer, by username
#       smartdns-watch u12           ...or by the label smartdns-acl list shows
#       smartdns-watch 5.200.12.34   ...or by address
#
#For finding what a service needs routed: have the customer open it until it
#fails, and watch. "via relay" is already routed. "direct" went around the
#relay - if the service refuses Iran, those are the names to add, with
#`smartdns add NAME` or the panel's domains page. "filtered in Iran" is Iran's
#own block, which no routing gets past.
#
#It reads this relay's DNS answers off the wire as they leave - the very answer
#the device got, nothing asked again - and keeps nothing: what it prints is all
#there is. Ctrl-C stops it.
#"""
#import collections
#import ipaddress
#import json
#import os
#import signal
#import socket
#import struct
#import subprocess
#import sys
#import time
#
#SYNC_ENV = "/etc/smart-dns/sync.env"
#USER_NAMES = "/var/lib/smart-dns/users.json"
#ACL = "/usr/local/bin/smartdns-acl"
#ETH_P_IP = 0x0800
#SO_ATTACH_FILTER = 26
## The address Iran's filtering hands out for a name it blocks.
#FILTERED = "10.10.34."
## How long a question may go unanswered before it is shown as such. The relay
## drops an unregistered address's questions without a word, so this is also
## how an address that is not allowed shows up.
#WAIT = 3.0
#
## The socket takes every protocol, not IPv4 alone. A socket for one protocol is
## handed only what arrives, and the relay's answers - the half that says where
## each name went - are what it sends; only an every-protocol socket sees those.
## That is what tcpdump does too.
#ETH_P_ALL = 0x0003
#
## A classic BPF program, run in the kernel on every packet: IPv4, UDP, not a
## fragment, with 53 at either end. Everything else - which on a relay is
## nearly all of it, game downloads included - never reaches this process.
## A packet socket of type SOCK_DGRAM hands the filter the IP header at 0; the
## protocol comes from the kernel's own note on the packet.
#BPF = [
#    (0x28, 0, 0, 0xFFFFF000),   # ldh proto         the packet's ethertype
#    (0x15, 0, 10, ETH_P_IP),    # jeq #0x0800       IPv4, or drop
#    (0x30, 0, 0, 9),            # ldb [9]           protocol
#    (0x15, 0, 8, 17),           # jeq #17           UDP, or drop
#    (0x28, 0, 0, 6),            # ldh [6]           flags + fragment offset
#    (0x45, 6, 0, 0x1FFF),       # jset #0x1fff      a later fragment: drop
#    (0xB1, 0, 0, 0),            # ldxb 4*([0]&0xf)  header length
#    (0x48, 0, 0, 0),            # ldh [x+0]         source port
#    (0x15, 2, 0, 53),           # jeq #53           accept
#    (0x48, 0, 0, 2),            # ldh [x+2]         destination port
#    (0x15, 0, 1, 53),           # jeq #53           accept, or drop
#    (0x06, 0, 0, 0x40000),      # ret               accept
#    (0x06, 0, 0, 0),            # ret #0            drop
#]
#
#
#def attach_filter(sock):
#    import ctypes
#    prog = b"".join(struct.pack("HBBI", *ins) for ins in BPF)
#    buf = ctypes.create_string_buffer(prog, len(prog))
#    sock.setsockopt(socket.SOL_SOCKET, SO_ATTACH_FILTER,
#                    struct.pack("HP", len(BPF), ctypes.addressof(buf)))
#
#
## ------------------------------------------------------------------ packets
#def parse_ip_udp(pkt):
#    """(src, dst, sport, dport, payload) of an IPv4 UDP packet, else None."""
#    if len(pkt) < 28 or pkt[0] >> 4 != 4 or pkt[9] != 17:
#        return None
#    ihl = (pkt[0] & 0x0F) * 4
#    if ihl < 20 or len(pkt) < ihl + 8:
#        return None
#    sport, dport, ulen = struct.unpack("!HHH", pkt[ihl:ihl + 6])
#    return (socket.inet_ntoa(pkt[12:16]), socket.inet_ntoa(pkt[16:20]),
#            sport, dport, pkt[ihl + 8:ihl + max(ulen, 8)])
#
#
#def read_name(msg, off):
#    """A DNS name at `off`, and the offset just past where it was written."""
#    labels, end, jumps = [], None, 0
#    while True:
#        if off >= len(msg):
#            raise ValueError("truncated name")
#        n = msg[off]
#        if n & 0xC0 == 0xC0:
#            if off + 1 >= len(msg) or jumps > 20:
#                raise ValueError("bad pointer")
#            if end is None:
#                end = off + 2
#            off = ((n & 0x3F) << 8) | msg[off + 1]
#            jumps += 1
#            continue
#        if n & 0xC0:
#            raise ValueError("bad label")
#        if n == 0:
#            return ".".join(labels).lower(), (off + 1 if end is None else end)
#        labels.append(msg[off + 1:off + 1 + n].decode("ascii", "replace"))
#        off += 1 + n
#
#
#def parse_dns(msg):
#    """(id, is_response, rcode, name, qtype, [A addresses]) or None."""
#    if len(msg) < 12:
#        return None
#    qid, flags, qdcount, ancount = struct.unpack("!HHHH", msg[:8])
#    if qdcount != 1:
#        return None
#    try:
#        name, off = read_name(msg, 12)
#        qtype = struct.unpack("!H", msg[off:off + 2])[0]
#        off += 4
#        addrs = []
#        for _ in range(ancount if flags & 0x8000 else 0):
#            _, off = read_name(msg, off)
#            rtype, _, _, rdlen = struct.unpack("!HHIH", msg[off:off + 10])
#            off += 10
#            if rtype == 1 and rdlen == 4 and off + 4 <= len(msg):
#                addrs.append(socket.inet_ntoa(msg[off:off + 4]))
#            off += rdlen
#    except (ValueError, struct.error):
#        return None
#    return qid, bool(flags & 0x8000), flags & 0x0F, name, qtype, addrs
#
#
## ------------------------------------------------------------------ watching
#class Watcher:
#    """Pairs each question with its answer and prints a line per name.
#
#    A name is printed once, and again only if where it went changes - a CDN
#    hands out a different address every few seconds, which is not news.
#    """
#
#    def __init__(self, relay_ips, who, targets=None, out=None, clock=time.time):
#        self.local = set(relay_ips)
#        self.who = who
#        self.targets = targets
#        self.out = out or (lambda line: print(line, flush=True))
#        self.clock = clock
#        self.pending = {}
#        self.shown = {}
#        self.counts = collections.Counter()
#
#    def feed(self, pkt):
#        p = parse_ip_udp(pkt)
#        if not p:
#            return
#        src, dst, sport, dport, payload = p
#        if dport == 53 and src not in self.local:
#            client, port, asking = src, sport, True
#        elif sport == 53 and src in self.local and dst not in self.local:
#            client, port, asking = dst, dport, False
#        else:
#            return      # this relay asking its own upstream, or being answered
#        if self.targets is not None and client not in self.targets:
#            return
#        d = parse_dns(payload)
#        if not d:
#            return
#        qid, is_answer, rcode, name, qtype, addrs = d
#        if qtype != 1 or not name:
#            return      # AAAA and the rest: the relay serves IPv4 only
#        if asking and not is_answer:
#            self.pending[(client, port, qid)] = (name, self.clock())
#        elif is_answer and not asking:
#            self.pending.pop((client, port, qid), None)
#            self.report(client, name, self.verdict(rcode, addrs))
#
#    def verdict(self, rcode, addrs):
#        if rcode == 3:
#            return "no such name"
#        if rcode:
#            return "refused (rcode %d)" % rcode
#        if any(a in self.local for a in addrs):
#            return "via relay"
#        if any(a.startswith(FILTERED) for a in addrs):
#            return "filtered in Iran"
#        if addrs:
#            return "direct " + addrs[0]
#        return "no address"
#
#    def tick(self):
#        now = self.clock()
#        for key, (name, when) in list(self.pending.items()):
#            if now - when >= WAIT:
#                del self.pending[key]
#                self.report(key[0], name, "no answer")
#
#    def report(self, client, name, verdict):
#        kind = "direct" if verdict.startswith("direct") else verdict
#        if self.shown.get((client, name)) == kind:
#            return
#        self.shown[(client, name)] = kind
#        self.counts[kind.split(" (")[0]] += 1
#        stamp = time.strftime("%H:%M:%S", time.localtime(self.clock()))
#        who = "" if self.targets and len(self.targets) == 1 else \
#            "%-14s " % self.who.get(client, client)[:14]
#        self.out("%s  %s%-44s %s" % (stamp, who, name, verdict))
#
#    def summary(self):
#        total = sum(self.counts.values())
#        if not total:
#            return "no names seen"
#        parts = ["%d %s" % (n, k) for k, n in self.counts.most_common()]
#        return "%d names: %s" % (total, ", ".join(parts))
#
#
## ------------------------------------------------------------------ who is who
#def run(*args):
#    try:
#        return subprocess.run(list(args), capture_output=True, text=True, timeout=20)
#    except (OSError, subprocess.SubprocessError):
#        return None
#
#
#def self_ip():
#    try:
#        with open(SYNC_ENV) as fh:
#            for line in fh:
#                k, _, v = line.strip().partition("=")
#                if k.strip() == "SELF_IP":
#                    return v.strip().strip('"').strip("'")
#    except OSError:
#        pass
#    return None
#
#
#def local_addresses():
#    found = {"127.0.0.1"}
#    r = run("ip", "-4", "-o", "addr", "show")
#    for line in (r.stdout if r else "").splitlines():
#        parts = line.split()
#        if "inet" in parts:
#            found.add(parts[parts.index("inet") + 1].split("/")[0])
#    mine = self_ip()
#    if mine:
#        found.add(mine)
#    return found
#
#
#def load_users():
#    """{ip: {"label": "u12", "user": "ali"}} and the set that is allowed.
#
#    Usernames come from the panel by way of the sync agent. An older panel sends
#    none, and then the labels from the allowlist are all there is.
#    """
#    users = {}
#    try:
#        with open(USER_NAMES, encoding="utf-8") as fh:
#            data = json.load(fh)
#        if isinstance(data, dict):
#            users = {ip: v for ip, v in data.items() if isinstance(v, dict)}
#    except (OSError, ValueError):
#        pass
#    allowed = set()
#    r = run(ACL, "list", "--json")
#    try:
#        for row in json.loads(r.stdout) if r and r.returncode == 0 else []:
#            allowed.add(row["ip"])
#            users.setdefault(row["ip"], {"label": row.get("name", ""), "user": ""})
#    except (ValueError, KeyError, TypeError):
#        pass
#    return users, allowed
#
#
#def resolve(arg, users):
#    """The addresses an argument means: itself, or a customer's."""
#    try:
#        return {str(ipaddress.IPv4Address(arg.strip()))}
#    except ValueError:
#        pass
#    want = arg.strip().lower()
#    return {ip for ip, u in users.items()
#            if want and want in ((u.get("user") or "").lower(),
#                                 (u.get("label") or "").lower())}
#
#
#def display(users):
#    return {ip: (u.get("user") or u.get("label") or ip) for ip, u in users.items()}
#
#
## ------------------------------------------------------------------ main
#def main(argv):
#    try:
#        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
#    except Exception:
#        pass
#    if hasattr(signal, "SIGPIPE"):
#        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
#    usage = __doc__.split("\n\n")[1]
#    if argv and argv[0] in ("-h", "--help"):
#        print(usage)
#        return 0
#    if len(argv) > 1 or (argv and argv[0].startswith("-")):
#        print(usage, file=sys.stderr)
#        return 2
#    if os.geteuid() != 0:
#        print("run as root:  sudo smartdns-watch", file=sys.stderr)
#        return 1
#    if not os.path.exists(SYNC_ENV):
#        print("this is not a relay - run it where the customers' DNS is answered",
#              file=sys.stderr)
#        return 1
#
#    users, allowed = load_users()
#    who = display(users)
#    targets = None
#    if argv:
#        targets = resolve(argv[0], users)
#        if not targets:
#            print("no customer or address matches %r - the registered ones:  "
#                  "sudo smartdns-acl list" % argv[0], file=sys.stderr)
#            return 1
#
#    try:
#        sock = socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM,
#                             socket.htons(ETH_P_ALL))
#        attach_filter(sock)
#    except (OSError, AttributeError) as e:
#        print("cannot watch the network here: %s" % e, file=sys.stderr)
#        return 1
#
#    if targets:
#        print("watching %s - ctrl-c to stop" % ", ".join(
#            "%s (%s)" % (ip, who.get(ip, "not registered")) for ip in sorted(targets)))
#    else:
#        print("watching everybody - ctrl-c to stop")
#    print("  via relay = already goes through the exit   direct = goes around it"
#          "   filtered = blocked inside Iran\n", flush=True)
#    for ip in sorted(targets or ()):
#        if ip not in allowed:
#            print("  note: %s is not allowed on this relay, so its questions are "
#                  "dropped - they will show as 'no answer'\n" % ip, flush=True)
#
#    # timeout(1) and systemd stop with SIGTERM; end the same way ctrl-c does.
#    def stop(*_):
#        raise KeyboardInterrupt
#    signal.signal(signal.SIGTERM, stop)
#
#    w = Watcher(local_addresses(), who, targets)
#    sock.settimeout(0.5)
#    try:
#        while True:
#            try:
#                w.feed(sock.recv(65535))
#            except socket.timeout:
#                pass
#            w.tick()
#    except KeyboardInterrupt:
#        print("\n" + w.summary())
#    return 0
#
#
#if __name__ == "__main__":
#    sys.exit(main(sys.argv[1:]))
#__END_SMARTDNS_WATCH__

#__BEGIN_TUNNEL_SERVICE__
#[Unit]
#Description=doctor dns tunnel between the relay and the exit (BackPack)
#After=network-online.target
#Wants=network-online.target
#
#[Service]
## BackPack keeps one tunnel running from this file, and redials on its own when
## the other end goes away. Its menu, web panel and kernel tuning stay off: the
## file says so, and this machine's tuning is the installer's to decide.
## The listening end's firewall rule - its port answers the other machine only.
## Loaded here as well as at boot, since an exit's nftables service does not
## read /etc/nftables.d; the leading - makes a missing file (the dialling end)
## no failure.
#ExecStartPre=-/usr/sbin/nft -f /etc/nftables.d/40-smartdns-tunnel.conf
#ExecStart=/usr/local/lib/smart-dns/backpack -c /etc/smart-dns/tunnel/tunnel.toml
#Restart=always
#RestartSec=5
## Every customer connection is a stream in the tunnel, and a console download
## opens dozens at once.
#LimitNOFILE=65535
#
#[Install]
#WantedBy=multi-user.target
#__END_TUNNEL_SERVICE__

#__BEGIN_SMARTDNS_TUNNEL__
##!/bin/bash
## smartdns-tunnel - the tunnel between the relay and the exit: see it, stop it, start it.
##
## usage: smartdns-tunnel          what it is, and whether it is carrying traffic
##        smartdns-tunnel off      back to plain TCP, now
##        smartdns-tunnel on       start it again, with the settings it had
##
## Either end will do for off: the relay's nginx goes straight to the exit the
## moment its end of the tunnel stops answering, whichever machine stopped it.
## To change the transport, the port or which end dials, run the installer with
## --tunnel on the exit and then on the relay.
##
## The tunnel itself is BackPack, the work of Amin Mohammadi:
## github.com/AminMGMT/BackPack (AGPL-3.0).
#set -uo pipefail
#
## Where this machine's config lives. A variable only so a test can point it
## somewhere else; nothing else sets it.
#ETC="${SMARTDNS_ETC:-/etc/smart-dns}"
#UNIT=smartdns-tunnel.service
#LOCAL_HTTPS=18443
#
#case "${1:-status}" in
#    status|off|on) ;;
#    -h|--help) sed -n '2,/^set /p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
#    *) echo "unknown command: $1  (try -h)" >&2; exit 1 ;;
#esac
#[ "$(id -u)" = 0 ] || { echo "run as root:  sudo smartdns-tunnel" >&2; exit 1; }
#
#if [ -f "$ETC/sync.env" ]; then role=relay; env="$ETC/sync.env"
#elif [ -f "$ETC/panel.env" ]; then role=exit; env="$ETC/panel.env"
#else echo "doctor dns is not installed on this machine" >&2; exit 1; fi
#
#get() { sed -n "s/^$1=//p" "$env" 2>/dev/null | head -1; }
#set_key() {
#    local tmp; tmp="$(mktemp)"
#    grep -v "^$1=" "$env" > "$tmp" 2>/dev/null || true
#    printf '%s=%s\n' "$1" "$2" >> "$tmp"
#    cat "$tmp" > "$env"; rm -f "$tmp"
#}
## Set up by the installer, whether on or off at the moment.
#configured() { [ -f "$ETC/tunnel/tunnel.toml" ] && [ -n "$(get TUNNEL_TRANSPORT)" ]; }
#
#show() {
#    if ! configured; then
#        echo "no tunnel is set up on this $role - the relay reaches the exit directly."
#        echo "to set one up:  sudo bash doctor-dns.sh --tunnel   (on the exit first, then the relay)"
#        return 0
#    fi
#    local port; port="$(get TUNNEL_PORT)"
#    printf 'tunnel     BackPack, %s, %s, port %s\n' "$(get TUNNEL_TRANSPORT)" "$(get TUNNEL_DIRECTION)" "$port"
#    printf 'setting    %s\n' "$([ "$(get TUNNEL)" = backpack ] && echo on || echo off)"
#    printf 'service    %s\n' "$(systemctl is-active $UNIT 2>/dev/null || true)"
#    if [ "$role" = relay ]; then
#        # Straight at the tunnel's own end: through nginx the fallback would
#        # answer too, and say nothing about the tunnel.
#        local code
#        code="$(curl -s -o /dev/null -m 8 --connect-to "github.com:443:127.0.0.1:$LOCAL_HTTPS" \
#                -w '%{http_code}' https://github.com/ 2>/dev/null || true)"
#        if [ "$code" = 200 ]; then
#            echo "traffic    through the tunnel"
#        else
#            echo "traffic    straight to the exit - the tunnel is not carrying anything"
#        fi
#    else
#        printf 'connected  %s tunnel connection(s) with the relay\n' \
#            "$(ss -Htn state established "( sport = :$port or dport = :$port )" 2>/dev/null | wc -l)"
#    fi
#}
#
#case "${1:-status}" in
#status)
#    show ;;
#off)
#    if ! configured; then show; exit 0; fi
#    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
#    # Kept, so an upgrade does not quietly bring it back.
#    set_key TUNNEL off
#    echo "tunnel stopped - traffic goes straight to the exit now."
#    [ "$role" = relay ] && echo "nginx falls back to the direct path by itself; nothing else to do here."
#    echo "the other machine's end keeps trying to reach this one, which does no harm;"
#    echo "stop it there as well with:  sudo smartdns-tunnel off"
#    ;;
#on)
#    if ! configured; then show; exit 1; fi
#    set_key TUNNEL backpack
#    systemctl enable --now "$UNIT" >/dev/null 2>&1 || true
#    sleep 4
#    show
#    echo
#    echo "if it is not carrying traffic yet, the other machine's end may be off:  sudo smartdns-tunnel on"
#    ;;
#esac
#__END_SMARTDNS_TUNNEL__

#__BEGIN_SMARTDNS_MENU__
##!/bin/bash
## smartdns-menu - every doctor dns command in one place, for when you do not
## remember the name of the one you want.
##
## usage: sudo smartdns-menu
##
## Each choice shows the command it runs before running it, so the next time you
## can type it yourself. Ctrl-C stops that command and comes back here.
#set -uo pipefail
#
## Where this machine's config lives. Variables only so a test can point them
## somewhere else; nothing else sets them.
#ETC="${SMARTDNS_ETC:-/etc/smart-dns}"
#VERSION_FILE="${SMARTDNS_VERSION_FILE:-/var/lib/smart-dns/version}"
#REPO="https://github.com/mehdi047/doctor-dns"
#
#B=$'\e[1m'; D=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
#[ -t 1 ] || { B=; D=; G=; Y=; N=; }
#
#case "${1:-}" in
#    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
#    "") ;;
#    *) echo "unknown option: $1  (try -h)" >&2; exit 1 ;;
#esac
#[ "$(id -u)" = 0 ] || { echo "run as root:  sudo smartdns-menu" >&2; exit 1; }
#if [ -f "$ETC/sync.env" ]; then role=relay
#elif [ -f "$ETC/panel.env" ]; then role=exit
#else echo "doctor dns is not installed on this machine" >&2; exit 1; fi
#VERSION="$(cat "$VERSION_FILE" 2>/dev/null || echo '?')"
#
## ------------------------------------------------------------------ helpers
#pause() { printf '\n%spress enter to go back%s ' "$D" "$N"; read -r _ || exit 0; }
#
## Show a command, then run it. Ctrl-C ends the command, not the menu.
#run() {
#    printf '\n%s$ %s%s\n\n' "$G" "$*" "$N"
#    trap ':' INT
#    "$@"
#    trap - INT
#    pause
#}
#
## Ask for one value into REPLY. An empty answer means go back.
#ask() { printf '  %s: ' "$1"; read -r REPLY || exit 0; [ -n "$REPLY" ]; }
#
#sure() {
#    local a
#    printf '  %s%s%s [y/N]: ' "$Y" "$1" "$N"; read -r a || exit 0
#    case "$a" in y|Y|yes) return 0 ;; esac
#    return 1
#}
#
## A menu: a title, then "label|action" items. The action is evaluated when
## chosen; what the user typed reaches commands as "$REPLY", quoted, and is
## never evaluated itself.
#choose() {
#    local title="$1" c i item back="${BACK:-back}"; shift
#    # The label is this menu's alone: the menus opened from here go back.
#    BACK=back
#    while :; do
#        printf '\n%s%s%s\n\n' "$B" "$title" "$N"
#        i=0
#        for item in "$@"; do
#            i=$((i + 1))
#            printf '  %2d) %s\n' "$i" "${item%%|*}"
#        done
#        printf '   0) %s\n\n' "$back"
#        printf 'choice: '; read -r c || exit 0
#        case "$c" in 0|q) return 0 ;; ""|*[!0-9]*) continue ;; esac
#        [ "$c" -le "$i" ] || continue
#        item="${!c}"
#        eval "${item#*|}"
#    done
#}
#
## ------------------------------------------------------------------ actions
#watch_customer() {
#    printf '  username, label (u12) or address - enter for everybody: '
#    read -r REPLY || exit 0
#    if [ -n "$REPLY" ]; then run smartdns-watch "$REPLY"; else run smartdns-watch; fi
#}
#
#add_address() {
#    local ip
#    ask "address" || return 0; ip="$REPLY"
#    printf '  a name for it (optional): '; read -r REPLY || exit 0
#    if [ -n "$REPLY" ]; then run smartdns-acl add "$ip" "$REPLY"; else run smartdns-acl add "$ip"; fi
#}
#
#reset_counters() {
#    printf '  address, or --all for everyone: '; read -r REPLY || exit 0
#    [ -n "$REPLY" ] || return 0
#    sure "zero the usage of $REPLY?" && run smartdns-acl reset "$REPLY"
#}
#
## The installer of the version this machine runs: a copy already here, or the
## release of that version from GitHub. The same version, so changing a setting
## never upgrades anything along the way.
#installer() {
#    local f
#    for f in /root/doctor-dns.sh "${SUDO_USER:+/home/$SUDO_USER/doctor-dns.sh}" ./doctor-dns.sh; do
#        if [ -n "$f" ] && [ -f "$f" ] && [ "$(bash "$f" --version 2>/dev/null)" = "$VERSION" ]; then
#            run bash "$f" "$@"; return 0
#        fi
#    done
#    echo "  there is no copy of the installer for $VERSION on this machine."
#    sure "download it from GitHub (v$VERSION) and run it?" || return 0
#    f="$(mktemp)"
#    if ! curl -fsSL -m 120 -o "$f" "$REPO/releases/download/v$VERSION/doctor-dns.sh"; then
#        echo "  the download failed - fetch doctor-dns.sh v$VERSION yourself and run it with $*"
#        rm -f "$f"; pause; return 0
#    fi
#    run bash "$f" "$@"
#    rm -f "$f"
#}
#
#update() {
#    local f latest
#    f="$(mktemp)"
#    printf '\n  fetching the latest installer...\n'
#    if ! curl -fsSL -m 120 -o "$f" "https://raw.githubusercontent.com/mehdi047/doctor-dns/main/doctor-dns.sh"; then
#        echo "  the download failed"; rm -f "$f"; pause; return 0
#    fi
#    latest="$(bash "$f" --version 2>/dev/null || echo '?')"
#    printf '  installed: %s    latest: %s\n' "$VERSION" "$latest"
#    if [ "$latest" = "$VERSION" ]; then
#        sure "the same version - run it anyway, to check and repair?" || { rm -f "$f"; return 0; }
#    else
#        sure "upgrade this $role to $latest?" || { rm -f "$f"; return 0; }
#    fi
#    cp "$f" /root/doctor-dns.sh 2>/dev/null || true
#    run bash "$f"
#    rm -f "$f"
#}
#
#uninstall() {
#    local a
#    printf '  %sThis removes doctor dns from this machine.%s type uninstall to go ahead: ' "$Y" "$N"
#    read -r a || exit 0
#    [ "$a" = uninstall ] && installer --uninstall
#}
#
## ------------------------------------------------------------------ menus
#menu_logs() {
#    local items=(
#        'each part: running or not, and its recent logs   (smartdns-logs)|run smartdns-logs'
#        'only warnings and errors   (smartdns-logs -e)|run smartdns-logs -e'
#        'follow the logs live, ctrl-c to stop   (smartdns-logs -f)|run smartdns-logs -f'
#        'more lines per part   (smartdns-logs -n)|ask "lines per part" && run smartdns-logs -n "$REPLY"'
#        'one file to send, secrets masked   (smartdns-logs --report)|run smartdns-logs --report'
#    )
#    [ "$role" = relay ] && items+=(
#        'what this relay is doing   (smartdns status)|run smartdns status'
#        'the names a customer asks for, live   (smartdns-watch)|watch_customer'
#    )
#    choose "Status and logs" "${items[@]}"
#}
#
#menu_domains() {
#    choose "Domains" \
#        'every routed domain   (smartdns list)|run smartdns list' \
#        'routed domains matching a word   (smartdns find)|ask "word" && run smartdns find "$REPLY"' \
#        'route a domain through the exit   (smartdns add)|ask "domain" && run smartdns add "$REPLY"' \
#        'stop routing a domain   (smartdns del)|ask "domain" && run smartdns del "$REPLY"' \
#        'never route a domain, even under a routed one   (smartdns bypass)|ask "domain" && run smartdns bypass "$REPLY"' \
#        'undo a bypass   (smartdns unbypass)|ask "domain" && run smartdns unbypass "$REPLY"' \
#        'what this relay answers for a domain   (smartdns test)|ask "domain" && run smartdns test "$REPLY"' \
#        'what every template does with a domain   (smartdns-rules check)|ask "domain" && run smartdns-rules check "$REPLY"' \
#        'every template: its port, customers and rules   (smartdns-rules)|run smartdns-rules' \
#        'one template'"'"'s full lists   (smartdns-rules show)|ask "template name" && run smartdns-rules show "$REPLY"'
#}
#
#menu_customers() {
#    choose "Customers and access" \
#        'everyone, with usage   (smartdns-acl list)|run smartdns-acl list' \
#        'one address   (smartdns-acl usage)|ask "address" && run smartdns-acl usage "$REPLY"' \
#        'register an address by hand   (smartdns-acl add)|add_address' \
#        'remove an address   (smartdns-acl del)|ask "address" && sure "remove $REPLY?" && run smartdns-acl del "$REPLY"' \
#        'zero the usage counters   (smartdns-acl reset)|reset_counters' \
#        'closed to strangers, or open?   (smartdns-acl enforce status)|run smartdns-acl enforce status' \
#        'close it: registered addresses only   (smartdns-acl enforce on)|sure "only registered addresses will get through - go ahead?" && run smartdns-acl enforce on' \
#        'open it to everyone   (smartdns-acl enforce off)|sure "anyone who finds this relay could use it - go ahead?" && run smartdns-acl enforce off' \
#        'save the allowlist to disk now   (smartdns-acl save)|run smartdns-acl save' \
#        'speed limits in force   (smartdns-shape list)|run smartdns-shape list' \
#        'remove every speed limit   (smartdns-shape off)|sure "every customer goes unlimited until the next sync - go ahead?" && run smartdns-shape off'
#}
#
#menu_admin() {
#    choose "Admin panel" \
#        'its address - forgot it? start here   (smartdns-access)|run smartdns-access' \
#        'move it to another port   (smartdns-access port)|ask "new port" && run smartdns-access port "$REPLY"' \
#        'a new secret path   (smartdns-access path)|sure "the old address stops working - go ahead?" && run smartdns-access path' \
#        'a new password   (smartdns-access password)|run smartdns-access password' \
#        'new path and new password at once   (smartdns-access rotate)|sure "the old address and password stop working - go ahead?" && run smartdns-access rotate'
#}
#
#menu_tunnel() {
#    choose "Tunnel between the relay and the exit" \
#        'is it on, and carrying traffic?   (smartdns-tunnel)|run smartdns-tunnel' \
#        'turn it off - plain TCP from now on   (smartdns-tunnel off)|sure "traffic goes straight to the exit from now on - go ahead?" && run smartdns-tunnel off' \
#        'turn it back on   (smartdns-tunnel on)|run smartdns-tunnel on' \
#        'change it: transport, port, which end dials   (doctor-dns.sh --tunnel)|installer --tunnel'
#}
#
#menu_install() {
#    choose "Installation" \
#        "the version installed here: $VERSION   (doctor-dns.sh --version)|printf '\n  %s\n' \"\$VERSION\"; pause" \
#        'update to the latest version|update' \
#        'get or renew a certificate   (smartdns-cert)|ask "domain" && run smartdns-cert "$REPLY"' \
#        'remove doctor dns from this machine   (doctor-dns.sh --uninstall)|uninstall'
#}
#
#restart_all() {
#    if [ "$role" = relay ]; then
#        sure "customers' open connections drop for a moment - go ahead?" || return 0
#    fi
#    run smartdns-restart
#}
#
#main() {
#    local items
#    if [ "$role" = relay ]; then
#        items=(
#            'status and logs|menu_logs'
#            'domains|menu_domains'
#            'customers and access|menu_customers'
#            'tunnel to the exit|menu_tunnel'
#            'restart everything   (smartdns-restart)|restart_all'
#            'installation, updates and certificates|menu_install'
#        )
#    else
#        items=(
#            'status and logs|menu_logs'
#            'admin panel|menu_admin'
#            'tunnel to the relay|menu_tunnel'
#            'restart everything   (smartdns-restart)|restart_all'
#            'installation, updates and certificates|menu_install'
#        )
#    fi
#    BACK=quit choose "doctor dns $VERSION - $role" "${items[@]}"
#}
#
#main
#__END_SMARTDNS_MENU__

#__BEGIN_SMARTDNS_API_GUARD__
##!/bin/bash
## smartdns-api-guard - let only the relays reach this exit's sync API (8443).
##
## usage: smartdns-api-guard           load the rule
##        smartdns-api-guard --print   show the rule, and load nothing
##
## The panel already refuses any address that is not one of its relays, but only
## after the TLS handshake: a stranger still gets that far, and enough strangers
## holding connections open can wear the API down. Dropped here, they never get
## a connection at all.
##
## smartdns-panel.service runs this before every start, so the list is always
## the RELAY_IP the panel itself reads: a relay added there by hand is let in
## the next time the panel restarts, as it would be by the panel.
#set -u
#
## Variables only so a test can point them somewhere else; nothing else sets them.
#ETC="${SMARTDNS_ETC:-/etc/smart-dns}"
#NFT="${SMARTDNS_NFT:-/usr/sbin/nft}"
#
#valid_ip() {
#    local IFS=. p
#    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
#    for p in $1; do [ "$p" -le 255 ] || return 1; done
#}
#
#list="127.0.0.1"
#for ip in $(sed -n 's/^RELAY_IP=//p' "$ETC/panel.env" 2>/dev/null | head -1 | tr ',' ' '); do
#    if valid_ip "$ip"; then list="$list, $ip"
#    else echo "ignoring '$ip' in RELAY_IP - not an IPv4 address" >&2; fi
#done
#[ "$list" = "127.0.0.1" ] && echo "no relays in RELAY_IP - only this machine will reach 8443" >&2
#
#rules="table inet smartdns_api
#delete table inet smartdns_api
#table inet smartdns_api {
#    chain input {
#        type filter hook input priority -5 ; policy accept ;
#        tcp dport 8443 ip saddr { $list } accept
#        tcp dport 8443 drop
#    }
#}"
#
#case "${1:-}" in
#    --print) printf '%s\n' "$rules"; exit 0 ;;
#    -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
#    "") ;;
#    *) echo "unknown option: $1  (try -h)" >&2; exit 1 ;;
#esac
#
#[ -x "$NFT" ] || NFT="$(command -v nft || true)"
#if [ -z "$NFT" ]; then
#    echo "nft is not installed - the sync API stays open, and the panel refuses strangers itself" >&2
#    exit 0
#fi
#if printf '%s\n' "$rules" | "$NFT" -f -; then
#    echo "port 8443 answers: $list"
#else
#    echo "nft refused the rule - the sync API stays open, and the panel refuses strangers itself" >&2
#fi
#exit 0
#__END_SMARTDNS_API_GUARD__

#__BEGIN_EPIC_PIN__
##!/usr/bin/env python3
#"""Pin Epic's backend names to the addresses that are actually reachable here.
#
#Epic's game backend must NOT be routed through the exit: matchmaking has to come
#from the same address the console later plays from, or the game server ignores
#the gameplay packets. See docs/fortnite-udp.md.
#
#But letting it resolve normally has its own failure. Epic round-robins each name
#across many addresses and a few are unreachable from Iran - one in thirty-three
#when sampled. A console that draws a dead one stalls on that service, which is
#why Fortnite worked on some attempts and not others.
#
#So pin each name to addresses verified reachable. Those address= entries are more
#specific than the server= bypass rule, so dnsmasq prefers them.
#
#The important part is knowing when NOT to act. Epic's address sets rotate
#constantly, so the first version of this rewrote the file on nearly every run -
#and since dnsmasq cannot re-read its config without a restart, that meant
#restarting the resolver every ten minutes, all day. Each restart is a brief DNS
#outage and a full cache flush, which is its own source of exactly the
#intermittent breakage this script exists to prevent. It made a day of test
#results untrustworthy.
#
#So: probe only the addresses already pinned. If they all still answer, do nothing
#at all. Re-resolve and rewrite only when a pinned address has actually died, or
#when there are no pins yet. In the steady state this touches nothing.
#"""
#import concurrent.futures as cf
#import os
#import socket
#import subprocess
#import sys
#
#CONF = "/etc/dnsmasq.d/epic-pins.conf"
#RESOLVERS = ("1.1.1.1", "8.8.8.8")
#PROBE_PORT = 443
#PROBE_TIMEOUT = 2.5
#
#HOSTS = [
#    "account-public-service-prod.ol.epicgames.com",
#    "datarouter.ol.epicgames.com",
#    "launcher-public-service-prod06.ol.epicgames.com",
#    "links-public-service-live.ol.epicgames.com",
#    "events-public-service-live.ol.epicgames.com",
#    "datastorage-public-service-live.ol.epicgames.com",
#    "data-asset-directory-public-service-prod.ol.epicgames.com",
#    "fortnitecontent-website-prod07.ol.epicgames.com",
#    "fortnite-public-service-prod11.ol.epicgames.com",
#    "mcp-gc.live.fngw.ol.epicgames.com",
#    "gc.svc.live.fngw.ol.epicgames.com",
#    "ds.svc.live.fngw.ol.epicgames.com",
#    "fngw-svc-ds-livefn.ol.epicgames.com",
#    "fn-service-habanero-live-public.ogs.live.on.epicgames.com",
#    "fn-service-discovery-live-public.ogs.live.on.epicgames.com",
#    "prm-dialogue-public-api-prod.edea.live.use1a.on.epicgames.com",
#]
#
#
#def resolve(host):
#    for r in RESOLVERS:
#        try:
#            out = subprocess.run(
#                ["dig", "+short", "+time=3", "+tries=1", "@" + r, host, "A"],
#                capture_output=True, text=True, timeout=8).stdout
#        except Exception:
#            continue
#        ips = [l.strip() for l in out.splitlines()
#               if l.strip() and l.strip()[0].isdigit() and l.count(".") == 3]
#        if ips:
#            return ips
#    return []
#
#
#def alive(ip):
#    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
#    s.settimeout(PROBE_TIMEOUT)
#    try:
#        s.connect((ip, PROBE_PORT))
#        return True
#    except Exception:
#        return False
#    finally:
#        s.close()
#
#
#def read_pins():
#    """host -> [addresses], from the file we last wrote."""
#    pins = {}
#    if not os.path.exists(CONF):
#        return pins
#    for line in open(CONF):
#        line = line.strip()
#        if not line.startswith("address=/"):
#            continue
#        parts = line.split("/")
#        if len(parts) >= 3:
#            pins.setdefault(parts[1], []).append(parts[2])
#    return pins
#
#
#def main():
#    pins = read_pins()
#
#    # Steady state: everything already pinned still answers, so leave the
#    # resolver alone. Restarting it to write a file that differs only by Epic's
#    # rotation is how this script used to cause the problem it prevents.
#    if pins and set(pins) == set(HOSTS):
#        addrs = sorted({a for v in pins.values() for a in v})
#        with cf.ThreadPoolExecutor(max_workers=16) as ex:
#            health = dict(zip(addrs, ex.map(alive, addrs)))
#        dead = [a for a in addrs if not health[a]]
#        if not dead:
#            print("epic-pin: all %d pinned addresses still healthy, nothing to do"
#                  % len(addrs))
#            return 0
#        print("epic-pin: %d pinned address(es) died (%s), refreshing"
#              % (len(dead), ", ".join(dead[:4])))
#
#    lines = ["# generated by epic-pin - do not edit, changes are overwritten",
#             "# only addresses that answered on tcp/%d from this host" % PROBE_PORT,
#             ""]
#    total = good = 0
#    with cf.ThreadPoolExecutor(max_workers=16) as ex:
#        resolved = dict(zip(HOSTS, ex.map(resolve, HOSTS)))
#        every = sorted({ip for ips in resolved.values() for ip in ips})
#        health = dict(zip(every, ex.map(alive, every)))
#
#    for host in HOSTS:
#        ips = [ip for ip in resolved.get(host, []) if health.get(ip)]
#        total += len(resolved.get(host, []))
#        good += len(ips)
#        if not ips:
#            # Nothing verified: say nothing and let the bypass resolve it live.
#            # A wrong pin is worse than no pin.
#            continue
#        for ip in ips:
#            lines.append("address=/%s/%s" % (host, ip))
#
#    with open(CONF, "w") as fh:
#        fh.write("\n".join(lines) + "\n")
#
#    check = subprocess.run(["dnsmasq", "--test", "-C", "/etc/dnsmasq.conf"],
#                           capture_output=True, text=True)
#    if check.returncode != 0:
#        os.remove(CONF)
#        print("epic-pin: dnsmasq rejected the file, removed it\n" + check.stderr,
#              file=sys.stderr)
#        return 1
#
#    # A reload only clears the cache; dnsmasq does not re-read /etc/dnsmasq.d
#    # without a restart. That is why the syntax check above runs first, and why
#    # reaching this line at all should be rare.
#    subprocess.run(["systemctl", "restart", "dnsmasq"], check=False)
#    print("epic-pin: rewrote pins and restarted dnsmasq (%d/%d healthy)"
#          % (good, total))
#    return 0
#
#
#if __name__ == "__main__":
#    sys.exit(main())
#__END_EPIC_PIN__

#__BEGIN_EPIC_PIN_SERVICE__
#[Unit]
#Description=Pin Epic backend names to reachable addresses
#After=network-online.target dnsmasq.service
#Wants=network-online.target
#
#[Service]
#Type=oneshot
#ExecStart=/usr/local/bin/epic-pin
#TimeoutStartSec=120
#__END_EPIC_PIN_SERVICE__

#__BEGIN_EPIC_PIN_TIMER__
#[Unit]
#Description=Refresh Epic backend address pins
#
#[Timer]
## Epic's address sets rotate, and a pin that has gone stale is worse than none,
## so refresh often and start shortly after boot rather than waiting a full cycle.
#OnBootSec=2min
#OnUnitActiveSec=10min
#AccuracySec=30s
#
#[Install]
#WantedBy=timers.target
#__END_EPIC_PIN_TIMER__

#__BEGIN_OPERATORS__
##!/usr/bin/env python3
#"""smartdns-operators - which Iranian operator each customer address is on.
#
#The admin panel shows it under every address, so "it does not work on
#Irancell" can be checked against who is actually on Irancell. The answer comes
#from the routing registry: every operator announces its address blocks under
#its own AS number, and RIPE publishes who announces what. This fetches that
#list for the operators customers actually connect from, once a day, into one
#file the panel reads.
#
#Nothing about a customer leaves the server. What is fetched is the operators'
#own public address lists; the matching happens in the panel. An operator whose
#list could not be fetched keeps yesterday's, so a RIPE outage leaves the panel
#as it was rather than blank.
#"""
#import ipaddress
#import json
#import os
#import sys
#import tempfile
#import time
#import urllib.request
#from datetime import datetime, timezone
#
#OUT = "/var/lib/smart-dns/operators.json"
#URL = ("https://stat.ripe.net/data/announced-prefixes/data.json"
#       "?resource=AS%d&sourceapp=doctor-dns")
#
## AS number and the name the operator is known by here. Each was checked
## against RIPE's own holder name, which is the comment beside it.
#OPERATORS = [
#    (197207, "همراه اول"),       # MCCI - Mobile Communication Company of Iran
#    (44244, "ایرانسل"),          # IranCell - Iran Cell Service and Communication
#    (57218, "رایتل"),            # RighTel - Rightel Communication Service
#    (58224, "مخابرات"),          # TCI - Iran Telecommunication Company
#    (31549, "شاتل"),             # RASANA - Aria Shatel
#    (43754, "آسیاتک"),           # ASIATECH - Asiatech Data Transmission
#    (16322, "پارس‌آنلاین"),      # PARSONLINE - Parsan Lin
#    (50810, "مبین‌نت"),          # Mobinnet - Mobin Net Communication
#    (56402, "های‌وب"),           # DADEHGOSTAR - Dadeh Gostar Asr Novin (HiWEB)
#    (25184, "افرانت"),           # AFRANET
#    (42337, "رسپینا"),           # RESPINA - Respina Networks & Beyond
#    (49100, "پیشگامان"),         # IR-THR-PTE - Pishgaman Toseeh Ertebatat
#    (39501, "صبانت"),            # NGSAS - Neda Gostar Saba
#    (24631, "فناپ تلکام"),       # FANAPTELECOM - Fanavari Ertebabat Pasargad Arian
#]
#
#
#def now():
#    return datetime.now(timezone.utc).isoformat(timespec="seconds")
#
#
#def fetch(asn):
#    """The address blocks one AS announces, as strings. Raises on failure."""
#    req = urllib.request.Request(URL % asn,
#                                 headers={"User-Agent": "doctor-dns"})
#    with urllib.request.urlopen(req, timeout=30) as r:
#        data = json.load(r)
#    if data.get("status") != "ok":
#        raise ValueError("RIPE answered %r" % data.get("status"))
#    out = []
#    for item in data["data"]["prefixes"]:
#        try:
#            out.append(str(ipaddress.ip_network(item["prefix"], strict=False)))
#        except (KeyError, TypeError, ValueError):
#            continue
#    if not out:
#        # An operator that announces nothing is a broken answer, not an
#        # operator that has left - keeping yesterday's list is the safer read.
#        raise ValueError("no prefixes")
#    return sorted(set(out))
#
#
#def load(path):
#    try:
#        with open(path, encoding="utf-8") as fh:
#            return json.load(fh).get("operators", {})
#    except (OSError, ValueError, AttributeError):
#        return {}
#
#
#def save(path, operators):
#    folder = os.path.dirname(path)
#    os.makedirs(folder, exist_ok=True)
#    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".operators.")
#    try:
#        with os.fdopen(fd, "w", encoding="utf-8") as fh:
#            json.dump({"updated": now(), "operators": operators}, fh,
#                      ensure_ascii=False, sort_keys=True)
#        os.chmod(tmp, 0o644)
#        os.replace(tmp, path)
#    except BaseException:
#        os.unlink(tmp)
#        raise
#
#
#def refresh(path=OUT, pause=0.5):
#    old = load(path)
#    new, failed = {}, []
#    for i, (asn, name) in enumerate(OPERATORS):
#        if i and pause:
#            time.sleep(pause)            # RIPE asks callers to go gently
#        key = str(asn)
#        # Three tries: one dropped connection should not cost an operator a
#        # day, and on the first day there is no yesterday's list to fall on.
#        for attempt in range(3):
#            try:
#                new[key] = {"name": name, "prefixes": fetch(asn), "fetched": now()}
#                break
#            except Exception as e:
#                err = e
#                if pause and attempt < 2:
#                    time.sleep(pause * 4)
#        else:
#            failed.append("AS%d %s: %s" % (asn, name, err))
#            if key in old:
#                new[key] = dict(old[key], name=name)
#    for line in failed:
#        print("could not fetch %s - keeping the last list" % line)
#    if len(failed) == len(OPERATORS):
#        print("nothing could be fetched; %s left as it was" % path)
#        return 1
#    save(path, new)
#    print("%d operators, %d address blocks"
#          % (len(new), sum(len(v["prefixes"]) for v in new.values())))
#    return 0
#
#
#if __name__ == "__main__":
#    # The names are Persian. A console that cannot show them gets a
#    # placeholder, not a traceback in place of the day's list.
#    try:
#        sys.stdout.reconfigure(errors="replace")
#    except Exception:
#        pass
#    sys.exit(refresh())
#__END_OPERATORS__

#__BEGIN_OPERATORS_SERVICE__
#[Unit]
#Description=Fetch Iranian operators' address blocks for the admin panel
#After=network-online.target
#Wants=network-online.target
#
#[Service]
#Type=oneshot
#ExecStart=/usr/local/bin/smartdns-operators
#TimeoutStartSec=300
#__END_OPERATORS_SERVICE__

#__BEGIN_OPERATORS_TIMER__
#[Unit]
#Description=Refresh which operator each customer address is on
#
#[Timer]
## Operators' address blocks change slowly, so once a day is plenty. Spread out,
## so exits installed together do not all ask RIPE in the same minute.
#OnBootSec=10min
#OnUnitActiveSec=1d
#RandomizedDelaySec=1h
#
#[Install]
#WantedBy=timers.target
#__END_OPERATORS_TIMER__

#__BEGIN_FONT_LICENSE__
#Copyright 2015 The Vazirmatn Project Authors (https://github.com/rastikerdar/vazirmatn)
#
#This Font Software is licensed under the SIL Open Font License, Version 1.1.
#This license is copied below, and is also available with a FAQ at:
#http://scripts.sil.org/OFL
#
#
#-----------------------------------------------------------
#SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
#-----------------------------------------------------------
#
#PREAMBLE
#The goals of the Open Font License (OFL) are to stimulate worldwide
#development of collaborative font projects, to support the font creation
#efforts of academic and linguistic communities, and to provide a free and
#open framework in which fonts may be shared and improved in partnership
#with others.
#
#The OFL allows the licensed fonts to be used, studied, modified and
#redistributed freely as long as they are not sold by themselves. The
#fonts, including any derivative works, can be bundled, embedded, 
#redistributed and/or sold with any software provided that any reserved
#names are not used by derivative works. The fonts and derivatives,
#however, cannot be released under any other type of license. The
#requirement for fonts to remain under this license does not apply
#to any document created using the fonts or their derivatives.
#
#DEFINITIONS
#"Font Software" refers to the set of files released by the Copyright
#Holder(s) under this license and clearly marked as such. This may
#include source files, build scripts and documentation.
#
#"Reserved Font Name" refers to any names specified as such after the
#copyright statement(s).
#
#"Original Version" refers to the collection of Font Software components as
#distributed by the Copyright Holder(s).
#
#"Modified Version" refers to any derivative made by adding to, deleting,
#or substituting -- in part or in whole -- any of the components of the
#Original Version, by changing formats or by porting the Font Software to a
#new environment.
#
#"Author" refers to any designer, engineer, programmer, technical
#writer or other person who contributed to the Font Software.
#
#PERMISSION & CONDITIONS
#Permission is hereby granted, free of charge, to any person obtaining
#a copy of the Font Software, to use, study, copy, merge, embed, modify,
#redistribute, and sell modified and unmodified copies of the Font
#Software, subject to the following conditions:
#
#1) Neither the Font Software nor any of its individual components,
#in Original or Modified Versions, may be sold by itself.
#
#2) Original or Modified Versions of the Font Software may be bundled,
#redistributed and/or sold with any software, provided that each copy
#contains the above copyright notice and this license. These can be
#included either as stand-alone text files, human-readable headers or
#in the appropriate machine-readable metadata fields within text or
#binary files as long as those fields can be easily viewed by the user.
#
#3) No Modified Version of the Font Software may use the Reserved Font
#Name(s) unless explicit written permission is granted by the corresponding
#Copyright Holder. This restriction only applies to the primary font name as
#presented to the users.
#
#4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
#Software shall not be used to promote, endorse or advertise any
#Modified Version, except to acknowledge the contribution(s) of the
#Copyright Holder(s) and the Author(s) or with their explicit written
#permission.
#
#5) The Font Software, modified or unmodified, in part or in whole,
#must be distributed entirely under this license, and must not be
#distributed under any other license. The requirement for fonts to
#remain under this license does not apply to any document created
#using the Font Software.
#
#TERMINATION
#This license becomes null and void if any of the above conditions are
#not met.
#
#DISCLAIMER
#THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
#MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
#OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
#COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
#INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
#DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
#FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
#OTHER DEALINGS IN THE FONT SOFTWARE.
#__END_FONT_LICENSE__

#__BEGIN_DOMAINS__
#3docean.net
#accounts.google.com
#acm.org
#activision.com
#adobe.com
#adobelogin.com
#ads.google.com
#adservice.google.com
#ai.google
#aistudio.google.com
#aka.ms
#algolia.com
#algolia.net
#altera.com
#amd.com
#amp.dev
#analytics.google.com
#android.com
#ant.design
#anthropic.com
#anydesk.com
#apache.org
#apexlegends.com
#apis.google.com
#appengine.google.com
#apple.com
#apps.admob.com
#appspot.com
#arcgis.com
#archive.ubuntu.com
#arduino.cc
#arxiv.org
#asana.com
#atlassian.com
#atlassian.net
#aws.amazon.com
#b4x.com
#baeldung.com
#battle.net
#battlecode.org
#battlefield.com
#beans.org
#bethesda.net
#bintray.com
#bioware.com
#bit.dev
#bitbucket.org
#bitsrc.io
#bitvise.com
#blizzard.com
#bluemix.net
#books.google.com
#bootstrapcdn.com
#bootswatch.com
#branch.io
#bugsnag.com
#bun.sh
#business.google.com
#c9.io
#caddy.com
#caddyserver.com
#callofduty.com
#canva.com
#centos.org
#chatgpt.com
#chocolatey.org
#cisco.com
#clamav.net
#classroom.google.com
#claude.ai
#clients.google.com
#clients2.google.com
#clients6.google.com
#cljdoc.org
#cloud.google.com
#cloudera.com
#cloudflare.com
#cloudfront.net
#cocalc.com
#code.google.com
#code.visualstudio.com
#codecanyon.net
#codecov.io
#codeium.com
#codesandbox.io
#codex.cs.yale.edu
#coinbase.com
#colab.research.google.com
#count.ly
#coursehero.com
#coursera-apps.org
#coursera.com
#coursera.org
#cp.maxcdn.com
#crashlytics.com
#crates.io
#criteriongames.com
#csb.app
#curd.io
#cursor.com
#cursor.sh
#dartlang.org
#datacamp.com
#deepmind.google
#deepseek.com
#dell.com
#demandbase.com
#deno.land
#design.google.com
#developer.chrome.com
#developer.google.com
#developer.samsung.com
#developers.google.com
#dice.se
#digikey.com
#digitalocean.com
#discord.com
#discord.gg
#discordapp.com
#discordapp.net
#dl-ssl.google.com
#dl.google.com
#dns.google.com
#docker.com
#docker.io
#docs.datastax.com
#domains.google.com
#dotnet.microsoft.com
#doubleclick.net
#doubleclickbygoogle.com
#download.01.org
#download.virtualbox.org
#ea.com
#eaaccess.com
#eaassets-a.akamaihd.net
#eacdn.com
#eamobile.com
#eaplay.com
#easports.com
#edgesuite.net
#edx.org
#elastic.co
#element14.com
#en25.com
#enterprisedb.com
#envato-static.com
#envato.com
#epicgames.com
#es.io
#eslint.org
#espressif.com
#events.google.com
#explainshell.com
#expo.io
#expressjs.com
#fabric.io
#faceit.com
#fbsbx.com
#fcmobile.com
#fiber.google.com
#figma.com
#firebase.com
#firebase.google.com
#flurry.com
#flutter.dev
#flutter.io
#fluttercrashcourse.com
#flutterlearn.com
#fly.io
#fodev.org
#forums.cpanel.net
#freecodecamp.org
#frostbite.com
#fsdn.com
#gallery.io
#gallerycdn.vsassets.io
#gamepass.com
#garena.com
#gcr.io
#geforce.com
#gemini.google.com
#getbootstrap.com
#getcaddy.com
#ggpht.com
#ghcr.io
#github.com
#githubapp.com
#githubassets.com
#githubusercontent.com
#gitkraken.com
#gitlab-static.net
#gitlab.com
#gitlab.io
#gitpod.io
#go.dev
#goanimate.com
#godbolt.org
#godoc.org
#gog.com
#golang.org
#google-analytics.com
#google.ai
#googleadservices.com
#googleapis.com
#googleblog.com
#googlesource.com
#googletagmanager.com
#googletagservices.com
#googleusercontent.com
#gopkg.in
#grabcad.com
#gradle.org
#grafana.com
#graphicriver.net
#graphql.org
#gravatar.com
#groq.com
#gstatic.com
#gvt1.com
#hackerrank.com
#hashicorp.com
#helm.sh
#heroku.com
#hetzner.com
#hf.co
#hoyoverse.com
#huggingface.co
#humblebundle.com
#hyper.is
#i.stack.imgur.com
#i18next.com
#ibm.com
#ieee.org
#incredibuild.com
#intel.com
#invis.io
#issuetracker.google.com
#itch.io
#jaspersoft.com
#java.com
#javacardos.com
#jenkins-ci.org
#jenkins.org
#jenkov.com
#jetbrains.com
#jfrog.io
#jfrog.org
#jhipster.tech
#jitpack.io
#jitsi.org
#jungle.net
#justpaste.it
#jwplayer.com
#k8s.io
#kaggle.com
#kaggle.net
#kaggleusercontent.com
#khanacademy.org
#krafton.com
#kubernetes.io
#labix.org
#labs.google
#laravel.com
#launchpad.net
#leagueoflegends.com
#learn.microsoft.com
#lenovo.com
#libraries.io
#lightstep.com
#linear.app
#linode.com
#livefyre.com
#maas.io
#mailgun.com
#marketingplantform.google.com
#marketplace.visualstudio.com
#material.io
#mathworks.com
#maven.google.com
#maven.org
#maxis.com
#mbed.com
#medium.com
#metasploit.com
#microchip.com
#mihoyo.com
#minecraft.net
#minecraftservices.com
#miro.com
#mistral.ai
#mit.edu
#mojang.com
#mongodb.com
#mongodb.org
#mp.microsoft.com
#mybridge.co
#myfonts.net
#mysql.com
#nativescript.org
#needforspeed.com
#netflix.com
#netlify.app
#netlify.com
#newrelic.com
#nextjs.org
#nflxext.com
#nflximg.net
#nflxvideo.net
#nginx.com
#ni.com
#nintendo.com
#nintendo.net
#nirsoft.net
#nodejs.org
#notebooklm.google.com
#notion.so
#npmjs.com
#npmjs.org
#nuget.org
#nvidia.com
#oaistatic.com
#oaiusercontent.com
#ollama.com
#openai.com
#openrouter.ai
#optimize.google.com
#optimizely.com
#oracle.com
#origin.com
#overleaf.com
#packagesource.com
#packagist.org
#packtpub.com
#parsely.com
#payments.google.com
#paypal.com
#paypalobjects.com
#perplexity.ai
#photodune.net
#php.net
#piles.overleaf.com
#pkg.go.dev
#play.google.com
#playstation.com
#playstation.net
#pnpm.io
#polymer-project.org
#popcap.com
#postman.com
#proandroiddev.com
#pscdn.co
#pubg.com
#pypi.org
#python.org
#qt.io
#qualcomm.com
#quay.io
#railway.app
#rapid7.com
#raspberrypi.com
#rbxcdn.com
#reactjs.org
#realm.io
#registry.k8s.io
#releases.hashicorp.com
#render.com
#replit.com
#researchgate.net
#respawn.com
#riotgames.com
#roblox.com
#rockstargames.com
#ruby-doc.org
#rubygems.org
#rust-lang.org
#salesforce.com
#scdn.co
#schema.org
#sciencedirect.com
#seleniumhq.org
#sendgrid.com
#sentry.io
#serialport.io
#serverfault.com
#slack-edge.com
#slack.com
#socket.io
#softlayer.com
#softonic.com
#sonarsource.com
#sonatype.org
#sonyentertainmentnetwork.com
#sparkjava.com
#spiceworks.com
#splunk.com
#spotify.com
#spring.io
#springer.com
#sstatic.net
#st.com
#stackexchange.com
#stackoverflow.com
#steamcommunity.com
#steamcontent.com
#steampowered.com
#steamstatic.com
#storage.googleapis.com
#stripe.com
#sun.com
#supabase.com
#supercell.com
#superuser.com
#surveys.google.com
#swaggerhub.com
#swift.org
#swtor.com
#symfony.com
#tagmanager.google.com
#take2games.com
#teamtreehouse.com
#teamviewer.com
#telerik.com
#tensorflow.org
#terraform.io
#themeforest.net
#thesims.com
#ti.com
#tinyjpg.com
#tinypng.com
#together.ai
#toggl.com
#traviscistatus.com
#trello.com
#ttvnw.net
#twitch.tv
#ubi.com
#ubisoft.com
#udemy.com
#udemycdn-a.com
#udemycdn.com
#unity.com
#unity3d.com
#unrealengine.com
#unsplash.com
#upwork.com
#vagrantup.com
#valorant.com
#valvesoftware.com
#vercel.app
#vercel.com
#videohive.net
#virtualbox.org
#visualstudio.microsoft.com
#vmcdn.com
#vmware.com
#vscode-cdn.net
#vscode.dev
#vuejs.org
#vuetifyjs.com
#vuforia.com
#web.dev
#wikia.com
#windsurf.com
#withgoogle.com
#wolframalpha.com
#wpastra.com
#x.ai
#xbox.com
#xboxlive.com
#xilinx.com
#yarnpkg.com
#yarnpkg.org
#zeit.co
#zeplin.io
#zoom.us
#__END_DOMAINS__

#__BEGIN_SERVICES__
#{
#  "services": [
#    {
#      "key": "playstation",
#      "label": "PlayStation",
#      "groups": [
#        {
#          "key": "online",
#          "label": "فروشگاه، اکانت و بازی آنلاین",
#          "domains": [
#            "playstation.com",
#            "playstation.net",
#            "pscdn.co",
#            "sonyentertainmentnetwork.com"
#          ]
#        },
#        {
#          "key": "download",
#          "label": "دانلود بازی",
#          "domains": [
#            "gst.prod.dl.playstation.net",
#            "ps5cel.np.dl.playstation.net",
#            "uef.np.dl.playstation.net",
#            "zeus.dl.playstation.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "xbox",
#      "label": "Xbox",
#      "groups": [
#        {
#          "key": "online",
#          "label": "فروشگاه، اکانت و بازی آنلاین",
#          "domains": [
#            "edgesuite.net",
#            "gamepass.com",
#            "mp.microsoft.com",
#            "xbox.com",
#            "xboxlive.com"
#          ]
#        },
#        {
#          "key": "download",
#          "label": "دانلود بازی",
#          "domains": [
#            "assets1.xboxlive.com",
#            "dl.delivery.mp.microsoft.com",
#            "dlassets.xboxlive.com",
#            "xvcf1.xboxlive.com",
#            "xvcf2.xboxlive.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "nintendo",
#      "label": "Nintendo",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "nintendo.com",
#            "nintendo.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "steam",
#      "label": "Steam",
#      "groups": [
#        {
#          "key": "main",
#          "label": "فروشگاه و انجمن",
#          "domains": [
#            "steamcommunity.com",
#            "steampowered.com",
#            "steamstatic.com",
#            "valvesoftware.com"
#          ]
#        },
#        {
#          "key": "download",
#          "label": "دانلود بازی",
#          "domains": [
#            "steamcontent.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "epic",
#      "label": "Epic Games",
#      "groups": [
#        {
#          "key": "main",
#          "label": "فروشگاه، لانچر و اکانت",
#          "domains": [
#            "epicgames.com",
#            "unrealengine.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "ea",
#      "label": "EA",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "apexlegends.com",
#            "battlefield.com",
#            "bioware.com",
#            "criteriongames.com",
#            "dice.se",
#            "ea.com",
#            "eaaccess.com",
#            "eaassets-a.akamaihd.net",
#            "eacdn.com",
#            "eamobile.com",
#            "eaplay.com",
#            "easports.com",
#            "fcmobile.com",
#            "frostbite.com",
#            "maxis.com",
#            "needforspeed.com",
#            "origin.com",
#            "popcap.com",
#            "respawn.com",
#            "swtor.com",
#            "thesims.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "blizzard",
#      "label": "Blizzard / Activision",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "activision.com",
#            "battle.net",
#            "blizzard.com",
#            "callofduty.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "ubisoft",
#      "label": "Ubisoft",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "ubi.com",
#            "ubisoft.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "riot",
#      "label": "Riot Games",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "leagueoflegends.com",
#            "riotgames.com",
#            "valorant.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "rockstar",
#      "label": "Rockstar",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "rockstargames.com",
#            "take2games.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "bethesda",
#      "label": "Bethesda",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "bethesda.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "gog",
#      "label": "GOG / itch.io",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "gog.com",
#            "humblebundle.com",
#            "itch.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "roblox",
#      "label": "Roblox",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "rbxcdn.com",
#            "roblox.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "minecraft",
#      "label": "Minecraft",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "minecraft.net",
#            "minecraftservices.com",
#            "mojang.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "othergames",
#      "label": "بازی‌های دیگر",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "battlecode.org",
#            "faceit.com",
#            "garena.com",
#            "hoyoverse.com",
#            "incredibuild.com",
#            "krafton.com",
#            "mihoyo.com",
#            "pubg.com",
#            "supercell.com",
#            "unity.com",
#            "unity3d.com",
#            "vuforia.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "netflix",
#      "label": "Netflix",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "netflix.com",
#            "nflxext.com",
#            "nflximg.net",
#            "nflxvideo.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "twitch",
#      "label": "Twitch",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "ttvnw.net",
#            "twitch.tv"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "spotify",
#      "label": "Spotify",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "scdn.co",
#            "spotify.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "openai",
#      "label": "OpenAI / ChatGPT",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "chatgpt.com",
#            "oaistatic.com",
#            "oaiusercontent.com",
#            "openai.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "anthropic",
#      "label": "Claude",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "anthropic.com",
#            "claude.ai"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "otherai",
#      "label": "هوش مصنوعی دیگر",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "codeium.com",
#            "cursor.com",
#            "cursor.sh",
#            "deepmind.google",
#            "deepseek.com",
#            "groq.com",
#            "hf.co",
#            "huggingface.co",
#            "kaggle.com",
#            "kaggle.net",
#            "kaggleusercontent.com",
#            "mistral.ai",
#            "ollama.com",
#            "openrouter.ai",
#            "perplexity.ai",
#            "tensorflow.org",
#            "together.ai",
#            "windsurf.com",
#            "x.ai"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "github",
#      "label": "GitHub",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "github.com",
#            "githubapp.com",
#            "githubassets.com",
#            "githubusercontent.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "gitlab",
#      "label": "GitLab / Bitbucket",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "bitbucket.org",
#            "gitkraken.com",
#            "gitlab-static.net",
#            "gitlab.com",
#            "gitlab.io",
#            "gitpod.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "docker",
#      "label": "Docker / Kubernetes",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "docker.com",
#            "docker.io",
#            "gcr.io",
#            "ghcr.io",
#            "helm.sh",
#            "k8s.io",
#            "kubernetes.io",
#            "quay.io",
#            "registry.k8s.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "packages",
#      "label": "مخازن پکیج",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "archive.ubuntu.com",
#            "bintray.com",
#            "centos.org",
#            "chocolatey.org",
#            "crates.io",
#            "fsdn.com",
#            "go.dev",
#            "godoc.org",
#            "golang.org",
#            "gopkg.in",
#            "gradle.org",
#            "jfrog.io",
#            "jfrog.org",
#            "jitpack.io",
#            "labix.org",
#            "launchpad.net",
#            "libraries.io",
#            "maas.io",
#            "maven.google.com",
#            "maven.org",
#            "npmjs.com",
#            "npmjs.org",
#            "nuget.org",
#            "packagesource.com",
#            "packagist.org",
#            "pkg.go.dev",
#            "pnpm.io",
#            "pypi.org",
#            "rubygems.org",
#            "sonatype.org",
#            "yarnpkg.com",
#            "yarnpkg.org"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "microsoft",
#      "label": "Microsoft / VS Code",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "aka.ms",
#            "code.visualstudio.com",
#            "dotnet.microsoft.com",
#            "gallerycdn.vsassets.io",
#            "learn.microsoft.com",
#            "marketplace.visualstudio.com",
#            "visualstudio.microsoft.com",
#            "vscode-cdn.net",
#            "vscode.dev"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "jetbrains",
#      "label": "JetBrains",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "jetbrains.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "adobe",
#      "label": "Adobe",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "adobe.com",
#            "adobelogin.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "nvidia",
#      "label": "NVIDIA",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "geforce.com",
#            "nvidia.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "apple",
#      "label": "Apple",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "apple.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "google",
#      "label": "Google",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "accounts.google.com",
#            "ads.google.com",
#            "adservice.google.com",
#            "ai.google",
#            "aistudio.google.com",
#            "analytics.google.com",
#            "apis.google.com",
#            "appengine.google.com",
#            "apps.admob.com",
#            "books.google.com",
#            "business.google.com",
#            "classroom.google.com",
#            "clients.google.com",
#            "clients2.google.com",
#            "clients6.google.com",
#            "cloud.google.com",
#            "code.google.com",
#            "colab.research.google.com",
#            "design.google.com",
#            "developer.google.com",
#            "developers.google.com",
#            "dl-ssl.google.com",
#            "dl.google.com",
#            "dns.google.com",
#            "domains.google.com",
#            "doubleclick.net",
#            "doubleclickbygoogle.com",
#            "events.google.com",
#            "fiber.google.com",
#            "firebase.google.com",
#            "gemini.google.com",
#            "ggpht.com",
#            "google-analytics.com",
#            "google.ai",
#            "googleadservices.com",
#            "googleapis.com",
#            "googleblog.com",
#            "googlesource.com",
#            "googletagmanager.com",
#            "googletagservices.com",
#            "googleusercontent.com",
#            "gstatic.com",
#            "gvt1.com",
#            "issuetracker.google.com",
#            "labs.google",
#            "marketingplantform.google.com",
#            "notebooklm.google.com",
#            "optimize.google.com",
#            "payments.google.com",
#            "play.google.com",
#            "storage.googleapis.com",
#            "surveys.google.com",
#            "tagmanager.google.com",
#            "withgoogle.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "discord",
#      "label": "Discord",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "discord.com",
#            "discord.gg",
#            "discordapp.com",
#            "discordapp.net"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "slackzoom",
#      "label": "Slack / Zoom / Teams",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "jitsi.org",
#            "slack-edge.com",
#            "slack.com",
#            "zoom.us"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "figma",
#      "label": "Figma / Canva / Notion",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "asana.com",
#            "canva.com",
#            "figma.com",
#            "invis.io",
#            "linear.app",
#            "miro.com",
#            "notion.so",
#            "trello.com",
#            "zeplin.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "cloud",
#      "label": "کلاود و هاستینگ",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "appspot.com",
#            "aws.amazon.com",
#            "bluemix.net",
#            "c9.io",
#            "cloudflare.com",
#            "cloudfront.net",
#            "cocalc.com",
#            "codesandbox.io",
#            "csb.app",
#            "digitalocean.com",
#            "download.virtualbox.org",
#            "es.io",
#            "firebase.com",
#            "fly.io",
#            "heroku.com",
#            "hetzner.com",
#            "ibm.com",
#            "java.com",
#            "linode.com",
#            "netlify.app",
#            "netlify.com",
#            "oracle.com",
#            "railway.app",
#            "render.com",
#            "replit.com",
#            "softlayer.com",
#            "sparkjava.com",
#            "supabase.com",
#            "vercel.app",
#            "vercel.com",
#            "virtualbox.org",
#            "vmware.com",
#            "zeit.co"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "education",
#      "label": "آموزش و مرجع",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "acm.org",
#            "arxiv.org",
#            "baeldung.com",
#            "cljdoc.org",
#            "codex.cs.yale.edu",
#            "coursehero.com",
#            "coursera-apps.org",
#            "coursera.com",
#            "coursera.org",
#            "datacamp.com",
#            "edx.org",
#            "fluttercrashcourse.com",
#            "flutterlearn.com",
#            "freecodecamp.org",
#            "goanimate.com",
#            "grabcad.com",
#            "hackerrank.com",
#            "ieee.org",
#            "jenkov.com",
#            "khanacademy.org",
#            "mathworks.com",
#            "medium.com",
#            "mit.edu",
#            "mybridge.co",
#            "overleaf.com",
#            "packtpub.com",
#            "piles.overleaf.com",
#            "proandroiddev.com",
#            "researchgate.net",
#            "sciencedirect.com",
#            "serverfault.com",
#            "spiceworks.com",
#            "springer.com",
#            "stackexchange.com",
#            "stackoverflow.com",
#            "superuser.com",
#            "teamtreehouse.com",
#            "udemy.com",
#            "udemycdn-a.com",
#            "udemycdn.com",
#            "wikia.com",
#            "wolframalpha.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "hardware",
#      "label": "سخت‌افزار و درایور",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "altera.com",
#            "amd.com",
#            "android.com",
#            "anydesk.com",
#            "arduino.cc",
#            "bitvise.com",
#            "cisco.com",
#            "clamav.net",
#            "dell.com",
#            "developer.samsung.com",
#            "digikey.com",
#            "download.01.org",
#            "element14.com",
#            "espressif.com",
#            "intel.com",
#            "lenovo.com",
#            "microchip.com",
#            "ni.com",
#            "nirsoft.net",
#            "qualcomm.com",
#            "raspberrypi.com",
#            "softonic.com",
#            "st.com",
#            "sun.com",
#            "teamviewer.com",
#            "ti.com",
#            "xilinx.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "finance",
#      "label": "پرداخت و مالی",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "coinbase.com",
#            "demandbase.com",
#            "en25.com",
#            "mailgun.com",
#            "paypal.com",
#            "paypalobjects.com",
#            "salesforce.com",
#            "sendgrid.com",
#            "stripe.com",
#            "upwork.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "webdev",
#      "label": "ابزار وب و فریم‌ورک",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "algolia.com",
#            "algolia.net",
#            "amp.dev",
#            "ant.design",
#            "apache.org",
#            "arcgis.com",
#            "atlassian.com",
#            "atlassian.net",
#            "b4x.com",
#            "beans.org",
#            "bit.dev",
#            "bitsrc.io",
#            "bootstrapcdn.com",
#            "bootswatch.com",
#            "bun.sh",
#            "caddy.com",
#            "caddyserver.com",
#            "cloudera.com",
#            "codecov.io",
#            "curd.io",
#            "dartlang.org",
#            "deno.land",
#            "developer.chrome.com",
#            "docs.datastax.com",
#            "elastic.co",
#            "enterprisedb.com",
#            "eslint.org",
#            "explainshell.com",
#            "expressjs.com",
#            "flutter.dev",
#            "flutter.io",
#            "forums.cpanel.net",
#            "gallery.io",
#            "getbootstrap.com",
#            "getcaddy.com",
#            "godbolt.org",
#            "grafana.com",
#            "graphql.org",
#            "hashicorp.com",
#            "hyper.is",
#            "i.stack.imgur.com",
#            "i18next.com",
#            "jaspersoft.com",
#            "javacardos.com",
#            "jenkins-ci.org",
#            "jenkins.org",
#            "jhipster.tech",
#            "jungle.net",
#            "laravel.com",
#            "material.io",
#            "mbed.com",
#            "metasploit.com",
#            "mongodb.com",
#            "mongodb.org",
#            "mysql.com",
#            "nativescript.org",
#            "nextjs.org",
#            "nginx.com",
#            "nodejs.org",
#            "php.net",
#            "polymer-project.org",
#            "postman.com",
#            "python.org",
#            "qt.io",
#            "rapid7.com",
#            "reactjs.org",
#            "realm.io",
#            "releases.hashicorp.com",
#            "ruby-doc.org",
#            "rust-lang.org",
#            "schema.org",
#            "seleniumhq.org",
#            "serialport.io",
#            "socket.io",
#            "sonarsource.com",
#            "splunk.com",
#            "spring.io",
#            "sstatic.net",
#            "swaggerhub.com",
#            "swift.org",
#            "symfony.com",
#            "telerik.com",
#            "terraform.io",
#            "traviscistatus.com",
#            "vagrantup.com",
#            "vuejs.org",
#            "vuetifyjs.com",
#            "web.dev"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "assets",
#      "label": "تصویر، فونت و قالب",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "3docean.net",
#            "codecanyon.net",
#            "cp.maxcdn.com",
#            "envato-static.com",
#            "envato.com",
#            "graphicriver.net",
#            "gravatar.com",
#            "justpaste.it",
#            "jwplayer.com",
#            "myfonts.net",
#            "photodune.net",
#            "themeforest.net",
#            "tinyjpg.com",
#            "tinypng.com",
#            "toggl.com",
#            "unsplash.com",
#            "videohive.net",
#            "vmcdn.com",
#            "wpastra.com"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "analytics",
#      "label": "تحلیل و تبلیغات",
#      "groups": [
#        {
#          "key": "main",
#          "label": "همه",
#          "domains": [
#            "branch.io",
#            "bugsnag.com",
#            "count.ly",
#            "crashlytics.com",
#            "expo.io",
#            "fabric.io",
#            "fbsbx.com",
#            "flurry.com",
#            "fodev.org",
#            "lightstep.com",
#            "livefyre.com",
#            "newrelic.com",
#            "optimizely.com",
#            "parsely.com",
#            "sentry.io"
#          ]
#        }
#      ]
#    },
#    {
#      "key": "bypass",
#      "label": "دور زده‌ها",
#      "groups": [
#        {
#          "key": "ea",
#          "label": "EA — سرورهای بازی",
#          "opt_in": true,
#          "locked": true,
#          "note": "روشن کردنش بازی‌های EA را از سرور جدا می‌کند — این‌ها روی ۴۴۳ نیستند",
#          "domains": [
#            "gosredirector.ea.com",
#            "blaze.ea.com",
#            "gameservices.ea.com",
#            "tnt-ea.com"
#          ]
#        },
#        {
#          "key": "playstation",
#          "label": "PlayStation — STUN و API",
#          "opt_in": true,
#          "note": "روشن کردنش تشخیص NAT کنسول را خراب می‌کند",
#          "domains": [
#            "np.playstation.net",
#            "np.dl.playstation.net"
#          ]
#        },
#        {
#          "key": "epic",
#          "label": "Epic Games — بک‌اند بازی",
#          "opt_in": true,
#          "note": "روشن کردنش matchmaking فورتنایت را می‌شکند",
#          "domains": [
#            "account-public-service-prod.ol.epicgames.com",
#            "data-asset-directory-public-service-prod.ol.epicgames.com",
#            "datarouter.ol.epicgames.com",
#            "datastorage-public-service-live.ol.epicgames.com",
#            "ds.svc.live.fngw.ol.epicgames.com",
#            "events-public-service-live.ol.epicgames.com",
#            "fn-service-discovery-live-public.ogs.live.on.epicgames.com",
#            "fn-service-habanero-live-public.ogs.live.on.epicgames.com",
#            "fngw-svc-ds-livefn.ol.epicgames.com",
#            "fortnite-public-service-prod11.ol.epicgames.com",
#            "fortnitecontent-website-prod07.ol.epicgames.com",
#            "gc.svc.live.fngw.ol.epicgames.com",
#            "launcher-public-service-prod06.ol.epicgames.com",
#            "links-public-service-live.ol.epicgames.com",
#            "mcp-gc.live.fngw.ol.epicgames.com",
#            "prm-dialogue-public-api-prod.edea.live.use1a.on.epicgames.com"
#          ]
#        },
#        {
#          "key": "azure",
#          "label": "Azure — core.windows.net",
#          "opt_in": true,
#          "note": "روشن کردنش این اتصال‌ها را قطع می‌کند — SNI در مسیر مخدوش می‌شود",
#          "domains": [
#            "core.windows.net"
#          ]
#        }
#      ]
#    }
#  ]
#}
#__END_SERVICES__

#__BEGIN_FONT__
#d09GMgABAAAAAbIwABQAAAADsWQAAbG6ACEAxQAAAAAAAAAAAAAAAAAAAAAAAAAAGotDG4HRKhy4
#Tj9IVkFSmmsGYD9TVEFUgRonLgCPdi9sEQgKhLs0g/EGMIaqVgE2AiQDqVQLlGwABCAFjlgH6CoM
#B1tqgJMJ/2vI3kewLtUdrlE6B2xbaQKgyLkFSYBcMnzaEHEVvaFjDAM2BQOy/EOOkNf25oJKb1Yu
#ztr9dNbs////////FyaL8Dd/doHZz10OEgQkfIIaLNba9rV9oNEDmZGldrWgNlHbepPR24AufVu9
#PcEy0+sO2fWtX4vYofWC1VEr96hxOJR9h+fj82Y0EXHS+sNZuVydSnVfK9O496eJN/RHHFGtEARJ
#Dmk8m23DxpJDDiyl2EucHK/tEpHVKJK+Ew6nvXW8EdZRzBRziHTDPcb3QQTilaLAdibuxLc1rIcp
#R/Ew7Ke1PeMEC+UGihuF0d1Ewk2hw11+oDeRWeRzoC34XTxO4t3bZ0oXZkq5gz8kDV9qLnFc7pDb
#D/e1lsu7LHeIxHxXc3nTRSVVUn8VFXfUEOe4MmKRuQTl/LgokT57vNGlHzEgAl18IbtETRERqK/g
#JgbHlmJ7xzAoR91BOQl7UUmNoEou/LNqxP4d/SgiAjGKuCJm6cVRDiJiyPzAozRkW2iccSRqHSME
#JxSXToZJGjE4Ivhwp8g1zCm2Tx8PZLfBkzT1l3pdyV3+XoqvTr9rSfRHCkPAOhNOGHoxE/+9NnQE
#rTSVFC2E07a0xf58rlsnI067iDOY+KGYbboSM5g4K52haQTl/Esr16syXmByIzfnpcyL/da+Hkje
#qE4UfzhywYNcmxhcfFv69Fe9UulnN/wVl2sMt1S8UxsX4/atziYOhDEIN2EU9yImwlCVtLJRSbik
#meWnLza1vtUi/q1wZmaKaQWHQyqt+/8DHV6+EAr7f5rpsQqnUCv1XFlbtcdANORuXxnDElGipCel
#Xfs2tplHHBFdrzqf8Qsl0bKKTEnVBj4fAj8RgXd0xK/tZ3ffvgvqgONABERApPKAI0MB4RMqQosn
#Yf8DwWrCJhQLsRAklNMmxC6sQmwslLjhcab+k8wyy5IssNCSJTOd7QPKYZCapCn9ZcS5823d74Da
#YWGYdoAdFjBlTNcAN5dLcpgcDk9z1r/RKGZFUqOmK9brAL27ryKZTEIMjwAxmYgJIZhWgCqVtW53
#vV0fnpaufzLiu57dZHezkaZpPTWoJ60DxfT/w0+QU+3MLH6OeDnloEhb/KDgLdCrSapJdzeyaqMQ
#/e8Xn1V1u9+b+TS7YTYajw8LReB0ZITRC0Pgtk7LpmPWdsxsqamlWG4UFQe4YKuIgIAyFAVBcA1A
#VBRUXCNLcSa2NLMx5pe1/+v79q8GeLv93easwxnrncwzklnGqaNCKDQo0S+roYwZWeOMQ5zM1fyd
#kYwyDxWNaeyzzzlzvCGcaicHmzRtU6Kte1h/Tx1148LgefBEOEd54nE7KkIAm5hkZBlkSydZYJFt
#mWCE39YzfBhPfNbzXfELs7Cw+PXmMAqb77C4KOa4wmLYyBW/sLAZY34s5mcOoxlGccVFcc0VxnEZ
#APRPjP3rnhsiYWNNImxYRkgSOvN0iCW31YDja0Rd+394N+v/MGJCTdAWimiMBAkSKAGCBy0EvE7b
#1+k8Mf+6IvJm3871WZWR7qyIhbHB1lqaAf/8T7/fvj31lWk1v7T+/gdhcSi6kTm5mZm1UE21JjES
#C8ZhLIHn8fDfk3uT/M6hY1KtIGPSwIIUtDiW10tW4hK8l5uDKhWxuVhd4MuhLpVatsIAku4BQ+Q0
#bN+wdZk6DQBkeCjwEMytAwWLqJE5xsY2trFg3SxYNNuIwRiMHpFSNgj4oo2iqKjvXqz4SL/a+vA7
#QbGF2sm91HYUDLMBygd6oVAmrNt9i8RAEBYlPAmoshlt3xGCAJ4Y29fFwxxxQDF/x+5FBPHAsfet
#ggY+gY1+Loo3HBU1Jg8koihSRzKxPKhq76OzM733vpShRKAAE4FiQBmQZBc3ASECbmpmQAyIwu01
#gsn3v2uqusBT5brsKW337VmdkTxN0hkZHeAC/8B75d9kzTqFPA/kP/jHM0m3AJyFkP9b63tvFXc1
#DOzsB2JF7P+JMLER8qvMm0SoGBVlwgphcebtYENxV9f/71zfxYSCDgpZUSYY0sbcNFtuuUW33Vbj
#4WzXbzvtDyn7DI/wiAo6Wafu+b+JW1JVFDoopHOlLYRNqzdOz7w5SOd/zn/ttyPOJ3pAGMACB26g
#vYHmUqBJ34A0GbMzoyYUCzc5oQelmauq6oPsdWQ4MGekBWxZc0nQwpJ99v/8+zxbAWqaLXrCyX2+
#SwXgzPP8FbrYbazRmglVCTTZJHsldu0DshMvHUG2LVlKXijyz5jpUF5wLV0LT4eop/efW/1XJWhV
#EqD7fZO1yUrEryDtSJphnJYkdxPO38GZXY+aI1+gssnk7f/f7rSCkpIQEoKyCI3HKIzjcuw/3WHe
#FZT4s4ASklW+vgdrbpROIzRSNgmJEpahTk1eTl6mKES4bMneprR7Si9C4QTCI/NVWAUMEXMLD8fG
#YMJYUkyWZAsGWzHU6GqRMQYgzc2KCZWVJ83KITxCw/P9L51NEWave2tc1rtM1KRSFP8gZKkSbwD6
#7/c6/efJqLgYE+FjZaPtv7R+qEVWoZI+HrDdBhVLa4pBlipRMYbBonAgnEBphHPt/zfVz3YeQYig
#tLsWNkXKleQUW2pDqpzS6WN6uHfevJl5GAAESAjEkBQFSvwi+QNIKiRr582bGQ4CocQfpOVPChtC
#pPiTpA0p9Q4xF5UrF6XLf1SpdEhF6aJ00bjtXfS9efh+2s/e4/Lkl+v+c4nb9Q56Lj30HkepGoeT
#CEUopakdjEMyHq2wCsnfm65K/2u3DbMGWAdzDrZOV+IsBBkr4Iw3Qdb6X61Wq8UgzDgYWAHjYJwG
#xsGsUau7tSAJdgbEWM0a1jin0azRaJ1gnTtjjEtvow033PiC6ILQuujqoovyS8NLrUmSi5ILsuOh
#XPZJw/W7uH3OjG97KHGNViUnOYv5Mx/hK7NfRv4/VcsWw5l/NyCA9wDx9A68SMpBkp2LTtI6V5dK
#V24qcAbDATgcBQalER8VNmpzpDZxpY10yt2WW18lXQihvNLu3Lku3Zvnf+5ZlhPS2m1xWJNfRAaL
#j8ErUbCYirABB64NYYL7n6pli//fcY4gHQhCnOGOVxci6ayucVXrKMkrCYLiZi4uw4kXl06xu6J0
#6fKa0iF3bg3/n7OfbXM/26vJRTVCuS6KHPawLuMZj0N9EJK/L9Wq638AISVV6mhQ1er6KDOR1LiX
#bZNj7qzi2NussWOPHXt2yYRQTCRJVRKUVEmw1JUCyyRBqfojKVUnQPU0SZQ0KqmdTDtprKRxVWNq
#pXbmJSRqPih1TxJq1UBcxzHG3dqaMd5c1133tnvdw2mPe9zrHo09HK8bC/jh9JXmx3EA6ZhsLILO
#Qi1k+vfuvp0vOUt2xlq0Sw5ygtwQ1LACmGJY+Acup9d/t38D9QpD2gvjPMDuqLFILd9a/uyvLQOh
#udKVOhknmdkNd0PmUdsvluaw2ECXpxFO4f+r+rpeAIQk81O2iRP6wOXs9pZh/P8/Z2I60zktdpcF
#S25l0slUSgXoSriK6UoVt7S6KqVOiSdn9jBlmP23tAL/zo9n9dxIq/oGLKWEYQgl1Dpfurv8r/1G
#1TvvSexce9EMMog0YqQRIyIiUjGdyTL/cmdznNZ8e2WVw72c++GkrTFCCLGIYViGzfHV3h9fQXRq
#3UB0FQY7L/tuX/33TgLz1Xf2ot4WmlCIiIiIBBEJ4swOFWDbf1UzQLzY327kBdAI4TC++HNQXjrQ
#HY1YtRQobeH2/Lqv+5E16wmKdlt7rZ3rYBiXMhghjRFiCOEZHjEif77FclX0xPQ1gkQIYyQDG2J0
#jcz7U6uVI1L6Pe/EM5d4bGyKBAgEqHQEmPu7QzatQeZ0wv/EUzEIUnnqlGfJcUlDxgtasgU1rRD4
#3gNBpq5ZiZr2AovEcppL3IrSoT++nMT9RBA0eH7Q41i+CRgvICr+r6QBs5UHxKG6C9OUHpAkX9DJ
#3Z5nGWkmSLkyTVfQhdTGPFXLSguAtd1i1T4ftdarj6r2jtnW7ZTpMNFd1KnH0v2GMm+tPP0xO2cr
#YTHX2gQW11Ha7+Po0LMTSu10vkCcERlTUvcWarG1/LGt4seuykZNz9850O9xNz7zIWH0pE+ipk+N
#JpSJ8hwqJGYZS7PX0Cdx4T/yImKOxbF4My3J4DAhaYYJzXtG1svkZaD8DFaYT8zLuGml6S9vSo2K
#5tLexIvDZoCqAFiLEdth9aEyxvStAZXEf9veV2oBAtgPE8BxAC4H3BfwaCBuCMRrAfF/IPgjfAIA
#Z/EB6wAEvODtT38n1iAcGZsoV6vWl9AGAArQL98dIrGxPo4pI8uFKqt6wQtiy2h3+4MRg0HBUb8B
#AgIBsydYUpVuAAbQQ3oEftH3SPmK3MoUOb0+sJ5cT62n12fX5zTilXHNLDWrld/m2ObZ5t8W0hbW
#Ft4Ga0O0oduwbbg2chu9LbuN1cZvE2gCNAmdV7riujHdhb3hfRn94f1x/ch+XH96f3Y//2DsMHr0
#udZSa63drw3ThmsjtDHaWG2cFqGN1yZosVqcFj+eO5E5aTnlOsWYeToj3RCzBA6NFFXaIQnAEKFw
#K3NqeibzT92+jkZYiYpV64neKS88YoLx4iSkpFVUdaIw4grKKuSpcyQYaZGzb2WtAbyyCgIGDgJe
#UGDBgYeAPKpoQRecHuP496YWDiyYCEcvwwnSmjAJesmRp8YgQ6ywyuH9w3aUWSHtba5Fjd8BBQkR
#KU68BGmSbTrODGEi5POpLFy6XENHHHncsAnPOgw90A+rxiWTc1AeGJwXicLwYXF4AomfQhMUFhWX
#lJJWUdWAUsg73ecZOeQRLlK0BPkVViag8EY4CmlMR5IZzFyZii6h/KVVsvJ1oCf4gZZa7lgXxz3U
#YsttcJOfCSkqSVJVEmDg+ODgEZDQCBIjSYo0efZy13f+73TxXW2+r+oWc8JUDTKMEQ1neKMYzQRN
#yuTNxxyKtTFGEln8Pn4p81wGk0wq+q+coYk29IncB/mRCbljjMJKqRXzMfOdFmfmd/iVWB3KjEXy
#BidJR7R/GobwUXOJDKQuZoBOHkIAgQDoe+PR8vyXT/TyvnmZeyv8tBLmZYwEeNlVjI0UX9nCoJ8h
#6HfRnCBzwhSYWOBqgZcFhq+7QfHdRn6GIYHAIICHP0QdCA/UB5MHnoPhxyYeo94afov6SPcJ9ZN/
#/+Q/P3n9J+/+TP5V7FcP/entf/zhX6Cehey6BGHAYAC11cgRxtKjFbYfrVMOAlggSS/keb+mZ8Hw
#pp/I8uBw88+3BfC71i5Uwe92tlsHPwwA3QYgYOFtih8wFK4TzdM48G/+304TvG6/t12HgJML88eN
#mACMd0mhrDvVmst3i2xVAANyyOPXeako9EsTZVRQRQ2gwMa0ITAcFOC2fIjrp0EJaN/397px6WtE
#L2KSVC7Jzo+d11wQnMnOVH+u/5if4+dHM26kSYoJ3djmHCc58FDmZy4a4JAw+BDwEyBImBgJUmTI
#UaBEhRYaAgQLE26c/8SZIMEkKdJkyDRVtlwzzDKHTL4C8yywiIDQIAmZISPGKKhM0tIzMrOiuYRE
#JaRl5RV95gu7fe1/9jngkCOOOeGk084acV7CmAlpOQUlqtRpYWBLiEFcpIRUkbqYXikZWXlF/Sqq
#Bg0bNW7StB3mW2aRVU5YNov9iggZOnL8hElKjzpCQ622cWC4YPiLJkCqAwX46lSR4DDWdurlgAZP
#GoHixxQ4WnQzfD9+mDRxWpnjuAs4wtG+hLrykBf1KrlKpNdLI5k6Ih/zZFJ1V34fnuLtabTU4Q/a
#py00CjUV0LA1XgagOcy60QCjlv2FFFFOvUiyBRlm3HQL1OCiZ8pC0GgTrBPKNLxWjqjyGJf8KCcH
#qSzVlnGmdX3SCXAYv0Dc6hrx4PfRe6shAMUDDgEJBQOLgIgfmQBqs5NvFBvllq+6kCAvtaKRUTem
#Grp2vIGRSVpGXkHRp8bnxi7jS2NPY6/sKDOs/BZ/yikpOXkFRUqUW/Z/a5NYRRYqVmKkUUYbY7Jp
#Zttim1E588oqFlRWRYYsDZKwAgMJg8GQMDSMAyYcYqEYSqEcKqEax+NEqIdGaIV2GMaZsArruBZB
#ERGxERfkSA5KpAY1srIqX+arfJNvsybrsj7fZ0M2Z0u2Z0d2Jj27sic/Z29+zW/5PX/kz/yVAzmY
#QzmcU7mRMzmbc3k1rw12AENuyA+FoTiU0SkqW3E35dwEKmoP94NmC8Frg3UcgcjByc3Dxy8gqENY
#VJcevfpMtczy8ff7B/jjWM3h5UpHHcc86RRdBs46x5QVa9fqbT96hzMXruMDRc2L9EWoMOEiRIoS
#LSaTziRL81aNWnWOAhwCARQMHBIKGgfhUUrhkCMJnmpaVHc27vbkoUc8ePLizYdvPjnPMKYj8CZO
#W1i8Y0mISSGf2kUq3j7X0BYfO5wv3frPJw38y9Be6ctvu/xhfhk0bNS4SVNm6pzMLli0ZNmq9brp
#fLdj95LDAQoPcYZHApJVyvlHjjwFiqH8EBDDrkj6vkluX6ULHRIcRE4efkFhXXpNtXw1519KE4o4
#rZgsJQop+CrrqPIUKYVKKxH+DbW0pbY73c6+66zpxtAtYmcOlrwLlCcUdVFxV+VKlZ1RASGU53By
#URqlCUVcUtYfyheKlEKllQhpoZa21HaX2lk3/NGt2Fkfw5o1qzZtYmNjb2EXZQI7iJlbYFhdJ9+S
#xR/VtRhhF6EQOHDhxR+40jazMb9+NzY2Nja2EzY2NjY2NjY29vPZzNUejw64vW23d+DMhSsvvkKF
#CRchUpRoMZKleatGrbpFJs7AwfmgRnGwyHkqrqkkylSoOu6EM/lkn2FIWMzC2efO95sffhk1bjJm
#Fujxtp+8w5kLV158hQoTLkKkKNFiJEvzVo3aqCuBQ5HzRFgklD73zQ+/jBo3GTOTOBUBUwxUiUIK
#vspCKE+RUqh02o63nX0XrW7g71bTndvw2ULUvxhYPTJCsAQCCgYJjYNw1TMt+gwQnWaTFPoMv6wv
#ifa1/J8f4zhoRIeJqckHwIpPpmtRi6CQsIiouFr8uNMnXO9hM+biWnlYMkWAGqFnAGOlIQZyDlAq
#JRFBbdoyh+iRLMESCCgYJDQOwkEpHTQcUy8Fa+9XHfwZ2llg2pdiZm6eb2lNndkOaf3gd4btlKRX
#k+eXgyBXlGtIYLNx3P28a4Yb8/tfhBJNsWnPVLOEwFkSdd/F2oevjvVAdMZWV+OuSbcygudCQiJw
#5uIfsDJzSz7GzHNFg2xF/Rp5O3PNr2Xr+ChtrfgT2U8wB8j1cpjj0nA8by9m5r5KtN3zvvKKN3ry
#0H/eeXEp0yb/t3l/LjjbErn/QK7ZA+UDl5k0SqQQQq05HAG/roBmI4Je1hCAhb+L2XQh8LzWBldq
#etPcMNYZ3eJlWm5/t7TIeesseORWxlyuamPFWT4Tx9V+2/LCwWp5qcrFAX9pxta8Hi8/j8dQKAKg
#a3FXVrDyX4IJiP5maf1iNSufhra8J2zrza7WhbHg6Nw6swLZouKEMjuxOtpaq7Rf6mUzgvpfl3X1
#+LmSNxgQVfM0u8ktbGaQ3dbBbWCkzHjWbNjUBmYqgyvd+/WOtWJcoHu17uuyYyAS7+b1rW85l4/H
#MZ4VV11nutjcreCv0vzKppcxz2jJqpe6xjUAWMO1t0veyuglraebV7e6pdxLwQ8T1WUselVRuSVK
#g5hXHTyReLqX3KSbJhp19pxoWBATP2GTBeIVCBlxs+c9S4iAj54Rt2M5tpbEdcpUGSiI4Dm1tCfg
#5bu0/EG6dFIVD+kNuk88bdX/7R1+rvfP+1avSrApCifMy1Sa/bNq90YNBDV+WAEI/rg3Nls7uv+o
#bevO3nWe/Jd982j/WrerBR8d7X7mRfHjJ7o4IlL2qdCm927mBou01J7xt26q+VRt8HzYlvZ345tr
#zqW2ey/5Y+ewBDvxcZ921d4nM5sva9Go8PhaLeeWo1NJWuWm00FiRqUMtNZEWivLjtwrw1ceue5E
#3yr/Ps6aM2/Bsm2GGm6scSaaZIqpkkyXbGYT2pQliSPJ7fLGJlObzJiuWhuHgrGYIX4yEy2sOJWn
#6rzoQ1SjVt071ii7DQ64ZHssDp9oM1rCHr4bNSUjwr/thjey0Y0B8+j3MGTXU6nBg+FTQxlGZasG
#I+BEA4wmJ1pgRJzogBnGyXAw+pwYghnJiTEYE05MwYzmxBxNmJsYNwluUtxkuMmBcGHHFYQbOxIQ
#7ux4gPHkxIsBX5QAlGCUMJRwlHEo/6HEoSSgpECkUqEYm1Js1uGwQSc/xGGTTu7Qwo/w+LEWfoLH
#z7VwJx53aeFuPO7Rwi/weADESTWcAdGqhjaQdiIdIGeJdIKcI3Ie5AKRSyCXiVwBuUrkDshdIvf4
#OQ/ymcQXUS6R+CbKFRK9oszi+ItjAIdieiNUD4MYXMSlhJSoIlXqugnFWpvgExVYMZVKBS/fIofd
#u6xsZWUrK1tZ2cqTTdZcsweP4jUlTUqb/py1gFHuFPwNFWy4SOPEmthxPMLp8we0GzLaf2VioC9b
#ClNFCj36VmBqXWDqTEDVFgi9D4R6Hgn2/wNEOxanXlUMyFgOGQExxRQHc4kiWtuCyfqBsxooa/UI
#FhUrNsWLHyDxCLk8QLZjbemNPXA8N6j7i0HbB0OtlwfUKwLslQH3qoC5OEAuCYjXhnbfHmpdHjri
#t+FAHAqM2BegqA1oHAycqA+caAgt8feAxpGAhjygcTRAcSy0xn8DI06G9ngk1EZb4KI9hOKJwMbZ
#ehw+WJ8jhOOZ4IlngzOeCyguByquFK4eT18jkHE9MHGjcPME3DpBt0+oHxJgPAo4ugKMxwHH64Dj
#XeCiO3DxMwjxK7Dxu/AnGvqi2X8JbHIDBsUGSxl/ASt5VdqCmr8tN4YLmD4k3uhmFypYKjf2vWyW
#2BnZGdkZ2RnZGdkZ2Rm3HYe4DhirfjbzgLGFGTsw9sw4gHFkxgmMMzMejHiykwkzBZepMFm4ZMPk
#4JILMw2XYj18Rw8PgDmJySkwZ8C0YtIG0Y6hA+Ishk6IcxjOQ1zYPy76+ngZDFcgrmK4AXEL4g7E
#XQwPoLCHvyvCLRzcpsMMB3fpsMDBfTpgHOzo4OBgTwcPCycqRErofqCP4G0Wl5BbwCXqlnAJvAMC
#4LEHVrCEH4xgiUAKgiUIqQiWOGRGsIQiSwIejdzkTlHAA1K9FeoxCgxMUlqhnqLAgCWla9RzHNCQ
#uV7ggAzO9RIHZHyuVzggQ3S9xr8goxSNdrvdLwaeENTDdUABaXaBgArS+Q2pxBS6sdqQGnTN0Wzd
#OksRhivMC8Mw3IwJAWQaYMwWINBi6OmasUwB4RaGgWF+MRer4LAXhYMeyxgO8ZkdF+p8BX1/PmAX
#BK4LA/K8gD3/Yiyo8IlkHAi8GV6tAiJwo15PwLwh1HljUYtnnG6O+ygg9EIgkIbjFKEuThe10J05
#c/vcfr8NhUZtGrcbgnZDxIIQAmoinvSA4mmA8SygeB5gvAgoXgYYrwKK14GINwHF2wME83rPgcTz
#EvsDgYyPNX0+sq9H9T1KfkSlYq4a4QlHddAH+YOHF70+DDjfFj5h+ViOPQygFzAh+CgSi51Z/deG
#YHtt6XQgUEaIryGk76LgReodbpW3zlocgQfyueb6DgKus+FLPL31l5F/uRuH2Bt307x0mTnW4/DT
#NDfMD8fI0UKniJRr+jGK/Mbd7h3e5tPgI+QP3vY5scc1QKqxIKTP4co1IoslZeLIm1i0x35fcf2C
#A6/1s2c9stgeZ3+jyrkH3B9WRg9YSbYdZCXxix+4aGCcx2AK6huUCdPCLm7sMY3efoY8UgXW+Qcb
#TBF/yOmHGRGSZZT3Ka/43As5XuarKnCz3dYHc7vtzr4kdx8i0n3tHqxJvS/kuNcvrdUF2t9qpNyn
#Gqsy2/OOlFwTxzaaXS1+8YOe1eOTXun/9DGvm/DjPpTwCy6V01/2lZxfAV3k1yJ9K9K3pe76OYyy
#M8BcNDNLW/tplK39/AEx8gv/4pfyrcWvlFiypbDqsaKA8qz7/02mn4qzq+2DHVcGqrtiRmq8ag5q
#sbE85ZXs0jYEcACgjL90DICTgLZ97kZmXPv1AP6k/ba+l3+NV8mPYnYs5sSzDvv9wE/BBgdc1KHw
#gyM4pST7gjKnyPb8eSu0DgIIVSO+rugfZb08PeUgRun/3DbYCBHE6IVMz6U6hRSiWy6YXU5lNRVm
#JJVcCo0pSctU90570OJNVY1VMsz/IQLgQcsHeEpfAwYYYcK3r2VLa8gKsAJ/oH60GwkkTtCOCN1d
#kMPpQT+SSC5HgQmKVN9tiPEgi2eZxuxTODolOZTttg/zx3Qxj31MJrgL2uzvNM5Rw3Ly2MBLZpvD
#v9jC318CC9nP4Ul2UqJRvKS9lmlZmwx8EJWcSFqyY9+sdV6nYK6T8lNsRsp/pqzyDO/wkdVe5XO+
#UX+uuMNPwsgcz8pZ4UGH03fZWutOGzQJ68O1/wMTavpR6p70alP3w1MeXsrwT1iQEGzyt7FM06mm
#7+XSn6fXlBb4wV+MreHtQgitJmZfVV4K0M2PYR+kOoUqyj740qr6RXFKEs0x/i0NJX2H8Qupplwx
#FJSCb6vMjwD92/YRn9IJlZrrOvp6IosndF6VNDboUfrO05BLsWME+UFuHL9QfoYtKBW4jDaHcOAH
#vQ25AOYhZSgzlBwwBL7Qj5A29BmkCe0JcUCAgFBGGOhZaAHAKtQb0Ah1AWRhuZkCBgYkQXm5YmlA
#PAgDpTJi+saCFKA/JvNXWhRQLZ2RtPFk5qLJxzcvSUl5IhE7b84GAcJgfzhmpeEECFjkMYLePG2U
#mSAooVRryBHyk1e3P8N+fgT5SzRr1AXYV9Oy3T9iYFKApcw5PwisAT7O214Czvw2oiBnMU0Ms/Hp
#/nSqc7TvxiIWHiKlhYc/05JW4u6+epfAt6Mjxl6dZ0ogdpUx5jMn1BgcxiIKReQBpVQLX3wOuR7S
#5bFPt51bhBfZHaL+s320cZ49r9lQ5SaU3DsTueXrQMD9h0kSTfFlh50Wh3kgTM0MNKQBPEPgxNvs
#IJF8GtD/mtBPNGxVgy8rwFGBForJYlKsFFCYg1BBqDffHFyjW/P9pnkQdQS08NH2frg0MKeeS1+3
#g+aHorPE1uFWPawJikyc68HUTfOJwYUh4sPzeeds5ZbFo7kDKAmz1ihue8htmclKqlbeRghYFkRX
#xCAmHTwtsB3mDjGfTnwBZbNhSzg7TgNTuRH5Wuanq8mRBT2sLbLS4GkUoZBKQ+Rw/VeL/IgYDtHi
#1rTsPyCNCW6cupJzmF2ow+Oh2X4q0CzSxCUj2Q0wqjs+N7sKqa6kQpAPRK7pnlwpNv8PwN1wN3S8
#0fWrIrVRESwNXXA2hvmQFnQCuROgM5jB0RpWrSslJgOjLfKmKVf11Anzub7JA47Hu8CIe0vu28mp
#sBYU7w7ATmG/5iM4HZyA3xa7/6STCV55bf0l7hfEDfefci+A8QPQJcTTbdp7/mtn4H/pUkDmDtVu
#9nFQ8OVH/Bil/QNUXAiJgBsSDrkr3ffTfT/djek+TUJ9VDAQPATEx0/bUFQ1CM215Xl7BFS4Hr9R
#JZkRSu9Qbj1V3/iFDMDpc8sLsQoUbF2IQsP07mHRgYGryFH/qWcsJ7Y7Q8uJumb2ahiDdrJweuKS
#1nXnzyQnF1p4iSWXWnoL8y3QeiKGR/R/0CRKIqbJmDmrH0QvuNAu8AmJySupMPxgxTmCB8+zXu+9
#7nnnW2zxLc7TZpmQWMKr5+RSZpOUAbGMmRiLKeprw7ilMYCZ+P7C5st0e1Co5/DoRRbd0rzzL9g+
#UAGi9nZaWNwLKHj12Nm0ac40DQtrTbmIddosJ+aBhBgQ1DcKR4ANgWDh3oDPYkAOaSX+fjrILw6x
#i90ahDUAJD+++hkRWVSXjGDT5PRs1YKZ4CzZTE5WCNNRzYzFaH4qMT1EVZA/XFpRzSZKeDe+sowo
#T2EySKlduDTkhQVkAr5o5MNArsmZsvJEO2MTCQuyDUZ6aB1FhUm5NdEwl7fBy+eAz0gaEMpm+LZV
#EeUREyaJkwuhJYUQiI/GqmtumFXmm3+BBVsvFMPKItPOEe1wwRCgN/X5c0u2PlQuT50CUAocmAaz
#2fx5kqaEtrmgf2l2WJ58BV1VeBBJXK0Fy1YahgQl35VUviStCD9byTVzUe0tQbPimpnQejdxb+KT
#y3Z2oL+RzdL+kfxlOpmDAcEJMXZmeX9/3WuwJr2b8uib0yTD082bSZtpFgwTb/GB6N7K4JREGX6e
#Uni1+WcvqVZPYKawCGD6/fN3EvI65Bo6KEd10zeCzngGl+L0D5YaO+5hp3n3th5moPl3dmDXEiVw
#aCRRAUmjyf8T2Xai6Y7/J3mu0Gd7nuxOPSP5G3HHwM/jPauY/DVGPGCQZRBgEVMVcQa9cAn+dzhv
#Trhtcsf4ev0mCBK6UA4n8zAO63AeaQAzvtnOHxc4f1lmzREHXXwLlYYXYbRHfiZW+v46q+feU67m
#vDmmiwXwADKADWRDHcb98Xpd8lJEu79dl5Y71DpbdQNBzFt8j13WAAAXwE9fMVu5ktkfXP7ttwd8
#rupu3ufM2MNT90vhcYT4btHnTQVU6FCLUmjrEFoJRS8maACLOGI3406QERsAwACuDeUfs9qqv1S1
#XJv1qAxlLNOzhABD5r+9/c/vkXorHYizFF3RnuXix36Vhb32iZ+UeOp9sE/f5rtzf8Z79IyNtbBc
#N4Isb/b+9uvwjsl7wiJuKB9+LLO7kKY+0bwWdndLW96K5eRYa1p7A13xJTBM8ICAsPNA9FQZZYx3
#DWAZWhjHEu0rGgiPSo9MMHAWArRhGEpM4DnUuNnbxk1GrLCc9Eg6gIcZthbEcNGCrnSHV7kTO7ea
#1RXmrGtgDJNIYy4Z0FgOAjNhLhPGMsmiVPMen9MkLOggD8VkYs2s0TGxVKcrkmjGAbG/b6DWqrTS
#a0cQohtnh7E4gDUcaMUN/Zxne0jqpjnfp4ANNd18t1h29ZQ1wgPvxRyfSULcEopudFySAplwopuX
#0pQDDwTjwkjNT1srmIyMZke/TxryQG+y2yRlqJPbxxnDykRl3bTN6EjG0hZmeR6Nab4tAMHrsl5L
#XorONGWZW77CqIjRT8F+l/LpO7N29yClzpkOwIZ8VZ0wXeoqVNyPcJHal+qGtIiFQt6SUh9OAvjZ
#VzVDobMCLVuFLtRb2bIq9ATcruAXJwGVr3smtU9qyke+MWzkSlfDlGL+s8AthdUWen1QA62JmPCN
#roFOnWi6pCrXXE2LA2uDC1Ek74omPy8NoDjuHL6POFeb/D7OXSwg3EoiJbWG4L4SGwjI3ttj/wdg
#hCZhb9QaTsBSf87XlM31Ua502sKclq3bsnMHSo0gz44h5+WC/bJjyage84ALXx199FkNa5XsyVqg
#nA6vNfjj++vEda9kOZ168mkus6BIpB+5Vr4JA3tV2ytt0j4W2uqe2R9vhJ/ETZd/POfC32LP95oC
#NHPKLn0Ue4q97nH01zROwSyeHux6lTVA6PsCknAjSRF3/mG+rGJxr2wgPXthJwGzkMjS/qEAC8Ym
#8qlveAeiKnT5v4Vhu/xQT1GBmS5fwXwuUUuERYaAmIlmUp7p28EsXdbCZQqjAKOGVKCCalNnUK7Y
#U65TQmHZ7XqWX8wlWUQ52k0JbvzmxEx8sj6aqKAFmsCE2RNloZechoXN9vyz14IZIy32juhfW7Xk
#fq2Q30z/0QDEcjB7Jxf7DoeAO582Ss07HF5LU+rSxs2ShPrkYD7zkJNkasGONfUqN6JM9V1BET54
#AfVvUT3iw0WNm2oTsG/KotOnrUrXPXLyX4za85asi+Ghxjzj/rnuUpL9kShbDRU/wZbot3ALptHm
#vkSOHIkXpZpcLl/+Fj/l9ZNHYxyLuWGOGzxWgYm4VP3yQ66rR4Xr2tVUiAgHlNNXKtcAIKKdlPOT
#XhNVRKD9wmflkzDIUGBDVQe7JmauFUCiSkARozymIurTWDuiomQNy1hKVGRyr9a3OqLasIbJzlUG
#jVbBBGr4dVNXtH7WlZkUjc8c6IWNoHtX9Il0xAlfpc5t22APMaAgudb6byITHAGSq0KfmEylpdpx
#jgEj95Tpf9rGl0ukVz6k1B5KihsTfSiKd3VT3NgRdK8VvFYjNQVImCjbQ12EZKPhSwaeCYEwSSAN
#XU7pLE/15tE0IcYLF++qpPzfDuuLIk43sJpVl18obyTQkRXqNeRhW2tURQMpGqKNrKslYYOjzUsw
#alVPzxoypkBOPLZ788uqSSH8x7eotE94lEz7SVJVYzLXKfZlkawKQYOvmJ1Jol5Igx5ix+WsE4cW
#h7OKtQpNVZrC4MsFqbRsokvO7aNQ3eNsYEe4d0aMnqvFZA2L8QAjVUbivw2TU6PC+buyx2xlFLtW
#ZrPg9gisMEGX6d2NYM4piYSYrl0izP+gioQORm4A90VUU2ifElzlDu5zWpgvtvzJjKlWqA+BGR2u
#YUFRb2uDiEoxFxQQ5MtyzlE2eyLuQ4umC3aLug2ldcKnfSXlCAqEmw2BgKmf4Sop6kYZKaNC9VpZ
#q/ziMxEa+FDuidDlEjn1SU3L6SqWyk4U0cLp3JYyG2nX8jCNuyk3DBT4aVm09LbplCLypNyIIIxy
#kU/AYtelBFt2VYNNLxlZe94TiA2hlyXlr0pXOUBXJuylBAXBDppmET6YayJ3K/4Fm9xipFdH/CRd
#ToRaTBjJHVmzObGTLlS+6yJTr/OUPTcVNaxYdWm1kifXqRoe1OOkwYXNaX2Q8tYw5aRWf5JerfIz
#iJiRbESUkU6sRIU1V2sPwMZwJeVl2fVtCWn4VqR6qhPPSaik7FiB9BrmkH0/Tpq/hsEp+3VcME+D
#7R6ws2a00Cfcd39CG1409hDzcR0tmDWW8sUbwin48uQWAkva1zYHEPR/+pbkFHCrzDcWe4AfLrl8
#7JPlHujuiQ9uBFEGnQ5Evo6oe61Eg1+7x4v1Zwd35feHn/o1xYP+6DHP+JsXveoN7/nIF/Y46Lgz
#4iblVUNb6AnW5JeTU5/SbBVyc5ySuFgHNcWQgyVZtF+8Xyy8Itwrwb4ba/HZ359vq9MzDxMkDjYY
#chXm9jOApOfmcaoDPfpzF+pNvHdyC+lJeFrU04+Lbr8YxHnElBY3whoe/F1rIWrFwQ8DXefPmV6m
#H+l95qqQaYMw0tvd8mcJKAZIEeC53osKtCwODkSzAyOxE/a9GXsR4QWr1O8qCbh9Q5DORq9wZPo3
#jRA9q16K2/VhMThgkuDu9g0Fh56dFJxt+WA8nU8taATcpynvGvKdXKTBE4zSyWhwLHoVezdyl9M9
#/GplOvwFcq37z/sZI8R9nuuLeGqz5P33T461XLoShjEI+hGu+esZ8E8aqrQYCb+6GTRGw8Yvqcwj
#hpRXZh1Ddb7vDOv9W7b8Rf0c9NIG+3K28u+vrOr8V7nIZU75+lndyz/ssS/hMk9wdR/9Zb/lz/Nf
#M77zsd/M7kuut1271ZoyH90i6ygv4f0ym9ms5ja/O3uwp1qTL/2A4l0rhnz5d6H5zBtwpwO7wVv+
#yGv5JFBBQzHYqEELBjGFdeigxw5Bqx8ZygQWspS8ZS11uRRRyhL2yveglZKr1PMNv8kSdBBBPooS
#qhTlqlhs3vN7cF+ADUM1uvSDqXol15y0ekmx0xhoIJeDhu2Pk51ixhcdfcyxxlnNY5njmu/Eu+Re
#j3kd8FnrLycmPEkpNk/ihJ+/IstUrhdq+PGAXO0zUYNOJpjzYs7wp2V6RzETo56b8wbGWb/kcjl1
#GctarnHldySr2s199D0ImehorWWyKX4piTq9eBEiQY46MSSRQR4lVNFAGz0MASxzC5s9cJSt33Vz
#JVydWqQdKruWXedcqmvPhbugS3IRdA9Yyv7PPtQ+ATqlNCBCzhw69LzBJAt+q4dDjAOtHhNXV95P
#IpUWdEcGYx1/HT0cwx2TnE210OfNq0J3e7iqvOnn06Zk4P8wEQ6Co+A0WkZhToQXYbqjzGr02Tly
#+nPyciI7pRzzzl7dtVHpf+JazPyc5btzhmKRX4SAuCGhCFp6S9tQUeWdq7b6vpnxYH131/92p1Zd
#C6Lqs/TFw8454jyrxffr048/IXmn18mNA3XWgf3luk9u9QtQ5vFd/ckDdLAPhD//7kRPEz0PkCg8
#/+zCzW+Fsqy8Vzh5su6bxfKbK/bSR3uAg90snd3ckYEnRfzXtdP8AMc4xttlnwzDCFZ6mxbOxJ12
#DrxmXr5P5Jsm7BfGtu2GW4045Za3TZ/n+EeDJqJn+rjPv2JeiU9/ufr4rh/X3M3PQWn8vy2c+CXv
#nLnn9i+kbWOlibr+fLH16YGc/3G54YnK7rsZqG9gB30OF8RHYhN6F2aKN2wpZfXpZdhLz0GneFJs
#oEdgmrjf22R2bv+40i1r5eBQnullMb8nNu1F+Gt/MrplFv8lVP/EbfKuGbsmEEoD16e0f5KflzNL
#DzPF06PybL0rb0fd2WG18ecjzvIx/7yPBcWM57zP4tyLHqEbVXOVXtaFipJ1zCZSpCG2pfb9PRDH
#kR9YNK/wpWpakcd+hJPHhg+x2dV9lkv30LSQLVZorS6ExdLpfvvg40BLYYsG6oLyN/3XCPhr/wMq
#KFl0wEF3pxbwllwgFX3vgxON72V9f1QgvF3G/u06oGm5SvAPNGDu3K6RdtFIl6igvq5rYN5pJ19w
#YLHm5PV9a7jaF8mpq+VTj1tmd2hZOA/cha/X5dIT+Gp7lY7l9yiItmth5CgpUMgkDfxb48DyqXJz
#8/BlFMRc8HMoq+W2e/fdrrJNj+deKbfXIS9bX7cCYFnMuXYAPPPF0oT0tDAttHoqY/6EW+Xad30O
#vhFEiBfD1RVfDGdELDWnCZPbbwzDxauRJt/j9fFtUDBIByXF+Zf6ova4FZtv6feLqeFTDN9LC1T+
#cFqp9yRgGiJ3+NhkoaWuUDXvR+eWefzltBSe9oOVmL3taN3ciZOA1DhD7Rtu4RRx2Qvo5Z2lyDqw
#VrLZG8sesVKKXjO9vBcuxjes2ykUKfVL3rJa+7xXvpRmaY2e+mxfYeAvdx593Zf7C0mJpxPs9k6y
#QgJd8BetU5oMbCI7v8AwMMHIRu5WeLLfA5tN4Hb/GJYc2+/hnHhXYrk3AxEwZs5rVL8GC8OzObLH
#338JrOPddEIAP4MV3VqZNiBgs39Q8dy/w96/AKt5zjBZlOJiuXDTcOXApP1WNuyjD4kJW6VH3uQT
#fXzeeKNc+KG8fwUAHDP+YvmbH3AitOEWgD0wiTbRJhZmVNvUrOU4M3ucNkM+Apat4WSnffChj9hi
#6hS+wbwbv+cNF+FJ62i1AXN2vJXIZYYveZ+YjgCuizT6VJ6/33H+Wsq24u6dkXReUyyn139GkVl4
#utzZ2LvisQreHBHalf41wwURK25HySglcnG8KZdYTiHc/QVdPq8CFk+60SuOiG0j9rsZnWs/4qaJ
#YD9uT+xYekYbOvzarwGrECVj97GUiP3389tEkBqTDuBmbbwWC+1LE7Ktxtt0o0CFUdca1x6Eg3Zy
#ZkJyPgs0giE4gs1yp5sWqESpms8Xv/qAwTcSLurcgw8ftt7Uyp0tOA0lt3QdGTdAOqP2QakYHYzq
#mO4DMWtYtyfv7ccdgW2nSP1R25G/bLt0XDrabdu79CwIHWx7uva8gD0/z3C2WHaMnhlPRssN98l7
#XxK27dHLc/Zp+USWx533cAtSI1SL/fEdYOE6uf8VlvM2NLIvVTRVlw3Q8WaycHcE8ytybrNr9RoR
#ilOm6Obl/vxCrA+49dye+0gz9iWV4oUrv4Sqpz22epPtO3fRBll5zwn2C9zUQZZixy19gGVWvat6
#YNsLW6xqurarb0cYd148Wvh4YL1mmJajZCeQJhKCxeUD28oBRLkjFzwBHkLLHd7TCr5hfqd5SbEA
#hbXlOZXMMs126ae3jzM1OfQnL3Y34pC+OOa+ccQcP6kpnf2t0tu//PL7vQ+dpozN/ur2sd/2PvcB
#yWYxINlfKmh5CFam56ByPLPKaF6CuTKZJbJ8iNUyp/LR71nOfs+PW1Dorg5Cnh+4fuaVU0/5333T
#BiJsvpz67LxoIZyyzv0rtmD8opUg53Fdek6uwU8MZd0nh00fhgOYfc99VOMCo60l+Bb2GmXs++6K
#pQAdqOi0+aOG4CtMc3ovsnLmGw5j+enkz34Uc3zkncm09DcttPOYcZ7L+sbeXkHnzXpBdXHaeQsY
#f9mY+SJ+lSvntMv6QLLpFIXja7EtxGduqu3y1XTSpp90Y6715cPR2rnl4DlV6UR9uklZxXWGbkLr
#bK8ChA5GL8LIFKCWqM+1Vfhg5iX5D5LHcofqYolLgroBdivXshAMjv5suMTqtByDE5c7mY5Fb0NR
#ny1/3iFlf0yeW4ZAzj1CvFF0tZn97MNYa7xHnrkn5nHgFtyJO1YSjes0YBFWmfO+iTMwLbvsS3ML
#CDPeIduXmaLSArpaMq/xBz1Fhtmd8ck5UHKHTFgEOCd/xpQ/P9touFyccvAI5NS1Kty+jL1mFy02
#rS9qOkk0A/rJpum9mokfDaeJ6AtVRcWT56vXYnwh1pxxQFylug3bFkQ/bMQeV2z3/7F8Q+NZ94xJ
#yxpb02A+Trp22D5d/0+H5nDxMtfFHBBLfuqt55OijFSrrdu+pOA6j/C5aV+NBvSa99coYiXGXH63
#HeqYW3S4AKAvednuchSmNh+uATyjNNdzDTZ8aG1kjMXJKNTGb/gXVj0Ywzt5KgFXzu3adzqQ00yd
#8P6VyP7xnkv9T/h0QbPMvUjPdWC4a7xzQkOoM+udtqzVycxP89/40Z8Y1QXPD2XL9w3V6sDANVyB
#DtZx6OYEFh0HrB1wbaY2FV5cc3MPELimyyNuQN5KdHe9PNJHzeKaQtazEeDj0NDT4B8S1uPXtzVO
#QCijGDhb3M27A8U3nSceKE6y1Pt3EqlQzym5vyVc6Ty46TLGyL2r4hGl/bL0MbKzfYoVJYqugmYa
#SWNZ4X9XPbBcOGpdNj0cpyFY6DunOZmM1bZ1aP7FPMP0zt7ZjGVoZ3p1+z7O5Mls1PwGSP0/RPGL
#fV0sMWY5r+7q7LwLDSY5IuSToYIrcLamnkEbUOc0r5nnTT0gmKMqz4K4w0btX+hmGBTXiZ1d9dQV
#0ydOp8Fy1KZbgpWKdxD+Q6s3XuiJsvmCNlFVDDStnCQfZfssJ7Zf8S28a/RRs+I2V1rvkIJk7Sph
#mii6oYqrAv/PiaMz90CCgcLPQ/jP8vzMvFGF9Mo7kCk0Ib3pxZ+3LWrUXIMfs+LTAAfw0FZh5W1Z
#bhktQjc7YqJH5c+H+RtKVL8J9X/g7aN/KwfIUaFViAgxJkqRKccs+RZYRmaMmo6Fk19UWtFue0Hr
#X1fP9k346vcP8zp5twWqtDewvWaCbdvWN2p/VL9+dgBHb51ptzeDUExT0va9P1BlA3zRvTnPvRPf
#9i32yyE9J3zLPD153W1zZvhOezWU7zqE9r+hyw68TbKxT5xqa1//bIY/0qG1h65Vn8RtOk/gS5N+
#+s9QPp/BIR//qxDp/+drwMfn3Xs47lKEx+FiXPxwHfriuN6g8jS48FBCJVHYNEzlXVK6nY2Arvkb
#oh8j7Uif1RA4nkYTws1sI9+MaywyDnqrLA0XleBMvgmzvYJSsM5Xz8kG91jRqulzoxmhPFwmDpsi
#GJpwe7RMEq7EKEXqXpCR0RGLTJM7x/J41HIl3/840T9OzFixIxttvER+nHRSWYsDvEy3efyAlu5o
#aAL1Z9zy8vTqnFo3+FY9zdsA/rx/wrvB0F+8WA1M3J9xCjC/GxtYIbz18kcej9aGkPCHXocnJOKE
#43AyzlT5vwnBqRDYLy03h6C8vlPlzb9ZCyG/MedbhTBbGhxNIfyWFhQ6ROp3PLiqtbHWEWK+rxTC
#i55ygzAD6eJQuqKifHYQItH+QIC7qSo6JKpuDBGV4ptGqIlX47FcjpG2luowFa1KI1jb+DtkYcIX
#x4yib+Pz4/76Lbz/Xon0d7bwYf2HzA+yDw0fNlY5tbEv2av09e9VXz7itUv2nWsER9DzOwyBzxNn
#CcnW8rbD+0+STnLIO8Ck9say4w5INR1Ba/9/Fc1eGp/ef/T0xavF5dX1ze3d/cOT86tbUdGbnf7A
#tIE3htEUEZaX1VxiUCKxVD48OqFUT+kMJovN4Q7HkplcoTQcTxerjSBBTL3QK73RO33QJyHNtZQl
#V75C6ECDhQDJqiVARhTxkDJSQxriktL65BSUlA2oGTJizIQpM3bKt9JSXzppzTwODF582CgJElXE
#U5XxD73BTd0HzNtgaWVYajRX1QiXlq7O5fH8rJdy04nTt4jIf3LpfEhRk6dBQjfabYFYOpvYrVid
#SJWAKmYUC9YUqlbCO1jtn2qaT6WafaVrrCXv0q22fTIcOnXp1qNXn0FDho0YNSZuwpRpiXlUKH3n
#GztkcYXhU47z8kzjixUrVa5SS+tKKlkfKj1GzLLKjhUnbgUVVlxGmSu+zPruXPVc+RVWnEHsbYyD
#Q9gFRQnVYfMPzQsNj4SCRp2/IKHGihQt1njJ9nDyiIhLeYGOJUYs4iMVJNAjEQR7VAqk6ExFaPox
#k6tCcvlNEvoPKSn64dLZSaEJcyljL0Y/6VmF6MqXCIhdYCShVM7zltGBCPCRivakNZhUS0lGJu+l
#MkL5NrBCb1ni8s5dKIslMjdA64HBucXLpRGMLhg0fGIgAJuUdR0I3QpYdwKK+ztAMFSST9a3Msab
#GMubD+sbDg+hQBxJX1aBMKNwwP3jdYiXOaCaV1zRHoYUEthqghnm2+K/AF7AwmLVi8wF4tzoDo8E
#iuiEeVyNW3EvfCI/rsdAMIIVRylImTyXAVmctXkkr+dEMkuyTOp6+VQ+K3CBKkJoBAJEsIAlOc+B
#VIgWsI6eXpDa6QN2euXA3gIEAwcsCRBM7AFWIQgGmy37KoLS4CX+03efYFKZSJ8dCMAXeItl+m0e
#pnoOn5+U46AXfxpuTHnhL44m7r+6Pln+zqJ/Lgt/IBH4DAfBZIeLEAnS9mSABfCeHUGLr4aPUE2H
#IX4ruTQX4hhwxuqipHeOaSLvOzHkT15bvvd0ggPzuhwe0vs/O1I4DU6yczBQ++jxr1CjT9jVuCUI
#zRvBOqeRpgwLNpdHIS4/byzbD2NQGx3LXTOELznamKKqJSpsFa4e4Zz2ky8zYGOR9lhyVn1G1m3i
#k9SCy3lxcExu5aUSkL46Qnvd+MPrJFXM57fsJ0Y/3Pd6kpDsiLf+4uMJ5FVeHzFz8nZ7mzcevJVS
#G3neUayhgwpEbJ00eWWgYbf1sVQ1/+M0T5nc0NlsWavtuJ3kwYLcliQPP2mVad+ss46lBe/uxwpA
#LjDFHyzfFhNJZ9spF6+nu65dWJrxbme70HBZ8ewScczU0iU9cNhXzn3m32cGmXVUY/eE0+YdcMxJ
#5+XUpQf7WL/Rj1IZrwrryDf/qC32GBUfiTVdU/NBj6VExdZFj3130M7hkRWbD/aGMoDAvDfJSq4p
#8ZncC2S/b5FYuHWOBVGOmpH4hHvpWVS1BUQV9vgKsC64i+rRWzMHPO58GOjaVaFYTNStFSG0PVRS
#FbzepDt2pKMuOMCyp7ovsV1i1vU2z3NhgE1rjLXc1+5axMHFFBE+2r7ib02d8dcpkqSielu33bDS
#x0OOgpBInRMDC5THkJRUWifVI0ceEKR5EewMrF/bSlptma98444FHFR0uKjrmUSdB4hblwTdwayw
#2Odu2lVbkaWUue6li5oPP3lNeqXD2/XBHeHXTxW5YaPGqUwyMnPwCYlNzoCZIv/rKLFy8gqKSiC2
#6oEcgayoQT9ATRlCCY8ZEUJsORKlhosoO4o8BYqqAFOqLHQ0BGT00IUIK1y0+KKDFQEFFzF8qZGl
#RYomA1WOvBAlkGTI8iDiJ5vc1DHndJPn6l9gwRknMD/juMvNObmLhRaun3CJysSTDwYiRYZMWXLk
#ylcIqhgCGm4KCq20Mjk/AhxSgnjfk2HhERClSEWSjoyCK3c+Stxc6H98v6X97KJl4xYQkTDDzs0v
#LC4lOwyNI1KVtZi+tWsIhygxtuIrkiw9PDgUbJgYIKiYYYOCiRKXS7KiYMqWRaAzW1wyx91palqO
#eiLLUTMsQB+0b64BYQmfsRFXriRplSuBhKksOt95QNUwzbypixSTfYP6XwW6TDT5OrI+CJccn7sy
#4SrCpCyDlx/lTDqK3CInURchnqg9o4MRVhDRutbm5jKHLp9XWmtEXyaCwfpA5VOo3b0woXSo37LA
#iSCyKeQvGNFT80ScfYZ7w9E1ff4wHbzs6w1eIFd54tEPh9kgoLkbzNwPZB6EMA/3mS5v+1jQGzyk
#rin3Rku0uFyK0Dhd9V9rNghze46ehMDEwVeQcyU1xq2FnpWdi+dYVBUQwlxfpSfEocmST5B9RdWV
#nYqWhY2T+zDKBxYeHITYkYWhvviM/O4/MwBvJa2QJLwryV5Vpp0KXJxHNHIHDUVcBNRk5TKhaSJe
#2dC57gO145CZLCDh994hL3QfUuXhoxdUaNBiqqdI70PmFxAWEZdQZmFj5+Lm4xcSbngz1XplLbpZ
#XLPFymOqfU0tRhGMHU9O6zAgHTkmyrvwIMw5FG+hogsWBoYp09TMduJ8LqvRYhQSNFho1NKaqcKI
#gL/6gsc4ApFM1aCfc+M2YRPj9UiERmWWtVF8daAq2AriDDZprdJSgJkFIqUJDRJ5c6qRJifvTBEj
#RQY+wH2HzgHvni2k02YK8bDkHjfyhq+tlhQkA4mABzJWHR8kX4I344Mf9+Cj9512x+x9FzunYDXE
#SU13TKpyknZKeXv7/xkn4rizbXWF1lW+54iNnl59DS66pu21Tm1RjBrVfATxAxK43/bf4yhHTpLy
#HUt+aVw3feBxOjo5aIfgyJDI0MjwyMiLjOb+ScbCyxRWDHwSwPImvN93DX7lCr921R/vYBEEtQwL
#qQhFKUZxC9TOYpFztvdigtu/FhPSloPH+YUvDcclf+f+8WJlykBIqfuiDD3llcTG2NwJ8NKQnFif
#jdkaK5t101wUq2P5I6+uQpK5PjbKleZcjheNA8nr1CyzveJe//Rv9/mfBzx0FPtE6CCRl7zsVf/w
#L//xX/d70Iq+uFgVa6I41sXa2BCboiLKY0tUoQeicL7plJUuzrLFigvuC7uOB1Oj7kHiAnCSM1wS
#1x0cOsRacfd0e+AdkggJtgwcbaeBbzxy8Q2e44H282qV00Jg/f2OPCP9/3pH6pvp31M/2OjO+aPt
#TTu1/EWF3KI/P1hWfLXkt48CpYdKf/Pox8eDZ4HK3zi78/x3V+gl79Vv3tx4v/fqJdqp6g+mP6/t
#r+t7uORx5vtff57VcK75lz46Px5q/801tHzbEx+8Z/uTDx0eObz38P7Ddxx+4P2HKI8tjqfaM/S9
#lPWOp+58mnorLUSN3iNoDKZaxdrMPTOnNiuLuHzXLffah/aue8kOOc4p/89RiFJeugGnkGoGM8Y5
#dtG5yfW07mMJpbaxPbpfn/jE9Qbxw9vMLJ9Xs7ksm1WytazPvvUMv7R5DH/XIL9A+002zVKuc8WL
#WhPtwcZNmWSHk8uuSQvj07Iv5nUrgYDBwZ+3FUKRlIqCj+mYT/a0/JH26EXbbFvrxrujXVAnGz7o
#rC5rrtu6oSfoTD3PDDOcXe2EjvFWr/uCr/qd4XJAAhukOB63xNbx/iiPWnpY8dwaiP8UJolBLHc0
#Ansielr3tMMZ3Nm+s1DutXMr3MkndiWJ9nkK15s8nyMmCIDBuSoviTNy/xU++duBI9qEtkF4FmyP
#qCe7a/ukF7ghmEtvF4tBQCCQt0kgAkEAdA+XrOOfyVQVvORuvIkpa7/chUEPS3Ma+eHBoL1fwSNC
#NSH4b/wj+Ut+yb9PutwT1fgjr56typ9O7z0P3qPWP9D8xeDfqP8lz/4Qav4IBv4jM/+T6Tto8m5y
#PpiqZ9B11Xf8sZqhv8Hz1mXzwVN7pAOxJF/fOgC0PoBNeMTQRjJpFQ0jD4R02DtaEBwvnobVcsOZ
#6Y66eZw9n7vtNOZBBsMLXkiYWAs4+jJYuMjAi0Tzf15ttn7ZgLrykaiE/ZUx0p4eUGxm05u91mrx
#B3wYteqrmzgJ9M97f3pV1c5VaOjh0P9/9UjhYPBppkxzfxWdtY8X/zX//mEKS96vyEkw3V24dPKn
#suvXN3VSPFqoti50mamstZfP8WWZ/kGy6VyVgfjFdyvyebT83r+bxEyWrz/bavaf5PgaAqjw6LMW
#YIJaBrBWK756Nfiu+P6+AMzWtdvf++CaXdQp0WRmJwYbb6seX25hVzakd7w9/6HE46KJv2WIEIb0
#9H2n+uN1wRXk4beJSKGeDg/g82ZhXCkkbboonH7E2OIm1ot7OtFkry4gG4ptYpk+TVk+gOfQA7vc
#un7m4mTM+sre6U9lB5Ob/i0jAPwc8vrnL+cpscID+Ad94MxuHZNyraMBFl1ub9u2U3HMQJUWsLeI
#AJF3PpDP3Qoyx0ZR5FpPeh0gl2r6OESZNBWzqZUGLpCOQyRVuR+2XHVMMvFl+EO7pojh0cL0fHZ2
#1aXpxp+8rT/om2IUdc2eD/7lsj2oxA9t76e1HUbiOWDuGg7mEA4iol/E1d0aUlaE4kHnu+jDhsls
#CGQy43gxu4bIbnUBnVRJMU/vfAE5Ir8JVpWsf7GuJM5td+V6S63vcABg3jmy/bDGYrJ0HHUwz1IM
#MuriICT+FQzun2J0xsXGa3C8UDCZ5Vzv/+zPILEwPvUmO2cr9bUTlDMQgPy2o0vl84y6wuE3YZvB
#olYHLxMoUk7whJfcB+ImVN0Un+fMbgrHBrIXOD+N2skRp8dP65WvmjFMgp2y+6072R+vW/UD+HjP
#ColgAgisETGQ2AFEz4bjItCOB+6zPBasu40PDCeEeYeTc/P26E2Nb3RxIWbqzvEIZsCglFB+c3xD
#E30N2DwMoiueZRHkxIlty99H7v8a1HQB4IE76+n9sb/SLHXtIRMsw+fbm7qxomb6vtoS3Wz//RdU
#stfhNaZr+lftMpApnqeZx+1x9Gz+k0JZ+0YCWQp5SctiOIczCfYNvu8JyCnaN3x1Nz34WOtBE3Py
#LW7V/oN/Yn+3+gRRQvbWdhGktt/A2NUIyGEPIKfpW9Vhg6X5Hmrd3sv4CTmRw2O6HbFc92T9I10n
#ZqbWUx5MWphMv3scCSTfPLqPHuDsnj5KuEG9ou8evGBDazacnI8fJx49cqGwhuqFwtklfl4ZIX5A
#QgIS2aybVyi5YvEqy1nDK5J9QpZYhbqCV5yYsErQXSCGgZ4jrR86GPw6JlVH7G2uvti3mdu14a+7
#0DvfICCHhSlsT9n/DZArf2MPA8hjd57NcI8lwt9+zJjPmnmbOdgh+9TJAFHTxEJ2seBPwRmL9JzF
#vZOcfdkSQJ5y7QPYq32eBz9oORu/Fr73X8pdiV5+AwuHyNEqwkSZZiHp0oaM3JdrAi6uT2T1oRZF
#6z4cDfTzmgmPv2YOn7pmnhiuXyDLzHc2r62Ij11Z+sU7xgWXvvjV5m7LOVaAGf4jHRwib0N2gSG2
#baIryv+Y6qdXAGZshrMAsMyCxMpNt0SaK7LxruXb1LF6ckakBTwqSWq2XEqGsqZkZdO5qLiWrmU9
#6zYNkhqnoDZFw8zGJyAmLW+GS0BUhqBRL0FHTgaCZpdTzrjkihs8oB/DWS5swQLCE5cqVWR1NNGX
#YY5c2rvshuGhT3zbrmNj5YvSt4BYeA8aJiKUdNDHKGPMMcI4UywAHv7WmmlYP44ibVnKhmVYNpgG
#AsAyUX5R9K7i9nb9fJDQDQOrwXpuFBaOPWnStJz28/bVsZOczITi1Ivgh9k2u2fvmZv7Qayc7L4F
#ET7SN4WMKUII16SEYldZR/+VqS6b3PJXXpC5nHSpka2hC+9IIgMBlbTT2w+g5SQ3GYPBPAfmimCr
#74eX+mjyIpuExviyfUX60xDvm8PTAdyPm32zYUD7FZ35Ml88mtmkm4bXP/23QTGSjDgj2ogyIowE
#APlnGg0sMJ4Z1CkA6b6RZqQCSDod1dlfSj6dy6sbjAoj7xv6qK4OQOg/pdSXeWA/+PTtb20fe/Db
#H7/677c/tf3J7Y0nB072HT968+z9rwG43+zDgwACwMOQY9uPXr93+h5y9GUA+ajFh08DsEY29yWz
#1aceSw/a4/mj7FFKHz7rEfuIeUQ9woDphGvsenKtYjkAY5X273KR66tE8//znccw7nI4LIyfmnEP
#8ps8ANIjbpXgxjOceIo48aSQ/YCS1XnON+kXnP/nv+nQT+jEwvi3Mmj5JXVais8tvv4Xjk984p32
#saXFpyiMv+OLeMuG7OkXha+iMkWX9PO22JFbVLRrsvNGF9rT4LplwZNDO2BRFwq2zA19pyCf+D8b
#knct+OSzs2cZL17Syp0IkQiR3PUWk8WJKMdpdU5EP0ikKh5ejrUlE1xsy/eTsnaTKDEi/aQnvRvS
#7N3m9gLlyczcB2T0y7w958+y78ZS9PVC2+Pcl1keHwybEyfnDI4FNUxBETDgwBq+Pdjubpn/ssAi
#f+Coqo+UHfFFEgfqh7/YEhrFtG97lqI71oHBbnqPpYaNqoea+nT0Qfsv+KwHJpECC4uCUV6WHYhR
#Vtnr1MZ1gVQ7ynKBURc22oWT9savADtdh6s+iUSfIq5ariVmXCX8dnX8OAl/3QR/2XghFZLbJP/S
#HD/sJLJ+cX/f+HXnebCfKIWQ32X+2B8e7Z9xnmyQ5xvh2YZ5oVH+3iwvx+at1tnRmorckJylDUPb
#AHx2Q3BqcHi82zm6u/jf7uTk7uejPczZPcjpPdDBovi46/i6j2u5Pq14NgPdq9kymvEsjamu7Aqq
#GzBofCOmN2Zyo57kqw0iDp6JsYbgyJPXtsX9polX0N70ONVTzqvvjpqigtEDQFaOTzgvOxMQEUyI
#+0/KRMX1J/kEHgfMYx/Hq+RuVZ9r/lALTskgGRb5GWiALR7W5qumSBk0/r8d9BxEhKzDhTQ/Lkfi
#rEJFdpnfgTPrU6zazRVWsjGm7J4xTrIvs9mcv7W+NeuiBeaba95Ij+iIcPcPzRlBL+YXTtEUT4mL
#yK2cKofUzEbWs+FYek+01NNIM20KFcWUUMb9kYWJZdBwsblGSwoywOxYF49IC2FAOg0oI/hMZNFh
#ylMM/4ip+DrmfCDmS+y1fQHPvECt8AJKHf/FLNwOyLcDzr4HbvUnOPADgJ2PwnxmOP6KrsewnWgw
#aPbqdCtDUEt4xYN99hlDmBsS9ScaCNOiHlsfdqsh/z42A61DTmLGhjm4GkWafQx4FEIIEs4yKNTJ
#11OCYZKaY0h5753QnAhJ4iDaFKp8D0aQMpKGlJHIJq+wZt3cxACbgcxFxo5MP3KKLNo8tDBqVNg3
#wUYFjs4sbFHkYK3xkBlzGAx/ooA2D5zHhwGyPp3QExPHzREvBkVkBP5R54afp7wRiegiGSeIYNYC
#4/02lxJkybnUxqsJa94SR8hs5eETlKCCcyCEE0njHgAWfgMRxankAI0Tq4wCKQwHcYuhVOo7vXA2
#ovxiYseFvOFZZAveJ7CGpA7pm1ySLdIJ3iQRJJ/JamKZFIFysmrPZPJbLs8rSY3zUEiZ0IK3hFeG
#KzATEuJDxwjlhITZSxw12XPmogzTd/3lTXnZF+159nXwEeQwFdzKgAoXe1RI8eKDUd0IUWcvoLqx
#TlyErC4n9kCY+LzkOCkYgGRG7MhAw93j73nxjSSVwXc0SiZXapde5OCCIOUzFzLotRg4ffuxkTR2
#21MlFqoC3Mg540chh5WIrQ2kunlSt3s5neBrGKaGz6LhLzvszcZvqNerDjxDYJ+b7kEzRYR/tc6c
#e22a4CU67KladtdUngjAwXBsDFYOwWRZY+ScezzSbkHvDjNNHnqCA6YN0zXhbvDamda8erHHMN5Q
#Nzutpj0VYqyog6QikhpWYWoY6t2wU/f108cOR7y7B5lJ+XpufFXDij5JLNhN6uCxv0ie5dO6xmcE
#M7BDUWWnse0lvDgWdwpGSrXnzmOWuwDT9MagKsp/Mm6tQ9ND2G5Wy00CKFDJl/P+zlswvVj8bQXu
#c4Ckmm50otJ/eKVE/2EP2KY8PklyX7YOmAoxYSp79eJ+Ydc46GfuukJI1Y4/t4XO2vG+xldFXa8q
#j5oi8pXpqh2+U1ZSmD+TuURR/rlCZNQYRlfXTZl97XG3O6DZ7/F2ZkQfvynwuJbUBLOr6XTej52s
#PDQUyXQ+DoOpsq4IPQe98DNQpperlUrcTBYzuPf6K2Vt+57FftCNdX35AW4FMBYcRIax0Dgm3755
#9H4Sgk4RIc82B9fvyn3B2E8D4rSvhztvorzoh3LUw8Obb9G3s3Q9mVW+4APHouPuSI8Fhr9HiWy0
#i+Pn+rw3eU7Pd56S5yq3U9sfLQJhlkY0f8638soabzOsjidJlLS6VsAJD77/QiUI2AM/HZbK6UD/
#6XjBD9uZuj3ngvWacS0iqoLsjpPLHuCXuYDNfh6HTvviVNi77PhDO6REZhxjL83i5RmUe0FuLnt8
#Oz5t74v2f+HzZ2s39m5XttULl+835em4X5w20utVB+z6tbJxp+WLc8HYUBxxDm+ukfRnRvvW2hEb
#MVWQ2hI85Cp1o4uv7aXftLKP3mlMQIbDSOltpiDf0foyeB9UukNKFwxCHbZZD02SiLEWwB3kl04a
#xZc1WY/tYrkLaFOFLGoH/zAEVfBwX4tCig7WMoiZaoGDbdgiA5m0lhd9GnD+UL4CEretE5fp8tAX
#CbCJTZT68gXOHeX2mHZIcUIyn0ORxGDwCUenZNwG7f5igLFTtm9LKcoaO+N5BJDbVYhQp+mUt5uC
#hj1itN24TCyaKIGIR0qdTsBG6PbOYVJVfuok+qUDjYGQs9YzlC0z1gRvqDQt1P+RzXnyUBZyRIGp
#KAylFkqU7zMZym5A6o+s6X51pygGGKFokw7BlWX5brAfckhGhyIUYijUJmX68D2gGY9SlOUd6QxD
#amKzb6XqcfIlRJ0hXNvpwsi4fDQymk3s4VHxxFJLLMAPuPPrsqy3KHqhBtauJWs4saxRuUUm/3cx
#cWpgWT8x4Df4L3m17aCxjjFA44GE1mh4TStBSSlK80SNsHLickXTxy1juxIyKwIioCOZtsYVOjI1
#naFsAc+LgQjDdHcWxlpimzw7spyJm1TimMzTHKc59TdkvIPxhZqqtMIlHR49MnCUCwgz+d21H67S
#i6aP8IBNIKt9Tkm9YHjVOAcUPe0Eb26h5F+9k9b8DNlGjbj7Oy6lKM1yJzQuzgxAptk0xo4OR4VZ
#luPFjzZJItxZ56RiZIwcNJhep6M05pQp6paJy70wTjuSstuWgOD8HEUfmSDhqhdJ3HozcHpZTwBl
#PT/SIQxlHDCelw+e4znswI4ieGoQN+XXTZwZEnDfbd0EoM/CTTWpPa7octvpbCa7j800aZplOAYF
#2xbtJVg+waYh2i7dDusiKmmOo6ktdGFM5dwMcjK8wFmDoKaugMm+AzT2sirAsdE1vZbDRBynof7X
#lTomzzfWRaNV8dnPirlW5QgNlCX+exNimJvpwirdhAu+8KGUopxWp3HAkj9GHDqEFOlH94bI62LJ
#mqPIDzAo1JX62DjYdcihoDqhjpZnCpSgm4MxfqFBy7Nj4CEQWN7BBoXOL4aznFGopvQkZjQKKBdW
#qTJlnJosn089LftZgVv1pDMrmKhrWbQaqmxBoFCVUiGUmm3/SZScYqKFDBTKPpqLlEsq02zxfJNW
#zVNrlan7372NGrzNChKUjPwStYWmUGtxmDUOlonOpj8+R02TrlaPhcPt/5qx2ypcizS7rtwgUXAH
#scrgnaGqeEC2PJfxZbbI16+h6KkE8uVEoDIvj0GXpopFNlCOZgpekhM8kAkg2RXUb6PBh7cVIS3x
#Z6Y0MDNT5qqqQHk8yVdsWKMpRLAhN4HqTQSpxcUmH5K+jplrvTsAGCSxyKnUsjnwB/rVQ2YjnHz+
#Xh2W99JedlMviHfB8TC1KqSeU1Jx5DfR/StvNmrjejNBLZ6cUtw0mg9L8k0rHWH57fdoL+ivzOnZ
#MhercqYkykVThQ8HwDRP9PHRqy6Mw0j77a85hXhfHRrdGUm7R/r4pnP4okmYMCvbmgWbWJoVfgV4
#b1sEqdRvSOJozCgAreFGHNpxWzICE0Rkk0FNqPYHkoLbEfXg9wiD7nkw3ZgxM9GLzkF0Qhf9gnkc
#ErjGHOW6PsfB65TmdIKS09YX8MAFWx01pTPtTS6BUjMUqYzMX32MZUzlz/MAIWksskNdtMZQKIGZ
#FoSV6aYwFoxf+Z67CjFwdbZD+rP10NoG0R7V8h4QaAsj/RjqGIjcgSoGRIzKNd7RbaszxwyTWDEM
#UcmKTIfU+dgYQdeYfp9CoXSgG0KlZWQbHZ1f6pgDeWwAyAxDeAAVjOiODZDvgI5jRCXRr+MSybJ4
#qUTzQvaZTCE+hbTqvR6/CibXCpgfpTZ82xY4MYo97mpgKDWy/x7Yv4Y1XKLrxM2HKFsOIuR+AYMG
#xRbjvxawbGDIrmRVXgMIqRw2uqEmJYSdMmIEqo2BtzxW/EHnUQ7VuNscQetbS1PrYh72TPvgGcYq
#E0awNjV3R3oXFqyc/YFQTzb92lkmiu+9Poupudur61Wb0Wohm1IwgW8J6sZStuW1UnFk0iNnlODh
#aTJ8tBA3CKZLgfNlXGJoh2F2ZvbxddWYf9sGPWip6Rx4xZvyM2pJ7qTe/xObyhQy3A9G1G+unY9I
#NrvKIKPOAW5VccERR696YM/+Z58hUGb4t2cJmXOc1tYXwXiFLhfnTYH83Zu/+nbVljOUbYOnWiyK
#forSJlB5HmiyBo/S9PqRDaFb8v7x569eoF93nfIQR2euEtdsBXlJcKBjBqidS0dJdK7TR5jDqxG2
#VunrfYrZOX2nsESNSL+M2YghBG1dNmv/gM4U1awlUNiaiSMhQUmKShoDu3cJawr9Yp0aqH0JtYjr
#IEK8nJKTsQQlBTHYWWvXVCNSSM3OROiesEc8QM2xi1zWbFqnxcvHnMpUrsqFNhgNbnuutbNxBz3l
#NR59VisP97LPwJJrjQxoxmK5IDt1jXOGlboqwBUAaWHt4XI8Igc76dTiC9lmtGE9KdYakL7v9AaI
#0KwX+F6zBobgTY2PQePR5ABm1FW26VSr+GTKWY/7OGZmpy7MY2GpVFk0eqY/t7PzykNrAS44GBND
#eHmTa+CgH6hXCY88CMJMgLNW4UzsmTlTBUjduzLdYjHflKRbqxQ358nAjKXV9S4bRQmeSBUjSxCi
#I2NKazEaKrMY/LHPOKRWTfp13fBVrSGwygnGhjLqiZnY1cJckDw+OSmWVTCTv0xXpFnJOI7dyZyi
#WoY4jQTHeKt+jjXI8NTFcl92RJ7Tws2N2Fk8yf6JLh/ollzJafkiCUpz6QcjxCLyarGGg/0GM4bj
#E6EVSkwLg5aCZnJzX4GOpeWqSeTxl8VdlEZpf5rsDK4zGUp/fTdVk6KkyNkBHkAIeLbn0vD5nohX
#faFyW4jXaFzqLFCX9TTMnnRggZxlG14MG5LW1kRKDtm02+roUW148VCIxGrYFHqoRXZjJcQ9zVKm
#CbxRA1Gw7qHboW7ixXkJj8feIGZmBNVLi8YxDX4dIPCS5FFk/ZTC13sB9sUFr+6tB8osE1r2OEVc
#WqOCWbXtomOT5YBrscKabKcoPVNoezr0+Taaw8idHz6m0TB/d3YTADOrt114Bw7dXNzliUjuloUt
#AQN8Lizf1bjbBZuPUCQb3TdRjQBgOBhz/wt0heAVJ05gLMfFG7Iy/KJUBDCVKqjhRFUZQ0QN25Ud
#R2zIpC3iittJ8VPLP5Kg9NzbXN41IatMtxtHuLMzIwNA82hCMsYLGviEObfXLES6JmoyONztYRjT
#vw/QgAZnEPkcKRYA4rHpGfWW1QBcRmufoV+Yc8wO/MyePHChOyoXnY8QkMnjVz/vofPUcgYYvq2S
#tDFOz3ELw57ZvHD8T2YGEX6dAnWQy7GwnznU4cMfZvzU6AfHhaHg7u1HbtXRT7HUo63n9DyCcYPS
#mZ4H5+F5aniYazgQGxLzUKHcXtVpcDUYm78bCMGdxfISssgGSMn5K06hdWsOh0Ke82KGsQj4Qw52
#+ZC/LpSW72EBigeTCQrMI6FEwF7VsKj4B2D3INn5yhJ7f6KarKyx8P61eaBA1MC7V7D0LEBqSQ8g
#THHf5RXNwthFKluU5FKFE0tAFtk0LmZro7J1RV670O3LiZSwYn4wvQ48RXuWyYVJvSbNGap4Tjh/
#6hvxbufiai7R5YF9E560NZVqqHt7Jzo1uE5lbqmgh1F/VocxkOa/uFiiCc8uz3L+4YWueVsynBKn
#Jyug678AihUL8WI3dhk79R0BPKqS8hyWIc8yqpWQ9Z9rg75C8sXb3Q98Ir9wcst6OHk4jPuDE9Wb
#xPke0adGR6MgZSuB24wXu2CTtRJTvf5doRE+RwlwEIfUGOrVFtpbTGymPmBSv9GIKfr6CTn6Bry0
#N7mpoTqyaPvOv8t/3d02bQvj8jnqlv+l/nyrlrNvlv4KFKo9/IQ82z8rv/3QxKb6JxY+2d8uD6cB
#Tczq7iYSHgeZQ1LIoOkdxaJhYcXgpggiSUaQIrYn9kdJpYP0bv9dOuTS6JlwFtRflznfUTiOp1/F
#yziQ4jthpi1goTL21Ic1En7UpWqHBDkcPXBAmjLHenil0vGhExKdkwI+tgz2qdCfqX0o631mR3No
#5oXcfHUu0+AvZobdNKUqLTdgWbbiIU6cxl/TznbgMtXFqYnZV31wWsxS5h4rHIlirEWTB629TTjO
#DlsF+0Mi27WtxnHsy5iv2d7IKw2WY3wEI81sfwHTut/RlQJsZmPsEtxyKDTF6Zx1OjkNEhwTq/+D
#qxiBbVWcQb0nczis6C0RYmcQimJe3XoLRvYe7xyVyKPVS30cdJ9PjjbWrtB9fNXaZd+24rBXvdg8
#80mHw+ufyKY6Iz4Xw92W3QoQXkatsrjFp+cSU38ttiOJczhmYEVNG6QsOr3ND+Pq2OptqlPprirk
#SdlGsTmMb8MGNCm13W3tbH4ksu4y3vtikEYjxS+SQcqTkatUlLjta8pUlFr6+jPh4r8PocKzEDBi
#dzzLvUBNKbrYl+XzAcviVz4vn73hfVP4ylvlyceqq5OK9F4eTwzfx90RYmzb8yxzyLztxwnbIGAw
#OrSbGS49V8nWXhinYAISPdBXXsB8u2i0o8PXOqrBWDz/f4K0hQ8nQ7n/gDIMJk2uy3QrZ1y2/hDw
#QvluIEPr/o6XwUC5x4PRievf1nne1ioXfP63gmSc2WJ1tlx1yuM9pcP9CX8pFYaWylRQecDZAtUT
#TSQ01I9Ca/dvoGvufKaXzCpSGzb9XxasFuP6Kb4rYlph5bT3bU9ipA4vm3Fcgh7G2SbDq1SVWDEh
#p6SszvRhuFSd+HkEeI0ERrNy107A5E2hQ1CgHZmxLX9nnXINUVqQ+PzSYhNDC/SSmjvD0cSd3LAt
#CwwOTtzA2sahJh6aHhB7uo+n2+5iqJi9h8LxbtN4nORwoDJpIJudfzQJYrIuWaQRdT415pPjsjNy
#Ha6/5m1Yr5cD8R/kNR7mKt7o+w8gNUszr57KzPWNsaeYDRZmiSF4PTa3aNfOYtm4OXcz8mBff8dM
#DYgKG9bilp33SimwYEdK/AoMvjA8O6Elo//EBlN7cZR7oP4YmyBEmHuEJH95GvLK81v6ekaERjK2
#WvJ8AZrR65pwuT3dqPRrYA0+V26tby90pHShLZ8eHQsyCBNBr6Md2e6/6/aof42DegcYrDnVZkjs
#TVK/y+kngItmzuzZfTvcDs/dtNjuTxIts2Bjp21Otpn9oVacVx+pP77u6RrGfsruDKnCAlen5QPO
#oTVkDL0H3ueYJnd6FvZwg4G+9hPXQoq4/t0WpqFHL9ToiR6nKfKxtpVKssXTiXLBjMVYShfjj+/f
#qqTZuu/afsN2GjXHqtUtoyGtOEAu5ip1q2bp6PeKDCxlpKgJNc2wK63yD5NaCZmY0i1/0+b8urAk
#eKjtOWkJKKRs3ajEMhpEs4HxEjdcsiXhJQ/tL00kHOkKrLkGoYZWmAjv1KyiPQFHkmCH0U/ASYS+
#jmd1UkMy6heWpD689KMUPC8JO7X/Uvxjyj3N4m7f6Avd8agZHSsm49b4WDIYLKA3RaeBKLlCnL+d
#DVvhdkOR1+GSQYbNzzygLzQhX/R09GFokefvRZu2mJqC9bhGt4yTLJeBtsvZ5JbkMxoPcxXZ/LZD
#ns5vv+OgbFhEfSI0QpgPsj65xW9HbYvrIDjWB1CP18Vx0WGIJLb9tigjkmfAYysbSjFnwLny/MqG
#03eSc2mvqm9QnbiN6imhQ77k/inhpJ3//Sx3q2dQ0+xOysS29/BeHRptdgK02G3ol3Jn8BO9cak+
#4sNPT9c6V0oma35KH1Af8Unz3qriZ6g1FM+94BefANe3gW0ZfRdZpuBak5eOatcht9oZ8+uHbE+C
#TloZfMahq+eEts8PwCKm87e1qa5W0qejxZ74eaFPeRz9wfh+a8BX6R0eEI1efyS+UcsNswWs6lyT
#I/Esm73031iSy00XJv0DciRDwb8qKnPIz7GDwK7esTeIWokx+yB508Ed3eod9EZqOq4JvSPgRIwI
#HvyA63KBVFGP34HWcdqWHXPNILgYGFK9UDqHHnaPrW4U1aFV65CXAUub0XQgbOlALlcYplKLIZkl
#cwt2Ydku1pXHka3LYng5ZGSErMo0zwNjQOO4NWKgTnFNuXhQEgrqJJDwkWXLefuyRmKEe9FyFWd1
#17sJx9RaYg0vrhvOHIB2Pi9nbrB2MhDsRCnmkb2Yzt5kSnzJSheWByI2bAkT4YfLzfbPA7dPJikR
#36e+1Nvwm8W2bGXuEOhiE9uxaE28ogBoL13h31HEcoy8DQvlougi3wVhZ9R7AQWlxQWvBc8bTEdK
#/9MGlEcvPLwlJDL4WQCdj9iezIe/yOcPlMSGvxCMKtFlaF9WE/5ipODeZ/WyMiqQqW7RfhmSjCxJ
#ManYEPPb9RtsH3F7W2qdsYh8efj+FZDwWmk3Jv7gc+W61VsOHEfTiRF79ssolNgfaNZ+8fFz/Oyb
#tQBgy+QKQhZJMCXhbI2Az3xUnpc9XFQuFwRZH0gQ5mHj3iWan1568Mnd3lZ1ajQ+BWOwBHGmCoLc
#TsobbPkiUoTaeUrcE2/niulx0PHKDjT7tcLhZbOUvOk7a0altOowM3VbcGadzHf5xK+eGJQsd14a
#U0x86wiwrJJfZu1o11eULmUe1kSCXkPntB/qiyL520pduW4TkzbyaMVH03CedN+FnTzcvBFohQdk
#m8HcebC/s+uEVHdxucG7/OOpTLwn44bBdk52YBXxVkvZvNX2Uh/aqIiLdCLZEVnYCN2RIMf8RpLg
#1Od34/hsaY0eWIS/wQM6sjjzB2QsoCss3Jlc5s3BFnwR8TfN8HKaHho9D2NwGdVzunxKbAvl65Bs
#Fwjj4cLoWhQ4NgOHDjJyjQE38MRsCIFwGt5aUSDGnu2WiVbFgDUpbLYgNNp6XD4gdZi+YKHQVx8Y
#51OfDVsxroVPtU0mzBjx2A4JyhyzASIr6zgy52n9JgymuFMscwK4fHC7PXgR6LglGE4kmESGSAN9
#maGlkwsyvwqwc6oAuh5JpHEIq9isiN3pjlWBTqqmVIHU9ZaLMBYG6XLT1OYiRfrADikiwyHBAtG+
#M7mYojTvr10VwHucU8TTuQ3zEahr2WFnD8eKkBNrdA+bg1aV/sZfsk8Lu6Lo2oVLc3/p30p3QpGZ
#Tm6L9lNa8UaI1trbTV8itn9b+2RT+552MGrp3Yab745v/SINspyWbuj5YNgu2DotvTOimlQB37hj
#tg0jWi2tA4LqxB8rKl781lin+UivuN/7bp+5sCTm7FNjJn5Vr81w7Ik3pZ0ED82vCiVLFiNy6e4S
#XUsCRUo8dYA/dYvGmy3Q1J1ywd4HHn2b3chpj/ZZafNWOXSOvh4lBOWrHqv0+jYsu904q4PfY581
#x1OdYaoeqUCy7e6m/U03LJUflLuevd94F2c7HNl61jVnS27NuSZsU+o5/VLpjH6jFLTvnTzE7HmE
#z//jnCC7oh12e14b8VPgWyoQjSmEvViaL7X1UXt08Yr9OPr2OVuvJVbUVJCVX02XbwEGgXlAaY9/
#+/tiLwZb141lGEb3TzLawquaa/MRvq3dAfb4kJb8CuoqRTq8lXBpxV2IMqfp1WylBxKRGBEy7/GX
#VUrT4ht1b3hUjhSWviLMOJ/QvJHbmZqIotPzP4IioxyiviQuqDCi/8UA8C26OmdcJb7/tnB0+P9K
#itslxSWp24qByb6lgsIHxvI5q+Zm7VDRiAT1urVBHvuuv6aoQBEdqQAu7M7ZtSyvsUvk5qYn5fyv
#/W4Dgq/Pxdb6s+msibU5TSbc0CI5TYaHaYWU3KDxKhJdKRYBLXe9tt1tV4upv3egB2jvzgnqYO2w
#k7b9XXtuJt/s8nDp3+itBZQGPowE3q8Hzeiig8T48YJgcYK2FyvYNL+p/2d88rfnpIHa70d1Qsul
#Up0UROF7WD4oVIlUwM5pm93itjPO5BX+pl+1+JfuBuJgR85Kc5tmuwacyjZXbQqps1yT2b2lUSoz
#t5RaLNHiHLYOjgUEpGg0yzT6uYKoPJ6cZo0U/uG9/WchRPKn6glM/+avLY3SS6+ag5oVr9T1atAD
#ubR+Qr7/Cv5ah5+l9hBoAzin2OlWpZcmx7lXemaYU1s1K8f/1ezYhP8yN6MsP5v1B4NOU1BmAwFG
#voJ288v6/MvZ3pwHqTJVFjF8eEptk/S+kdogCGUSZErBgvONUprqtMBg6N4SonSyoaFxlc3e80Zt
#L0MNjCsixuMIj1bRKo879XQrWjvLhAIBHpKnIYc/K/WZsVkWHSK+iX/HXxEJevPhpyr1/yoqCsiJ
#ecWi0yRbgNR59Oq92LrEo23YVTe1RT+LepeXrwuhMc4PE3VgU2NWtol/8x02+2nvse/7Zo+8M2Ne
#sWxwI230a5KNj5wYqdOuZQb9wf/95aMeCPfVnGTPHnl7bfsHWfvHdiAMZaefMeZAhbaqGFRGq0H4
#jdtWA7lpV2A9Y+Y9rd4P2PcrvAx6jw38xik8byaZN4yxLJLGsCoOSeL/6OUOUj7MioUUsT0PVRCm
#aAP+aXGzcmr05L7alj9Kyn/Qro7m/VjiOhtPExh9xpnvDwWk+n2MjXIidKIwqShhqoVAE7K9Wr/b
#WAf8/vykXH0PnZEnndASK0pOZsZEkUdp9D+c78Q70+JNcKeetQv6Xs3P423w6Q3C1LSK+IqE6txT
#L7ta89MHxlE5Pt4k0LnMX2Op2cpuo0xUmGsPPPRr1F1qR72zfAXHCcY3yuVJWrD27DwiLztX3PwW
#zPtUJSqgXSajVVqWIvhRajc/tHKOU5e7eCWjvPwqNveofL66UcyD5wdCJWDDZcglSHZ1+0gCizcb
#SVfzZqkFWAommz4GZ9YdtxifYvPKL+q5jf7Lxk2LHNW2JSIQ4ZDTFewyZJeUsV/vHwnsdqP9AH1w
#uydisGIO6++0sXI4eud9TYv+6ORmdwiGbEeB75xGc0+jT+b12YCrVqXKYeFjB6OXdYrgs6KAnTDN
#/QwW5ypPie5jA15X2tGtt3q2nu455mRj1m+b0vbpTeT73IiDvnCRxxUfYKOXjGzgbttA2jZiYymt
#cHCUajb9Xd8Q+kVaKNXVg9AlHhEOPJCz9VWn4dyzL54Z3mm/xwuWi4NwifIQGs9v3husi+LCcbOy
#qhPw7NNLFtpqNn1faEHjETBOSY0pp3bdIpFUw8C7l2e4Cf+DCuCWsFFRejnXTqsVl+Ly5VfJ2b/p
#Ts+dEUY1K6BUfDssRxTUvckQ3T+541GfQh7Onj+5cXojzZ0qhQBbv0+2L6cGFhgcHBhllmrmBmfk
#2lN3hURfskBZMObllL37k1sTd837ElJDNrohVVDTGaiZ7gQZcP8NDguwaxH7YA4uTv3pRnH8yhZb
#fUrLZrv9MawoMikutpgXV7mu6wIQOj4dejIExvWswA3VQQwGxw6tGlRCHuAeNEJWDh4aWzlYBznh
#TTiF/zBaIMobK0j5cJgwmvpxvCCvcKQA+xEEjlOCtaJ/l6SWplcVRf/SjLWS/2akppYXFYX/Ta+e
#WxY9pSBQSApC7FRpaGnckXoCqXXoFjCH3o1WGgaj24PWNhrHeveno08r9igwZwbS2TGNxoFc7cEr
#GoyiK38+SzbSuo/VGP5ospnapu6fd29HqavKmrQmC0mEb6rnZd5sCmUiSHCbnUqEcqUY7U7eGHfJ
#ypnl7mz4aipe15EZPsdOHbt5siIWFwDlhz6a9EAOMRgc75frHF+RpS1I3SDt49j/ROJTfyenDXWz
#m8HK6mIk32zLkWxfjK3NQgYbSumGk4WlpyM+ijnHa6x/dlT0/1OUbH2cUwj7WHJ6vJBmJA0yYlyO
#rnVddE5aWNLEan7XAA97amEDZ0BB4LAVBOgA03ks4FhedrxVl8dwAMdt9jvPd5zJ+/iyprfvZU3e
#R6Ujn/Q8u7kPRzcS2Fs1e/ddMXhacUq1XDWvAlG3f/fvj5D734nIfzng52/NZ5TTW592a7/4BEqk
#Mk0ZuyY8UIyMCiypiWOjHK1P0jf2LbFzzxXV5i4uZQDHKbgaXiXgYBIFxVWbvugoN+VnCBm9dFZG
#55kkoBd4jO04kEe3/fLBwNxs3AdtPPvAmZA/hbmQ76cCu2HxBbzkjgxLr2s4M3ZL6e8PgJ+pfd77
#nMQ7JUuP623iUDer7uq1JVGrYNCCqMIm1YDdx0+i8akN50BmpSFYVS49eOvNkeGk0FIJBrW+bkKv
#eXui14uAIZq7uRV/boz93bHiFNj+twbjZ8Zi+1pmoqtc5K432dxONlsw/oSi7H0hzDvHmUNCC6Uw
#JqXsQGBt6AGuSRmVZ3tk901+eh+bJxpdIraQT+1rzyb0MueifOuqoRLbMGfNPpgbaHps99gF8/t6
#UvptjmMpFakEunwBUVx7JoXWmTqLFnPKRPyU8F3E0H6fzNQBm/EUfHVKapZ0EV6GOrizGoOoxM1C
#diEUe2qTyPG+bcQI0CB4xrCrwvWi0H9GZB+Qnp/gNZdMKYhflbeaCF8vzfQVj+4b3i0T09wWHblv
#OY43779CuNoJMR0DVuYDTry86tvJ7cD0hVQ6Iw1X31Kn1uxTPPdBvPj+NB2gGsvgVhGn/R4z+2SB
#gIRwAdoDmgMYwzH7u9lh+3uGYxkbwDcpOqnHe/UbPql/pX51n1LXmUQ58OrTzt3vVdz/01PS+IFR
#/Ylx/+R9TnxDU3g6WYXwRX0O0LGUzhqWCsevoQtLrqDzxksNjxgmncsq8FL2NOYXgQDJHwtzgNKm
#zUyirulXtVz9p6VcdpPMfaZbmF8UxqgaoVT2PCV/BMR/0xdLkSenU5srMljBO4Yajes01qhIy9lO
#nRGCI860L/eGH/Zo062b1+2mtEqrr1rxxptej5R2fVoQbu9rP+6NPmJu8aPWutoip2DSMJFmTJoO
#vVi9zkobt7RkbLE0v85AW22m1Jo1/HA9WmN+2gkxAS5CTEryinZ9M11oKlxjKTXkurkWiuOOSEM9
#qyPiXWbeqYmNHaUmIcEH4gpjWLt3fwON5BX8rluBBxev3XmylOHjeBSEeD8CgknplnHr8cfVQarI
#x66zLrOPlJG1QYC3q5H/QPDgoQ1pu+28bf89Djx5nDVwbfwXe9j/Sd1WpHfiFzHX5qIN6OrUaB5o
#/HorfBYd87b7TNnmK9t724GXqUqFUXlZiFDDVvkB9yNmPIFqtwrYaXW7Upo57DCqGykasRpDq58j
#lPAmYzM6+T/2mvNLYuafmmTi1+oVHe0YTiNHUzIpiUXhcIqttIp2wOnC1e5HNfYmYuowIysnnwJO
#3YN5p6drnUDQ8en/HGc8uJHeIKCySljRR8wI9Yq5eLH2/tzJL4kltQbJ/nsrUFhedRptbxPUTIfw
#ooipnTmk6WDxoWltY/vS4UdP63qeVXO/aFTb8z9flUvAg4cGv8kct2baiNE9XjgBK6YEj9B31rO1
#Cio3TwEzo2+OS4HM7wZmusSNvgeeoG2KmI3Ce3gsblzqodmZ3U90Yf48ixuaaRzU9bPc9mDw4u2A
#6tl2v+VdaBLcz2BNQKFzYkOJjVGJO+IhT7x6WCX1F1gcTFsPIovekhBfHR/m0ViFHba9E+7FsJgL
#EnmU1t6wlIR2uEgWeYbf35j4HZtQ2VwZGfcgLktxg8bW5eNiaqr5YC56/PKQMCOtNNF/4wnp9vB8
#bDgnODAQvpOAsmqqxm/6JNaiiV5ORkxMriyImFIDi+KF7SlA06OE29+l555aB6vHZZUez824VjGY
#B78RFt+ydigq7BZi5CLekSQ6g3M7C04xSiFBMj2M8veHE1yEjIKQ9+PkBb4MYYLzqY/Y7bKQoOgQ
#t4+ycL6Mc5HT9A4PqFxJlKm1NbV3qw9NYOi6CKodcsGaj8qFWZazVFKb/K1u5w0YBevvnlndj/aA
#yfngAqhTvsOS3jkPTG6zXd8BgdzVzWAKckhBJiaXQqNDdqsxZXA1ndCpR7PpUxCJqMoIWGAq0h0d
#bc4FEZ3nLHahS2d2Za1Pzl6NV2pEzO3B3DEucJixmdwAbi76Ds87cZGoVuEYNcUnTDr2uDbscTWA
#CRia7JIRjYwDzyzPxvyQuDhce3PD6+oIe/XnVWNRroevf2nciZp0XXBic3be24H/N/3leNda61WX
#F2Ae63lIj+vhGcOdgZ/YXDwwFBUKKUrCiJvXmxjhuw4dG6KmiZl7764tNhkV/9JNUhgF/l2qtIt4
#N7qAT4o7DbjdcAJC1Uyu1/oiCyHtad+PppRXHRGSX5locCYd5FfTwsrKY1WpP3SNVgzc+QI6LSzD
#jSff6Vr8xPe7mUSAwKYX0HzOgVUhzuG7tK4QwBJXANui/EUcjC4/4Mxuc9RdK7iaHtc9QpQJ2Gli
#5lVa4HRL9Zrv5s6czc4tVYHTtCvMNAlbIBshxnWTrxRgjgF0vteZPebUUh0wTbvKJIlZbOkoJq49
#/WoB+oTBSktnTpuT7krBFXKcZhQjZbFIEuYVWkCwpQoYTr1RZQN0Q7bqJGDJAJ5FqOYBS55XsQC6
#AZg43W3idTRW13Q28pr8QnTIuBA0sDTSbdD1f2vcgsiGXZM82QQiMzvJVe3JIhKYWcCwJDjbm2eG
#a5cTA3pPpnN7bjVSvyqUFdSvt+e7xcczGNrl2bTlwSR6VmAkR8L1OkvYbsGclXCAQN+vpqWmoc41
#/5lx/jRbA1Sxk2pCVDJBzVGuyFQTxr/ksAeeXxkOXF86287aru39Fz9rk6GrKDOw9wRzu1S0wUt/
#A8+ra1qUg42DqrVfTDB1P32jRfvw0RJQ0mAlx2cFaD9UYrEXkCFU2D87MInW8jkQ9yE2NmwqYn/3
#2AZzbOciAOeGPNJvRw6d+D4TuTmVQu0AxOdJ9ZrxNnXH7J1D3EOzdzrUE62aehIhEReMDtrlF+Vw
#MupIOHzi/68E7Mue4bvEgoI7xO7hOE9ZOXap++AdAnvuEnoOohvLOGUdTJOFy2BGQwOYceoC5TuQ
#OXUVzEzPXLhUAu4LDm4M5UI0B/VxhaowFEqNUBHYRyAG9hiAMug5gnqGCWW4pe6hu2jZkFNWZgo9
#B6tld62DeRH+l/Tz5ZJKdvdYHnBiccX5S5AgzQtKxoNLdp58X7oMHFlvAKo2C1jIwTlTq77MHycT
#iiqnhBmvjDtwxhryqyPCKvFJWeZ3XY0VveKciJaO40WHiy2EP06rZnDjMty4zkK633lgbuCJgc6H
#56qfqFP2UuFYpznWl/6L8Fh94Ga36rGqoqJv8LvUicXdd3e6yQtsbeFyOD4uq5XHY/l97Gi1qMTf
#zcWLBeXlfAGewBeFeGIRQMUaED248h5ESaAcFzgNRTRYa8ugyRSu3AP+XNFgs1AoNtskOAdyHf/o
#4t/2l/uBsvNe9G70eq5t04zVWEHGWbpl7pyewqDXfrStu/bsTcvSsbn6zHtzDeXi5Q6Vh4ip4dAx
#loC4Ib8fer7RdKB9oGXldUOJ+ihipEa23HtJjWpU0O2paH2AwKgFilYt6Bn0BjXy/O8R9zPHu8Tx
#9rpVV6+Cww/p+bXjPwKFEkikVRKQaM5+MhL8zZzy2dEf70HQU3cmHL6buwKd9UatMS3b3KC1qAZM
#/KcHt7tEx7elO+2bZWVMbxVGdrMfQv8+USa4eM+ydOi6Ze7FkZzW86+5Vo5ed+WfX81WcAI9nEp1
#F4cVUKiYbQGqRtNNDXFn/6rzXLppK+y5ZctdqutrPHvTNK/npomkF4siKN4GukDgIZO9EhE5AsWi
#TH9kA/1nlIdN09ei2tqvi7zTHms9hEd+Ik4gOBnHlOsS/SqS6tx5fJo7ManC0J/ODKftIiU+FYsi
#V2jhbM4YPL0CRUmXayPZ7LHIDPkM0wsba9pJxXsJSAQrheBvLMHEgsJ+1iCnsPAgh0Ue5IklA7xW
#lJeERA2IJGG9tBmdKiaNNeBbWHx+KwtPN5L8NpYmZ/fv+/Z9dd8diBf6NUgIOtqMlIByyBjE8U+P
#XJuBcCI+Xgfpd/qpyEn9MFMhYfckomaUy4YOjqtswt43avt6nhoHmeFxwGWvv8ZDXMnzFTkdRgbh
#qA0zPI//n2XY+fOZcZOXXVFzcDPwDTyjR7nieflAWsPxZLk67iI3B3VBqZ5NTqv6rbb0cz7cfBPo
#TquBxJhmIWYltKjaoAqrLdaeVfuBc1Oq2/HMI+H/EyP/OtXk/31jrLL2TnH+o8oW7osLhUXsyUxa
#PzYUHHOI4AbSXfi2yqTwzixkSEtJGiFJSAue4qZr01aOHH8uwG1JZvJJGzwgLVY1V+onPNfrGVWo
#FlTdA9OQgRcCe6O59yd/SeOh0WO6ftvAda95TaEhm3R2atpLtixSlso+LjtBBrkF0al0NxZmIqrs
#YSlZrfN8W147NZPxCC8Lkh3m/rrF2J/JRGM+zpxubGepWdPm8KjEWILZrLl3qrNUuXHtIUAHjuu4
#yAtS977JVbOsUaW7uTADa8rfQ2br9Xxb/v8m5RGXm982g7TJBifYW++HY3ZM8gQu8tFTedQHypr0
#BxdFbag2d0E1vGk1mWZasK2Qh+LHBjaScSEKSSIBT/AAfNq86QqSaMJw0d5qndhJC+Khi/n0R8r6
#vA/va0cyz+3FkohVwZ6n3NLr1CkJA3RseH15EiEpzV4GdLc2OIYIBrvXOtmaMKX5XWOE1MN8Bnp0
#hirPnI7gKVbTawxREclpOTkV9IyyEkFC4jZw0SG0QdU9LcGvO+ESCSkVb6sUhAd0DUSmR5Z4xTuX
#hecFR7mRIqgKCjVaErGvGygsh8guGqxysAZY8Y1JwRkMy4Y5oxO6dsewTT5WCkfHrSgNLY0Dzpt9
#pdrChN7+NFviMNLl8vmMpVkiCANZ2WlZu/zZ29vd/ljc6fkNYP3HtQXwQuxTjetx5PIs6zrtM186
#8GHW+EpOqhSLV5CDlgvJL64sK5i30liB3OSznTnNlKDjNz3Q7oUMOsi5569QK3ya7OuQ7hwrMwTR
#GBAx1Fov878Lseqj/DiRUJqhCsssP3B8bZ7B0hSfkFG+zyRJ6/KiwxL9SQoNOQ8mXV9H9XTNYQsl
#5muL3kVdZ6/vPpkiFs+nMLpn8tZh9xMa/IQChl8FAZvosx/X4CPgM8P3/EKFyePMv7puEXm4Q6fu
#SVVwkeYDbbjpCpwmikSjhaWRQYZ74bvDveAxaNYoUc5u84vTurKtkUXXoDlOPKk/q9wg9vuxEClE
#axRAGFqFmkE9vP9klDkYntqYE+dch8bXjgSDh2oosVQ0lB3NSVMehrH2tifYs3e4tjiVeodJU9xK
#YtHEIsRdaS5ifzEWJy+uIrLQVepdeEpLLVBvAm0FHXpOQO1/QXuMzPP8M5YnvVO7cr2t75/bVGuZ
#E/PdGT525p9TijYTPXsOFAtmtlXlBb6THaICp4n4PuIkEkmYIBQSsAUK4RKdrl+woP4k5i1dV/DC
#gFGqAg/IBL2wvqDGYEeomDeWHPyE8fCTJ8U5g83d5xO8ENbtLhMYWUwtV4wCFYUSXuXyeplzqRFA
#q06Kq5b0oD8KAJehXSiI7neGVv0+AdfXa2S+OV1eQm+JTjgkW5w9m+jhsuzmcli+cufOQSAKy1iA
#3ndXviMMSx+UgXKL5aFA0Zb5SOPdK2iZanIinBjaDLRz7r3cfXXt7vmh3Wfu7wapT0ezeppBVKbL
#koC/PCCUTiLNQoysbXc8J+PN9fk/7i8rGN0JvLLYRvfSM9vPPLxYZW7Z6NuNXv9Alf9z5tVmROFW
#ODP7gICX5V9p86nPMem2V+UYCfWVaSx/Hj/bX9TgvJUOrDfv4P+8v1xPR8OUyenORh7JUNxT8X/M
#vN4cV7S10c3y528wWLH7Csaq7boc06uoTM0G7gFxw+IywOTMoYOdzTaV580VNzeYRsgTcQApNjp1
#RCPSvxbXSZcv6qONjDTAKQeZPaqsbZdtDN6QAaHKfjE/EMhG6nk/cNSKAMejMcy27vWJ8M8+67No
#iLrzYVKWvma6NLDGcuTv4wAS6r48vIHE+u/TSoI150PKS6eftC3P8QKhjFIxwJn9NevvYI51t2Cy
#3zor0Rfpj1bXDL/VfHhOqapFN85C+zbVlrTAuZ4ZvzVqeAuWkspmSAA4uhzqOIWFQpUx9XBIz0TL
#reenLLzz3v1DbSo/Zz2C6hjbnkbuudxzKezxfRRo3FgK/qbr4+dzP3W6P7g1v6KnRrYOEiqLnUa0
#tSxznsszjjeFO1PXQ8Jf/fEWnjtaNJyScDhHJ+FRkFiqHLgv2XUHdHv+GZWkIwB73aHRSZ3GCboJ
#JkKrNMqUxUQXl0Fl/w7lP/LGIl7X8Z+yLBBnBw9l/F7xY2gyQra4Que9bz0iK2nbKVBmG2boAW3y
#ZvUygMod+b0C02G/eAbSqERgN+SHZMQblgoa7snvFADpiW7B61mB5a6NnND91wYX7yDNQrSbPydi
#0Oj0Zr5coVocu3hddy7Rx+nezVUyfRnOLYPHthQUhPCcrp6QVOd0IRKGq87Onsf6VLu28SimYhos
#2wQ0X/bJOmTAMYG0Chkw+2n7byhqhv3RVimC85xVqs2s/OyccT8pyYOS10t0OzY7MgPo0DFQBltj
#Qnu01nStKa1hjckqY2qvrDEpAhzJn/ocjdp9FksxnXtYlSoBOlq081C8UuK2ADTPott/Q6u3WHSe
#RdObXU6Qn5ZFT4sJkUn5KP/51CTfvTlpaH8PSqXaU0+qqgzs5Ja0xuDqjsiTn+TVkJfOVzSKRklZ
#A57Xs0PYW76Mu6nu/3a7xQIcvS48Xkj/9xjH6Z2L9TGFiIguAQ7aKUnFIHnuYpmTEV4TUsmdPUXM
#q7smYT2vHyh4eS1P3PhUIPr75BprNXBNz2Bww+b/naTm9EzgrjcXn4SQa3duib8gk9YTIyihe33s
#QA+fEwqHsfdzbE4Ykg6Z3xBHlwwwEONUFvGILqtMMVuIvlMaWgx5Uzvxxe2EBXi13Tj9iSeRrqyP
#j431o/PQ/mSoInQXI4e14Xd9vyTnPpaKGwxpk0aHFRbDMfgSOFRO9qzFHKBn9fiwo4HPlxb5+P8I
#kkfVELIruMvLrsN97QENKPA/aFtklnOPHTwiTE/Kq63r/vflCDM2MQiXUAu0zaa0dWaL2lUe5LE3
#kkZMa0wjW80mzMAW0yRN3veH083qR3WB0oi05f14OKVSPZITOVOzns6arGRQMioYVElfX8eerMga
#sKwaEOcOUT6qzotiLkfy+ZfMB5mdAuJ9qWDjbMomAS7QBEcjhBTow7JY2gpqelaj/xZYj4kuEY10
#TtJwv9+dblLfq+PU5XB+GEXVPMb9oUMX7UKxU8II/UjTni7l5JIs/6N29HGk3znjhDFlX+3xiZwo
#mF8inbwT3Z0E72PPW8xaOQNog+56TsWA6VlgtQLc5kB29cDq82D+oq5udjQytf1dLzD4bGXVhr7r
#U5TKjY/8qv0eLe9JUAUdYFM5Ui9spyH5eUltkaa6CuKxNnm4b31kkRd4KLGJoW4l84E7NIWzG82y
#v/cPse9kd0gElKzB/IOAU2eBeGpmUdMxvdiKaJlabO+YWex+h8Ci+Di0OliEixZgsckCYJiz6ppL
#L8Dz/tdAG9NCUp2DmUVwqPaNhVV7aoRNV300j/bYpJmVznyle0TV0Q8jn5fQyXiZBZQnyIu0xDn6
#aeA7uyq56GE+62ZFObfxkN9hBvIxV2KpLU5sjVNno9/525INUM7wMBUdhShGaTSNclE+Kk2C6IYX
#GkNtjTji/wIge/N/4x64LzOynnG7i0v0NkVixB6YKAMTrX0J8ouf+/o5//jNcJ3fG1ar7lZzPjSv
#k2Y9vibpbaaUEALmseuctJPFlAxqqSDg9aIQmBOXE8LYBYzUqOj48IoyBI5Qigi746MRYRVuDo8v
#H+yu1kTvzuXN95TvhZblIEolyFwkF4m3Rnxf3mFtDLJIgjQx8MsQMNoRk0GisEORUl4MAxmnbcOb
#zu5rz7SYWNemGQNuvoEEAiQQWTry3NUOmHMkReqkrjAgIZdAkTAav3bh0HCUEBEsPKIuQCQDN6Kx
#YtchFSJEUifyJRciQirynHnd5fdCfUC6WQtNHZq01zvVuxxevOtIZJTrKC8hZx5QUX8/hqDvIhd/
#TiLBnw/71XPQQAaTnbZ4w0J97byORquiUSpUf7ZzVMA7XqtqVG1rvTFww7oU2xzSDCLIWsDGzgK6
#dMnLJ+I5AY6pBwDFmFytBXTIzWLMqi/jx5xSUTkjpEWoVmWkob6aFVaXzcky/skmPy1m5AhiI4rN
#+9UoAiTV/VEkYe6/AAzUsyDZtktE9qd/Ake6WdlUJo+KqiKAuzo91sMuXSL35LWLWgysiV3yj9Oo
#vpvl/g4SNYpAelXBQbTxSQeYe6Pi3RwcJpfDQFWSCIEh9s4k5yzcOTuJhbVkl+r2OMOjktuZOx9c
#cCcxDn8GIEule3GK1q/XL1I1cP86QNo2GS3JpsF2c5G7kg4+Oz6LgMV58CnQ0mgBgwrbxUBPIIQA
#sQWS0Qj3id1B+7jMGMG24f0AKweLiDlk5io3A4VpJcB9inKCwv8yLHISkQn4ZmGapXcAJIkBjrS9
#TgeZTDIAwy7Fm5JaoIH5K2MMB6H3GotzLQlA+rq5dPaE3cuxglUkvtPa274JNONNRNlqTzVwHJc/
#0BP3PkvZT4qU+TnHrkvjrKYPFUqQWUzKljUM+OrKImsL9FOs4vS9BSuD40wVan2iMDaCGToeMfs6
#z8rMoqQCPharniRUATcIWFVa8k461xMTyN6NBPcdLhAwOKqYPv5w+nN/QjouDJqGi4SlYaBh6Zj4
#cAeUgwPwO+v5x3sPkPCw2WYfWudTl9CefDqakIdOSpNNJvGLj2BTVXhdSA4vK5qwGxYOhfLrdjkT
#h7cOx8fzk4mUuqNxhfJFMrkLM7ssygrFdSTCXS44KJBeHvfsYU3eZ41qe9FfPxUbmFlAvLeauZSN
#fFyPLxqFKKCEjVIGW1uezlR+e7G5mAia3HnCSjYqgK5ugVVuq3O5nMZsE2bn9TzEKF8aPL6liw4r
#rIgkaeqFySE+qtngGufGbdfJzFaR6q+Xj//jz89lJ4X4auZDZS4NrpdTGWrRyOqTj1N0O5pIqD7+
#jF6sgcce0JZeUafhY/yp8XNh5S4Kl2vk7HZhw+tR4EfWUp0uwBac+jZYqjbdzEtz+pV/cDQ2F7TS
#Pkt48vKfrHP8+XdyfH+5pAYwEkRvurSI33V3AIL5es50IWbXXfPsfWV3XfcHrM71YwWadjV1xqYl
#zLea9ZJhoaojjGsDAo1dF59OqNv5TE3yhx1rXJ8+v4zKO2NtOUi864rfQyma+z6aAkpvTeMWYnqW
#KXVe1LTm+HSdOlXgppZ7OM7mLX52C4FnImCqOw1ts3LHwBGGbMXdZDkfpI1sOVFgfbU7ZpT21Y6a
#z07IMc+sxKFN9hECs1XvVytVNJpQQaZyhewSTvautH0wUlUdhd/fM+eVcLsGuXrzmFg4ZcXXEA41
#+Y5WgJV5Bb8h9hWGI0CF/T8uvFWxRNorUegGD8Dr2nfzlS1Zo9RVdpFbS+JXGbRcckZNQV1GYO+3
#W89svZy8Wmvm00qT8Ld12zeWMvfOHYfObeQqEuwc+J7XDxR0hocGPC92wPc9FT2vvz33U2dMZ3jz
#jiZsayvPmKWEF87+NOv2SDMMjpHat1pettze5gTkHUlTl9wytg/HNHCl8uDjwHrmhG9AK3c+oNtQ
#EfOBk/EfaiZzMcO2Xjq1iafC+7xEjbSNzPSKV73eCy/WrxheNOYGx/aVBerql9jt+6DefZNTQTUN
#sEHGWMfV1xzLLIu4Phdvt21VzPQFqOr+nWWVWJF/gmAGHmmtO7aouK39u7Kjgp/yXO0fUfz172/K
#6p4ru4/BToiKTiMNgRWz6Whds3J6EdZPBpat3T0dLlllvcXLrIYShZhLppptFxEdwU+PlYYqh88k
#TS7srF04OI0UbpZ7vHM3ZHPVs9BWJatbuYojyevg/KZeu969zdAFOC9fDeWTUfC/OXpCdMkCW2Qf
#wMmHDrIbcfSqLmyVt0Dqre5DUnT0xtMdQ6IxlNqtWEDIyEwun4KmqbBCgO11lf7X1qpOXwb4AmKD
#tYKCYaRjp2CwbchAmIDQaKOSS+jp0x9BlYl0IJo7o0wSGGsF5fSCGXjuT4WVCTxjowDBKmDkw3Li
#ohmDD06+ewYoS7NJ1dVek+PVmJSmbVtkUlaKJFkx/bzh4i4bcNZubk5X9ijOzmYdK/QQ64dmBbZ+
#IW1Eu9pd/9Kb+Vtf/fJeg63gVPcJoXxkETAhu4I//OQZczpDHy0oLENrHOUSWSeF06JY9bWuvuJd
#NnoEbZo105GdhlY6qUkMiNo5VdrQyTZ2jWKYLPfWOYY7OuyXXK7jtx3FqzcuZkawRn0jXAEvEZxY
#2K/xZEWxKBhtDurfChFXRNzH57WOcM2js4UNcveAVnZ6B4BNpGX5VK3M/S96E+lsysditH34wWpk
#a8fC5YFLjcdSCXUGaFnbuJ68B/BNdmxlEnZtiRho1kvgsRbIz6L88ecrlCpAMv1vrlHlS/+1n8HG
#u/qNu+ZkH+dAWK/AzcTjOEwCgUPH4bl0Gn5udn5udF5BSG5+Dsj68viq+oYHh1bqmQ1rkLM6DAwL
#WzNAnDMI2VoZlcKlUBt4BnkPUJi6m3fSO4k6PJYCKYNaMYKrsVaiixBuGPRxt+7BlajSmDh59McO
#avTU7kNIpYUva6hXVZ3ckTz9447OrUZ1RiPEjIRFsQDWKqKw4VFRZJHjCYl0PtudJo4mqKSMmC0p
#pObLOcZ8Uk3nmAWdxzRaf9zuMszqTMr0h4QnIpuYRA6Qcfg5xnxjhdcxiGDoOTR5/bbK6+WN69c5
#/uhT1BSHV2bk0WrZ0J7K4kfEuuwEfkpbbeKuF+Df31jhYhk46d+UMFBXq8t2JrvRJv+OUdsixYH8
#bS93uaX6gViiWwhUoRqLEl0EdxcXPe4aFgKaEpK7DiAVZp68plZb4WFk1Ggebjnup0cVFw+h2n0L
#5RTKgGlZTDGFJYZ5FEXHipzEKZVDJSOKkZJutRrryX0sLmXy8wknciyr6uajd51C/EsZcHyYWK3n
#FasgdWUjl7l5HM1WdeVWNQPXxqfT0xk5sJTF65RCd3fq0rtSDUMaEyKEsu1AyOqTfv3/bBLF+nI6
#8ym9Yuy7FtGm9rf79csLodJShl+vQCiuxUWn/770ZAmS4GRbAmEpS0Cq4ZCFnsosiw8IN6PL2s61
#81q+mDM/+L7Fi5LcBttHU+RcLU7feuUY/n5ghf3W+dCfyNsnDctqUPBFF/IbuPfJR9IZT/mthqVl
#2Z8NqrzlSMA5jG6KpEdc2NK1iXHlW9XMpR4ZZXdgx7UqMUO6sCvuws74ERqzUrsEB6Ubr+X/8myX
#3jFL/nO5zkfx2db8S+pOzXM3S0vtgXEnkK/i4eX5/FaZtRWQ51Rc9Yggu2OZJxC9sfpIZxk+1fwl
#/pqoaa08+l4ljkhKiasX+epMXm2apuLKidA0Ae2L9sn8lSDj2P4pmvisx1B0M/3mPlpBbcknddua
#w0ML3r3HPv1yKFj8Y5EGK/jHhwNKM1Mmo/W41QTMM3WGgw31jqUzac2ak7zlHSNPqsoLKJIExsvb
#ZM/aFpOvpYrK0U0R30xLPQhtGD1anBUoB/TqprNVB0CCmG2HVt8Ez63GV/p3F8AzzXZ8hdhGaspu
#oNVbcXTaCUTpPsBsOqDodpDORDojj/9xmwTjmGo24YdLRXDGLj1liSKrDdZ6l524RDPGsNJF2Xkw
#YNU+4bx9+snHxCD/FygXBGJRnfshwqPlOVrwzECKdPY4fSP+amxOLIifCuKDAMcK7rifnEYVeKsQ
#CY6/9/hOZQ5xes2nrmSmIa8cvfdvdHd3/mrAt+QXx/qVkhtFb9EnvWppeBHLn87jM1PfebXUOlsR
#0xSbWCTJVMRkhbeWNKc1EnhaKrpGkaGIbY7PNiSSEJr1gJ/i/3YJHJeC+xM7BvbG8eb67p/VNHz7
#ZFnT4XcDj6NARSqMwuSzkuXJXgQ/6xeoDSvmwpEkLQ3tUbD0Me461KGIF7yiww7oDctrGOHu0Dp2
#y4Y9jB4PyzIUNKI6CipqRhWMKX239cpRep20k2Dy8ObBcrzSLmtssKlJmFKT1vEC2cXKtGpNrS3d
#z/uXvXTif86S3DTtEtDH2scPKdIUtWOgTHsyE/GcYccU3iLvEWkC8Gnh3ovqSWdHrCHaNXLgt4bK
#DNK+t6CSF7daq593pVMEiPRGvoKJ4sMxVZn9ayuXdRFgpW//F25lp3peJYG1uVnG4yQ9Uk2b6FCo
#EYq4YcLsbk4a1n1Y1DJKOe2gpTkoHFe+8FCZNhsprBrhPA2t4zJvsKYGLNUT70rWr88xIHsyC/0G
#ncP6MXb7ax8ZmJv0PJ7JyiKWCzQFb57McG5v1iXzyulYyPpVs9JVHpnakQb59omh6XDoC1fJ7EY6
#xJWbHVaU+22h6B9gmBDpuLXC1o/dTT+NQDNRv3xwOSjH+gjLQHhwEMVGv2GOQzVs6I+HLoCUpSo2
#RJxepySUFN0twGnL5BFva1iw3AJkFewrxu8UOc+jYyH1sYZNrJyCltziDeG2AF1z2zY3FKq9I/Ws
#TlkR3+XiJ5T7MQF4nS6naEpU8KRsCVLIOMFngFvRcZlquLwkKVdHqBRfEzBC/jRSA2G/bNHMH2J3
#vPox2Yi0vrrgIXRno9k5D9fT0hMfGt8ViK4HeU4R7g08qlkgoJk28F3hAlJXDV8qqeWTOsExq+u1
#c3h5UeDf7kOFIkB730jG1M7jd8JRGD/aAMNeffXm9WvX4MILSVh27VcLuoxRHiW949NHQCaXnIxS
#bpDByVn1lWyZsDqPq8uQmwqNDXvxGT6n1E2o0CnrM3bHWc/GovE9ObQX+ozWcAAR+aCxsLfstQ7D
#UEb2ySjFeg2cBKnFMtGI8bS6NeY1/v3hoG9Shu1NFOTlQrOUdG5xU6YU41OdjuxBTiLNRnYushuf
#iewsB7tPk3AjAda4uL5l7HV6EXdnlCgKcuH+sKBINZAmJKOLczVVVfu13cUJR+VtkbJsNwzH4/UV
#VCY+sHNO32+WMfiifM6cR0psdDPAsaXF0zoZJZA/Ed2Z52/dMqPUCn9eTHWCHNDL1vxc+fqVr+0+
#+qdoF5x7t6dYbRCCwI9t6afoN1/+CqmTaJp0EzNiXbxlTcTu8FXHZavzcupiMv/cvCkmcvevEhJP
#pNsMJ9JkiU+LIfvSQVidFj1zYjmY59+rgstr77u56uSkzcmbe+Hkrrk/ETIx+f6TXbsfguzEmKLo
#IESFn4uuEbySBOjax3Gef7lr5iGUD2RYJAj1yeNoWHaTUEUnCMuR1sRAKLfDGgVfhjoj30NAM+FV
#3WVIvBwqDLusvw2rhdih09qX6h1TSHdlr0jdXbKNo0H6zdypTIBYLJP7bG1s5REL+7hCXyImEKQy
#vM2QEvApjGm3N+tLJyQkS5RJgdvZnA12ZEXOHQ40jdCQtyAZUsadqjziTunMIZBzc9kH9kFzMuK9
#0+BLfvfELz1zrIC06IO08krD4TH/uMVYyamSKBFkD0GiUA3kTa9jf6XRfwpMRV4F5mYZca2puKq1
#+j6s6Fimf2lz7FXoZaWl1LRd5UsOJtusjjBzzBOwbcFMHeNyBzd+PkZ2qiRSmLSLoeO2VB8MgtIY
#0lo1qs3j67MGrdYzApz0gIhVnydMCkLomhKkhhb9BLJyHFKBhvqhH+qad1BrFd1CVVfJTv7kUu1h
#f3MstV2/9HJVrcL7Bj568aatlI3I8YgkFByPWGpK9ao+MgnACr4lHDz92aGAoD9ktPiyc80IVCoP
#KOtXzZ4rqhMHe5ZOMvFNu3Ix00zmKu1vMzpKAMPosibDLADB2OrqdYAn40GDRaQtsDvSPoTMZoS2
#vxilyceUJGm/B/bG0/bitgZNBZJlRB8gN5hU+f3tvnvo53ugLihUo7hqdEVij0csrt+z+lPz1CvD
#aJjFddS7fpV87n4U9/JhHHtI+bfL4zuas9Km5XMrN8Qb7Qh2aXa9UEIdpB/XRtU3OsGuKTy5aiKl
#TbvlveQMqojbLtt46lJmGvKGaPVlW5+5LDjDLnlLv3+KZGeO3xryppZqDkKqo4EO79DURJIahkTZ
#lNKCo0oZzlKKIKiVhLgPmPgPHk1WU/iEc4qZFqcuZA1FFFqCtqTyB4pSoj7LhKMR++x1fXQuq4du
#qyf2ULGZFoK+94ESyYHBCvAw3tEO53TjnfhILzhuCgSbRlftWszYhkbUz/TDr1snT9QM+VdN1C16
#1UQKSK37OIqx1UplB9mhpPSpYK3reMRBTpx2Tu/LGk6YO378rSe4euJr3oz5gJS5pal/kjtTy0b5
#/zt7JW8NzivOz+H8ebqU0GNx2clOHJsv3Jc++I9z9y/dwei8BzHNxRMiUUulgObqYp4r+CwqSfVI
#4scKfCOwUyPO4bava4+7e5LLjHAYimkvFH0ubFtTh7WiEMV0fFPOrthjYZou3nNhG/yTsUkLTckf
#pX7cNAZlgNG5H8Y1wjj5SVtIflQQhdVFGmfS0vAn1n9skdQ7qY2bJqACgJp/voqt7WpDwTt8x40L
#xneHaWZvSsJYYRrGBIxXcnBvEUBPo7FVkcaZTWkFqPX7G8mwFYo/r9enzVGBFToBeV5e52R8KWzp
#/1A/lfZPKbDU396KaeXK8CQ6o8nsrb1pnzYU17f0Vzd/VR4jM0ZR/XZC5BTqQmpQEievt2jQcihK
#SoIXiaW057+IDSiRPTd+E3bOsNfcbmRrCq29+k6oe/3Tp+nROQ6q2rJ1b7LeelBum6lBphoIlW8F
#XcKYmqCj4QnKNuv/JO4pCOfiB+erYdqxM9I18/cnA93IgpW1Q/JKmf2Gy/xILvlasBI+JK9gfmqt
#+FFQ2C6eYmaMfFtcXxK5z5Rq6Y5LmDYpWShYs/MdQdn+aZrorAcXM5/u2Ecq8CWcZZf3/n+jZKu0
#TnZzjR6OIACZCkYGR6fGpLfjjXlR3C3pWjCB4O5f4dxgLVeg849aelyp1I8b2Lplz21h884RVonO
#T3tGxRKb4Ixi5rdPPdj9YZv0a2GW1VcjRUDZFWQd3nzoC3WIQlxeRRDrXHOM67n3Ilygd+Eh0eG1
#myNCpDlJoKYlWD8Nypt6HamLkfw0PMhwKE1YWwSNd2zKLN+EtiBhvwapIR3O3MYUK7JBWt/ok9mq
#4QmmGEN+TaqPMD2s7Kyrka+YsFyiYZys7bQbMAfeQFVhlBwIGFRn/PRO+SqPKHiBKbSOvf0rQeb1
#ytKlpnGHuOGZILxh3G6kpp0SPJn25ttpq1vcIEMSRt5+g1mTRWGNTewJPhM1ZrKko9ZRXoZksZBI
#5p4xJ1hMs/Uom2LABJ8zsyvuehzddmioyFsvSRgLV3eZCw8eJBSEGEkdCeLG2rVC9xqht1Yc71qn
#mk/kGVjpcHe8xFsfKuKumOs75Jn6hQUbPW33x51zlbmmAwfsTKDl56fvX1hbhoWjUX7+TTKGedJ9
#zaOdtdFVPaFYJe9/8LhoWQyy+/DDrkdBcgWvice+yw2+JwpPYdXPz7eoPWwPqIX70Df2FNLYbw+2
#jAs+fQqCuYadwRVz2+59NsgiwDb+isi4ZcuZ507aEgou9UlljFLZ3C+hGzc+XS0j/ke+CixM28OX
#1cGt75yGrPTZgzdvYeypMmJkJEaptIa0tb/yxZ1DVLzsX2H/PwCgldBfoYLi8HsFTQRb69FmbdD5
#Ts1IcVal7K2FU7YX2ET2aHkCDw2EjVunEZlQ9JlYxhpLYiUlLi+WbuBSvRAOPJ+N97v5gCvDnhct
#PxLNSbkeHd02VT9xT+NYxq3vlpdbFLySr2CqcPgtx4rqjyZ0Em+Kd6DZe1VIreinuO40g+5wZ+8s
#X2+oaQa8kSr2S9u2m6j13t1fyN56x2K1xNyXUXdiXIE4V6ktkEulsQfQ4ozVYefR1vAy+eBgbdZe
#sPvhRVrdbAy97EbKBe857EFlf4lnYiYNCkbESfiTxnENrfvDD5zY8MezWvjOg6vCFNjF/5q66+PQ
#EusYWL6Nb6CHGRbioyjSlC/syykW9E7zU0/S/eBkPaISAlrcp8fME5wfeiyfWUvLSoS10l/o85mc
#BED2AjdPH1ehrwEa/Go/12O1AtjCmUb4roXO/6+Y7XI4thY8+ZK5JgzKh0ua2g+u2q25P/Kcmn1W
#JsDN3WJOvvczXHu78Snrd+8E+okrGA7thB06iXpQB1kxOO6G2/j9aJpklI/5qK3JGx/x1TEbO5Bj
#4OPqMS3+wxhfnL+jUz9oj83OPmzwNRg8NM6y5b4PrSckkFkISBT7vdW8ZdZAg8XJ4f4D1fEcDEAK
#jD20qe8ZK+dMUa0xn1G1le2P24G8XK6SJ9MDykjlxD3p09efFvKrjnKlai6FPECnkwfniC2oZlEz
#GPnCugYaxBWEJieLEKEViOh43oZfySYXQIO5YTXeIcpwt4fWSKSkNAvxk1s4I8nkLh9Hr4XvKb1j
#7ZfOfnvlx3jrucpc9WCDq4RsevfNVrlO2/I4p3Ym5Cpmh7JUVIjzYnrfYl2GCGEgGLljK1Vmf59E
#iW9RJdIyVYnIFsqPNQg1qU6MV3efJ2FRLBx6vCQsCYOCSfsMBq2P9S0Ia3yxANfYeOkxnrbPBwK+
#i1IQW+lnKndePKbpmD5Wj+TC0faOmaPdLypjqrxGna6qstLTMBi0XuHXVVe028uIZ4D7JtncNm7F
#NKM4Us0/fOD1u/vwXImcJzvxw9SushTLZxbTtB8OZIaR2rK5m/TS908vp5waTRHQY2i0liULRvHf
#3TTyMPNTFgjEhUE0e9c/EtcdvcG50Bd0Xnb2n78HFycJh29iS87be3Nz+1rsg/aL7e2AuGAjarIQ
#ccDaaVB0zdMVdjKCcgE2N0jYckvWTctQ/C3/a1B6S04PTunvkxUz+vmq2bb1Tjj00jeo8RrST93c
#7SFELaz1SY/1+K47dd9tZU19gBI+yHIPRh6mUFy+hAPLLtiTl5Vam/gtqMsIb5yBiXVsscshxxpw
#y1jLxdrn1gp+ME42LIvgwyuwn5/YNCtCx6Fg+m0j5y3M1L3t3Ambdx19lZonDSpcW1L41roNvkjH
#8lR9+MX+oLqbanNxx7BmdgjqzMgydqIOx/LD2gl4UIArGy9ua5Z1kU171N40cGE4z4bhe/LUGTxV
#V01th23QyJo0piH4ltmZ/22/l85vYv/KM526nJnan5WI9ZXnfYgvxs0LFin1DJrgSYjzRbL1o1YP
#jv28dnF8c4o3K5hdIaZi7P5xQo2axab0G5uPyj6JiPyhQ2Q1/pCgRUQBPQ+hliTrPhcBy6hAflaq
#thXHIhsvrR+7R+SnNL+KqXaqLi+YU7eP4g5gVgN7xa4CPxOeI8NzI7zd7FpFf2kVO8jEORNrp/Tv
#H6qgkbs7kmIA+iNewoWPIV6eF06UsQgp8ydqczqZoupcFq7Hd6q7G3MpMGOoobS8q9+t7dslOG+y
#0rd1yNX2MV/lpcKP6jVeK/tXdlrAq1JMj6NVCZaUI6guLhtcuhmsb572PPsbbXb9DBbIEiEyY1kk
#P3U7TKIOKhpf5+9rsQ+TvWea/hbJto8hb7N5sfnHnzeLJhKvRgGsgl6sUrqu3hUNOQiJZW0jcfEF
#VUR8xSPc3AmA8Mvv5MmQxu/FfV9cS6XpDecVNXzgwADpwVRVSj88ii1WMKvdpcQor1MPL5crA+5O
#j+8qJXVMTWhp488OZOHeDrU2ZHNpe+l+/IPPM6rUBZ1e9VwWdHl4LMwVdCOHoctztl6Ve69qqY3G
#J1hTPnZP81swTyeBJJgoNjEp5tz9XZq7QI7nvXJGnbytfppXNZ9dhEVQx/DHM2/jVTO/oK4RP9h/
#bhqyrfTJ3282nE4evqaYpMTYJw+4f9/BH1WBXJapJqrVY4tPz6QJI0cdgllavWaTVuPcn+UdLb5j
#XeijDEnGbs6nJoxS5qNlSv8YJf43ClNbh6iQ6FjMYhhfx55iW3OTF7PSiKHhhGAJ/scM5jo7Y2yp
#MjmylV4hQQRLOPqU9/tG892khgtB61s7h1/0PcASptbxCTz0nZPr885Yp0DO1KVydmUvxr02a07u
#Yt/9LO2QJij27iaKmjVJ1/ING8L4nGz94Y80luykwr0lV2PbWmNZr/ehT8HoU9coV/NInKP/S3/P
#uId3UfQIhhv0hdF+9q5j8Dk3bN51+cNLX1I5v8115WhQuxCz/Tn8fgBElxCcAEz1jGo3foVmBV8H
#k33UMfsLWnqTRO8mDAcLqe//OHpK9Qej+N0KDybF37/tEem0tSDkRkngvEl4C8P95llyJ3ECvYvE
#iyLi6UcntqyA3s+ruS36iF8EESW4pd+S2IRJXH3aXvpr3E3FzUs4IH2OGjIvZNXiF3gt+dOn1uU/
#kzkjPiwc504j45tJEGfuGG6WzE3pJb5cfUJwu9gfWPuV5Py85kRwQA5of3ujeZFGq+c8YqwiiLeM
#xHHx4fTMltzD4FA2WarYV9yJqYl45Z2EN4LrWczrFX0lCBbZC2SwIKyECWO3IOofQvL4K9s/JyoB
#dnOwUGDhQCpx9zYtrZy0cMXxsws+v0QJbsfl/6vY4MajTsybnFK3e2TFghTxpLg2PZhpqLaFWaLv
#VwrK1koKu51to5eVbXUqxrjIQcVNU9N1+oawyr/erFJhLPVQjTlo3LwjplSQLwhIQXWzjGMrbyHQ
#IIXEDVmvp2c3YRSInqOYvvRgBkW+lp+vKPAB0vasu6yQQBjkKMTx17dh8RJMN1GTjkNW2Xz2fWBw
#jzvCupYZ9aRSMDNcgfJZ26ag4IJ5x3Y+Ufp9i//1vC2bw+gVOKkPWXWRl2x05M4zgpkUGaywJwzV
#qLpxTN2JucsvUJqzG+mbxMYjvwyeq405uoZ8VvvS6TSgE4xDIlEEuxhcPTi9YvuZBTssaRTTqp5a
#Wu9EcEXRI1Qh5fid/HFz6bEoQfI/1ffUUhGAoMYODQbKBcmLUZ69w8V4f6twl/HA9O3I++d9r+Ze
#zSxc1GU8k67dfkOYPG7CoWxGU79eBnfzgvwLyU5ykDx2N+sKRlKl1Tr41hJ5UrGWMYU4nCyRHk6e
#QqgZxUkwCcdUaalUA2AKE2yoeS32X/40/klBcDF9Z+y6SAsq0yekM4x1GAp+qFQEZ07rKScostoL
#Tu+p+vL0RpQNPEotPRbZ1MyBQMUmkfCTFdy3oCKmTmZSKDM+7OI3h+buD7aHnYYsIxkF1cR76PtP
#Bds8e9ZxYjMWhYqJTF2RiEAjW+7eoi4/nZrOOZMu2yzvyQ8W6pQ8yKRr+11d5Nkvq8Q3i1+cV/dz
#8MuyMssQs0tvmsA3wrBUejAdflBS12EdNAG/rwN07vKtIe9sex6VW5UezOxUNjc9vwSOy8H9ie3b
#ALGReEDH3zr/596pF8czKjd3AK6WnuwWDVOlCmp0rlwmC6SFsepyRZnBbImWnt8sOL100+BNY/GZ
#acSqzR6MjvjPtXs+yXgrYP/TbDcRPr7ZexhZDW0YSlowDS7EYvTAf7jBNVwj4ItEGcKUPW+88U0U
#VKtg2sqqp+SCOY9Xf/5IptcYEGs7uWO8ToOYVRSEC2y5MtaBF3zhrYUt2vlCgw3O8p2Tf7wdsBzd
#/L26Tiw9LZhawkNg9JH0eLNuZkdy7Xv5eJPnS+cmjT1kOIckNlIuKdEXsG11IpOlSzmQXlxhvtjh
#YjtO/gD64geZNVqotmsjU8f29bbhXfecZenbTjcPPTJ6B+IzHuTf9NQnIn8r0+Kh4ZVuEp3umeS4
#h5g34JGET6aSJJ9m18kHpqDvzG4sfdoastiqESaAeAH8fYF+HY+3tCecf6S2ghdX/HqcP9CcL1ZR
#r33zdW3iGsC5nmMdrbnTX7z9R2zQg1dAxGJPF1FXFMwX67RFp/oKq/nmDrg7n3pn4Px36u3Ac35x
#htf8WxauwvfinckvfGLfcy9OP0RK9CWWAZ/QlwDC4xP8CeJfpn56dxtX//reHiLsEO6DUMtof/p2
#OeeSIX7ItpZEf6IWE/eP76Ap8C/fXqdGxz/egy9+chy6ZHUGeZVHXmkqDaCKNRTfbsCRtcmLT1WY
#XreMumL38SUYIZ8bFqIZcz4kcr3RTTjuriwqxbaD8+VRIXWQHWwyLcvENdJuXpOtt9Pl7u+0IRyh
#TxgLGO41BQikDPpkdhNHKDEOXwJuLqmgoAtX/T5fnJWexxc8pdUhjrZ+pKS/SSnWCvVqL6576uIj
#90oCeOdv57dEPx968MLBwiPLyQaZLcsNi7VEHAwVxX8Y/V00L2k4viGBFIichFhYqCy7hBuGIeDu
#VjNSl2D9itlEVd4aS4jxzWWmUyKLI5DARyJjB9HFt/Bsal4Qs2V04FWeOaZm/QiYtHCrGXMNjFXX
#MQ/f0RP5wXfXWtwrCb63NqTf/LZ27cQtr4cFFuqV/d5az0drSb/nLcgr5t7atRa3Ax6Ur1l67H8L
#CHohv1d9rLqfauXJe+fnzG5mP93BCgEPeZq/eeHMZsdnr91xovhML2Eia9NN2Oxlv454D27n2LC8
#zawB5narNGTD41hgMP5MFCLyQjsIWULKw3Wf193ebJHQbbYmQSR+6xnBZkyCa2jFHAs8xzcJPhY8
#Wsh/nA+VbR9YYP5iP/sV6bdEerN+bUKxvW+X3VUqC5UbKQu+cIRduZN7jodUL6mBzwT8yYfsja/w
#pTVX+eyN3z35wLJ4NbdG2kNagr6Xr77d3HtgUZCMQfGT/e/2bu4JuCDAo7D5+P0vgpD6OMtbpave
#Llcpfy+rWHVKuFC+8v1ypepdWdnKmee7a+OPN6WQScqUhOO1u2sTTjSnksjKVOQJIBlHfP/ISMaj
#yx79vVcbax6d/n/F4+2JomNM1/3VgMeLAYf9TR2HF18sBi81+f1LYOHG5OvOntKy7p5DNcOdvWVl
#Xb2a4MVqrpHJ5BqrF6t5ZpbzAN/AJNA3hQIwITd/kbEVYMWfpCJABc+rVS5VQi5YVxkakW0Z3yby
#OSjCqyAThZ2Vcj4buDu9pJRXLONnhG9PJmUSZrlsA35zK0jKNfa5m+d0Ju9s9x1c6+axbm3BDJoH
#UCoDGxCGEj1Jg2JZy3hQzC8wHxTrke4MuuiGZAZdGALeoIsCZPSNVE7LIBnUbmvEbFtVeiZ7WDaf
#emQHKx4+wFrnNF5F+CosZep3/1YM/fsAt1Kux4TOlO4Bcbx1VGkuaivtmLLL4rRW28/hVYIlhsBb
#mG5W+GB4pNSg2UROZAN3h5dMlKZMYyiRdm2ZJikppTEhPUdKxSFlnE7I7iZl0uUCeUUcA7DCT4Pl
#/B3hByHlmvbczc4KyzvbfZZr3UKhqVswg9zgR5qH96yv+PyNWYDGVzOvWxUPHciA6hRrxV7mCKoe
#4O76WsrW0CxTBVnNtmBGhH2qEjMpq6OgkmwjFNsawPIwKKkPsD5BbohjArJh59sBL07sBxG/TGGW
#NinCS4Fl7RXhLyJfwJZMiYL/5uVd+UrIH77U3V6aK98Ox5TvB2bezlP4tn+noi04tQ000Q8SxQjF
#dqNQ6aAEhAYDrGsnUWd92ADCzWqwuUk0ujQrZf+eAxitBm1QiVmqBaAgSiOWsvUvOxT5sCjW5cPZ
#/lm+oVctFejDtk4FuW1zxl4b0aZcsA+UivX+fn4dh4uZuoJ7Gdg7kB4XM53GSMpFW+xl+1FUdd+1
#+6w6KOUdbMGp/I3cVVw1yh4pFyfiRFGXDOmBk2IYijVkooRlImMs5fcIXwEpk6SUcUTKFS3l/MEd
#co/wKCx185WMFDQiZ9woeFvFiA9ulr8Fp/JahspULHs8CrLIpqOLTBGVR+d06tmQXfDSJped0UXG
#Yw28jDdK8XjFdhp4mQyH9AB3w9dSpooaVDG8AqC8lOaIlvQivMpKhNl2+6LStAue43MW6i5x5Uvp
#KvgSToKzXfhdmjXVhz+C/sO62jdcVVwQJ/IhwjdAJkqepZwOpRZvqyrL+BLZq+OlTCosl0XAb64G
#SblSZYfOyg6+lB0KPuim7Z8pibpvLfrUuz9RkniBGRLGsogtWCwLGatXKX+r9pWjyr+fUjlZ7qkX
#cOotjFTd/TZqHYmN3SyXUBXf1YDqLFVXJG8AKbfllFy7yrKLbkqQGHLw2mApDaEXdsZL4ReQkN2J
#5fyMwnpT4Xhiiy/BqeVJdU6jP1jOXf3FBXoUhYlHQIeHrgDiRNShVHdndUpGB4hNGwaj95GXczti
#pvuO8HcoxAx0SjEo5jcoHXBB0RORx6m3YyZu16SBWBUToA5mitRbofQMAHsVs+NvCerQaHS1zP2J
#VPJUXXf/5khvJKpDsjL3F0g/Bjrtc9DqKVe0peWbgOdQAAdYKq0D62pESz+ux/A2ZG5AQiliLTKZ
#kdUtEDjbVNgqNezes2sF4EDmVuG1bt5oaUBuddTCwdqBX0wpnFGY1tHW/Kbe1o4sYpEMuh78rS29
#JgQUc6RCvG6x6VDrMmIFOhtfJVTItz63XY+E36lb+SHQLY9A1tfKEaH88TPAPYN3tAYUu9sYttrj
#T9RFVcCXBjf9LHGgtTj+W8wW/+ytHnAdf6hTWevc0lLoPOhR2xI8mN27sx/HFEhvW4trMyy2LUgv
#tavbQQxk960hHNul+/7qbmnN9tt1Xwfqv3+gxwbO3BSO0K2y6E+knnPXbdRAhqpMz5Rzpb+DL7iR
#ht4KCIv5MUceaG5FwnG28HhlCbk0v7P+6QejzmYllgbAgZLMRoEO3OCg77dMjSszp9s9XsHwmzMQ
#U6vMhdhSZ0she3zJWOtMBFFvchS8Pfpb3xhWe2sOaF2ziJxbXiN6jmyInroLi8HOOLrWq1y/O/XR
#DNZSZ+K70qwlw8FBTY/ybMBhLRNsBgQMM0kuDl/GoZtclf9WoK91by6zilY1MTZ1yBQVsMc6wuVc
#OavU9yocSifzHs6zZ31LrUFh5t8Ba/d6kG1Z9CdSzWvouonaL6Mu7vP4GeYY/xQM228EjB2iaVw2
#jHLr7S/Qm1j41lh7uq3EgyATV8AUfBHeZjREhjZzYcG/DGTqKUCwfxri+tpO/gQYzxCltZn0x0au
#yUumusR3c+nwsLolc6VJgnzNbnl4+a4y9BSqsE5kjt+QkLwv9V9yIp/r5KSPoJRj9CNUbHO5Vndi
#MvxWUl27AzP6pTGM32ybAWPha842eXxO3f7HJy00xaIiatYsAtR96IHhVSyBc3KhMYRV89vFtwqK
#mVasGgekB6fGI3P7ZepikGYzjCIM4x+FMOZTsxEIetpxflMYY7KPO367Gu6fHZIgFCNVmcIpwCYZ
#mgLD4MWHixZVEom4pXhxykgROeoElRzP2yRrMydXvdg5pevb8I8Zx2sUF5wtZGmdhcPPNNOdcQY8
#xMXwCF8ko7oeWRY1B0YPgCrUXsAu4I2jwAe3EF/KTMZhL+5rFK5Romge2fkJcxQvxvmwr17gXa1v
#pVVzyAjYTNT353H8kocmrkMHmD03SN81FUfs+QOtyWbPP39ZeRaMnOtfHYDhgLDjYGCIqJEv075B
#lxf8uAvdnz+aXaoVmRJksHpze4cgrA9ZfP5f0r6HGwL+dxfDascqMuyWRcEKjyyPrDVhNvhYMVvc
#R2aHAw+1vdcXOlidcsQJY9bhWuCeKstfX5NtB4SmHruAHz6xHKMGB5rsFOhjG56ci+JmmkUpnSlk
#wD7LKNm5UayKHVBOMN50UniI6kDD/0bXCAsuN5MuHyNJS4DB3M81SJQx7NgRun2qGr/Sln8QbyAa
#g/J++ppB7Z+8QW9kER+PCnP3/VGQYLoYnDON1i/IZS8+fXy8zLsIuc+C+wOklZm86ffcxXRLtvnO
#RbS76eyk3LY7dGcbTFdvHsdY+KFd2kMMBhrdDIYCj2SS4TBBxK8acA1a6oPDnFEnXcQZp7mNZlYX
#sZjSfZWfg/W5iIU8+rh1NFMtTjTct8cisvpofuBS5zj6m3lImHD3wz2wr+wilvKKkRjNtpaj6cBR
#Gl3gH1d5bLSF4uyHvknwugjTc3xCJhQSNTt38HJWAFUAbeJp3r5WXkymisV4XopD+BPzn2rYtGaX
#mPh/+Gefsf/c5riIC3mQdX8R8zwkW4nrWqCGetfSIEZUbLwP7y4RJr45xE7p31JuKMmxYh63/A5v
#gyX4k69nCRwkBFlUaZCz736mxMWmP2V/MD3bB5hq1rQAfgwPcTE8wgPEg3KRxADTm4ccAVwC3vg3
#8aE4uB2CHxVH+46duZjNZbOiMpD4PcqHldevAP3YOoVvZ2AlzJct5cnjx3UpJfPKHasz/Y9mOZ+5
#68u0tc3KmYssJ+/yIKV5ZUsura2/MDq3kS70b8cgZfeZw0hfM41tfVbOZL6iAveKv0EsfmPGe4w4
#DlokJ5XHcHBwOLSM7uHj52C+uzCbWIMnW/Xqz1duFOvgFbQABNULD2iplMBhXcFNIdLw9Ld9TkYY
#KMwF9AJzboQDm4N2NpKBelxKR3bnnSMXPUfmfwDFZeBfeo4y/zz2KnkiSzTJ0i8W0oobxYxToh8q
#46ZFWFGbAI8yDa7V82HBWv1SDz63QutBxcfA56AZoK9RIA5Uf2cOc1qXmxI5TPkTFdQoqZ2rtvv/
#VBFhptmIWGQuuhLL1rJXQObKPTreOa9UAmfWAA7gAKDTtgDoA+3Jlqkgn4ppEy8K2tgIoW0KgAba
#s1HRgnR0TFwZkjNwTF2X+RCZE64kZFeYY6wXC+Mhq7t6rCCCpGhyohYsCkdBQYPkRL74dQGOMEVf
#7HBlzKSeUW1XgP5MuSKeKef2QHvxIN/O9uiLdZol6RBH5nb6YoEZTs8olWcS+I2XwR0ux6krC93w
#7J6JbQpdrvprWPBuO/ei/ky5Avvl3IyLDxAoGrxNeu8jhnkgE3DUb/P1JWArauAdH9K0LPwP6Lkl
#t1xS/WVdwDQoCDGQOQfPZGQlAcdJeyWERSWntMwkz1x664Hv8APLQyUO2ry4OXQc50DhSC8bPWHD
#EwbeoM6dyg9EOz0vR8A7eNJ61CFx5JOSjHJwx1Ut/zKJbst0R5LIKaKqnyOrvLuYZnFZx8ph4PPT
#o3a6xg7qyZz2rxJcj6d/POfFWuh0VVIw4nBoHNXDIbzNMNXrQn1X/e+VmMthBtAgX5odK1SIxRlb
#PVy/JnrL40Vu5XFveMVrqdPRdIjeFLyPRC8KkD4gfl/D33CR0fam4JIkelDwlMJDIJZdmCp+8O7a
#eZ7C7EPKfMTOChaC4nhqlfnEfCy7grs7/wvun5hkHuwkuUnOJZyfWtB1fNPq453vgZVbpn0enfkS
#2QkLFN6dw8E1q4z+pgFDX/a4IMRGdacGgZ4UDg8cVjOCMps7zhCCWmd2V7Wl0zVOE528IfWsO3Q+
#Q6zTebZYY3tc44jBLdJK8gl97ZNGaPuWTBnjItCfzRjdXJLYIeUJpJNl5JPaD4WAxMZNJ5OFnNw8
#oGL45BmlU4hR7I1bTiuSXKbdccjojvgYvdHRU4wgl7nk5JnRl9WVyA2Pn26qAXLLMePG26zu4IaT
#px5JbV7Gaa8cvKgfSRy8aC7SK48tMeVLPTmJQ15Xcx4cVZ2+jtNZhttBc1qlLzfKEo7QY+K4UyIJ
#nbR1fPXC19a/ftLp3PXW2PHW2O3k3iY3IHkO6tweSqvfuxVDmezSxDk4F0/DM/BMPGt89uDSsrqX
#agktgkHBe72DBJ4Apy8xEhzyZLlXzHs2EV+fM9dn/OBBN4sD9Eyp5HJyrSn/WeWEBJJB1/7fXNk1
#ebhDDahgGaxyV9rZalAgjgUOdTy7/8+m9h8CeoqeeJYaNx88+PfBI2VFT3vaz/ww/CyY/3nEi5N/
#WTgDQyMe/WX/piebQnAyzf5J5xDFa+4DqZ6sl5D2c+hMfBrgJi9ORtUgjuDKiALsdd5eZ1735q72
#UkYae03w/ieC4GSnuPpu757DXvrf+vPzpsaKfMhi29L+bKjox7AlVW+uCfamczX1/U/mAzZZ/am7
#HbFPv0UGv4qCafxkzGofVr0DYPeCwXQK4avmzAEw57DYneI0wuvV5i1Yh3rjEKZ/HD2Yhl6L0Img
#RYsUQZNSorVbnSkgA4J1swZUeAKHQRYwc37k69UGJjtSzwr2A5Bga0nR8adFpxPaOwtCTz8gkBcm
#I2qUGFLrFdSTovUFTcZT0XByfN5htvR0B0TMq1+gS4y8oX8rt1MAB7wBRY0AvLgFWXhjGa5YvHTG
#06LRiaNZQidipjprO15wWIxOdvfFamScFcS1yVzSAdD9gxad7r5aFuRqFLcEOyckR0+H9G41okp6
#51MYsx1tyahto1ryot8k1s7iiNpsZhIsu3uQCYoWkycOxVTBo6Y5cZiWTwyspJhWE/08XXRqfbCV
#iLzFnLHctR8utHpJmvh6XDQMhq4ot6R0vYoFk1r//63jBwacj0TM5IzVKaDa65WJa2RLAszEp90U
#9CZNlk5GkbHSluPneHnTfMc5p1fVs0W5NtJheWzKYJW4Ao4Aa82jPI5L3KogDkbr3WT1BGKQqsSm
#dCgvAGYCky0u7QwFY8C8ux95h9UYjhspZ4WEAYAIfoPafPJYxTamOcBVSzG8Q73FMlJ/ihjZDaN4
#SZvk5ekUawTS1ATDSSXVMnTZqrYZ080Rh4XvpEfAWcmzU0Gga0nRGUuLTie8dxbABOwB7Z1cBTGY
#JewRZPnkTJNDH2cr0to3hZeTC//bKCUHxHohmKh69Nf61qGcm2MwBN7cil5KLO4XDikdmwLewJWE
#OJ2oJm2M0RtTQQE0a2MN81nvNz8gGJ+nU9gL6nu5OmmpHZGnJjGqVr0iuGOgd00/ofhCwXSKkJl4
#CThJpNyx+wo1QcNhhTkgd6/qx4vrRnYWV+iAaskb6EQ08xK0w00c88XC9MjSgNAC6fhHp5KsG6+0
#6oBJtM7ZqwfrKQjOP9zxg1ea4h11jLLDkC06PhDf8TMC+UNKoVY9nYgtMwKF9MjBmsyB3Q//GVpM
#MsX7Pxx3diLMZNLP5gqtcvY626fsdPuRsyxLMNcr2RaN1InN2oDbrQfegPffiFQgXkxG1NbJsPXl
#Tz/cJGCXOuqfxdH1t2+kVhE1FQKK3p1Uk4dQOmNiyWfr6VH1qvcmou6Dtu5OLmYf2X0s61c/W8Yf
#Hhbg6QJ2mrJmFcq02jZx/cAQNyyKg3O7ekAJu6nIMERcYuSOYrmKpMkCocN+irxEpJ96cx2DMAfQ
#y5Knc1kYDwudAUGv6uexujWID/uGLwChnxQSzmYfrq3ECdSlLE0EbTiIO0FdO/SdWNSi4eYhxANh
#x5c65TtCt0ivnxx5ZTi4IiNGa/nGXzQLbc+HAUxLQcc/2kntq38smpYbEDh4nioow/BztvdWPbyR
#Y5AUMGezB6uGJFNcV0dR2x6NqqHQkLC1eguzRjB+sxv+qUX+guu/qoMlUF+qeWsNXR0x5mkTSM0s
#pqpsz+iAoFf1y1HdO+CiCq3yplfLik39Hk+Wm8uexR6IiDVrYpR0x+onYlEmLPnxOvrvjC/71Mdh
#wsmqRlxn3GxNVscV55avhdqk+rf6eG+lFzXSSEbXLGDxMHMqmJOsR9pKVD1Ts2/eulFzK8UY4dgz
#s4AGvnT/Y9IVUcxCY4hlbZGMYvevCGPZvb0xe/ZAaclq/5fg+DLCHWGZDQg8ubVDrSqwF0L1Ewvp
#uztUShu9faD2VSqk4VC/DC6FwJXvG8O0nMSXbAJiI+7hFXIh2B0O2Of6iT9trk9mVnhv7He+nkgt
#7kGeesbZryiVZYFanbp02kqr2hwV3qc3oYFR3SE71BI50x2OAlEPKkKfyDDNBR7St59lUzEGMdED
#xtVKUAR5ibPF9YFvm6BWzEYfTaK+ou9T29iH6CbeAWOShAz79AhhY/747CTd8bxx+ESI1q//qGHD
#hpTbbxJmVArUWCvZkVf6PmpZHyNNTxaY7gfK63bRZ67UZ7p+Szx83KC/QIwtPT4Dcnzpko712hZh
#1aAAvmj5vKITRVGJUTlbX67YZ2BOIG0K6qXT0nIEpjReNtWIX/cpBCN2T21BVXEr3T1hlJ2iazuv
#Z4IqXUQ7k8WuFEO3wVolnmARXsKx6rFeTo4i0fmUjY6VvBb9vZ17XcMZCPV1H8tG5Ynvvr4uJNzF
#d1nMwvs8ZwknHZO/9h3NGlKz6PobW6M+FsMwarb23KXBu7C/GntaH3WYP1fBTKdtPKQaBZoWHGZ2
#zT89klDz7giLFKMxylLQ4XjECDKuZhItL4YVW01WIDtW9Nbf5fHn7QxpW1pp99saDGQ2OZs7mvl0
#DhtpZLU6s8/aC4/yzgg1RsLtRhqtP4ccVn4mTYftZ/W2sOyfT2x8egLZquqINnKLvLpBeLz8itNR
#WUzVgBFr+nDUgAf/zZ0veC6pSK62SHWRaRwFYD08haewXj/NDTUlNb6V5xzybU0HquqB0mPl9aL2
#zwdSEr0K4UguBxLSBNRSbiNTSBOIa3J0UFrXqxGyOVEsLhfq0wqljWxdVv4S6DzadYIoSydn6GM7
#oTRGC0VZruURoyTSkJRHTVihGmapyC9jGfbkTiGRYjAwlLLVoaljlYc9aioYOSASXfg6carz3W5u
#IhVfCei1s5RjryECqcLxpTPAn5IPiFikl5R7o1JDGyN6p2qMuU/2irZqoljPS6kf4kWIFVLpjnnZ
#bJ+MqZ0U8LWVEl02JVO/6hcQs2t1uFPhTnXkDGLVvPE7MgQ5ONkwUhAn61WkU0erMbKIMCV42uuz
#tcPuO1a8TYGFpjlcOg2q2yBhinlbsRJ1M1RMSSgoxe/Qj3jXF96UEZdELaxPPDOpPvhqP/fpiKJ3
#DtbCVjFvF7fstNQnb6qbHw8aZxfOLdGnPdVcDBnKFUz2L6RpALTAMqJP6xOdajpc6VSE2UTtFLUq
#VE11norW6ZPepBLDjy2pyfiXaWwtkm5veBI1Wv10KmsDljriDfMpJkMv51Q1sm4Y0mhiZ0lPyBrj
#jWXEqFafvA+tI8zL2xGzV+w8n7JocCXfFDYOigVaaqwaPFWYVm6sFsBtrmhfW0EFgVgupdnMkL28
#uig6KIZnoMzbgY0g1rdG9qyaPQQydvSsigzu+1BhtnJAUukjqJz5OLpJx2Ri0jHrOJOLOBsbpWRU
#4f7Q2hdtGSfW+uzNGs6qLVEys16cZYT1OsxWRmFKcN/Rl2dztoz4zM6WgUOUAWQyoFt2n/xKUawc
#Nstxhq9TlSWxwxkNWG3vv5dad4jPP41k/f7w4PWlElN7x9vRQSRmQWD/FiGxMSeNzHpn+ucuBMuc
#9elshJ8b6s8G8KcadXmmk9HDKcOkpwS8dFh7RmG0Grl3ZKV7PKSZ5nQneUkodb8UpVJ6yE/MW8LN
#LMQ95iNTUo8G4x68nhNlOReR7l3ASuvmPNwAP2/KPA4xxNhlfrv5ezo6vGtsPaeSmXcRXlZYsIqk
#e93lbfXflNVP9/S453kbYYpsqVC+F3/Skej65Yk7QIcd40bexXQVeObp6PHOwhsRFbe0pvOD5xWj
#R8Cr8XHwwrwXrc258on0NZlez6TveCGW8+BSkv3VO7MY7nVcAVdArHRuhbs8bNHm96m3SrQq6kB3
#UE+aAPpEumi0Yo/h2rkERwwbQTV1kkwTYYioLEo7VE7m4POdh5y9n8pKBc87cda6HNC6WJQIatf1
#CzIT/WJ0nZfTrysQh7FWKZJ2oDDF2+sYe4+IadbP4v8lF4BpGGBh0V8ijpaRp1/XOFiRuiusLGSv
#+wpUnDapWk1q1TWNiKkdc7CWZa1pkq39nx+5zd8DH8fDIC6EXdwN/4iO9bEj6uNk6mZgfiqRki2N
#ItWlcqyHFVzkKq+HQ2jIDa0RNiijZTwee2vj0uqLpdRyXaoHtVnBypZSbTE6pSqrdmWoTC0aEmpF
#l0W0rfAYGe9xetyczvMy/fP/5vB8ve5cfat6OXpHq53t9s7o8m7r0f7cLfNOesglbvawJ7zmq6be
#ccS0i4Ek94RTTFdyUp2uQKZzKjfyjg1wRFnHMBe4zwYx8tS3yXV1qa6cq10ztULbdETPunZcirke
#mx07FrsYeycOGhcdlxkHj1PGPR13Ox4dnxRfEI+NZ8Yr4q3x3vie+Mn4+fhvEgwTjkESIfkQDIQB
#kUPMkAZIN2QCMgc5lhiXmJ2ITKQkihNvJ2kkbUv6Mmk7OTw5ITk32Zi8M/mHFF7KeMoLKf0psykb
#qWtS41JzUufTNqYlpxWl4dLYaco0W9qzaX/SptLW0sPTU9Ox6cx0Rbo13Zt+Kv3E+I+9cR8N4Y9c
#dGIVqRCiBpjImGMbV8BhEBWMEQaFAv70prnkS+mUT3XipLlLAtupkGVF0RA11ZP4UmuokCgVtByf
#HnntN/NdYYtDLrpvf35fRmVK5mVp9uVc8VYwIlj870qNFMsEKt/b/tk9N3BFDVJT6tp9z15W19Sr
#KlUfaTu1jsPfYwa/x44jBJ+F3h5qnHJPI6fZkBH2CfPhxjntXHpuOZ+IOEWekR0XLnIhchA9FB26
#arGgWDTWccu6abG/AiayDFmL/Ab1CLUNdQZ1HZ2MLkRj0Uy0HG1Ge9BdZZvKksryyk5hkjH5GByG
#hVFgLJgzWAyWia3CurBvYkEdXhwV14TrxX1efqV8uvy18lG8Op6M34b/lHCcQCKICHsIVwjPE9aJ
#EGI5kUWsIrqIj0i5pCXSRdJzpL8VNyuaKgYrjlTcI0uQneRh8mHyJ5RjFCTFSOmgjFNmKFcoz1PY
#lAPqRmoytZCKpbKoCloOrZrWTOun3aB9o+3TMfQyOpMup1vojfQe+iR9mf4Ow4YxxTjEeJnpzXQz
#B5hfMwdYHKwElorVxjrHusn6zOpnw9ix7Gz2LPswJ40zxvmG85cLcKVcI3eUe5/7lTvE4+Gl817g
#g5kav5s/wZ/nB/mv8z8JOIIEQZ4AI2AKTILLQmCeJmwS9go/Fv4QEUQm0fviBHGv+LDEIrkneSmF
#S8OkndL3ZP6yOtkp2TXZa7KfcmE5QW6U++Un5Zfk38oHFFyKBcX7Sj0lTDmrXFReUN6pHFFZWkmq
#fFL5T4VTZauIqkpVg6pLNakOUUeqU9SD6sfqbxqoZr3mY62tdlgb1H5XZVNFqZrXJetsurf0nnqh
#Xqev1b9t0DZoDDbDtOEj40ij03jUeM74s0nFRDTxTRpTtanZdMN03fTE9MmMzJHmFHOBGWNmmGVm
#k7ne3GnebN5tPmI+Z75hvm5+av5o/mtBWyCWPAvaQrNILAZLraXdMmKZthy2nLPctHRbflohtz2t
#Cuug9Snr7zZ7217bLbumvcV+wyFwZDtQDqpD6jA7PI5ux7hjzrFYnVwNrW6s7qk+VX3VaXF6XRGu
#dFe/qweqo2xwQ90EN5+STMmg5FJKKQ2UDsow5QhlgXKV8oTygfI/dRf1BQ1Fo9J0mRvrDmZqMy9m
#3qYn0dn0UrqM/pb+LyOekcqgM3IZYsZhxnvGF8YQk8vkb0htaGV2MnXMG8w3zK9Zosa8xu6symz9
#bL7s6Gx59svsTyxxE4tVzJKxLrHusQPZ0Wwl+yD7Mgf44DgnOB8fK+SDFrELRmEi5mED/4wlWIk1
#hEr+IXqys9CCA82gCEqhItqg/9LdRYv2LIchGYWJWJsFLGffs1b2HxtnGqZjL5lpyZIgj8kXCmJR
#VhwrSeU7s0T0hLeEL4RfRIyIvyenB91D6xGKUCKqKE9ULmoQaUTvRd8LIcy8N78X23uscFK8p48p
#Ror/kXBLNki2SXwkYRKEhCjJloglckmHZFRyUnJV8lTyvki8HB7/CxQcEIAcdEIWVEEbDIMCC3AG
#7oANR5CHOreGm+G+84f4f/O7PM4zfEH4jUilaOnrEpU2Jb+UlnipIkM58k9+LQtyVfmO0q08UaCi
#4E5UMY01XIW5WIVdyOMsnsSbaOER4sjiI1gGkrG1s6ZWk9uEm76Qj8mNcp88I1+EY1VWeXLzhaAj
#8AVU8M2QcsgyFBzKDy1PFtb72RSU1FJqL/WQBkijpVgpTZonLZM2SLuko9IT0kvSB9I30m8pSJmF
#zF7mLvOXwWUYGVXGk5XK6mWdshHZcdll2SPZ77K/Uznl6+XOci95iBwhT5Vny0XyGrk6uMk++eS3
#wnn5zTrbOnbdQt0vBU+hqN9Qz6q/0+DdEN4Q35DWwGqQNMga2hreNx5olDf+pvRQ1ihfN4U0tTf9
#yOJo3tDcoNqs2qHyU0WpUKp09Uq1hXqLeqd6vxquxqkZaqG6ssW8xbrFpWVfS3hLckt6C6vlcsvj
#VtdWQeuD1ldteW0lbbVtqrafBdaaFM2P86OnGG7Pt2HMYDIEDBnDkjglFsUtb6MfQg/v0Lv2nqup
#kaAyfWVc79yz3R6oPXC+81iX+cGag1e7LQ5t6Vl5xH8Ef4R+xHXEe2R3b0fvYO+ZI9+P6hylHjUe
#dR596eifRZ5FarFgEbPIWqxcdCy2LA70y/rb+0cGHI4dHhgduH1s6tjqcbfj3uNnBn8uhSxtGWob
#OjQ0O3ThhPiJuhPPnpQ9WXaSeXLv8Jdl9PKVQxeWh5Znl5eXkW+lP99j+cfLLVpf+Uf9Wv+H8m62
#B/bsS/ud9VfBC7n/0A/yVx4YmvnL8OuFn8ibxfN0EwTnLvJt6Tm/KyhFsbTKiq3ox8NHSRS5i9wk
#FjkkMcKSKiUo9EGjtEw7aYbqrH5UHze3tF1aXRvRUPfTP6W/Np4w9gzc4I26SZq7+QnL3frbobZi
#32rP2f8ZzQ62kzWxPsazafaVqazuoMZpPI2aMW/sPNoV3ozpIGCncHoaD5gyptaazPUljb7/zW8t
#ey0RS8nS/WosDovPIltaFOzEbnbeunWHdetPGHzr54AkvoXYgCgIyBMUgMWVoiG0q+657P/F4+Pv
#5UGqwBUHXPHjbwdzL6MA5wNFO+5+4FDv3ve4b+x4sQOWQpAWKtzORjyqQElmwEF2LOfzg8yjOf8B
#fFH5pOfTdfDc/9AJpDrI0UO1/6F1Wz+/id396KWVr7LPZt6igJM7WEGvLgd/O4bAl2DUbeyP92x4
#ebhPuHVvTZmXcBs8pmQ6tZonqwnCscsD5kxJD8h3bjXa0rs6bZLBg07DitCUyoo9MC3Oqei6OvF8
#oxRjgwrO0x1FddWG7OWb8uy7QM5z2KJlvCXPJ3pb7bRJwbeYmMXocKD9atJs+wmNa5TL91rD+RZE
#eQiyqn5vkFgkbLyYUKS++z9h3KzGfPaNaypyMDZpzZ2PU0QIetWqAZsMZnBjzv4i2F6MRIgipDWV
#+8hBFJSbJTad/jMo/XizMlB5p2v16g92bsoTOChGzbQPZ2slzoKcTgDhWoQgIjFCjtZrQ8VP/pP/
#D1bz8NWOjxmAq43MbrwqgH/csXtzU3Np47UUKD4oR/Hffp9JMbnvP5bbXjy3FszZeP498A8QTacg
#aeQGUQu6UnG7s1EuT/PdD0xw5GVR5b/evQa1f6Vbf+IN5x4RY37r/ZaGDCDvPIMVn+r9IvyEDVVf
#nITVR88bi7U57YXKxGe+Oegg5O36tgdbv/SfgxHYw3vvvB3s2cXv4NNQbAVGdZ8FIViGN/0HZG7J
#3PrGk0BAlBCF37n8a0A62qPzYP/JMAAKXQrZWUbMc6NokEulqTchl86pQMu5wm6IdA0OcEQ3sA9+
#+h5YMHRRz00nnRNO+op5mdBn5Bv0LrGdXiP20RfkcfprcbS5gZk7B/rRYJRU8QGX/Ru3JR+ASiBJ
#mu590LLgTonmNYmDUJkeTb8JeZedqsAiW9X3SrUZ5weey7Quk4yecDiWyK0k+SH2iI26jrffNQWa
#xTwTUuHErbc5zWqGkn8zzg/+5SVmOUlhsOW2D0ddiwSnuq7Wirz9rhiYe1XbnSrU7v6ArOYnLGrR
#kiT40zJhKcSybriHSJajg+HFsLMmeRL5fMniTLBlD3soXe3K2w9g60uOStzBE3dIq3oSbkz56HQ6
#EaMXOHXSWw/z9oOiPNyr/RnwHKe7/BvujFd94M1YBzU3z3Tr39CsSS5DPyAaPQeVxybloB8KCqsN
#ULpegd93p9Mfj0I7axoegM6H+qvj0I6c+oNQXO+ehnblPKrAUe34E+TJCVgK1XXgTojJMRdBDe2/
#HwoRfH16BdZgI4uGFGm8sHVte1/0O9qfVfI6H18t61Nd0Sg/Zcy4nqAvLb1ZNoyGIwQ6AZyA3Rd4
#nGfHc/upqxjpcDhRfKThacpluSD03UlYJsfLtdhMl5XPCovqd8t35K/byl0b9KWYwoZEIX+dqJZc
#S53x9YVhHzoEzsH+zDzGE7YLo5QQq5Qqk7Sib/gBZceJa1EzuSdVtyEvmWE9xQIpXL/0/t7WjtIf
#7T+u43W+EzDrw0VCr27Ve7fpxxb2sKaxaChh57bc7ddel5dDld2GDuPa+B50pH5LufNF6zpodEHV
#qmZshsvCipVlvS/6dqTb7U+tU59jlTbECYVZ/aPx5e74utwgrbODabA/t6zlGf+MynhTtZaeZZz6
#u+X0hVmLs9b2dkOzDhrQC54I+fMbPntIbQoB+LZyxm2bV34yumssdGkEbcYeqq05m+ArcEFNcxOY
#lk+/xWtSGv1+r7erDI6alA+WDdPRljn06KMXF/v19mTIR03wnKCTs+k7HMvC5uE2xQ0PrESumQEX
#SIRzwUon6RaPKh0IqtHptGEIx+9l9xGtC7fHp5uVHVwR/k8eCHiTJctJoYmzJcS8geDHggcWElOT
#1F7qUYm7Gr4E52SoTGC6lN3nMSgNLo4ka7vAXpV41H3FEJmljjx5fpEAW1zET00SbF7nTyV/5lnN
#b+qbox3+vmXTxW1jDu0BwiUcU9pClSGIyypxcJu8WewShky3YIDd/kHYUF8MVkfMAfTiecSsqR2F
#I2ohuuBaVgvwnfmr8hGAXAxwJOPWKokCLSc9CnG3dF5DDBBPsGY1pfRTOUT46hHIM2u12C4zlf7g
#0IL0ZIaImYpfV5YLJa4CC8BA5jwt9s6F353qL78hVzAyGHuDbz1I+mDk+9+LA5aiiPWfXu8iZA14
#eRRwx2E6AnIrrR9U2ddvr+BV0ahd64omupEHaYNspF5QTKvZWtjf2zA9PVJ0ruaGylKhRFVCr0ly
#toijm5lbwj188ysY5ZU+FFsPhv0Q8l+6JKSevic9hGzCyxUwx0EmgAIk526xR2qrJq+oXrYAq6tl
#wWV9kCkdOnv3IoJAY4pMryHTIBjSc+L1QQCpKqSDK7M9WJb10GDUUUtk2anp8MIs2043hvcfSLyM
#Mq+P7VO7t/B+koGnH0PYOFzTpHd8kGc7tWOXipwABDh7xIQhV4weCL39ZfW16eEHK4MDxmXIr99D
#P8gRyMng7gr0obRineaeQmEMctht+8MG/KKAgAME/cBbwDvfgwSXvoPNrdg7dbfv/4sNGhTXwuh8
#Mwv+Iz68xQBIaEYi2tO6UfIz8c/evHTp/OdkxJ/vgVnwkXsEeOCAsTS6wMNO3hnGQPTkM80XH+ON
#Ftr9krYZ5AgeeP6bm0yP447rWxxRR/4Z4C34qwPfJVPqGxee49UvGFsJVti14I0vK9abuTViLTD3
#9V8fvAPWslyFtMcaLRmk08ScxZnOZi9p7AnCfEy4IpOFO3Wn5+UEL4CtOoZQg8E3ee0Q4fbyKnXi
#edfmRqnO0pJaz7u2syr1pD3HEhik1pO1pItQMA1LQmjLbt7wqty4vQjXdpfxdRRQsK73A/vGUzWA
#aIawyadvY60IE1UmN5/oiUSunlulFzUIL55P/2BsCwbS4BUOd/qfcmaRZuVfsxTGNSc4j0xHi/Qx
#BS45U2nf7yGq7oYOqmgtCxFE/qoMYXJE13EGPH1CLKSL5Vy6IBz0QbO28HSBHKSzopPeZ8YIfUqO
#0l+Ij+lpoh+mxxo/1aPPKCBeg1a4QnCC9Z+jUhL0VyIhZ1nqKFkGUCe+Lz2TsOgCQKzaE5Pwg8WW
#YIwloSIpKarTz7XHtGORX/feCsF0MCzH+tzcqp9xgAcFXw7BAdI7CoPx8/opJQstNXjge7X7Ovde
#/oPnJyHOTUD3Sq56vpBwBMhUp1uAFjeNj+Hfa7RqS8wrEyFdoxOU42Hq88cS587fK/ZUSEGZNihr
#9o+Y8DUKkTmbYDkInSUmGRg/o1EYWJvsnKJ860jif+HPhuS9Npn2mi/q9U65cVIuB6wVClOjVP9H
#ZkZ6R8fw28hm1l0dYaA22kEgUFN/6ilVYH5wYDR6R0mrHKqBOU50+JRUPc2Ogh9gat9XRdee25PP
#g29/AcZOqSMAoTAHVwzid2sg2kTLxiUMihPI09JweJoiNRoVeY19WbcJiTWv1gSvDVpAw+035uIm
#wTocgHWJAfY8RSlV17ZuLUNntjo53xyM3hGEqYWqIwsrSF45WdtOZd4HqAwKu9f03PX7rswbwOnH
#ouSktSG9F/6qbtZ6Sa30+ZxK8uRm7EcvqcfBu5ezdXxA3yUOlueLX0cC93+0eQGs2mED6CPJxo5t
#ZwqaDREhF0FgubYg9izT+PQRMY+CJfe60SgIy0nAoDaHOwH4EfXS+B7UEGu8eyXI5TPhq9M3d/ve
#yd0WOo22WxFKuZwLy8RCni6ChDoQxCynemJzOEhDtw7hLwsf1Ga1oJdjPu16XTJ7TF1lKjXNTv/1
#q5GLwGFWKsm+9vaZ6bIfPpfRVRTo7wwRddWXiN8ouvypMoWoUb/LeGMj5Pefpqhs9/ke52a14B3V
#PKPRG78mLh/yXfiTDTdyvNKzp3dffnnveude8k3+Y2jbAD3imppK+q2m2JFMhUNBZX/HDhzUd4Hq
#Zr9/N3IpBRGQe2v1ytVOGpXbFaJVEj6hmlp4vl2ec8vIGfYt7jfC41wAh1HboBBqz/0lhXqMF/ox
#78kTMrxx+5ub+B3X7w05pk/r0ae3f5fcGD/HE19sffFQeujWl/HN1w+qzqkzh3xxQCeBcESwUC5O
#5ntcNCbNEoJeLxczP+8m5fqG/QQ1SNzvSmu7i4sHuUyeeB/fpssKafGe941blDbSKwiJ1WVxzOX6
#rfPqdHNHpvxm+VHq5OJi3FZppFI4NStgY2+xUrjPUxKGyzetknR20H1iyqjRPG8ACLJw+qmwEoW0
#o9AAUFwj/X7HxXEcvquuD6xu7ZL1ErfIu3kIqyEYoeUKilgAfOsQvCCpa8yq+W+VQ6NQ0XYaksx+
#O3C9IBziBjaQ3Q/F0BTSVBJ3s0allfKJYqwvK/absu8FZw1NU7M3C0+jJy4sxKyVRiqdpGKJMOmt
#+mOgIg6Xrm/D8ht64bRe/0wB5Q3MC6gRUiw15+U6GQi4tX/wu8YfFMWeQSFvRiO3qTvMvPDGg+0E
#yI5HFxALKFCoS7w2iLJIMGnuyNBfmwrXcbOpTzfdleUHQdlDz42HLQASWtNtGFlw69tsK7IgBcVl
#c/8+rqVWS0XcC63+/bEzc9S87uaNUhJuvz6YkggTxxqJmHkRpsPgBCKoXFa62eat6uXN5b2gvMn8
#d7ORxz/G69ibalwpG7CSUs9fE75u6+LG5Bo7u1E6Rz5YjBanrw4TzTShWnCIhc0kaZm3tqEvlEH0
#YBpggz5l5xi2usmZd0vE8xYdmpFHt+V4PgbGL52j58VMZq2lAB4R4g5mO+pQVfnXuO4flbz9n3wJ
#ST4/iSfH9lzff9t7yKMXYmDDCRu/qOMd/tjbcMFrfMXEyI7rb/3uU+Tp24NyzFQ4V+jjLxY0xO7U
#cvsXFh7u02+9uGcSWaDDM+tAueTjX3gD9/b97EIsYGjJaUNjXU7bH967/OegcOBfANpjEAFb4O96
#6NuHAiTdtzdhYoYw6Y0vIUtV6Xkd7QK49u1kH8gyC/Z/uwxb/K8vBinE2D3CfX6w4lgCklbYFrw8
#HySW+87c/QGw2KnqVAok4xXgKle8SoDT8WKwyU2tmJsaviKadXIUD4ri32msyocBVIeqgUkxMUvy
#o0vkBXTJnCL0OXmC/lqEEVykkYftJ1NDFhtr5b+Um9TlPkt3TgZAqmL8Yc06mQ0SqRP3aTaFzG1t
#3nJwclLVQCLzIngdgzAjyJOJD5ef3B28ODsWYqoB9n3m0ZwtoXSwX1F+psl962vNwNcAfmCXDatM
#2+qeeInlo++inBfpaxNmRNqhF4pDMLp9SFx/YdlxBgg9CenPiXIOhUX5FaWuPDZbKzzToLhJns+j
#j+QsM0rNcvH8z7WVWmgjvAAcAI2uyljNev3Yqyy3gXK2uvsfpaI8UKVYGmoT/8CVnosXAA5gKfiS
#adcok+8tFjcIehgjWf/sE5jNebgFgtHdHyZngZexGN0up9535o+OF3nmU4UHn5kFDoRI4KZtAwld
#fHsS1eZ+3KdRoKDYe5G/7jdPu96xs0GwgaZ818rF646xpxnLqulEeav/d0Nlnn46+Bu9D6wQv7Dw
#klfpvq/Z9dEfZXiDMGS/nXDjYpG0A9wwVcDxHaGfG/kEx7Ylhky5H/nQROI+/GjxaXQF0OCRtc8u
#lwZfm8RaMkv40AYCKv+N6W/wuwchYGeCwIXvjj7Qd5x9zZiKUcbWMyP3U9D/5k9QJJrJb7ADUAUQ
#dkAJIvrlJzWx/0UV7/AzIGdAffY7rg8dBN7DJuqxizreaVZoNvqtQVPuc/jFO15HXv5komlIrO04
#ciwRGOXlJLgDoN+RAwCAybGJDkhaxUgB88GDfNsm8vkzYBy0cZgm/t895HMnGWSEx5hzlePwyRga
#Flm32XskAag6WXL6MPLgSXqZYNeKM6eRf13fxQi7gWbSFmXPYnM5m+2/4yMjbW3gOOj4baEzLcvw
#GeOq0AeN9RSaxWCSLNdqgCWgUydLU7v0cioCfNBftt+OXvSI0W5mhqbBkbbcNw6y7dPKNhVZkIlG
#G0ASmSb5b5QOYIAGcBdwz8jVffxarQoUNrZ8gbd9Yncx8Z1Xbhzp/KtKxRt4wvxBGu5DErATIuL1
#FWRw6kXQAPPunn1917u29xUK128QBS78X38D6Bol/oKPybyZsu9aKdeufOt97Gb+33o9T+0p63ud
#8CQAHRRMwXRBzb63yDvesz3O89cNV8/81g44AnDCg9QD2ANmAsncXmnJKHyAyngb2CJ50jmXwMhS
#ofjyaTbPpBJ0XPaloHPAHl/y+SRCrLsBiNcWHGDZD3cUfQ1r/86GL+AaIH9czSIf+/OFm7dJruEP
#hSOy70mti2y7ryu+eMwpuIOtpAv2pWDhMUK28gt1SqxPwRcQY/+dyj6agHZVfU1LWDvkNl18a8Ym
#VrOGBzkJXkgSrMP4V//+8U35jj8ch8+ADvg48I7DUQjclm35q3/4AFiAMuDp4W476QYgkzkgiVGz
#YJHZMEguhBzgKd/6PU7KpROZuC/sk7shUvvIvJdRbEG1ssg2pIVChXV01x6pTxF97M9dgcccnBDN
#p8Oa7LbdrNtVqbKTAey9ZruXX5/nJ2AogjLrx6rRPYi5zA/eCoOmpxHzJ5MTkJW1Sxf+WkuAxZee
#R9zX02lkGViW4wJ7uPHRlX24knAQgAH8BZMmMDLIX3GhNazOYU1J7mkEJ4CBlDTaH350pw0KSMUL
#NoPRPxiHB77QSuUn58pH6QoCrqrndBa6By7qBwKn28VTSN1x5p5thg8cfwPFoxuNgd3Pb599qiyT
#DJ8xzsJ7qKhGKyaOOT4RPI8axJfu3/QHe9MP/T07tJchofbnKLCl2FMYfc4X2DFsmkrQbEgNRfXw
#rtru0jR3x0k2j/AyCYd7YUyLZiM1PwkAzf6Hr2/WMOBT+7fCVTR/fOQDsydOScNQJs2tNzhEAkKV
#xY2qefCdn+eDLFzu44LarUw5Q0PycYqePDUPm2VFwGhaP2Lt0xXLFEEhxTGksNHbRj8PACvU5OjO
#O84reUq9KMiNbf0nOg2IYIQxfrKs7q3onu8BVPg1BjoJ+MJpRAT23xETLOSIPo6FIFhJgWSfck7X
#zjiPnFGb0DGqZ40jZwvSifML1r483bj94nft9qk5QnjxJ6k5UnjxS/PNNC7QB7SjnI4mQAoKkDCY
#yCX91ic0eksKe3mwDU1FGM4NwBbIyseJukI2CdMhv1lpYnomu4pBc7IXha1XXetlRau+WbRXRyNb
#USXtx2kNWXuy39N47+l8q+fbCF6Cz10cA0gZWd5gJRUMyTsvlXXFs19uN3RuXOzcVDckNzdu56aa
#Vu41QGhdUBNhZI1EsaGqMBHXBzU6W957cky0Lss7++C2/MRrbAPtssF3M0YH1TG5mYF8YZ82/pp7
#Ssfn0aPaGglBFSKACQ0h3Zkfa0L3dUyfINIX4X0vAERtXh/bvrRYqYTc+xVxMnJFU9i/XRKj64rD
#1lvYonisSP651KVNdpayHhfC181SXN+cWXl5rv9FyXqs2KTTHVccYWwcNmakAE0QaMvx/lw22O4e
#wdetr3pTk1J4oUTeHQz4waudAIBh1QxExJvJ1+LJp5YVROxSrHwOh6FooHk8uVhFM1bLlPbpJgJV
#U/vssyYwXpNqarWMCYX/nh4+tqa2md2kjID2aTWck/1azasA+ct0mi7US/hVaZlUhPCkeJkLKxeq
#42ssO7N+/0UNMzMVannHVweE4Tc58bkc068xGE0mEVeysQaFg8PDr+LqBZPjiFaql/+ranZFwnkm
#J2g8WnlKEvr1RvvywPfexVFTweEcXx0Yhd+UqZqc4sk1c9Va7fd5lo01TOqok885D4KHBvcIK4QO
#vYEwNekByKz4S3o/QJaymADRSazKFwD0FDIcpodMX370QTmb/mF2E/oluZ9+LtL0q7LcfM32oLoV
#CahLHISJ7lisg8Lgt3NpMxrbEeQSLTjBUU679ltNyUhNO+d+Ol0oBwv71uEM3K9eqmu99lqkJC+o
#w1xzE3VrNUlbN6rRcYSpSOMCTXC5nv/FfExR8yf24iCJ/pckFzUxafgnUIc7krZe9Mw7fDE5YrNC
#FOjzsuGfZCLC4LC7tGCqJ/JgZP7ufrYfnbyXC9KfRWNzTYZOyXtaCxtutzpOkxqHWRoPu8KOoNbm
#9cj1yME7w/brb4ZBP+0oVlx2fcWz2FmqkPSteL7FgpnMQQtLKPWIklLJHMA2Xty5mlRBzncktCsJ
#+/UWCwwJO+vaHKCgNYh4sReGS7m4gpSMpkk5/P4Q7Z6VO+aJl/tM6aWTrIOBUYQDOM6cuzxxWabE
#92xPuzvVWu7UhQhqvILdetu2CZfM0IgI9c5yK+WGf/1rE463XBUZqHeSr7dmxlmJXTf2SK77fFqb
#X9KQugr0WUOYXwtS7lD3l/dOfJ3jXhgwaYMifsneWhmTFcERL3b9IzhUUhDYbCuOgzaCCkWoK17f
#5c2Cwp9JaCwJ+9FF5eX3Z9iR6ibuYXHUq9S1lEGznGFVnZOqROzx+IyMQNMkq9ROJqp1sJe2DeTE
#tMaViewj02/eudhYW63HMW0ch5U6mD+ZaeXqK2uNxcww8Pp1E44biwVrQf8VAbMMHiyOGdTll5eR
#2YheEH+h+8z+sy/1RaMi7BaXxFxX9Mca/7pH4r0xdRsO/Oh9Pf3/mD01pwVQGMjqIqGfC8zvrQI9
#8Q3j3rAS7avVG76kDtfeKtITXzm+2qtM+/I/iA1jQa2Kay98oysP4D6U0GwmC7DMZHVuvLXAvBmP
#6ocakGaasKjLL06tqLviKTKXvMaK95Llmk19qAI+gzsz8tRURueJr+25KGPcHj4UaXaUx8Sy+5jI
#onap1FbxSoZPVY8vgulw34z0TjknfQYzJnG3ctrnNU0XcTgOrYneexfct0YyXUCG21veu/6VsPrc
#GvgK9kDylfFesIw1lLBeUggnm23FEa648AcLyY/aYV5Bc8vq0XkwFfa7icPjM/6lXoSmFnYC8zwF
#hNfPe+Ob5S+3BudLDbYNWxqlSdz3CY0dnfSeGA1YVkqu2gbyqX5K86GSoWe8ce0TKPGkD+K9tnb8
#H0N+2myUj4/BEATKatFldEn/v5JQanF0i0hLSyf8T7fG7J4Kn1cLpVLnMNz++IIvhb4q7sE3brAd
#cxE9Tve9df1Ka8KYzeLTmO+KvnD1N5rc0zF1/cKbPG07eQogYKybvDh6e2PX/sv1QagoZglcc3OB
#4Ysgkkzr0Ucvb8i3iT9k/tPogV/Q1xgGXCpBI+ZdVpILiOIDqDs6d20/eQXOq7qxnt37lFIvhDdW
#nLCLHbPYRWLf3rcnf/0/wd/uLoGLRDXYHYbiyJnoMVR7mlgZ3SGAi0Usq6AIJp9tCSehRCKaqr30
#0tHFGwos3g8/NdX1Per/KAoMIGiAzJBnNxA4rJrtc+V3E1egauW+8Jf7Al0QLjY/buVDc46rRN7e
#tyP9i2cjv95VBBtWhVmmKJYyJtM7VfEZ3vncaQvgVgvHKtmaCwaO+PD95tXmZcmq+9c6AzZYA6s+
#eR4AnWKLEii1a55QIS9l8k+ur1eyspkaSFjdDTezhWpl/9vgNSTmEuOL1udpnv9xmz6vj58TiWSR
#dyPpcihbQJzD6XRctGvfaKDwhg34Gi43EKy141OyFkBHW1wUwvUOlo0d1Gjk1XQgqdRyUlURqhxf
#qR25pJ+GDN1E2171FvkB3Jjjwv1SLFTq9349uNDpW7WIgywSo2d3IrpyjzNQbVhAWqramb7M4mez
#mrDlwCVgLLZniQr5/CFKswmlRRKq5ZPWztieTQW098qkQqzHaCsNZCKpVHUoW60X4DRNrSQhhH5p
#zA7pSU6SdtB6nqSorxX6ljx/A41H9qJZEXFyG/NS2w9JHesVw9/bgI/hCgNSrqUlJXG0TWliJZad
#tZO4M7xrKh2JMapSaClCQ+IlKTRjM0JGb6En3ghnbjVHKQ3aoimmu1T6tXV1pPppUHISbo+lqKhI
#oXpNqwyBfNtu8UO/Ju55bwqcge015NMRPBKjpKbikcRaZf9l486pvWC8UCjGWJdO4VqII8JFG94Q
#B/Vad0fWfvJvvb8mTG5du/TKXysAVlorV33yUQA9tjCB+oasjzVYYB9Q1p7QVhuwieUEOYb2um2d
#PtD81tM+vKW4yQFyqqJmmes/iJAnl9b1lXsiDhmLGME8mAJ5oJxwOhxvDYDEzklw4Ib6UG+qEoce
#fixRUUjHjOqlshGjeVjiMO4V+yMMKw+/a7Kmro9xE/dGLmso5LKPh5fGA1F6GCoFHHBsm/YwQ4EH
#gpGhTcjD2hv3D7xl+vQqi6E4I090tyHQM2PblXdzFZvlycv6bkitXW31NnmodBgWvgzQihpUtC38
#ZN557ZtEMrgn9N7fPvnOuk2QqiD0wZXiQE0PnJ5R77rxoXeHUpngvN9Ry7GZmbOvNwTRb0PHXoD6
#x5nyzHBG6J9Awd8Av5eeQSonuXhEklesa+fBkOoqgHXzJlw7ZwZBxy2CIanFakxyw7KGZG9THikd
#bnu34dDxViETiz6jtrZs+TrUESMclxb+BjihWrKgQgtQMV52P1opAdfAfmqrc/83Sjfi2xNDWfQB
#NXl96dwi7qjA24Eb4LU1Vo+IsYHpjDR7H5p2gcLluQNRGtHdbfg7dQ2UreecizzuxqimQPXYE9C9
#1nohXkG36QuSbHbstn0hfQDjfv+qut2NZsbty3ROan0omFrvZD4un/HOO9ldu0c4r3tRFPODBKhd
#799vi5Db7VWi7DfB2ZortLXX299lsNWzFWvblp6xmNlpcexRV2179g3UEnc2mQz7Q3Va7iyvPKsF
#x1rT3T5rmg9JXndpW8utSRPsDzFQusSvr4rqNO8VNHaoqlLi5xxoQuvKdL1uhs16Xabr2XmDaKuq
#+v/+OqrGnFouy35TFZ90jr1hBkBjuou2pvl20esqbhbcQgzkAlmwNaE/j97wPYEfv6ysEwUe7PZy
#/IG8M34yOA4gZeT9mz5mAkYkKzP4Q6+OG8+eotCHpCf6bycsLD/I8vhipmyDfSVuQHrZ+l/CUg+Y
#gD0bWK7AYn4zvTKNObe32jfX8wiVkAV05IaRv4//mlDFvrVXnPlrVUCE1GYRPC4rHfE6qkCiPyND
#BDiiEzBB0Jm4HQz9oHcTnfRJg1PRO6RO7zCjBaR3mqkzeo/spN8WRHMv64BjzkgMecEYfzRoZBla
#3B8+C0sU+7oikYpjEPf9udLVNRTgIg4HbRAPgrmtBcu2a9lAQJardnWwzae1BaXzZS+dFqy/gH24
#ETyulZYglORKaG0f2GsTXAAM14PLbDNLHwPLtMGFhXI6k+SGLGCS79By6xgSd9QfzfBdD1ZyDJGw
#q7yh3R+FviySMbS9LO/x3XdTGIjvJi5+N1+Pso2GUGH1NUS2SJtm9139gjaQzJdV2fTU+1a7cV2w
#6UbnD0ugwe7ZbLQm4YwoKoU65RHrDCHV9VIjdNc9KpeJh00qu2frh1+WcskAelpWDR48jVacxEcZ
#c3F10O810gwxZWuwRtddRS7QF+eLqnRS9WblTlSrioq+5CWEq7mWR5bit101glHQ7HKQVPDiMy0j
#Uow+grEmII0cmG37zsh/hmTC4n3hrWdSi/aKdU1gV2RelnLu9WjFfVaMJCaO5uaiwF8EqkdQfQqL
#/PQXS0AiqswgQf3pHtAEBDsgOA2EjELCUKB3hxkQ3MX4fLDih8F01P4G/B6ZNHspo9zVgJecE+dq
#/ekzpSf3AysfaCrc+P1vbTR+Y0AGCoB0EZkeCLXurBZfP3TEs6ZSfzGt+/T3twt76M3OEfEI1bG2
#PbUv+V0mdbkVEKQg/j21Qo34KPF/pTUT24SleyTH3OJB/BkDq6fxPjWHxOX336a7AYGJSvDSwbf6
#sF3TPiCHAMj4wbofrDoALgMZh/2/PtU3oT9Qhex/R8Q2TTcx+tzN9Pf7mKApGIPwCiKygfARtz5w
#uouhb8Qb8UDl/pRsidYMZ7WBMbM+Ff2WvJSuFDz9Z+luRpkFP8p4WIC65/nxT/zwj+Uv3zwsdvTg
#gB48CR+kCnDIRIQCHLGa4AO5P7ni+icu5NfPLQLRAjJvAKGuF4sNkpKUUUHqZz/246cKv/WVHyp6
#wAFeQOUNKBncY+FtNV4fof3/2b71lfev/78EhGmGlQNoZ6KmpGQwmCrt//7uXLyveALsshnECnDe
#BxkjIi+l/vJzM83femSgCx84AxbJlwIoOBvOocat1e8iX/1Iw/VA+k0DsAoQg6GoAil1N6rOZkYF
#7//Z0fN1oEpZ3wfCN8u/8wIdgCX0HAfM4eaQDak6OVLLmWhQ8J8g6v3L2wYLSVhzabrjJUuPR50+
#7nL6+B37+DNb4+Z81h67YB5DXvQX3qaNxqWlZ8icP4uO+1z81NRTnVcjt7+/7SDm/ThQUmpQ91af
#SfEzTF1SmEeFP5cwTvqTU080X40dOLIFuT8F5EWtA2Imlo4I2wRZmTe/0TztC7dmr/rk7QBKs5kJ
#uG/mYFd+zDyY30nVJDuguQVqI/Bp5nOBcUPEowzb//qk2+qtmUp5PB5yWdHYtJz5gbETQW5f7Tch
#0q17YKKR9e6M7uOGppjyxVlVomCAEThurLyDeO5+mOBpBSdE70Reachumt+7Df6hY1oRQx3fX7NQ
#bipkTcg5PB702P00yb+7prIlfo/FRxd0l0CUomk/Hh4cHY19cT0B1VzyrJAcakc0ppX6WaLscZkk
#rl4H43Cue9FzgXjFZDZbRQquFSbfcqUL5UZ3wXAEHuuEBt5jU6aS0RxTJjCjS5gDpApSrTuKrHR9
#BGbnTWBmQt/368OD6Vb/Czz5I1wDBViHxax5efiPCUjeAzY2Qn8zeVTKszAXTb2rdB/7v/m1+jsM
#Gf9Gcmsxm9LUgY7Ru1d6/RJ+K3wRqEq+kH2TNx6R10pEozRqAR1ILIbeGJKUhBYrOomLhQYhOSQ0
#pDHgjxXVdFAyG1taLTRM5cbtBsl4ygS5Xx64ts4/xXJNQEJiA7tBM9YHe7Qnu7WmrPFVrFVPtHnM
#8Cx1iW9qEBqlrMXc3WuPPFD6sNkKDgoWnRdB9s60sfWGeDPUERUbDY8kN6EwQXpbPhHNre+4c5s9
#ODyvq8me3O23UfNsbq8QiKbRCTUbc2dhKqb6qGFDMD1dfkij3x5mVjWk3DQBMtVMLRpE+awc9izk
#oiRrutLVkIHnJmpOhwVX63CZB7F6AC6N92IeDwSbHPHHA1b7U9OgEWYW14jRJ+Cs2V7zS3kc4ltl
#B86UNWioqLexZi+gjfGipNa/ddKWZsdk9lTiZU3P5w+U/5N8Tk1vg/1cbrZawTkEbLOarzWyb9uc
#Q91iMMzzrdE3N48gbhsJY+DfW/Cx0QstgLqjq8DDzdIo4324t/bokEO6BBz0mKs6ra/0+VXG1nhY
#8DczGwwazREBuyzWfPgMNaO0RDGykn3nFe+zygjrRs0xsU0Rqc3z6fDpowh8/YInyCQ04ff92v2G
#5m8Opx0n8Igi9SvNXFMQdk2Iz1uxUum6sTwti2eYFzqRfDvxSDRdaQBY00uVCREJkQfgLtzDHWJO
#pJ2HRsd5s9I7EI5EcD1EJnVHsplsKzvjyOPe6wbacMSXcJwZckp9qjiKlTK4PxRDrz7zeXUvXF4b
#7MKhkP872WpGw3cEnxJHyYxp6R4hHjd8SWIyicSHvDqrw0ISpeFYJITEcgFAqqo51mpOrnqVNM7d
#xMmk/tzxaDKRVMRYAmPJsDdo2BvmiOBQ1bMXog5DgTlL0PlC3Q62NUWiUg5/mSFeNYmWSg1FxGgn
#HzcllnXReeWXMbe1iIJOMPXAiVeTxcq+C+a2N/rtK/aXP2jomHH4MCew0GS0i1qjpTdBuF9rnjax
#QR4q6yltwE977KTSKYRkxR8I96ssRcr7InKjP5tdzZdbkttkoP2rz59FbfIw5OZyviOosxU/9Ww+
#ly+ihmNaPbfYoBomi/M4kERFKzG/RaWiMPpxl/UgCt7DgUGUatJbVBtOYJPteNJ4wTZnXERBk6kD
#/kiKTMsTnRbvtq4kwvtKP8kXd2P4WC3zgcC1/JrDaU20WAH39Ny/qpHirnm00xFXxfImSJLOiS3G
#n2VRlpWjC9OuPbgxoAqnSOd5vR5M61ii1zVfd7kdQjPBorRdPA4xBwLgrWf9IBgZdYxV5NBw1O8U
#irAAGpCEtZDA79Vf8wEjkINlZYggZFwIjB2kzGnUdH3M1vYxSVf5sSDDUJRa+6HXyzB49ClJjyye
#lXPXYczfXa3XM9ACdzbawqKqJIlinonMqlo9eafOhERPWpKizMugj2yD6Vw+ssEpMPHDBH5/IPhh
#ocCYjftgltnr8zPfsL/QQContST43MZnj4prvCbFXHgRxd8GFmjTkUGc6w8u4u2eJj4FnBZtlGrA
#GC4d6mC1AZL/bnn5T5d+OX0BZcsL488tADPIGq9T50Fn0PiAvEi0O6jq1iX7eHBeuNUB6fu49Cko
#3PNVfS0nvJztRqE4QgabBKyJgwF7McQyvL3GOX0CTH+A6eCEAxQ+ETjO9jeRiOdtCo9a69hzuLO5
#qWOSzDWu00eR6U/mEot8wqov8/sBdEfHiWHCzKWt1Rc6Oo4cmlp/IABaL0oCSgJkKHeKOWDv82xP
#wxVY/3C/eQwtgK8Q+94b6pAU8AcDToP1TUe6w/oUK0C+4w80/NBE5yTbDmrh8Ux3AJlI2pijOYFj
#y1e8jhKKu48Wcslobj6YUVveYPBIioC5ZMS95DEIC0QPCtXZhs9m0vJIxGNEjmyunxV5OJyrDUVZ
#CDIM+67WNXjs+nf6C77+j2bfPbjkA+PUlva1bXt79uHStePzBzfKm/XG1pVxER2096WopCIWButV
#O8kwo3M9uz50HvL+aIid8Af2xa8V1doIolrojKei7MeGLvRkMu3xYqmSQfuJ0/ORSH67KprrbJIR
#pR5aENJx/v5gpJosd3aw3wIeQVyUz5g4IaCQtpvC7PbwAjjDMa/LQkD0mVRTO+01G0ooXPfSoRxO
#0gAWBpaIbBbAxhxjyKYEqjJuaP9Z5FzRkTaISMFtRVZG05Z2/4jC5c2rHo8dTOZWTwWDNwki49KD
#87c8LleQb2E3QzMUarI6pm3bVjeXDAYCUaqoI8EdTWhemwFDAVHcsizJ2WAollb6ne28kaJp6I0A
#HTxHdBBKdzrVNk43o+kCKKkpSyEztsYkzTGzEbJmxrqzWUnc9gNVPCgdTCHOCE+I/SIluK1YYa4c
#+dzUfoRQFcDm624iyPX7nyBzsJGKACnc+mcad8/uljr9UUbiOU4tT0R9dtt7wdOoPmmaDq1MZEHp
#J9DNdsNDhAgM6S0Fjv29z4kxGte+0WYkg1Df6iK6kDmaulc3OU0E76Cn/32vxj16G9J0NpzqZDwe
#hpwOZ1KhH7KygYcDeHqourhYsHkN6VkFgMsk0AWBYzqV1VHItqD/WFyYaDY6GI/PThGwhZPhX+l9
#9WOQZ5tOfJpY18804KPmU/NPOnBoniTNGhojwa+eoJNf6oAADAE9qYSXoxeNpvDOGks4HtDIuZGA
#9sliLwqThvh2dsEIfHytmQbD6RUZ7wjN4SihGd/FIt/erbweLz+zgl9XDZW93Pv+VqdLHgNfFATf
#3ERqayn10VrtQtsX3+IiGIOPf+YQAREAZWRmxKtXG9YIgU8TxWTycA9FEnQIGwGD4KlQSnHXUkQ0
#s4lEozdfcgxLQx8c+dqFbY1dqfQiGAGcH7nD9uuh541SAgftw//Zpzn1Ymbolte4nCGxND5UR2IU
#0xeLJ1OioUfqsmF7SXoXPv6hHJb0zPbZiiTjYAzQ4XQTbZHI1bqJCXDh3GC71WciSN7pej9ZIOg6
#hFIl6IAV8Sf7rr1PvTaF6gNb/iho14m3fWJQP/3IvS+CzXhh46Xn+G3/gek86ANs5Q177z1yG0jt
#9FkQcL7+Il8xSJf7b6HNdk83PKOmUQNcq2CuOuHZmkOHmioQ/iS+G9858g6/QGfNM3R4RraBztg6
#fywCd6ja/8EHA3408YRve99BAPfn2DkoK7YzS2LSJiTEthN8pZfA7VOqVZwus7yKOoxMINqRFhxK
#chGsvutpVa5LFak3xwNbWRQ/vg4AE/24ECwUHy1UI0QZE/BxOWVdmle9vtj7Ucr5Gol2TUtgBMYW
#g32+VE7KE1BNk6HEK2w343RcuIVn6aGJEXj4soFC0vELIsLG0uZ2QWWJxKkymy80WbctU9XG0pv8
#luEm2gyeBS2oe4SYORJBm5jeZes6QqmDxVgMO6PkTJJPqmygSwCltm686TiaagHNLq2kLMuXqo88
#EnjSrwf1qS5mYuYhTdabcRqF54TVBtBUhps/3LoVWC6rqA9G8EgYmfpsdQ77m2oNaFqPtHNPQrQQ
#7n7tVTdvOZEOVGVcAmq+EckuBXkIIjckt+c2gwlINCUVc1WZ3m3zwwLgo9XGs5/iohGQxuVaTFh+
#3IMEWEE9xyEEUTGVui0U8GFmZKtO4+XokXxfcR39HjMwxDwWz0oVIcSyzyAVIjSveppRwRVqfhrv
#o8mHoMZmpF8DwzCHuVnunRZkmHW0tek+Yzo7PyV57EjjiwM+jgqlo7+g5zR20SdwGI/eX7gfGcAN
#4iNGGxAwCO4CbV/kX8+5Uum9JfUzJcuiTm60Z/RZeSmHAtuVNF0Qlf+TxECn+HizUju6H9VjBIJs
#aszlAp35PIw+nAc7RXHBcdI61wnIL/rHDDOW1/pVJoeNi7Zkzz59hiQBXzRIcxuG8P1HR1J2XXBv
#4dj4O/f0Xh0YhQdKPs0I2sHJfQUa3O4g07G9E3SztbJazLYBWLA7I+GN8kJ1HI9aUI5XvR4KHIGz
#fl43IEkltsxxywmtxUanNm5ZAQ2pjvUDS5vVJYXXoHtgxYrFs/ErjiGxaGPtlDrZ2mWyO6B+cQG1
#gh91eT2oGksNfkh3DMXa49hV4zUjYBSng3SxL9JGw7n0TdHumHdLGPBr7HEntykOSQArVGX+3Lzb
#HeUtF6yU0apYraraj7sQvkCujkhdANcTt/HoKDbHkWQk0OCfY5Sep02oHkzQMIhM8p4VNnMTL/AB
#CP1vZuwf7QR6XBAIUxPKuiKSADv+qhMVQPWx26hzE2Ug9GTruhm/7UkeEKspbKNlznTJYMQ4w1Zh
#M0qeOj9z1rox9WHERpJsH4dBmwAoxEDnoxdZ6UvHiPAEjCEBU7q+I01XFCIgWXENwRcrDL1y51l4
#3XMAffHJNb8HTQWJsJdlFpJ5ltIxr3FdqwQgjLh1j2cAqTjOKlkBLskOfC7dkf+q/535xdiFgRL8
#xokbWml02uzbIPByflGWJ879ELo1uwW9YCKRvxklf//1dJ5jSCIZDQbUB6NJgmS4fBqIZHrgzguH
#WPZQCIW/GLsw+BR+I2KdeHQuCwJL1cUsXWiYj8JmXYUMIyOjUbfcp2UlZp033S/O/UykbjNd46Vy
#tVyo05ST+SmX4KriyrZ4NBqL+K7itvPTYCxUGNLv3IuCcXBN0l0VvTVy9lprSGt2XJpVXlOMExwt
#4Qn1+Tm/u6HosvnN1z2hQQyU/VZX7Hsu2X9xLr2kFQonXCWqFl5dg28BCjZik0wJqUh8Z8A71mj3
#gj0ldBGX5wvRsH3q9sTbqKq8Go5b54cIE5899oluKPBmOHrOvOCep3JMD5K0IdiHDiOEAE5iavsl
#XSLGJqDb/oPEb753nM6AHoUe/5s1t+Grdmc+hJwScgh2ssTzSHGGnaHbfTsNnmZa3+3Zsw89i84z
#zuiT/P034MS8vlqfvGVC8d8NAaYddbsXFvYOiCF6/jpzUR4EVuoU53lT3ZPPs5ciG90O0ralLlUV
#F7LZ1oxupww4Y35/Kyaq5q8FiBw60hGI2mHQ63ZIXi+VdBabtsbEUnlVFQWWFSTlFNJBoiBdRyF+
#tzJIGJgmygM9yM7Fvnpkymbb6z7OkRLohkLBCeBoXTMkR/pzdrnsm/9wcL5HgIiKSBLrfj0fBAKd
#2rQBr9ygyQSX27Sfmww1O6wWFuRNMtUwiOfm+4UwQk6eX/ReXO4Gy9sR3LMh1SMIF67W9+eGze8o
#lS/tBWIkgAIwRouPjBESkkya7W+Hi/7I3W/bv2jY785j4XX8jTtygq9eQpcgwB0t9AAfpO8vbYn7
#xuEn3yznOfL3bp9PjU44nvcqKB6M2jc9/nhdTTf5FXtAbJqr8P6uOOyDTt2ROonrOQNU268Vq1Ef
#hxqUZo52VW2tEds7xlqhISXc6YhBqmgqgtUoZaXolF5BrMgt9K1+jecDAZ/vl+bY43WmCo2kzPu5
#Qh/9rcjeeHr3CqigNbNdhRVPhTTWWMrlfturBjQa9MUbQI7G1hDdatTrLZ7KR7zpDCzXdMVrNC0r
#c5LY4euqjk+XIgpj5QiFSwgdgUChP5Zks3dcfcDnlB7l8mnrm+X1vkeqvuZuRi7zQ0icHYjV8oWQ
#z+0OP2uQqzZ/qP0XBw2HRrAOucyELTQlaLEpqbH0j/TztygmI94x6Adw+DHRR4QHQskI3VkwJA7X
#mYbzSJ3KGcvg2HHZgiiyssQkFy8y7cVDuxeEA/1eNeD3Jd8dlNeUftiYWqA4Tn+J+10L9OFaqtGp
#maPuCIJnn+AXy7dIsAnWgX+STK9ZGlCe5rDFWfFq4Cf66LGZH3f8d8DC3QpUOXOJiNx5c0cF7IHE
#CM7hWm4owbZcezT6QaPe0csXtuJuZ37ZEDFkuktNHg/rUyQhLzHuCtSiprRt26JFZh3Vt0TLLeIT
#No6emyJBBBLjBGSJ6kQHy4PnLwwa3cBOI5pWuijQW/OkjPu1Kvag63lk+Th7IRg/Bgjo6CPiAnqv
#WZ8dvctMEHqSmI4LREDwnKVbphH4DvuDgIjKSrWyNrJoU6sVS7WfLwVOzcRf7NeMqIOf3qy4BpZe
#k0Xl3oih84KNckaQf9h0H5sMv9yPN2bK3dJcq5qwD1wqtZTeVqlUTDEioTAJwj0QCyavXDYg3+oa
#s+QtOJgBaKzBcwUHeJFf5r6WdEclG+rKFS05yWMorpSUOQ+fbvmtvaR5cnvWJIo6z2XDv/tLRvme
#U4BKlH5UzLd+0T1fd8e2rRAzqfRcc16AgAxMQ2tisYXQbswFwlDOMmJF2TVcYbOAOMOsIhc25JSq
#CVWTC11WIfca142mvqCwjAIfz/4ICwi/GP+8cQnGKjn4BmyEiUJZKVaq9UaXtWYlJ5ZU1/GpqN29
#c/aeeqvtbT7PcpLWsmaLtCpZjv3WHHlsynpUXAkDka45O+fKkqpWDaXHqFaLGb6QWJjoROIT3BJn
#vvWGEYfbRk6OobFSh2l30PuZZ0CveD0X0VZXDKGmgEdfYKNGyDS+6K7AXpo6OYVdGCibFI8hT0kr
#Ax6l1PYlz2LTU/k8ZbNn3nWRhQoFNIssQMXjDO80j5bIYa5jfrV+Vl2tJsLeDDeSrGHBOIQ9UBCT
#Obxc0aCEXs7wT/jOTgdfgtioBAa26XzFpqgF03n0B+lT0+EeaLKKtw/eBWq2lHa9XirIi5lBjRsz
#3mt8ZdAq6XkKK1zsCg9ypXsW11fVgTCLW+xaDWJc7HsJjTmmEKKlmtjLeSxgSgIyXu5Iqs505JEy
#lmYKuICwrVy3+3gazkvgLAdS6wTnFmot3tAB5GA2J8jZKukfMtwNG7l/K9wQZQmY4RCtb3fRACga
#hOildbjuEtn5rlMZ2QoGsQ0HqcS/rU3sgPbeBQXPItE3AuhlrqZSZ6vaA7+aNZtvlKJ4yClRhCqQ
#6RSRUnf30cPV4PZ8wGoFwwiRtFQ2FNSgw5MN5ywtguFkKJFyXp5Bp96S+aXji8lDBZ+cpcwFE2U+
#HzNOR3LGiMdAZPzJGrkjkoTnxGAWgCpqFc+/f3Ss7jym3l3X2Slvcy+ojIKDz4IV2b762LsTs+Oi
#KDdF+Tg50/DXOaSbqvE/hnNCQLdIJ0OUXdc0178kqFjCCtW3jgPeW4/NbLcBSztU0U4SRxWene9H
#qoaP4fkQEMJc+U4vU+vczgsPFkhGeBTeudb1PKLvskCkHvjnbK/5JL7oP3L0/94GiGEf8Y/fr488
#efADIH0uFoAAG470Vk1BWrOqxMM+VqxU+iNl0poQVOI7xFBcKhIMHW2gpVLc5rrkve7lMaq1jtSa
#UuxicqdxQwXyYHd9eorQ8n/stbsdqzKBrmXGcXY02oEmTCazbFlK8iHIR8bbop/epnwOvZzc6gvn
#CIkrYtptoWaj8w5niLjoiZTXuIOlzWqwYxeSs/r4lvAq8n60A87C3PodYpzekua877CmFdA1q2cz
#kWWbGgXvA+fLwhs9K0e9yynj1Qdip+q7B0ZEd1txATpOGmsOdrpkEmD90QToQO2pCfaI6ayATkdF
#hzYwYD9f2EIYeGMcJr8ahysPKFqsJ5HuK/ggtLRa5XiiGRKr/6a8XgFYAikiLYjnAOQQ0qD+iTm/
#+UnppP/9vgtXLGyYIKCNxWIfjAAITQD3F0HSgPPsrfzlKnZWN7uJUcAPx6bFUvn0tEBuLxHI0NmK
#AWEocfGZrbZ52ef1+QJOz4pXoVhyDxjAwyIhAjbKgdq3fZfRO8aB3WdXfTf/bwm5Dkv41FAx3xWP
#U9T9AYCvU2a14kHrGXKaZRaU/yn067ZuEhQ92gz+HNaxhsOCaN5Kr7zzcE39JJuwLqVjK6sLCxGZ
#bMndNmQZRYAf0zR45QcfQ9wz36wsOewfeahUrFX/MKScdC1xIw1KKunWgL6omTpyqafRMRoyarGG
#RPTM4N+uA6EnhfIEUMu9i55w/LhiZGTEmt9PYr8B/wFjRVl7To1KzKXdo2SobD5v2jooYmecjrJt
#hNNYUAR2fPv9A49BdpGr94+0VDJbPTC20JxBQwEwK5b6g3KjCVvHwxcdqKTSqsXuq38JE1yuiHaP
#1jx1YhMQuoxAHIQUMG26UNS4YWZ6SpZeck+5thM1PA/L9hX4RT16E1SM7rxuAqQ000g8lBgUjcfQ
#blA26PcelyTJcN9zhziQXGrb5bRoS5NkqpRUMolrwY9Xu6V7HaeUwYfbeQXApULuVHHnurkhYL8o
#8kgqwxaSy71ep/NWcQh2NWQ2UCDkFPl27r3aA5kksLldcEI5O6UsxnzeUMtybdLs8NO+X1u2BpTu
#MItjl+HsDGAA6fAjzICFH37mqBto3A9Af9PcKAd2gPDQkVSaNI+J3ONvFZbjvNfexhoZDhU5z4w3
#8VsjFyYS50XEMM4m5DroBfoj6zkV9no0RUNBID0OpYGrDUIh8vyw9YqsnUNGLXjGUS0SuoCRuNY0
#gnNPXhKZH4JWWV5KKKjSKFcB0Y9btFcghheiNyjoqtAm5yfzX30HAcsBgttOxmr/ZTOACp+51dXN
#OJngFhFpx43soHatdjhXkHFDO42Kz0QNUEv11okp2trqozajICYxQ07XCO/f9i6/HkOawxJno9LM
#Xes1xMl11ahxS6QuG4d7dAsJvLm9Y6Rn6+RU4aY/ECuaKlSZDlE85LhTnruRkgJOLpVueC4zwrmr
#8ttITlqqWbqhSEZD0w69Ci/VIx1Sa/NI9+/TXGFWXtVYNcBBe5bl7Ion/ltDJy56/8REWapTt0zx
#X6TrKMJI0edlXaO1QhtBlA/j+InpxSwGAkVLl27mlrtfLxe2mSRsWqxbfFgWHyq82+1dRWnUUEk0
#KMN9nhH25YFbXMFG1VZNUyS92mwOP7o1b1ZZonnYeQQOGv0U6nH47NAsuFqWTJP7JXMz76bE1kxC
#Zwzn6jJ3MjGkx+o4TqCVWpJT2hMZ1qzn5sFHFAVXaYkF+Gw01+b2YyN9KE6CNIBnDOrkUIAA3GNY
#DpSnlBa3pDM0g8yW2ZliV9rlEiP06RyZEkgqalkqgS/wD/NJNsb/tKbOGnjJHoYCkyRuK5RiGGOs
#9/vNQj6PDHmhSrmazIse08mkR2j2RQu18uCW1hZsDG/BR/5leyU0xry71jvP0v0wpVQxRj09Mz4O
#nQQWrz8m2CsrYbZ7e+SeCvYeCvZBTj5QHtdDNzzx5xo/QRs/P/jvfxvxfTcO5EAu26Yf3SR4+Pkz
#4wo4mLxw0/5ycAciLqkvFNE92PMl+AdQvYhYKTxDPsp/OXZULEy3et+wlm+oR8TIFOnBF4CH4NtE
#cXBivYc4GlhBqW1YUfZ5O+5u+9WM5XEy4AcOJD5c85P7GPPoQ4/8T+byO/Cx9Wv8AtBDFwpMkvy8
#kzvvX/UdzIEU/NAt0gfKLQ9IaJoBJ1KO3e33H80CF69Yz5QWGYG+fNOtwpAs7bUIHHDkF5PhgmvA
#AM6AeLErRZVkmCNhkASxujyPuuEDGpS+/k4ZfgKfZx1PpYGHQ8eUyrlSu3yeYZFYJ+yc3G0hGwIr
#lcrFXJWkneSPwM7ZuLwppElVci5uPacGM5DNzY7RACFUOrtVOb6DAOj4CwW78p/sdnff+PDHRU9Z
#MskEm9+6AOX4FdhNeRJyhfGQ1eWyeCmOSsZ/QPyU1rWUNZ53xVdywDloZwO6IZs9NhKCcJM7dB2f
#waUTvS+cEssUKA9/Fb4OVPIgNVHK0sqlca7BBqO5+zVzyhq5N024hy15x/RPrF3Mo1by4MxdBMvA
#1aOMe7KCDnt/Qd0F4Vc4NAzc3fvSMTj/PRbQkAZ2o3ZCOUWIk8vG8uIYi6KGVMwRBt5tpRXiuEdq
#g99tqSkxag1D7SRYMSgr1TI/y9hfozu1X/MNkhSC6CIq+L8Pr179DI1P6PkSFZzAVwSf+ZMau3eF
#N9BE4Z2ev7bREI3GUWPxVrUPERZw6Z5HlpDKmjPTd66PHgfJjYOgDBCKNCuN+ekoahUABFIt68at
#1ZpG8sLFEZR3TPbXEWTc4MYNzvQs7GuVphDmQzEInjDHeuy6mhfCMXVzqGUj3Tbamgy+clFYKJXK
#oFkzMuXadXf/WhkQtsQ7Cbjv08OXp0sdms/5Kn0Xeeb6qDB0B3yK/amvwhx1e9Rz+JJxMq3Rmzgd
#iGcl3uCqy2Y2XYutJ4QdNXgxGfSnGRSR1TP4qhqMAvBc7oRzyAtMf7JakS1Iq1ZL2Qa06Uac85Be
#nnrS5YIs47K0B0KJUq7hQ49t9UUJNegz5n1y3Q8G6qMPbtM+nXjsr/Um+aTI4g5vmc51BQN8Eif7
#l2tysj3Rkk4IaEnItde8sxPAS2CJ5kqHttVWLs10vbSzJ5PPJNNRfLSzIYsfCh2LpZgxLmAIWAgy
#JSJjpjuc0XrrOmpXYjFLBoaPUt0OYBIfkvSN9UUA2Qkvg5XpC7OkSbzfNN1R/x0f39okgFixd1zo
#r2fLcsiosq5+RUwkxEf1CgAblsD+55h3PTa++CixRUa+w+vgycPiXPfvKmDB6v8PIvTbI8NjdwUp
#42w/Z3pTDf7YAjZAzweu+pRn9X0PavvQ/4TQF14L4mVuJ8clwKIGtePrE0c/u0flg/FNEugNs+F2
#F1ePvZMko6Zi22IdqtL753BSjfg/HPT9WBkLgA7+xVDEHM5VwrxmxiuhEvtdp6OKGtusJflTqn5k
#96owo0R+ggCStEiILH30fpcPS84DEzpO5YuVljrSLXssUZf+Gyjd7tarqhmoQTh/SdVvPhN27/A9
#E3KtClvfXHWquetb3fZB13Y9xprJEDanEloWHJjR8AumQNnhBKobNRRKlhpC92zzau3oeimnis6j
#1rnBWXpEvTNaWVXuvnq2SjE/A1eqdP+mA2Iz6D2lAKImKbAJu73Goo7PNyymQsrtm5j56ORHE0AO
#FrrRKCeVqhyLgYDUkNWZecbu2PDsW6y7wCZAwA8LzNXu59fxPWx66k7cdwFqJQwNJm3AOQIZwNq0
#/6Hwox+29DRBZpJhn2/HMeC+HMDMYBcV0b4ROTEKHzYaMrN52+YSMchhpnnAOfcb9zcKuQhhKDSc
#sK9VZ2/JtUh3Cbra+UFNs9N7+dT4sONCx9L+kqecBPnmHG8yc6IRZFkl19VC1tb5jPXkfCJbyzEy
#99Xck41/lB9XxnzaNWTp+vpu6EoIQGHJ5d5T8B0kOEc5ziikYYtC61eLOz/eoov2+dq2ExydHfsS
#90gHyUJDWrN5d4vjpQzJSGaKMlq1J3cPkLgjQNM5As4SZcBCLX6Avuz/CQSC8KFWZOgnS4x1Mvn5
#1V+z98jgMQAuQ3AsA7iKNkA7Or7oXrzr8dbd2Q/PexkMEG46BflCkqhxPeRsSeshANoJ8T+Be37l
#xdxXDZTYYju4KwtgTVQYqhMgp/lZkuQ8Av2ApF04mClt4SNI3v9cKGgO4Gb5Zt+1nG22Pebp7p3l
#f2Ze8P2DQk3zeQpA7E+1R6J+P5AafmOTZhZ8lxEqZ2dTEu65mrqB6dnDemrnzyGm9vdLlpzxOIFl
#mjLtaWjDvE/oo+Jcc5iZsIHg/sFbtA7ES8SHjIAQ6WHfcq3iSwBa7hiHl+GOw3eNhHNyDMMJPMMI
#ksDBHZHgoWaheXUkvKmLAOnCl5c3Qu2hX1SG5J3XaQeUS/sOzPnzjXq15vu1WmO+6c/963e/gRfP
#X+v3jhuqAFHtt8hzi4Vys1ku6oHOEg4UL2jTnv+Bv5D6KEcqiNlo6DKmhRiuMWp8XQ3NGEKVSwFm
#pGY8v75lNy6tRJecmvEcJzmB5nqtZRo9WR91x/qWzmJzplk9q4OcNF+U0VPRFj0tIq8iKtFSp9tN
#mmKypGCwfhQkURvrv634LBEMqnAQchryxSoD1XUEJNUVxqKNgaDKoQb5MOHiAqFAsY+5h28HH+w4
#IrmeWKFSKcTcBt5pUj4LGBJC6kOM8qpLibLAUwVzGoSw1dDJYMPphGAtggdUbs1qZOr0+SctstWA
#S6nkYNUDwj0V92gHQ5M6u6ovRWhi2xrwWJX11U0vmEPPSyCwNmHHSXQ+Xzjs9UcKj9caIhv2O7Gw
#wzJPL9JgE+hGR9kQ/tNssPRgYwBtmxW+kW3kNh1tdt9bs+JIS2TVbHEiygQSy9Q6Hba6ee0iDX8m
#6ErlaKvVvbsiuCEVvFuC6SfUqmOVcijEty4H3jpuHxgSLBZlNRbXMQ05SEJAdtkuv6kYGoslGomF
#Y4WPCZos2/L+Beg1Za0MfiNmwf9hmobYAVqtRnGpdFceldoKz/4+hmKeh15P2B/PsCxJboitWuWC
#HqXrGCAhQ7fUo82H4K7g/qnDsw5dXPgHdHj9mU9JcOCH4r9M6Z/V8vCPEMo0Ep//5cJPNntBs4QA
#NQhSs/gKCTncnkQeCo9Ej4IcCkVeIvye+x11mDU/Cb8EgMoYFLxe1OsHWqiMVKDYH7D4DTeCkk+b
#WD3mW+ePI/XYQ+74deZI/uZfSuATQuQs/mhMD6m8O4n4dp5KHYVJfirGB7euT/9HQWIA/wr+vIK/
#9v6weqzvsUkLuObp6W4pUGfWXluAEcGyi68D/4BmasQhCctndoMuTWy80NRT0ViJkbuArYkZyKvP
#oSMG6I+i0Oq4X6CSRSwg56Ty9W4phAv/WR3ALcH13/7SR9/ri56kqQyeCJ5h3/Y5OADhAv37/m6s
#z94/144KQIHc/Zyp8w75sQI2GT3/2BMdbR1y6WpmoOPfbfD5XPdKb2A4vAKCfpktcMPQxMPP3jx5
#9Mj1TXBdvGEVaL8OAodRxE63yxPLn1dPZ9OZDDPLxg2Fn+yfcc06LxSNo9b1KHjnMmsxQMtf8fi0
#1hwoiOpBGOodLuXbRvPksPlzxzrHVyiibuXntAHNS14QuW4YEN0GkmVJxpMdCvzCntsU3owAXVrS
#J9BwFCiOuUbD+S49eKvp7qdGm8BCmUTC9NrIy165y8wsCC93Z/gdBEvZdTDzydrse8JbZ4lpu9Nl
#kRDg9v+KDikU0lSdph2eT7yhH563ngCVYuw93DK/fnXwaCRUaCCZ25TX/iqd26nI4DCN0N1bwekm
#J2j5HEm+B35Wyn0WgwB1vG/Dz7yy10cRGO71ZtcJGEh4xjN/0F62aRUBX09kWAyt2er80Lh020jd
#Q+H1+5O5OiJUIzZNmagpzFGr1dr1skesoPaoyzzWOvbJm/3VVzePAwS2cbVGLPQv64Jhmc+2G14n
#8tGA2xp1WRcdm1HwEg4ekHKGXrPB9qdZ8L1tbDAe14JydT174sKPUZkqpcZHjm2wD5op479sGPJc
#4I99Rp+h9RMw5TZfUzRrFef+8fv7JHxkIRvSkzFiSDlucjpds9bwI6OgBA7zrnA8nRldE8vXDKmR
#WrsIdLea85+ZrLYVyhc7Ctqv1lVSgnk1sOtGDIxUUdXwSqGCVudg/1dQjhh0vrXwHDFfzD5H5ZBB
#AWU8Izdeakx6NIddcEhgC5uhcpuAzarr+gtPFsPcKUeWrogARV2TrczlM+Vy+2EKzNvlQgU8y/vW
#Bu7U6Gn2tfvwbcT2S/QbtH8bQMgC2BZcgl8A23Eu9upPtYfuV3+AmdM889mxDXcAFgGh7iAMGAzv
#nPVjk1sjjDiTVpSp8Ms64DvNOFP7BvKg8mG9G+2rdAsCeASWvyC+5VYbPThsP0PDd4Xfr6PJOB0J
#+4SUGCXgUdvsjXcWOyyqSHsZbwNtFCan+5zenE6C2gKWm9YuBLU3j+JYuG0l5JsCfaMw1KjIzPot
#68qlokfONI941B+Lf6Xa7TTLqVlL2G+k+afDsfWl6rlcJiJLbjPL0KopTCwck5I3mbZIggnAmgbu
#GijcPGrcf7XJ8+m9hoJgdahnTjjOTY+n0Wk0XPSHzyOQ9Qea5YGv7mCPzbXhr6uDPUnCHEgywV71
#b1NWwcd/9zfuQwNqjsPmYWJa6975x5BzneoPJFxHsR4ygASFhop+BoGF0HEpMmVkKvfen8HucPIL
#NPsNcw1hTKaLlWKplxMzosese1hv5r+SGyYgaVpyDldnFEbzdjX7C84O3grcBz17kHrV4J/FkrVA
#cPsJHwe2kLiC3sVjwpoBfC9sD5PidwEREm78kgLY1EnRDzibMZWegUNttL+OLWIX6XTJ/9bzqXIx
#nwr7XVQUzO0ovf53yxcq6ofC0A24tKUl1yf8l+uNpdvx/voyCALP+pQIbhgh5z1MPsP6FN+4skqs
#Tx8OgtH/NTL7RT09kY8VnD6ILUIUr/pef8amzirzJlF3soUU5q0xj5fb/3vsTlfhT3n9DmjvNgPM
#47fDt3lpY0sSKHV6HgV6VXD2kQsouIV1qpStHya7V1UFxYYvBV+n5KY1YUd/lk+NBkSvjW5DdWgZ
#O5OKZwUqtJzYGb4G4hx9AN0Q/WjP7N6BHNItct6TUr17q1gojiagLGdyxYqm8OFc0vXXMZl9VaEH
#WmP1Pj9mju/cXSs0mg3mGBd/GtKrS5G5UCZTDnAN0pDUDvv9zrbMEDVwxhQcWAa9XL4Z3dSsJ3jT
#1aUnkKXCVrvb9Br8vPcZRfJmHkXDhYoOa/0Bet752oh95c/tBWAPH4fWpKWoF1B4xhXs1Ws6UzaS
#ty/e4V8sOznurWjAMj8XJ9QEMKvlujledC2doEl3nAS7ufj0dHzDT79pN0i50Mtg53WLjb50Oida
#kcthj4mIxmw0D+SbUQCu0UxTl9vBpzNJrQ5TbVkpdnya9tsslsVU0GZw5xfReLM1qy0si8RTEm3t
#ESlwnr7IFG/+wGdHDv9PNFlqCxdu1DlVqKHdrTdQvWokhB6uKuWrDSJbkEW/l9viSGQBXAdzlYmG
#Qce09jCrynHf6yKZaZnb0cX4DC0aQrntNhqsCXFfiLBbycEFEOfQ42D7XLvr0m27EXrsKrWgf+yF
#Brj6hlEjdUthvZz9lD/KN+ihCl7i+Gwg+WS8p+1tfh3dz0IG+eJq6lk9RdWJRcHSM588e4zahVvn
#3A3BysVco/P088i3kSv39eOpq9432ZpaaTiglB4qe4ML0oXp8iS3gq2QqojWdb2JquHkhPt1SZUd
#DJdLkp+xEQxDoAGzhXwmThB8xWyBFK3bQZvAU7xnkEt16fm4N3rSFNygoDSHIFRYiGKKLYRstOot
#js2kSN7nUqoNw7RrjqHqZqNiIqi0TDhdBpcA1dhqGs8BNxf0EZByR6qGmnMV0I2JZXG90WyhYq6h
#21DncC3Xz0ZyjXktb8kevaYBB9Ld7FfyO5dbZBnADSfdPmmf6g7/Pd075QGqhlk/fOYxx4v82gGX
#3Dnfp9cis0O/sTEK7ugJkzDdidFyIdD+MGpc/5yXvOQNH/5cJN3s5mZW+vMc/bv4vShdU6YXTKRm
#D2/bg7ryeYRkGEKVNDdkAz3SuQoSfixGT+mqiWHufmX/wTJmER/3L8Q9weedodsemBZGL780eMD5
#xD9GY3M+EK4Agcfv60rFXnMpqn3dw+l+Dga2N98b2ldTw/PE/MpB0wNzjIDGCuVPZPPx6Gx4raf3
#EXeTdDeyVAL3EpRUmxVXieVdZctblUaqW1mwIlnfMeIi0EE/yPYpUApDC1yjoimevcrkUguGxskH
#NY7v4rupvmbH4HW5GoO55kZuZo5dvOvpOfz1AdXzpYaSnZp/oAUfgkBtgCgYFKwYtq1f5+H/CW/O
#fchOTitzpMgjtbJ1/ju+3vtatrQ7CbjvseHl6fr+M3yWrH4N91YvAgWuF1JCQVAywlkztSmaboNy
#VFl43oPTLlMgBjMNJsnrQrEFkG2UJ2iu/3pnybB1BG1ly9suObsqLJDHJsPHiYsv0QEJ4pw13hG/
#om3/Kq8rlSlbnL2FML6jaxxCMLIXTzXNJpP19HmXRdC4bt4ezU3NRAfoUWXxpdr5X87H1xVBqKay
#GuNVcvl9NCrwdMyWarOKBxTyj4KABNrbpz3TpixilCqe5B4EBD1YhYYQGcXnwxUlglHTZOp0Or2o
#xO4NsegfqE2FiXdrkJsdXeMQwsjuH0Awm8z13+oTD5aj7lC+VNFosbpTfNXHi4AxgD+q+awZfus2
#nuNCqUSAt9BRgWVMk3jRJWD/7H31ZDGXwym4ejvsg3wU3e1FD93Sha7QgrmumsrE3IxQng2tGqW7
#ss1eEoZKm3jKZEq5Xzyrqvsd7r0Xr2Nhdq5WrVWPmYePN1qHLRbM+8qTdIVyewSjxhodi/1gD/rk
#TOyVASvRz+hT0c2Kt68BXXAn+ZDJ5HL5UxUmRaXG5ribrl8ATtyyZ4x+8LIz37AyH0hfWe5yvQji
#gAOGoiXOtC+izN3Vh8Jt4ztwFLDDoJxNfFjnKrjhnN040EcyoXEEREz4nDBu5K6ZWfbTQPBwBYAf
#MmcznvY2efLS7om/scQh7eo/vnFq85sLY8y7Kg9H2sa381mVBBic+o3SfMK8XzMz/wMpAAzkF9nT
#sMqcmxiXNmNx4AIcgndu1EyFkRzcqwJm2CfRJ9vLoMT9KFw7CmZNsxISB7sb9z0Dtr0ZpCoH9sIH
#HE7K7gGLUTDSTXMfgx/3ic6/r7htdn6aOrECOxV/58RGJYqccr+swUhDi4dIHw491KKq0NlzXlXt
#Bc6VkaiI4xiuYQhMcMbu9a2vT6qx2WlD3c+pifDlcokQ93O/qG0osqqiHQGgkTM4SsP3Q2jwkhmF
#84pWl93VqnYUi7WW3SgWwyq1tVpgpdesa1ameR06TBHQaNtwli+PhM1qZkZXoX0q1IjgHzNLWqAs
#kFOBS4Ctlxs326qM62LFVmvjFyMX1G15PLKey5vdesa0IaFC22rRGWwbNUG3CRqYVnZBs5MxOxD4
#wDQwpYqh2W7ub+g6wH3F4Zc8w+YD+8U7AIOrV7kqfU+3JA3jqi+Py96QoeeZ7ruKvHaPOqPvPggs
#rkE9nq9+DDEfkqv6u0hEjY3XE/n9fERXIMYWi4WVYjMV9zsdHxCbBUfetZx66MRaXYqWV/m7UBIv
#9RkpPOBHIFlhrYMb79HY1+WhYvFIpj/Bsgl65uzGInc4PfzeBqFly2KbdznFvdSQa3xGBeAIEYIg
#kYJF8skPEuJEM1/d7NJU6RyxlP/3x7LC/Xy4XXby0ggM4DCMP32s71kU8A5EOElySOsHWAhsvvLS
#TeHLzVaXfx6vuf29ougc7rjispoBHX4jSXPOh5KFrQJw9my4iDfrLV31XRehlIIRGi2TKt2AVDTW
#FTkQTbAUWwns5UqtxVoNCK3UNaTMPZuTC9HeLzDEouSdMmdGeEVq+xnBT+LojXpxjQtVuEDxpiGZ
#redoEuJLe6xgBVjJLzrDL7HkcuG4nVyOK9wZGmMdBIBMszyWupq7UQzgS9C4Ajh07QoGJHFEbv6/
#NsD6NcbKR0JQuQfj/auoI0JFWameeEPEdvPFO9X2zepcFn7F29yAgGzZffLzK5cbCwHjiyFNij2/
#ZAeLDUqwJjB1C4LdHxEnrzLhaQPtLq1RPHxpDb/1So01W1dutCiqp426QDG0BwllsjxGQnBaEtct
#rY/t3EAZpbN443mZQuF5AGjavFiiiH5gBGMO+0aM5pxUbozltSgdNkAG7cTuc+Zuy8pYl+Aejs/3
#r7NlreekOnxG2eycWpgaUlNhPIzjtNok2bc1pZSqo1XMwIW0efY1TUZj3UaEKRerpQunQgU2nOgO
#hw8OUiMLJznuFgl0oMDLEYMTW0WZ8i3jyJ0XyZJakplIY1CKxxqdPeswssgxt7wLIgL/MPBk/iL7
#rRTNmiwZHQGFWdRW1uZhvOjmymOUNIpj1ixJvovlBD0L2kmbLdvyiuK4tOU2aEVkBC6ZizE/DFQA
#xUZrPAqBJ8w+YAPWiTRcsi7xhR0L33Hw8E8UkwZnEkCvp+HcAcM5kJafCIZb7zR8fn5m4PHB166H
#AL4NALuqqr21zRgMPpPhRrs8C34lzlF5LIVc5JAcTosh3Gdf44fVuzVhHjMbDWwyXj4UP6LhgLdz
#rW8aMobBk6nk7R4HQ2EbI3nImp7HUmx9teda6uHSNBBTzM9jf6xUR23XNDic7EiW38p9U/i1cnVu
#AmzgWJKoz0E+VNgBH8Vo1UkQJ8MIE6syCTHEvJ3/TW28UpSjLS1RWRQ3RoddGKiFG9/x0TRmaGpD
#iWNW7GQGx4ti3yISliQLNB6GyIsISkWjyoj/uwLhABJg4y0TK2ywQnZJ2FRQXPw+CrRlH9gYwXZl
#kVA8/Q3zw762eo/gOz+lo70nk8NZQ2TSYtlKUD+ueJbEjNsRz2bJts4FKVBD6NeeBhHA232Af+Wv
#tpCSl/ZrABgP8eScuGF4Oet45tYAbCKWp1MDOHt1VPUdpxtg2D62vRGT9kI86jmlvKaGCl5EWUYK
#XQpMchwIgW3JD9TOCbBw5Vhb8pVd+PZUIe1cBd3j84G448BIYxXWZl58xP47wGWnCPC1AMboQhPc
#1YNrpTzy8oERuOA7yE+zVf9drGh997FGh40/g/7mwHscj6tI4udoUOzK+J85JNGTri/fqweoIREa
#hdktoWeOz+kVZkIvvOUxP2PfFQG3EmWGMyDly4TF64T/U6BzJipuCMiyIhPTUcu5afDXd8HIlMH0
#o6CcexOsgBpe1mT8gvoifqfbesXkcBi9FTcVc/iDoO/sFLk43tf0X7SMs5ZpLThUg0/ZDJb8lMtV
#LB1P7gmSo80QIxTqF6JL0L4vJyJW5ZbEe9V00yaFH15xrM/PeAOJWJG2xIXx0Ua3pUq7LxBRiTjn
#LK3+ZdI0iFUiu37wthrr1dFY2BHJdX3pW7T7KwutNGnrnELY74OPrprl+W1+kJxET1//TjmdDoVd
#q5BPN+U/Vn84yuk88Q1Q6Xw2xT0Y0gnVW4hlFeDD4BI1zk+H89WQ5AXjF18lRrBsZnvKHBXLQo8o
#FurxdR4ijgyNAlmfMyAQkaH/jC1kKN+0TXJR3V8o/TtRIdRRDZIXEy1141NWotWeJBa9QFjBbk45
#HFPaEnMJu+eS+0XQ/Z7daJMk00AwKbmt9EBnDk5O+VZaCDUR6UfdDRJGecZTMimI6PV7dcwJ5ne9
#is+mGgwjSnQ6xSEw6hffY7R6iwuGGyPeS4G5Tu33xR0WPJVr8APXiWhTiQDw5RMue41mc3H3IKBZ
#Vm6Q1hgOZdfHULQBB9T6pHmfDwxOy07gpSf94uY78cOYmM4T/w1/c2nsZAOgwUNr7p0vIXnhr6GK
#iXIQf6GxQHXUQo6vFXdHYc/KHSvA4YJLGZL4zgOS9xkt7C1k9cYlP95HTHymULYLzycSBZVAO9kB
#dspNOJt08oJbJKGxTpH7jRW5JFAkI1KU1vY5VxywDm8Yyf3dNu2DOEQw2COSJiVKZL8Agw87YYtX
#qUCAdMdAhKjjxiPijEqjiQEqxf7P51cj1q3xHm96S+ACtXF4bcDzboE/hZsccXm9mN3vNZ5HbSeu
#zfdD448MrfNDOA4qRTLFuWJ9LqkjqSZ3626qi8HlIbheBYH5V3QiEEiEfL5oOr31WCFLCd/DEP2Q
#8JliZG7bHGLk6DHueZExU0F19AjYOP9mGon6fKFEIEBOeuuZzRcH3C6lhmOpTQVrjiZiTHPheZaJ
#sb0fTLnQ2Td4isrJDK2tDsANsVdg2uMK3qxpgA0f6TqMPDzJADj3YYsF/Bvd2feacT1PiALWJuw+
#MX/5fK1lU4lZuy+XWxM7aBo0AGw9+O96a2mEvzC3wbUUAFdbMQqtfzbOxmwNZ0yYF4RWMRAOwi8B
#CjOATanGSgfzOeiSaf9ncNPmdaw9qz5IXQlxBosPoCPP/dAbngu/TA+QYUPLUx08JIKK7oNWAbtw
#UPjml53TWru5wmgg5BPLVv0PHVtl2BtrZyqbvDAhMAoOhefccA+LydaM6ll0Vs31dfkY4emaUHR1
#V0uWad+4Z10yPwWGTxlC8AAR3xGq3lffABEWZkh2Xtgwoy3T2CNbeFqmWjuD4bRk01VDv4IJtIk8
#zdUC/uK6sNFva3Dp7VRd5X3F75XHxFotxEuWsyfOi1I9rDgO2RRB0VYP+ycyNs66ejHnE1fBVyDn
#fsltk0JIAr8QQcJHkQS/cnx+y171PmsfUinR4zDmPGVtjUPQ2IhwHGHJ6c8lR3GewPQx73y5PD2s
#UPlplt+iq4FaQy2ThvTTMMxSkbs3wxVr7Fs0m1P3PR6vz+f1HK8bS1gsidyQaYxgsiInAnC+qQtp
#yZUaBw2tzRhC46opkua8YH2laZu4TZbjxNwsn5uYXObTE3h8f/SkkgIkWDbaqJ31nxs6scijD980
#yzAb/LB8Xgk0skFLJLSoP9obdhuKlZZaCwCSgnfVQb236VVpgE50R1XThuyWNM2zDk8fTcBB3FSv
#e+1dseKUPSPzbK1U5KVaK35gbNJ36xrgUNdN8CtzXXDDqZeJKUelZPElsbNMKuB2f8h79hR2TAwa
#Cd4IOUxfN54MpxGi+NCQa5MbTLTDLuy05kmVyulIWLQrzVKIZWs+ElrRaNTVdDgSS6S4msJlAlbr
#zPCvBul76KVHFeOmZDUj0Z5Quu3h8C9/Qd5W7QwixuF0u9P3LPBpz9M1j+H9V4tHzisOqjguQyoc
#8EVIVqorXmyWyrmlkq8JJZMP+KP5oF2kFDbr/OdOrVOOUmUUIMOIPRW/C3adCcAcpv+GIjfgvfrV
#TRtc4baXRew+g+LpRNWubglSfQEq1++YTYBFH8JS2uh5LNhhSfAqvZYznLVclj3UZpOxq4EGl2Vs
#uLGYeNh1B1dlKopzvstY6OZjYodEKKMtdgvZ9AbXAU1kaFGel0sM+c2ISkSZEaCHYRODdPhwRDlg
#9JiVNT2B/V01cESNO9NTigfzZrm8zYqUJ/n8HHxBZmRl+RFgD+6Cb/m1slJ0qBBydqrnCNBOuwJ9
#vqcZCzplfg6kD1Ywh3eU0r6esq9qE3GIzG/RbpLci3SZXj+1b6iRH5WFRfLS9OAolwdOwAbw9u3w
#OIwyaiPsIN3emV2u1qNPRbxBsgzCfd98R8QFsjeNs9m5pFR7wBVfoa9CTy61/Krmp61g4hZ6YpQ0
#vy4K7zSrk5QgI/ZoLnffTz/NpMZaV0QVfECNp6cbrwy2cVBFYkxrr6v1+o3Qyz6XhSBWgQ5u7PL2
#3JmaLzSvrkeQGW82UOOKyiqPRrJX6USaYsWiblNCJDlRtu3Mi/1SvkGg9g5lWJ9kOg5/dZCNMC7C
#XPIcubimKu3zOKhxOG98fc8hd2qqWsgLAOFvBjZdnk6YBM0CVg4StYO69AKvRgAmr4OAeO3XzpPn
#rcT/MR+YAJ14TNCuu/bXJ2z/2CiqWwGqUmj1BhdAVjVi1r6PgOSED7Rf5fUDOucQsDruz0QRxcG3
#Liv8UPF9dM73aa/n1IUrO+G3rqhed0+vmSpqC59OLR433YsG55E+b+UvLIBGzngqNeBCE2v9DEow
#Np218A8iTg8cAlM24LsPwbakAUkxAd5NQOkFn4IKr3wuY1WjVafHzw9YfBabjDWEasQSBzk27n+p
#z9K0vvNf2py+7vTiaGMsguJmnZg+bAZxUDf6eWoRoI6+d+mRW76Rn4WZhjRrTUEcUuLE2ZxO7iYM
#yFaKcZcpeMvuJnGi+QdeKOT2bxfd/GURCD2NpMzXZamdJj1/S7adNBdXOxw02inMQ+jG/cTabhqO
#ctTjuRfduk4iL21aVUVhuUt/YgpXcr3L64NdHzAknwnbSpGnax21nQm9x88L7IR8dbxKq5TN+Mwo
#1CoIjl7fcPhy6ppqymVxzwSdJ3AqcK7r96Eg4m1ykOAQRd0LLrr2fMHtr6j5ZwPBzditoJ8jSloM
#REGoMrI4rvPHWaOKeopob0Jg8NovC+oFawablmwPYZWdBWwmVFxDUX40Ghyjpr3E2l4/9HLYi/0e
#vNmhxtK7blRnFe7p13D08bqHl5Thgs+7+0+bEtxOV3vYgM1hC8SrIlWyLLGOy8z3uuEazc7y9uvh
#GZMzFA3F0WSUFuXCa72YEZyHZ3UPdB9Ja6evyfd7wV5s5pFK09Jto+OaZhiFRBsRyEJnsu125cpR
#biOLGVrus3SEYxyJ0QFWQkMgLK/liQFBAi54LHsSVKFrRXEOp816DGcrVDLfJN6NIoGgwqhWeSok
#kxZXguyeDnAjGbbcxjFsDbYHwGeIoa5/EHj7E6jf9XBA8LLRISjrhW32YChl8qLz/KCFlupO3cVs
#NZ90WK74NPGy63XTe/mqTx/x9bdNTlsku2COEb+Pj/hkmdfDrGiIJ1LupeiWKYXnmx4hgJSyWc0F
#x/hPspRVtapC8WXdfp7WZf1A4E6/xsUCTos3+1Jru903oUWpOFZu52uerZAMfbw15L/yGMiiSC/4
#xL34eW+16Kcb9nHTgrTUyXJJlKyujajWeXyEnrDP3AiEK1ZvMt/Rsx1mXrjJJvKfq9xQtiGSG91k
#HYCQiQQ+tTv9+rNoYBMFzOrM0ddnz1YzNyKAxTpojSCsOdzHsGtzZIvdh6zu818z3xZCAd+IM9s1
#HVjbhvo1Z3uF/H0VkNgWw/dfvhN7/dqM3r4m2Vc9fl9BsukeQXqM3Iv1/QwNNpWah5CvsCBgemxs
#Kf2p2EO4LaeoP1oTr7J3wDi1W77PW3D6COAApz1nb/99Lq/v59o+ZXKF+NWFiXR+Dc02d/2DI2Am
#srTv+RYIhtiM2NJP4A6mRO955x6WvytSZ24h6CNyObYPdvE8SD9yH/rmim3rqV2IL79QUoZmE/5Q
#0BrwL0TsdtD98H1G1kIRjAdn8spOxa1+fkC9CD6KRh+hOvM8+ePki3y+gD/Is2+Y51FkfubJ9xDq
#QzTIGGeHN4iuEJo+3uJ7NNKS3UvwHMsqKumzGQ394GmvYcw0FXx746+qA95UK8xCnXgrn7o992uX
#Jakki8FWX/MiMiH5/eJtvcVxjyhZ80vW+fMyMAllc4PPEctAKjc39K5t1PaE0pyrC3V2CJQZVkXV
#bDSt7lQvhdyZiszinCyHmZn7RIEPN3Quo4sOGcAJ6g8gtt9N1fmwp2+lJ/JKozX3lmpAVJlzpYyc
#xqw2fQexQ3uxacMW6Q1pWInHm29SffrjBmSbVVd+d7f7VKrMUeEGi4qrk+171DWjcnWjDLtkYDUm
#GPx2hdO4LhrRpdYEQC/H5iEOlC+cUOHQ40GjxwGxbXZSMF9VDgxLgyqrw1Cp01ukF0ttEtjFe+SQ
#9PurCDQUnFbBCR9QQs+kX1yqPUieYbr04v/DgLprJ9wok1EgwIdu4zcZi6d1ZEMpGzHhHxZDoex7
#/VLdLdkC5SvWkS6CvMpLEtAKQ1ptAqJJFfwXJrkEOr92CoDY4WeVJOMTWZLk/27fQ0phJXYZlM3x
#Am4Gwc8mrbxjX3lmQ3r+Q+wKsZhRg/JwkN7CT9p9+UCFFNtozFuMH3w61vIxsXwFxKk9xNvO4C7a
#fXmpg7BSZ/OI4FHmTMssu1QxFMkGOJRJLRmgFtWN8Xjz5Yg6bWRayZXc2ukw35m2Qa4Ry1yxjKoP
#cDlNBwI+q2VXTOLWVNBLSyefh9dV2HezWCJZqLPacX6CmejKOjUYQqXW0nmDwdaMwM7QmDFBFxB2
#Qd5PBjZ2t0sOrWSvBtraUAuqEPAMyfTzZCYDeY0SXOj37nuI1IvPzYEU3BEOXN0Ga0Z1GMZqKMbu
#5HTNKzZqDV3lzaPpAaR2VRkWxeZF3u29kmwykXT6ckEnsTvQ3OtirLzD4lZJN0y0RPFAwucAp8Ad
#N3DR7OB2NRtEQkvHJNTZllZX6GqPlNwwVLg25Ub9CSx5doxqWdXNk+bBWjiT7k4ACvmw7BoReDdZ
#E6RtDDpoIYNDmxiaWAC3vGbDZ9c+JjmsM+EdaWrfhqGRI1aHY5LESmSuu1quNk1VazSOXf5Pfkkc
#4Liymu1iB6YVop+9rLHHy4Z0PBRwTE/fy0YtCyWH0+kOk2BwqqpjmK44QpVWkiVUiQSwGZhOeq3t
#OtBO7Z58Lq5FNZ5itUxmptIwSUhJHiepAf8qq1PFDaXNZh1xvEPsCKajyezN0AcUFjcIiupqpFgX
#StCMG0anUKQig7p9QfOMx+1ox87FsFydZY2XxzNL+Qj88N1gMLMspm+R/Irq+5uc0bQprZiXahi2
#8u3WzISe38SQUcC8algOh6R4qZ1ee4Ieyxn0sEsAmSwE38eNMcNhpb0iRKeAXaxVAuTFsZgOu9wL
#rQhnosGH8IEyQM8GnTZ0Iz9ibh+rFcHL7NM/kzhjvW73xC2kYs/M8C4cav2kqX3RBP3SHnfPWryg
#BrjHXfbeZFrKtNOnjuLTSmVbG76c9ZppYYZ2iAEDUKi6HRW3OIa11+uxR91uG6HgktUsp+hXqc5O
#/hgZX3HapK/r4rsXF5/NVHhudpWYac+Vw5DpgRzgoTquU+NLEu5+Dmwr4zhdgQ/dIoOORcPfqHUg
#QiMNy96eLQpOJVXg3Ip+Zd4JXhW8FKlYHhSrGRQK2bJHqHq8s6/fpPQ2hGDoLVT3tOCffAGJSKcs
#fYcbLG6M/qxQiXJ9UoIW7P97ich0Bg/UOXR6OpkgbCMGiN47CMRSpnsQqBpZccr+qgpDGewh37XA
#TbygdeheOmN/UmwPODXWa/GOhWCUZEmwZvsiMUzWYRiPJN2GD+T34DaCTXdEuBH8qnV3OkMbzc0s
#p8rb00XsRDJb6662a1Umi7SqrJtXTzLltlsX/hpMIeYZuc1LqaWQ5GT4krfZawezz4LIXZn/gQVA
#tWo+wcUBPDWIRO31uowKJnoZR9vfqC9BKhXz6YRkAYQHZidLtVZTaEeOT38EGgAnaJ2K68BUVhCU
#UVXNgJPvA1nFcYF6tywTNdP44y9RNanj9W/ND4/xOjTeV5sUC1ux6aeKc5FW75+3a+PUQUOYXnMV
#n/f8GDGisLQwSkDnzpxp6A7CltvhBTHka2eipEDIywx+8pLe3+evoh1vRX9m6P+uZ7Ph7M3W0xrk
#wRmrgivu60ACwGMjJElAFRxBWwe2Xq1yaZ8jrtoAL+I66HDDhUscTYTsjv/KlSq4Up6x44My+Vbg
#n/Ye62bkXJPy/q/QBBecnnSeBb80Ma2I5cOlZC4336Q8JbL1iHDjoxOvpjNCVyib8z8CWxAaaa83
#ny8TpVQGoqBjlly0R9j43hhAN3ZB5TQbnLs+562vdwAnwflWrovvqT5PNroubtUOf174PfTTU7s3
#0fHSBxzRzZShDPHwPHHRjuPvZ9iJPUbJa4F0tig1fWPYVlaOjiq+q/daPNEWLjqaWtgI1x+sjIHZ
#hUtsqXGT4fzT7ew9tpM4fzYOgU3u6SRLlNp6fHt4JsMbrDsiwSgNpEd+Brp5qI0TENU8/ZQEt+qy
#Ey9Lh7ZGUj3rLSBm2iajjs4eIkN96U1EX/OYRQzx+qodUJTTcQK5Zq7x0I1Cgtq24aUtmVDXFtPv
#SQIDiTWzYNpPCPMgoi9+DIErowo0mssmsoI6D4Lo6z+AqDJudZrwByOpCaK+5UNIzktiiqcYBkHe
#Okyy2hpOYqw635gcyxSD6pZ2SvYSpuL5PUR3uj7vOMzPkxP1cDr1gfP6A+bAnTE7+JUGGf7svMmG
#kV+4ONWPLakF/Wwxlc2SBLiBDE2g1nWvCmbJ3AqbqExenxO3hohV4ZCDcpEa1RIgzOWuYYhAiyjS
#RAOV8hK0CAi0iYIFORDt08XVpBDnIumw9ZLaIelTEpVOwpJQfK2YLhHmoMKJXCsM0CbgIeEe1G3l
#bhTnOYHa8c2aHLhg078I/DILWxfnEnvDf1jk548wDp5/FfhW12/begSUUWAS0E2rmp8vvpzzXlwB
#76wVA3QAZWWqie7cbHICH7VeVsonjFTj7f1gNQdfJ1d2/FyyfKsOvwjQ9wHfP84gSu8oLhrLrskG
#SSoA8g1isPvOnwB0CIUsrruLGsgTffKug3RABFZ+80kE7AyG9aDecXD5yxG6Wrezx+VPnL0k2lnJ
#YSL8//VVyFWLqtZ7K3yuedY2zatb/GoVycIxHZde6HZ7e5qopRGZrfNu8dDF3P8jnYCpzcHljSpL
#r+ItiDrKVFlNx8xS7TCoyoireaFtu2n9pl+W7Hcc4LvK1PXnsDOi2hGoeqNkWcE5SgiCpgk5BH/R
#rztwcsK4AFYfsNQx0GBu4w00j3LPNz9f2GSbNXvp6oE5oiT+k7W0bO8MKibrRvcktKE17LIxXlj/
#rYmNV7zQVp70FGAVNCFKhRoh8BKqgkI01p4JRRkX7YVyTUep3ISLztcX7BmVeHcnLhdM04xQeSAb
#XnGBIaWx63YbHVfpHwB+Rm4YoAjbLGfL4ToTu4luQD5zcHAcDQGe+f6XX//uXNl6CJTB7+JnC7I9
#88LO/dayZ/788PJj9MwD7nFdUWzPt+204kSoZyS5qgFFqAl5Jar5z6/jU2QmeFAUPirG4Lb5w5e7
#HB7+8fZD51rtAk7uUQ0+zcdWcOyN2a5yYcNtly/57R4yrEvzre5K2DtHR7U1O7kGD8MLV03T7X4c
#krWeoM/t2yoZoLLhWRGHKJlxNoudkF2T0kamiTOPXDTLaS14UmzCNX4oeII2B8lDmf6ixLuMQYH3
#FBXhNdbOOTfUujhMUMxTYkUGNiV0Vmu7WIZmv+NOh932pi5BIkZc8K9CaZj2uOATPJzZNuvj5hMV
#7MRMiqJr3lSfajD8gYAfQndxuqHTgwk8Fgr4Ze/jFG6rkIyVdXHrCandZBPXvKKgdNvOiK3iBwA8
#VtrjSRQ9WrUaUmgnrMrOGVRa8Y1QuEAtemfJ+bnOMRe6gdNY3B7ahOms/fXcBizybNF1wdi47D4b
#tlq9RhMBrz+GPgtoM8+OyeF8ixszC5eMsZTL2gXZrbv/vj41lcRSaoprz1HjhW77vnRgnDAqDXsx
#7QTbbKzP5xljSBni4BfoNNEiqK3OdYnOG1SgLdlYm9/NPJ8dsP282+m2Ux6mQi/wV9J/IxQnc2zJ
#DB63L88TlKAoZDLqdVzYb9GzMHm2W+peQOdQfSziVxvJ766d4pp2E4wQm9UTp7PVKeMsunq2ekFO
#Fn0+1MhaNwVZ4kRQJEnzakTLYCWTfNLe1+SvwS/SSUJQpLAqpVo8Zok7XW4n9nu4aqqOncpF5mtg
#MpiMwGwAVy9pkEYYMWUCplvWkSFRynrZsi6Wz6BME4j1JyKYOgw9c0jHe0wEDOuoW44dFjEHqtAv
#cuGchCJyJ5jvd+e817rED05SB6pPxYctyAOsv+NyuJnVtw3cK1zhRH4honXHsy8txwvbhQVtwOcV
#dJXs2V+OxGsuQ+95bbocg3LgIrJKNu89ATrpTFVrVCMSsGczMz5fQPFGFqJlvpvDPFRZgWvsYZHV
#KDlfD4P6WapDwkZLnX4t5MVmVMFRqx65tXNaE+hjx4TzbXMaJCRGUNmNijg59+41jLE6GGh4RZK9
#ClfoDOh255dWwLOh85e3rcDjdRQaZCwfQyddOgU+6v8qAtI6nDdzK2zrJg0y6lD5xTpZJQOYYeoB
#VBmDBrQrj3IcOgVnjbQ6q3erM7DU6mjxkh/QgckSAWFmt1oKxcAwQ9QeJENhog2PYS9TEuoA4B0X
#NQXOOWNIN3ZNHHj1YuHpr9lYDhCBwtZREBBlYLbiEN19Szi4aOAN+Um2lcYwZ2HdrIKN9qhQsvQE
#13VEqHE4qFP47tDTM55WY9nTCr6i25s6XyHG8GlDyEh6WSikB2LRZdFRDVB7+melBr0PhvK/kN0L
#q8AQbLue6sztQWGQ9PSwas5Ibd0lJuXyHsSTVBDcDoepmrsWTvqdlHvW2ygcP6mscBHuGdJ6jnYf
#wnOkX6IMHlf+nA6LTBkouC+oFj2Dn1sZvy1Ohwb+YTEvg0+QsIwij6LzpstGIaHY/ananqnOaSRU
#e4v6MUe6hF2Ojsm9XEXGUoln4fKErRAbK6tu8zi2xgUqSzsTCGe7So9dxWs8xctcutsf5KZuEjmZ
#qvJsdnWQfoEVRPT9fLTHTz7MSkjRsanesJqt7NlVzzLIsRafYdkwo/e/cZmweEMmQU//TnYBAVG8
#1y4zLrZ5Ab8LmEv6OvCD32rcWF3r+FEWSRKBGprdxanZcHWjA51UgGaLgih4e8yiBbqloY46OTdk
#n5L5jJhyhR/B7iYll41MW2jNhG7/6ohy/9YUW4e+pezN0u6LzlLNV5/tz7rN8BGR4AGYy3tAh0R5
#IqrNRJkFz8rsxfH/3sslAywOPVOIJDhCQQVjAntNwJ/9hiBMberS5BtSFl9lOBLQ8ZxemDPMMISC
#gyeEfjbS7bu9SbXA6a5z80IE0PTBYHCzaTwwBGcG1TBU/kAndcfqS6lIUBwBUnd8CkFs7Gh2t+2+
#ka3RBifOwJkdW+qpcjlJZ/zMMOUAW5nlVmBmERy13M9lHIyk3t/Lnbg6qnLQdGgl5zqr1tB0lyRx
#hXE37z4T+4lSlsB7WMBc8K7OXVFIY07V9k3b8fAeIfALzGf5H8UsaOKg1SUI9+rFuasZBpOLUqxl
#mOO2ab5WArndSKCeD6eObrKfCwOzRFxWWI4pf99q0nhLTyDHDca7W0W8MR6+BKNUaUlmkUyGfI5Z
#usgZqJC2552rsObmQOU1bt4plTiaLPSd06QyN6Bn2oVkq0udiFlOAzpY6rAMW6w70MWQEq6kJ5qR
#gb8aJbagTVSujY06ikIeiyktBa5zuHe3jnHGm45XGIBQAUx9w4Y653ShfLDOQFq1Dnt6F6fn3AsS
#k3LWyRRDdNF0MIFubkYMseG2hmC56T4oWffUlVMhGwSQz0Q08XXwXISSIwkC0/eXMRgh8duQBEXi
#3mwmx1oimEmBUPQgkLOgBR9zMWutxbyG2SJx441DWhIVhuuoc0ZPCdWfPO5N0jrMo2C0T5hDyxMA
#/wET7QQwQJj9tZt/R0RxYFI2ROlbIQuQMwwFsEx4ND1QLkkg5VpHrJnEfgZJcCcsCB5XG7OcSck0
#jfGZ7lTUHk/9h5B8fjcju9hgcuqVfQRqChR+iRthJZ1Il2zqrRaTyYpFVYSDlSbzylOk2AM4TLKE
#FFmrq3Yjgbl4f8WwLqKM0XlvhcR/9oGgu9tFw+2ML+P2fJjValnyeZMVTySRoU4aDXS84owSmRB2
#jS6dhboKdPEpRuVzn9Wy+pFQiuPO8vu2sG0y4ruHHFFZmkvYvWRy4YtmG7z3nz++eqKYJ2loZ++n
#W1G3YwHe4tpgyazfwsIwzHY6SKDdEkz8X3+qqx//7DHg8SJ+7a990xY+n6dErDbUdgSa62qcJr1S
#NJc0NTW4LQadUiyUG+qbPYDP0cRLGzxu45dI+u/hYbMKabDxO8brC/shdwZ4C+42Z1VW7K4Ti9df
#dQf+T5nNf118/wdP728GJ6HXPwRRVQxXIVdtrtA/WHKWgFHa9MB0cRQ5M5Ps7OtF1mLXqmucdEBm
#ek0K+MZ1mzKFBPwKJcGmgCHMzkC3n2XZy890psASLEus3UkwXCMfc8jh9pBO/wKnFPMstF+hcXK7
#x1quQoHDsOnnt+1KAnpLiZ1gLQX/MmpJLPjSmuxnEwHsYuL+AAOBMl7silJi9glrOSCZL1wU14o+
#obo96sNUnOua2NFLeFmByX0hm+KKZJ1y3ENJMhdqBJC4NBzrgjWwDLbrco+VWG3yrmGbwhJpazSX
#VquzjpMj+N/C/O7Tl0sPcNKD+cbiEqcyl0htmRpMkhmkTKETpKLQ0ncBpi+qX2QpeY0vGeDUZeid
#piedsW1tycpCI136rshYKarzYY5qxG1fWIlO4It+bCVs5BNcU7YPLsmdzk6mgkEb72zJdq3Hr3cG
#G0EX0hEG59PAEIi47dj5z9vaOjWSJdXxhZNtHntgFMHGu3I4yCkkjxQmYwgbwVAbXOvIbDJUHqgP
#qTXecbB0qnUKOTfj2E9c6ojsdTioaBztmroIPfRzI4MS0ZS/hEVbLQFixODRszkmHShlqGTqCvx1
#HD5z0obntSdtGBpRcA5t/GHpZt52zHYjWowOmGcPn2owHcel4byGCs/1fCLSbtgVry+DhBhhRaGf
#76q0ebC98F6lLDWAJNLZ41p8FD0YqX5qDQEyT6lEKLtzkxqHyD+DZyJnJJ7sqtdufCm06ME1niZ7
#mUKn5/RYi0xCr4oGT3EJCtM+i89glEHVV6JqV8W2f49JeowaYrPpsg1RyndlTCzdIjFVF3DE8i7S
#fFMqWFkVEjlGkN5eX0NcyXnV7Pa43ueBYA5xY6ltXDOkPRYQ79x8uhjQhAGF0rQ1je4aDoI7392m
#dPjhzv3SvZ1JzrwrMTBLk4fnJLRGozO1uNFw6ggD8nmOshsXRWNBXqRSWIFojuSaXRMb0yMCwk0V
#k1PJVZUjhqXWzziZbeWGzM6fQ5z/jFn4gf1LwoexvzraZD6d2uEnwFdBtaGXyu1yz6wGNpdrTKnm
#c2GtXqmHqgq74snEb7qVTemrVhB8PwgvI8hSSQAUV6U+WMtzuFyX6njNekNGQzpHj+mqNbc3SD6C
#lMHhjrnPKBdqXpnvlHCGkunRHV2/WJeqBiaj7bCWftZD6xAhgOhvsWypbvNzGyqcqRgDLaIp5BQc
#riqBIWJCiL4DMV2c4Z91XCqWAsZy+PJGGNWGjSWjlFkbli6uYSRHBibzwZm1LLthImt4qq2fCWbD
#j+DP0Mue4y0QcsJPQDzUrN5sMk/JXGWG9lyZpVzXBorInY1t7nl+EJyB3S0tmKhUyuFMlIbC87Ul
#WiYga2qKYO+aPVY4T1oqnMKoL9YdXMtP/ThRIXwWcZYRuU3vQvMJgoE+iHmKHmSxuMcpOod1XXKI
#+JhAy6JmpPcyrWHvBluWdr5iVTmaqsplrDsPL4RGfK5+MTe1m3RbOdk1NJE1/dExezPvlNh71qR4
#vOznx0XX5Niv33y5GFE98+deiFXasro0e8qqLgIveV17WxEgJSJTS8r5MBhjrxaV2qjjkJkgWWSR
#lxTl7eZyHfREyrwWHGVS5TnrWkfqyDBy0BOu7bsfhx7z5357VaLrFZATUh6guBKL/iBvnFIpzhW0
#O5Btse9vMRMNOcEI0YpFQ5VmSjFdnvudz0YDbBjAycAP7fx0g+UI5jB9DlnJYWIS6GJvNDHeMfjU
#0+Nq5fz3a4piWwl+tX/QMrXtj4Es6vJltwky/4sunrFLpQkPtsQbGbp5a4gju5KQ9+lE8hkwZPI/
#Q32m1f2xbqr6qwGxKcua0to7heExJB3TzF4uT+55a1PNlmKa8FxXmQRr3d5+p6mKQ2QLsRKj6Xrx
#BH13urBtV9IkOvb39OJIH+7ydGKG4fKjXiapqYstZLUhVZSgOY6KjnFjdV2bWtm2XaetG0ayie2c
#H7O/nDNYiULuXS92I8Y43hk+hvACtC91dlcSiuCOrm5oLJgtMrktdvG6kFRbbJkLaWXtBKQotNEB
#RFnhKVWoYtLmh+qmUUrDEng5b9pbDOinzfiwkkzvTZMjNsXqGPjhdNtWrPZFemN8K2qeTkDh8tpm
#n/7WwKuSORTAP76fzfzhA9m0GBlJZn6RwkBvwFMgxcOHRdNUXhFy4+52gHnAwoe3nkQdXoD+aDFA
#BArSHNuLQam5u6Iy118mSXzBMnM3w2j3CY4iJ/IbX5LuX/Pm5DMZ7VBcb7aqcWeawVq2vTCwGuR+
#YONBKaIlljJ0zQSC8bLjrqifw9TiK3WT4tC+d+qTd20MN7UuRotg8jLWgaQqEc7Z3EkVYjahMERq
#cd8ipSLg8jX0mPkdhkeSq3rpzADrdWO/8SUh7LP6WIKnZFykLRBJw1s0y5LmAiyFNk3LsYCrO0Z1
#WF/DiGNX9K5gOcnVO0f2NwvRix8+Bc2lvBua0xM9N0+S6B8TdAGu0nba1Q1wPv15/41oOJEvVpRN
#pxyK30LmhZTVSnuJlZizIXgNi5EatZzFSt+exjxu36vMYTuDtEB4d1Thvb5bQXzyJD7eq1marwKx
#DkbV696Gwo9JhcbEZD6fGRfFTpuYaveztLPgUcl0ltDzCu718lZ6jBZMzjjJdX7Sa7A2RCoVinng
#LgYo+U67lQOmxmigLBg3Eza95jkFp4wOznvxwY3gK6V+7wWMhwa6eGTWHsttQmgq1szn4ufCqXgA
#DLHIxap5lzW2ATv+Y6Ex14G6GMJni2MBaQLarw6K+SXoJR9xVLIjfsX7r2Q5xFd96UomWuq/so3V
#VVPNKm3VV1I5ytJtHvGmqklHoeatDBXZRmBo/zGGFOdLDDSLS2OFNqclzBFLIi2HrwMi+HY/HQzb
#jAmIEtbAGGSSoxjHIUGZhEFnljvEbU2WjmMLqolYuwR3eqwlN0RaVTzLwF6dJdDPlCGgpHNVEmWa
#n8+RF3G0HMrmbjh6Ov3pDboqUjxygqdpwJTIOm5oVUiNhVtVEuHk2p+G8rLfqFJi9GfKho3JXsDe
#yNMQXol0cjge9Wo5dYhwWeN+jrJZWhazYX4OBh2Do6kOy41YMeTxgaVrxpHA9LVClW3NUsBSpzNU
#aiUt2Jg353U2wFLEAT9jExn0OsEE9CnvnWZXh6wmX3YLlqWLEX2rPibLCEVww/kkI1dlx6YQdQRW
#Y9lK0Uvh87qNrfA3mzdNZClTrPC11DbTyQlZ4JyWJPWfA8SVBFkiGrVd7xC4h7CAUVdJcYODqwf0
#84cmJCKWJHttQRnKW9f5/xwYJZTr3/lqNaeIMBnHw66DPTN4LbUEbPhaSXvvHz9S0+JRU8fuDX/A
#1q40+Wn7tT20lfnhEFfq7OH0SwrnIeR07rkIFAAREl9MsvX5xa0EjPJZMxpUWXQzpK+yyTxeIldq
#OQIFKP+X7a5kPNujez6Mx5NQVOSi9sdBpaYG/IAOs68Usp7cHBroYuDku54Xfr5J7L1R36QHbWUK
#MOI8mJYJD6dIhIX6UYkLBeEtGPhsh0kd5xYHzLhgx7ONaTOsdGupY4ZvAnpgJzj8cE7eeyWomICd
#oCA1G9IgEvKxPpq8x2x3uQkmlgioceRebuOvEG77EQgKI1qtrVqdNCbT4cDjJM0YSKOldyN8EmuZ
#cLkcS8g6h3iD5c6t2ZhgccgmpJq11dhsNiVuMhwlyTjLPhGJxjguxnq0LAZXJRsjpAA0aVKNiKZC
#bqK9baVu6gQp8me/3UKohTLTlN1IhwvOUOpYwFeIQeqqf8rjV1VJotchaE/FtSAPCgb32+hDMwwh
#4Ta1P+rtAeadZ772saDjzDzEN77MbZjDi17sUR0QG5HLOIthABLqPfE0AgKP4eZ2Z6buSi3vOJXI
#iXjbG1mtTIHNx4Er7QRtrtrvGoev1+pFjrwYuMTXeKAw7/iEqD/+th8AvLXN6CXEe/Td18OVG2ye
#u94JPpZOAJvHQ7DjmRWHdhO0Eg8jRXydxDSFHI+hXAYMBjdyuS7FO4AAm0Vfude5cGZduon7EAJk
#S13GpE4FBdT8b/f5nuXbl1p498qhYCxF7enK0G2ShO+5LYq+wWUUgK/bPWTTzhiwrk1e69fW/bRz
#+BlAAAAvStrBrrlJ8uSbq+l/vxA/aFphPQyDTlCe+xc9dCaC8ZPK1snDlihAcNQRr4CBTegxXZ04
#QKt+os3MXVPLJPJUgkFrdYUG+8Jr+T/2SiqF7qCqj77DlV6GN1fmuO58uhvvSobVJAcMITHOYLo9
#2UZA5N2riUDTAZIjRGSBusdLEdrWdG4bttjU2mF9yCoIBC3Ol+NA45DSAKP0sh7s7w7IFGi768zr
#U+nNzBX5vYfC8JB5bD7oipLUSWb+6p8OJm6vyBkYF8by07uFTw4xXugB8xXctp4STj5Bin+Kija5
#3t80sP46ugEawH2HnQ5gUT2hx3FjkV2JGh1Zis5iC7SSUIZsR7zyukQkrN3fEkmp8ciT9mAetgBQ
#FozXhrqM23m/yIaKOeTEFTJAWL5xZbVcLulNPb2/iwLzD9JpPTbEJa2YA2WkWlMzL5RHJYILlPyj
#+Cc8GSzqKazX440lTZd1VNYBy6ood3cqHWuiviWnZfhP3GtA9piiuVu3O49gBAeg3cu5sTPRReaS
#pKxz02+sKV6QSBJdhLwLDLKsT5jn0q/dhi2/IMnk7F5WwWVgFxVSeVOmvEUMn+ByCEePn1BLllgg
#8UtThWoo5JzlxLRaRr2i2BlQ5zRpnHtRFd6Yray5xSZiramVwQ6g7aOa7YKGmB4dZynzDKPqQJla
#KJSWdyZqy/WWamTDwcFR7qa8dVOXz+DQbr4T9yP+4VFUML2luYAA3yuf0qHFs25oORDYh1dDG6XW
#eRHxdAKfKLGdXOkCcxOZi5FltuHaaFxiAQMSYoujCanuNkBhHDr7ThaYYDXstHER0lWImgK/Pze0
#xIwkv6yoJTuCUm7QSdZih05yNKGWB/L5P4oLu+36+2dT4zX4GXNDFGTYHRDm87C4X31jtrhWr7IK
#Y616RlmLdrz2WlznHYVbA4OL+o7iKfxcw7He3wdm77qY9YMidaQ+gsmAB44xLAEQ9DHoPkSIVnYh
#nvQF7mYuYsjtwccZtWqk6dDc896w/nGOPn1EFmTHfrMb4A9ekKxdv6lvg1gyY71P3SjlEbfmOHTy
#DluzLqtIHuZ5QRDzODUTFPjv9BRJ/Dh76EMfYzEgyqml1Ryjnkz5xeicBzhguJ7rfQJtjB4wyCxE
#CDYCtAtBn0ed3c2rbLOuMjxhhWtpz4O5bDyZmvnfgujNByVHncGposNXcqGvP/xEB7NQaiXMQtwZ
#4lBuhTkYd24Yr2WmqXOTeGsgXEmw3oT8neiUWlsKVQg2KS5Ah1Ctp7uB/EN7Mh3LAi2K1NYNSCwY
#40e7iJpHu6tRlzFMP5OS20OArIPkndYj83wYBjIbelwBwHCHj0zW+BiFBHwvPQ3KR7uCMvusITWz
#YC7A/ADDyEBoKdHptdzlamGiEoHUpMA0G61Ft4ChRR5h4SzithjrJIWKMDmNJmlvJTUYAm9nu1Zw
#tuePx5WNosj0Zi1oBtramKLckC+UVsINlUKJ9ApopOdGwr59PEPYqpU7/r24edM7/7Y/PU3oO84r
#9nf0tZq59lWv1QxnDotUWvCW94e899XvyOwqqepMYPLWmEe7KtsTa8b2I77FmIZT1FTX+ji2UHgr
#4bE2YT2xVwFD4ossyBuFqjhLaF4Ew0OcZrrmFrP0XHt34yAEIFENH9g4SYzRwtQl/kCL4vWUzsGn
#lgTDiMd0U4JvpiXPBvD18zmuR91spHFz2G03dmMGY4uoE5UgHrMLfgL4cutKBVZQSVtLa/YlNt4F
#vcqzyPn8WKS3YcvLMJxnagvubEFKIU1adVU06T4OCfd8SyixRFBqP0pVCRqtshgXsyHGyPN4Fmyn
#plQy1q9jevYnWrVPa4RqtPuSNbNbE67ak2Wy+RZmUTfej6GBRypCLlcEo0+Z/hDXnk5a/kPhDCdI
#yfZgAn5CxVOmn+yyjbcUwfLGi1A/iPpHoNrszehkp2y5ln2sUR5083TlWjpiyCBhvppkpvkewvU4
#+B2c9hPP6y5GtJDOUtjZIwQXTIzaMN2A05RzeQXOoaN/HXDCvmdKPpaXzpPeoAoMwf1i7VlFQBjD
#Y4Png4BB+1E37bdcmhDyqXHfjJvrtkemY/vldE5u/iORj4wQ6jHWPbPiUomrQuXOzZwfHFvuqjMk
#uydQF/HovNioSPPJLuYI2GS7JaLSF6KUnPk8Lu8jYsNrKEwRt+1WUUnpFBbT1/Yz8EVHZH+dH2tX
#+ALxalfxg/FfNTEsR1nDLmBUik9HoiWJdtqUkqY2w3rNuMu6em5+KQt0K4y1O9nsrW8c5Wc5UIDB
#c1jaV9UsoUE6XSpVk2iz/UjBJ2Is3wbuHgVr+BWhLplMyme+iQlS00y2biuftJ6cVEolEqp5F7ou
#DovEqPZZe6LpEebDx655tcxtSaVRCizectlsQQptR/rVNDiuuMD2Uy9RA+nrJiOWBfi+SPhGJeIb
#HsUE05sb8xuosXAzdzRbbY9Wl0ptpZkp7W4O6+xq+vAV6PMP7oskSiJ6oQsSZwg/b7G4EgXgmPpH
#Q3t/ff8LtYwic/1QNC4coMD8/TwKrZ9dxaSHa7Nn0K79oA537WFz9QQCdEcSBGYF6jCsRviCInkd
#Fso4in0MhSgzmMvG/f78LOtkjhttfoSp2WUhoIxlcVXPgDrTO1fnXNrmW5vampdXA2/lFxxQLidv
#k/4+4eeShJQp3ATNvil+1ZZOYwu/n00bcHMYa9iMxDVwsyVKKY9zzQv7If1iA4OQR+c9mJNsOb2O
#hQ9vhpvIMS2ej+PTQezsiCF/x7r4R7zfsFTAYZxqPkK7bELuBes9DdmNPMsjVudt2TPN7Cr8pbTj
#YHMl6ZlOuZyvHkSieGBFo6ILN0qhyvpuPTJ43yN8EXaI5vjCxPAUHXvsTMWh2dPv9s+47eafge1b
#BhyXXCF2cHGNwZkLmbJ4BMJcmbSGPSsrSXiFqtuRUm7MNOvQTLh0lc4V+ZF97yxdImKGjPa/PR3c
#H6DpdmkYmzFOdGdIxELBO0X9fgGwS33tceOiUh3AXoQddankSmAiUUohJ6+CPLo3bctLKX0RemVB
#VD/29MH5SnLRlPisK+ZCIOHor+4mYYgiyih5jkyyd1BDF6Rp5GPf8DkZ5JDaepMT2tNnjmSq6zsb
#FAhYcx4SyYTqsLR3MhfwXTj+HkNdl5+h81ScpuPW48M69qTfstZtObs+4SdXqxnGCCEHgCeVRrIn
#cUaT6ZLaMISAP0YH8WpYf1+rNALsQTHM8TyX37dQTxoX7zcgfyvsqUdlV4JSqULcjs8jl9C9ZUex
#nzGWmUWrkj8oCJy+WBtfds50ozXlPchR29BBkK/cEJD2MiX4IdHEEzfg1QK6SgdL/sB0MCkZqZfU
#zn/XPPFKlnBlSjMHus5bVmcsxdXtsjEao/NFNMCAiyTB5P3dfkYEe9aGARiUcSmakKjyWftsyFJU
#VOmzqJzlAhOoIvGDGbe6CrI8J3pxfS62m7jpBBWw4UCtE07AJGjBSLYIxjm8h4a9KSfN+1CiLguf
#oSYP169M26QX3akddEeiccei+rLiiCTnZR3E2Kr2C2k3mQ0/rHmekEPERsUojlhr2FvYy1cRtesm
#/XEP1PVlziFhO2qxBe0q+faDz/AuQ4vJeA0LRsvtTRDQ1DV9EIMgCmuatj6JAhp/ztRiRhFunBu/
#k2l/QNNkpkWzxhYDCk28gDU7jrEkzgaAFuLIX8eFuyQOOZn7LMAPsXfkDhEbQO8z6CzHJTRYs+CP
#CjNGhxPAjQiaNe2WUn7QwN7IIp1+eEhBDaDDGAZwN3Qzic2MpD3vKDCU4g2g2MvmBtMPugB8ESjD
#CFtvJ/2eMPbz7+7lNglmBcVM7y+2EZBHN4wMzVbWgTg+SwGa9DViSL2bnjK5RAxamiZ3M4hmEi/9
#VdabNpmFBPkEPWgvdBe50W5M6sjlLqzt3gJi3VjXs53ccbUmmuDtNVYk/+3j1EE8aIMv/ONNkNzd
#XYOdWXw+B1QvV6McTNOP9SwyIhivwVVI9uyJKN0DtIDEQNb9lr4ukJMhCAxm9T1MQSe74KxuFkys
#dyG6sV6vouQ8eok6KgtfLR/Jh26AGR1CHl6m086TbAAooRl0wtqUbQ5+CUdILngSwjP0IpUfoEMu
#UyRjO/PA6aD6OUoTcHZifGwPtoyIqBiDyhr2I65aQ4Ba3DzC0ClStXgeOk6bvZaDMq68AnTR8tnk
#W0VnLW2JiswME+qrg3xpYCowH3DM0hLSj+vHxr1zhiCtD1Tw6WHp1IQECzjrqlLWv012nfN4NX08
#Nuzmre37OChUoWBCs6LWwOEb4P6cSvER3QdEo6bywZBcDxPEwhzMmPY0OYWK/Nw/n/xxKn1Y9z2k
#7g8WFJfCi6AUf6hTqKRowO1OZYEeX4HJ6ZgZRWSO2ksHsYbt9sr0H1979teTIWuhh6/VW2dVuZqf
#TkFRGO21rd2WGel6NBoeBUN5zSyQAdMw8T64lLhU140OHHWk/0cdIHhgnLbtmaPAxhCrU+GOCT1z
#VIaglvXoc2aleD1Ua9kDgIwHcWrmhHbSUHDqBlG6w3VcDVOfZDxtCeRoL50VjgIeJSFAjITBeRyi
#7nJlMAXyoxNTcR88kEtE4bRxngfHGZ//T5z+0vbXjsH/nbLpG3WizOyKWRUhA2+ypahhoGEkvq9R
#iCxMWDfoK5BoKiqS/6XJgyChxjma7O9JiQj1NwMxNOAsBn/RIehIy0c3e26TOXwaPMdqqCW3xO8f
#/BGP4DzPCbpsJNwf+RK07GKaxU+OJ5nNdDoSVF67+ORMJUkcyqO1mgS1AruurLHLD0Xy5t3Ls7Eu
#hB4yT6lcoZDGvPUVUQk1+1aixpMtybS4ZLbULJw819hiq9wqxRy6EkVzE8FLkSSp1TUvb6q1WVtK
#rW3M5C4snXK2TrXQzWUBAXDkg+Ha+y4CAUtfh9YO4ar7mSM3HkVPWCByL+xOL2y8/JpRd2GlisII
#ad7ZFnJCE33Eb25ZpVGyjLm2jVHbuXF2/r3QMpCkruTZRBz5q9N8MJxOv1PVWuuikyEIBJDXgLph
#aUqmHiBWfnVx6Pj2RHDocoAbupAQpwk+iJ/pYLwEEbRA/nFCgMZlZk1v2TD7yvwqHx8Bcno+2biC
#7lyfHww7foiyWICxAQAA6ESc3kGzx4H0R8iJQ02tSiP34FR/hLJie0aJoLj02PmC9PSG100TW2AG
#bfn310QAVlMyrR4UTE1nUG6RMMmamMaj//4VNHcE4Ki4jXrRFlR1UU0p7INAq4QbMU65sbYp+6Px
#ajiczTDPKjXOKsH34ehyj3F6c99iBWoZml61uRzRVUDnKFkyPEknK16czstAtB3JY6+6b/hsJI/k
#YkYr7c0uEwVDhTv1oWsTimWjJdQFfKTWz3KeWjbgRU3poMTzu+I+a4hDGsVSXhTwPh6SEPgbm9oW
#tRczwBB39HOVQDoZRM084ogqRNus4lizuSnScoOE7Gc5a6kmhSSo5o00MSGg4JNhRgWCM6tBSiyR
#RNjnSMNJayq8ZpFDlWcgckb80xb2sYZOpo294AjwDRhhoFgLgAXG+W+iJEj2eLHAdqOR7FoC159J
#6OfHu0i730a9fiUcYrNVenk9YQcFJlTDgAgg9h+3/FUG/CbMIHQxjeDuOuEWmhO+vUC4RXnL1BqS
#7f6HN0AeDd8bdbXbRuPhhKZgZ4tC9CNNAFdILgqtkwZpPShUIUTXOaMgxD1GgscEgsxhQhVTBgR8
#NkJu4ErINbdgeAZijxlsUeVLsSCsrDl/BGjtFc55XVFwQKSRS9939ed425oi/L7sbw9NvbBL/WRk
#rxDIp+uNxy8OOz2s1teU6OdTePj8rZy2sXulmc2WPPfDU4hPBBityQzKeYK2PcVGXiaYcsbkNY8Q
#tHwWHO+myYCpXJdAMkbWTNN1CFJ0w/l1MQHq3n34ioj9h1/1RfLqMD/ljJjWfyAEgZGfYwHjuUoM
#ARKHEFUAhFTMmtZ2Nzjh22c8r0LubkKEU4UXGaGcjeEC8uzsKLpj8eN/xIggz/Z4bQinYxQSp5mU
#3IA1kt831eYp2/YURGf/X2vI+cqBcHxaatyCr6bhbl3VshD6hxPv7AQ5BtPaOMJku0ZiQJyrmeIc
#ASmaP3w7rgXPv7n/PJyPDg1CV46cZ8KUsL2cgiCoGj1XOKLyFUWfoM8BM8NsLhTE/C5TWeQik1Zr
#6KyA5WTiV3PaxCZtWPb9p/PlLlCEBhKIyYyS4lvE5D3YK76EuumbdHmDUb9C3xtdqNON9OUD/ol4
#1EuvIwE28/YlXVrx0P2S6DAX6fNI/BwvrrbkZyZW4EsYrHlnwtbeUpYNnfZE+fRZ6QVtyTzN6LdO
#T9861Wu5OP+cuT8MP60lOfutt3S4gJZbtd9xe5CA+3c7+oTUoD/pN24GxiIpWmx9zOU8zwv6I4Te
#pEtGPUT6SENuc0IvLwEH9jl3Eu6q6CBKdOzbKnUgGzuQxqzEzML57PZ/ftA0g9ExHoV6pCGPcnJJ
#g4HV5HwbiQA34UQAo3TsKzg3m23MIUjZtpkFL8+uPdKNOIUQ3nYYkPZpGUIP+uqUOfyZwCMfo97A
#1qKJhnoiYFhfL19JAx6BJBDDKKv/UizM2aw6cYAjbUJASVRsX4xX3PO5XJNmGBNHd31afbDNvu37
#45a/Fx/sAmdLcTcSC5z3ZvdzVdIATy4U7XeFQC+LOxx2i0HnKIXdU6agvbC1enwFBf+SaA8mVroD
#t1KYuBq0Oma8c1syLU20HuoiW5bbSTyqvfSEzf/Pg/uuPbql0jyP90npTfgYF0xEFDVcXk38OiDi
#IsuVM6hKbkRIdazYSDS145gyoebWwoKBBSguPRwPJRuj4wf0zdKwHh3wLlrFBLT28zh1LT6Qfsgo
#YygEDGbEbrKhmBm1UXhnu8PldD1XehMCoIPXut1vU8u/WRuh+WK9WXdz4JX4OIb3ehZpqOcxsmLT
#aGic2FmuDBfeSIXDqLz3un/2siuzKpFFT/fHEziepmCfzsz6/Uy7Oozl0HnhvXQ4V/+kzwzNLunC
#FuPgBvRUKhTDeJzUcwfTXKE0kaPNZxRFfcZk8ShbY/jawlYBgcHoatUED3SNZz4ppvbnUJPNXryw
#B1rDyfWuG+Wz4XJHcUPctSjhYkljfNW1T9is0H8Gfey6ejDbsEW5ViZhDwii00Evb+qwacsUNis/
#YdIzOOh1vJYda1fxjdYwsYVowAxB/eRyHBMnIIlQ86I9lw8MLX0dIpY4sjyergKeGeVUP9evKhzX
#xbXeMYK/4odKHl56KUITNCCCENOWDwiFFj28ubKdgCFXqOWt8ajPbgvz7sNP/e7OL7muIupUgkpE
#ez1YCCZKlfwodMgCOQYg9zFD31H26JM3Ij7fElnQqEWe0816TodObkNGom+sZGA/yzPW010/tnxC
#mUTG1hldovSPfMnstBiNK/HcnV5QaCnT6nnK3n6maacEIG1j5cZi9KFPICC74J2y5KjljlUsLt6f
#JopGFF5vKr8jpPHaqjRtsxkzIHKi81Rl/ANkPpX6ZNjilySKQhGKwFpkFjXgZfBNMbrfeP141G61
#z2za6CYsU4MAJatzvjhpjqRo+aO+UD7sPdTw8YNDlsyvlTDw+p+RqPI1yHWBgBFoNFJCRKGYlPRp
#8Wvwi8DgFRRo8tL1HVP3tvIV5PeZoHGJt7Z8GmjqBIpolo0hFg0UjxO7ARDoEirtwNA3WjP0Y3y3
#AJ3YcF7ZGt4HEH62p0Pb8vXzNFVTpQT9cQ7MdtHVSZC4ws2AiP3xQWCs1ZzIszSUOgLOjTgBTEul
#QCrDA9LrNe4fqYEQ4rG+0Anfuc7zHRAp952XRQ9CFhhCxmWzaeMzeFHhOW13zjiYAeDgnRiwizz4
#4Xgc0C5bfQHeOoZu3cD00mOIubJkCH85GhyPx8CoM7XXfvSSgSkD9I/gwTGM6SQHqmPZFDJrqzqo
#j3SDIJt6Txjhcp4MQCgSP4vPg+nuLkEijgLs8FQcXDqSAL3B6feeQ6YmebUEpHczJhumww69t5Vd
#yr1W/JMxgG4w2CnBqI8BMzMOujU9BeL9OejOuvMvEPOahjugBj3ab80bfHvVfkWMxQfbtm2rj8Db
#2A/muSw1DMoZQbBKZUBfxgg4rdKAz8iDvYoESxntoE1VwakRCKgLTvIuSB3rLkOsl2TBSM1pFiE8
#/dYo1FU3pAyNz8aFWYQcW8QiZ1lREwDFnSDvnsW9pGbHknCMURd10F85aCIj67IL8dY07YUm6fri
#HVCmY6yZ/UILboIF54nm9jEhqNRhLXrXMQjnvOqV/OmeMQ4/DVqln6w4bHrwrNxkk90HwiZ9+Qyp
#sv14PLB2rWoTfSiMZHKaG2CyM7lGEwC2Js7qK+VQoK78ACSYbRm8kjUOQibq0bslS78EGgNoLyvW
#jOf+ymQfm7gNPSjyYcLvq3i+e0aoCTAzroG5bjo/kKGDkGqCKRkcEFUWNI9hjwqGbdKU3y+ZsIOo
#zToMtjsxdopFkacSEaSPMHu3gbJPXOkWT4AzziFllj7QtLCXC2bHtiPWH/NFcGRamtcMxy6v6dJO
#+cC+wmyYEUo02Ko1pO2mbYKPYEGHwO5b0nafSYLDGi/TCc5sTzbsZS0L0Gxm6h1alQXshxkCIQ7G
#+FSPN2Bb5eBCPLS+BgYrocIDW+lmKDigoljoa/dD+R3GZy17t5QPye7uN7Bzpeq6L4LGJw2jlwKS
#tAMKVl8QHNqnYB2MAIxlQK/GgMkrPwSH10HsHU3oUxiW2/AuP8ctJ/vADgL/FQpTe0PckcTpRT6f
#w/XfgG4s7xX6ICB5l1PvwedTn1pvVZ+qd++WFpzC9kGszwxA03e9ArLzuD7k+SyDHfLsCBatIwos
#grxfjmene+XP+QyjFLZWC9+NDgwCV1L38vUfNmx/dbX3ANMTK/ARfYb/EIWdm49GSZNNpxvSQv7D
#5MhpB0mq+3V/6XWwv1v1BuJcup+8QsN5l6yyLCxDM/pqQMKzNPjvbw+Le4+R6nJf7IuzXRe3nOSN
#CFjSRe9l7JQMJMDWVj/6BPLBgG/CqBTar07AOKhV86XRJSQS6vNM4pYD1W14yudjy3Bq4UcWo/Q9
#Cwyobdw7EvxUipLJrXVY40aAtJhJA5InTtVaJHlEHXGnPRP49R+Fm+HDItCRzzznPoJAUeZ2yNz9
#5Vd3f8dic37ngQ/en+icTia1CmP2KXATKmOrKiGE7U8MOT2qRRQO/0ffQkBlRS98G4HJrJWac/fT
#IvzstejFKdYZdFiNAhmPa/0zHawhM7Xjx1Mzosp8bC8ylmi2ZW7tfPBgUAbxV3d22FPRms8f6q9U
#ms3HcWCywpt3n1U75ljiP65YaniCcob/s0KrkHUbi3PbdcRjaSlwtU/bG3ECQ9vsSqmeik6nb2wB
#9xpvvIHsdyU2xGLRDqdPi+BfXjvd5JAGxCw7mSiB39JAIbkVSzGq7i729HkHChYtd3MLCDfmWPBM
#BGxnR/qNFrLWiIBjOYJlqjCNCW2pWRTjAAZvGeq/mg9fi64PwVi7dFr6cJLx60Ygu+kDoyHsQ9mt
#Rl8ff4VCeGh27y4IoEskLcbbZhMbI3diIKJPfUYm0/OeSodG161KI539sH8wVbgs6e4gek5MTSkX
#EjH3yxlBGn3cNMrO8BfRXzfXOh9jS1a7Ht/UCjQ+N2rSWiCWrPJlTu6pI6qmLYb2fiJj2X0i2AQP
#4HT1EZbr/qiWuFgnY2sHXztWE3dlx/psIGpcmvC4Cun6WfmZOVmh+DAQZ6wlzeRjUFKLx7FDrfqR
#tRjm11zjxeziMA42wLySSD/C2tPK5TNmcaQoU9hIS7cAPdgJnaNryXY3BM51Nu/OwqqHqkk5i12b
#lIx5zHaspy2xxbIVjuIzyzn35XMkN8A/QHbuZrdktZLGkeRdem+VreVvWY8vnQDbp+9NHlUOvTaB
#TLU9bVdP6uzLr5sSN6VqxmDEhDQeBboQ0eQ+N1Trf+eSdBIxvdN1oyx7Ffu/WHJNm2P3jfQk4Zcn
#UZCQW9QHTgE6k9afRpfGlKiY7QaejVFSh/5ZJvVgMLgCxvOrmkXXF//12R7g/39mCO6A/9ivvVpj
#9TEEwTY6MenwYEK1/bs11r++pEOjRG7bhBdOb687n0+hSWeyFM1gSGUz6RSXobPp+IVSWYbbjNXF
#UO+Vb/h+/qsldvAbBje9t306Yznk5sFUtu/WYXyTSppoOmDztY3ZfYJwTyWCdD20O2OIwL0vuRVO
#JoPN2EaD1uhs8qgYupMpObrThndyZpyY7ZeboCB7PGS7dip+dWNM09vJfq7vNx9VhzX9lM23jHxP
#BcF2EQhBSGS7Ad9GTru4reaLx7OFQjpVLqcT4XC6oHzr9z+/8Ged2FyZ04dFjHICga1gtOVBO75Q
#qv9zb+TKNa9+/xIre9xhJ3zyGRDsJToS0aqBmIF12wYG/E9vbBOZ+s1zl/0LYFxhasirRiBAGDit
#TCcMTWQNQNqJ+OixXVPEAoCwj+aQDRRr5Re1PlrYUWsxFb4DK1WXjRkLAZ4mna3lnBTxJqwKboqe
#TW94n6Mj1+817XhDQtpyuK/AJnv/BOG4dWVIW//qUmtPyJCtzST9lwGxSG4HyGr+ZWlL2CRHC+vD
#FQCnhDHasGAoVNUlnN0rTd/670c27TXBeQNw1Zw/yQZvbNTcP8kGOWNpDD87US9FJKzdNQ+yeFxp
#VSz/01Cxk8v8Qh0ev4R3094jDF9sfvIZ0gIcHrv5xeIVASYU/UJ+wOcDM48YrwyKmQdjdhRe83qw
#CJH5nFge9hnJRDh1YkJVI/n8gefRGxTH/oLXwFCPr1cLKyUJn4X5MQeNzHr0Fl6sNxFMix6DSP5g
#zA6vaxvOVYLC0SWf015stdbu9vqYSa3UCafPiaTKQFQul3dtShxoOvtiXIqLGlOeYSwiIBh1uuqb
#MybU4FBbhSxuOL/xyB4kHw8FdOxBmPXWai4qNM6OZiWBcMGem/U4onoCbIxjpOqkA7Ock6v05ywc
#jq1i9h7sO9Bt032ediadAuYrhL9Wh8idgE/ZDADR2N+skoEHtikVTHSuMoS7YO9BssgfVbvrA06H
#xkC5t/lKMBhxWrBDEv03zrH5O310x9FT+RctMaCvbjFAkEBSrVoLy5iFp5Qzlyh6p9bU9D89Ma0c
#TuxoNSK96jXG5sL5E2e3/c8/AnoVD2RahD53VF5rsNe9Ex0eCuFmsUQSei/ju7bb5QtYHISjPcSF
#MgAPUjFIR3Pvhhqfkxtwet37WljgKI8kIYskkr1MNUXOz/kIQ7s/T7m5Pbqru5/gBGAIzX9N9gpp
#pP4u9/75cJ69ROCoP2xS6mPj+czYw4kObL8IJQZXEeErMH7Z7nRXpnzO5zHR0HjDqovOTA/382gC
#1q188Iiu1Zb86Yea99G5yjhGJiJx12nxZM3hqBIYPT7DX7kUXi87aNH1v2oLO/8Oy+wN++XX400N
#ILFenuc4X6TVxXRwmKaeFiF2qxGMHabICfJDqX282FvIkIk1oYwIRv6gVUgpe+x6saTWWcIB7Z98
#OmY6ZsrFYLltshBC6vGV1gcS7j0wc263VYy+gFX/3XgEjMnwQefM8BnY4RZYZQBrQXfAAEDTlAb1
#9O5VB4Qe03laULNPRhDhiajuURQX8H5hcc2bPBYwSgv7nXYY+ZOTq3ySsU4KeBgKrHYr00xJWZvu
#u6USSXJU0XTwLVjQzbCmlCd0AGe5vFsTCQKzpjCKsq6E3G5XeBlG6X5Jfsoy487PhVUoK5HMqBMM
#N0Pj8wWnB9S3S2I+Mv4J7zEfPcmTJXQ1pcqxmvzzZbqiGT5q11bGUjnuM0FiJggI4KBNB4OYbm4S
#F0HFMFNY8WX7L67wluMhvqdmEcQ+d3RvkJKvsBKGkxVDoSDC4XsUezHhXwjTE/h0yHSZ9iU291bP
#zDRBvKjzKHqaHK9Bu3PH7/WY1vUpW4gaxcWCsQ4/Yc0ZD3AByfUf5kqhnL5hqkyjtGhOBtPOsmn6
#vlg1VBaXLxappb6HszkKbo3emIDJtH5NSQhgjOtjFtrChM12WGQaLc2+bTCFAg6C5z6qWFFEK82b
#1PrdWq3ArNWCPuxcG/a62qaarFXv9FpPbN6dTTdhU7ktHS/bPir0ULCTFINq8VjISzvAxQuo6+C3
#MHObi8WV7txsnbtplQk0YcfYwZcMoxtHylTuNZPRkwu0c3OJdaGcaeM3z5ts3qDfLU5uwBKN0fwE
#HPSmzacu3e5LrOwnnpUtwrmRj1KzhvgcG/WuATOpS/dGx5KFfwck3lw4ujDSUF5e80Ft7174/2h9
#s692qukZvfz+/6GI/VgeodVGO/dvp7gzOoOCepXR6NpYm7Dt+C5xPj0ND44P3JNrYqDP97hsXp22
#i3I9BR3mDlJ5zDdqjcHff30L8PYLcDHSTynFSSR7BankIyuuc4FVJiSgaHnlclj5NxOxQeR//x2A
#INtgYK9hiyHL4HDB//5DKLzvPPaQDI4FUtLcGzVP++fp4mxOe+MNB1TOoiQzUmZ2NWtjPmdwMSnz
#bNQOikZs6RtlS3nVVBetYn5KbSpov1xaJeY3eyaeMHICEE2wsr5Qa7p5clw/mBD0WV9vneNCwZbB
#VIu1FxtWgE8ep/T0IasZjyktILNER/+YNYKbkQLDBVeF64Ja29nmY4LyWSAz/qxgMf1MH2X4eQUQ
#1r0HS8B32PQoqHEQS6+qrhBDxkPQZrdHIBU++E5GqprBwhmFCy+7MwtCbZyvDYWliwU0Hh4PztuN
#qZAXqVudTdJesku/6/q3cmJsdGIqGFlS9cZemxz5otDZnNaEGLkqg7JBdAb8xyXjMJpc4lRNDWgc
#jWkNs+rcXKtLlN1yvz+akc1FXr8hSbFoa4if53Crbi0KR6av7KJTMZxsCUKtVk9z4aprQNXlymTy
#X5QpLpuf8QNpuUHn9oMTL4RE9PBbkOxBjcYAzrltxzFR5YIU0uB2WGscV+GDzmxLz+JOJy5PSi5+
#d3zEAgXM92Nh5LPB89mxQ6uNraCeicN8VIXak6TxWmHCBi48/zjpc0LUKDtLqd0DIvM8yt8Puglx
#mhrhOEJXH2NTOJ8bv+8WIBwPPX5RkSSrYk0omCNbJMSOiAMHX3jIcX+Evtag7Zh6Ygt1jBbSnGNc
#EKHIiQw5Vo97De3xNw0D9k8KRYVdoQY/q3dXQ9FIe0uyCDWur4BVcwqvZ85MIFYUoJblEks1ZJvX
#m9jD0hXgbGHx+EJ7l7PUIq1dhDcM2iLAwaghxoOTV5bJlKlWL1ibT7gNf8iCLbJkoFmAQa0IXnCY
#qw9psELDMlXDbPC201x3QAU9pJ8wN0AzYu6qD80ma1j4lYeTE1zjIhJhUp8ZT/qvKD+b/2Qo7ORy
#O/PJV0iZLJPVxHcLdYluDm8yDZvP6SeUt4xLRGZvPaswOMuJ4XfjMXgcTyR5AmeqPIl7lozROAnv
#AzpIvFRGXxPgcKobe73u5FRmpHcSkmqf4/3osg6GYKUJzwbQvM5tYNod04BQY0xl9LWJESjgaMiN
#8zleRxVaOC0lgsq1FGj499EIm4leG4H7AQcvonqQugRxwaMMW+C4KlU5L1ezZLq8k1//Y0TP5Hnj
#G7Ut+57OF0gkxocQjiayB5KqD86shJ56fKRGJEnMc1GSFS5LdY43JdLnkiPIVz+H2XHPTLoWF2Cp
#vL6mg8Ouq8pR5zTnkSM9yYV5LZhiZdNpsrd5pUeQJXMp6JEgbhpCyRMsMt2yKAMuVp8dBMwS4310
#BImv6EwnLpc6kRrCov04usrwiOcy8/TzozZj44ohdUpaSmo1Tmd9b0vTmnkm7inutFdMolQYOkP6
#7fGIE+7TQXqcHB71exwQ8iqCGRej2WNy63hcinSF1eopOvis901+zywMnEF2e3uSkCT/yxAGBcZ6
#FrMPZ05rUjONLOUyQ9j3yrli3dWoAQ2KEztJ9Yt0EKfTA/gJiydYmFvGpJ1eNc4EnLkV6VTudsXZ
#jogYp5yhaNVnukjcTaJkmS1HqE9vt4YXYjEfbKLvrEZRQN+jlUTaK8xalna95Lbp4aEpZ7l2mp6W
#j+vKLwqykYBJlloqYHK5c9hlunJ9kqxgPVt9I55K0TEmqo+XQ3GeTLJMBSeLohpJrYg8RJK0sZdH
#E7GgpgXLfQHyOWZcRLJK12pe82KLX41drVsOrrSOHpm4elGrNfsLlbW78NnGMTNfV7Ak55fzL6ej
#EPZadcun1SFmDKt9ZU/EpNMmQBRlKTcoArXW2gkKsZZTjEWUMIRiuZXCsV/5WsOtLhcKXcvBsdVi
#cR4FIZH2PjMw2sxMpxSg5MP5P1/Zg6iYJeHOhDaSdzhPdAqvMFJuuLq+SsAorMn2gbo34NKpxWuH
#iquoZc65gmCwQ6RQ9x6ZL9IDSfyX5AeJmK1pnPqh5B6PD7QJJCzJjd0q0RF/SwIrZC7ZMSZWkskQ
#5vUVmEdmZpAxE57krGgfQu0ygCFgmLRl3pEtRJkpHwqrCMWjXytTdd98+SGE57kpdapWugEwMmwo
#GBVGMBXeYbX1FuPqDwQnqeJWWZNGPAZRchx0lZMy+8S1ZWKdbCP2Dt0qf5IFdsPUkOVQNhe7j1dO
#ZjoiqZTh0gnlVHKC8iqF2I3cikieJSM3zAmyXMsOiV3ZikbKZbCFmDf6pAknjhVVNqqu7VSbI8mr
#ZD17ZVY2qi6guYEvq66MbJpkXN4aG2JxwrpzfO7EqAEycoz/EUKYruQTYBIeQEMYUvZwVxFgNhka
#TUM985iG8dpRyMeteiy1eW25kgBdkouhZJW0OvdDJXdTGLNQV6cYnTGRHany36nrJH3uA3lMOeoi
#b/dkkJOA3Zh5e9cTnlDp3iONhwMeMn322nqWO4fZQISzppMv2W1CPr7nghu14bntKsGM3nYPchz8
#RLjdY9taWNNYrQ+KO2CVOr5639XgA+iGDx4QrWCPP6L2Unx8RfqLk0xXxVksLSCmaEtByJ1f+vwy
#+4FybTkrqwz6W73y3flYWnM2s6dsFdisqDzRzs33A+WzAbhNl4FNk7rNK3ZSBlf9JXPJHbrnXcjs
#B8rqe26FMuhvycnsLL0ZZxtVt4qTLHWLOME8V9Av5dZwV8QiutywExYeRm1d1QgkKDhcjNqvARd/
#4hnp6YjAejUEyJPdsk8dJ89iaX27kmofOCpIHESpL4eskfUJ1frPm557HdbmdUUXehM9s5qCW0ny
#QllX5BBYJEVwBCHr29BYgxaeZSP8lF+cwG9xAPI4NC4PxwXJPTaRiFIG3RQZ7IDWj35/QH7fJ54r
#v+ouuuQ/Ok48VfcaeN6PuhAC/eo5v31PrU+ofc2I9Qw00hDqRQavsEp2/ykKO1glmztm91NVbzPJ
#gVSraYusQzSNvnh7z1WeElpXsvAkKQI1I5uvXLMQ/7SF9QIER0hS32E5DZ+0Ce+hF9xTknztST2k
#uTDekU/YwRsNveIRGUEvyCfg0KtURPspG92fidDVEUOigrljGb4COt9kIm8QWRHg+q9dRUHNM/vY
#fXakab9zA35QqyfDcXhYzCVSxB+Qkb7dZ/3u7HwrCaXUE87FZHnBUO80JTjI4RcE1+LaTCYVU1k3
#0kzFphkKs/4ceurc4LAxtsjrNdxbW/nAhlOU1eNdX+n11n6sxfsC4u0aH7h6k5PPxFCqYaO6YzPp
#4CaoC9+zxeeoyQD9vRJpaqkr03tqsZAOr1RQQm4jqGveYDa2LWygeRx6KD+v386TCvNwj0bvp1IQ
#bReAN0TfqKD4QbMyWXe6m7hqH2kQ/JkmIgQTtmvLHOh+KV3Q8oNC8Hact3pw7Chtc6wc/z/t8IaW
#PSG/O55zE0EvyDuInQKzQaiMkHU6WzBZwecIvzcAYeCi0ugpvx0lA4AB/k4rE6dosab5t1oKgezI
#5pmWX8qxlasEPFTu+e3ooZlcmLsJvyhJHe7fFCsn8W1X/uBNCaV+zev5OzhAlWJD4OikUaCIMXBb
#8WBtsg5Hf2SzlYtvR7q3zM4D9wXgp6Rjctdv/HMFQajX/wmyQOTJY9PdM15vCpqqlXmfoXrZc53B
#5Dx8ZTy2M7CjU3VgoYpIkR1r7xs5UV3F0ABVx9XNjras8loAHtITcg4qoZpoqVQdSe+XjriY/CQA
#qtIeu4D/txbAq8Xp+qky4eewErLmIzpk8zI9phsLuKCkxiMOE4QW4zmH58gx1BvPImU7/60c3k8d
#iMvQ4GG/6ElaRY/StGoFi4fJ0S4pHc6iftSXqxhPPGd9H9RVilVNleGAIW2nsI4wE41yYh4fDnpf
#5KXGlovNf+e5/NxSPx/pOWDlj1o8RxCinApdqzkUtBYrKoBWYHMYqRCwrEn3N6CtLs+q0r2Q7M+D
#FT4JY7EO3lIW4BzXS4VdMQtE3uPELe3jnmXahjkOVWNOhVmZrjxsy5+fQbuKc7kseh3EKW2V4KLM
#k1TMTHFiAcw9XRjjn+UE86Jsb9dEzMLaY6tVX6y41G1LpaPPOdxeNskB0eRFOVlUKWZBQy4AAGtJ
#Ytt/pyxRnBZRpzvK+dQBXifLegSfhe3xjTYrVItjGf3RCcLKK6pEmKFkwLCJ5KpQUlk2dtxYQupZ
#vDEMLFqG5FSP8HMrO+0OIjQrIAWGw7KLhlbJegADgZYFqVtGwb20u8g0EK7rvrx4V3DVvTeDv8BK
#SFnzCWWw02nHwjFDCULzrGeSkJ3e5qDp6BqBsHXOO+TKwdKM9j5ARAhrQqstw9fgcMk1Poe7OjUJ
#E8b6oCR5MO29AUEJa1lBd4fVvexsraWl3lyQVhjP963Z6d0Pio7TZQaIhPnrp842IrWwiYiTE1Vg
#X9uQ+VY2SzSMSWZbTVphJIMD0Ow5eB9XTWL8PAmop5T++obLbofzUK3CZJpYgWz5iqFH4OQB8HVT
#uGLrsIqcj+CVPYFKfCROsBh6nARznhyd8qdNwyfyLbzt0zIKFGYrSKZ/8jwATnuT2Lj6YNN+Z58F
#LLfM5lOvhIIk4lFsRweIfvJI7aw8nmJexQlOnXcyAF9aApzCkJGSlu5g662K07rqJH+AfZbT4MvE
#5zDiHBU1bV2Qw954gBm3WD1H6nsnI85ZtXMWw0IKcj6MV6QQlCr5MCeUZrdNwIUsj4X/yOX+hGR0
#Uui3s2qHXHcs6dYIvH0nzzlzRRJyTAbhynVBr3y6fR9Ymvp/HIPFa2k9+bt2XBoH+BR0VJvPa+26
#JupoQu9oNHnPdkqtoQ3NksQVsYZw3G4JRVeLEJpm3GoCCwnNP+iqOoLiUqgBbNNYo4OFX7ay2hjv
#B22NulLP8FGcNUxzrXHlMCD2yJY0eEBcBoAaScXt/PxnAyO2pqCxqnzWKMTXsIEyjmlxlZwF7Fy2
#9+goNN4cHmkB+y6FKxaLX+w7Z51Jvg98XzHt4LE7KcTdNuHXzChaav0IHJlonlU2plMp2YFJp5Cu
#VB6JxJloXsah3eBGaPJQnuCIHKfnXKb76H2UfruTNLP7RoeR8SOGVEtnMnr2eMgxo6IrFksgj1ZV
#yXYY88L8dn7qTcQpQrLsBDqZbWKLypLr4VIeTVrsdrWKtPWkNHiEv7gAEUdsV/gFHGloje9skKjM
#WYK+022awPWY+yf7TNNB07yzAVdDqwm5Zp24kB5VrpEXWRoWraeFfW38Yus7jrS6UKACEQK3lsL5
#vtDB0dlvPVJKm09QnYWzkcO3IN16881UyUYdRlmXB+fIi47EYKhFgCVP3SUnypoN+0KpbDpqUSRx
#FNZoOpcKutzURQn+PVuy6aAloqvriTOHrUFSggbYCCJU84Ut1f0DDLqQ1yhHwhI/im+4CCshctO/
#wNLq7FGWpix1XkqngnaAp3OjrLGhQb7E2RNai1YeiGaqrVYKigbX3AciO/75+UovnzXJ2VqKplck
#vXUP9/oIYyrXm8im+2mzCbcunc7lc9UK68BokpSX8ewz09N2n4+nXLPhdKXoSAEIFjNTlQDvtAq1
#2xAQ9oAFtDNvZ08rFFeJiBAY4k2BTBGLFhUBGfizXmLLqmDldQGfApk6vNV2+JPp9FmlYVWlU2CS
#QfokotWkAdYdnztWrABA/RZAEJzD2QljhJ3Ih56S5JwsYdfiXVudbwpXSrWLu8c6XF3RPvgCtMc7
#eKi7I592KZxg/ORJnWUe4Aek1LRe2dRdny/GDIjMwAQ5B7iU3ZTx/spz0mue9hJsZdyn9nshyjho
#lzvbYTsXaj/0kNIWyxSSbpPBMT1kndPsKKIyUdu+0qHXO2K5TMyqlFI4lPzYWyQrikewsBb7FNjF
#aV+1bltwKGS6eU0luQQMpstUQXi4W41SxuM66dGpXVy8k68Xltak7Zlpe/pc1p8uLHWyXrcvWuws
#rq4fqibC7CZZha8G67CFVoGlXd5sZ2lhC4JP0kmkivDh3gzQHtozBtfAod6hD2kGEpNWqLkX0G/7
#0A+Ppx3YCP18B3Vw0J0bCpBhTg1wpvAHOBeitjD0ix4ckxxNJUpU6yMJB6he8PGcqt4Wgdg2NwXB
#9HdOPah4iTBkKOu1xmYLDBEQoVGqC2vQ9W6uaEAsd+f2uGTADLwpsPljx2K6Z8HYg06QtKD2PtyG
#r+49VSCocD2QlrMXUMbX5npsBj2fQDtg0DySeeOOUQJGmO72TSITS4J2ntrgzagZj8Pli3mAQfHV
#sdQq+9soTFDYA4CG8cgLJoJBtu0NcARjIW6fYPFhWVh7g8fnWq4FUcjomWNJ09ImFbwoIpC5N1z4
#5gTIwYisjLIHZkelOShWTyM2j1NqvqJSR+vkcHrdKgpTFOctvu2pqPGYetA1nZZfxJ3jNjkKYQoD
#EDoxxdUtRi65zdtuSfJ6z+EEWlpaBchCoqFKjxlf/DqsCFZgnNiU+S1tGBWkHO3AqupmwMDrNhjF
#Vre5UAJXsuXhY/WJs1/QDbz2dnZpmSV2v0Mnj9QV2hr0QDU2ZQkfyziHoeAbEglFcuo3V9DhaqYa
#CKxmwIKeo0ow871qcjANUT+8rMBlPVMUG6SljVOUHk9kA6ud0sQ+PSGzPecnAokEOcpw6heCdqNo
#JTc60npGPEpVW4ghVcwT29guUHhucact+fIqIzUOFH8nouE4vCL4umsNo5CZZZ6gStPvPWWCLKE2
#oUKUezmQac+NdAlC05LPBRgRYiwxbRuHJixP9AotufLaE9lRdJ+cRfQHGXEMrBC5m55woWr6hFoU
#CzNQUmzBrX6MXtZiN5RyP/TEqHFce20dplADtXA21ChyyrUasEQCsRoHmZqDR91GdgJQeJ6NmBbT
#VQYUbtkypESdc/v8AZn1jrDcVo5sClm5rdDAPY5d8jHGFNpQOnNnorY052c19jSmAHXLcood66Gy
#fhIVOJccTre06v0uYyiW5q0QRAGq5tNJEWUSNGxVNAw4EIJYsOd+GCb8sVBgfVpUL3Oi3bPRyrKT
#VlbXNyp9GmzwDVSdsAXKPTXGvvjAbUC46DEqFz1RAs4NyWAPdBQHo8CfUiswn01m9HVnoRVRzOiM
#5RJhbxN2I/ajhN9YhZLP23CjsEg6M2XSLq1xj1XBjchtzsSkMVw3yeewfBLGetkyY1GsHE/lZESg
#OgAFIm+E+iPpWnWT3M4Zo/ByiT592g3PVKbQ4sev6MifCvt07iDQ400OSbkFVEgLwtJ1jwJblbjl
#8tttgDap/h/HYPHqEJkwy+Sjup/g1CTGMQvptY7ARjCGDI7x0Myw3uO6j0ZhHBE9OVqibva5CfoZ
#zpArTrgdtofoUxjfY3oKaeBbOUKnsN4E26szlA28sY1Qt8TQhihTBsLUcpwbUNBSYoLkY2xuzuuw
#AXuS4HOEaIhZGBL/b8Ny0aGzSkEabGelivTEe6EewX+033QeGUDXXJNs1sL6IPIsNg+ZvFLzSaFj
#B62HmoiRsMGWfvznRzIXOIBnaehBkMPnYJA42J7QXMt9D+dz1YrLlHqsb5+Kke12cdK+Wnb5PHge
#3SrAdkx5Ixy5rOnAVdcXpzsqolNHhLn9qSZ39e5sxhgBD6z2KubZi+H6jG4vaUyEwaIDXH4cDnCw
#mRtPqzsyjoqt+bdqrgj4MozbY0Xwcb7yWT2PxrMjJol/S+fPqG8wwWYwDmuwU61Z4jfJaiSJHJ+K
#xPbhBe9qsRUnSI0ab93Daoinh3ByU29seIIxMm/XsznG0tSnwM/zXDiBt9ZkKTGHieccs4nrAxd1
#2e7TeJ8DxzRCL8Oi7hmBNFR5FgiB+3ZyPoCpPRkK61sL7xWPRJIpd4tJd77SoaW0w3UovKaCUgMj
#yWEr2BpN8Vk1pY9EMgI4PwH3x6IxnsJNJ8eWmF2OwIzlfI7byBKr5Mz7wEAtBd14SoqUqaDF98X6
#+NOuQEyQChyOtuc1prHZAVaoyRXqB5CFSh1ZhUag1T8b0lRUrTZkfQZgfH2KcFAdVG0c4h942kUn
#QFcbiBb4D9rm9ssC3xcAujAMADR1r0A0hAlpQjgGADq1UyqpCQfAMNi8FVcVY8uOoO7Bo2emI8mi
#zWm7PZOOaX6/VYfyIMc5i+eZSTaHQIxhGDc7LfymyBNVGwelGueeZ8amUSrHR405LP8GjF0CrHxP
#IwbaTm242EejM6kG+1LYbPHF49k+jhnnwV13gE5kBkj4y5ul3B4KlDwnBypUiqkky7tprSs/hcIg
#MfbJ6nq+arYoYgySjDPshs4gsfByyMnArX59lQm6PBA6511xawIM+k1ZVbPNTrRVvHBpiB4uvagK
#b8ZzAI2IOsc+l+nA2fUuh0qBQwQjlMjuoRIAuBYLboOOmVtBd3NhrplvbJ/NU+ci5fZgG8dVkbPa
#ARIlL9ePg39Au+U6fAs3t7P2uG9vdPXxPB0Yw4oZ8+HZOU2EK1YMCoKklAk330Iv7cq6jnBdOmrV
#HNa5Gn54smckOzqWNR0hsGg0pGEz9Ba314qEC+mogbP/AtTsVR8iM30SHQ2J5rh+OdsKoBLTAMyZ
#Qt6n+R+87tv29YeZtyJgEpAzgoJTmG/nH5VAxAmRgxL64D4wBpAccD7NEMbHTe/HU2en50b/pL+9
#X9vKPpO+9Y3ZL4lrRwCXDIIA5QMRagAhDngAKB05nB80Tx7U/2QXdMf7NwjNzNj70vgL7uef94A+
#iAhEWPMTmdAG7Qj8h0GXVNFnnQFcIQfVX7ku0IttZXiK5EEbOFuw1537Of37rrXuugvIB7a7tUXa
#hnkEgl6Zu3D/EALTzmQa2MBOHsVurz/QPAq5VSBwkxOTQYa3gJ8zlPVNvYFwD/fzQTBaQng9AZ9r
#RKs6rzR/fK19MvcI8HlBIVVefS76UyC0y4/zqdLIWzdq0KJ5Vx4k/i/JRM29IeP/VRVOyW+knd2U
#MUL22TLd98nN65fWvvzaYTFXngECDMEHLwXQMnDrBxNDfKUvPIWAurj6q50333njbaBYom/DS1/d
#JIF03wUMH8j61p/hrFyp6bxd9IpyKBj8Oj535DTglMEOaL1hqexe66nHFUmWTwKSJ5q9MSg78bve
#2ibmvhVSiVrXarOlUFxcFA6DMJBm3s0BBwCfjKBIDBXuYf+OTM79TB4DV7bX1BBmmQDrZkDBVpc1
#vdg5ZoVuVStBabFlJVH0Gx+J//9F0zjPVkp5sB/9neuyFhiC2bnG8rkBRXz8E2u0GAWs4H6hTavM
#VQm/FiSpID86bn28DuJSGn2tdUvmmhlI/6Eg8gtswLjLOlhraDMCQziY2g1ChRQQWrz1LdFunZsV
#X3rbPvT1mcYS15OWRwlAZGbfBteLvaEv8eMGPuSkW5jm7v8zkbe7wqDIRKhtFwnGS5ARMO2uXhn8
#fhJgYP5Qm/mEZamz7Fs/9JsOjJf9XEcTFxYu2IJXv+tDfO9n/XJsBfum7tv5sn337K1m9/wOLNDj
#/saatQicymyCqf5J2VylfDf9PJi6fg84ddnqrVAb9ANNjKPcj8KWOi0OW8VyeSzxuTuo85OuZpyN
#uVgKdCVhH8R9ajMz2tWBndp4AiLiOOyfqs7ajRWzGoEPvqqu9zV7V2mmfR5zhcYa4/GlWr+kKSqb
#cntW2s3pPOMGD5ADcZ1GEAXj4Nj4TEnxlCun9ly8pgAHP9jz/lCP8Fy49jY5DfRBxFGy1EC+Tksc
#lugmD9lvafAjO/DSYBu+/bpj9Rx8DHZPlA2FNMr5jTZCaSKEyQ0N8GLfJDoRmzKo4RtoQ0GTDcXi
#7tWZS/FYKKs+IkbcylpdcWOwug6+1XD8VN+82RTpQaMQvU9rKSG9+XKwVRhjrT87P4ETT/vnN3QI
#L+w41kRKc4Q7auhiuQJEVCkV47FPZyYn5x8qJT6ZvjmRlyAVEJOC0rCwbnLC0WzR9S277adnh9Le
#ew89uLrNi0RZ6PMwybYvW9zb1NUukSffu3QSp+81sqoQdTL4VodSR/lPbfrw2VLvbjq1+eYDnWpw
#EId9YKZYaYlqq1w89Uimb9p1OvaiFm2Dd4EtnaAgArIqilQbqW0eQj01M5K/xp+h3ZGMg0EVFTFS
#5INMgenKC4K5mAaudWnneJXXpQ1Gn6oOl4KqRaa6Zu4BLXqkdtWBeNdy0KvxdwoiEYAB7cr59GP7
#dhwlzgxjBpAND/zzWRXc4bP32Ex9pPWw08lkguk77AQGYAj9/+tyYP1xQduCD9LNvHKOZNID4fLe
#uKJPHJbtQ84V3KtLAk9K9gXVBkW258IccIAoatqZfEJIrZgDEUxZpHNtEaf1STit2B/JGmy5hyXJ
#WW/e/ZdeT57eqJPo5jVsDeZ2ltJ5iIUQMw2Lh4VcnTsbAa9JV5KWCMthtpz28mbPrVgzBcpcwdYc
#rQ/MrXILqOlja9HUb6VpqfQleRdEs3mn1mZZp3izNqMtzBz+h28ksvDOd+C8aiPhQJvQTCw1GihF
#5Lq0kO76Eoqbya/BbQomDhU9doDUwqlbA+agvQaW9NthHSp9EzO/8FR/367hKLmC8cqLyeMDKVcJ
#tFXuTISkU4eTsX3ZXYbDOjL/2dxwgERqjGSlMbCXF0a1+P5qQ4E0AZMdD0Hg+pJ2U4Yi5ox0qSYG
#8peitqOY+eTmHUoHc2nrJDNaruqg32evo0sMzyWEvfpz1wiQcBUXvhHNWKJ6+v67ghZZQk6yh7ke
#4CgKBLZNE7XVgYziet4wLCkW9997j0z+UWOuFgXZSEXA2PaKw3S3b0SwV11vIdcJbG9KMost14k9
#K4dRm1Bca4NGt5CxDZbGU3VpHsmmuD4x7cPUYEfiqZYUZMqgn1F1wBzuQAudE7ZifW1kqxGQWEfs
#WKHgkoW8W6ARDZEHhJFGcouRzCcsPmRpJkAmmVoWktUuf+ZrjVKBba7apwovEulS4bC9jIwqyhCQ
#qmHbq0ttj9IlLBK17Wt3s5p6f98FVetQoonCVB0MIeonRb4IhfWydv3pJGnKE1ugaTVu8VeMuEMG
#y2Ldb9Xc9Z1qN/UUee91spzvUHdgD+WL26eM/TzEnDBS0WeEmrs262DKc/EVbO3DlpWle1nKyOjO
#810YtRjuIWUFehQhsC3RBySn+Y3lpFItBMlmuXj1UzbSPwXfoalIz4itSdcwEtLNo7gKe3uvnD0P
#9vQZxChmCFUoIe0cWquXqukbKYZhsq6O8zf2ok4IS/GkCiza2OOBuA7YxZd1MQ6wsjLGFwKKchB5
#SkRlQiWBVphSIhspeysOG79XNyNTQCzKQtK9jJAmihEQp/uxCae+2kwkFYH7dD/TThq4dcZ1jlSr
#4CCSGRupWTjDuccBBFT6K92x8RfWlJilw7geQc0VodKQmnw8AZyANLP9K3tg+wNl5F3WfOapXdsa
#l2htNl21hK6nDBBGLcGkduporCTmE6J8eWNYZZU7yPefc0OT5MoldUBs2b2ycSxHyfVIaTvnoHk+
#nR/f+GUO1v/D9zs6bjKGGEnyqahLOpmhL5luDFWNK+HEeJkK1AgDi5+uDIe3HoBRvizO1JCBGjWY
#xcFwCmOJednvHlsh1lB8S5gLWT0a9IbPs4GpQjnWq7iOCSMg8h3Qav1WP86lxwyzKt10C2zttqk1
#jUBaq21RlPgCc5Cnjn+fKrHfD12TKpaTvRj1OOBhZhUzSEzxcQiQYhwboEcma793xwakC20LyIb2
#wKNX1R5ILQY4vTv4eI9C+2ff6OK2OcQTNhrX92ioTmXHaIJyQigjDNQIWvdNeCJiga3RVmV1gq/s
#C9QPWNE11YNtm0khxZDEGu5kDiM3KZA8l94V/vxShGmCFNNTbQ/2sfzB8Zg/9sbjd+ZAIvtus1zW
#7a6wND6Awzok6N1hVveE0FKelUnPrTSPJ1tiKx3Y6zCs5fNIHC5uD6DQse1BOnuSEm79OhPgFLso
#pzrb5vbt7HaMnUvH7WynPCTS7L/9UHeu4ax4J9e1VaXy1pUGHJo7UL9tRRpZu2nn5g8I5ZLyDtpw
#EZJoxodYxGqmE1kPYm3U2XmMaQjSDjZbkwrMQkS0DAfL6r48ZWazZrkG58t3JPlfuIL2cRodariv
#Wg2pn+SLKvlgpbpApMMBd/sNLVOq1wIY1ayPaCuplmjGa1k1a7UPUkP5G7Lqo1DrguNL6RFThg40
#WHFTlXxldVSIkJxwgigVCEfgtmTqgtaWbwe3L4l3Eq6xVAp4UNZlutq2C0TZ1rg4wa4dpNX10Y/P
#gd3sKyncKbWFjqLLCu+eobBFxRBkf5OxzNon++2aIQrZYzgeuPsSE14b7QItFR6FN1oC/eD7OdnX
#BC5ewcptqjpQIe3VjnTSWCT4yLPUHuZYm+Vp8xYfJeDBHK765H27+a2BXxNf6+GxQa7bapdCxBFI
#ZepFVHkizaqXFWsAj0k7Sfiaupi85g7D82VAyylBFEYXPqJOzAQ5ilANHCyPkhOywwQMjmAKfP1G
#jjv+GF9vEeQKctakZH3KVqCyHCfuwXAyyBCRWl5FsK6UP/DxeGByiUS6ehwwZw7wPs6bz2tSRS58
#wA5VK/o1BfFIjLx3N53M6Ln24QJHscGVQOwhspDFEj/s2gx8W8Vz+4ptPU93vlFz06f6ZkRRHvBS
#WGLOGC581Il2Hh24vSEQThd9C3mwws1IvpMdetG1w0/fa2BGhRcVUoy0n9TLvaDQv7i3Z+ExezrV
#xH1UsbxO0CLRmQ8hZlh8aqAoMxUvUn8aURJqAtv/Yz3JG+YedwVIv9ed1NbE+1azPQfZtdBMK0ri
#VnAWxsazlhTfPoo9Ido0PLmjMErNGiFdSSMRMRgv1gzmu1bWqH1MsyLesrsfYKMYO3Ykn1y//upK
#t8fcNkIkG9uXcTV8RseKdu11tIAG+zfRftpdZaguZrKiWYYkK/rkE9SNNcaUgbGlMWr9to7fsUSO
#IEiggnOP/HDAs2B1IwrV2Ettb9mJWDa7jvb6BbTNvEjuKX4Nq8Mi+sjDsCLS8yQAc04k3HSYdFTF
#eMVoVa0depGs7GCBKRV1QBs1sgtjjTGsYnydGNfLKBoC9wFLurCuNXuFXhs8TLLGSpla9XqnMsz2
#O5Y4BBDDs7o3CWgTAg0dMmFQhTYTAYmumxgwKg4TBb1SltmMNZG5sPeK8kx8fFuJJhVklA5XVAVx
#h10NAtip60wIlOlVEwYufWgiIOwJEwN8+rMTNQFuBWLfsUMmDggWxsQFLqtr4oHGkrnf8IHPXtnJ
#aZzkaeD5mFtZWl7n9AVAc8Msts1paDY5arIcxsbjnWIPjD0mPtaPMxmZ8sxJaHISxu4s9lovaAon
#zdaC3QqHi6mJmoMJCLLT5DQLTueFeo6gqO8caSB4QF7tmQtLptVdLtTuGuT1otW0zCmAqjaIG6o5
#Br1BU0lhDYOnipbHLNxVoDib0XnLiV0R6WcuHKB7A8w5Ye4bndV6HggDPcLasMncrbNgjT9ug6Qg
#vbAKxvqZMhFqdPCYiYETgxeJXAtuLTsIp5eYII/1YQzCO0JTAD7iwYF6mjMdpw4BCJhRbLApIgCx
#olyww3CeyHHfs9bWggmRx319nC/HQqk+4wPj5npw7CQfzcS2a3I9Hi7iEqjQAvoE6K2GiQYejHBf
#JCKUTt2yBsG6DpIClgOdwQekN3+25GnWxBqyIJDQ9oC5xwm7vhM8rQUM9JJXvvkVK5cQUwQvU+Kg
#CMS1NhaJxn19WqUGy1ZbF5S/YLK0m7g5FhVrNkLMdhw2ob2zpy2uiaSPu4YnJcuJZQ4lz+QgQIhp
#jUMtDgsDGjDTPVa+PT28E52LbK3DCZa7gJzEQiYsb/fCkC74gdELkwleqk6g6TrUBG/gOt3O6DwL
#mP0cX/c+CSFmEqRDDV7QfScx5Bsf9lYFTNjExFo75mZg208S1c96gDPqeL5/CBPBiMC6EIgiFi41
#hLiIh/hICS60FqlAWsZIDerD6hbVIyYuoVdSiuvaJKNPVo4/h1dAkUhAkn6W7GVF+7MnZ1U1VAUN
#GTZilPtSQ1PcBHvzMGXaDED1Zni2+yzxPEL1sbVY44UOG2Qw7rUS1jN/hJFG8aEPGm0M5hrEQkMi
#6PNK400w0SSTsdRG0WLEisNK2yRI5GpfNNU0rvUVrvdV/nknN/q6FKnSzJQuA2vdYpbZ2OiAbDly
#sdWnzJVnnvnyFVhAgu3m1VCJXSO52KpijTNesgkmnhxmHMUUHuxnAf6sejO4pNsJlsl6z5tlNhu9
#xJ/XwlbHzLfAQossxlgJ45VaZjmBKrisQ7yke3lZ9/nCl77ytW/8n1f0F2lW86gpvrbEPkv1vudV
#/cdGm2z2gx/5oFVe06O2wevWpFmLmFaOZePbndXBcRPrpf0GVKyVeG2TLNYRlshYP3lnzEpKCVmq
#kyzTKTLlZOX4oHkF8yzXBSVlxlNULbDG1D5xt5LWuMfO1lVVTXU11OSufsLqn3QZ/KdDQutf0cC0
#6YOvVCoYc4tA3uyQJIUXdY9NesCPDHE+AHfeMngm5pYwTjOYQtFQcNqPLVHeEEKw1IgkhrnwZGvg
#gQ1mbA1WgllmzxBmGm47VsVqWJCbP0yA+4UnGBaOYIKPENbm135yG6KiY3hsuyHNxsUnJCZxSJv9
#ySkFUnnIcy7atoJca3ph/t/AdiJyBxe3vIKf3q5ixTnK6UTJUvSZM08+I8//8yrLD+h2sjz982Fg
#vpUYnF+VqrVUg+f2kQqiZsaFcNxDl+tS2KOU+4grBi2s8GBFFImeVwUvuphiWTtr8rFEmzsEheZp
#ct8vhyy+BITU11+t0PykRonnGZhnz3z/WYWDMhWYqPOk3fsMqmyk8SuM+BWMc94SE58DR1VwxA7P
#nt2KyBp39sVSiVsabxndXnpkVuiB9r4oUaOVGZ1hSthDRgOdZ7J8PlT69XHL4Qu/P33FEr7888Zv
#KpzcryugWIu/lKjCxPRyvQX7VmAvKv3/KyqqaPqvQUMCS4oU3Wk95Y0+IWqZPSur7HLK/YdQse0s
#rGgfuzWlpl7j+a221FpbpsxZwrJmy54jp8zzaJGiU8fWJZpLlCkbuXdsP1Nu8diPnE9MSk5JreCS
#y6646prrbrjpljXrNmzasr1+7O70l+Z5pw8Oj443kLWFcDa3vfL5GE54SYpmfLTPJoQfClO7XCgc
#icbiiWQqnVFyni4US7P+7ldtqdWPT7icb3JxeXV9c8sLoiQrqjaebOlWu9Pt+T/XWeF6KD8YT2AY
#xck0RZhQluVFaQJNbfqOFExJfLxoUCyRyuRDw2e30bHxCYUSFvkqk1PTGq1ObzCazBar7UY2dc7w
#wi9fMNKKZ3P5wq1sCrVFRH8sfi+bz5YmMlmSgjSTYzleyIuSrKiFtuuPaOO/9BoY0/b5b03kGc8B
#Q0RMQkpGjlBgKVEcnoqaQENLR8/AyIQpM+bzzX4dazZs2bHnwJETZy5cuXH/J5lIptKZbC5fKJbK
#lWpLrX58cnp2fnF5dX1zywuiJCuqphuNZqvd6fb6g+HItGwHuN4EtOU1gWEUJ9MUYUJZlhflrKrn
#d6SAEooGxRKpTD40PDI6Ns7tPFepUk/e7GKzVqffjBarOnu4THu8PoRnBUMMz4rGIJ4vkkylM9lc
#vlA0kTwLs6I8y+FkeZbHC/OsQJDmebdINBbHEz7PShNCzyIpo2cxOaVn8YLTsyQZmVmF9u4Xyw86
#XA9Qm2vqdV91oVgqV2pq5da3XN4ii7LtzpTq1irI2z3CDXKBu++24tyEjqGBJtSFlcKxFnMtCHa2
#cpWvQhVHY+Gf3EzbPuO/C3MxneuxEIbu1oL+TgrW3K3kI8E3IKuEe1CeblPJ/L6TxdwO/pgAcNdY
#Quj9jZwxWLwz7iIdk1Mlr2CW6ms1y/BvQKPUCltzTcbD2Aqz6ouSpy/v6ax9qURj3AhB0lkpu8nC
#RBfRBjS8tRWI0QhKpV/jMXn1QQW7u115f65KVdWpa2VjQ4ouTge/Zi7hxrzL2jspKZWXhx29YrD8
#vGRsADhpeX8SUiKkso2+ThA8/UtQX7dJgQQVMvhGjBjIUsjrVm7onGmrtV0gViMopY8NhZKSgXK4
#Juq5yr5fstdQMhihbHPwcDckDhA4FE/Swf6epkbrdpVbtO3+NXlO26VxpaFTey1vh+scWnPF29SC
#Adq7QtrCIu4kc9qxL9GTbKxyw+4S1aV6GiIGQNLdRWDQxiPVmQqaVtQ3NUt/qNI10oalFporjhuv
#PEHL1j4NMZ3v6Cx8qcG0XGaMU8PjSX8IksjG/5lOqlMK8Q9rwv3t8OUXvG6NmH3KI3YjHyN/hfBO
#buIJut30BiWsQw2CJ0eUFwOpKOUiovrYNqIXpvCLexuqJrdUb/jGL4JPHPjbVS2IqFKzbtTIKOpK
#4yhsiyc+KibSCpPO17cl4xqTqGSUxiVNGhnTRSr5uVy7/uB27bG03094a4eAFqr7HJUKOShCjaY3
#6I3cR/naO3RLvC962RtTUlX6S9Bl6WAINZWMalRr0JBsiGZjfJXIaAU9LwwPLMUHhkm7e6/lkuiz
#RD9X9HTdIKVNdU5m1Gel3ukStzQ8MYC2UVb4KrwxyMRQIReLW40BJ0ZT1wLiEz4xAjWMIWuYjeuW
#calIjYyhUw3VkxQ1ck0K5jcCTj4jRBbadDmbpQaIj4+kUUPTk36nzXazX2Nf46L+Xnmy7Fsk7a5q
#Z0Lbt7bbfLytSSVV2i47npSPdlqdvaUjOxdvQyeA2edOJGq6X/gyM4Fvw+fuOH4uwc/z701Nu0/j
#kbEd/CybSasMTLExS3MoDkWLI700r+LU5H+b+Z9GZz6cuFVt9DOzWTUo7/t2sPHjHqOxWPLXeR1l
#d9gNdRjHNxslN2xy3BLH+hsrcA4ocRHipBQ8uuaYYgFAa9gnts9L0FZOuuUs/7vI6+J1Et0mJC8F
#NZnXTOBSxUCbbKxB1EftBgKmhHWQ2dO/M5dw8jat3WGkGsx4z8EqSYsZO/JYB+GgY6iCzCfiA5Ba
#MFwCLGM0VKA8S0MVljyLhJgDABjAIxCodwXXbiZeV3u3Tpgj7zt/I76FRflxHiB+nC/cz+eBVowR
#Lzs+t+42XLMNkQUI2vxkFYxZ0Fk2oIP6WTlO2+N86cQO4ERk+j/SY9kBFMXxGKaz/ZFNG2z9Jr4E
#KCeAg9nVcLdNAp38eBEUFHriZqsjCxWeqwa2XhYgSrOgx35DoQy7K9kDJc9DYJFV53x/UVKm0bSI
#tukQYQ4AYACPgDUDlz0LEHdEoPHJMxNXLG6bmsfp8QtGNisj0MM9IX3eUfF18xtIQA0NO2cyUys1
#W/GQbvZpHTJpfpQt0JRss2WPNIeubwR5+FNYgOubocm64LGCYwQAzIHTUg10m6PgecMvOMQAasgw
#rJiNFcLdfS2UdIqfJfjoTrCTlmqG3HUBAMBcgFTcxtzy86ETOs+3OWY5LYxQGoZhxVRAhi0hWTJG
#XOcQZ7AdtA1vk06ujII6gOXXb9ReR0kl30NdVaArD5KraL7FE4ITb3lMeFqb1i4aHRHHqoy5jnku
#iFf5DQFAQoU0cRMBEiqkir6wX3rmTD4sf8Ww04pkj3YTEFEdm4QIE8q4kEob1+ssBiDChDIupMp7
#2geloX3/H//v/3/58etc9x+4fEAH/FHO+WvIf/Gv3FLd5AEdcK/zElAQYUIZF1Jl//5Of9Fsjbve
#b3EfHrsUSPx9y27413P1xq5oskz5fR/3WiibjlDR3xicdlrqa2BBVAgXJkVoUVaMFxclZMlZQhs3
#3xnGforG0E7T6lFt2bLXuxwUJDLntLSG1uhsxHsOPKolGbLR6TSWHrVFLVp0GiLztKSvvq9Eks+2
#ZelhW8OKzWCWfFVD6+Vr3PNccFSLOmSjswELFiw4RcleslKlaunSpUubMmXKuLFvW280htbo3PO2
#66a20FJmq0r0/Ie7s/iYnaPBoKfnvrrxvRvyGlAw6YyiT60xuCvr2+Gbus82x7iYSdbZEmjTK1xm
#zrmiTMyLf7XtGrYtH9ABp5x+cRxyZ5cHdMCdOeewmFff5z2iHm77kN21FjpoJjAY9JXOkDvrksIk
#9WwlmYMb7/Lym4Vzf6Zfi2sKokK4MPlDvmw14MU/WovibPHpdhWzZR/3praMv92LixLyKr9wo8YY
#qlNrdMYhc3LS1Ba18Bv+hA8EauJOCkOLAYgw415sCmHGY1KFqug0wiZuehjXi82IyEwKzgLYUasD
#qbSJmxNSZZ/+4axpPeHr8WIfb5PauF5sPoAIE8q4kEob14vNBUgo4+IpfyOQDkSYUMZF5u/zk4W+
#OktEX1Bfk9LG9WIvLpfqbJTK5D3jg/g/hKAkctq5i/A3waNX9mfdYz5tKwjIeMbndtXZA5UqX+T7
#yo/Yd61Zs+QygwuptIk7PYxzviKQShvXi80EiDCh3oc9s654N226EFJp43q5f/W/Sp/bptVA4l//
#FhY7J866LAhlXEiljRebj7CIzB0336cb0BaodM2D592P3HetW/d6ny8/YnPp1XzzHCDChHEhlTau
#F5sBEGFCGRdSaeN6sZmQ+OlduwUu9H3RR+zhlSZDKEs/bYd+s+KIbc1MVPbZIswRZXozpXysJiHC
#hDIupNLG9WKzASJMKONCKm1cLzYHIMKEMi6k0sb1YvMCRJhQxoVU2rhebD6AKPk0A+qSFJkqGBdS
#6W6i5XmeZ+3jNpI//dDbApUqX+T7ko/Yd61SpcpUGBdSaQOZrJVyGLnyY9+sj1D/75sC6/+DS8UG
#/uhIAu0YPzROk8DKjlLQupob9O3SLBsUZjclwfP84O9vhzzHC8QN5vJjHAAM4BG4egwp/rg9SwAA
#AAA=
#__END_FONT__

#__DOCTOR_DNS_COMPLETE__
