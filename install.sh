#!/bin/sh
# hopbox installer — the compute-box substrate (`ssh box@host`).
#
#   curl -fsSL https://hopbox.dev/install.sh | sudo sh
#
# Installs hopboxd + hopbox-mcp + the in-box agent + box-guest, writes a systemd service, and
# starts it on the docker backend (zero extra setup). Idempotent: re-run to
# upgrade or reconfigure. Settings live in /etc/hopbox/hopboxd.env.
#
# Backends:
#   docker  (default) — boxes are containers; only Docker is required.
#   microvm           — boxes are Firecracker microVMs (auto-suspend/wake). Needs
#                       /dev/kvm + a golden rootfs (build/microvm/build-rootfs.sh).
#                       Set HOPBOX_COMPUTE=microvm and the fc-* paths below.
#
# Overrides (first run): HOPBOX_VERSION, HOPBOX_COMPUTE.
set -eu

PREFIX="/usr/local/bin"
LIBDIR="/var/lib/hopbox"
ETCDIR="/etc/hopbox"
ENVFILE="$ETCDIR/hopboxd.env"
VERSION="${HOPBOX_VERSION:-latest}"
COMPUTE="${HOPBOX_COMPUTE:-docker}"

log() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (e.g. via sudo)"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"
case "$(uname -s)" in Linux) ;; *) die "Linux only" ;; esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported arch $(uname -m)" ;;
esac
log "platform: linux/$ARCH  backend: $COMPUTE"

[ "$COMPUTE" = docker ] && ! command -v docker >/dev/null 2>&1 && die "the docker backend needs Docker installed"
[ "$COMPUTE" = microvm ] && [ ! -e /dev/kvm ] && die "the microvm backend needs /dev/kvm (KVM / nested virt)"

# --- download the box bundle ---
# From hopbox.dev, not GitHub releases: this repo is private, so a release asset is a
# 404 for anyone without access — which broke this installer for every outside user
# while still looking like a working one-liner. The release workflow mirrors each
# tag's artifacts to hopbox.dev/dl/<version>/ (and /dl/latest/), which is public.
# HOPBOX_DL overrides the mirror; the checksum is verified either way.
dl="${HOPBOX_DL:-https://hopbox.dev/dl}/$VERSION"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
asset="hopbox_linux_$ARCH.tar.gz"
log "downloading $asset ($VERSION)"
curl -fsSL -o "$tmp/$asset" "$dl/$asset" || die "download failed: $dl/$asset"
# Verify against the published checksums. A tarball that installs a daemon as root is
# worth one extra request; a mirror that silently served the wrong bytes should stop
# the install, not become the daemon.
if curl -fsSL -o "$tmp/checksums.txt" "$dl/checksums.txt" 2>/dev/null; then
  want="$(grep " $asset\$" "$tmp/checksums.txt" | cut -d' ' -f1)"
  got="$(sha256sum "$tmp/$asset" 2>/dev/null | cut -d' ' -f1)"
  [ -n "$want" ] && [ -n "$got" ] && [ "$want" != "$got" ] &&
    die "checksum mismatch for $asset (expected $want, got $got)"
else
  log "no checksums.txt at $dl — skipping verification"
fi
tar -xzf "$tmp/$asset" -C "$tmp" || die "could not extract $asset"

# --- install binaries ---
install -m755 "$tmp/hopboxd" "$tmp/hopbox-mcp" "$tmp/hopbox-host" "$tmp/box-guest" "$PREFIX/"
mkdir -p "$LIBDIR"
install -m755 "$tmp/hopbox-agent" "$LIBDIR/hopbox-agent-linux-$ARCH"
install -m755 "$tmp/box-guest"    "$LIBDIR/box-guest-linux-$ARCH"
log "installed hopboxd + hopbox-mcp + hopbox-host + box-guest to $PREFIX; agent + box-guest to $LIBDIR"

# --- config (created once) ---
mkdir -p "$ETCDIR"
if [ ! -f "$ENVFILE" ]; then
  cat > "$ENVFILE" <<EOF
