#!/usr/bin/env bash
#
# Stand up the container. Run as root, from a checkout of mdical:
#
#   git clone git@github-mdical:oliver-hughes/mdical.git /opt/cal/mdical
#   /opt/cal/mdical/server/bootstrap.sh
#
# Idempotent, and designed to be re-run: it stops when it needs something from
# you - a deploy key added on GitHub, a tailscale login - and picks up from there
# next time. Nothing here is interactive, so it can be read before it is trusted.
#
# What it does NOT do, because both need a browser or a phone in your hand:
#   - `tailscale up` and `tailscale serve`
#   - adding the CalDAV account on the phone
# Both are in README.md, which is also where the tun passthrough that has to
# happen on the Proxmox host lives.

set -euo pipefail

MDICAL="$(cd "$(dirname "$0")/.." && pwd)"
CAL_ROOT=/opt/cal
CAL_USER="${CAL_USER:-hugheso}"
VAULT_REMOTE="${VAULT_REMOTE:-git@github-vault:oliver-hughes/vaults.git}"

[ "$(id -u)" = 0 ] || { echo "bootstrap.sh: run as root" >&2; exit 1; }

step() { printf '\n== %s\n' "$*"; }
todo() { printf '\n-- TODO %s\n' "$*"; }

# ------------------------------------------------------------------ 1  packages

step "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# luajit runs the build; apache2-utils is only for htpasswd -B; curl for
# MKCALENDAR and the healthcheck. No luarocks and no lpeg: the parser uses plain
# lua patterns, so there is no C dependency to build in here.
apt-get install -y -qq git curl pipx luajit apache2-utils

step "radicale and vdirsyncer"
# Installed to /usr/local/bin rather than root's ~/.local/bin, so a service
# running as the `cal` user can actually execute them. --global would do the
# same on a new enough pipx; the environment variables work on every version.
export PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin
# radicale's bcrypt support is an extra. Which shape it takes moved between 3.x
# releases, so try the extra and inject as a fallback.
pipx install "radicale[bcrypt]" 2>/dev/null || pipx install radicale || true
pipx inject radicale bcrypt passlib >/dev/null 2>&1 || true
pipx install vdirsyncer || true
pipx upgrade-all >/dev/null 2>&1 || true

# --------------------------------------------------------------- 2  user, dirs

step "the cal user and the layout"
# One user for both services rather than the two radicale's docs suggest. It owns
# /opt/cal, the collections, and the deploy keys, and it is the only account in a
# single-purpose unprivileged container behind tailscale. Two users would mean
# three sets of permissions between vdirsyncer, the vdir and the collections, and
# every one of them is a way for the nightly run to fail silently.
id -u cal >/dev/null 2>&1 || useradd --system --home-dir "$CAL_ROOT" --shell /usr/sbin/nologin cal

install -d -o cal -g cal -m 0755 "$CAL_ROOT" "$CAL_ROOT/vdir" "$CAL_ROOT/state"
# This checkout was cloned by you, as root, before bootstrap could exist to do it.
# run.sh pulls it as `cal` every night, so without this every single run fails to
# fast-forward, marks itself degraded, and never pings the healthcheck.
if [ -d "$MDICAL/.git" ]; then
  chown -R cal:cal "$MDICAL"
fi
install -d -o cal -g cal -m 0755 "$CAL_ROOT/vdir/cal-events" "$CAL_ROOT/vdir/cal-tasks"
install -d -o cal -g cal -m 0700 "$CAL_ROOT/secrets" "$CAL_ROOT/.ssh"
install -d -o cal -g cal -m 0755 "$CAL_ROOT/.config/vdirsyncer"
install -d -o cal -g cal -m 0750 /var/lib/radicale /var/lib/radicale/collections
install -d -m 0755 /etc/radicale

# --------------------------------------------------------------- 3  the secret

step "the CalDAV password"
if [ ! -s "$CAL_ROOT/secrets/caldav-password" ]; then
  # Typed into the phone once, then never again, so length beats memorability.
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 > "$CAL_ROOT/secrets/caldav-password"
  echo "generated a new one"
else
  echo "already there, leaving it alone"
fi
chown cal:cal "$CAL_ROOT/secrets/caldav-password"
chmod 0600 "$CAL_ROOT/secrets/caldav-password"

# ------------------------------------------------------------------ 4  radicale

step "radicale"
install -m 0644 "$MDICAL/server/radicale.config" /etc/radicale/config
# -B is bcrypt, which is what the config asks for; the spike's plaintext is gone.
htpasswd -B -b -c /etc/radicale/users "$CAL_USER" "$(cat "$CAL_ROOT/secrets/caldav-password")"
chown root:cal /etc/radicale/users
chmod 0640 /etc/radicale/users

install -m 0644 "$MDICAL/server/radicale.service" /etc/systemd/system/radicale.service
systemctl daemon-reload
systemctl enable --now radicale
sleep 2
systemctl is-active --quiet radicale || { echo "radicale did not start - journalctl -u radicale" >&2; exit 1; }
echo "listening on localhost:5232"

