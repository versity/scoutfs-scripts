#!/bin/bash

# Function to calculate evenly distributed offsets
calculate_offsets() {
    local num_jobs=$1
    local device_size=$2
    local offsets=()
    local step=$((device_size / num_jobs))
    
    for ((i=0; i<num_jobs; i++)); do
        offsets+=($((i * step)))
    done
    
    echo "${offsets[@]}"
}

# Function to generate FIO configuration file
generate_fio_config() {
    local device=$1
    local num_jobs=$2
    local rw=$3
    local offsets=("${!4}")

    cat <<EOF > test.fio
[global]
direct=1
rw=$rw
bs=1024k
ioengine=libaio
iodepth=16
runtime=30
numjobs=1
time_based
per_job_logs=1
EOF

    for ((i=0; i<num_jobs; i++)); do
        cat <<EOF >> test.fio
[job$i]
filename=$device
offset=${offsets[i]}
EOF
    done
}

# Main script

# Parse command-line argument for number of jobs
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <device> <num_jobs> <read|write>"
    exit 1
fi

DEVICE="$1"
NUM_JOBS="$2"
RW="$3"

# Get the size of the device in bytes
DEVICE_SIZE=$(blockdev --getsize64 "$DEVICE")

# Calculate evenly distributed offsets
OFFSET_ARRAY=($(calculate_offsets "$NUM_JOBS" "$DEVICE_SIZE"))

# Generate FIO configuration file with evenly distributed offsets
generate_fio_config "$DEVICE" "$NUM_JOBS" "$RW" OFFSET_ARRAY[@]

# Run FIO test with the generated configuration file
fio test.fio | tee test.fio.log
echo
echo "SUMMARY:"
grep -i "$RW:" test.fio.log

