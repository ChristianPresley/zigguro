# `.zgcrash` v1 format

Normative specification of the zigguro crash report format (E17.F05.S01.T01). An independent reader can be written from this page alone. The reference implementation is `packages/crash/src/format.zig`.

## Conventions

- All integers are little-endian, unsigned unless stated.
- Offsets are from the start of the file.
- "Padded to 8" means zero bytes are appended until the length is a multiple of 8.

## File layout

```
Header (32 bytes)
Section*            each: SectionHeader (16 bytes) + data (len bytes) + zero padding to 8
```

Reports are streamed: a writer never seeks back. A reader iterates sections until end of file. It stops early, and reports the file as truncated, when fewer than 16 bytes remain for a section header, when fewer than `len` bytes remain for its data, or when the data's CRC does not match. Every prefix of a valid report therefore reads as a valid, possibly shorter, report.

### Header

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 8 | magic | `ZGCRASH\0` (`5A 47 43 52 41 53 48 00`) |
| 8 | 2 | version | 1 |
| 10 | 2 | flags | 0 (reserved) |
| 12 | 4 | section_count | `0xFFFFFFFF` (streaming; readers ignore it) |
| 16 | 8 | created_unix_ms | i64, crash time in Unix milliseconds (UTC) |
| 24 | 8 | reserved | 0 |

Readers reject a wrong magic and any version other than 1.

### Section header

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 4 | kind | section kind (below) |
| 4 | 4 | len | data length in bytes, excluding padding |
| 8 | 4 | crc32 | CRC-32 (IEEE 802.3, as zlib) of the `len` data bytes |
| 12 | 4 | flags | bit 0: data was cut to fit the writer buffer; other bits 0 |

Readers skip sections of unknown kind.

## Section kinds

| Kind | Name | Data |
|---|---|---|
| 1 | META | ZON text (below) |
| 2 | EXCEPTION | `Exception` struct |
| 3 | CONTEXT | CPU context |
| 4 | STACK | raw stack window |
| 5 | TRACE | return addresses |
| 6 | MODULES | loaded modules |
| 7 | THREADS | thread list |
| 8 | LOG | recent log lines |
| 9 | ANNOTATIONS | key/value annotations |
| 10 | FLIGHT | E14 flight recorder dump (opaque to this format) |
| 11 | PANIC_MESSAGE | UTF-8 panic message |

### META (1)

A ZON struct literal with string fields unless noted: `.product`, `.version`, `.channel`, `.commit`, `.target`, `.optimize`, `.os_version`, `.pid` (integer), `.uptime_ms` (integer), `.boot_pending` (bool), `.report_kind`, `.install_kind`. Readers must tolerate missing and extra fields.

### EXCEPTION (2), 48 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | kind: 0 unknown, 1 segfault, 2 illegal_instruction, 3 bus_error, 4 arithmetic, 5 abort, 6 trap, 7 bad_syscall, 8 panic, 9 stack_overflow, 10 windows_exception |
| 2 | 2 | reserved (0) |
| 4 | 4 | os_code: signal number (Linux) or NTSTATUS (Windows) |
| 8 | 4 | si_code (i32) |
| 12 | 1 | has_fault_addr (0 or 1) |
| 13 | 1 | access: 0 read, 1 write, 8 execute, 255 not applicable |
| 14 | 2 | reserved (0) |
| 16 | 8 | fault_addr |
| 24 | 8 | thread_id of the crashing thread |
| 32 | 8 | pc |
| 40 | 8 | sp |

### CONTEXT (3)

`arch: u16` (the numeric `std.Target.Cpu.Arch` tag of the build's Zig version), `size: u16`, then `size` bytes of the native CPU context as captured by `std.debug.cpu_context`. Readers decode x86_64 and aarch64 and show other architectures as hex.

### STACK (4)

`start_addr: u64`, then the raw bytes of the crashing thread's stack starting at that address (from `sp - 128`, clamped to the stack mapping).

### TRACE (5)

`count: u32`, 4 zero bytes, `count` × `u64` return addresses (innermost first), then `skipped: u64` (0 none, `0xFFFFFFFFFFFFFFFF` unknown, otherwise the exact number of omitted frames).

### MODULES (6)

`count: u32`, 4 zero bytes, then `count` entries. Each entry is a 24-byte header followed by `id_len` id bytes and `path_len` path bytes, padded to 8:

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | base address |
| 8 | 8 | size |
| 16 | 1 | id_kind: 0 none, 1 GNU build id, 2 PDB 7.0 (GUID 16 bytes + age u32) |
| 17 | 1 | id_len |
| 18 | 2 | path_len |
| 20 | 4 | reserved (0) |

### THREADS (7)

`count: u32`, 4 zero bytes, then `count` entries of `tid: u64`, `name_len: u8`, name bytes, padded to 8.

### LOG (8)

UTF-8 text, one line per record: `<unix_ms> <level> <scope>: <message>\n`, oldest first.

### ANNOTATIONS (9)

`count: u32`, then `count` entries of `key_len: u8`, `value_len: u8`, key bytes, value bytes (no padding between entries). A value of `<torn>` means it was being written during the crash.

Registered keys and their owners: `ui.view`, `ui.modal` (E04); `cmd.last` (E15); `gpu.device`, `gpu.driver`, `gpu.api` (E02); `boot_pending`, `update.channel` (E17); `agent.state` (E10, state only, never transcript content); `scm.op` (E09). Keys are at most 31 bytes, values at most 224 bytes.

### PANIC_MESSAGE (11)

The UTF-8 panic message, without a trailing newline.

## File names and retention

Reports live in `<state>/crashes/` and are named `<YYYYMMDDTHHMMSSmmmZ>-<pid>.zgcrash` in UTC, for example `20251021T031700123Z-4242.zgcrash`. The store keeps the newest 50 reports and at most 50 MiB, deleting the oldest first.
