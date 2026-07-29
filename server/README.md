# the container

A Debian LXC that holds a CalDAV server, a checkout of your notes, and a nightly
job that turns one into the other. `bootstrap.sh` does everything that can be
done without a browser or a phone in your hand; this is the rest, in order.

```
/opt/cal/
  mdical/          this repo, read-only deploy key
  vault/           your notes, read-WRITE deploy key
  vdir/
    cal-events/    .ics files, one per VEVENT
    cal-tasks/     .ics files, one per VTODO
  state/
    last-build.lua counts, emitted UIDs, and which mdical built them
    run.lock       flock, so two runs cannot overlap
    vdirsyncer/    sync status
  secrets/
    caldav-password
  cal.env          run.sh configuration
```

## 1. the container, on the Proxmox host

Debian, **unprivileged**, static IP on `192.168.1.0/24`. 1 vCPU, 1 GB RAM, 8 GB
disk - radicale is one python process and the build is a nightly script.

Tailscale needs `/dev/net/tun`, which an unprivileged container does not get by
default:

```
pct set <CTID> --dev0 /dev/net/tun
pct reboot <CTID>
```

or Resources → Add → Device Passthrough → `/dev/net/tun`. **Stay unprivileged** -
tailscale's own documentation says not to switch to privileged just for this.

## 2. bootstrap

```
apt install -y git
git clone https://github.com/oliver-hughes/mdical /opt/cal/mdical
/opt/cal/mdical/server/bootstrap.sh
```

The first run gets as far as the vault clone, prints two public keys and stops.
Add them on GitHub - the **vault** key needs write access, since the ratchet
pushes markdown back; mdical's is read-only - and run it again. It picks up from
where it stopped.

Clone over HTTPS the first time because there is no key yet. Once bootstrap has
made one, `run.sh` pulls mdical over `github-mdical`, so switch the remote after:

```
sudo -u cal git -C /opt/cal/mdical remote set-url origin git@github-mdical:oliver-hughes/mdical.git
```

## 3. tailscale

```
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
tailscale serve --bg https / http://localhost:5232
tailscale serve status
```

`serve` needs **MagicDNS and HTTPS certificates** enabled for the tailnet in the
admin console, or it has no certificate to provision and fails with nothing much
to go on. `serve status` should then show a `*.ts.net` URL.

This is why tailscale lives in this container rather than on the host: `serve`
proxies to localhost targets only, which is also what lets radicale bind to
localhost and never appear on the LAN at all.

## 4. the phone

Settings → Calendar → Accounts → Add Account → Other → **Add CalDAV Account**.

- Server: the `*.ts.net` hostname, no scheme, no path
- User name and Password: `hugheso` and the password bootstrap printed
- **SSL on**

Then confirm **both** Calendars and Reminders toggles exist and are on. If
Reminders is missing, the collection's advertised component set is wrong - see
`mkcollections.sh` - and iOS caches that from the moment the account was added,
so fix it there, then **delete the account and add it again**.

CalDAV on iOS is fetch, not push. Most "it didn't sync" is an unfetched account:
pull to refresh.

## 5. the first run

```
sudo -u cal /opt/cal/mdical/server/run.sh --dry-run --verbose
sudo -u cal /opt/cal/mdical/server/run.sh --verbose
```

The dry run does the two reads and no writes: no git, no vdirsyncer, and both
binaries in `--dry-run`. It is the cheap way to find out that the vault clone or
the scope tags are wrong before anything is published.

`--no-sync` skips vdirsyncer, for when you want to test the build alone.

## running it

```
systemctl list-timers mdical.timer     when it next fires
systemctl start mdical                 now, without waiting
journalctl -u mdical -n 100            what the last run did
journalctl -u radicale -f              what the phone is asking for
```

`Persistent=true` on the timer is the reason it is a timer and not a cron line: a
container that was off at 03:17 runs as soon as it comes back, rather than
silently skipping a day of completions.

## the order, and why it is the order

```
1  git pull                  the laptop's edits
2  vdirsyncer sync           the phone's ticks, into the vdir
3  mdical-ingest             completions back into markdown
5  git commit && git push    durable, BEFORE the resource disappears
6  mdical-build              rebuild the vdir from markdown
7  vdirsyncer sync           push it
8  healthcheck               only on a fully clean run
```

**Ingest before reconcile.** Backwards, and everything the phone did looks like an
orphan to the rebuild and gets deleted.

**Step 5 before step 6.** A completed task stops being emitted, so step 6 deletes
its resource. If the commit had not landed first, a failure between them would
re-publish the task as outstanding on the next run and you would tick it twice -
and the second tick would have nothing left to match.

Everything that writes is idempotent, so a run that dies anywhere is safe to
repeat. The two steps that are not - the commit, and the vdir delete - are
ordered so that repeating them is a no-op rather than a loss.

## when something is wrong

**The build refused to publish.** The count-drop gate saw the item count fall
sharply against the last run, which is what one bad parse looks like. Nothing was
changed. Look at `mdical-build --vault /opt/cal/vault --dry-run --verbose` first;
`--force` publishes anyway once you know why.

**A note "changed underneath us".** Ingest plans a line and then re-checks it
before writing. That message means the bytes moved in between, so it wrote
nothing to that file. Something else is editing the vault on the box.

**The run finished with warnings.** Deliberately no healthcheck ping, so the dead
man's switch fires. The usual cause is a push that could not land: the calendar is
still correct and the commit is safe locally, but the laptop is behind until the
next run gets it away.

**A task came back after being ticked.** Its summary probably changed. UIDs are
content hashes of kind, summary and date, so renaming a task makes it a different
task - the old resource goes and a new one arrives.

**Something on the phone was overwritten.** Expected, for anything but completion:
`conflict_resolution = "a wins"` makes markdown authoritative. That is M0's B10
question answered on purpose.
