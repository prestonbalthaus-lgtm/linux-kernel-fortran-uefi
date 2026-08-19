/* SPDX-License-Identifier: GPL-2.0 */
/* Deliberately EMPTY.
 *
 * tests/fs/test_vfs.c takes its errno, mode-bit and limit constants from the
 * vendor tree's own uapi headers rather than transcribing them, and
 * uapi/linux/stat.h reaches types.h -> posix_types.h -> stddef.h -> this file.
 * Everything stddef.h wants from it is an attribute macro that only matters
 * inside the kernel build; the three headers under test are plain #defines and
 * need none of it.
 *
 * Measured: this is the entire shim set for those three headers.
 */
