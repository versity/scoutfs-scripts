# default to /usr - there's no reason for /usr/local to be the default here.
ifeq ($(PREFIX),)
	PREFIX := /usr
endif
ifeq ($(LIBEXEC),)
	LIBEXEC := libexec
endif
ifeq ($(SYSCONFDIR),)
	SYSCONFDIR := /etc
endif

SCOUTFS_FENCED_RUN_DIR := ${PREFIX}/$(LIBEXEC)/scoutfs-fenced/run

all:
	# nop

check:
	shellcheck scoutfs-fence-agent

install:
	install -d $(DESTDIR)$(SCOUTFS_FENCED_RUN_DIR)
	install -m0755 scoutfs-fence-agent $(DESTDIR)$(SCOUTFS_FENCED_RUN_DIR)/
	install -d $(DESTDIR)$(SYSCONFDIR)/scoutfs
	echo "SCOUTFS_FENCED_RUN=${PREFIX}/$(LIBEXEC)/scoutfs-fenced/run/scoutfs-fence-agent" | tee -a $(DESTDIR)$(SYSCONFDIR)/scoutfs/scoutfs-fenced.conf
