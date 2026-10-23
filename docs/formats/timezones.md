# Time zones

Automations run on wall-clock schedules (`0 9 * * 1-5` means 09:00 local
time), so the scheduler needs the IANA zone rules. zg_agents reads them
itself, with no libc and no ICU (`packages/agents/src/sched/tz.zig`).

## Where the zone comes from

| Platform | System zone | Named zones (`TimeZone.named`) |
| --- | --- | --- |
| Linux and other Unixes | `$TZ`, then `/etc/localtime` | `/usr/share/zoneinfo/<Area/City>`, then the embedded set |
| Windows | `GetDynamicTimeZoneInformation`, mapped to IANA through CLDR | the embedded set only |

`$TZ` may be empty (UTC), `:Area/City` or `Area/City` (a zoneinfo file),
an absolute path to a TZif file, or a POSIX rule string such as
`EST5EDT,M3.2.0,M11.1.0`. A zone that cannot be read falls back to UTC.

## Formats

- **TZif** (RFC 9636) versions 1 to 4. Version 2+ files are read from the
  64-bit block; leap-second records are ignored. The reader keeps at most
  twice the file's size. `std.tz` is not used because it rejects version 4
  and ignores the footer.
- **POSIX TZ rules**, from a TZif footer or `$TZ`: `std offset [dst
  [offset] [,start[/time],end[/time]]]` with `Mm.w.d`, `Jn` and `n` dates,
  quoted names (`<+0330>`) and the RFC 9636 extensions (rule times from
  -167 to 167 hours, all-year daylight saving time). Instants after a
  zone's last transition follow its footer rule.

Wall times that do not exist (the clocks went forward) resolve to the
first instant after the gap; wall times that happen twice resolve to both
instants, and a schedule fires only at the earlier one.

## The embedded set and its limitation on Windows

Windows has no TZif files. Windows builds embed
`packages/agents/src/sched/tzdata/zones.bin`: every IANA zone that a
Windows zone id maps to in CLDR's `windowsZones.xml` (territory `001`
rows, about 140 zones, about 120 KB), plus UTC. The Windows zone id is
mapped with `tzdata/windows_zones.zon`, which also lists IANA aliases
(`Asia/Calcutta` is `Asia/Kolkata`).

Limitations:

- On Windows, `TimeZone.named` knows only the embedded zones. Zones that
  no Windows zone maps to (for example `Australia/Lord_Howe` or
  `Pacific/Chatham`) are unknown there.
- If the system zone id is not in the table (a new Windows zone), the zone
  is built from the `DYNAMIC_TIME_ZONE_INFORMATION` instead: the current
  year's rule applied to every year, so past dates may be off.
- The embedded rules are as current as the tzdata release they were built
  from (recorded as `.tzdata` in `windows_zones.zon`); Windows updates do
  not change them.

## Updating the data

The generator is `tools/tzdata_gen` (`zig build tzdata-gen`). Its inputs:

- `tools/tzdata_gen/data/windowsZones.xml`: the territory `001` rows of
  CLDR's `common/supplemental/windowsZones.xml`.
- `tools/tzdata_gen/data/links.txt`: the `L` (link) lines of `tzdata.zi`.
- The compiled zones of an installed tzdata release (`/usr/share/zoneinfo`
  by default, which must contain `tzdata.zi`).

To update:

1. Install the new tzdata release (or build it with `zic` into a
   directory) and copy the `L` lines of its `tzdata.zi` into `links.txt`.
2. Replace the rows of `windowsZones.xml` with the current CLDR rows that
   have `territory="001"`.
3. Run `zig build tzdata-gen` (add `-- --zoneinfo <dir>` for a directory
   other than `/usr/share/zoneinfo`). It rewrites `zones.bin` and
   `windows_zones.zon`; `-- --check` reports whether they are current.
4. Update the versions in `packaging/notices/iana-tzdata.zon` and
   `packaging/notices/cldr-windows-zones.zon`, then run
   `zig build test-agents`.

The test fixtures in `packages/agents/src/sched/testdata/tz/` are compiled
zones copied from tzdata 2026e and need no update.
