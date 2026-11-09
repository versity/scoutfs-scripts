#!/bin/bash
#
# collect-triage.sh - ScoutFS/ScoutAM Triage Collection Script
#
# Collects the ScoutFS Triage Cookbook per-node data set (sysfs/debugfs
# trees, scoutfs counters, fencing config, sysrq stack traces, scoutfs
# trace, sosreport, crashdump inventory) plus memory, I/O, CPU, and
# ScoutAM metrics for diagnosing performance problems (e.g. slow tape writes).
#
# Usage: ./collect-triage.sh [--duration SECONDS] [--no-trace] [--output DIR] [--scoutfs-mount PATH] [--no-perf-top]
#

set -o pipefail

# Default values
DURATION=60
TRACE_ENABLED=true
OUTPUT_DIR=""
SCOUTFS_MOUNT=""
INSTALL_MISSING=false
PPROF_ENABLED=true
SOS_ENABLED=true
SCHEDULER_PROFILE_SECONDS=0
PERF_TOP_ENABLED=true

# PID tracking for background processes
declare -a BG_PIDS=()

# Run a command or shell function with a time limit and never block on it.
# `timeout` is not enough on a hung ScoutFS node: a process stuck in
# uninterruptible (D) sleep ignores SIGKILL, and timeout then waits on it
# forever.  Instead, poll the command; if it overruns, kill it and move on
# without waiting.  Abandoned commands are listed in hung-commands.txt.
bounded() {
    local secs="$1"; shift
    "$@" &
    local pid=$! ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if (( ticks >= secs * 20 )); then
            echo "WARNING: abandoned after ${secs}s (likely blocked in D state): $*" \
                | tee -a "$OUTPUT_DIR/hung-commands.txt" >&2
            pkill -9 -P "$pid" 2>/dev/null
            kill -9 "$pid" 2>/dev/null
            return 124
        fi
        sleep 0.05
        ticks=$((ticks + 1))
    done
    wait "$pid"
}

# Run one collection step under bounded() and record it in steps.log with
# start/end times and exit status (124 = abandoned), so a capture that stops
# early shows which step it stopped in.  zib/20261106: vers06's capture lost
# its debugfs and fencing config with nothing to say why.
step() {
    local name="$1" secs="$2"; shift 2
    local t0=$SECONDS rc
    echo "$(date '+%F %T') start $name" >> "$OUTPUT_DIR/steps.log"
    bounded "$secs" "$@"
    rc=$?
    echo "$(date '+%F %T') end   $name rc=$rc $((SECONDS - t0))s" >> "$OUTPUT_DIR/steps.log"
    return $rc
}

# Free space (MB) on the filesystem holding OUTPUT_DIR.
free_mb() {
    df -Pm "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2 {print $4}'
}

# Stop the open-ended collectors if the output filesystem runs low, so the
# capture finishes and the node's /var/tmp is not filled.
# The space watchdog (below) flags low space with .low-space; this acts on
# it, or on its own df check, once.
MIN_FREE_MB=1024
LOW_SPACE=false
check_space() {
    local free
    [[ "$LOW_SPACE" == true ]] && return 1
    free=$(free_mb)
    if [[ -e "$OUTPUT_DIR/.low-space" ]] || { [[ -n "$free" ]] && (( free < MIN_FREE_MB )); }; then
        LOW_SPACE=true
        echo "$(date '+%F %T') WARNING: low space (${free:-?} MB free) under $OUTPUT_DIR; stopping trace, perf, background collectors and hang samples" \
            | tee -a "$OUTPUT_DIR/steps.log" >&2
        stop_trace
        stop_perf_top
        HANG_SAMPLES_ENABLED=false
        local pid
        for pid in "${BG_PIDS[@]}"; do
            kill "$pid" 2>/dev/null
        done
        BG_PIDS=()
        return 1
    fi
}

# Background disk-space watchdog, started with the trace and running for the
# whole capture.  The main loop's check_space only starts after the start
# snapshots, which can take minutes; a busy node's scoutfs trace can fill
# the disk well before that (zib/20261109: vers06 wrote 31 GB of trace in
# about two minutes, and the merge into trace.dat then failed).
#
# Stops the trace while there is still room to merge it: trace-cmd copies
# its per-CPU files into trace.dat, so it needs about their size again.
# Flags .low-space for check_space to stop everything else.
WATCHDOG_PID=""
space_watchdog() {
    local trace_pid="$1" free trace_mb
    while [[ ! -e "$OUTPUT_DIR/.watchdog.stop" ]]; do
        free=$(free_mb)
        trace_mb=$(du -cm "$OUTPUT_DIR"/trace.dat.cpu* 2>/dev/null | awk 'END {print $1 + 0}')
        if [[ -n "$free" ]] && (( free - trace_mb < MIN_FREE_MB )); then
            echo "$(date '+%F %T') WARNING: ${free} MB free, ${trace_mb} MB of unmerged trace; stopping trace early" \
                | tee -a "$OUTPUT_DIR/steps.log" >&2
            touch "$OUTPUT_DIR/.low-space" "$OUTPUT_DIR/.perf-top.stop"
            [[ -n "$trace_pid" ]] && pkill -TERM -x sleep -P "$trace_pid" 2>/dev/null
            return
        fi
        sleep 2
    done
}

start_space_watchdog() {
    rm -f "$OUTPUT_DIR/.watchdog.stop" "$OUTPUT_DIR/.low-space"
    space_watchdog "$TRACE_CMD_PID" < /dev/null &
    WATCHDOG_PID=$!
}

stop_space_watchdog() {
    [[ -n "$WATCHDOG_PID" ]] || return 0
    touch "$OUTPUT_DIR/.watchdog.stop"
    kill "$WATCHDOG_PID" 2>/dev/null
    WATCHDOG_PID=""
}

# Cleanup function
cleanup() {
    echo ""
    echo "Stopping collectors..."
    for pid in "${BG_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
    done

    # Collect end snapshots if OUTPUT_DIR exists
    if [[ -n "$OUTPUT_DIR" && -d "$OUTPUT_DIR" ]]; then
        # Already stopped on a normal run; not after Ctrl-C.  The trace
        # runs until stopped, so it must be stopped here.
        stop_trace
        stop_perf_top

        collect_end_snapshots
        calculate_deltas

        # Collect SOS report (do last before tarball, can be slow)
        collect_sos_report

        stop_space_watchdog
        rm -f "$OUTPUT_DIR/.watchdog.stop" "$OUTPUT_DIR/.low-space" "$OUTPUT_DIR/.perf-top.stop"

        # Create tarball
        local parent_dir
        local dir_name
        parent_dir=$(dirname "$OUTPUT_DIR")
        dir_name=$(basename "$OUTPUT_DIR")

        echo "Creating tarball..."
        (cd "$parent_dir" && tar czf "${dir_name}.tar.gz" "$dir_name")

        echo ""
        echo "Data collected in: $OUTPUT_DIR"
        echo "Tarball created:   ${OUTPUT_DIR}.tar.gz"
    fi

    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Usage
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Collect ScoutFS/ScoutAM triage data (Cookbook per-node set) plus tape
performance diagnostics (page cache behavior and I/O path analysis).

OPTIONS:
    --duration SECONDS   Collection duration (default: 60)
                         Tape operations may need longer (300-600s)
    --trace              Enable trace-cmd for ScoutFS kernel events (default).
    --no-trace           Disable ScoutFS trace collection.
                         The scoutfs trace is one of the most important parts
                         of the triage data; only disable it if trace-cmd is
                         unavailable or the overhead is a concern.
    --trace-max-mb N     Cap the scoutfs trace at N MB (default: 1/4 of free
                         space, at most 4096).  The most recent events are
                         kept once the cap is reached.
    --output DIR         Output directory on local disk, needs 4 GB free
                         (default: /var/tmp/triage-HOSTNAME-YYYYMMDD-HHMMSS)
    --scoutfs-mount PATH ScoutFS mount point (default: auto-detect)
    --install            Auto-install missing utilities via dnf (requires root)
    --no-pprof           Skip ScoutAM Go profiling (enabled by default)
    --no-sos             Skip SOS report collection (enabled by default)
    --no-perf-top        Skip perf CPU sampling (enabled by default)
    --profile-scheduler N   Collect a ${N}s CPU profile from the ScoutAM scheduler
                            pprof endpoint (only runs on the scheduler node,
                            detected via port 8888 listening)
    -h, --help           Show this help message

EXAMPLES:
    $(basename "$0")                           # 60 second collection
    $(basename "$0") --duration 300            # 5 minute collection
    $(basename "$0") --no-trace --duration 120 # 2 min without scoutfs trace
    $(basename "$0") --scoutfs-mount /mnt/scoutfs
    $(basename "$0") --install                 # Auto-install missing utilities
    $(basename "$0") --no-pprof                # Skip ScoutAM profiling
    $(basename "$0") --no-sos                  # Skip SOS report (faster)

OUTPUT:
    Creates a timestamped directory containing:
    - sysfs/ (entire /sys/fs/scoutfs tree, read file-by-file)
    - debugfs/ (entire /sys/kernel/debug/scoutfs tree, read file-by-file;
      lock state first: server_locks, client_locks, messages, connections)
    - steps.log (start/end time and exit status of each collection step;
      rc=124 means the step was abandoned, see hung-commands.txt)
    - hang-samples/tNNNN/ (every 10s: debugfs lock/message state, D-state
      stacks, ss -tnpie; to tell a deadlock from slow progress)
    - versions.txt (kernel, scoutfs module, packages, cmdline)
    - journal/ (systemd journals for scout* units and the kernel, this and
      the previous boot)
    - network-start/end.txt, net-counters-start/end/delta.txt (ss, ip,
      ethtool, TCP/IP counters)
    - time-sync.txt (timedatectl, chronyc)
    - pressure-, buddyinfo-, slabinfo-start/end.txt; sysctl.txt
    - scsi-devices.txt, scsi-stats-start/end/delta.txt (tape and SCSI
      device I/O and error counters)
    - etc/scoutfs/ (fencing configuration, incl. SCOUTFS_FENCED_RUN)
    - crash_ls.txt (inventory of /var/crash crashdumps)
    - vmstat.log, iostat.log, iotop.log, sar-paging.log, turbostat.log
    - meminfo/vmstat snapshots (start/end/delta)
    - scoutfs counters (start/end/delta)
    - fc-stats-start.txt, fc-stats-end.txt, fc-stats-delta.txt (FC host stats)
    - sys_block_settings.csv (block device queue settings)
    - device-hierarchy.txt (MDRAID, DM, multipath topology)
    - ps-auxf.txt, top.txt (running processes)
    - dmesg.log, sysrq-w.log, sysrq-t.log, sysrq-l.log (kernel logs and stack traces)
    - dstate-stacks.txt (kernel stacks of D-state tasks, from /proc)
    - process-info.txt (scoutamd state)
    - scoutfs-statfs.txt (scoutfs statfs for every scoutfs mount)
    - pprof/ (goroutine dumps every 10s; heap, block, mutex once at start)
    - scoutamd-threads/ (kernel stacks, syscalls, memory maps)
    - scoutfs-trace.gz (unless --no-trace), trace-cmd.log
    - perf-top.log.gz (perf record/report CPU samples every 5s for duration)
    - cpuinfo.txt (/proc/cpuinfo snapshot)
    - samcli.txt (ScoutAM scheduler and catalog state)
    - sosreport-*.tar.xz (system diagnostic report, if sos is installed)
EOF
    exit 0
}

