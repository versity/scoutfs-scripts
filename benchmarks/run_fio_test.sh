#!/bin/bash

# Script to create and run fio tests with various configurations

# Default values
OP=""
DIR=""
FILES=""
SIZE=""
TIME=""
DROP_CACHES=0
BS="1M"  # Default block size
RATIO="1:1"  # Default write:read ratio for rw test
WRATE=""  # Write rate limit (optional)
RRATE=""  # Read rate limit (optional)
FALLOCATE="native"  # File allocation mode (default: native)
CSV=0  # Output in CSV format
REMOVE=0  # Remove test files after completion
RUNS=1  # Number of test runs

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --op)
            OP="$2"
            shift 2
            ;;
        --dir)
            DIR="$2"
            shift 2
            ;;
        --files)
            FILES="$2"
            shift 2
            ;;
        --size)
            SIZE="$2"
            shift 2
            ;;
        --time)
            TIME="$2"
            shift 2
            ;;
        --bs)
            BS="$2"
            shift 2
            ;;
        --drop_caches)
            DROP_CACHES=1
            shift
            ;;
        --ratio)
            RATIO="$2"
            shift 2
            ;;
        --wrate)
            WRATE="$2"
            shift 2
            ;;
        --rrate)
            RRATE="$2"
            shift 2
            ;;
        --fallocate)
            FALLOCATE="$2"
            shift 2
            ;;
        --csv)
            CSV=1
            shift
            ;;
        --remove)
            REMOVE=1
            shift
            ;;
        --runs)
            RUNS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --op wr|rd|rw --dir PATH --files N --size SIZE --time SECONDS [--bs BLOCKSIZE] [--ratio W:R] [--wrate RATE] [--rrate RATE] [--fallocate MODE] [--runs N] [--csv] [--remove] [--drop_caches]"
            echo "  --ratio W:R : For rw test, creates N*W write files and N*R read files (default 1:1)"
            echo "  --wrate RATE : Limit write bandwidth (e.g., 100M will limit writes to 100 MB/sec)"
            echo "  --rrate RATE : Limit read bandwidth (e.g., 100M will limit read rates to 100 MB/sec)"
            echo "  --fallocate MODE : Set file allocation mode (none|native|posix, default: native)"
            echo "  --runs N : Number of test runs (default: 1)"
            echo "  --csv : Output results in CSV format"
            echo "  --remove : Remove test files after completion"
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$OP" || -z "$DIR" || -z "$FILES" || -z "$SIZE" || -z "$TIME" ]]; then
    echo "Error: Missing required parameters"
    echo "Usage: $0 --op wr|rd|rw --dir PATH --files N --size SIZE --time SECONDS [--bs BLOCKSIZE] [--ratio W:R] [--wrate RATE] [--rrate RATE] [--fallocate MODE] [--runs N] [--csv] [--remove] [--drop_caches]"
    echo "  --ratio W:R : For rw test, creates N*W write files and N*R read files (default 1:1)"
    echo "  --wrate RATE : Limit write bandwidth (e.g., 100m, 1g)"
    echo "  --rrate RATE : Limit read bandwidth (e.g., 100m, 1g)"
    echo "  --fallocate MODE : Set file allocation mode (none|native|posix, default: native)"
    echo "  --runs N : Number of test runs (default: 1)"
    echo "  --csv : Output results in CSV format"
    echo "  --remove : Remove test files after completion"
    exit 1
fi

# Validate operation type
if [[ "$OP" != "wr" && "$OP" != "rd" && "$OP" != "rw" ]]; then
    echo "Error: --op must be wr, rd, or rw"
    exit 1
fi

# Validate fallocate mode if specified
if [[ -n "$FALLOCATE" ]]; then
    if [[ "$FALLOCATE" != "none" && "$FALLOCATE" != "native" && "$FALLOCATE" != "posix" ]]; then
        echo "Error: --fallocate must be none, native, or posix"
        exit 1
    fi
fi

