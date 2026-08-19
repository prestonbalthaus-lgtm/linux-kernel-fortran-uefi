# SPDX-License-Identifier: GPL-2.0
TESTS      += vfs
FSRC_vfs   := src/fs/fk_vfs_types.f90 src/lib/fk_string.f90 src/fs/fk_vfs.f90
DRV_vfs    := tests/fs/test_vfs.c

# NO ORACLE_vfs, and the reason is mk/serial.mk's. There is no C function to
# diff a VFS scaffold against: fs/namei.c is entangled with the mount table,
# RCU, credentials and the dcache hash, and nothing standalone survives being
# pulled out of it. The path-walk semantics are diffed against a reference
# model in the test, which is exactly the weakness
# docs/HARNESS-VALIDATION-PHASE2.md names -- a model and a module that share a
# misconception agree -- and the mutation table is the evidence they do not.
#
# The CONSTANTS do have an oracle and the test includes the vendor's own
# headers instead of transcribing them: asm-generic/errno.h, linux/stat.h and
# linux/limits.h. -D__KERNEL__ is required -- uapi/linux/stat.h:7 hides the
# S_IF* block from anything with glibc 2 -- and it pulls in a chain that ends at
# linux/compiler_types.h, which tests/shims/vfs supplies empty. Measured: that
# is the whole shim set.
#
# The Fortran constants are NOT read back through accessors. They are tested
# where they are used: a 256-byte component must come back as -ENAMETOOLONG,
# the root's mode must have S_IFDIR set, opening a directory for write must be
# -EISDIR. A constant that only ever appears in an assertion about itself is
# not tested at all.
CFLAGS_vfs := -Itests/shims/vfs -Ivendor/linux-7.1.8/include/uapi -D__KERNEL__
