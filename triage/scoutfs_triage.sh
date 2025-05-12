#!/bin/bash

HOST=$(hostname -s)
DATE=$(date '+%Y%m%dT%H_%M_%S')
RUN_SOS=0

if [ ! -x /bin/trace-cmd ]
then
    echo "Please install the trace-cmd package."
fi

TRIAGE_DIR="/tmp/scoutfs.${HOST}.${DATE}"
if ! mkdir -p "$TRIAGE_DIR"; then
    echo "Failed to create $TRIAGE_DIR"
    exit 1
fi

cd "$TRIAGE_DIR"

# Capture entire sysfs tree /sys/fs/scoutfs
mkdir sysfs
cp -ar /sys/fs/scoutfs sysfs/

# Capture entire debugfs tree /sys/kernel/debug/scoutfs
tar cf debugfs.scoutfs.tar /sys/kernel/debug/scoutfs
mkdir debugfs
cp -ar /sys/kernel/debug/scoutfs debugfs/

# Capture fencing configuration
mkdir -p etc/scoutfs
cp -r /etc/scoutfs/* etc/scoutfs/
if [ -f /etc/scoutfs/scoutfs-fenced.conf ]
then
    source /etc/scoutfs/scoutfs-fenced.conf
    cp "$SCOUTFS_FENCED_RUN" etc/scoutfs
fi

# Capture dmesg before clearing ring buffer
dmesg -T > dmesg.log

# Clear dmesg ring buffer
dmesg --clear

# Capture stack traces for all stopped tasks
echo t > /proc/sysrq-trigger
dmesg -T > sysrq_t.log

# Clear dmesg ring buffer
dmesg --clear

# Capture stack traces for all running tasks
echo l > /proc/sysrq-trigger
dmesg -T > sysrq_l.log

# Capture ScoutFS trace
if [ -x /bin/trace-cmd ]; then
    trace-cmd record -e "scoutfs:*" sleep 5
    trace-cmd report | gzip -9 > scoutfs-trace.gz
    rm trace.dat
else
    touch no-trace-cmd
fi

# Gather sosreport
if [[ "$RUN_SOS" -eq 1 ]]
then
	mkdir -p sos
	sos report --tmp-dir sos --batch
fi

# See if there are any crash dumps
find /var/crash -ls > crash_ls.txt

cd /tmp
tar czf scoutfs.${HOST}.${DATE}.tar.gz scoutfs.${HOST}.${DATE}

echo ""
echo "Please upload /tmp/scoutfs.${HOST}.${DATE}.tar.gz to Versity support"
echo ""
echo "You may also remove /tmp/scoutfs.${HOST}.${DATE} directory"
echo ""