# Validate runs parameter
if [[ ! "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
    echo "Error: --runs must be a positive integer"
    exit 1
fi

# Parse ratio for rw test
WRITE_FILES=$FILES
READ_FILES=$FILES
if [[ "$OP" == "rw" ]]; then
    # Validate and parse ratio
    if [[ ! "$RATIO" =~ ^[0-9]+:[0-9]+$ ]]; then
        echo "Error: --ratio must be in format W:R (e.g., 1:2)"
        exit 1
    fi

    # Extract write and read parts
    WRITE_PART=$(echo "$RATIO" | cut -d':' -f1)
    READ_PART=$(echo "$RATIO" | cut -d':' -f2)

    # Calculate actual file counts based on FILES as the base unit
    # FILES represents the base count, ratio determines the multipliers
    WRITE_FILES=$((FILES * WRITE_PART))
    READ_FILES=$((FILES * READ_PART))
fi

# Create directory if it doesn't exist
mkdir -p "$DIR"

# Capture system parameters
HOSTNAME=$(hostname -s)
SCOUTAM_VERSION=$(rpm -q scoutam 2>/dev/null || echo "not installed")
SCOUTFS_VERSION=$(rpm -q kmod-scoutfs 2>/dev/null || echo "not installed")
SCOUTAM_STATE=$(systemctl status scoutam 2>/dev/null | grep Active | awk '{print $2}')

# If ScoutAM is active, get additional parameters
if [[ "$SCOUTAM_STATE" == "active" ]]; then
    SCHEDULER=$(sudo samcli system 2>/dev/null | grep 'scheduler name' | awk '{print $4}')
    ARCH_AGE=$(sudo samcli config fs 2>/dev/null | grep 'Arch Age' | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
    ACCT_AGE=$(sudo samcli config fs 2>/dev/null | grep 'Acct Age' | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
    DEMAND_BACKOFF=$(sudo samcli debug stager 2>/dev/null | grep 'Demand Stage Backoff' | awk '{print $4}')
else
    SCHEDULER="unknown"
    ARCH_AGE="unknown"
    ACCT_AGE="unknown"
    DEMAND_BACKOFF="unknown"
fi

# Set defaults if values are empty
SCOUTAM_STATE=${SCOUTAM_STATE:-"unknown"}
SCHEDULER=${SCHEDULER:-"unknown"}
ARCH_AGE=${ARCH_AGE:-"unknown"}
ACCT_AGE=${ACCT_AGE:-"unknown"}
DEMAND_BACKOFF=${DEMAND_BACKOFF:-"unknown"}

# Function to drop caches
drop_caches() {
    if [[ $DROP_CACHES -eq 1 ]]; then
        echo "Dropping caches..."
        if [[ $UID -eq 0 ]]; then
            # Running as root, no sudo needed
            sh -c "echo 3 > /proc/sys/vm/drop_caches"
        else
            # Not root, use sudo
            sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"
        fi
        if [[ $? -ne 0 ]]; then
            echo "Warning: Failed to drop caches (may need sudo permissions)"
        else
            # Ensure the cache drop completes
            sync
            sleep 1
        fi
    fi
}

# Function to create read files
create_read_files() {
    local num_files=${1:-$FILES}  # Use parameter or default to FILES

    # Check if read files already exist
    local files_exist=1
    local i
    for i in $(seq 0 $((num_files - 1))); do
        if [[ ! -f "$DIR/readfile.$i" ]]; then
            files_exist=0
            break
        fi
    done

    if [[ $files_exist -eq 1 ]]; then
        return
    fi

    echo "Setting up $num_files test files..."
    local precreate_time=$(echo "$TIME * 1.5" | bc)

    cat > /tmp/fio_precreate_$$.fio << EOF
[global]
directory=$DIR
size=$SIZE
direct=0
${FALLOCATE:+fallocate=$FALLOCATE}
time_based
runtime=${precreate_time}
ioengine=libaio
group_reporting=1

[precreate_files]
rw=write
bs=$BS
numjobs=$num_files
filename_format=readfile.\$jobnum
EOF

    fio /tmp/fio_precreate_$$.fio > /dev/null 2>&1
    rm -f /tmp/fio_precreate_$$.fio
}

# Arrays to store results from multiple runs
declare -a READ_RESULTS
declare -a WRITE_RESULTS

# Function to run a single test
run_single_test() {
    local run_num=$1

    if [[ $RUNS -gt 1 ]]; then
        echo "Running test $run_num of $RUNS..."
    fi

    case $OP in
        wr)
            if [[ $run_num -eq 1 ]]; then
                echo "Setting up $FILES test files..."
            fi
            cat > /tmp/fio_test_$$.fio << EOF
[global]
directory=$DIR
size=$SIZE
direct=0
${FALLOCATE:+fallocate=$FALLOCATE}
time_based
runtime=$TIME
ioengine=libaio
group_reporting=1

[write_test]
rw=write
${WRATE:+rate=$WRATE}
bs=$BS
numjobs=$FILES
filename_format=writefile.\$jobnum
EOF

            drop_caches
            echo "Running test..."
            FIO_OUTPUT=$(fio /tmp/fio_test_$$.fio 2>&1)
            ;;

        rd)
            # First create the files to read
            if [[ $run_num -eq 1 ]]; then
                create_read_files
            fi

            cat > /tmp/fio_test_$$.fio << EOF
[global]
directory=$DIR
size=$SIZE
direct=0
${FALLOCATE:+fallocate=$FALLOCATE}
time_based
runtime=$TIME
ioengine=libaio
group_reporting=1

[read_test]
rw=read
${RRATE:+rate=$RRATE}
bs=$BS
numjobs=$FILES
filename_format=readfile.\$jobnum
EOF

            drop_caches
            echo "Running test..."
            FIO_OUTPUT=$(fio /tmp/fio_test_$$.fio 2>&1)
            ;;

        rw)
            # First create the files to read
            if [[ $run_num -eq 1 ]]; then
                create_read_files $READ_FILES
            fi

            cat > /tmp/fio_test_$$.fio << EOF
[global]
directory=$DIR
size=$SIZE
direct=0
${FALLOCATE:+fallocate=$FALLOCATE}
time_based
runtime=$TIME
ioengine=libaio
group_reporting=1

[read_test]
rw=read
${RRATE:+rate=$RRATE}
bs=$BS
numjobs=$READ_FILES
filename_format=readfile.\$jobnum
new_group

[write_test]
rw=write
${WRATE:+rate=$WRATE}
bs=$BS
numjobs=$WRITE_FILES
filename_format=writefile.\$jobnum
EOF

            drop_caches
            echo "Running test..."
            FIO_OUTPUT=$(fio /tmp/fio_test_$$.fio 2>&1)
            ;;
    esac

    # Store results for this run
    if [[ -n "$FIO_OUTPUT" ]]; then
        READ_LINE=$(echo "$FIO_OUTPUT" | grep "^ *READ:" | sed 's/^ *//')
        WRITE_LINE=$(echo "$FIO_OUTPUT" | grep "^ *WRITE:" | sed 's/^ *//')

        if [[ -n "$READ_LINE" ]]; then
            READ_RESULTS[$run_num]="$READ_LINE"
        fi
        if [[ -n "$WRITE_LINE" ]]; then
            WRITE_RESULTS[$run_num]="$WRITE_LINE"
        fi
    else
        echo "  Warning: No FIO output captured for run $run_num"
    fi

    # Clean up temporary job file
    rm -f /tmp/fio_test_$$.fio
}

# Function to remove only write files (for between runs)
remove_write_files() {
    if [[ $REMOVE -eq 1 && $RUNS -gt 1 ]]; then
        local write_pattern="$DIR/writefile.*"
        local write_count=$(ls $write_pattern 2>/dev/null | wc -l)
        if [[ $write_count -gt 0 ]]; then
            rm -f $write_pattern
            echo "  Removed $write_count write files for next run"
        fi
    fi
}

# Main execution loop
for ((i=1; i<=RUNS; i++)); do

    if [[ $RUNS -gt 1 && $i -gt 1 ]]; then
        echo ""  # Add blank line between runs for clarity
    fi
    run_single_test $i

    # Remove write files between runs (but not after the last run)
    if [[ $i -lt $RUNS ]]; then
        remove_write_files
    fi
done

# Function to extract performance metrics and output CSV
print_csv() {
    # Print CSV header
    if [[ $RUNS -gt 1 ]]; then
        echo "run,hostname,scoutam_version,scoutfs_version,scoutam_state,scheduler,arch_age,acct_age,demand_backoff,operation,directory,base_files,write_read_ratio,write_files,read_files,total_files,size,block_size,duration,file_allocation,read_rate_limit,write_rate_limit,cache_drop,read_gib_sec,read_gb_sec,write_gib_sec,write_gb_sec"
    else
        echo "hostname,scoutam_version,scoutfs_version,scoutam_state,scheduler,arch_age,acct_age,demand_backoff,operation,directory,base_files,write_read_ratio,write_files,read_files,total_files,size,block_size,duration,file_allocation,read_rate_limit,write_rate_limit,cache_drop,read_gib_sec,read_gb_sec,write_gib_sec,write_gb_sec"
    fi

    # Process each run
    for ((run=1; run<=RUNS; run++)); do
        local read_gib_sec="0"
        local read_gb_sec="0"
        local write_gib_sec="0"
        local write_gb_sec="0"

        # Extract performance metrics for this run
        if [[ -n "${READ_RESULTS[$run]}" || -n "${WRITE_RESULTS[$run]}" ]]; then
            # Extract READ line if present
            if [[ -n "${READ_RESULTS[$run]}" ]]; then
                # Extract bandwidth value - looking for pattern like "bw=123MiB/s" or "bw=1.23GiB/s"
                read_bw=$(echo "${READ_RESULTS[$run]}" | grep -oP 'bw=\K[0-9.]+[KMG]i?B/s' | head -1)
                if [[ -n "$read_bw" ]]; then
                    # Convert to GiB/s and GB/s
                    if [[ "$read_bw" =~ ([0-9.]+)([KMG])i?B/s ]]; then
                        value="${BASH_REMATCH[1]}"
                        unit="${BASH_REMATCH[2]}"
                        is_binary=$(echo "$read_bw" | grep -q "iB" && echo "1" || echo "0")

                        # Convert to GiB/s
                        case "$unit" in
                            K) read_gib_sec=$(echo "scale=6; $value / 1048576" | bc);;
                            M) read_gib_sec=$(echo "scale=6; $value / 1024" | bc);;
                            G)
                                if [[ "$is_binary" == "1" ]]; then
                                    read_gib_sec="$value"
                                else
                                    read_gib_sec=$(echo "scale=6; $value * 0.9313226" | bc)
                                fi
                                ;;
                        esac

                        # Convert GiB/s to GB/s (1 GiB = 1.073741824 GB)
                        read_gb_sec=$(echo "scale=6; $read_gib_sec * 1.073741824" | bc)
                    fi
                fi
            fi

            # Extract WRITE line if present
            if [[ -n "${WRITE_RESULTS[$run]}" ]]; then
                # Extract bandwidth value
                write_bw=$(echo "${WRITE_RESULTS[$run]}" | grep -oP 'bw=\K[0-9.]+[KMG]i?B/s' | head -1)
                if [[ -n "$write_bw" ]]; then
                    # Convert to GiB/s and GB/s
                    if [[ "$write_bw" =~ ([0-9.]+)([KMG])i?B/s ]]; then
                        value="${BASH_REMATCH[1]}"
                        unit="${BASH_REMATCH[2]}"
                        is_binary=$(echo "$write_bw" | grep -q "iB" && echo "1" || echo "0")

                        # Convert to GiB/s
                        case "$unit" in
                            K) write_gib_sec=$(echo "scale=6; $value / 1048576" | bc);;
                            M) write_gib_sec=$(echo "scale=6; $value / 1024" | bc);;
                            G)
                                if [[ "$is_binary" == "1" ]]; then
                                    write_gib_sec="$value"
                                else
                                    write_gib_sec=$(echo "scale=6; $value * 0.9313226" | bc)
                                fi
                                ;;
                        esac

                        # Convert GiB/s to GB/s
                        write_gb_sec=$(echo "scale=6; $write_gib_sec * 1.073741824" | bc)
                    fi
                fi
            fi
        fi

        # Prepare values for CSV (handle empty values)
        local base_files="$FILES"
        local ratio="$RATIO"
        local total_files

        if [[ "$OP" == "rw" ]]; then
            total_files=$((WRITE_FILES + READ_FILES))
        else
            total_files="$FILES"
            # For non-rw operations, set appropriate file counts
            if [[ "$OP" == "wr" ]]; then
                local write_files_csv="$FILES"
                local read_files_csv="0"
            else
                local write_files_csv="0"
                local read_files_csv="$FILES"
            fi
        fi

        # Use actual values for rw operations
        if [[ "$OP" == "rw" ]]; then
            local write_files_csv="$WRITE_FILES"
            local read_files_csv="$READ_FILES"
        fi

        # Convert empty values to "none" for clarity
        local rrate_csv="${RRATE:-none}"
        local wrate_csv="${WRATE:-none}"
        local cache_drop=$([ $DROP_CACHES -eq 1 ] && echo 'yes' || echo 'no')

        # Clean up values for CSV (replace spaces with underscores)
        local arch_age_csv="${ARCH_AGE// /_}"
        local acct_age_csv="${ACCT_AGE// /_}"

        # Print CSV data for this run
        if [[ $RUNS -gt 1 ]]; then
            echo "$run,$HOSTNAME,$SCOUTAM_VERSION,$SCOUTFS_VERSION,$SCOUTAM_STATE,$SCHEDULER,$arch_age_csv,$acct_age_csv,$DEMAND_BACKOFF,$OP,$DIR,$base_files,$ratio,$write_files_csv,$read_files_csv,$total_files,$SIZE,$BS,$TIME,$FALLOCATE,$rrate_csv,$wrate_csv,$cache_drop,$read_gib_sec,$read_gb_sec,$write_gib_sec,$write_gb_sec"
        else
            echo "$HOSTNAME,$SCOUTAM_VERSION,$SCOUTFS_VERSION,$SCOUTAM_STATE,$SCHEDULER,$arch_age_csv,$acct_age_csv,$DEMAND_BACKOFF,$OP,$DIR,$base_files,$ratio,$write_files_csv,$read_files_csv,$total_files,$SIZE,$BS,$TIME,$FALLOCATE,$rrate_csv,$wrate_csv,$cache_drop,$read_gib_sec,$read_gb_sec,$write_gib_sec,$write_gb_sec"
        fi
    done
}

