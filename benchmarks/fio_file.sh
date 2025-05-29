#!/bin/bash
                
set -euo pipefail
                
BLOCK_SIZE="1024K"
IO_ENGINE="psync"
JOB_NAME="versity_bench"
TEST_DATE=$(date '+%Y%m%dT%H%M%S')
                
# Check if fio is installed
command -v fio >/dev/null || { echo "ERROR: fio not in PATH"; exit 1; }
                
# Parse command-line argument for number of jobs
if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <mount> <num_jobs> <read|write|fdx> <run_time> <size>"
    exit 1      
fi
                
MOUNT="$1"      
NUM_JOBS="$2"   
RW="$3"         
RUN_TIME="$4"   
SIZE="$5"
                
if ! [[ $NUM_JOBS =~ ^[0-9]+$ ]]; then
        echo "ERROR: num_jobs must be an integer"
        exit 1
fi

if ! [[ $RUN_TIME =~ ^[0-9]+$ ]]; then
        echo "ERROR: run_time must be an integer (seconds)"
        exit 1
fi      
        
if ! [[ "$SIZE" =~ ^[0-9]+(G|M|K|T)?$ ]]; then
  echo "ERROR: size must be a number with optional unit (e.g. 10G, 500M)"
  exit 1
fi

# Test to verify ScoutFS
df -t scoutfs "$MOUNT" > /dev/null 2>&1

BENCH_DIR="${MOUNT}/bench/${HOST}"
mkdir -p "$BENCH_DIR"

BASE_FIO_OPTIONS=(
        --ioengine "${IO_ENGINE}"
        --bs "${BLOCK_SIZE}"
        --numjobs "${NUM_JOBS}"
        --time_based
        "--iodepth=1"
        "--per_job_logs=1"
)
                
WR_JOB_NAME="${JOB_NAME}_write"
RD_JOB_NAME="${JOB_NAME}_read"

WR_RESULTS="/tmp/${HOST}.fio.wr.${TEST_DATE}.txt"
RD_RESULTS="/tmp/${HOST}.fio.rd.${TEST_DATE}.txt"
                
case "$RW" in   
        write)  
                echo "Dropping caches..."
                echo 3 > /proc/sys/vm/drop_caches
                echo "Done"
                
                fio "${BASE_FIO_OPTIONS[@]}" --name="${WR_JOB_NAME}" --rw=write --runtime="${RUN_TIME}" --size="${SIZE}" --directory="${BENCH_DIR}" >"$WR_RESULTS" 2>&1 &
                ;;
        read)
                echo "Pre-populating read files..."
                fio "${BASE_FIO_OPTIONS[@]}" --name="${RD_JOB_NAME}" --rw=write  --runtime=$((RUN_TIME + 90)) --size="${SIZE}" --directory="${BENCH_DIR}" > /dev/null 2>&1
                echo "Done"
        
                echo "Dropping caches..."
                echo 3 > /proc/sys/vm/drop_caches
                echo "Done"

                fio "${BASE_FIO_OPTIONS[@]}" --name="${RD_JOB_NAME}" --rw=read  --runtime="${RUN_TIME}" --size="${SIZE}" --directory="${BENCH_DIR}" >"$RD_RESULTS" 2>&1 &
                ;;
        fdx)
                echo "Pre-populating read files..."
                echo fio "${BASE_FIO_OPTIONS[@]}" --name="${RD_JOB_NAME}" --rw=write --runtime=$((RUN_TIME + 90)) --size="${SIZE}" --directory="${BENCH_DIR}"
                fio "${BASE_FIO_OPTIONS[@]}" --name="${RD_JOB_NAME}" --rw=write --runtime=$((RUN_TIME + 90)) --size="${SIZE}" --directory="${BENCH_DIR}" > /dev/null 2>&1
                echo "Done"

  
                echo "Dropping caches..."
                echo 3 > /proc/sys/vm/drop_caches
                echo "Done"

                echo fio "${BASE_FIO_OPTIONS[@]}" --name="${WR_JOB_NAME}" --rw=write --runtime="${RUN_TIME}" --size="${SIZE}" --directory="${BENCH_DIR}"
                echo fio "${BASE_FIO_OPTIONS[@]}" --name="${RD_JOB_NAME}" --rw=read  --runtime="${RUN_TIME}" --size="${SIZE}" --directory="${BENCH_DIR}"
                fio "${BASE_FIO_OPTIONS[@]}" --name="${WR_JOB_NAME}" --rw=write --runtime="${RUN_TIME}" --size="${SIZE}" --directory="${BENCH_DIR}" >"$WR_RESULTS" 2>&1 &
                fio "${BASE_FIO_OPTIONS[@]}" --name="${RD_JOB_NAME}" --rw=read  --runtime="${RUN_TIME}" --size="${SIZE}" --directory="${BENCH_DIR}" >"$RD_RESULTS" 2>&1 &
                ;;
        *)
                echo "Invalid mode: $RW"
                exit 1
                ;;
esac

wait

if [[ -s "$WR_RESULTS" ]]
then
        PERF=$(grep -e WRITE -e "bw=" "$WR_RESULTS")
        printf "SUMMARY: %s %s\n" "$HOST" "$PERF"
        echo "Results file: $WR_RESULTS"
fi

if [[ -s "$RD_RESULTS" ]]
then
        PERF=$(grep -e READ -e "bw=" "$RD_RESULTS")
        printf "SUMMARY: %s %s\n" "$HOST" "$PERF"
        echo "Results file: $RD_RESULTS"
fi
