# collect-triage.sh

Diagnostic collection script for troubleshooting slow tape write performance on ScoutFS/ScoutAM systems. Captures memory, I/O, CPU, kernel, and ScoutFS-specific metrics over a configurable duration.

## Quick Start

```bash
# Basic 60-second collection
sudo ./collect-triage.sh

# 5-minute collection, skip SOS report for speed
sudo ./collect-triage.sh --duration 300 --no-sos

# With deep kernel tracing
sudo ./collect-triage.sh --trace --duration 120

# Auto-install missing utilities
sudo ./collect-triage.sh --install
```

## Requirements

- **OS:** RHEL/Rocky Linux (tested on RHEL 9)
- **Root:** Recommended. Some collectors (iotop, turbostat, sysrq, trace-cmd) require root.
- **Core utilities:** `vmstat`, `iostat`, `sar` (from `procps-ng` and `sysstat` packages)
- **Optional utilities:** `iotop`, `turbostat` (`kernel-tools`), `perf`, `trace-cmd`, `sos`, `curl`

## Options

| Option | Description |
|---|---|
| `--duration SECONDS` | Collection duration (default: 60). Tape ops may need 300-600s. |
| `--trace` | Enable trace-cmd for ScoutFS kernel events. Higher overhead. |
| `--output DIR` | Output directory (default: `tape-diag-YYYYMMDD-HHMMSS`) |
| `--scoutfs-mount PATH` | ScoutFS mount point (default: auto-detect from `/proc/mounts`) |
| `--install` | Auto-install missing utilities via `dnf` (requires root) |
| `--no-pprof` | Skip ScoutAM Go profiling |
| `--no-sos` | Skip SOS report collection (saves several minutes) |
| `--no-perf-top` | Skip perf top collection |
| `--profile-scheduler N` | Collect an N-second CPU profile from the ScoutAM scheduler pprof endpoint (only on the scheduler node) |

## What It Collects

### One-shot snapshots (start of run)

| File | Source |
|---|---|
| `meminfo-start.txt` / `meminfo-end.txt` | `/proc/meminfo` |
| `cpuinfo.txt` | `/proc/cpuinfo` |
| `vmstat-start.txt` / `vmstat-end.txt` | `/proc/vmstat` counters |
| `scoutfs-counters-start.txt` / `scoutfs-counters-end.txt` | ScoutFS debugfs counters |
| `debugfs-scoutfs.tar` | Full ScoutFS debugfs tree |
| `samcli.txt` | `samcli scheduler`, `samcli scheduler -d`, `samcli catalog`, `samcli catalog pool` |
| `fc-stats-start.txt` / `fc-stats-end.txt` | FC host statistics from `/sys/class/fc_host/` |
| `sys_block_settings.csv` | Block device queue settings (max_sectors_kb, nr_requests, scheduler, etc.) |
| `device-hierarchy.txt` | lsblk, mdadm, dmsetup, multipath topology |
| `ps-auxf.txt` / `top.txt` | Running processes |
| `process-info.txt` | scoutamd threads, I/O counters, status, file descriptors, ScoutFS statfs |
| `dmesg.log` | Kernel message buffer |
| `sysrq-t.log` / `sysrq-l.log` | Kernel stack traces (stopped/blocked and running tasks) |
| `scoutamd-threads/` | Kernel stacks, syscalls, memory maps, FDs for scoutamd threads |

### Continuous collectors (run for duration)

| File | Interval |
|---|---|
| `vmstat.log` | 1s |
| `iostat.log` | 1s (extended stats) |
| `sar-paging.log` | 1s |
| `iotop.log` | 1s (if available) |
| `turbostat.log` | 1s (if available) |
| `perf-top.log.gz` | 1s (if enabled) |
| `scoutfs-trace.gz` | Continuous (if `--trace`) |

### ScoutAM pprof (if responding on ports 6060-6062)

| File | When |
|---|---|
| `pprof/heap-PORT.txt` | Once at start |
| `pprof/block-PORT.txt` | Once at start |
| `pprof/mutex-PORT.txt` | Once at start |
| `pprof/goroutine-PORT-NNN.txt` | Every 10s |
| `pprof/scheduler.prof` | If `--profile-scheduler` (scheduler node only) |

### Computed deltas (end of run)

| File | Description |
|---|---|
| `vmstat-delta.txt` | Key page cache metrics (refaults, reclaim, faults, dirty, writeback) |
| `scoutfs-counters-delta.txt` | Non-zero ScoutFS counter changes |
| `fc-stats-delta.txt` | Non-zero FC host statistic changes |

### Optional

| File | Description |
|---|---|
| `sosreport-*.tar.xz` | Full SOS system report (skip with `--no-sos`) |

## Output

The script creates a timestamped directory and a corresponding `.tar.gz` tarball:

```
tape-diag-20260123-143022/
tape-diag-20260123-143022.tar.gz
```

Press `Ctrl+C` to stop collection early -- end snapshots and the tarball are still generated via the cleanup trap.

## Analysis Tips

- **Cache thrashing:** Check `vmstat-delta.txt` for high `workingset_refault_file` values.
- **Reclaim pressure:** Look at `pgscan_kswapd` / `pgsteal_kswapd` in the vmstat delta.
- **I/O bottlenecks:** Review `iostat.log` for high await/util on tape or backing devices.
- **FC issues:** `fc-stats-delta.txt` shows link failures, CRC errors, and credit stalls.
- **ScoutAM hangs:** Goroutine dumps in `pprof/` show where Go threads are blocked. Kernel stacks in `scoutamd-threads/stacks.txt` show where kernel threads are stuck.
- **Scheduler state:** `samcli.txt` shows current scheduler and catalog state at time of capture.
