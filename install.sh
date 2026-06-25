#!/bin/sh
# Hopbox single-server installer (Linux + Docker).
#
#   curl -fsSL https://raw.githubusercontent.com/hopboxdev/hopbox/main/deploy/install.sh | sudo sh
#
# Installs the control plane (hopboxd) and the service gateway (hopbox-gw) as
# systemd services, configures the docker-bridge reverse-dial firewall rule, and
# (optionally) wires Caddy for wildcard HTTPS. Idempotent: re-run to upgrade or
# reconfigure. Settings come from /etc/hopbox/hopbox.env (created on first run).
#
# Environment overrides (first run):
#   HOPBOX_VERSION   release tag to install (default: latest)
#   HOPBOX_ZONE      wildcard gateway zone, e.g. gw.example.com (default: gw.example.com)
#   HOPBOX_CADDY     1 to write+reload a Caddy gateway block (requires caddy)
set -eu

REPO="hopboxdev/hopbox"
PREFIX="/usr/local/bin"
LIBDIR="/var/lib/hopbox"
ETCDIR="/etc/hopbox"
ENVFILE="$ETCDIR/hopbox.env"
VERSION="${HOPBOX_VERSION:-latest}"

log() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (e.g. via sudo)"
command -v docker >/dev/null 2>&1 || die "Docker is required but not installed"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"

case "$(uname -s)" in Linux) ;; *) die "Linux only" ;; esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported arch $(uname -m)" ;;
esac
log "platform: linux/$ARCH"

# --- docker bridge gateway: the address workspace containers reverse-dial ---
BRIDGE="$(ip -4 addr show docker0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)"
[ -n "$BRIDGE" ] || BRIDGE="172.17.0.1"
log "docker bridge gateway: $BRIDGE"

# --- download release binaries ---
base="https://github.com/$REPO/releases"
if [ "$VERSION" = "latest" ]; then
  dl="$base/latest/download"
else
  dl="$base/download/$VERSION"
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fetch() { # <release-asset.tar.gz> — extracts into $tmp
  log "downloading $1"
  curl -fsSL -o "$tmp/$1" "$dl/$1" || die "download failed: $dl/$1 (is there a release with linux/$ARCH assets?)"
  tar -xzf "$tmp/$1" -C "$tmp" || die "could not extract $1"
}
# Server bundle (hopboxd, hopbox-gw, hopbox-agent) + the CLI archive (hopbox).
fetch "hopbox-server_linux_$ARCH.tar.gz"
fetch "hopbox_linux_$ARCH.tar.gz"

# --- install binaries ---
install -m755 "$tmp/hopboxd" "$tmp/hopbox" "$tmp/hopbox-gw" "$PREFIX/"
mkdir -p "$LIBDIR"
install -m755 "$tmp/hopbox-agent" "$LIBDIR/hopbox-agent-linux-$ARCH"
log "installed binaries to $PREFIX and the agent to $LIBDIR"

# --- config (created once; edit then re-run to apply) ---
mkdir -p "$ETCDIR"
if [ ! -f "$ENVFILE" ]; then
  cat > "$ENVFILE" <<EOF
# Hopbox configuration. Edit, then re-run install.sh (or: systemctl restart hopboxd hopbox-gw).
HOPBOX_DB=$LIBDIR/hopbox.db
HOPBOX_AGENT_BIN=$LIBDIR/hopbox-agent-linux-$ARCH
# Address workspace containers dial back to reach hopboxd (docker bridge gateway):
HOPBOX_ADVERTISE=$BRIDGE:7777
# Wildcard gateway zone — workspaces are exposed at <name>-<id>.<zone>:
HOPBOX_ZONE=${HOPBOX_ZONE:-gw.example.com}
# API is unauthenticated for now — keep it on localhost and reach it via SSH:
HOPBOX_API_ADDR=127.0.0.1:7700
HOPBOX_AGENT_LISTEN=:7777
HOPBOX_TUNNEL_ADDR=127.0.0.1:7701
HOPBOX_GW_LISTEN=127.0.0.1:8088
HOPBOX_GW_ASK=127.0.0.1:8089
EOF
  log "wrote default config $ENVFILE"
else
  log "keeping existing config $ENVFILE"