# hopboxd configuration. Edit, then: systemctl restart hopboxd
HOPBOX_COMPUTE=$COMPUTE
HOPBOX_SSH_ADDR=:2222
HOPBOX_AGENT_LISTEN=:7777
HOPBOX_META_ADDR=:8090
HOPBOX_DB=$LIBDIR/hopboxd.db
HOPBOX_HOST_KEY=$LIBDIR/hopboxd-ssh-host-key
# docker backend: binaries side-loaded into each box
HOPBOX_AGENT_BIN=$LIBDIR/hopbox-agent-linux-$ARCH
HOPBOX_GUEST_BIN=$LIBDIR/box-guest-linux-$ARCH
# AI-control MCP plane (local socket) + optional canvas surfaces (set an addr to enable)
HOPBOX_MCP_ADDR=unix:/run/hopboxd-mcp.sock
# microvm backend: kernel + image catalog (build with build/microvm/build-rootfs.sh)
HOPBOX_FC_KERNEL=/opt/hopbox-microvm/vmlinux
HOPBOX_FC_IMAGES_DIR=/opt/hopbox-microvm/images
HOPBOX_DEFAULT_IMAGE=ubuntu-22.04
HOPBOX_FC_RUNDIR=$LIBDIR/microvm
# Default: ephemeral boxes (reaped a short grace after disconnect). HOPBOX_GRACE
# is the reconnect/blip window. Set HOPBOX_AUTO_SUSPEND=true for the persistent tier
# (auto-suspend on idle, resume on reconnect) — reserve that for known accounts.
HOPBOX_GRACE=2m
HOPBOX_AUTO_SUSPEND=false
HOPBOX_IDLE_TIMEOUT=5m
EOF
  log "wrote default config $ENVFILE"
else
  log "keeping existing config $ENVFILE"
fi
# shellcheck disable=SC1090
. "$ENVFILE"

# --- systemd unit ---
cat > /etc/systemd/system/hopboxd.service <<EOF
[Unit]
Description=hopbox compute-box daemon (hopboxd)
After=network.target docker.service

[Service]
EnvironmentFile=$ENVFILE
ExecStart=$PREFIX/hopboxd --compute \${HOPBOX_COMPUTE} \\
  --ssh-addr \${HOPBOX_SSH_ADDR} --agent-listen \${HOPBOX_AGENT_LISTEN} --meta-addr \${HOPBOX_META_ADDR} \\
  --db \${HOPBOX_DB} --host-key \${HOPBOX_HOST_KEY} \\
  --agent-bin \${HOPBOX_AGENT_BIN} --guest-bin \${HOPBOX_GUEST_BIN} \\
  --fc-kernel \${HOPBOX_FC_KERNEL} --fc-images-dir \${HOPBOX_FC_IMAGES_DIR} --fc-rundir \${HOPBOX_FC_RUNDIR} \\
  --default-image \${HOPBOX_DEFAULT_IMAGE} \\
  --mcp-addr \${HOPBOX_MCP_ADDR} \\
  --grace \${HOPBOX_GRACE} --auto-suspend=\${HOPBOX_AUTO_SUSPEND} --idle-timeout \${HOPBOX_IDLE_TIMEOUT}
# Only hopboxd gets SIGTERM on stop, so it can snapshot the firecracker children
# before they die (graceful drain).
KillMode=mixed
# The drain's cost is per BOX, not per shutdown, so no constant here can be right
# for both one box and thirty. NotifyAccess lets hopboxd push this deadline out
# itself (sd_notify EXTEND_TIMEOUT_USEC) for every box it finishes snapshotting —
# so this value is only the backstop for a drain making NO progress. Do not shrink
# it back to a "budget": that is what silently lost boxes.
NotifyAccess=main
TimeoutStopSec=300
Restart=on-failure
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF
log "installed systemd unit hopboxd.service"

systemctl daemon-reload
systemctl enable --now hopboxd.service
sleep 1
log "hopboxd: $(systemctl is-active hopboxd)"

cat <<EOF

hopboxd is installed and running ($COMPUTE backend).

  Config:  $ENVFILE  (edit + 'systemctl restart hopboxd' to apply)
  Connect: ssh box@<this-host> -p 2222     # spawns a box and drops you in

EOF
if [ "$COMPUTE" = microvm ]; then
cat <<EOF
microVM backend selected — build the image catalog first (once), then restart:
  # on a machine with Go (or pass prebuilt AGENT_BIN/GUEST_BIN):
  sudo IMAGE=ubuntu-22.04 OUT_DIR=/opt/hopbox-microvm build/microvm/build-rootfs.sh
  systemctl restart hopboxd
  # add more images:  sudo IMAGE=debian-default BASE_URL=<debian.ext4> ... build-rootfs.sh
EOF
fi
echo "Boxes are anonymous (key = identity). Keep the SSH front door where you want it."
