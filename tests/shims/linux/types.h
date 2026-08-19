#ifndef _FK_SHIM_TYPES_H
#define _FK_SHIM_TYPES_H
#include <stdint.h>
#include <stddef.h>
typedef uint8_t  u8;   typedef int8_t  s8;
typedef uint16_t u16;  typedef int16_t s16;
typedef uint32_t u32;  typedef int32_t s32;
typedef uint64_t u64;  typedef int64_t s64;
typedef u8  __u8;  typedef u16 __u16; typedef u32 __u32; typedef u64 __u64;
typedef s8  __s8;  typedef s16 __s16; typedef s32 __s32; typedef s64 __s64;
/* The __kernel_* family, added at roadmap 6.1. tests/fs/test_vfs.c takes its
 * mode bits, errnos and limits from the vendor tree's own uapi headers rather
 * than transcribing them, and uapi/linux/stat.h and asm-generic/fcntl.h declare
 * structs in terms of these on their way to the constants. This file shadows
 * the vendor's linux/types.h for every test -- CFLAGS puts -Itests/shims first
 * -- so the typedefs have to live here rather than in tests/shims/vfs. */
typedef long          __kernel_long_t;
typedef unsigned long __kernel_ulong_t;
typedef __kernel_long_t __kernel_off_t;
typedef long long       __kernel_loff_t;
typedef int             __kernel_pid_t;
typedef __kernel_ulong_t __kernel_size_t;
typedef unsigned int    __kernel_uid32_t;
typedef unsigned int    __kernel_gid32_t;
typedef _Bool bool;
#define true 1
#define false 0
#endif
