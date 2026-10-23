# Time zone fixtures

`Europe_Berlin.tzif` is `/usr/share/zoneinfo/Europe/Berlin` from Ubuntu's
tzdata 2026e (IANA tz database, public domain). It is the "fat" TZif v2
file: transitions through 2037 plus the POSIX footer
`CET-1CEST,M3.5.0,M10.5.0/3`, which `localtime.zig` applies after that.
