#!/usr/bin/env bash
# provision.sh — stand up a full hopbox microVM host on a fresh Debian/Ubuntu server,
# zero human actions. Idempotent: re-run to update binaries, kernel, or catalog.
#
#   curl -fsSL https://hopbox.dev/provision.sh | sudo bash
#
# Needs: root, x86_64, /dev/kvm (bare metal or nested virt). Builds hopbox from source
# (installs Go), fetches Firecracker + the guest kernel, builds the image catalog,
# and installs a systemd service.
#
# SAFETY: the front door defaults to :2222 so it never collides with the host sshd on
# :22 (that would lock you out). To serve the public front door on :22, do the cutover
# deliberately after verifying — move host sshd to another port, then set
# ssh-addr: ":22" in /etc/hopbox/hopboxd.yaml and restart hopboxd.
#
# Env (all optional): HOPBOX_REF (git ref, default main), HOPBOX_CHANNEL (trunk|release
#   — only needed to re-run this on a host currently running the RELEASE artifact,
#   since building from source here moves it to trunk), FC_VERSION, KERNEL_URL,
#   GO_VERSION. Daemon settings live in /etc/hopbox/hopboxd.yaml (see
#   deploy/hopboxd.example.yaml); edit + `systemctl restart hopboxd`.
set -euo pipefail

REPO="https://github.com/hopboxdev/hopbox"
HOPBOX_REF="${HOPBOX_REF:-main}"
FC_VERSION="${FC_VERSION:-1.14.1}"
GO_VERSION="${GO_VERSION:-1.23.4}"
KERNEL_URL="${KERNEL_URL:-https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.10/x86_64/vmlinux-5.10.223}"
MVM=/opt/hopbox-microvm; PREFIX=/usr/local/bin; LIB=/var/lib/hopbox; ETC=/etc/hopbox; SRC=/opt/hopbox-src

log() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ "$(uname -m)" = x86_64 ] || die "x86_64 only"
[ -e /dev/kvm ] || die "no /dev/kvm — need KVM (bare metal or nested virt)"

log "1/6 base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# sqlite3 is the backup path's snapshot tool (consistent VACUUM INTO copies).
apt-get install -y -qq curl git ca-certificates e2fsprogs debootstrap iproute2 iptables sqlite3 >/dev/null
# rclone ships backups off-host. Optional: a filesystem destination needs no rclone,
# and a distro without the package must not fail the whole provision.
apt-get install -y -qq rclone >/dev/null 2>&1 ||
  log "rclone not available from apt — install it if you back up to a remote (a filesystem destination doesn't need it)"

log "2/6 Go $GO_VERSION (to build hopbox)"
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go$GO_VERSION"; then
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
fi
export PATH=/usr/local/go/bin:$PATH

log "3/6 Firecracker v$FC_VERSION"
if ! firecracker --version 2>/dev/null | grep -q "v$FC_VERSION"; then
  curl -fsSL "https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-x86_64.tgz" -o /tmp/fc.tgz
  tar -xzf /tmp/fc.tgz -C /tmp
  install -m0755 "/tmp/release-v${FC_VERSION}-x86_64/firecracker-v${FC_VERSION}-x86_64" "$PREFIX/firecracker"
fi

log "4/6 guest kernel"
mkdir -p "$MVM/images" "$LIB"
[ -f "$MVM/vmlinux" ] || curl -fSL --retry 3 -o "$MVM/vmlinux" "$KERNEL_URL"
# NOTE: this prebuilt kernel has NO FUSE. For the shared /wrk workspace, replace it
# with a FUSE kernel via deploy/build-fuse-kernel.sh (see deploy/README + docs/deploy).

