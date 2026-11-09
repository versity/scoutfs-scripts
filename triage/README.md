# collect-triage.sh

Triage collection script for ScoutFS/ScoutAM systems. Captures the ScoutFS Triage Cookbook per-node data set (sysfs/debugfs trees, counters, fencing config, sysrq stack traces, scoutfs trace, sosreport, crashdump inventory) plus memory, I/O, CPU, kernel, and ScoutAM performance metrics over a configurable duration.

## Quick Start

```bash
# Basic 60-second collection
sudo ./collect-triage.sh

# 5-minute collection, skip SOS report for speed
sudo ./collect-triage.sh --duration 300 --no-sos

# Without the scoutfs trace (e.g. trace-cmd unavailable)
sudo ./collect-triage.sh --no-trace --duration 120

# Auto-install missing utilities
sudo ./collect-triage.sh --install
```

## Requirements

- **OS:** RHEL/Rocky Linux (tested on RHEL 9)
- **Root:** Recommended. Some collectors (debugfs tree, iotop, turbostat, sysrq, trace-cmd) require root.
- **Most important:** `trace-cmd` — captures the ScoutFS trace, the single most important triage artifact. Install `trace-cmd` before collecting if at all possible.
- **Disk space:** At least 4 GB free on local disk for the output directory (`/var/tmp` by default). The script refuses to start with less. See [Disk space](#disk-space) for how it keeps the capture from filling the disk.
- **Optional utilities:** `vmstat` (`procps-ng`), `iostat`/`sar` (`sysstat`), `iotop`, `turbostat` (`kernel-tools`), `perf`, `lsscsi`, `ethtool`, `sos`, `curl`. None are required — if missing, that collector is skipped and the rest of the triage data is still collected.

## Options

| Option | Description |
|---|---|
| `--duration SECONDS` | Collection duration (default: 60). Tape ops may need 300-600s. |
| `--trace` | Enable trace-cmd for ScoutFS kernel events (**default on**). |
| `--trace-max-mb N` | Cap the ScoutFS trace at N MB (default: 1/4 of free space, at most 4096). Once reached, the most recent events are kept. |
| `--no-trace` | Disable the ScoutFS trace (one of the most important triage artifacts; only skip if trace-cmd is unavailable). |
| `--output DIR` | Output directory; use local disk, not a ScoutFS mount (default: `/var/tmp/triage-HOSTNAME-YYYYMMDD-HHMMSS`) |
| `--scoutfs-mount PATH` | ScoutFS mount point (default: auto-detect from `/proc/mounts`) |
| `--install` | Auto-install missing utilities via `dnf` (requires root) |
| `--no-pprof` | Skip ScoutAM Go profiling |
| `--no-sos` | Skip SOS report collection (saves several minutes) |
| `--no-perf-top` | Skip perf CPU sampling (`perf-top.log.gz`) |
| `--profile-scheduler N` | Collect an N-second CPU profile from the ScoutAM scheduler pprof endpoint (only on the scheduler node) |

## What It Collects

### One-shot snapshots (start of run)

Kernel state is collected first, then fencing config, crashdumps, and the ScoutFS debugfs lock state, so the most important data is captured even if a later step hangs.

| File | Source |
|---|---|
| `meminfo-start.txt` / `meminfo-end.txt` | `/proc/meminfo` |
| `cpuinfo.txt` | `/proc/cpuinfo` |
| `vmstat-start.txt` / `vmstat-end.txt` | `/proc/vmstat` counters |
| `scoutfs-counters-start.txt` / `scoutfs-counters-end.txt` | ScoutFS counters (sysfs counters dir, or debugfs counters file on older builds) |
| `sysfs/` | Full ScoutFS sysfs tree (`/sys/fs/scoutfs`), read file-by-file |
| `debugfs/` | Full ScoutFS debugfs tree (`/sys/kernel/debug/scoutfs`), read file-by-file; lock state (`server_locks`, `client_locks`, `messages`, `connections`, `server_lock_stats`) first |
| `etc/scoutfs/` | Fencing configuration (incl. the `SCOUTFS_FENCED_RUN` file) |
| `versions.txt` | `uname -a`, `/etc/os-release`, `/proc/cmdline`, uptime, scoutfs module version (`/sys/module/scoutfs`, `modinfo`), `lsmod`, scout/kernel/trace-cmd packages |
| `journal/` | systemd journals (`-o short-precise`): each `scout*` unit for the last 24h, `scout*` units from the previous boot, kernel log for this and the previous boot, `systemctl status`, boot list. Previous-boot logs require a persistent journal. |
| `network-start.txt` / `network-end.txt` | `ss -tnpie` (TCP queues, retransmits), `ip -s -s link`, `ethtool -S` per NIC; `ip addr`, `ip route`, `ethtool` at start |
| `net-counters-start.txt` / `net-counters-end.txt` | TCP/IP counters from `/proc/net/snmp` and `/proc/net/netstat` |
| `time-sync.txt` | UTC time, `timedatectl`, `chronyc tracking` / `sources -v` (or `ntpq -p`) |
| `pressure-start.txt` / `pressure-end.txt` | PSI stall time for cpu, memory, io (`/proc/pressure/*`; RHEL kernels need `psi=1` on the kernel cmdline) |
| `buddyinfo-start.txt` / `buddyinfo-end.txt` | Free-page fragmentation (`/proc/buddyinfo`) |
| `slabinfo-start.txt` / `slabinfo-end.txt` | Kernel slab usage (`/proc/slabinfo`, root) |
| `sysctl.txt` | `sysctl -a` (incl. `vm.dirty_*`, `kernel.hung_task_*`) |
| `scsi-devices.txt` | `lsscsi -g` / `lsscsi -t` (or `/proc/scsi/scsi`) |
| `scsi-stats-start.txt` / `scsi-stats-end.txt` | Tape drive I/O stats (`/sys/class/scsi_tape/stN/stats`) and per-SCSI-device request/done/error/timeout counts |
| `crash_ls.txt` | Inventory of `/var/crash` crashdumps (`find /var/crash -ls`) |
| `samcli.txt` | `samcli scheduler`, `samcli scheduler -d`, `samcli catalog`, `samcli catalog pool` |
| `fc-stats-start.txt` / `fc-stats-end.txt` | FC host statistics from `/sys/class/fc_host/` |
| `sys_block_settings.csv` | Block device queue settings (max_sectors_kb, nr_requests, scheduler, etc.) |
| `device-hierarchy.txt` | lsblk, mdadm, dmsetup, multipath topology |
| `ps-auxf.txt` / `top.txt` | Running processes |
| `process-info.txt` | scoutamd threads, I/O counters, status, file descriptors |
| `scoutfs-statfs.txt` | `scoutfs statfs -p` for every scoutfs mount |
| `dmesg.log` | Kernel message buffer |
| `dstate-stacks.txt` | Kernel stacks of every task in D state, read from `/proc` (root) |
| `sysrq-w.log` | Kernel stack traces of blocked (D state) tasks |
| `sysrq-t.log` / `sysrq-l.log` | Kernel stack traces (all tasks, and running tasks per CPU) |
| `scoutamd-threads/` | Kernel stacks, syscalls, memory maps, FDs for scoutamd threads |

### Continuous collectors (run for duration)

| File | Interval |
|---|---|
| `vmstat.log` | 1s |
| `iostat.log` | 1s (extended stats) |
| `sar-paging.log` | 1s |
| `iotop.log` | 1s (if available) |
| `turbostat.log` | 1s (if available) |
| `hang-samples/tNNNN/` | Every 10s: debugfs `server_locks`, `client_locks`, `messages`, `connections`, `server_lock_stats` per filesystem, `dstate-stacks.txt`, `ss.txt` (`ss -tnpie`). `NNNN` is seconds into the run. |
| `perf-top.log.gz` | 5s `perf record` samples, top 50 symbols per sample (if enabled) |
| `scoutfs-trace.gz` | Continuous from start to end of the capture, capped by `--trace-max-mb` (unless `--no-trace`); trace-cmd output in `trace-cmd.log` |

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
| `net-counters-delta.txt` | Non-zero TCP/IP counter changes (retransmits, drops, resets) |
| `scsi-stats-delta.txt` | Non-zero tape and SCSI device counter changes |

### Optional

| File | Description |
|---|---|
| `sosreport-*.tar.xz` | Full SOS system report (skip with `--no-sos`) |
| `sos-output.txt` | Output of the `sos report` run |

### Collection log

| File | Description |
|---|---|
| `steps.log` | Start/end time, exit status, and duration of each collection step, plus free disk space. `rc=124` means the step was abandoned. |
| `hung-commands.txt` | Commands abandoned after their time limit (usually stuck in D state on a hung node). Only present if something hung. |

## Hung nodes

Every collection step runs with a time limit. A command stuck in uninterruptible (D) sleep can't be killed, so instead of waiting on it the script abandons it, logs it to `hung-commands.txt`, and moves on. The capture always finishes and produces a tarball; check `steps.log` to see which steps completed.

## Disk space

On a busy node the ScoutFS trace alone can write hundreds of MB per second (zib/20261109: 31 GB in about two minutes on a 96-CPU node), so the capture limits its own disk use:

- The trace is capped with trace-cmd's per-CPU `-m` limit at `--trace-max-mb` (default 1/4 of free space, at most 4 GB). Past the cap the oldest events are dropped, so the trace keeps the end of the capture.
- A background watchdog checks free space every 2s from the start of the run. If free space, less what trace-cmd needs to merge its per-CPU files, drops below 1 GB, it stops the trace early so the merge still fits.
- Once space is low, perf sampling, the continuous collectors, hang samples and the sosreport are stopped or skipped. `steps.log` records when and why.

## Output

The script creates a timestamped directory and a corresponding `.tar.gz` tarball:

```
/var/tmp/triage-HOSTNAME-20260123-143022/
/var/tmp/triage-HOSTNAME-20260123-143022.tar.gz
```

Press `Ctrl+C` to stop collection early -- end snapshots and the tarball are still generated via the cleanup trap.

## Analysis Tips

- **Cache thrashing:** Check `vmstat-delta.txt` for high `workingset_refault_file` values.
- **Reclaim pressure:** Look at `pgscan_kswapd` / `pgsteal_kswapd` in the vmstat delta.
- **I/O bottlenecks:** Review `iostat.log` for high await/util on tape or backing devices.
- **Fencing / quorum:** `journal/scoutfs-fenced*.log.gz` and the other `scout*` unit logs; `journal/*prev-boot*` if the node was fenced and rebooted.
- **Network:** `net-counters-delta.txt` for TCP retransmits; `ethtool -S` in `network-*.txt` for NIC drops and errors.
- **Cross-node timing:** check `time-sync.txt` on each node before lining up logs.
- **Tape errors:** `scsi-stats-delta.txt` for `ioerr_cnt` / `iotmo_cnt` changes.
- **FC issues:** `fc-stats-delta.txt` shows link failures, CRC errors, and credit stalls.
- **ScoutFS hangs:** Start with `dstate-stacks.txt` / `sysrq-w.log` for blocked tasks and the debugfs `server_locks` / `client_locks` files for lock state. Compare across `hang-samples/`: the same tasks waiting on the same locks in every sample is a deadlock; changing state is slow progress. A `Send-Q` in `hang-samples/*/ss.txt` that never drains points at the network. `steps.log` and `hung-commands.txt` show which collection steps blocked.
- **ScoutAM hangs:** Goroutine dumps in `pprof/` show where Go threads are blocked. Kernel stacks in `scoutamd-threads/stacks.txt` show where kernel threads are stuck.
- **Scheduler state:** `samcli.txt` shows current scheduler and catalog state at time of capture.
