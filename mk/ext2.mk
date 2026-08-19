# SPDX-License-Identifier: GPL-2.0
TESTS      += ext2
# ORDER IS SEMANTIC, as everywhere in mk/: fk_ext2 USEs all four of the modules
# above it, and gfortran cannot compile a USE until the .mod exists.
FSRC_ext2  := src/fs/fk_vfs_types.f90 src/lib/fk_string.f90 src/fs/fk_vfs.f90 \
              src/fs/fk_blkdev.f90 src/fs/fk_ext2_types.f90 src/fs/fk_ext2.f90
DRV_ext2   := tests/fs/test_ext2.c
CFLAGS_ext2 := -I$(BUILD)

# NO ORACLE_ext2, and it would be the wrong shape if there were one.  Linux's
# fs/ext2 is a super_block, a folio cache and an inode allocator; there is no
# standalone function that turns a path into an inode number and could be
# linked next to this one.
#
# THE ORACLE IS e2fsprogs INSTEAD, and it is a stronger one than a linked C
# function would be.  tools/gen-ext2-oracle.sh builds the fixture with MKE2FS
# and reads the expected answers back out with DEBUGFS, neither of which shares
# a line with this tree -- so the driver is diffed against a second, independent
# implementation of the same format rather than against a model written by the
# same hand that wrote the parser.  docs/HARNESS-VALIDATION-PHASE2.md names
# that weakness ("a model and a module that share a misconception agree") and
# this is the milestone that does not have it.
#
# The LAYOUT has a separate oracle again: the same script cuts the four on-disk
# structs verbatim out of the vendor's fs/ext2/ext2.h, and the test diffs every
# offset the driver uses against offsetof over those structs.  A vendor bump
# that moves a field turns that red.  ext2.h cannot simply be included -- it
# pulls in linux/fs.h, linux/mm.h and linux/highmem.h -- which is why the
# structs are extracted rather than the header shimmed.
#
# THE GENERATED FILES ARE PREREQUISITES OF THE DRIVER OBJECT, not of the test
# run.  Makefile's own header records what happens when an object's real inputs
# are not declared: build/oracle-string.o did not depend on the fragment that
# chose its contents, the stale object linked against glibc, and a milestone
# spent a run diffing Fortran against the C library.  Here the fixture header is
# #included, so a fixture rebuilt with different contents must recompile the
# driver or the test asserts yesterday's inode numbers.
$(BUILD)/ext2-vendor.h $(BUILD)/ext2-fixture.h $(BUILD)/ext2-fixture.img &: \
                tools/gen-ext2-oracle.sh vendor/linux-7.1.8/fs/ext2/ext2.h \
                | $(BUILD)
	@bash tools/gen-ext2-oracle.sh $(BUILD)

$(BUILD)/drv-ext2.o: $(BUILD)/ext2-vendor.h $(BUILD)/ext2-fixture.h
# ORDER-ONLY, and it has to be. Makefile's generic link rule is `gcc -o $@ $^`,
# so a normal prerequisite would hand the disk image to the linker -- which is
# how this first went wrong ("file format not recognized"). The image's CONTENTS
# reach the test through ext2-fixture.h, which IS a real prerequisite above, so
# nothing is lost by making the image itself only an ordering constraint.
$(BUILD)/run-ext2: | $(BUILD)/ext2-fixture.img
