#!/bin/bash
#
# collect-tape-diag.sh - Tape Performance Diagnostic Collection Script
#
# Collects memory, I/O, CPU, and ScoutFS metrics to diagnose slow tape writes.
# Focus: Page cache behavior and I/O path analysis
#
# Usage: ./collect-tape-diag.sh [--duration SECONDS] [--trace] [--output DIR] [--scoutfs-mount PATH] [--no-perf-top]
#

set -o pipefail

# Default values
DURATION=60
TRACE_ENABLED=false
OUTPUT_DIR=""
SCOUTFS_MOUNT=""
INSTALL_MISSING=false
PPROF_ENABLED=true
SOS_ENABLED=true
SCHEDULER_PROFILE_SECONDS=0
PERF_TOP_ENABLED=true

# PID tracking for background processes
declare -a BG_PIDS=()

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
        collect_end_snapshots
        calculate_deltas

        # Collect SOS report (do last before tarball, can be slow)
        collect_sos_report

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

Collect diagnostic data for tape performance analysis.
Focus: Page cache behavior and I/O path analysis.

OPTIONS:
    --duration SECONDS   Collection duration (default: 60)
                         Tape operations may need longer (300-600s)
    --trace              Enable trace-cmd for ScoutFS kernel events.
                         Higher overhead, larger data files.
    --output DIR         Output directory (default: tape-diag-YYYYMMDD-HHMMSS)
    --scoutfs-mount PATH ScoutFS mount point (default: auto-detect)
    --install            Auto-install missing utilities via dnf (requires root)
    --no-pprof           Skip ScoutAM Go profiling (enabled by default)
    --no-sos             Skip SOS report collection (enabled by default)
    --no-perf-top        Skip perf top collection (enabled by default)
    --profile-scheduler N   Collect a ${N}s CPU profile from the ScoutAM scheduler
                            pprof endpoint (only runs on the scheduler node,
                            detected via port 8888 listening)
    -h, --help           Show this help message

EXAMPLES:
    $(basename "$0")                           # 60 second collection
    $(basename "$0") --duration 300            # 5 minute collection
    $(basename "$0") --trace --duration 120    # 2 min with deep tracing
    $(basename "$0") --scoutfs-mount /mnt/scoutfs
    $(basename "$0") --install                 # Auto-install missing utilities
    $(basename "$0") --no-pprof                # Skip ScoutAM profiling
    $(basename "$0") --no-sos                  # Skip SOS report (faster)

OUTPUT:
    Creates a timestamped directory containing:
    - vmstat.log, iostat.log, iotop.log, sar-paging.log, turbostat.log
    - meminfo/vmstat snapshots (start/end/delta)
    - scoutfs counters (start/end/delta)
    - fc-stats-start.txt, fc-stats-end.txt, fc-stats-delta.txt (FC host stats)
    - sys_block_settings.csv (block device queue settings)
    - device-hierarchy.txt (MDRAID, DM, multipath topology)
    - ps-auxf.txt, top.txt (running processes)
    - dmesg.log, sysrq-t.log, sysrq-l.log (kernel logs and stack traces)
    - process-info.txt (scoutamd state)
    - pprof/ (goroutine dumps every 10s; heap, block, mutex once at start)
    - scoutamd-threads/ (kernel stacks, syscalls, memory maps)
    - scoutfs-trace.gz (if --trace enabled)
    - perf-top.log.gz (perf top output for duration)
    - debugfs-scoutfs.tar (ScoutFS debugfs tree snapshot)
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