# Install missing packages via dnf
install_missing_packages() {
    local packages=("$@")
    if [[ ${#packages[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: --install requires root privileges"
        return 1
    fi

    echo "Installing missing packages: ${packages[*]}"
    if ! dnf install -y "${packages[@]}"; then
        echo "ERROR: Failed to install packages"
        return 1
    fi
    return 0
}

# Map a missing command to its RHEL/Rocky package name.
util_package() {
    case "$1" in
        vmstat)      echo "procps-ng" ;;
        iostat|sar)  echo "sysstat" ;;
        iotop)       echo "iotop" ;;
        turbostat)   echo "kernel-tools" ;;
        perf)        echo "perf" ;;
        lsscsi)      echo "lsscsi" ;;
        ethtool)     echo "ethtool" ;;
        trace-cmd)   echo "trace-cmd" ;;
    esac
}

# Scan for missing utilities, populating the missing_optional/missing_trace
# arrays in the caller's scope.
scan_missing_utils() {
    missing_optional=()
    missing_trace=()

    # Performance collectors are optional: a missing one only disables that
    # single collector, it never blocks ScoutFS triage data collection.
    for cmd in vmstat iostat sar iotop turbostat lsscsi ethtool; do
        command -v "$cmd" >/dev/null 2>&1 || missing_optional+=("$cmd")
    done
    if [[ "$PERF_TOP_ENABLED" == true ]]; then
        command -v perf >/dev/null 2>&1 || missing_optional+=("perf")
    fi

    # trace-cmd captures the ScoutFS trace, the single most important piece of
    # ScoutFS triage data, so it is tracked and warned about separately.
    if [[ "$TRACE_ENABLED" == true ]]; then
        command -v trace-cmd >/dev/null 2>&1 || missing_trace+=("trace-cmd")
    fi
}