# juicefs — host-side, so hopboxd can format workspace volumes (also baked into images).
if ! command -v juicefs >/dev/null 2>&1; then
  JFS_URL=$(curl -sSL https://api.github.com/repos/juicedata/juicefs/releases/latest | grep -oE 'https://[^"]+juicefs-[0-9.]+-linux-amd64.tar.gz' | head -1)
  curl -fsSL "$JFS_URL" -o /tmp/jfs.tgz && tar -xzf /tmp/jfs.tgz -C /tmp juicefs && install -m0755 /tmp/juicefs "$PREFIX/juicefs"
fi

log "5/6 build hopbox @ $HOPBOX_REF (into a staging bundle)"
if [ -d "$SRC/.git" ]; then git -C "$SRC" fetch -q origin; else git clone -q "$REPO" "$SRC"; fi
# $SRC is root-owned, so git's dubious-ownership guard makes `cd $SRC && git log` fail
# for the login user — which is how a human answers "what is actually deployed here?".
# SYSTEM scope (/etc/gitconfig) so it covers every account on the host, not just root's
# ~/.gitconfig; safe.directory is only honoured from protected (system/global) config,
# so this is the right place. Idempotent: `--add` duplicates, so only add when missing.
if ! git config --system --get-all safe.directory 2>/dev/null | grep -qxF -e "$SRC" -e '*'; then
  git config --system --add safe.directory "$SRC"
  log "marked $SRC a git safe.directory (system-wide)"
fi
git -C "$SRC" checkout -q "$HOPBOX_REF"; git -C "$SRC" pull -q origin "$HOPBOX_REF" 2>/dev/null || true
# Build into a STAGING dir, never straight into $PREFIX. On a host that hopbox-host
# already manages, three of those $PREFIX names are its release symlinks, and
# `go build -o` REPLACES a symlink with a plain file. That silently evicts the host
# from release management: /usr/local/bin/hopboxd stops pointing into
# /opt/hopbox/releases/<sha>/, so `hopbox-host` can no longer tell which release is
# live — rollback loses its target and `clean` refuses (it will not guess), until the
# next hopbox-host run migrates the loose binaries into a `pre-hopbox-host` release
# that is no longer named for any sha.
#
# The sharp end: provision.sh never writes `deployed-sha`. Re-run it with a
# HOPBOX_REF other than what is deployed and the live binaries come from ref B while
# `deployed-sha` — and so `hopbox-host status` — still reports sha A. The host then
# reports a version it is not running, and it swapped to it with no --check, no
# health gate, and nothing to roll back to. Stage here; deploy through hopbox-host.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
( cd "$SRC"
  # -buildvcs=false on the two binaries the images bake: Go stamps the commit into
  # every binary, which moved the agent's content sha on every commit and made
  # `hopbox-host status` report `agent: DRIFT` after deploys that never touched it.
  CGO_ENABLED=0 go build -tags "docker firecracker" -o "$STAGE/hopboxd" ./cmd/hopboxd
  CGO_ENABLED=0 go build -o "$STAGE/hopbox-mcp"   ./cmd/hopbox-mcp
  CGO_ENABLED=0 go build -buildvcs=false -o "$STAGE/box-guest"    ./cmd/box-guest
  CGO_ENABLED=0 go build -buildvcs=false -o "$STAGE/hopbox-agent" ./cmd/hopbox-agent
  CGO_ENABLED=0 go build -o "$STAGE/hopbox-host"  ./cmd/hopbox-host
  # Makes $STAGE a bundle `hopbox-host update --from` accepts. A source build is the
  # `trunk` channel even when $HOPBOX_REF is a tag: compiling a tag on the host is
  # still not the artifact users install, so it must not claim to be one.
  sh build/release-manifest.sh "$STAGE/hopbox-release.json" "" "$(git rev-parse HEAD)" trunk >/dev/null
  # hopbox-backup ships inside the bundle, so the deploy installs the script this
  # release was built with instead of whatever the host last copied out of $SRC.
  cp deploy/backup.sh "$STAGE/backup.sh" )
# hopbox-host is never part of a release swap, so $PREFIX/hopbox-host is a plain file
# and safe to replace directly — and the deploy below needs this new one (--from).
install -m0755 "$STAGE/hopbox-host" "$PREFIX/hopbox-host"

log "6/6 hand off to hopbox-host (config, unit, deploy, catalog, backups)"
# Everything below the prerequisites is hopbox-host's to own. It was bash here twice
# before, and twice it drifted from what hopbox-host already did: building over the
# release symlinks, and calling catalog.sh directly so the drift fingerprint was never
# recorded. Neither failed loudly. Owning it in one place, next to the code that
# depends on it, is what stops a third variant of that bug.
#
# HOPBOX_CHANNEL is forwarded, not assumed: this bundle is a source build (`trunk`),
# so re-running the provisioner on a host that runs the RELEASE artifact would move it
# off release. hopbox-host refuses that unless it is asked for, and this is how you ask
# — the same rule, and the same flag, as a plain `hopbox-host update`.
hopbox-host bootstrap --from "$STAGE" ${HOPBOX_CHANNEL:+--channel "$HOPBOX_CHANNEL"}

sleep 3
log "hopboxd: $(systemctl is-active hopboxd)"
echo
echo "  Config:   $ETC/hopboxd.yaml   (edit + systemctl restart hopboxd)"
echo "  Cutover:  move host sshd off :22, set  ssh-addr: \":22\"  in the config, restart."
# No backup warning here: bootstrap owns it, and only IT can tell whether a
# destination is set. A copy in this script read a variable that no longer exists, so
# it warned on every run — including hosts whose backups were configured and working.
# A warning that fires when the thing is fine is how you learn to skip warnings.