# --------------------------------------------------------------- 5  collections

step "the two collections"
# Must happen before `vdirsyncer discover`, and the component sets are what
# decide whether the phone offers a Reminders toggle at all.
CAL_USER="$CAL_USER" CAL_PASS="$(cat "$CAL_ROOT/secrets/caldav-password")" \
  "$MDICAL/server/mkcollections.sh"

# ---------------------------------------------------------------- 6  deploy keys

step "deploy keys"
# Two, because a GitHub deploy key is per-repository: the vault's must be
# read-write (the ratchet pushes markdown back), mdical's only needs read.
for name in vault mdical; do
  key="$CAL_ROOT/.ssh/id_$name"
  [ -f "$key" ] || sudo -u cal ssh-keygen -t ed25519 -N "" -C "cal@$(hostname)-$name" -f "$key" -q
done

if [ ! -f "$CAL_ROOT/.ssh/config" ]; then
  # Host aliases, because both keys talk to the same hostname and ssh would
  # otherwise offer the wrong one first.
  cat > "$CAL_ROOT/.ssh/config" <<'EOF'
Host github-vault
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_vault
  IdentitiesOnly yes

Host github-mdical
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_mdical
  IdentitiesOnly yes
EOF
fi
chown -R cal:cal "$CAL_ROOT/.ssh"
chmod 0600 "$CAL_ROOT/.ssh/config"
ssh-keyscan -t ed25519 github.com 2>/dev/null >> "$CAL_ROOT/.ssh/known_hosts" || true
sort -u "$CAL_ROOT/.ssh/known_hosts" -o "$CAL_ROOT/.ssh/known_hosts"
chown cal:cal "$CAL_ROOT/.ssh/known_hosts"
chmod 0644 "$CAL_ROOT/.ssh/known_hosts"

# ------------------------------------------------------------------- 7  configs

step "run.sh configuration"
if [ ! -f "$CAL_ROOT/cal.env" ]; then
  install -o cal -g cal -m 0640 "$MDICAL/server/cal.env.example" "$CAL_ROOT/cal.env"
  todo "set HEALTHCHECK in $CAL_ROOT/cal.env"
else
  echo "cal.env already there, leaving it alone"
fi
install -o cal -g cal -m 0644 "$MDICAL/server/vdirsyncer.config" "$CAL_ROOT/.config/vdirsyncer/config"

# --------------------------------------------------------------- 8  the vault

step "the vault"
if [ -d "$CAL_ROOT/vault/.git" ]; then
  echo "already cloned"
elif sudo -u cal git ls-remote "$VAULT_REMOTE" >/dev/null 2>&1; then
  sudo -u cal git clone --quiet "$VAULT_REMOTE" "$CAL_ROOT/vault"
  echo "cloned"
  # The repo root is not the vault. It holds brain/, main/ and ops/ side by side,
  # and pointing the scanner at the root would read all three.
  [ -d "$CAL_ROOT/vault/brain" ] || todo "no brain/ in the checkout - set VAULT in $CAL_ROOT/cal.env"
else
  todo "add this as a read-WRITE deploy key on the vault repo, then re-run:"
  echo
  cat "$CAL_ROOT/.ssh/id_vault.pub"
  echo
  todo "and this as a read-only deploy key on oliver-hughes/mdical:"
  echo
  cat "$CAL_ROOT/.ssh/id_mdical.pub"
  echo
  echo "bootstrap.sh: stopping here - everything above this point is done."
  exit 0
fi

# ---------------------------------------------------------- 9  vdirsyncer, timer

step "vdirsyncer discover"
# `discover` prompts to confirm creating collections and there is no flag for
# non-interactive, so answer it. The collections already exist from step 5, so
# there is nothing for it to create - this only writes the status files.
sudo -u cal sh -c 'yes | vdirsyncer discover' || {
  echo "discover failed - check $CAL_ROOT/.config/vdirsyncer/config" >&2
  exit 1
}

step "the nightly timer"
install -m 0644 "$MDICAL/server/mdical.service" /etc/systemd/system/mdical.service
install -m 0644 "$MDICAL/server/mdical.timer" /etc/systemd/system/mdical.timer
systemctl daemon-reload
systemctl enable --now mdical.timer
systemctl list-timers mdical.timer --no-pager

# ------------------------------------------------------------------------- done

step "done"
cat <<EOF
The CalDAV password, which the phone will want:

  $(cat "$CAL_ROOT/secrets/caldav-password")

Left to do by hand, both in README.md:

  tailscale up && tailscale serve --bg https / http://localhost:5232
  add the CalDAV account on the phone, SSL on

Then a first run you can watch:

  sudo -u cal $MDICAL/server/run.sh --dry-run --verbose
  sudo -u cal $MDICAL/server/run.sh --verbose
EOF