# Check for utilities.  Nothing here is fatal: the script always collects the
# core ScoutFS triage data (sysfs/debugfs trees, fencing config, sysrq stack
# traces, scoutfs trace, sosreport) regardless of which perf tools are present.
check_utilities() {
    local missing_optional=() missing_trace=()
    scan_missing_utils

    # Auto-install missing utilities if requested
    if [[ "$INSTALL_MISSING" == true && ( ${#missing_optional[@]} -gt 0 || ${#missing_trace[@]} -gt 0 ) ]]; then
        local packages_to_install=() u
        for u in "${missing_optional[@]}" "${missing_trace[@]}"; do
            packages_to_install+=("$(util_package "$u")")
        done
        local unique_packages
        unique_packages=($(printf '%s\n' "${packages_to_install[@]}" | sort -u))
        if install_missing_packages "${unique_packages[@]}"; then
            scan_missing_utils
        fi
    fi

    # Warn about missing optional performance collectors
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        echo "WARNING: Missing optional utilities: ${missing_optional[*]}"
        echo "  vmstat: dnf install procps-ng"
        echo "  iostat, sar: dnf install sysstat"
        echo "  iotop: dnf install iotop"
        echo "  turbostat: dnf install kernel-tools"
        echo "  perf: dnf install perf"
        echo "  lsscsi: dnf install lsscsi"
        echo "  ethtool: dnf install ethtool"
        echo "These collectors will be skipped; ScoutFS triage data is still collected."
        echo ""

        # Record missing utilities
        printf '%s\n' "${missing_optional[@]}" > "$OUTPUT_DIR/missing-utils.txt"
    fi

    # Loudly warn about missing trace-cmd - the most important triage artifact
    if [[ ${#missing_trace[@]} -gt 0 ]]; then
        echo "*****************************************************************"
        echo "* trace-cmd is not installed.  The scoutfs trace it captures   *"
        echo "* is one of the most important parts of the triage data.       *"
        echo "* Install it with 'dnf install -y trace-cmd' (or re-run with   *"
        echo "* --install) and collect again if at all possible.             *"
        echo "*****************************************************************"
        echo ""

        # Append to missing utilities file
        printf '%s\n' "${missing_trace[@]}" >> "$OUTPUT_DIR/missing-utils.txt"
    fi
}

# Auto-detect ScoutFS mount point
detect_scoutfs_mount() {
    if [[ -n "$SCOUTFS_MOUNT" ]]; then
        if [[ ! -d "$SCOUTFS_MOUNT" ]]; then
            echo "ERROR: ScoutFS mount point does not exist: $SCOUTFS_MOUNT"
            exit 1
        fi
        return
    fi

    # Try to find ScoutFS mount from /proc/mounts
    SCOUTFS_MOUNT=$(awk '$3 == "scoutfs" {print $2; exit}' /proc/mounts 2>/dev/null)

    if [[ -z "$SCOUTFS_MOUNT" ]]; then
        echo "WARNING: No ScoutFS mount detected. ScoutFS metrics will be skipped."
    else
        echo "Detected ScoutFS mount: $SCOUTFS_MOUNT"
    fi
}

# Get ScoutFS debug path
get_scoutfs_debug_path() {
    if [[ -z "$SCOUTFS_MOUNT" ]]; then
        return 1
    fi

    # Find the scoutfs debug directory
    local debug_base="/sys/kernel/debug/scoutfs"
    if [[ -d "$debug_base" ]]; then
        # Get the first (or matching) scoutfs instance
        local debug_path
        debug_path=$(find "$debug_base" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
        if [[ -n "$debug_path" && -d "$debug_path" ]]; then
            echo "$debug_path"
            return 0
        fi
    fi
    return 1
}

collect_samcli() {
    if ! command -v samcli >/dev/null 2>&1; then
        echo "WARNING: samcli not found, skipping ScoutAM CLI collection"
        return
    fi

    local output_file="$OUTPUT_DIR/samcli.txt"
    echo "Collecting ScoutAM CLI data..."

    echo "=== samcli scheduler ===" > "$output_file"
    samcli scheduler >> "$output_file" 2>&1
    echo "" >> "$output_file"

    echo "=== samcli scheduler -d ===" >> "$output_file"
    samcli scheduler -d >> "$output_file" 2>&1
    echo "" >> "$output_file"

    echo "=== samcli catalog ===" >> "$output_file"
    samcli catalog >> "$output_file" 2>&1
    echo "" >> "$output_file"

    echo "=== samcli catalog pool ===" >> "$output_file"
    samcli catalog pool >> "$output_file" 2>&1
}

# Collect start snapshots
collect_start_snapshots() {
    echo "Collecting start snapshots..."

    # Kernel logs and stack traces first: on a hung node these are the most
    # important data and nothing below may get to run.
    step "kernel state" 600 collect_kernel_state

    # Memory info
    cat /proc/meminfo > "$OUTPUT_DIR/meminfo-start.txt" 2>&1

    # CPU info
    cat /proc/cpuinfo > "$OUTPUT_DIR/cpuinfo.txt" 2>&1

    # vmstat counters
    cat /proc/vmstat > "$OUTPUT_DIR/vmstat-start.txt" 2>&1

    # Fencing configuration and crashdump inventory: plain files under /etc
    # and /var, so they cannot hang; taken before anything that can.
    step "fencing config" 30 collect_fencing_config
    step "crashdumps" 30 collect_crashdumps
    step "versions" 60 collect_versions > "$OUTPUT_DIR/versions.txt" 2>&1

    # ScoutFS counters (sysfs dir or debugfs file)
    step "scoutfs counters" 30 snapshot_scoutfs_counters "$OUTPUT_DIR/scoutfs-counters-start.txt"

    # ScoutFS debugfs (lock state) and sysfs trees
    collect_scoutfs_trees

    # systemd journals (fencing, quorum, scoutamd)
    step "journals" 180 collect_journals

    # Network, clock sync, memory pressure, SCSI/tape
    step "network" 60 collect_network start > "$OUTPUT_DIR/network-start.txt" 2>&1
    step "net counters" 10 snapshot_net_counters > "$OUTPUT_DIR/net-counters-start.txt"
    step "time sync" 40 collect_time_sync > "$OUTPUT_DIR/time-sync.txt" 2>&1
    step "pressure" 30 collect_pressure start
    step "sysctl" 30 sysctl -a > "$OUTPUT_DIR/sysctl.txt" 2>&1
    step "scsi inventory" 30 collect_scsi_inventory > "$OUTPUT_DIR/scsi-devices.txt" 2>&1
    step "scsi stats" 30 snapshot_scsi_stats > "$OUTPUT_DIR/scsi-stats-start.txt"

    # ScoutAM CLI
    step "samcli" 120 collect_samcli

    # FC host statistics
    step "fc stats" 30 collect_fc_stats "$OUTPUT_DIR/fc-stats-start.txt"

    # Process info
    step "process info" 60 collect_process_info > "$OUTPUT_DIR/process-info.txt" 2>&1

    # ScoutFS statfs
    # (-p PATH; -s takes a field name, and "statfs -s <mount>" only printed
    # "unknown field").  Every scoutfs mount, each bounded: on a hung node
    # one filesystem's statfs can block.
    if command -v scoutfs >/dev/null 2>&1; then
        local mnt
        for mnt in $(awk '$3 == "scoutfs" {print $2}' /proc/mounts 2>/dev/null); do
            echo "--- scoutfs statfs -p $mnt ---" >> "$OUTPUT_DIR/scoutfs-statfs.txt"
            step "scoutfs statfs $mnt" 30 scoutfs statfs -p "$mnt" >> "$OUTPUT_DIR/scoutfs-statfs.txt" 2>&1
        done
    fi

    # Thread diagnostics (always collected at start)
    step "thread diagnostics" 60 collect_thread_diagnostics

    # Block device queue settings
    step "block settings" 60 collect_block_settings

    # Device hierarchy (MDRAID, DM, multipath)
    step "device hierarchy" 120 collect_device_hierarchy

    # System-wide process listing
    step "processes" 60 collect_processes
}

# Collect end snapshots
collect_end_snapshots() {
    echo "Collecting end snapshots..."

    # Memory info
    cat /proc/meminfo > "$OUTPUT_DIR/meminfo-end.txt" 2>&1

    # vmstat counters
    cat /proc/vmstat > "$OUTPUT_DIR/vmstat-end.txt" 2>&1

    # ScoutFS counters (sysfs dir or debugfs file)
    step "scoutfs counters (end)" 30 snapshot_scoutfs_counters "$OUTPUT_DIR/scoutfs-counters-end.txt"

    # FC host statistics
    step "fc stats (end)" 30 collect_fc_stats "$OUTPUT_DIR/fc-stats-end.txt"

    # Network, memory pressure, SCSI/tape
    step "network (end)" 60 collect_network end > "$OUTPUT_DIR/network-end.txt" 2>&1
    step "net counters (end)" 10 snapshot_net_counters > "$OUTPUT_DIR/net-counters-end.txt"
    step "pressure (end)" 30 collect_pressure end
    step "scsi stats (end)" 30 snapshot_scsi_stats > "$OUTPUT_DIR/scsi-stats-end.txt"
}

# Calculate deltas for cumulative counters
calculate_deltas() {
    echo "Calculating deltas..."

    # vmstat delta - key metrics
    if [[ -f "$OUTPUT_DIR/vmstat-start.txt" && -f "$OUTPUT_DIR/vmstat-end.txt" ]]; then
        calculate_vmstat_delta > "$OUTPUT_DIR/vmstat-delta.txt"
    fi

    # ScoutFS counters delta
    if [[ -f "$OUTPUT_DIR/scoutfs-counters-start.txt" && -f "$OUTPUT_DIR/scoutfs-counters-end.txt" ]]; then
        calculate_counter_delta \
            "$OUTPUT_DIR/scoutfs-counters-start.txt" \
            "$OUTPUT_DIR/scoutfs-counters-end.txt" \
            > "$OUTPUT_DIR/scoutfs-counters-delta.txt"
    fi

    # FC host statistics delta
    if [[ -f "$OUTPUT_DIR/fc-stats-start.txt" && -f "$OUTPUT_DIR/fc-stats-end.txt" ]]; then
        calculate_fc_delta \
            "$OUTPUT_DIR/fc-stats-start.txt" \
            "$OUTPUT_DIR/fc-stats-end.txt" \
            "$OUTPUT_DIR/fc-stats-delta.txt"
    fi

    # TCP/IP counters delta (retransmits, drops, resets)
    if [[ -s "$OUTPUT_DIR/net-counters-start.txt" && -s "$OUTPUT_DIR/net-counters-end.txt" ]]; then
        calculate_counter_delta \
            "$OUTPUT_DIR/net-counters-start.txt" \
            "$OUTPUT_DIR/net-counters-end.txt" \
            > "$OUTPUT_DIR/net-counters-delta.txt"
    fi

    # Tape and SCSI device counters delta
    if [[ -s "$OUTPUT_DIR/scsi-stats-start.txt" && -s "$OUTPUT_DIR/scsi-stats-end.txt" ]]; then
        calculate_counter_delta \
            "$OUTPUT_DIR/scsi-stats-start.txt" \
            "$OUTPUT_DIR/scsi-stats-end.txt" \
            > "$OUTPUT_DIR/scsi-stats-delta.txt"
    fi
}

# Calculate vmstat delta for key metrics
calculate_vmstat_delta() {
    local key_metrics=(
        "workingset_refault_file"
        "workingset_refault_anon"
        "pgscan_kswapd"
        "pgsteal_kswapd"
        "pgscan_direct"
        "pgsteal_direct"
        "pgfault"
        "pgmajfault"
        "pgpgin"
        "pgpgout"
        "pswpin"
        "pswpout"
        "nr_dirty"
        "nr_writeback"
    )

    echo "# vmstat delta (end - start)"
    echo "# Key metrics for page cache analysis"
    echo "#"
    echo "# workingset_refault_file - cache thrashing indicator"
    echo "# pgscan_kswapd/pgsteal_kswapd - reclaim pressure"
    echo "# pgmajfault - major faults (disk reads)"
    echo "#"

    for metric in "${key_metrics[@]}"; do
        local start_val end_val delta
        start_val=$(grep "^${metric} " "$OUTPUT_DIR/vmstat-start.txt" 2>/dev/null | awk '{print $2}')
        end_val=$(grep "^${metric} " "$OUTPUT_DIR/vmstat-end.txt" 2>/dev/null | awk '{print $2}')

        if [[ -n "$start_val" && -n "$end_val" ]]; then
            delta=$((end_val - start_val))
            printf "%-30s %15d\n" "$metric" "$delta"
        fi
    done
}

# Generic counter delta calculation
calculate_counter_delta() {
    local start_file="$1"
    local end_file="$2"

    echo "# Counter delta (end - start)"
    echo "#"

    while IFS=' ' read -r name start_val; do
        local end_val
        end_val=$(grep "^${name} " "$end_file" 2>/dev/null | awk '{print $2}')

        if [[ -n "$end_val" ]]; then
            local delta=$((end_val - start_val))
            if [[ $delta -ne 0 ]]; then
                printf "%-40s %15d\n" "$name" "$delta"
            fi
        fi
    done < "$start_file"
}

# Collect FC host statistics
collect_fc_stats() {
    local output_file="$1"
    echo "# FC Host Statistics - $(date)" > "$output_file"
    echo "#" >> "$output_file"

    local found_fc=false
    for host_dir in /sys/class/fc_host/host*; do
        [[ -d "$host_dir/statistics" ]] || continue
        found_fc=true
        local host
        host=$(basename "$host_dir")
        echo "=== $host ===" >> "$output_file"

        for stat_file in "$host_dir/statistics"/*; do
            [[ -r "$stat_file" ]] || continue
            local stat_name
            stat_name=$(basename "$stat_file")
            local value
            value=$(cat "$stat_file" 2>/dev/null)
            printf "%-40s %s\n" "$stat_name" "$value" >> "$output_file"
        done
        echo "" >> "$output_file"
    done

    if [[ "$found_fc" == false ]]; then
        echo "# No FC hosts found in /sys/class/fc_host/" >> "$output_file"
    fi
}

# Calculate FC stats delta
calculate_fc_delta() {
    local start_file="$1"
    local end_file="$2"
    local output_file="$3"

    echo "# FC Host Statistics Delta (end - start)" > "$output_file"
    echo "# Key metrics for tape performance:" >> "$output_file"
    echo "#   error_frames, invalid_crc_count - data integrity issues" >> "$output_file"
    echo "#   link_failure_count, loss_of_signal/sync_count - connection stability" >> "$output_file"
    echo "#   fcp_input/output_megabytes - throughput" >> "$output_file"
    echo "#   fcp_packet_aborts, fcp_frame_alloc_failures - resource issues" >> "$output_file"
    echo "#   fpin_cn_credit_stall - flow control stalls (performance killer)" >> "$output_file"
    echo "#" >> "$output_file"

    local current_host=""

    while IFS= read -r line; do
        # Check for host header
        if [[ "$line" =~ ^===\ (host[0-9]+)\ === ]]; then
            current_host="${BASH_REMATCH[1]}"
            echo "" >> "$output_file"
            echo "=== $current_host ===" >> "$output_file"
            continue
        fi

        # Skip comments and empty lines
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue

        # Parse stat line: stat_name value
        local stat_name start_val
        stat_name=$(echo "$line" | awk '{print $1}')
        start_val=$(echo "$line" | awk '{print $2}')

        [[ -z "$stat_name" || -z "$start_val" ]] && continue

        # Find matching end value for this host and stat
        local end_val
        end_val=$(awk -v host="$current_host" -v stat="$stat_name" '
            /^=== / { current_host = $2 }
            current_host == host && $1 == stat { print $2 }
        ' "$end_file")

        if [[ -n "$end_val" && "$start_val" =~ ^-?[0-9]+$ && "$end_val" =~ ^-?[0-9]+$ ]]; then
            local delta=$((end_val - start_val))
            if [[ $delta -ne 0 ]]; then
                printf "%-40s %15d\n" "$stat_name" "$delta" >> "$output_file"
            fi
        fi
    done < "$start_file"
}

# Collect device hierarchy (MDRAID, DM, block devices)
collect_device_hierarchy() {
    local output_file="$OUTPUT_DIR/device-hierarchy.txt"

    echo "# Device Hierarchy - $(date)" > "$output_file"
    echo "#" >> "$output_file"

    # lsblk tree view (most comprehensive)
    echo "=== lsblk tree ===" >> "$output_file"
    lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,MAJ:MIN 2>/dev/null >> "$output_file" || echo "lsblk not available" >> "$output_file"
    echo "" >> "$output_file"

    # lsblk inverse tree (show what each device is built from)
    echo "=== lsblk inverse tree (slaves) ===" >> "$output_file"
    lsblk -s -o NAME,TYPE,SIZE,MAJ:MIN 2>/dev/null >> "$output_file" || echo "lsblk -s not available" >> "$output_file"
    echo "" >> "$output_file"

    # MDRAID status
    echo "=== /proc/mdstat ===" >> "$output_file"
    if [[ -f /proc/mdstat ]]; then
        cat /proc/mdstat >> "$output_file"
    else
        echo "No /proc/mdstat (no MDRAID)" >> "$output_file"
    fi
    echo "" >> "$output_file"

    # MDRAID detail for each md device
    if command -v mdadm >/dev/null 2>&1; then
        echo "=== mdadm detail ===" >> "$output_file"
        for md in /dev/md*; do
            [[ -b "$md" ]] || continue
            echo "--- $md ---" >> "$output_file"
            mdadm --detail "$md" 2>/dev/null >> "$output_file" || echo "Unable to query $md" >> "$output_file"
            echo "" >> "$output_file"
        done
    fi

    # Device mapper table (shows DM topology)
    if command -v dmsetup >/dev/null 2>&1; then
        echo "=== dmsetup ls --tree ===" >> "$output_file"
        dmsetup ls --tree 2>/dev/null >> "$output_file" || echo "dmsetup tree not available" >> "$output_file"
        echo "" >> "$output_file"

        echo "=== dmsetup table ===" >> "$output_file"
        dmsetup table 2>/dev/null >> "$output_file" || echo "dmsetup table not available" >> "$output_file"
        echo "" >> "$output_file"
    fi

    # Multipath info if available
    if command -v multipath >/dev/null 2>&1; then
        echo "=== multipath -ll ===" >> "$output_file"
        multipath -ll 2>/dev/null >> "$output_file" || echo "multipath not available" >> "$output_file"
        echo "" >> "$output_file"
    fi
}

# Collect block device queue settings
collect_block_settings() {
    local output_file="$OUTPUT_DIR/sys_block_settings.csv"

    echo "device,max_sectors_kb,nr_requests,read_ahead_kb,scheduler,rotational" > "$output_file"

    for dev_path in /sys/block/*; do
        [[ -d "$dev_path/queue" ]] || continue
        local dev
        dev=$(basename "$dev_path")

        local max_sectors_kb nr_requests read_ahead_kb scheduler rotational

        max_sectors_kb=$(cat "$dev_path/queue/max_sectors_kb" 2>/dev/null || echo "")
        nr_requests=$(cat "$dev_path/queue/nr_requests" 2>/dev/null || echo "")
        read_ahead_kb=$(cat "$dev_path/queue/read_ahead_kb" 2>/dev/null || echo "")
        # scheduler file shows available schedulers with current one in brackets, e.g. "mq-deadline [none]"
        scheduler=$(cat "$dev_path/queue/scheduler" 2>/dev/null | grep -o '\[.*\]' | tr -d '[]' || echo "")
        rotational=$(cat "$dev_path/queue/rotational" 2>/dev/null || echo "")

        echo "$dev,$max_sectors_kb,$nr_requests,$read_ahead_kb,$scheduler,$rotational" >> "$output_file"
    done
}

# Collect system-wide process listing
collect_processes() {
    echo "Collecting process listings..."

    # Full process tree with resource usage
    ps auxf > "$OUTPUT_DIR/ps-auxf.txt" 2>&1

    # Top snapshot (sorted by CPU, then memory)
    top -b -n 1 > "$OUTPUT_DIR/top.txt" 2>&1
}

# Collect kernel logs and stack traces
collect_kernel_state() {
    echo "Collecting kernel state (dmesg, sysrq)..."

    # Capture dmesg before sysrq triggers
    dmesg -T > "$OUTPUT_DIR/dmesg.log" 2>&1

    # sysrq triggers require root - dump kernel stacks to dmesg
    if [[ $EUID -eq 0 ]]; then
        # Kernel stacks of every D-state task, read straight from /proc so
        # they cannot be lost to a wrapped dmesg ring buffer.
        bounded 120 collect_dstate_stacks > "$OUTPUT_DIR/dstate-stacks.txt" 2>&1

        # Clear dmesg to isolate sysrq output
        dmesg --clear 2>/dev/null

        # Stack traces for blocked (D state) tasks only - small enough not
        # to wrap the ring buffer, so capture it before the full 't' dump.
        echo w > /proc/sysrq-trigger 2>/dev/null
        sleep 1
        dmesg -T > "$OUTPUT_DIR/sysrq-w.log" 2>&1
        dmesg --clear 2>/dev/null

        # Stack traces for all tasks
        echo t > /proc/sysrq-trigger 2>/dev/null
        sleep 1
        dmesg -T > "$OUTPUT_DIR/sysrq-t.log" 2>&1

        # Clear again
        dmesg --clear 2>/dev/null

        # Stack traces for all running tasks
        echo l > /proc/sysrq-trigger 2>/dev/null
        sleep 1
        dmesg -T > "$OUTPUT_DIR/sysrq-l.log" 2>&1
    else
        echo "# Skipped - requires root" > "$OUTPUT_DIR/sysrq-t.log"
        echo "# Skipped - requires root" > "$OUTPUT_DIR/sysrq-l.log"
    fi
}

# Print the kernel stack of every task in uninterruptible (D) sleep.
# Uses the read builtin (no fork per task) and touches only /proc.
collect_dstate_stacks() {
    echo "# Kernel stacks of tasks in D state - $(date)"
    local stat st tdir comm wchan
    for stat in /proc/[0-9]*/task/[0-9]*/stat; do
        # Tasks exit mid-scan: the braces make 2>/dev/null cover the
        # failed < redirection as well as read itself.
        { read -r st < "$stat"; } 2>/dev/null || continue
        st=${st##*) }
        [[ "${st%% *}" == D ]] || continue
        tdir=${stat%/stat}
        comm=""; wchan=""
        { read -r comm < "$tdir/comm"; } 2>/dev/null
        { read -r wchan < "$tdir/wchan"; } 2>/dev/null
        echo "=== ${tdir#/proc/} comm=$comm wchan=$wchan ==="
        cat "$tdir/stack" 2>/dev/null
        echo ""
    done
}

# Collect process info
collect_process_info() {
    echo "=== scoutamd Process Info ==="
    echo ""

    echo "--- Thread listing (ps -eLf) ---"
    ps -eLf 2>/dev/null | grep -E "(UID|scoutamd)" | grep -v grep
    echo ""

    # Get scoutamd PID
    local scoutamd_pid
    scoutamd_pid=$(pgrep -x scoutamd 2>/dev/null | head -1)

    if [[ -n "$scoutamd_pid" ]]; then
        echo "--- scoutamd I/O counters (/proc/$scoutamd_pid/io) ---"
        cat "/proc/$scoutamd_pid/io" 2>/dev/null || echo "Unable to read"
        echo ""

        echo "--- scoutamd status (/proc/$scoutamd_pid/status) ---"
        cat "/proc/$scoutamd_pid/status" 2>/dev/null || echo "Unable to read"
        echo ""

        echo "--- scoutamd file descriptors ---"
        ls -la "/proc/$scoutamd_pid/fd" 2>/dev/null | head -50 || echo "Unable to read"
    else
        echo "scoutamd process not found"
    fi
}

# Start background collectors
start_collectors() {
    [[ "$LOW_SPACE" == true ]] && return 0
    echo "Starting background collectors for ${DURATION}s..."

    # vmstat - 1 second interval
    if command -v vmstat >/dev/null 2>&1; then
        vmstat 1 > "$OUTPUT_DIR/vmstat.log" 2>&1 &
        BG_PIDS+=($!)
    fi

    # iostat - 1 second interval, extended stats, all devices
    if command -v iostat >/dev/null 2>&1; then
        iostat -x 1 > "$OUTPUT_DIR/iostat.log" 2>&1 &
        BG_PIDS+=($!)
    fi

    # sar - paging stats, 1 second interval
    if command -v sar >/dev/null 2>&1; then
        sar -B 1 "$DURATION" > "$OUTPUT_DIR/sar-paging.log" 2>&1 &
        BG_PIDS+=($!)
    fi

    # iotop - optional
    if command -v iotop >/dev/null 2>&1; then
        iotop -b -o -d 1 > "$OUTPUT_DIR/iotop.log" 2>&1 &
        BG_PIDS+=($!)
    fi

    # turbostat - optional
    if command -v turbostat >/dev/null 2>&1; then
        turbostat -i 1 > "$OUTPUT_DIR/turbostat.log" 2>&1 &
        BG_PIDS+=($!)
    fi
}

# PID for trace-cmd (tracked separately for graceful shutdown)
TRACE_CMD_PID=""

# Total size cap for the scoutfs trace, in MB (--trace-max-mb).  Default:
# a quarter of the free space at start, at most 4096.  trace-cmd's -m cap is
# per CPU and keeps the most recent events once reached, so on a busy node
# the trace covers the end of the run.
TRACE_MAX_MB=""

trace_cpu_kb() {
    local ncpu kb
    ncpu=$(getconf _NPROCESSORS_CONF 2>/dev/null || nproc)
    kb=$(( TRACE_MAX_MB * 1024 / ${ncpu:-1} ))
    (( kb < 1024 )) && kb=1024
    echo "$kb"
}

# Start trace collection
start_trace() {
    if [[ "$TRACE_ENABLED" != true ]]; then
        return
    fi

    echo "Starting trace collection..."

    # trace-cmd for ScoutFS events.  It records until the sleep it runs
    # exits; stop_trace ends it early by killing the sleep, so the trace
    # covers the whole capture however long the start snapshots take.  The
    # sleep is only a backstop if the script dies without stopping it.
    if command -v trace-cmd >/dev/null 2>&1; then
        local cpu_kb
        cpu_kb=$(trace_cpu_kb)
        (
            cd "$OUTPUT_DIR" || exit 1
            exec trace-cmd record -m "$cpu_kb" -e "scoutfs:*" sleep $((DURATION + 3600))
        ) < /dev/null > "$OUTPUT_DIR/trace-cmd.log" 2>&1 &
        TRACE_CMD_PID=$!
        echo "$(date '+%F %T') trace-cmd started: cap ${TRACE_MAX_MB} MB (${cpu_kb} KB per CPU)" >> "$OUTPUT_DIR/steps.log"
        echo "trace-cmd recording ScoutFS events (cap ${TRACE_MAX_MB} MB)"
    fi
}

# Stop trace collection
stop_trace() {
    if [[ "$TRACE_ENABLED" != true ]]; then
        return
    fi

    [[ -n "$TRACE_CMD_PID" ]] || return 0
    local pid="$TRACE_CMD_PID" i
    TRACE_CMD_PID=""

    echo "Stopping trace collection..."

    # End the recording the way it ends on its own: the command trace-cmd
    # runs exits, then trace-cmd stops and merges the per-CPU files.
    pkill -TERM -x sleep -P "$pid" 2>/dev/null
    for (( i = 0; i < 3000; i++ )); do     # the merge can take minutes
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "WARNING: trace-cmd did not exit after 300s; killing it" \
            | tee -a "$OUTPUT_DIR/steps.log" >&2
        kill -INT "$pid" 2>/dev/null
        sleep 5
        kill -9 "$pid" 2>/dev/null
    fi
    echo "$(date '+%F %T') trace-cmd stopped" >> "$OUTPUT_DIR/steps.log"

    # Generate report and compress
    if [[ -f "$OUTPUT_DIR/trace.dat" ]]; then
        echo "Generating trace report..."
        step "trace report" 1200 \
            bash -c 'cd "$1" && trace-cmd report 2>/dev/null | gzip -6 > scoutfs-trace.gz && rm -f trace.dat' \
            _ "$OUTPUT_DIR"
    fi

    # Per-CPU files left by a failed merge can't be read without trace.dat
    # and can be many GB; don't fill the disk again by tarring them.
    if compgen -G "$OUTPUT_DIR/trace.dat.cpu*" > /dev/null; then
        echo "$(date '+%F %T') WARNING: trace merge failed; removing unmerged per-CPU trace files ($(du -cm "$OUTPUT_DIR"/trace.dat.cpu* | awk 'END {print $1}') MB), see trace-cmd.log" \
            | tee -a "$OUTPUT_DIR/steps.log" >&2
        rm -f "$OUTPUT_DIR"/trace.dat.cpu*
    fi
}

# PID for perf top (tracked separately for graceful shutdown)
PERF_TOP_PID=""

# perf top is interactive: run in the background with no terminal it reads
# EOF from stdin and redraws its key-help screen in a tight loop, which wrote
# 2.8 GB in 30s on a 2-CPU test VM and 30 GB on vers06, filling /var/tmp
# (zib/20261106).  Instead, sample every few seconds with perf record and
# append the top of perf report: the same "what is on CPU" view, a few KB per
# sample.
PERF_SAMPLE_SECS=5

perf_top_loop() {
    local data="$OUTPUT_DIR/.perf-top.data"
    while [[ ! -e "$OUTPUT_DIR/.perf-top.stop" ]]; do
        perf record -a -F 99 -o "$data" -- sleep "$PERF_SAMPLE_SECS" >/dev/null 2>&1 || break
        echo "=== $(date '+%F %T') (${PERF_SAMPLE_SECS}s, all CPUs) ==="
        perf report -i "$data" --stdio --no-children --sort comm,dso,symbol 2>/dev/null \
            | grep -v -e '^#' -e '^$' | head -50
    done
    rm -f "$data" "$data.old"
}

start_perf_top() {
    if [[ "$PERF_TOP_ENABLED" != true || "$LOW_SPACE" == true ]]; then
        return
    fi

    if ! command -v perf >/dev/null 2>&1; then
        echo "WARNING: perf not available, skipping perf top collection"
        PERF_TOP_ENABLED=false
        return
    fi

    echo "Starting perf sampling (perf-top.log.gz) for ${DURATION}s..."
    rm -f "$OUTPUT_DIR/.perf-top.stop"
    perf_top_loop < /dev/null > >(gzip -1 > "$OUTPUT_DIR/perf-top.log.gz") 2>&1 &
    PERF_TOP_PID=$!
}

stop_perf_top() {
    if [[ "$PERF_TOP_ENABLED" != true || -z "$PERF_TOP_PID" ]]; then
        return
    fi

    echo "Stopping perf sampling..."
    touch "$OUTPUT_DIR/.perf-top.stop"
    # The current sample finishes within PERF_SAMPLE_SECS; never wait longer
    # than that plus margin (perf can block on a hung node).
    local i
    for (( i = 0; i < (PERF_SAMPLE_SECS + 10) * 10; i++ )); do
        kill -0 "$PERF_TOP_PID" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$PERF_TOP_PID" 2>/dev/null; then
        pkill -9 -P "$PERF_TOP_PID" 2>/dev/null
        kill -9 "$PERF_TOP_PID" 2>/dev/null
    fi
    PERF_TOP_PID=""
    rm -f "$OUTPUT_DIR/.perf-top.stop" "$OUTPUT_DIR/.perf-top.data" "$OUTPUT_DIR/.perf-top.data.old"
    sleep 1    # let gzip flush perf-top.log.gz
}

# Copy a sysfs/debugfs tree under the given destination dir.  These files
# don't report their real size (debugfs reports 0, sysfs 4096), so tar
# would archive them empty or padded with zeros; read them instead.
#
# The file list is written to a local file under a bound first: an unbounded
# `find | while read` stalls the whole copy if find blocks.  Files named in
# the remaining arguments (relative to src) are copied before the rest.
copy_tree() {
    local dest="$1" src="$2" f list
    shift 2
    [[ -d "$src" ]] || return 1

    list=$(mktemp "$OUTPUT_DIR/.tree-XXXXXX")
    bounded 20 find "$src" -type f > "$list" 2>/dev/null
    for f in "$@"; do
        [[ -f "$src/$f" ]] || continue
        mkdir -p "$dest$(dirname "$src/$f")"
        bounded 10 cat "$src/$f" > "$dest$src/$f" 2>&1
    done
    while read -r f; do
        [[ -e "$dest$f" ]] && continue
        mkdir -p "$dest$(dirname "$f")"
        bounded 10 cat "$f" > "$dest$f" 2>&1
    done < "$list"
    rm -f "$list"
}

# Collect the full ScoutFS sysfs and debugfs trees (Cookbook per-node data).
# Counters, mount/volume options, quorum, fence and srch state all live in
# the sysfs tree on current builds.
#
# debugfs comes first: its lock and message state (server_locks,
# client_locks, messages, connections) is in memory and is what a lock hang
# is diagnosed from, while some sysfs files (quorum, volume_options) can
# block on a wedged node.  Each filesystem is its own bounded step, so one
# stuck filesystem cannot cost the others.
SCOUTFS_LOCK_STATE=(server_locks client_locks messages connections server_lock_stats)

collect_scoutfs_trees() {
    local d
    if [[ -d /sys/kernel/debug/scoutfs ]]; then
        echo "Collecting ScoutFS debugfs tree..."
        for d in /sys/kernel/debug/scoutfs/*/; do
            [[ -d "$d" ]] || continue
            step "debugfs $(basename "$d")" 90 \
                copy_tree "$OUTPUT_DIR/debugfs" "${d%/}" "${SCOUTFS_LOCK_STATE[@]}"
        done
        # Top-level files (older builds keep counters here).
        for d in /sys/kernel/debug/scoutfs/*; do
            [[ -f "$d" ]] || continue
            mkdir -p "$OUTPUT_DIR/debugfs/sys/kernel/debug/scoutfs"
            bounded 10 cat "$d" > "$OUTPUT_DIR/debugfs$d" 2>&1
        done
    else
        echo "WARNING: /sys/kernel/debug/scoutfs not found, skipping debugfs tree"
    fi

    if [[ -d /sys/fs/scoutfs ]]; then
        echo "Collecting ScoutFS sysfs tree..."
        for d in /sys/fs/scoutfs/*/; do
            [[ -d "$d" ]] || continue
            step "sysfs $(basename "$d")" 90 copy_tree "$OUTPUT_DIR/sysfs" "${d%/}"
        done
    else
        echo "WARNING: /sys/fs/scoutfs not found, skipping sysfs tree"
    fi
    # File lists left by abandoned copies.
    rm -f "$OUTPUT_DIR"/.tree-*
}

# Capture fencing configuration (/etc/scoutfs and the fenced run file).
collect_fencing_config() {
    [[ -d /etc/scoutfs ]] || return 0

    echo "Collecting fencing configuration..."
    mkdir -p "$OUTPUT_DIR/etc/scoutfs"
    cp -r /etc/scoutfs/. "$OUTPUT_DIR/etc/scoutfs/" 2>/dev/null

    if [[ -f /etc/scoutfs/scoutfs-fenced.conf ]]; then
        # Read SCOUTFS_FENCED_RUN in a subshell so we don't clobber our own vars.
        local fenced_run
        fenced_run=$(source /etc/scoutfs/scoutfs-fenced.conf 2>/dev/null; echo "${SCOUTFS_FENCED_RUN:-}")
        if [[ -n "$fenced_run" && -e "$fenced_run" ]]; then
            cp -r "$fenced_run" "$OUTPUT_DIR/etc/scoutfs/" 2>/dev/null
        fi
    fi
}

# Inventory any existing crashdumps (do not generate new ones).
collect_crashdumps() {
    find /var/crash -ls > "$OUTPUT_DIR/crash_ls.txt" 2>&1
}

# Hang samples: ScoutFS lock and message state, D-state task stacks and TCP
# connection queues every HANG_SAMPLE_SECS for the whole run.  One snapshot
# cannot tell a deadlock from slow progress; a series can (a deadlock shows
# the same tasks waiting on the same locks in every sample).
HANG_SAMPLE_SECS=10
HANG_SAMPLES_ENABLED=true

collect_hang_sample() {
    local dir="$OUTPUT_DIR/hang-samples/$1" d f fs
    mkdir -p "$dir"
    collect_dstate_stacks > "$dir/dstate-stacks.txt" 2>&1
    for d in /sys/kernel/debug/scoutfs/*/; do
        [[ -d "$d" ]] || continue
        fs=$(basename "$d")
        for f in "${SCOUTFS_LOCK_STATE[@]}"; do
            [[ -f "$d$f" ]] || continue
            bounded 3 cat "$d$f" > "$dir/$fs-$f" 2>&1
        done
    done
    if command -v ss >/dev/null 2>&1; then
        bounded 3 ss -tnpie > "$dir/ss.txt" 2>&1
    fi
}

# Take one hang sample, named by seconds into the run (t0000, t0010, ...).
# Bounded below the sample interval so a stuck read cannot stall the loop.
take_hang_sample() {
    [[ "$HANG_SAMPLES_ENABLED" == true ]] || return 0
    bounded $((HANG_SAMPLE_SECS - 2)) collect_hang_sample "$(printf 't%04d' "$1")"
}

# Kernel, ScoutFS and ScoutAM versions.  sosreport also has these, but it is
# skipped with --no-sos and can time out on a hung node.
collect_versions() {
    local f
    echo "# Versions - $(date)"
    echo "=== uname -a ==="; uname -a
    echo; echo "=== /etc/os-release ==="; cat /etc/os-release
    echo; echo "=== /proc/cmdline ==="; cat /proc/cmdline
    echo; echo "=== uptime ==="; uptime
    echo; echo "=== /sys/module/scoutfs ==="
    for f in version srcversion; do
        [[ -r "/sys/module/scoutfs/$f" ]] && echo "$f: $(cat "/sys/module/scoutfs/$f")"
    done
    echo; echo "=== modinfo scoutfs ==="; modinfo scoutfs
    echo; echo "=== lsmod ==="; lsmod
    echo; echo "=== packages (scout*, kernel*, trace-cmd) ==="
    rpm -qa 2>/dev/null | grep -i -E 'scout|^kernel|trace-cmd' | sort
}

# systemd journals: fencing actions, quorum elections and scoutamd errors are
# logged there, not to dmesg, and dmesg's ring buffer can wrap.  The previous
# boot is included in case the node was fenced and rebooted (it is only there
# if the journal is persistent).
JOURNAL_SINCE="-24h"

collect_journals() {
    command -v journalctl >/dev/null 2>&1 || return 0
    local dir="$OUTPUT_DIR/journal" unit
    local -a units=() uargs=()
    mkdir -p "$dir"

    journalctl --list-boots --no-pager > "$dir/boots.txt" 2>&1
    systemctl list-units --all --no-pager 'scout*' > "$dir/scout-units.txt" 2>&1
    systemctl status --all --no-pager -l 'scout*' > "$dir/scout-units-status.txt" 2>&1

    while read -r unit _; do
        [[ -n "$unit" ]] && units+=("$unit") && uargs+=(-u "$unit")
    done < <(systemctl list-units --all --plain --no-legend 'scout*' 2>/dev/null)

    for unit in "${units[@]}"; do
        journalctl --no-pager -o short-precise -u "$unit" --since "$JOURNAL_SINCE" 2>&1 \
            | gzip -1 > "$dir/$unit.log.gz"
    done
    if [[ ${#uargs[@]} -gt 0 ]]; then
        journalctl --no-pager -o short-precise -b -1 "${uargs[@]}" 2>&1 \
            | gzip -1 > "$dir/scout-units-prev-boot.log.gz"
    fi
    journalctl --no-pager -o short-precise -k -b 0 2>&1 | gzip -1 > "$dir/kernel-this-boot.log.gz"
    journalctl --no-pager -o short-precise -k -b -1 2>&1 | gzip -1 > "$dir/kernel-prev-boot.log.gz"
}

# Network state.  ScoutFS lock requests and responses travel between nodes
# over TCP: a Send-Q that does not drain next to a lock request that is not
# granted points at the network.  Interface and NIC counters are taken at
# start and end; TCP/IP counters go to net-counters-*.txt for a delta.
collect_network() {
    local tag="$1" ifc
    echo "# Network state ($tag) - $(date)"
    echo "=== ss -tnpie ==="; bounded 10 ss -tnpie
    echo; echo "=== ip -s -s link ==="; ip -s -s link
    if [[ "$tag" == start ]]; then
        echo; echo "=== ip addr ==="; ip addr
        echo; echo "=== ip route ==="; ip route
    fi
    if command -v ethtool >/dev/null 2>&1; then
        for ifc in /sys/class/net/*; do
            [[ -e "$ifc/device" ]] || continue    # physical NICs only
            ifc=$(basename "$ifc")
            if [[ "$tag" == start ]]; then
                echo; echo "=== ethtool $ifc ==="; bounded 5 ethtool "$ifc"
            fi
            echo; echo "=== ethtool -S $ifc ==="; bounded 5 ethtool -S "$ifc"
        done
    fi
}

# /proc/net/snmp and /proc/net/netstat as "Proto.Name value" lines (each
# protocol is a header line followed by a value line).
snapshot_net_counters() {
    awk '$1 in hdr { n = split(hdr[$1], h)
                     for (i = 2; i <= NF && i <= n; i++)
                         print substr($1, 1, length($1) - 1) "." h[i], $i
                     delete hdr[$1]; next }
         { hdr[$1] = $0 }' /proc/net/snmp /proc/net/netstat 2>/dev/null
}

# Clock sync.  Lining up logs from different nodes depends on it, and quorum
# relies on timeouts.
collect_time_sync() {
    echo "# Time sync - $(date)"
    echo "=== date (UTC) ==="; date -u '+%F %T.%N %Z'
    if command -v timedatectl >/dev/null 2>&1; then
        echo; echo "=== timedatectl ==="; bounded 10 timedatectl
    fi
    if command -v chronyc >/dev/null 2>&1; then
        echo; echo "=== chronyc tracking ==="; bounded 10 chronyc tracking
        echo; echo "=== chronyc sources -v ==="; bounded 10 chronyc sources -v
    elif command -v ntpq >/dev/null 2>&1; then
        echo; echo "=== ntpq -p ==="; bounded 10 ntpq -p
    fi
}

# Memory and pressure state: PSI (cpu/memory/io stall time), slab usage and
# free-page fragmentation, at start and end.
collect_pressure() {
    local tag="$1" r
    if [[ -d /proc/pressure ]]; then
        for r in cpu memory io; do
            echo "=== $r ==="
            cat "/proc/pressure/$r"
        done > "$OUTPUT_DIR/pressure-$tag.txt" 2>&1
    else
        # RHEL kernels ship with PSI disabled; it needs psi=1 on the cmdline.
        echo "# PSI not available (/proc/pressure missing; boot with psi=1 to enable)" \
            > "$OUTPUT_DIR/pressure-$tag.txt"
    fi
    cat /proc/buddyinfo > "$OUTPUT_DIR/buddyinfo-$tag.txt" 2>&1
    cat /proc/slabinfo > "$OUTPUT_DIR/slabinfo-$tag.txt" 2>&1
}

# SCSI and tape devices on the archive path.
collect_scsi_inventory() {
    if command -v lsscsi >/dev/null 2>&1; then
        echo "=== lsscsi -g ==="; lsscsi -g
        echo; echo "=== lsscsi -t ==="; lsscsi -t
    else
        echo "=== /proc/scsi/scsi ==="; cat /proc/scsi/scsi
    fi
}

# Tape drive I/O statistics and per-SCSI-device request/error counts as
# "name value" lines, for a start/end delta.  Each tape has several mode
# devices (st0, st0l, nst0, ...) sharing one set of stats: read st<N> only.
snapshot_scsi_stats() {
    local d f name v
    for d in /sys/class/scsi_tape/st*; do
        name=$(basename "$d")
        [[ "$name" =~ ^st[0-9]+$ && -d "$d/stats" ]] || continue
        for f in "$d"/stats/*; do
            v=$(cat "$f" 2>/dev/null)
            [[ "$v" =~ ^[0-9]+$ ]] && echo "$name.$(basename "$f") $v"
        done
    done
    for d in /sys/class/scsi_device/*/device; do
        name=$(basename "$(dirname "$d")")
        for f in iorequest_cnt iodone_cnt ioerr_cnt iotmo_cnt; do
            v=$(cat "$d/$f" 2>/dev/null)
            # These counters are hex (0x1a2b).
            [[ "$v" =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]] && echo "$name.$f $((v))"
        done
    done
}

# Snapshot ScoutFS counters to a "name value" file for delta computation.
# Prefers the sysfs counters directory (one file per counter, current
# layout); falls back to a single debugfs counters file (older layout).
snapshot_scoutfs_counters() {
    local out="$1"
    local ctr_dir
    ctr_dir=$(find /sys/fs/scoutfs -mindepth 2 -maxdepth 2 -type d -name counters 2>/dev/null | head -1)
    if [[ -n "$ctr_dir" ]]; then
        local f
        for f in "$ctr_dir"/*; do
            [[ -f "$f" ]] || continue
            printf '%s %s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
        done > "$out"
        return 0
    fi

    local scoutfs_debug
    if scoutfs_debug=$(get_scoutfs_debug_path) && [[ -f "$scoutfs_debug/counters" ]]; then
        cat "$scoutfs_debug/counters" > "$out" 2>&1
        return 0
    fi
    return 1
}

# Check if pprof port is responding
check_pprof_port() {
    local port="$1"
    curl -s --connect-timeout 2 --max-time 5 "http://127.0.0.1:$port/debug/pprof/" >/dev/null 2>&1
}

# Collect initial pprof data (heap, block, mutex) from a single port
collect_pprof_initial_port() {
    local port="$1"
    local output_dir="$2"

    # Heap profile
    curl -s --max-time 30 "http://127.0.0.1:$port/debug/pprof/heap?debug=1" \
        > "$output_dir/heap-$port.txt" 2>&1

    # Block profile (where threads are waiting)
    curl -s --max-time 30 "http://127.0.0.1:$port/debug/pprof/block?debug=1" \
        > "$output_dir/block-$port.txt" 2>&1

    # Mutex contention
    curl -s --max-time 30 "http://127.0.0.1:$port/debug/pprof/mutex?debug=1" \
        > "$output_dir/mutex-$port.txt" 2>&1
}

# Collect goroutine dump from a single port with timestamp suffix
collect_pprof_goroutine_port() {
    local port="$1"
    local output_dir="$2"
    local timestamp="$3"

    curl -s --max-time 30 "http://127.0.0.1:$port/debug/pprof/goroutine?debug=2" \
        > "$output_dir/goroutine-$port-$timestamp.txt" 2>&1
}

# Known ScoutAM pprof ports
PPROF_PORTS=(6060 6061 6062)
declare -a PPROF_ACTIVE_PORTS=()

# Collect initial pprof data (heap, block, mutex - once at start)
collect_pprof_initial() {
    if [[ "$PPROF_ENABLED" != true ]]; then
        return
    fi

    # Check if curl is available
    if ! command -v curl >/dev/null 2>&1; then
        echo "WARNING: curl not available, skipping pprof collection"
        PPROF_ENABLED=false
        return
    fi

    echo "Collecting initial ScoutAM pprof data..."
    local pprof_dir="$OUTPUT_DIR/pprof"
    mkdir -p "$pprof_dir"

    # Discover active ports and collect initial data
    for port in "${PPROF_PORTS[@]}"; do
        if check_pprof_port "$port"; then
            PPROF_ACTIVE_PORTS+=("$port")
            echo "  Port $port responding, collecting heap/block/mutex..."
            collect_pprof_initial_port "$port" "$pprof_dir"
        else
            echo "  Port $port not responding, skipping"
        fi
    done

    if [[ ${#PPROF_ACTIVE_PORTS[@]} -eq 0 ]]; then
        echo "  No pprof ports responding, periodic collection disabled"
        PPROF_ENABLED=false
    fi
}

# Collect periodic goroutine dumps (called every 10s from main loop)
collect_pprof_goroutines() {
    if [[ "$PPROF_ENABLED" != true ]]; then
        return
    fi

    local elapsed="$1"
    local pprof_dir="$OUTPUT_DIR/pprof"

    # Format timestamp as 3-digit string (000, 010, 020, etc.)
    local timestamp
    timestamp=$(printf "%03d" "$elapsed")

    for port in "${PPROF_ACTIVE_PORTS[@]}"; do
        collect_pprof_goroutine_port "$port" "$pprof_dir" "$timestamp"
    done
}

collect_scheduler_profile() {
    # Only run on the ScoutAM scheduler node (scoutamd listening on port 8888)
    if ! ss -tulnp 2>/dev/null | grep ':8888 ' | grep -q 'scoutamd'; then
        echo "Skipping scheduler profile: scoutamd not listening on port 8888 on this node"
        return
    fi

    echo "Collecting scheduler CPU profile (${SCHEDULER_PROFILE_SECONDS}s)..."
    curl --silent --show-error --max-time $((SCHEDULER_PROFILE_SECONDS + 30)) \
        "http://localhost:6060/debug/pprof/profile?seconds=${SCHEDULER_PROFILE_SECONDS}" \
        --output "${OUTPUT_DIR}/pprof/scheduler.prof" 2>&1 \
        || echo "Warning: failed to collect scheduler profile" >&2
}

# Collect thread-level diagnostics for scoutamd
collect_thread_diagnostics() {
    local output_dir="$OUTPUT_DIR/scoutamd-threads"
    local pid
    pid=$(pgrep -x scoutamd 2>/dev/null | head -1)

    if [[ -z "$pid" ]]; then
        echo "scoutamd not running, skipping thread diagnostics"
        return 1
    fi

    echo "Collecting scoutamd thread diagnostics (PID $pid)..."
    mkdir -p "$output_dir"

    # Kernel stack traces for all threads
    echo "# Kernel stacks for scoutamd threads (PID $pid)" > "$output_dir/stacks.txt"
    echo "# Collected at $(date)" >> "$output_dir/stacks.txt"
    echo "#" >> "$output_dir/stacks.txt"

    for task in /proc/$pid/task/*; do
        [[ -d "$task" ]] || continue
        local tid
        tid=$(basename "$task")
        echo "=== Thread $tid ===" >> "$output_dir/stacks.txt"
        cat "$task/stack" >> "$output_dir/stacks.txt" 2>&1 || echo "Unable to read stack" >> "$output_dir/stacks.txt"
        echo "" >> "$output_dir/stacks.txt"
    done

    # Current syscall per thread
    echo "# Current syscalls for scoutamd threads (PID $pid)" > "$output_dir/syscalls.txt"
    echo "# Collected at $(date)" >> "$output_dir/syscalls.txt"
    echo "# Format: syscall_nr arg0 arg1 arg2 arg3 arg4 arg5 sp pc" >> "$output_dir/syscalls.txt"
    echo "#" >> "$output_dir/syscalls.txt"

    for task in /proc/$pid/task/*; do
        [[ -d "$task" ]] || continue
        local tid
        tid=$(basename "$task")
        local syscall
        syscall=$(cat "$task/syscall" 2>/dev/null || echo "unable to read")
        printf "Thread %-8s: %s\n" "$tid" "$syscall" >> "$output_dir/syscalls.txt"
    done

    # Memory maps
    echo "# Memory maps for scoutamd (PID $pid)" > "$output_dir/maps.txt"
    echo "# Collected at $(date)" >> "$output_dir/maps.txt"
    echo "#" >> "$output_dir/maps.txt"
    cat "/proc/$pid/maps" >> "$output_dir/maps.txt" 2>&1 || echo "Unable to read maps" >> "$output_dir/maps.txt"

    # File descriptors (more detailed than process-info.txt)
    echo "# File descriptors for scoutamd (PID $pid)" > "$output_dir/fds.txt"
    echo "# Collected at $(date)" >> "$output_dir/fds.txt"
    echo "#" >> "$output_dir/fds.txt"
    ls -la "/proc/$pid/fd" >> "$output_dir/fds.txt" 2>&1 || echo "Unable to read fds" >> "$output_dir/fds.txt"
}

# Collect SOS report
collect_sos_report() {
    if [[ "$SOS_ENABLED" != true ]]; then
        return 0
    fi

    # A sosreport takes hundreds of MB more in /var/tmp.
    if [[ "$LOW_SPACE" == true || -e "$OUTPUT_DIR/.low-space" ]]; then
        echo "WARNING: low disk space, skipping SOS report" | tee -a "$OUTPUT_DIR/steps.log" >&2
        return 0
    fi

    # Check if sos is installed
    if ! command -v sos >/dev/null 2>&1; then
        echo "WARNING: sos command not found, skipping SOS report collection"
        echo "  Install with: dnf install sos"
        echo "sos" >> "$OUTPUT_DIR/missing-utils.txt"
        return 0
    fi

    echo "Collecting SOS report (this may take several minutes)..."

    local sos_output
    local sos_exit_code

    # sos can hang on a wedged node; bound it so the tarball still gets made.
    # Output goes to a file, not $(...): command substitution would wait on
    # an abandoned D-state child holding the pipe open.
    bounded 1800 sos report --batch --quiet > "$OUTPUT_DIR/sos-output.txt" 2>&1
    sos_exit_code=$?
    sos_output=$(cat "$OUTPUT_DIR/sos-output.txt")

    if [[ $sos_exit_code -ne 0 ]]; then
        echo "WARNING: sos report failed with exit code $sos_exit_code"
        echo "# SOS report collection failed" > "$OUTPUT_DIR/sos-error.txt"
        echo "# Exit code: $sos_exit_code" >> "$OUTPUT_DIR/sos-error.txt"
        echo "$sos_output" >> "$OUTPUT_DIR/sos-error.txt"
        return 0
    fi

    # Find the generated SOS report
    local sos_file
    sos_file=$(echo "$sos_output" | grep -oE '/var/tmp/sosreport-[^ ]+\.tar\.(xz|gz|bz2)' | tail -1)

    # Fallback: find the most recent sosreport in /var/tmp
    if [[ -z "$sos_file" || ! -f "$sos_file" ]]; then
        sos_file=$(ls -t /var/tmp/sosreport-*.tar.* 2>/dev/null | head -1)
    fi

    if [[ -z "$sos_file" || ! -f "$sos_file" ]]; then
        echo "WARNING: Could not locate generated SOS report file"
        echo "# Could not locate SOS report file" > "$OUTPUT_DIR/sos-error.txt"
        echo "$sos_output" >> "$OUTPUT_DIR/sos-error.txt"
        return 0
    fi

    echo "Found SOS report: $sos_file"

    # Copy the SOS report to our output directory
    local sos_basename
    sos_basename=$(basename "$sos_file")

    if cp "$sos_file" "$OUTPUT_DIR/$sos_basename"; then
        echo "Copied SOS report to $OUTPUT_DIR/$sos_basename"
        # Clean up original from /var/tmp
        rm -f "$sos_file" "${sos_file}.md5" "${sos_file}.sha256" 2>/dev/null
        echo "Cleaned up original SOS report from /var/tmp"
    else
        echo "WARNING: Failed to copy SOS report to output directory"
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --duration)
                DURATION="$2"
                if ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
                    echo "ERROR: Duration must be a positive integer"
                    exit 1
                fi
                shift 2
                ;;
            --trace)
                TRACE_ENABLED=true
                shift
                ;;
            --no-trace)
                TRACE_ENABLED=false
                shift
                ;;
            --trace-max-mb)
                TRACE_MAX_MB="$2"
                if ! [[ "$TRACE_MAX_MB" =~ ^[0-9]+$ ]] || (( TRACE_MAX_MB < 64 )); then
                    echo "ERROR: --trace-max-mb must be an integer of at least 64"
                    exit 1
                fi
                shift 2
                ;;
            --output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --scoutfs-mount)
                SCOUTFS_MOUNT="$2"
                shift 2
                ;;
            --install)
                INSTALL_MISSING=true
                shift
                ;;
            --no-pprof)
                PPROF_ENABLED=false
                shift
                ;;
            --no-sos)
                SOS_ENABLED=false
                shift
                ;;
            --perf-top)
                PERF_TOP_ENABLED=true
                shift
                ;;
            --no-perf-top)
                PERF_TOP_ENABLED=false
                shift
                ;;
            --profile-scheduler)
                if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
                    echo "Error: --profile-scheduler requires a positive integer argument" >&2
                    exit 1
                fi
                SCHEDULER_PROFILE_SECONDS="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Main
main() {
    parse_args "$@"

    # Check for root (needed for some collectors)
    if [[ $EUID -ne 0 ]]; then
        echo "WARNING: Running as non-root. Some collectors (iotop, turbostat, trace-cmd) may fail."
        echo ""
    fi

    # Set up output directory
    if [[ -z "$OUTPUT_DIR" ]]; then
        # Absolute path on local disk: if the cwd is on a hung ScoutFS mount,
        # mkdir and trace-cmd's trace.dat writes would block.
        OUTPUT_DIR="/var/tmp/triage-$(hostname -s)-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "$OUTPUT_DIR"

    # A capture with a sosreport needs a few GB; with less, steps fail
    # silently (writes get ENOSPC) and the capture is incomplete.
    local free
    free=$(free_mb)
    if [[ -n "$free" ]] && (( free < 4096 )); then
        echo "ERROR: only ${free} MB free under $OUTPUT_DIR (need 4096 MB)."
        echo "       Free space there (old triage-* directories) or use --output DIR on another local disk."
        # Nothing collected yet: skip the EXIT trap's tarball and clean up.
        trap - EXIT SIGINT SIGTERM
        rmdir "$OUTPUT_DIR" 2>/dev/null
        exit 1
    fi
    echo "$(date '+%F %T') free space under $OUTPUT_DIR: ${free:-?} MB" >> "$OUTPUT_DIR/steps.log"

    if [[ -z "$TRACE_MAX_MB" ]]; then
        TRACE_MAX_MB=$(( ${free:-16384} / 4 ))
        (( TRACE_MAX_MB > 4096 )) && TRACE_MAX_MB=4096
    fi

    echo "============================================="
    echo "ScoutFS/ScoutAM Triage Collection"
    echo "============================================="
    echo "Duration:    ${DURATION}s"
    echo "Trace:       $TRACE_ENABLED"
    echo "Pprof:       $PPROF_ENABLED"
    echo "SOS:         $SOS_ENABLED"
    echo "Perf top:    $PERF_TOP_ENABLED"
    echo "Output:      $OUTPUT_DIR"
    echo ""

    # Detect ScoutFS mount
    detect_scoutfs_mount

    # Check utilities
    check_utilities

    # Start the scoutfs trace first so it is running even if a later
    # collection step stalls on a hung node.
    start_trace
    start_space_watchdog

    # Collect start snapshots
    collect_start_snapshots
    check_space

    # Start background collectors
    start_collectors

    # Start perf top if enabled
    start_perf_top

    # Collect initial pprof data (heap, block, mutex - once at start)
    collect_pprof_initial

    if [[ "$SCHEDULER_PROFILE_SECONDS" -gt 0 ]]; then
        collect_scheduler_profile
    fi

    echo ""
    echo "Collecting data... Press Ctrl+C to stop early."
    echo ""

    # Wait for duration, collecting goroutine dumps and hang samples every
    # 10s.  Sleep to the next 10s mark rather than a fixed 10s, so time spent
    # collecting does not stretch the run.
    local elapsed=0 start=$SECONDS nap

    # Collect at t=0
    collect_pprof_goroutines $elapsed
    take_hang_sample $elapsed

    while [[ $elapsed -lt $DURATION ]]; do
        elapsed=$((elapsed + HANG_SAMPLE_SECS))
        nap=$((start + elapsed - SECONDS))
        (( nap > 0 )) && sleep "$nap"
        check_space
        if [[ $elapsed -lt $DURATION ]]; then
            echo "  ${elapsed}s / ${DURATION}s elapsed..."
            collect_pprof_goroutines $elapsed
            take_hang_sample $elapsed
        fi
    done

    echo ""
    echo "Duration complete."

    # Stop trace
    stop_trace

    # Stop perf top
    stop_perf_top

    # Cleanup will handle the rest via trap
}

main "$@"
