/* Reference-model test for src/mm/fk_efi_mmap.f90.
 *
 * There is no C original to diff against -- an EFI_MEMORY_DESCRIPTOR walker is
 * a translation of the UEFI specification, the situation the PMM and the UART
 * driver were already in -- so this file carries its own model: descriptors are
 * described once as a C struct array, laid into a byte arena at a chosen
 * firmware stride, and every accessor is compared against the struct.
 *
 * THE ARENA IS POISONED, AND THAT IS THE STRIDE PROOF.  Everything a descriptor
 * does not cover -- the Pad word at offset 4, the bytes between offset 40 and
 * the firmware's stride, and the tail past the last descriptor -- is left at
 * 0xA5.  A parser that strides by sizeof(descriptor) instead of by
 * DescriptorSize therefore reads poison for every entry after the first, and
 * the same logical map is asserted identical at strides 40, 48 and 56.
 * Guard bands either side of the arena catch a write where only reads belong.
 */
#include <stdint.h>
#include <string.h>
#include "fk_test.h"

/* Both sides carry unsigned bit patterns; compare them as such, once. */
#define EQ64(what, a, b) \
	FK_EQ(what, (unsigned long long)(a), (unsigned long long)(b), "0x%llX")
#define EQ32(what, a, b) \
	FK_EQ(what, (unsigned)(a), (unsigned)(b), "0x%X")
#define EQI(what, a, b)  FK_EQ(what, (int)(a), (int)(b), "%d")

/* --- the Fortran module's bind(c) surface -------------------------------- */
int32_t fk_efi_mmap_set(const void *base, int64_t total_bytes,
			int64_t desc_size, int32_t desc_version);
int32_t fk_efi_mmap_count(void);
int64_t fk_efi_mmap_base(int32_t i);
int64_t fk_efi_mmap_pages(int32_t i);
int32_t fk_efi_mmap_type(int32_t i);
int64_t fk_efi_mmap_attr(int32_t i);
int64_t fk_efi_mmap_bytes(int32_t i);
int32_t fk_efi_type_is_ram(int32_t t);

/* --- constants, mirroring src/mm/fk_efi_mmap.f90 ------------------------- */
enum {
	EFI_OK = 0, E_BASE_NULL = 1, E_DESC_SIZE = 2, E_TOO_MANY = 3,
	E_NOT_MULTIPLE = 4, E_NO_ENTRIES = 5,
};

#define DESC_MIN	40
#define DESC_MAX	4096
#define MAX_DESC	1024
#define BAD64		0xFFFFFFFFFFFFFFFFULL
#define BAD32		0xFFFFFFFFU
#define PAGES_MAX	0x0007FFFFFFFFFFFFULL	/* 2^51 - 1 */

/* UEFI 7.2 memory types. */
enum {
	EfiReservedMemoryType = 0, EfiLoaderCode, EfiLoaderData,
	EfiBootServicesCode, EfiBootServicesData, EfiRuntimeServicesCode,
	EfiRuntimeServicesData, EfiConventionalMemory, EfiUnusableMemory,
	EfiACPIReclaimMemory, EfiACPIMemoryNVS, EfiMemoryMappedIO,
	EfiMemoryMappedIOPortSpace, EfiPalCode, EfiPersistentMemory,
	EfiUnacceptedMemoryType,
};

#define EFI_MEMORY_UC		0x0000000000000001ULL
#define EFI_MEMORY_WB		0x000000000000000FULL
#define EFI_MEMORY_RUNTIME	0x8000000000000000ULL

/* --- the guarded arena --------------------------------------------------- */
#define POISON		0xA5
#define GUARD		256
#define ARENA_CAP	262144
static uint8_t arena_mem[GUARD + ARENA_CAP + GUARD];
#define ARENA		(arena_mem + GUARD)

struct desc {
	uint32_t type;
	uint64_t phys, virt, pages, attr;
};

static void put32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void put64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }

static void arena_build(const struct desc *d, int n, size_t stride)
{
	int i;

	memset(arena_mem, POISON, sizeof arena_mem);
	for (i = 0; i < n; i++) {
		uint8_t *p = ARENA + (size_t)i * stride;

		put32(p +  0, d[i].type);
		put32(p +  4, 0xDEADBEEFU);	/* Pad: a parser must never read it */
		put64(p +  8, d[i].phys);
		put64(p + 16, d[i].virt);
		put64(p + 24, d[i].pages);
		put64(p + 32, d[i].attr);
	}
}

static void guard_check(const char *what)
{
	size_t i;
	int bad = 0;

	for (i = 0; i < GUARD; i++)
		if (arena_mem[i] != POISON ||
		    arena_mem[GUARD + ARENA_CAP + i] != POISON)
			bad = 1;
	fk_checks++;
	if (bad) {
		printf("  GUARD %s: arena guard band was modified\n", what);
		fk_fails++;
	}
}

/* --- the reference model ------------------------------------------------- */
static uint64_t ref_bytes(uint64_t pages)
{
	return pages > PAGES_MAX ? BAD64 : pages << 12;
}

static int ref_is_ram(uint32_t t) { return t == EfiConventionalMemory ? 1 : 0; }

/* Lay the map out at `stride`, latch it, and diff every accessor against the
 * struct array it was built from. */
static void check_map(const char *what, const struct desc *d, int n,
		      size_t stride)
{
	static char tag[192];
	int i;

	arena_build(d, n, stride);
	snprintf(tag, sizeof tag, "%s/%zu: set", what, stride);
	EQI(tag, EFI_OK, fk_efi_mmap_set(ARENA, (int64_t)((size_t)n * stride),
					 (int64_t)stride, 1));
	snprintf(tag, sizeof tag, "%s/%zu: count", what, stride);
	EQI(tag, n, fk_efi_mmap_count());

	for (i = 0; i < n; i++) {
		snprintf(tag, sizeof tag, "%s/%zu[%d]: base", what, stride, i);
		EQ64(tag, d[i].phys, (uint64_t)fk_efi_mmap_base(i));
		snprintf(tag, sizeof tag, "%s/%zu[%d]: pages", what, stride, i);
		EQ64(tag, d[i].pages, (uint64_t)fk_efi_mmap_pages(i));
		snprintf(tag, sizeof tag, "%s/%zu[%d]: attr", what, stride, i);
		EQ64(tag, d[i].attr, (uint64_t)fk_efi_mmap_attr(i));
		snprintf(tag, sizeof tag, "%s/%zu[%d]: type", what, stride, i);
		EQ32(tag, d[i].type, (uint32_t)fk_efi_mmap_type(i));
		snprintf(tag, sizeof tag, "%s/%zu[%d]: bytes", what, stride, i);
		EQ64(tag, ref_bytes(d[i].pages), (uint64_t)fk_efi_mmap_bytes(i));
		snprintf(tag, sizeof tag, "%s/%zu[%d]: is_ram", what, stride, i);
		EQI(tag, ref_is_ram(d[i].type),
		    fk_efi_type_is_ram(fk_efi_mmap_type(i)));
	}
	guard_check(what);
}

/* Every accessor on an index that is not in the array. */
static void check_oob_index(const char *what, int32_t i)
{
	static char tag[192];

	snprintf(tag, sizeof tag, "%s: base(%d)", what, i);
	EQ64(tag, BAD64, (uint64_t)fk_efi_mmap_base(i));
	snprintf(tag, sizeof tag, "%s: pages(%d)", what, i);
	EQ64(tag, BAD64, (uint64_t)fk_efi_mmap_pages(i));
	snprintf(tag, sizeof tag, "%s: attr(%d)", what, i);
	EQ64(tag, BAD64, (uint64_t)fk_efi_mmap_attr(i));
	snprintf(tag, sizeof tag, "%s: bytes(%d)", what, i);
	EQ64(tag, BAD64, (uint64_t)fk_efi_mmap_bytes(i));
	snprintf(tag, sizeof tag, "%s: type(%d)", what, i);
	EQ32(tag, BAD32, (uint32_t)fk_efi_mmap_type(i));
}

