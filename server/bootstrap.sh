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

# `set -e` exits silently, which in a script this long is the difference between a
# five-second fix and an evening. Say which line, and what the status was.
trap 'echo "
bootstrap.sh: FAILED at line $LINENO with status $? - nothing after this ran.
Fix it and run bootstrap.sh again; it is idempotent and picks up where it stopped." >&2' ERR

MDICAL="$(cd "$(dirname "$0")/.." && pwd)"
CAL_ROOT=/opt/cal
CAL_USER="${CAL_USER:-hugheso}"
VAULT_REMOTE="${VAULT_REMOTE:-git@github-vault:oliver-hughes/vaults.git}"

[ "$(id -u)" = 0 ] || { echo "bootstrap.sh: run as root" >&2; exit 1; }

step() { printf '\n== %s\n' "$*"; }
todo() { printf '\n-- TODO %s\n' "$*"; }

# Run a command as the cal user.
#
# Not plain `sudo`: a minimal Debian LXC template does not ship it, and bootstrap
# runs as root so nothing here needed it until the deploy keys. `runuser` is
# util-linux and is always present.
#
# HOME is set explicitly because neither tool sets it for a non-login invocation.
# Without it `vdirsyncer discover` reads /root/.config and `git clone` uses root's
# ssh keys, both of which fail in a way that does not mention the home directory.
as_cal() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -u cal -- env HOME="$CAL_ROOT" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -H -u cal "$@"
  else
    echo "bootstrap.sh: neither runuser nor sudo is available" >&2
    return 1
  fi
}

# ------------------------------------------------------------------ 1  packages

step "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# luajit runs the build; apache2-utils is only for htpasswd -B; curl for
# MKCALENDAR and the healthcheck. No luarocks and no lpeg: the parser uses plain
# lua patterns, so there is no C dependency to build in here.
# sudo is not in a minimal LXC template. bootstrap does not need it - it uses
# runuser - but the runbook's manual commands do, and so does anyone who ever logs
# in to look at this box.
apt-get install -y -qq git curl pipx luajit apache2-utils sudo

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
install -d -o cal -g cal -m 0755 "$CAL_ROOT/vdir/cal-events" "$CAL_ROOT/vdir/cal-tasks"
install -d -o cal -g cal -m 0700 "$CAL_ROOT/secrets" "$CAL_ROOT/.ssh"
install -d -o cal -g cal -m 0755 "$CAL_ROOT/.config/vdirsyncer"
install -d -o cal -g cal -m 0750 /var/lib/radicale /var/lib/radicale/collections
install -d -m 0755 /etc/radicale

# Everything under /opt/cal belongs to cal, and this repairs whatever does not.
# Two ways it gets out of step: the mdical checkout is cloned by hand as root
# before bootstrap exists to do it, and anything run as root leaves root-owned
# files behind - state/run.lock being the one that then fails with a bare
# "Permission denied" and no hint as to why.
#
# Cheap, idempotent, and the thing to reach for whenever the nightly run starts
# failing on a file it used to be able to write.
chown -R cal:cal "$CAL_ROOT"

# --------------------------------------------------------------- 3  the secret

step "the CalDAV password"
if [ ! -s "$CAL_ROOT/secrets/caldav-password" ]; then
  # Typed into the phone once, then never again, so length beats memorability.
  #
  # A **bounded** read from urandom, not `tr < /dev/urandom | head -c 32`. That
  # reads an infinite source into a consumer that exits early, so `tr` takes
  # SIGPIPE and the pipeline returns 141 - which under `set -o pipefail` killed
  # this script stone dead with no message at all. 1 KiB of random bytes yields
  # around 248 alphanumerics, so 32 is never in doubt, and `cut` reads to EOF so
  # nothing gets a broken pipe. LC_ALL=C because BSD `tr` rejects random bytes as
  # an illegal multibyte sequence.
  password="$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-32)"
  [ ${#password} -eq 32 ] || { echo "could not generate a password (got ${#password} chars)" >&2; exit 1; }
  printf '%s' "$password" > "$CAL_ROOT/secrets/caldav-password"
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
  [ -f "$key" ] || as_cal ssh-keygen -t ed25519 -N "" -C "cal@$(hostname)-$name" -f "$key" -q
done

# Regenerated every run: it is a generated file, and an older one had `~` paths
# that broke as soon as HOME was not cal's.
#
# Host aliases, because both keys talk to the same hostname and ssh would
# otherwise offer the wrong one first.
#
# Absolute IdentityFile paths, not `~/.ssh/...`. A tilde expands against the
# *running* user's home, so the moment anything invokes git with HOME pointing
# elsewhere the key silently is not found - and even `ssh -F` on this file does not
# save you, because the expansion happens at use.
cat > "$CAL_ROOT/.ssh/config" <<EOF
Host github-vault
  HostName github.com
  User git
  IdentityFile $CAL_ROOT/.ssh/id_vault
  IdentitiesOnly yes

Host github-mdical
  HostName github.com
  User git
  IdentityFile $CAL_ROOT/.ssh/id_mdical
  IdentitiesOnly yes
EOF
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
elif as_cal git ls-remote "$VAULT_REMOTE" >/dev/null 2>&1; then
  as_cal git clone --quiet "$VAULT_REMOTE" "$CAL_ROOT/vault"
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
as_cal sh -c 'yes | vdirsyncer discover' || {
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

Then a first run you can watch. Run them as root - run.sh re-executes itself as
the cal user, so there is nothing to remember and no need for sudo:

  $MDICAL/server/run.sh --dry-run --pull --verbose
  $MDICAL/server/run.sh --verbose

--pull matters on a dry run: without it the preview reads the checkout as it
stands, which is not what you just pushed from the laptop.
EOF
