# SPDX-License-Identifier: GPL-2.0
TESTS         += string
ORACLE_string := lib/string.c
FSRC_string   := src/lib/fk_string.f90
DRV_string    := tests/lib/test_string.c

# src/lib/fk_string_abi.f90 is deliberately NOT in FSRC_string: it defines the
# compiler-facing memset/memcpy/memmove/memcmp, which are exactly the symbols
# the oracle object defines, so linking both would be a duplicate definition.
#
# HOW ONLY FOUR FUNCTIONS GET COMPILED. lib/string.c wraps nearly every
# function in `#ifndef __HAVE_ARCH_<NAME>` so an architecture can supply its
# own; arch/x86/include/asm/string_64.h does precisely that. Defining every
# guard EXCEPT the four under test uses the kernel's own override mechanism to
# select them, and leaves their bodies untouched. Four functions are not
# guarded at all -- sized_strscpy, stpcpy, strnchrnul, memchr_inv -- so they
# still compile; tests/shims/string carries what they need to do so.
#
# -ffreestanding is what lib/Makefile itself sets for string.o: without it gcc
# rewrites memset's and memcpy's byte loops into calls to memset and memcpy,
# i.e. into calls to themselves.
#
# The two CONFIGs are the ones arch/x86/Kconfig selects that reach the code
# under test: CONFIG_HAVE_EFFICIENT_UNALIGNED_ACCESS turns on memcmp's
# word-at-a-time fast path (arch/x86/Kconfig:238), and CONFIG_64BIT picks the
# 64-bit half of the word-at-a-time helpers. Anything narrower would diff
# against a memcmp x86-64 never builds.
#
# -include linux/kconfig.h mirrors KBUILD_CPPFLAGS in the kernel's top-level
# Makefile, which is how IS_ENABLED() reaches every .c file in the tree.
CFLAGS_string := -Itests/shims/string -ffreestanding \
                 -include linux/kconfig.h \
                 -DCONFIG_64BIT -DCONFIG_HAVE_EFFICIENT_UNALIGNED_ACCESS \
                 -D__HAVE_ARCH_STRNCASECMP -D__HAVE_ARCH_STRCASECMP \
                 -D__HAVE_ARCH_STRCPY -D__HAVE_ARCH_STRNCPY \
                 -D__HAVE_ARCH_STRCAT -D__HAVE_ARCH_STRNCAT \
                 -D__HAVE_ARCH_STRLCAT -D__HAVE_ARCH_STRCMP \
                 -D__HAVE_ARCH_STRNCMP -D__HAVE_ARCH_STRCHR \
                 -D__HAVE_ARCH_STRCHRNUL -D__HAVE_ARCH_STRRCHR \
                 -D__HAVE_ARCH_STRNCHR -D__HAVE_ARCH_STRLEN \
                 -D__HAVE_ARCH_STRNLEN -D__HAVE_ARCH_STRSPN \
                 -D__HAVE_ARCH_STRCSPN -D__HAVE_ARCH_STRPBRK \
                 -D__HAVE_ARCH_STRSEP -D__HAVE_ARCH_MEMSET16 \
                 -D__HAVE_ARCH_MEMSET32 -D__HAVE_ARCH_MEMSET64 \
                 -D__HAVE_ARCH_BCMP -D__HAVE_ARCH_MEMSCAN \
                 -D__HAVE_ARCH_STRSTR -D__HAVE_ARCH_STRNSTR \
                 -D__HAVE_ARCH_MEMCHR