# Function to print summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "FIO Test Summary"
    echo "=========================================="
    echo "System Information:"
    echo "  Hostname: $HOSTNAME"
    echo "  ScoutAM Version: $SCOUTAM_VERSION"
    echo "  ScoutFS Version: $SCOUTFS_VERSION"
    echo "  ScoutAM State: $SCOUTAM_STATE"
    echo "  Scheduler: $SCHEDULER"
    echo "  Arch Age: $ARCH_AGE"
    echo "  Acct Age: $ACCT_AGE"
    echo "  Demand Stage Backoff: $DEMAND_BACKOFF"
    echo ""
    echo "Test Parameters:"
    echo "  Operation: $OP"
    echo "  Directory: $DIR"
    if [[ "$OP" == "rw" ]]; then
        echo "  Base Fil
                        es: $FILES"
        echo "  Write:Read Ratio: $RATIO"
        echo "  Write Files: $WRITE_FILES (${FILES} × ${WRITE_PART})"
        echo "  Read Files: $READ_FILES (${FILES} × ${READ_PART})"
        echo "  Total Files: $((WRITE_FILES + READ_FILES))"
    else
        echo "  Files: $FILES"
    fi
    echo "  Size: $SIZE"
    echo "  Block Size: $BS"
    echo "  Duration: $TIME seconds"
    if [[ -n "$FALLOCATE" ]]; then
        echo "  File Allocation: $FALLOCATE"
    fi
    if [[ -n "$WRATE" ]]; then
        echo "  Write Rate Limit: $WRATE"
    fi
    if [[ -n "$RRATE" ]]; then
        echo "  Read Rate Limit: $RRATE"
    fi
    echo "  Cache Drop: $([ $DROP_CACHES -eq 1 ] && echo 'Yes' || echo 'No')"
    echo ""

    # Display results for each run
    if [[ $RUNS -gt 1 ]]; then
        echo "Performance Results:"
        for ((i=1; i<=RUNS; i++)); do
            if [[ -n "${READ_RESULTS[$i]}" ]]; then
                echo "  Run $i - ${READ_RESULTS[$i]}"
            fi
            if [[ -n "${WRITE_RESULTS[$i]}" ]]; then
                echo "  Run $i - ${WRITE_RESULTS[$i]}"
            fi
        done
        echo ""

        # Calculate and display statistics for multiple runs
        echo "Performance Summary:"

        # Calculate averages, min, max for reads
        if [[ ${#READ_RESULTS[@]} -gt 0 && -n "${READ_RESULTS[1]}" ]]; then
            # Extract bandwidth values for statistics (in MiB/s)
            local read_bws=()
            local read_min_idx=1
            local read_max_idx=1
            local read_min_bw=999999999
            local read_max_bw=0
            local read_sum=0
            local read_count=0

            for ((i=1; i<=RUNS; i++)); do
                if [[ -n "${READ_RESULTS[$i]}" ]]; then
                    # Extract bandwidth value and unit (e.g., "4320MiB/s" -> "4320" and "MiB")
                    local bw_str=$(echo "${READ_RESULTS[$i]}" | grep -oP 'bw=\K[0-9.]+[KMG]i?B/s' | head -1)
                    if [[ "$bw_str" =~ ([0-9.]+)([KMG])i?B/s ]]; then
                        local value="${BASH_REMATCH[1]}"
                        local unit="${BASH_REMATCH[2]}"

                        # Convert to MiB/s for comparison
                        local bw_mib
                        case "$unit" in
                            K) bw_mib=$(echo "scale=2; $value / 1024" | bc);;
                            M) bw_mib="$value";;
                            G) bw_mib=$(echo "scale=2; $value * 1024" | bc);;
                        esac

                        read_bws[$i]="$bw_mib"
                        read_sum=$(echo "$read_sum + $bw_mib" | bc)
                        read_count=$((read_count + 1))

                        # Find min/max
                        if (( $(echo "$bw_mib < $read_min_bw" | bc -l) )); then
                            read_min_bw="$bw_mib"
                            read_min_idx=$i
                        fi
                        if (( $(echo "$bw_mib > $read_max_bw" | bc -l) )); then
                            read_max_bw="$bw_mib"
                            read_max_idx=$i
                        fi
                    fi
                fi
            done

            if [[ $read_count -gt 0 ]]; then
                local read_avg=$(echo "scale=2; $read_sum / $read_count" | bc)
                local read_avg_mb=$(echo "scale=2; $read_avg * 1.048576" | bc)
                # Extract just the bandwidth part from min/max results
                local read_min_bw=$(echo "${READ_RESULTS[$read_min_idx]}" | grep -oP 'bw=\K[0-9.]+[KMG]i?B/s\s*\([0-9.]+[KMG]B/s\)' | head -1)
                local read_max_bw=$(echo "${READ_RESULTS[$read_max_idx]}" | grep -oP 'bw=\K[0-9.]+[KMG]i?B/s\s*\([0-9.]+[KMG]B/s\)' | head -1)
                echo "  Average - READ: bw=${read_avg}MiB/s (${read_avg_mb}MB/s)"
                echo "  Minimum - READ: bw=${read_min_bw}"
                echo "  Maximum - READ: bw=${read_max_bw}"
            fi
        fi

        # Calculate averages, min, max for writes
        if [[ ${#WRITE_RESULTS[@]} -gt 0 && -n "${WRITE_RESULTS[1]}" ]]; then
            # Extract bandwidth values for statistics (in MiB/s)
            local write_bws=()
            local write_min_idx=1
            local write_max_idx=1
            local write_min_bw=999999999
            local write_max_bw=0
            local write_sum=0
            local write_count=0

            for ((i=1; i<=RUNS; i++)); do
                if [[ -n "${WRITE_RESULTS[$i]}" ]]; then
                    # Extract bandwidth value and unit
                    local bw_str=$(echo "${WRITE_RESULTS[$i]}" | grep -oP 'bw=\K[0-9.]+[KMG]i?B/s' | head -1)
                    if [[ "$bw_str" =~ ([0-9.]+)([KMG])i?B/s ]]; then
                        local value="${BASH_REMATCH[1]}"
                        local unit="${BASH_REMATCH[2]}"

                        # Convert to MiB/s for comparison
                        local bw_mib
                        case "$unit" in
                            K) bw_mib=$(echo "scale=2; $value / 1024" | bc);;
                            M) bw_mib="$value";;
                            G) bw_mib=$(echo "scale=2; $value * 1024" | bc);;
                        esac

                        write_bws[$i]="$bw_mib"
                        write_sum=$(echo "$write_sum + $bw_mib" | bc)
                        write_count=$((write_count + 1))

                        # Find min/max
                        if (( $(echo "$bw_mib < $write_min_bw" | bc -l) )); then
                            write_min_bw="$bw_mib"
                            write_min_idx=$i
                        fi
                        if (( $(echo "$bw_mib > $write_max_bw" | bc -l) )); then
                            write_max_bw="$bw_mib"
                            write_max_idx=$i
                        fi
                    fi
                fi
            done

            if [[ $write_count -gt 0 ]]; then
                local write_avg=$(echo "scale=2; $write_sum / $write_count" | bc)
                local write_avg_mb=$(echo "scale=2; $write_avg * 1.048576" | bc)
                # Extract just the bandwidth part from min/max results
                local write_min_bw=$(echo "${WRITE_RESULTS[$write_min_idx]}" | grep -oP 'bw=\K[0-9.]+[KMG]i?B/s\s*\([0-9.]+[KMG]B/s\)' | head -1)
                local write_max_bw=$(echo "${WRITE_RESULTS[$write_max_idx]}" | grep -oP 'bw=\K[0-9.]+[KMG]i?B/s\s*\([0-9.]+[KMG]B/s\)' | head -1)
                echo "  Average - WRITE: bw=${write_avg}MiB/s (${write_avg_mb}MB/s)"
                echo "  Minimum - WRITE: bw=${write_min_bw}"
                echo "  Maximum - WRITE: bw=${write_max_bw}"
            fi
        fi
    else
        # Single run - display results as before
        if [[ ${#READ_RESULTS[@]} -gt 0 && -n "${READ_RESULTS[1]}" ]]; then
            echo "Performance Results:"
            if [[ -n "${READ_RESULTS[1]}" ]]; then
                echo "  ${READ_RESULTS[1]}"
            fi
            if [[ -n "${WRITE_RESULTS[1]}" ]]; then
                echo "  ${WRITE_RESULTS[1]}"
            fi
        fi
    fi
    echo "=========================================="
}

# Function to remove test files
remove_test_files() {
    if [[ $REMOVE -eq 1 ]]; then
        echo "Removing test files..."

        # Remove write files
        local write_pattern="$DIR/writefile.*"
        local write_count=$(ls $write_pattern 2>/dev/null | wc -l)
        if [[ $write_count -gt 0 ]]; then
            rm -f $write_pattern
            echo "  Removed $write_count write files"
        fi

        # Remove read files
        local read_pattern="$DIR/readfile.*"
        local read_count=$(ls $read_pattern 2>/dev/null | wc -l)
        if [[ $read_count -gt 0 ]]; then
            rm -f $read_pattern
            echo "  Removed $read_count read files"
        fi

        if [[ $write_count -eq 0 && $read_count -eq 0 ]]; then
            echo "  No test files found to remove"
        else
            echo "Test file cleanup complete"
        fi
    fi
}

# Output results based on format selected
if [[ $CSV -eq 1 ]]; then
    print_csv
else
    print_summary
fi

# Clean up test files if requested
remove_test_files
