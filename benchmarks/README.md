## Introduction ##

This collection of benchmarking scripts can be used to test various aspects of ScoutAM systems. The current focus is device performance for ScoutFS filesystems.

> [!CAUTION]
> The benchmarks described in this document are destructive to data/metadata previously written to devices.
>
> DO NOT RUN THESE BENCHMARKS ON PRODUCTION SYSTEMS WITHOUT EXTREME CAUTION!

## FIO I/O Benchmarks ##

The `fio` utility is a filesystem and device benchmark utility used to test raw device and filesystem performance.

### Install `fio` ###

The `fio` utility is available from the base RHEL repo and can be installed using `yum`:

```Shell
yum install -y fio
```

### Metadata Device Benchmark - `fio_gen_meta.sh` ###

The `fio_gen_meta.sh` script can measure the IOPS of metadata devices intended for ScoutFS metadata storage.

Usage:

```bash
./fio_gen_meta.sh DEVICE JOBS OPERATION
```

The `DEVICE` parameter can be a system disk such as `/dev/sdX`, a multipath device such as `/dev/mapper/3600c0ff000f7f2d55e16976401000000`, and MDRAID devices such as `/dev/md/scoutfs_meta`. It is often helpful to run benchmarks at the lowest level device before moving up the stack to validate performance scales as expected.

The `JOBS` parameter is the number of simultaneous `OPERATION` to run against the target `DEVICE`. Where `OPERATION` is either `write` or `read`.

The following example runs multiple operations with `1` or `4` jobs:

```bash
./fio_gen_meta.sh /dev/md/scoutfs_meta 1 write
./fio_gen_meta.sh /dev/md/scoutfs_meta 4 write
./fio_gen_meta.sh /dev/md/scoutfs_meta 1 read
./fio_gen_meta.sh /dev/md/scoutfs_meta 4 read
```

The output of the script will provide the IOPS per job as well as the total throughput.

```
SUMMARY:
  write: IOPS=5965, BW=373MiB/s (391MB/s)(10.9GiB/30001msec)
  write: IOPS=5800, BW=363MiB/s (380MB/s)(10.6GiB/30001msec)
  write: IOPS=5966, BW=373MiB/s (391MB/s)(10.9GiB/30001msec)
  write: IOPS=5926, BW=370MiB/s (388MB/s)(10.9GiB/30001msec)
  WRITE: bw=1479MiB/s (1550MB/s), 363MiB/s-373MiB/s (380MB/s-391MB/s), io=43.3GiB (46.5GB), run=30001-30001msec
```

#### Interpreting Results ####

While the benchmark returns bandwidth results, the IOPS numbers from each job run are the most important results. Generally, for ScoutFS metadata devices, IOPS rates for both writes and reads should be several thousand, as shown in the above example results. While the results do not directly translate to filesystem operations such as file creates, since ScoutFS batches metadata I/O requests in 64 KB chunks, the results provide insight into the capabilities of the devices.

### Data Device Benchmark - `fio_gen.sh` ###

The `fio_gen.sh` script measures the throughput of data devices intended for ScoutFS data storage.

Usage:

```bash
./fio_gen.sh DEVICE JOBS OPERATION
```

The parameters are identical to the `fio_gen_meta.sh` script.

Example running different scenarios for write and read with `1` and `4` jobs:

```bash
./fio_gen.sh /dev/md/scoutfs_data 1 write
./fio_gen.sh /dev/md/scoutfs_data 4 write
./fio_gen.sh /dev/md/scoutfs_data 1 read
./fio_gen.sh /dev/md/scoutfs_data 4 read
```

The output of the script is identical to the `fio_gen_meta.sh` script, but the more important results are the read and write bandwidth numbers at the bottom:

```
SUMMARY:
  write: IOPS=3142, BW=3143MiB/s (3295MB/s)(92.1GiB/30005msec)
  write: IOPS=3142, BW=3143MiB/s (3296MB/s)(92.1GiB/30005msec)
  write: IOPS=3142, BW=3143MiB/s (3295MB/s)(92.1GiB/30005msec)
  write: IOPS=3143, BW=3143MiB/s (3296MB/s)(92.1GiB/30004msec)
  WRITE: bw=12.3GiB/s (13.2GB/s), 3143MiB/s-3143MiB/s (3295MB/s-3296MB/s), io=368GiB (396GB), run=30004-30005msec
```

#### Suggested Runs ####

1. Get a baseline of a single job for write and read
  - `./fio_gen.sh /dev/md/scoutfs_data 1 write`
  - `./fio_gen.sh /dev/md/scoutfs_data 1 read`
2. Increase the number of jobs to match the number of tape drives and/or expected incoming streams
  - `./fio_gen.sh /dev/md/scoutfs_data 4 write`
  - `./fio_gen.sh /dev/md/scoutfs_data 4 read`

#### Interpreting Results ####

The most important number from the `fio_gen.sh` script is the last line that provides the total bandwidth for reads or writes. While no target bandwidth number is required for ScoutFS, the most important aspect to consider is what the filesystem will be required to do. For example, if your workload ingests data at about 1 GB/sec and creates two copies of data, then your storage should minimally be able to write at 1 GB/sec and read at 2 GB/sec to achieve the desired overall throughput. Since filesystems put an overhead on devices, ideally, the results for raw devices will be higher than the required target performance.