# Check for required utilities
check_utilities() {
    local missing_core=()
    local missing_optional=()
    local missing_trace=()
    local packages_to_install=()

    # Core utilities (required)
    for cmd in vmstat iostat sar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_core+=("$cmd")
        fi
    done

    # Optional utilities
    if ! command -v iotop >/dev/null 2>&1; then
        missing_optional+=("iotop")
    fi
    if ! command -v turbostat >/dev/null 2>&1; then
        missing_optional+=("turbostat")
    fi
    if [[ "$PERF_TOP_ENABLED" == true ]]; then
        if ! command -v perf >/dev/null 2>&1; then
            missing_optional+=("perf")
        fi
    fi

    # Trace utilities (only if --trace enabled)
    if [[ "$TRACE_ENABLED" == true ]]; then
        if ! command -v trace-cmd >/dev/null 2>&1; then
            missing_trace+=("trace-cmd")
        fi
    fi

    # Handle --install flag
    if [[ "$INSTALL_MISSING" == true ]]; then
        # Map missing commands to packages
        if [[ ${#missing_core[@]} -gt 0 ]]; then
            packages_to_install+=("procps-ng" "sysstat")
        fi
        for opt in "${missing_optional[@]}"; do
            case "$opt" in
                iotop) packages_to_install+=("iotop") ;;
                turbostat) packages_to_install+=("kernel-tools") ;;
                perf) packages_to_install+=("perf") ;;
            esac
        done
        for trace in "${missing_trace[@]}"; do
            case "$trace" in
                trace-cmd) packages_to_install+=("trace-cmd") ;;
            esac
        done

        # Remove duplicates and install
        if [[ ${#packages_to_install[@]} -gt 0 ]]; then
            local unique_packages
            unique_packages=($(printf '%s\n' "${packages_to_install[@]}" | sort -u))
            if install_missing_packages "${unique_packages[@]}"; then
                # Re-check after installation
                missing_core=()
                missing_optional=()
                missing_trace=()

                for cmd in vmstat iostat sar; do
                    if ! command -v "$cmd" >/dev/null 2>&1; then
                        missing_core+=("$cmd")
                    fi
                done
                if ! command -v iotop >/dev/null 2>&1; then
                    missing_optional+=("iotop")
                fi
                if ! command -v turbostat >/dev/null 2>&1; then
                    missing_optional+=("turbostat")
                fi
                if [[ "$PERF_TOP_ENABLED" == true ]]; then
                    if ! command -v perf >/dev/null 2>&1; then
                        missing_optional+=("perf")
                    fi
                fi
                if [[ "$TRACE_ENABLED" == true ]]; then
                    if ! command -v trace-cmd >/dev/null 2>&1; then
                        missing_trace+=("trace-cmd")
                    fi
                fi
            fi
        fi
    fi

    # Report missing core utilities and exit
    if [[ ${#missing_core[@]} -gt 0 ]]; then
        echo "ERROR: Missing required utilities: ${missing_core[*]}"
        echo ""
        echo "Install packages (RHEL/Rocky):"
        echo "  vmstat, iostat, sar: dnf install procps-ng sysstat"
        echo ""
        echo "Or run with --install to auto-install missing packages"
        exit 1
    fi

    # Warn about missing optional utilities
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        echo "WARNING: Missing optional utilities: ${missing_optional[*]}"
        echo "  iotop: dnf install iotop"
        echo "  turbostat: dnf install kernel-tools"
        echo "  perf: dnf install perf"
        echo "These collectors will be skipped."
        echo ""

        # Record missing utilities
        printf '%s\n' "${missing_optional[@]}" > "$OUTPUT_DIR/missing-utils.txt"
    fi

    # Warn about missing trace utilities
    if [[ ${#missing_trace[@]} -gt 0 ]]; then
        echo "WARNING: Missing trace utilities: ${missing_trace[*]}"
        echo "  trace-cmd: dnf install trace-cmd"
        echo "Trace collection will be skipped."
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

# Collect start snapshots
collect_start_snapshots() {
    echo "Collecting start snapshots..."

    # Memory info
    cat /proc/meminfo > "$OUTPUT_DIR/meminfo-start.txt" 2>&1

    # vmstat counters
    cat /proc/vmstat > "$OUTPUT_DIR/vmstat-start.txt" 2>&1

    # ScoutFS counters
    local scoutfs_debug
    if scoutfs_debug=$(get_scoutfs_debug_path); then
        if [[ -f "$scoutfs_debug/counters" ]]; then
            cat "$scoutfs_debug/counters" > "$OUTPUT_DIR/scoutfs-counters-start.txt" 2>&1
        fi
    fi

    # ScoutFS debugfs tree
    collect_debugfs_scoutfs

    # FC host statistics
    collect_fc_stats "$OUTPUT_DIR/fc-stats-start.txt"

    # Process info
    collect_process_info > "$OUTPUT_DIR/process-info.txt" 2>&1

    # ScoutFS statfs
    if [[ -n "$SCOUTFS_MOUNT" ]] && command -v scoutfs >/dev/null 2>&1; then
        scoutfs statfs -s "$SCOUTFS_MOUNT" >> "$OUTPUT_DIR/process-info.txt" 2>&1
    fi

    # Thread diagnostics (always collected at start)
    collect_thread_diagnostics

    # Block device queue settings
    collect_block_settings

    # Device hierarchy (MDRAID, DM, multipath)
    collect_device_hierarchy

    # System-wide process listing
    collect_processes

    # Kernel logs and stack traces
    collect_kernel_state
}

# Collect end snapshots
collect_end_snapshots() {
    echo "Collecting end snapshots..."

    # Memory info
    cat /proc/meminfo > "$OUTPUT_DIR/meminfo-end.txt" 2>&1

    # vmstat counters
    cat /proc/vmstat > "$OUTPUT_DIR/vmstat-end.txt" 2>&1

    # ScoutFS counters
    local scoutfs_debug
    if scoutfs_debug=$(get_scoutfs_debug_path); then
        if [[ -f "$scoutfs_debug/counters" ]]; then
            cat "$scoutfs_debug/counters" > "$OUTPUT_DIR/scoutfs-counters-end.txt" 2>&1
        fi
    fi

    # FC host statistics
    collect_fc_stats "$OUTPUT_DIR/fc-stats-end.txt"
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
        # Clear dmesg to isolate sysrq output
        dmesg --clear 2>/dev/null

        # Stack traces for all stopped/blocked tasks
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
    echo "Starting background collectors for ${DURATION}s..."

    # vmstat - 1 second interval
    vmstat 1 > "$OUTPUT_DIR/vmstat.log" 2>&1 &
    BG_PIDS+=($!)

    # iostat - 1 second interval, extended stats, all devices
    iostat -x 1 > "$OUTPUT_DIR/iostat.log" 2>&1 &
    BG_PIDS+=($!)

    # sar - paging stats, 1 second interval
    sar -B 1 "$DURATION" > "$OUTPUT_DIR/sar-paging.log" 2>&1 &
    BG_PIDS+=($!)

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

# Start trace collection
start_trace() {
    if [[ "$TRACE_ENABLED" != true ]]; then
        return
    fi

    echo "Starting trace collection..."

    # trace-cmd for ScoutFS events
    if command -v trace-cmd >/dev/null 2>&1; then
        (
            cd "$OUTPUT_DIR"
            trace-cmd record -e "scoutfs:*" sleep "$DURATION" 2>/dev/null
        ) &
        TRACE_CMD_PID=$!
        echo "trace-cmd recording ScoutFS events for ${DURATION}s"
    fi
}

# Stop trace collection
stop_trace() {
    if [[ "$TRACE_ENABLED" != true ]]; then
        return
    fi

    echo "Stopping trace collection..."

    # If trace-cmd is still running, send SIGINT to stop it gracefully
    if [[ -n "$TRACE_CMD_PID" ]] && kill -0 "$TRACE_CMD_PID" 2>/dev/null; then
        kill -INT "$TRACE_CMD_PID" 2>/dev/null
        wait "$TRACE_CMD_PID" 2>/dev/null
    fi

    # Generate report and compress
    if [[ -f "$OUTPUT_DIR/trace.dat" ]]; then
        echo "Generating trace report..."
        (cd "$OUTPUT_DIR" && trace-cmd report 2>/dev/null | gzip -9 > scoutfs-trace.gz && rm -f trace.dat)
    fi
}

# PID for perf top (tracked separately for graceful shutdown)
PERF_TOP_PID=""

start_perf_top() {
    if [[ "$PERF_TOP_ENABLED" != true ]]; then
        return
    fi

    if ! command -v perf >/dev/null 2>&1; then
        echo "WARNING: perf not available, skipping perf top collection"
        PERF_TOP_ENABLED=false
        return
    fi

    echo "Starting perf top collection for ${DURATION}s..."
    perf top -a -d 1 --stdio > "$OUTPUT_DIR/perf-top.log" 2>&1 &
    PERF_TOP_PID=$!
}

stop_perf_top() {
    if [[ "$PERF_TOP_ENABLED" != true ]]; then
        return
    fi

    if [[ -n "$PERF_TOP_PID" ]] && kill -0 "$PERF_TOP_PID" 2>/dev/null; then
        echo "Stopping perf top..."
        kill -INT "$PERF_TOP_PID" 2>/dev/null
        wait "$PERF_TOP_PID" 2>/dev/null
    fi

    if [[ -f "$OUTPUT_DIR/perf-top.log" ]]; then
        echo "Compressing perf-top.log..."
        gzip -9 "$OUTPUT_DIR/perf-top.log"
    fi
}

collect_debugfs_scoutfs() {
    local debug_base="/sys/kernel/debug/scoutfs"
    if [[ ! -d "$debug_base" ]]; then
        echo "WARNING: $debug_base not found, skipping debugfs tar"
        return
    fi

    echo "Collecting ScoutFS debugfs..."
    tar cf "$OUTPUT_DIR/debugfs-scoutfs.tar" -C /sys/kernel/debug scoutfs 2>&1 \
        || echo "WARNING: failed to tar $debug_base" >&2
}

# Check if pprof port is responding
check_pprof_port() {
    local port="$1"
    curl -s --connect-timeout 2 "http://127.0.0.1:$port/debug/pprof/" >/dev/null 2>&1
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
    curl --silent --show-error \
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

    sos_output=$(sos report --batch --quiet 2>&1)
    sos_exit_code=$?

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
        OUTPUT_DIR="tape-diag-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "$OUTPUT_DIR"

    echo "============================================="
    echo "Tape Performance Diagnostic Collection"
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

    # Collect start snapshots
    collect_start_snapshots

    # Start background collectors
    start_collectors

    # Start trace if enabled
    start_trace

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

    # Wait for duration, collecting goroutine dumps every 10s
    local elapsed=0

    # Collect goroutines at t=0
    collect_pprof_goroutines $elapsed

    while [[ $elapsed -lt $DURATION ]]; do
        sleep 10
        elapsed=$((elapsed + 10))
        if [[ $elapsed -lt $DURATION ]]; then
            echo "  ${elapsed}s / ${DURATION}s elapsed..."
            # Collect goroutine dumps periodically
            collect_pprof_goroutines $elapsed
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
