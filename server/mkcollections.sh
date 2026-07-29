#!/usr/bin/env bash
#
# Create the two CalDAV collections. Run once, after radicale is up and before
# `vdirsyncer discover`.
#
#   ./mkcollections.sh
#
# Lifted from the M0 spike's script of the same name, with the spike's plaintext
# auth swapped for the real credential and the names changed to the ones the
# build writes.
#
# **Separate collections per component type is not cosmetic.** iOS gives
# Calendars and Reminders independent toggles and decides which to offer from the
# advertised `supported-calendar-component-set`. If the Reminders toggle does not
# appear on the phone, this is why - and iOS caches the component set from the
# moment the account was added, so fixing it here is only half the job: delete
# the account on the phone and add it again.

set -euo pipefail

CAL_HOST="${CAL_HOST:-localhost:5232}"
CAL_USER="${CAL_USER:-hugheso}"
CAL_PASS="${CAL_PASS:-$(cat /opt/cal/secrets/caldav-password)}"

mk() {
  local path="$1" name="$2" comp="$3"
  printf '%-12s %-14s ' "$path" "$comp"
  curl -sS -u "$CAL_USER:$CAL_PASS" -X MKCALENDAR \
    -H 'Content-Type: application/xml; charset=utf-8' \
    -w '%{http_code}\n' \
    --data-binary @- "http://$CAL_HOST/$CAL_USER/$path/" <<XML
<?xml version="1.0" encoding="utf-8"?>
<C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:set><D:prop>
    <D:displayname>$name</D:displayname>
    <C:supported-calendar-component-set><C:comp name="$comp"/></C:supported-calendar-component-set>
  </D:prop></D:set>
</C:mkcalendar>
XML
}

# 201 = created. 405 on a second run means it is already there, which is fine.
mk cal-events "Calendar" VEVENT
mk cal-tasks  "Tasks"    VTODO

echo
echo "check what was advertised:"
echo "  curl -sS -u $CAL_USER:... -X PROPFIND -H 'Depth: 1' http://$CAL_HOST/$CAL_USER/ | xmllint --format -"
