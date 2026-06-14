# DriveMount

### How it works

- `config.ps1` holds shared settings, dot-sourced by every other script: `$RemoteName` (rclone
  remote, e.g. `MEGA:`), `$DriveLetter` (e.g. `M:`), `$LogFile`, `$RcAddress` (rclone's
  remote-control API, local-only), `$LogLevel`, and `$PidFile`.
- `mount_mega.ps1` checks that `rclone` is on `PATH`, that the WinFsp service is installed and
  running, and that the drive letter isn't already in use. It then starts `rclone mount` in the
  background (hidden window) with `--vfs-cache-mode minimal`, `--network-mode`, and an
  unauthenticated local RC endpoint (`--rc --rc-no-auth --rc-addr ...`) used later by
  `unmount_mega.ps1`. It polls for up to 15s for the drive to appear; on success it saves the
  rclone PID to `$PidFile`, on timeout it kills the process it started and exits non-zero.
- `unmount_mega.ps1` sends `core/quit` to rclone's RC API. If that exits non-zero (checked via
  `$LASTEXITCODE`, not try/catch — native exit codes don't throw in PowerShell), it falls back to
  `Stop-Process` using the PID saved in `$PidFile`. Either way it then polls for up to 10s for the
  drive to disappear and removes `$PidFile`.
- `status_mega.ps1` reports whether the drive letter is currently mounted and whether the rclone
  process recorded in `$PidFile` is still alive (handles missing/empty/stale PID files).

### Prerequisites

- `rclone` installed and on `PATH`, with a configured remote matching `$RemoteName` (run
  `rclone config` to set one up).
- [WinFsp](https://winfsp.dev) installed (provides the Windows filesystem driver rclone mounts
  through).

### RC API note

`--rc-no-auth` binds an unauthenticated control API to `127.0.0.1` only — any other rclone
command (or local process) can issue commands to it, but it's not reachable off-box.

### Running / testing

```powershell
.\mount_mega.ps1
.\status_mega.ps1
.\unmount_mega.ps1
```

To simulate the unmount fallback path, kill the rclone process directly (so the RC `core/quit`
call fails) and confirm `unmount_mega.ps1` still cleans up via the saved PID.
