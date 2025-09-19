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
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --op wr|rd|rw --dir PATH --files N --size SIZE --time SECONDS [--bs BLOCKSIZE] [--ratio W:R] [--wrate RATE] [--rrate RATE] [--fallocate MODE] [--drop_caches]"
            echo "  --ratio W:R : For rw test, creates N*W write files and N*R read files (default 1:1)"
            echo "  --wrate RATE : Limit write bandwidth (e.g., 100M will limit writes to 100 MB/sec)"
            echo "  --rrate RATE : Limit read bandwidth (e.g., 100M will limit read rates to 100 MB/sec)"
            echo "  --fallocate MODE : Set file allocation mode (none|native|posix, default: native)"
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$OP" || -z "$DIR" || -z "$FILES" || -z "$SIZE" || -z "$TIME" ]]; then
    echo "Error: Missing required parameters"
    echo "Usage: $0 --op wr|rd|rw --dir PATH --files N --size SIZE --time SECONDS [--bs BLOCKSIZE] [--ratio W:R] [--wrate RATE] [--rrate RATE] [--fallocate MODE] [--drop_caches]"
    echo "  --ratio W:R : For rw test, creates N*W write files and N*R read files (default 1:1)"
    echo "  --wrate RATE : Limit write bandwidth (e.g., 100m, 1g)"
    echo "  --rrate RATE : Limit read bandwidth (e.g., 100m, 1g)"
    echo "  --fallocate MODE : Set file allocation mode (none|native|posix, default: native)"
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
        fi
    fi
}

# Function to create read files
create_read_files() {
    local num_files=${1:-$FILES}  # Use parameter or default to FILES

    # Check if read files already exist
    local files_exist=1
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

# Main execution based on operation type
case $OP in
    wr)
        echo "Setting up $FILES test files..."
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
        create_read_files

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
        create_read_files $READ_FILES

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

# Clean up temporary job file
rm -f /tmp/fio_test_$$.fio

# Function to print summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "FIO Test Summary"
    echo "=========================================="
    echo "Test Parameters:"
    echo "  Operation: $OP"
    echo "  Directory: $DIR"
    if [[ "$OP" == "rw" ]]; then
        echo "  Base Files: $FILES"
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

    if [[ -n "$FIO_OUTPUT" ]]; then
        echo "Performance Results:"
        # Extract READ line if present
        READ_LINE=$(echo "$FIO_OUTPUT" | grep "^ *READ:" | sed 's/^ *//')
        if [[ -n "$READ_LINE" ]]; then
            echo "  $READ_LINE"
        fi

        # Extract WRITE line if present
        WRITE_LINE=$(echo "$FIO_OUTPUT" | grep "^ *WRITE:" | sed 's/^ *//')
        if [[ -n "$WRITE_LINE" ]]; then
            echo "  $WRITE_LINE"
        fi
    fi
    echo "=========================================="
}

# Call print_summary after test completion
print_summary