/* A real-shaped OVMF map: a fragmented low megabyte, the loader's own images,
 * boot services either side of them, ACPI, runtime services carrying
 * EFI_MEMORY_RUNTIME in bit 63, an MMIO aperture and RAM above 4 GiB. */
static const struct desc ovmf[] = {
{ EfiConventionalMemory,      0x0000000000000000ULL, 0, 0x00000080ULL, EFI_MEMORY_WB },
{ EfiBootServicesData,        0x0000000000080000ULL, 0, 0x00000020ULL, EFI_MEMORY_WB },
{ EfiReservedMemoryType,      0x00000000000A0000ULL, 0, 0x00000060ULL, EFI_MEMORY_UC },
{ EfiConventionalMemory,      0x0000000000100000ULL, 0, 0x00000700ULL, EFI_MEMORY_WB },
{ EfiLoaderData,              0x0000000000800000ULL, 0, 0x00000100ULL, EFI_MEMORY_WB },
{ EfiLoaderCode,              0x0000000000900000ULL, 0, 0x00000080ULL, EFI_MEMORY_WB },
{ EfiBootServicesCode,        0x0000000000980000ULL, 0, 0x00000040ULL, EFI_MEMORY_WB },
{ EfiConventionalMemory,      0x00000000009C0000ULL, 0, 0x0007E400ULL, EFI_MEMORY_WB },
{ EfiACPIReclaimMemory,       0x000000007F000000ULL, 0, 0x00000100ULL, EFI_MEMORY_WB },
{ EfiACPIMemoryNVS,           0x000000007F100000ULL, 0, 0x00000100ULL, EFI_MEMORY_WB },
{ EfiRuntimeServicesData,     0x000000007F200000ULL, 0, 0x00000100ULL, EFI_MEMORY_RUNTIME | EFI_MEMORY_WB },
{ EfiRuntimeServicesCode,     0x000000007F300000ULL, 0, 0x00000100ULL, EFI_MEMORY_RUNTIME | EFI_MEMORY_WB },
{ EfiUnusableMemory,          0x000000007F400000ULL, 0, 0x00000010ULL, EFI_MEMORY_WB },
{ EfiPersistentMemory,        0x000000007F500000ULL, 0, 0x00000080ULL, EFI_MEMORY_WB },
{ EfiMemoryMappedIO,          0x00000000E0000000ULL, 0, 0x00010000ULL, EFI_MEMORY_RUNTIME | EFI_MEMORY_UC },
{ EfiMemoryMappedIOPortSpace, 0x0000000000000000ULL, 0, 0x00000000ULL, 0 },
{ EfiPalCode,                 0x00000000FFFF0000ULL, 0, 0x00000010ULL, EFI_MEMORY_WB },
{ EfiUnacceptedMemoryType,    0x00000000FFFF8000ULL, 0, 0x00000008ULL, EFI_MEMORY_WB },
{ EfiConventionalMemory,      0x0000000100000000ULL, 0, 0x00080000ULL, EFI_MEMORY_WB },
};
#define OVMF_N ((int)(sizeof ovmf / sizeof ovmf[0]))

