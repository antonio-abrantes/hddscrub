# AGENTS.md

## Project Context

This project implements an HDD Backup Integrity Checker for Windows.

The primary artifact is expected to be a PowerShell CLI script named:

```text
hdd-integrity-check.ps1
```

Its purpose is to help the user periodically verify cold-storage backup HDDs that are manually powered on and off through a physical controller. The script must never control electrical power. It only interacts with Windows disk state, SMART data, filesystem checks, checksums, logs, reports, and optional disk offline/online actions.

## Core Principle

These disks contain important backups. When in doubt, stop and ask for explicit user action.

Prefer:

```text
abort safely
```

over:

```text
continue automatically
```

No convenience feature justifies acting on a disk whose identity has not been confirmed.

## Platform

Target environment:

- Windows 10 or Windows 11.
- PowerShell 7 preferred.
- Windows PowerShell 5.1 acceptable only if all required functionality works.
- Administrator elevation is required for disk, SMART, and offline operations.
- `smartctl.exe` from smartmontools is required for SMART support.

Expected native PowerShell APIs/cmdlets include:

- `Get-Volume`
- `Get-Partition`
- `Get-Disk`
- `Set-Disk`
- `Get-CimInstance`
- `Get-FileHash`
- `Get-ChildItem`
- `Test-Path`

Check required dependencies before performing work.

## Safety Rules

Never automatically choose a disk for any operation that changes disk state.

The user must manually select the target drive by index or drive letter. Normalize input such as `E` and `E:` to `E:`.

Abort if:

- The selected drive does not exist.
- The selected drive is `C:`.
- The disk contains a boot or system partition.
- The disk contains the active pagefile.
- The physical disk cannot be resolved safely.
- SMART device mapping cannot be matched unambiguously by serial.
- The drive disappears during execution.
- The serial observed later differs from the serial captured at the start.

Never run destructive or repair commands by default, including:

- `Format-Volume`
- `Clear-Disk`
- `Initialize-Disk`
- `Remove-Partition`
- `diskpart clean`
- `chkdsk /f`
- `chkdsk /r`

Filesystem verification must be read-only/non-destructive by default.

## Disk Identity

Do not persist HDD identity by drive letter.

Primary identity:

```text
SerialNumber
```

Auxiliary identity fields:

- `UniqueId`
- model/friendly name
- disk number
- bus type
- capacity

The drive letter is only an initial manual selection mechanism.

Before placing a disk offline, repeat:

```text
DriveLetter -> Partition -> Disk -> Serial
```

Then compare the result with the original serial. Abort immediately on mismatch.

## SMART Mapping

Never assume:

```text
E: == /dev/sdX
```

Use `smartctl` scanning on Windows, query candidates, extract model/serial, and match against the serial reported by `Get-Disk`.

Proceed with SMART operations only when the match is unambiguous. If mapping fails, record the reason and abort by default.

## Verification Flow

The intended sequential workflow is:

1. List eligible volumes.
2. Let the user manually choose a drive.
3. Resolve the drive to a physical disk.
4. Show model, serial, capacity, disk number, and state.
5. Ask for confirmation before verification starts.
6. Capture an initial snapshot.
7. Run initial SMART collection.
8. Ask whether to run SMART Long/Extended Self-Test.
9. If enabled, run and poll the long test before heavy checksum reads.
10. Run read-only filesystem verification.
11. Run SHA-256 checksum baseline or comparison.
12. Generate TXT and JSON reports.
13. Show the result.
14. Separately ask whether to prepare the HDD for physical power-off.
15. If yes, ask for a second confirmation with full identity.
16. Revalidate serial and safety conditions.
17. Run `Set-Disk -IsOffline $true`.
18. Confirm `IsOffline == True`.
19. Only then tell the user it is safe to turn off the HDD physically.

Do not run the SMART Long/Extended Self-Test and heavy checksum reading at the same time.

## Checksum Behavior

Use SHA-256.

The main manifest must live outside the HDD being verified, for example:

```text
.\manifests\<SERIAL>\manifest.jsonl
```

or:

```text
%ProgramData%\HddIntegrity\manifests\<SERIAL>\manifest.jsonl
```

A copy on the HDD under `.hdd-integrity/` may exist only as redundancy.

On first run, explain that creating a baseline does not prove the files were already valid before that date, then ask for confirmation.

On later runs, classify file results as:

- `OK`
- `MODIFIED`
- `MISSING`
- `NEW`
- `ERROR`

Do not label a hash mismatch as corruption automatically. Use `CHECKSUM MISMATCH` and record objective facts.

## Reports And Logs

Persist human-readable and structured reports by serial, for example:

```text
reports/<SERIAL>/2026-08-13_093600.txt
reports/<SERIAL>/2026-08-13_093600.json
```

Log all important actions and decisions, including selected drive, physical disk identity, SMART mapping, health results, long test progress, filesystem findings, checksum summary, and offline attempts.

Overall result classification:

- `OK`
- `WARNING`
- `CRITICAL`
- `INCOMPLETE`

Use consistent exit codes as described in the specification.

## Offline/Online Handling

The offline step is separate from verification and must never happen automatically.

After verification completes:

1. Show the result first.
2. Ask whether to prepare the HDD for physical power-off.
3. If the user says no, leave the disk online and exit.
4. If the user says yes, show full drive/disk/model/serial identity.
5. Ask for a second confirmation.
6. Revalidate that the selected drive still maps to the same serial.
7. Set the physical disk offline.
8. Confirm Windows reports it offline.
9. Only then display the physical power-off message.

If `Set-Disk` fails, do not say the disk is safe to power off.

On a later run, if a known eligible disk is offline, the script may offer to bring it online only after explicit confirmation. Never bring disks online indiscriminately.

## Implementation Priorities

Follow the specification's recommended order:

1. Manual drive selection.
2. Safe physical disk resolution.
3. Safety blocks.
4. SMART identification by serial.
5. SMART reporting.
6. Separate safe offline action.
7. SHA-256 baseline.
8. Checksum comparison.
9. Read-only filesystem scan.
10. SMART Long/Extended Self-Test polling.
11. History and reports.
12. UX improvements.

The first functional delivery should prioritize correct HDD identity and safety over visual polish.

## Non-Goals For The First Version

Do not implement initially:

- GUI.
- Windows service.
- Background monitoring.
- Electrical control of physical buttons/power.
- RAID handling.
- Automatic backup synchronization.
- Automatic file repair.
- Automatic filesystem repair.
- Automatic file deletion.
- Automatic firmware updates.
- Simultaneous SMART operations across multiple HDDs.

## UX Guidance

CLI output should be clear and interactive.

Colors may be used only as a supplement. Never rely exclusively on color. Prefer textual status markers such as:

```text
[OK]
[WARNING]
[ERROR]
[SKIPPED]
```

Always show model and serial before any action that changes disk state.