fi
# shellcheck disable=SC1090
. "$ENVFILE"

# --- systemd units ---
cat > /etc/systemd/system/hopboxd.service <<EOF
[Unit]
Description=Hopbox control plane (hopboxd)
After=network.target docker.service
Requires=docker.service

[Service]
EnvironmentFile=$ENVFILE
ExecStart=$PREFIX/hopboxd --db \${HOPBOX_DB} --agent-bin \${HOPBOX_AGENT_BIN} \\
  --agent-listen \${HOPBOX_AGENT_LISTEN} --agent-advertise \${HOPBOX_ADVERTISE} \\
  --api-addr \${HOPBOX_API_ADDR} --gateway-addr= --tunnel-addr \${HOPBOX_TUNNEL_ADDR} \\
  --gateway-zone \${HOPBOX_ZONE}
Restart=on-failure
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/hopbox-gw.service <<EOF
[Unit]
Description=Hopbox service gateway (hopbox-gw)
After=network.target hopboxd.service
Wants=hopboxd.service

[Service]
EnvironmentFile=$ENVFILE
ExecStart=$PREFIX/hopbox-gw --listen \${HOPBOX_GW_LISTEN} --tunnel \${HOPBOX_TUNNEL_ADDR} \\
  --zone \${HOPBOX_ZONE} --ask-addr \${HOPBOX_GW_ASK}
Restart=on-failure
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF
log "installed systemd units"

# --- firewall: let workspace containers reverse-dial the agent port ---
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  agentport="$(printf '%s' "$HOPBOX_AGENT_LISTEN" | sed 's/^.*://')"
  if ! ufw status | grep -q "${agentport}.*ALLOW.*docker0"; then
    ufw allow in on docker0 to any port "$agentport" proto tcp >/dev/null 2>&1 || true
    log "ufw: allowed docker0 -> :$agentport (agent reverse-dial)"
  fi
fi

# --- optional Caddy gateway block (wildcard HTTPS via on-demand certs) ---
if [ "${HOPBOX_CADDY:-0}" = 1 ] && command -v caddy >/dev/null 2>&1; then
  cf=/etc/caddy/Caddyfile
  if [ -f "$cf" ] && ! grep -q "ask http://${HOPBOX_GW_ASK}" "$cf"; then
    cp "$cf" "$cf.bak.hopbox"
    log "appending Hopbox gateway block to $cf (backup at $cf.bak.hopbox)"
    cat >> "$cf" <<EOF

# --- Hopbox workspace gateway (on-demand TLS, bounded to the zone by the ask) ---
{
	on_demand_tls {
		ask http://${HOPBOX_GW_ASK}
	}
}
*.${HOPBOX_ZONE} {
	tls { on_demand }
	reverse_proxy ${HOPBOX_GW_LISTEN}
}
EOF
    caddy validate --config "$cf" --adapter caddyfile >/dev/null 2>&1 && systemctl reload caddy \
      && log "caddy reloaded" || die "caddy config invalid — restored backup: mv $cf.bak.hopbox $cf"
  fi
fi

# --- start ---
systemctl daemon-reload
systemctl enable --now hopboxd.service hopbox-gw.service
sleep 1
log "hopboxd: $(systemctl is-active hopboxd) | hopbox-gw: $(systemctl is-active hopbox-gw)"

cat <<EOF

Hopbox is installed and running.

  Config:    $ENVFILE   (edit + 'systemctl restart hopboxd hopbox-gw' to apply)
  CLI:       hopbox --addr ${HOPBOX_API_ADDR} ls

Next:
  1. DNS: point  *.${HOPBOX_ZONE}  at this server's public IP (wildcard A/AAAA).
  2. TLS: run with HOPBOX_CADDY=1 (Caddy installed) for automatic wildcard HTTPS,
     or terminate TLS yourself in front of ${HOPBOX_GW_LISTEN}.
  3. Create a workspace:
       hopbox --addr ${HOPBOX_API_ADDR} create demo --image ubuntu:24.04 --expose app:8000
       hopbox --addr ${HOPBOX_API_ADDR} exec demo -- uname -a

The API is unauthenticated — keep ${HOPBOX_API_ADDR} private (SSH in, or tunnel:
  ssh -L 7700:127.0.0.1:7700 <server>).
EOF