/* Addresses and lengths a signed comparison or a wrapping multiply gets wrong. */
static const struct desc extreme[] = {
{ EfiConventionalMemory, 0x8000000000000000ULL, 0, 0x0000000000000010ULL, EFI_MEMORY_RUNTIME },
{ EfiConventionalMemory, 0xFFFFFFFFFFFFF000ULL, 0, 0x0000000000000001ULL, 0xFFFFFFFFFFFFFFFFULL },
{ EfiReservedMemoryType, 0xDEADBEEF00000000ULL, 0, 0x00000000FFFFFFFFULL, 0x00000000FFFFFFFFULL },
{ EfiConventionalMemory, 0x0000000000001000ULL, 0, PAGES_MAX,             0 },
{ EfiConventionalMemory, 0x0000000000002000ULL, 0, PAGES_MAX + 1,         0 },
{ EfiConventionalMemory, 0x0000000000003000ULL, 0, 0x0010000000000000ULL, 0 },
{ EfiConventionalMemory, 0x0000000000004000ULL, 0, 0x8000000000000000ULL, 0 },
{ EfiConventionalMemory, 0x0000000000005000ULL, 0, 0xFFFFFFFFFFFFFFFFULL, 0 },
};
#define EXTREME_N ((int)(sizeof extreme / sizeof extreme[0]))

/* The same logical map at three firmware strides must parse identically. */
static void stride_proof(const struct desc *d, int n)
{
	static const size_t strides[] = { 40, 48, 56 };
	static uint64_t g_base[64], g_pages[64], g_attr[64], g_bytes[64];
	static uint32_t g_type[64];
	static char tag[192];
	size_t s;
	int i;

	for (s = 0; s < sizeof strides / sizeof strides[0]; s++) {
		check_map("stride", d, n, strides[s]);
		for (i = 0; i < n; i++) {
			if (s == 0) {
				g_base[i]  = (uint64_t)fk_efi_mmap_base(i);
				g_pages[i] = (uint64_t)fk_efi_mmap_pages(i);
				g_attr[i]  = (uint64_t)fk_efi_mmap_attr(i);
				g_bytes[i] = (uint64_t)fk_efi_mmap_bytes(i);
				g_type[i]  = (uint32_t)fk_efi_mmap_type(i);
				continue;
			}
			snprintf(tag, sizeof tag,
				 "stride 40 vs %zu [%d]: base", strides[s], i);
			EQ64(tag, g_base[i], (uint64_t)fk_efi_mmap_base(i));
			snprintf(tag, sizeof tag,
				 "stride 40 vs %zu [%d]: pages", strides[s], i);
			EQ64(tag, g_pages[i], (uint64_t)fk_efi_mmap_pages(i));
			snprintf(tag, sizeof tag,
				 "stride 40 vs %zu [%d]: attr", strides[s], i);
			EQ64(tag, g_attr[i], (uint64_t)fk_efi_mmap_attr(i));
			snprintf(tag, sizeof tag,
				 "stride 40 vs %zu [%d]: bytes", strides[s], i);
			EQ64(tag, g_bytes[i], (uint64_t)fk_efi_mmap_bytes(i));
			snprintf(tag, sizeof tag,
				 "stride 40 vs %zu [%d]: type", strides[s], i);
			EQ32(tag, g_type[i], (uint32_t)fk_efi_mmap_type(i));
		}
	}
}

int main(void)
{
	static struct desc many[MAX_DESC + 1];
	int i;

	/* (1) Nothing latched yet: every accessor answers its sentinel rather
	 * than dereferencing a null pointer. Must run first -- the module's
	 * state is process-global from here on. */
	EQI("cold: count", 0, fk_efi_mmap_count());
	check_oob_index("cold", 0);
	check_oob_index("cold", 1);

	/* (2) The stride proof, on the OVMF-shaped map and on the extreme one. */
	stride_proof(ovmf, OVMF_N);
	stride_proof(extreme, EXTREME_N);

	/* (2b) The 40-stride trap is armed: at stride 48 the bytes a walker with
	 * a hardcoded 40 would read for descriptor 1 are NOT descriptor 1. A
	 * test that passed because the trap was toothless would prove nothing. */
	{
		uint32_t wrong_type;
		uint64_t wrong_base;

		arena_build(ovmf, OVMF_N, 48);
		memcpy(&wrong_type, ARENA + 40 + 0, 4);
		memcpy(&wrong_base, ARENA + 40 + 8, 8);
		EQI("trap armed: 40-stride type is not descriptor 1's",
		    1, wrong_type != ovmf[1].type);
		EQI("trap armed: 40-stride base is not descriptor 1's",
		    1, wrong_base != ovmf[1].phys);
		EQ32("trap armed: 40-stride type is poison",
		     0xA5A5A5A5U, wrong_type);
	}

	/* (3) The OVMF map at its real stride, plus the aggregate the PMM will
	 * ask for: only ConventionalMemory counts, and nothing else does. */
	check_map("ovmf", ovmf, OVMF_N, 48);
	{
		uint64_t ram = 0, ref = 0;
		int n_ram = 0, ref_n = 0;

		for (i = 0; i < OVMF_N; i++) {
			if (fk_efi_type_is_ram(fk_efi_mmap_type(i))) {
				ram += (uint64_t)fk_efi_mmap_bytes(i);
				n_ram++;
			}
			if (ref_is_ram(ovmf[i].type)) {
				ref += ref_bytes(ovmf[i].pages);
				ref_n++;
			}
		}
		EQI("ovmf: 4 conventional regions", 4, n_ram);
		EQI("ovmf: conventional region count matches model", ref_n, n_ram);
		EQ64("ovmf: usable bytes match the model", ref, ram);
		/* Not a tautology only if the map really does hold non-RAM. */
		EQI("ovmf: most regions are NOT free RAM", 1, n_ram < OVMF_N);
	}

	/* (4) Every one of the 16 defined type codes, and codes outside them.
	 * Type 4 (BootServicesData) and types 1/2 (Loader*) are deliberately
	 * NOT free: this kernel does not reclaim boot services. */
	for (i = 0; i <= 15; i++)
		EQI("type_is_ram over the 16 defined types",
		    i == EfiConventionalMemory, fk_efi_type_is_ram(i));
	EQI("type 16 is not RAM",          0, fk_efi_type_is_ram(16));
	EQI("type 17 is not RAM",          0, fk_efi_type_is_ram(17));
	EQI("type 0x6FFFFFFF is not RAM",  0, fk_efi_type_is_ram(0x6FFFFFFF));
	EQI("type 0x70000000 (OS range) is not RAM",
	    0, fk_efi_type_is_ram((int32_t)0x70000000));
	EQI("type 0x80000000 (OEM range) is not RAM",
	    0, fk_efi_type_is_ram((int32_t)0x80000000));
	EQI("type 0xFFFFFFFF is not RAM", 0, fk_efi_type_is_ram(-1));
	EQI("the sentinel type is not RAM",
	    0, fk_efi_type_is_ram((int32_t)BAD32));

	/* (5) The byte-count boundary, called out by index so a regression names
	 * itself. 2^51-1 pages is the largest count whose byte total still fits
	 * a non-negative signed 64-bit integer; anything above is REFUSED. */
	check_map("extreme", extreme, EXTREME_N, 48);
	EQ64("bit-63 base survives",       0x8000000000000000ULL,
	     (uint64_t)fk_efi_mmap_base(0));
	EQ64("bit-63 attr survives",       EFI_MEMORY_RUNTIME,
	     (uint64_t)fk_efi_mmap_attr(0));
	EQ64("all-ones base survives",     0xFFFFFFFFFFFFF000ULL,
	     (uint64_t)fk_efi_mmap_base(1));
	EQ64("all-ones attr survives",     0xFFFFFFFFFFFFFFFFULL,
	     (uint64_t)fk_efi_mmap_attr(1));
	EQ64("u32 halves do not sign-extend into the upper word",
	     0x00000000FFFFFFFFULL, (uint64_t)fk_efi_mmap_attr(2));
	EQ64("2^51-1 pages: byte count is exact",
	     0x7FFFFFFFFFFFF000ULL, (uint64_t)fk_efi_mmap_bytes(3));
	EQ64("2^51 pages: refused, not wrapped",
	     BAD64, (uint64_t)fk_efi_mmap_bytes(4));
	EQ64("2^52 pages: refused, not wrapped",
	     BAD64, (uint64_t)fk_efi_mmap_bytes(5));
	EQ64("bit-63 page count: refused, not called negative",
	     BAD64, (uint64_t)fk_efi_mmap_bytes(6));
	EQ64("all-ones page count: refused",
	     BAD64, (uint64_t)fk_efi_mmap_bytes(7));
	/* The refusals must not have eaten the raw counts. */
	EQ64("2^51 pages readable raw",  PAGES_MAX + 1,
	     (uint64_t)fk_efi_mmap_pages(4));
	EQ64("bit-63 pages readable raw", 0x8000000000000000ULL,
	     (uint64_t)fk_efi_mmap_pages(6));

	/* (6) Out-of-range indices, on a map that IS latched. */
	check_map("ovmf", ovmf, OVMF_N, 48);
	EQ64("last valid index still reads", ovmf[OVMF_N - 1].phys,
	     (uint64_t)fk_efi_mmap_base(OVMF_N - 1));
	check_oob_index("oob", -1);
	check_oob_index("oob", -2);
	check_oob_index("oob", OVMF_N);
	check_oob_index("oob", OVMF_N + 1);
	check_oob_index("oob", 1000);
	check_oob_index("oob", INT32_MAX);
	check_oob_index("oob", INT32_MIN);
	guard_check("after out-of-range sweep");

	/* (7) Every rejection path, by exact code -- "nonzero" would hide a
	 * bound that fires for the wrong reason. Each one must also CLEAR the
	 * map that was latched a moment earlier. */
	{
		const int64_t good_total = (int64_t)OVMF_N * 48;

		arena_build(ovmf, OVMF_N, 48);
		EQI("reject: a good latch first", EFI_OK,
		    fk_efi_mmap_set(ARENA, good_total, 48, 1));
		EQI("reject: latched count", OVMF_N, fk_efi_mmap_count());

		EQI("reject: NULL base", E_BASE_NULL,
		    fk_efi_mmap_set(NULL, good_total, 48, 1));
		EQI("reject: NULL base cleared the map", 0, fk_efi_mmap_count());
		check_oob_index("after NULL base", 0);

		EQI("reject: a good latch again", EFI_OK,
		    fk_efi_mmap_set(ARENA, good_total, 48, 1));
		EQI("reject: desc_size 39", E_DESC_SIZE,
		    fk_efi_mmap_set(ARENA, 39 * 4, 39, 1));
		EQI("reject: desc_size 39 cleared the map", 0,
		    fk_efi_mmap_count());
		check_oob_index("after desc_size 39", 0);

		EQI("reject: desc_size 0", E_DESC_SIZE,
		    fk_efi_mmap_set(ARENA, good_total, 0, 1));
		EQI("reject: desc_size 1", E_DESC_SIZE,
		    fk_efi_mmap_set(ARENA, good_total, 1, 1));
		EQI("reject: desc_size 4097", E_DESC_SIZE,
		    fk_efi_mmap_set(ARENA, 4097, 4097, 1));
		EQI("reject: desc_size with bit 63 set", E_DESC_SIZE,
		    fk_efi_mmap_set(ARENA, good_total,
				    (int64_t)0x8000000000000000ULL, 1));
		EQI("reject: desc_size all ones", E_DESC_SIZE,
		    fk_efi_mmap_set(ARENA, good_total, (int64_t)BAD64, 1));
		EQI("accept: desc_size exactly 40", EFI_OK,
		    fk_efi_mmap_set(ARENA, 40 * 4, 40, 1));
		EQI("accept: desc_size exactly 4096", EFI_OK,
		    fk_efi_mmap_set(ARENA, 4096 * 2, 4096, 1));

		EQI("reject: total_bytes not a multiple of desc_size",
		    E_NOT_MULTIPLE, fk_efi_mmap_set(ARENA, 3 * 48 + 7, 48, 1));
		EQI("reject: total_bytes one byte short", E_NOT_MULTIPLE,
		    fk_efi_mmap_set(ARENA, 3 * 48 - 1, 48, 1));
		EQI("reject: total_bytes smaller than one descriptor",
		    E_NOT_MULTIPLE, fk_efi_mmap_set(ARENA, 20, 48, 1));

		EQI("reject: zero descriptors", E_NO_ENTRIES,
		    fk_efi_mmap_set(ARENA, 0, 48, 1));
		EQI("reject: zero descriptors cleared the map", 0,
		    fk_efi_mmap_count());

		/* 2^63 is an exact multiple of 64, so a SIGNED bound would let
		 * this through, latch a negative count and read the arena from
		 * a negative offset. BGT is what makes it a refusal. */
		EQI("reject: total_bytes with bit 63 set", E_TOO_MANY,
		    fk_efi_mmap_set(ARENA, (int64_t)0x8000000000000000ULL, 64, 1));
		EQI("reject: bit-63 total cleared the map", 0,
		    fk_efi_mmap_count());
		EQI("reject: total_bytes all ones", E_TOO_MANY,
		    fk_efi_mmap_set(ARENA, (int64_t)BAD64, 64, 1));
		EQI("reject: total_bytes 2^62", E_TOO_MANY,
		    fk_efi_mmap_set(ARENA, (int64_t)0x4000000000000000ULL, 64, 1));
	}

	/* (8) The descriptor ceiling, on both sides of it. Each descriptor gets
	 * a distinct address so the walk is checked and not just the count. */
	for (i = 0; i <= MAX_DESC; i++) {
		many[i].type  = (i % 3) ? EfiReservedMemoryType
					: EfiConventionalMemory;
		many[i].phys  = 0x8000000000000000ULL + (uint64_t)i * 0x1000ULL;
		many[i].virt  = 0;
		many[i].pages = (uint64_t)(i + 1);
		many[i].attr  = EFI_MEMORY_RUNTIME | (uint64_t)i;
	}
	arena_build(many, MAX_DESC, 40);
	EQI("ceiling: exactly 1024 descriptors accepted", EFI_OK,
	    fk_efi_mmap_set(ARENA, MAX_DESC * 40, 40, 1));
	EQI("ceiling: count is 1024", MAX_DESC, fk_efi_mmap_count());
	for (i = 0; i < MAX_DESC; i += 113) {
		EQ64("ceiling: base walks by the stride", many[i].phys,
		     (uint64_t)fk_efi_mmap_base(i));
		EQ64("ceiling: attr walks by the stride", many[i].attr,
		     (uint64_t)fk_efi_mmap_attr(i));
	}
	EQ64("ceiling: last descriptor", many[MAX_DESC - 1].phys,
	     (uint64_t)fk_efi_mmap_base(MAX_DESC - 1));
	check_oob_index("ceiling", MAX_DESC);
	guard_check("ceiling");

	arena_build(many, MAX_DESC + 1, 40);
	EQI("ceiling: 1025 descriptors refused", E_TOO_MANY,
	    fk_efi_mmap_set(ARENA, (MAX_DESC + 1) * 40, 40, 1));
	EQI("ceiling: refusal cleared the map", 0, fk_efi_mmap_count());
	check_oob_index("after ceiling refusal", 0);

	/* (9) DescriptorVersion is recorded, not validated: the module must not
	 * start refusing maps because firmware bumped a version field. */
	arena_build(ovmf, OVMF_N, 48);
	EQI("desc_version 0 accepted", EFI_OK,
	    fk_efi_mmap_set(ARENA, (int64_t)OVMF_N * 48, 48, 0));
	EQI("desc_version 2 accepted", EFI_OK,
	    fk_efi_mmap_set(ARENA, (int64_t)OVMF_N * 48, 48, 2));
	EQI("desc_version does not disturb the count", OVMF_N,
	    fk_efi_mmap_count());
	guard_check("final");

	return fk_report("efi_mmap");
}
