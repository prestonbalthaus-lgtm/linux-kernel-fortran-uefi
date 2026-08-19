/* SPDX-License-Identifier: GPL-2.0 */
/* Test for src/fs/fk_ext2.f90, fk_ext2_types.f90 and fk_blkdev.f90: roadmap
 * 6.2's filesystem driver.
 *
 * FOUR CHANNELS, and mk/ext2.mk says why none of them is a linked C oracle.
 *
 *   (1) THE FILESYSTEM WAS BUILT BY SOMEONE ELSE. build/ext2-fixture.img comes
 *       out of MKE2FS and every expected inode number, size and block number in
 *       build/ext2-fixture.h was read back out of it by DEBUGFS. Neither shares
 *       a line of code with this tree. This is the channel that would catch a
 *       parser and a formatter agreeing because they were written by the same
 *       hand -- which is the weakness docs/HARNESS-VALIDATION-PHASE2.md names
 *       and the reason roadmap 4.1 walked the ACPI tables in Python first.
 *
 *   (2) THE LAYOUT ORACLE IS THE VENDOR'S OWN STRUCTS. build/ext2-vendor.h is
 *       cut verbatim out of fs/ext2/ext2.h, and every offset the driver uses is
 *       diffed against offsetof over it. A vendor bump that moves a field turns
 *       this red rather than turning the parse subtly wrong.
 *
 *   (3) THE REFUSALS ARE dir.c's. ext2_check_folio (dir.c:118-131) makes five
 *       checks on a directory record; this file corrupts a real image five ways
 *       and requires each one to be refused. The rec_len == 0 case is the one
 *       that matters most: without that check the walk does not return a wrong
 *       answer, it never returns at all.
 *
 *   (4) THE SEAM IS EXERCISED FROM ABOVE. vfs_resolve("/bin/init") is called
 *       with NOTHING in the dentry tree, so every component of that path is a
 *       cache miss that had to reach the disk. blk_reads() and vfs_fills() are
 *       what turn "it returned the right handle" into "it read the disk to get
 *       it" -- a driver that invented the answer returns the same handle.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include "ext2-vendor.h"
#include "ext2-fixture.h"
#include "fk_test.h"

/* The mode bits the driver must pass through untouched. ext2's i_mode IS
 * Linux's st_mode -- the same S_IF* octal values -- which is why nothing in
 * fk_ext2.f90 translates between them. */
#define S_IFMT_  0170000
#define S_IFDIR_ 0040000
#define S_IFREG_ 0100000

/* ---- the device under the driver ------------------------------------------
 * fk_blk_submit is THE SEAM src/fs/fk_blkdev.f90 declares and does not define.
 * In the kernel src/fs/fk_blkdev_nvme.f90 defines it over a real controller; in
 * this file it is a memcpy out of an image that was loaded once. The Fortran
 * above it cannot tell the difference, which is the entire point -- the code
 * being tested here is the code that runs on the metal. */
static uint8_t *disk;
static long disk_bytes;
static uint32_t blkbuf[4096 / 4] __attribute__((aligned(8)));
static long submits;
static int submit_fail;

int32_t fk_blk_submit(int64_t lba, int32_t sectors, int64_t phys)
{
	long off = (long)lba * 512;

	if (submit_fail)
		return -1;
	if (lba < 0 || sectors < 1 || off + (long)sectors * 512 > disk_bytes)
		return -1;
	memcpy((void *)(uintptr_t)phys, disk + off, (size_t)sectors * 512);
	submits++;
	return 0;
}

/* The kernel reads its DMA landing zone through fk_readl for the reason
 * fk_nvme.f90's nvme_sector_word states; the driver therefore does too, and so
 * this file has to supply one. */
int32_t fk_readl(int64_t addr)
{
	uint32_t v;

	memcpy(&v, (const void *)(uintptr_t)addr, 4);
	return (int32_t)v;
}

void fk_writel(int64_t addr, int32_t v)
{
	memcpy((void *)(uintptr_t)addr, &v, 4);
}

/* ---- the Fortran under test ----------------------------------------------- */
void    blk_attach(int64_t virt, int64_t phys, int32_t bytes, int64_t sectors);
void    blk_detach(void);
int32_t blk_read(int64_t lba, int32_t sectors);
int64_t blk_reads(void);
int64_t blk_capacity(void);
int32_t blk_u8(int32_t off);
int32_t blk_le16(int32_t off);
int64_t blk_le32(int32_t off);
int64_t blk_le64(int32_t off);

void    ext2_reset(void);
int32_t ext2_mount(int32_t dev);
int32_t ext2_mounted_sb(void);
int32_t ext2_block_size(void);
int32_t ext2_inode_size(void);
int64_t ext2_inodes_per_group(void);
int64_t ext2_blocks_per_group(void);
int64_t ext2_inodes_count(void);
int64_t ext2_blocks_count(void);
int64_t ext2_first_ino(void);
int64_t ext2_group_count(void);
int64_t ext2_inode_table(void);
int32_t ext2_stat(int64_t ino);
int32_t ext2_stat_mode(void);
int64_t ext2_stat_size(void);
int32_t ext2_stat_links(void);
int64_t ext2_stat_block(int32_t k);
int64_t ext2_first_lba(int32_t inode_h);

void    vfs_reset(void);
int32_t vfs_resolve(const char *path);
int32_t vfs_lookup(int32_t parent, const char *name, int32_t len);
int32_t vfs_root(int32_t sb);
int32_t vfs_dentry_inode(int32_t d);
int32_t vfs_dentry_parent(int32_t d);
int32_t vfs_is_dir(int32_t d);
int32_t vfs_inode_mode(int32_t i);
int64_t vfs_inode_size(int32_t i);
int64_t vfs_inode_priv(int32_t i);
int64_t vfs_super_priv(int32_t sb);
int32_t vfs_dentries_used(void);
int64_t vfs_fills(void);
int32_t vfs_add(int32_t parent, const char *name, int32_t len, int32_t mode,
		int64_t size);

/* The driver's own status codes, in the order fk_ext2.f90 declares them. */
#define E2_OK		0
#define E2_IO		-1
#define E2_MAGIC	-2
#define E2_DIRTY	-3
#define E2_REV		-4
#define E2_FEATURE	-5
#define E2_BLOCKSIZE	-6
#define E2_GEOMETRY	-7
#define E2_INO		-8
#define E2_CORRUPT	-9
#define E2_NOENT	-10
#define E2_FBIG		-11

/* ---- (2) the layout channel ------------------------------------------------
 * Each row is <the byte offset fk_ext2_types.f90 uses> against <offsetof over
 * the vendor's struct>. The literal on the left is the ONLY transcription in
 * this file and it is the thing under test; everything on the right came out of
 * fs/ext2/ext2.h an hour ago. */
static void test_layout(void)
{
	FK_EQ("sb s_inodes_count", (size_t)0,
	      offsetof(struct ext2_super_block, s_inodes_count), "%zu");
	FK_EQ("sb s_blocks_count", (size_t)4,
	      offsetof(struct ext2_super_block, s_blocks_count), "%zu");
	FK_EQ("sb s_first_data_block", (size_t)20,
	      offsetof(struct ext2_super_block, s_first_data_block), "%zu");
	FK_EQ("sb s_log_block_size", (size_t)24,
	      offsetof(struct ext2_super_block, s_log_block_size), "%zu");
	FK_EQ("sb s_blocks_per_group", (size_t)32,
	      offsetof(struct ext2_super_block, s_blocks_per_group), "%zu");
	FK_EQ("sb s_inodes_per_group", (size_t)40,
	      offsetof(struct ext2_super_block, s_inodes_per_group), "%zu");
	FK_EQ("sb s_magic", (size_t)56,
	      offsetof(struct ext2_super_block, s_magic), "%zu");
	FK_EQ("sb s_state", (size_t)58,
	      offsetof(struct ext2_super_block, s_state), "%zu");
	FK_EQ("sb s_rev_level", (size_t)76,
	      offsetof(struct ext2_super_block, s_rev_level), "%zu");
	FK_EQ("sb s_first_ino", (size_t)84,
	      offsetof(struct ext2_super_block, s_first_ino), "%zu");
	/* s_inode_size IS 16 BITS. Everything after it shifts by two against a
	 * naive all-__le32 reading of the struct, which is the single easiest
	 * way to get this layout wrong. */
	FK_EQ("sb s_inode_size", (size_t)88,
	      offsetof(struct ext2_super_block, s_inode_size), "%zu");
	FK_EQ("sb s_inode_size is 2 bytes", (size_t)2,
	      sizeof(((struct ext2_super_block *)0)->s_inode_size), "%zu");
	FK_EQ("sb s_feature_compat", (size_t)92,
	      offsetof(struct ext2_super_block, s_feature_compat), "%zu");
	FK_EQ("sb s_feature_incompat", (size_t)96,
	      offsetof(struct ext2_super_block, s_feature_incompat), "%zu");
	FK_EQ("sb s_feature_ro_compat", (size_t)100,
	      offsetof(struct ext2_super_block, s_feature_ro_compat), "%zu");

	FK_EQ("gd bg_inode_table", (size_t)8,
	      offsetof(struct ext2_group_desc, bg_inode_table), "%zu");
	FK_EQ("gd sizeof", (size_t)32, sizeof(struct ext2_group_desc), "%zu");

	FK_EQ("inode i_mode", (size_t)0,
	      offsetof(struct ext2_inode, i_mode), "%zu");
	FK_EQ("inode i_uid", (size_t)2,
	      offsetof(struct ext2_inode, i_uid), "%zu");
	FK_EQ("inode i_size", (size_t)4,
	      offsetof(struct ext2_inode, i_size), "%zu");
	FK_EQ("inode i_links_count", (size_t)26,
	      offsetof(struct ext2_inode, i_links_count), "%zu");
	FK_EQ("inode i_blocks", (size_t)28,
	      offsetof(struct ext2_inode, i_blocks), "%zu");
	FK_EQ("inode i_flags", (size_t)32,
	      offsetof(struct ext2_inode, i_flags), "%zu");
	FK_EQ("inode i_block", (size_t)40,
	      offsetof(struct ext2_inode, i_block), "%zu");
	/* i_size_high is an ALIAS onto i_dir_acl (ext2.h:344); the driver joins
	 * it for a regular file and must not for a directory. */
	FK_EQ("inode i_size_high", (size_t)108,
	      offsetof(struct ext2_inode, i_size_high), "%zu");
	FK_EQ("inode direct block count", 12, EXT2_NDIR_BLOCKS, "%d");
	FK_EQ("inode i_block entries", 15, EXT2_N_BLOCKS, "%d");

	FK_EQ("de inode", (size_t)0,
	      offsetof(struct ext2_dir_entry_2, inode), "%zu");
	FK_EQ("de rec_len", (size_t)4,
	      offsetof(struct ext2_dir_entry_2, rec_len), "%zu");
	FK_EQ("de name_len", (size_t)6,
	      offsetof(struct ext2_dir_entry_2, name_len), "%zu");
	FK_EQ("de file_type", (size_t)7,
	      offsetof(struct ext2_dir_entry_2, file_type), "%zu");
	FK_EQ("de name", (size_t)8,
	      offsetof(struct ext2_dir_entry_2, name), "%zu");
	/* name_len is ONE byte only because INCOMPAT_FILETYPE is set. The
	 * driver refuses a filesystem without it for exactly this reason. */
	FK_EQ("de name_len is 1 byte", (size_t)1,
	      sizeof(((struct ext2_dir_entry_2 *)0)->name_len), "%zu");
	/* The 8-byte header plus the name, rounded UP to a multiple of 4. A
	 * 4-byte name therefore still fits in 12 and it is the fifth byte that
	 * costs a word -- which is why the minimum is 12 and not 9. */
	FK_EQ("shortest legal record", 12, EXT2_DIR_REC_LEN(1), "%d");
	FK_EQ("a 3-byte name still fits in 12", 12, EXT2_DIR_REC_LEN(3), "%d");
	FK_EQ("so does a 4-byte name, exactly", 12, EXT2_DIR_REC_LEN(4), "%d");
	FK_EQ("a 5-byte name costs the next word", 16, EXT2_DIR_REC_LEN(5),
	      "%d");

	FK_EQ("root inode number", 2, EXT2_ROOT_INO, "%d");
	FK_EQ("original inode size", 128, EXT2_GOOD_OLD_INODE_SIZE, "%d");
	FK_EQ("original first inode", 11, EXT2_GOOD_OLD_FIRST_INO, "%d");
	FK_EQ("dynamic revision", 1, EXT2_DYNAMIC_REV, "%d");
	FK_EQ("clean-state bit", 1, EXT2_VALID_FS, "%d");
	FK_EQ("the one incompat bit implemented", 2,
	      EXT2_FEATURE_INCOMPAT_FILETYPE, "%d");
	FK_EQ("block size exponent base", 10, EXT2_MIN_BLOCK_LOG_SIZE, "%d");
}

/* ---- device plumbing ------------------------------------------------------ */
static uint8_t *pristine;

static void load_disk(void)
{
	FILE *f = fopen(FIX_IMAGE, "rb");

	if (!f) {
		printf("  MISSING %s -- tools/gen-ext2-oracle.sh did not run\n",
		       FIX_IMAGE);
		exit(1);
	}
	fseek(f, 0, SEEK_END);
	disk_bytes = ftell(f);
	fseek(f, 0, SEEK_SET);
	pristine = malloc((size_t)disk_bytes);
	disk = malloc((size_t)disk_bytes);
	if (!pristine || !disk ||
	    fread(pristine, 1, (size_t)disk_bytes, f) != (size_t)disk_bytes) {
		printf("  UNREADABLE %s\n", FIX_IMAGE);
		exit(1);
	}
	fclose(f);
	FK_EQ("the fixture is the size the gate's disk is",
	      (long)FIX_SECTORS * 512, disk_bytes, "%ld");
}

/* Every corruption case starts from the image e2fsprogs wrote, so a case that
 * forgets to undo itself cannot leak into the next one. */
static int32_t remount(void)
{
	memcpy(disk, pristine, (size_t)disk_bytes);
	submit_fail = 0;
	vfs_reset();
	ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	return ext2_mount(1);
}

/* The superblock lives at byte 1024 and the fixture's block is 1024 bytes, so
 * these two agree by construction -- stated rather than assumed, because the
 * corruption cases below poke absolute byte offsets. */
static void poke16(long off, uint16_t v) { memcpy(disk + off, &v, 2); }
static void poke32(long off, uint32_t v) { memcpy(disk + off, &v, 4); }
#define SB_AT 1024

/* ---- (1) the fixture channel ----------------------------------------------- */
static void test_mount(void)
{
	int32_t sb = remount();

	FK_EQ("the filesystem mounts", 1, sb > 0, "%d");
	FK_EQ("and becomes the mounted one", sb, ext2_mounted_sb(), "%d");
	FK_EQ("block size, against dumpe2fs", FIX_BLOCK_SIZE,
	      ext2_block_size(), "%d");
	/* THE FIXTURE IS FORMATTED WITH 256-BYTE INODES ON PURPOSE. A driver
	 * that hardcodes EXT2_GOOD_OLD_INODE_SIZE reads every inode after the
	 * first at the wrong offset, and only a fixture that is not 128 can
	 * tell. */
	FK_EQ("inode size, against dumpe2fs", FIX_INODE_SIZE,
	      ext2_inode_size(), "%d");
	FK_EQ("inode size is not the original 128", 1,
	      FIX_INODE_SIZE != EXT2_GOOD_OLD_INODE_SIZE, "%d");
	FK_EQ("block count", (long long)FIX_BLOCK_COUNT,
	      (long long)ext2_blocks_count(), "%lld");
	FK_EQ("inode count", (long long)FIX_INODE_COUNT,
	      (long long)ext2_inodes_count(), "%lld");
	FK_EQ("inodes per group", (long long)FIX_IPG,
	      (long long)ext2_inodes_per_group(), "%lld");
	FK_EQ("blocks per group", (long long)FIX_BPG,
	      (long long)ext2_blocks_per_group(), "%lld");
	FK_EQ("first non-reserved inode", (long long)FIX_FIRST_INO,
	      (long long)ext2_first_ino(), "%lld");
	FK_EQ("one block group", 1LL, (long long)ext2_group_count(), "%lld");
	/* super.c:813 puts the descriptor table one block above the superblock,
	 * and the inode table is where the descriptor said. */
	FK_EQ("inode table block, against dumpe2fs", (long long)FIX_INODE_TABLE,
	      (long long)ext2_inode_table(), "%lld");
	FK_EQ("s_priv carries it into the VFS superblock",
	      (long long)FIX_INODE_TABLE, (long long)vfs_super_priv(sb), "%lld");

	FK_EQ("the root dentry exists", 1, vfs_root(sb) > 0, "%d");
	FK_EQ("the root is a directory", 1, vfs_is_dir(vfs_root(sb)), "%d");
	FK_EQ("and i_priv names inode 2", 2LL,
	      (long long)vfs_inode_priv(vfs_dentry_inode(vfs_root(sb))),
	      "%lld");
}

static void test_stat(void)
{
	remount();

	FK_EQ("stat /bin/init's inode", E2_OK, ext2_stat(FIX_INIT_INO), "%d");
	FK_EQ("it is a regular file", S_IFREG_,
	      ext2_stat_mode() & S_IFMT_, "%d");
	FK_EQ("with the permissions mke2fs gave it", FIX_INIT_MODE,
	      ext2_stat_mode() & ~S_IFMT_, "%d");
	FK_EQ("size, against debugfs", (long long)FIX_INIT_SIZE,
	      (long long)ext2_stat_size(), "%lld");
	FK_EQ("first block, against debugfs", (long long)FIX_INIT_BLOCK,
	      (long long)ext2_stat_block(0), "%lld");
	FK_EQ("one link", 1, ext2_stat_links(), "%d");

	FK_EQ("stat the root", E2_OK, ext2_stat(2), "%d");
	FK_EQ("the root is a directory", S_IFDIR_,
	      ext2_stat_mode() & S_IFMT_, "%d");
	FK_EQ("root's first block, against debugfs", (long long)FIX_ROOT_BLOCK,
	      (long long)ext2_stat_block(0), "%lld");

	FK_EQ("stat /bin", E2_OK, ext2_stat(FIX_BIN_INO), "%d");
	FK_EQ("/bin's first block, against debugfs", (long long)FIX_BIN_BLOCK,
	      (long long)ext2_stat_block(0), "%lld");

	/* inode.c:1328-1330's three-part validity test, one clause at a time.
	 * The middle clause is the one that is easy to leave out: inodes 1 and
	 * 3..10 are RESERVED, they exist in the table, and a driver that only
	 * bounds-checks hands back inode 1's contents for a name that resolved
	 * to it. */
	FK_EQ("inode 0 is refused", E2_INO, ext2_stat(0), "%d");
	FK_EQ("a negative inode is refused", E2_INO, ext2_stat(-1), "%d");
	FK_EQ("inode 1 is reserved and refused", E2_INO, ext2_stat(1), "%d");
	FK_EQ("inode 10 is reserved and refused", E2_INO, ext2_stat(10), "%d");
	FK_EQ("the root is the exception and is not", E2_OK, ext2_stat(2),
	      "%d");
	FK_EQ("one past the last inode is refused", E2_INO,
	      ext2_stat(FIX_INODE_COUNT + 1), "%d");
	FK_EQ("the last inode is in range", 1,
	      ext2_stat(FIX_INODE_COUNT) != E2_INO, "%d");
}

/* ---- (4) the seam channel -------------------------------------------------- */
static void test_seam(void)
{
	int32_t d, i;
	int64_t reads_before, fills_before;

	remount();
	FK_EQ("nothing but the root is in the tree", 1, vfs_dentries_used(),
	      "%d");

	reads_before = blk_reads();
	fills_before = vfs_fills();
	d = vfs_resolve("/bin/init");
	FK_EQ("/bin/init resolves", 1, d > 0, "%d");
	/* THE CLAIM THAT MATTERS. A driver that fabricated the dentry would
	 * return a handle just as positive as this one; only the read counter
	 * separates "it answered" from "it read the disk to answer". */
	FK_EQ("and the disk was read to do it", 1,
	      blk_reads() > reads_before, "%d");
	FK_EQ("through the miss path, twice -- bin, then init", 2LL,
	      (long long)(vfs_fills() - fills_before), "%lld");
	FK_EQ("two dentries were created", 3, vfs_dentries_used(), "%d");

	i = vfs_dentry_inode(d);
	FK_EQ("i_priv is the ext2 inode number", (long long)FIX_INIT_INO,
	      (long long)vfs_inode_priv(i), "%lld");
	FK_EQ("the VFS size is the on-disk size", (long long)FIX_INIT_SIZE,
	      (long long)vfs_inode_size(i), "%lld");
	FK_EQ("the VFS mode is the on-disk mode", S_IFREG_ | FIX_INIT_MODE,
	      vfs_inode_mode(i), "%d");
	FK_EQ("it is not a directory", 0, vfs_is_dir(d), "%d");
	/* Roadmap 6.2's validation sentence, in one number. */
	FK_EQ("the starting LBA", (long long)FIX_INIT_LBA,
	      (long long)ext2_first_lba(i), "%lld");

	/* THE SECOND RESOLVE MUST NOT READ THE DISK. That is what makes the
	 * dentry tree a cache rather than a log. */
	reads_before = blk_reads();
	FK_EQ("resolving again gives the same dentry", d,
	      vfs_resolve("/bin/init"), "%d");
	FK_EQ("and reads nothing", (long long)reads_before,
	      (long long)blk_reads(), "%lld");

	FK_EQ("the parent is /bin", vfs_resolve("/bin"), vfs_dentry_parent(d),
	      "%d");
	FK_EQ("/bin is a directory", 1, vfs_is_dir(vfs_resolve("/bin")), "%d");
	FK_EQ("/bin's i_priv", (long long)FIX_BIN_INO,
	      (long long)vfs_inode_priv(vfs_dentry_inode(vfs_resolve("/bin"))),
	      "%lld");

	/* Four components, so the miss path had to recurse through three
	 * directories it had never seen. */
	remount();
	d = vfs_resolve("/deep/a/b/leaf");
	FK_EQ("/deep/a/b/leaf resolves", 1, d > 0, "%d");
	FK_EQ("its inode, against debugfs", (long long)FIX_LEAF_INO,
	      (long long)vfs_inode_priv(vfs_dentry_inode(d)), "%lld");
	FK_EQ("its size, against debugfs", (long long)FIX_LEAF_SIZE,
	      (long long)vfs_inode_size(vfs_dentry_inode(d)), "%lld");

	remount();
	d = vfs_resolve("/etc/fstab");
	FK_EQ("/etc/fstab resolves", 1, d > 0, "%d");
	FK_EQ("its inode, against debugfs", (long long)FIX_FSTAB_INO,
	      (long long)vfs_inode_priv(vfs_dentry_inode(d)), "%lld");

	/* A 255-byte name is legal and must come back off the disk intact. The
	 * boundary is exercised from the DISK side here; test_vfs.c exercises
	 * it from the caller's. */
	remount();
	d = vfs_resolve("/" FIX_LONG_NAME);
	FK_EQ("a NAME_MAX name resolves", 1, d > 0, "%d");
	FK_EQ("its inode, against debugfs", (long long)FIX_LONG_INO,
	      (long long)vfs_inode_priv(vfs_dentry_inode(d)), "%lld");

	remount();
	FK_EQ("a name that is not there is -ENOENT", -2,
	      vfs_resolve("/bin/nosuch"), "%d");
	FK_EQ("nor is a directory that is not there", -2,
	      vfs_resolve("/nosuch/init"), "%d");
	/* namei.c:2782 through a real filesystem: the trailing slash survives
	 * tokenisation and the result is a file, so -ENOTDIR. */
	FK_EQ("/bin/init/ is -ENOTDIR", -20, vfs_resolve("/bin/init/"), "%d");
	FK_EQ("/bin/init/x is -ENOTDIR", -20, vfs_resolve("/bin/init/x"),
	      "%d");
	FK_EQ("/bin/ is the directory", vfs_resolve("/bin"),
	      vfs_resolve("/bin/"), "%d");
	FK_EQ("//bin//init resolves the same", vfs_resolve("/bin/init"),
	      vfs_resolve("//bin//init"), "%d");
	FK_EQ("/bin/./init resolves the same", vfs_resolve("/bin/init"),
	      vfs_resolve("/bin/./init"), "%d");
	FK_EQ("/bin/../bin/init resolves the same", vfs_resolve("/bin/init"),
	      vfs_resolve("/bin/../bin/init"), "%d");
	FK_EQ("/.. is the root", vfs_root(ext2_mounted_sb()),
	      vfs_resolve("/.."), "%d");

	/* A DIRECTORY IS THE ONLY THING WORTH ASKING THE FILESYSTEM ABOUT.
	 * Filling from a file would hand the parser a file's contents to read
	 * as directory records. */
	d = vfs_resolve("/bin/init");
	FK_EQ("looking a name up inside a file misses", 0,
	      vfs_lookup(d, "x", 1), "%d");

	/* An I/O error must not be reported as "no such file": the name may
	 * well be there. */
	remount();
	submit_fail = 1;
	FK_EQ("a read failure does not resolve", 1,
	      vfs_resolve("/bin/init") <= 0, "%d");
	submit_fail = 0;
}

/* ---- (3) the refusal channel ----------------------------------------------- */
static void test_super_refusals(void)
{
	memcpy(disk, pristine, (size_t)disk_bytes);
	poke16(SB_AT + 56, 0xEF54);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("a wrong magic is refused", E2_MAGIC, ext2_mount(1), "%d");

	memcpy(disk, pristine, (size_t)disk_bytes);
	poke16(SB_AT + 58, 0);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("a filesystem that is not clean is refused", E2_DIRTY,
	      ext2_mount(1), "%d");

	memcpy(disk, pristine, (size_t)disk_bytes);
	poke32(SB_AT + 76, 2);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("a revision above MAX_SUPP_REV is refused", E2_REV,
	      ext2_mount(1), "%d");

	/* META_BG is in the VENDOR's supported set and not in this driver's,
	 * because it moves the descriptor table off the one location
	 * read_super computes rather than reads. */
	memcpy(disk, pristine, (size_t)disk_bytes);
	poke32(SB_AT + 96, EXT2_FEATURE_INCOMPAT_FILETYPE |
			   EXT2_FEATURE_INCOMPAT_META_BG);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("META_BG is refused", E2_FEATURE, ext2_mount(1), "%d");

	memcpy(disk, pristine, (size_t)disk_bytes);
	poke32(SB_AT + 96, EXT2_FEATURE_INCOMPAT_FILETYPE |
			   EXT2_FEATURE_INCOMPAT_COMPRESSION);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("COMPRESSION is refused", E2_FEATURE, ext2_mount(1), "%d");

	/* A filesystem WITHOUT filetype has a 16-bit name_len, which is a
	 * different record shape, and is refused rather than misparsed. */
	memcpy(disk, pristine, (size_t)disk_bytes);
	poke32(SB_AT + 100, 0xFFFFFFFFu);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("every ro_compat bit is ACCEPTED -- nothing here writes", 1,
	      ext2_mount(1) > 0, "%d");

	memcpy(disk, pristine, (size_t)disk_bytes);
	poke32(SB_AT + 24, 3);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("a block bigger than the buffer is refused", E2_BLOCKSIZE,
	      ext2_mount(1), "%d");

	memcpy(disk, pristine, (size_t)disk_bytes);
	poke16(SB_AT + 88, 100);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("an inode smaller than 128 is refused", E2_GEOMETRY,
	      ext2_mount(1), "%d");

	memcpy(disk, pristine, (size_t)disk_bytes);
	poke16(SB_AT + 88, 192);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("an inode size that is not a power of two is refused",
	      E2_GEOMETRY, ext2_mount(1), "%d");

	/* Zero inodes per group is a DIVIDE BY ZERO in the inode locator, not
	 * merely an odd number. */
	memcpy(disk, pristine, (size_t)disk_bytes);
	poke32(SB_AT + 40, 0);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("zero inodes per group is refused", E2_GEOMETRY, ext2_mount(1),
	      "%d");

	memcpy(disk, pristine, (size_t)disk_bytes);
	poke32(SB_AT + 32, 0);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("zero blocks per group is refused", E2_GEOMETRY, ext2_mount(1),
	      "%d");

	/* A filesystem that claims to be bigger than the device it was found
	 * on. Every later bound is derived from this number. */
	memcpy(disk, pristine, (size_t)disk_bytes);
	poke32(SB_AT + 4, 1u << 30);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("a filesystem larger than its device is refused", E2_GEOMETRY,
	      ext2_mount(1), "%d");

	/* THE SIGNED-WRAP CASE, and roadmap 4.1 is why it is here. A 32-bit
	 * count with the top bit set read into a signed 32-bit lands NEGATIVE
	 * and every "is it too big" test then passes. blk_le32 returns 64 bits
	 * for this reason. */
	memcpy(disk, pristine, (size_t)disk_bytes);
	poke32(SB_AT + 4, 0x80000000u);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("a block count with the top bit set is refused", E2_GEOMETRY,
	      ext2_mount(1), "%d");
	memcpy(disk, pristine, (size_t)disk_bytes);
	poke32(SB_AT + 0, 0x80000000u);
	vfs_reset(); ext2_reset();
	blk_attach((int64_t)(uintptr_t)blkbuf, (int64_t)(uintptr_t)blkbuf,
		   (int32_t)sizeof(blkbuf), FIX_SECTORS);
	FK_EQ("an inode count with the top bit set is refused", E2_GEOMETRY,
	      ext2_mount(1), "%d");
}

/* dir.c:118-131, one corruption per check. Every one of these is applied to
 * the FIRST record of /bin's directory block, which the walk reaches. */
static void test_dir_refusals(void)
{
	long bin_dir = (long)FIX_BIN_BLOCK * FIX_BLOCK_SIZE;
	int32_t d;

	/* THE HANG CASE. rec_len 0 is an offset that never advances; a walk
	 * without dir.c:122's check does not answer wrongly, it never answers.
	 * If this test times out rather than failing, that check is gone. */
	remount();
	poke16(bin_dir + 4, 0);
	FK_EQ("rec_len 0 is refused and terminates", 1,
	      vfs_resolve("/bin/init") <= 0, "%d");

	remount();
	poke16(bin_dir + 4, 8);
	FK_EQ("rec_len below the header size is refused", 1,
	      vfs_resolve("/bin/init") <= 0, "%d");

	remount();
	poke16(bin_dir + 4, 13);
	FK_EQ("an unaligned rec_len is refused", 1,
	      vfs_resolve("/bin/init") <= 0, "%d");

	/* dir.c:126. The first record is ".", rec_len 12, name_len 1. Raising
	 * name_len past what rec_len can hold makes the name run into the next
	 * record's bytes. */
	remount();
	disk[bin_dir + 6] = 200;
	FK_EQ("a name_len too big for its rec_len is refused", 1,
	      vfs_resolve("/bin/init") <= 0, "%d");

	/* dir.c:128. A record whose length carries it past the end of the
	 * block. */
	remount();
	poke16(bin_dir + 4, FIX_BLOCK_SIZE + 4);
	FK_EQ("a record that spans the block end is refused", 1,
	      vfs_resolve("/bin/init") <= 0, "%d");

	/* dir.c:130. An inode number no inode table entry can hold. */
	remount();
	poke32(bin_dir + 0, 0x7FFFFFFF);
	FK_EQ("an inode past s_inodes_count is refused", 1,
	      vfs_resolve("/bin/init") <= 0, "%d");

	/* And with none of that done, the same walk succeeds -- otherwise every
	 * row above would pass against a driver that simply never works. */
	remount();
	d = vfs_resolve("/bin/init");
	FK_EQ("the uncorrupted walk still resolves", 1, d > 0, "%d");

	/* A directory bigger than twelve direct blocks is REFUSED rather than
	 * searched to block 12 and reported missing. i_size lives at +4 in the
	 * inode, and /bin's inode is entry (12-1) of the table. */
	remount();
	poke32((long)FIX_INODE_TABLE * FIX_BLOCK_SIZE +
	       (FIX_BIN_INO - 1) * FIX_INODE_SIZE + 4, 13 * FIX_BLOCK_SIZE);
	FK_EQ("a directory needing indirection is refused, not truncated", 1,
	      vfs_resolve("/bin/init") <= 0, "%d");

	/* A block number past the end of the filesystem in i_block[0]. */
	remount();
	poke32((long)FIX_INODE_TABLE * FIX_BLOCK_SIZE +
	       (FIX_BIN_INO - 1) * FIX_INODE_SIZE + 40, FIX_BLOCK_COUNT + 1);
	FK_EQ("a block number past the filesystem is refused", 1,
	      vfs_resolve("/bin/init") <= 0, "%d");
}

/* ---- the block layer ------------------------------------------------------ */
static void test_blkdev(void)
{
	remount();

	FK_EQ("capacity is what was attached", (long long)FIX_SECTORS,
	      (long long)blk_capacity(), "%lld");
	FK_EQ("a read past the end is refused", 1,
	      blk_read(FIX_SECTORS, 1) != 0, "%d");
	FK_EQ("a read ending exactly at the end is not", 0,
	      blk_read(FIX_SECTORS - 1, 1), "%d");
	FK_EQ("a read straddling the end is refused", 1,
	      blk_read(FIX_SECTORS - 1, 2) != 0, "%d");
	FK_EQ("a negative LBA is refused", 1, blk_read(-1, 1) != 0, "%d");
	FK_EQ("zero sectors is refused", 1, blk_read(0, 0) != 0, "%d");
	FK_EQ("more sectors than the buffer holds is refused", 1,
	      blk_read(0, (int32_t)(sizeof(blkbuf) / 512) + 1) != 0, "%d");

	/* AN OFFSET ABOVE WHAT WAS READ IS -1 AND NOT 0. A zero byte is a legal
	 * thing to find on a disk, and every caller in fk_ext2.f90 branches on
	 * the value, so the two must be distinguishable. */
	FK_EQ("one sector was read", 0, blk_read(2, 1), "%d");
	FK_EQ("the last byte of it reads", 1, blk_u8(511) >= 0, "%d");
	FK_EQ("the byte above it does not", -1, blk_u8(512), "%d");
	FK_EQ("nor does a negative offset", -1, blk_u8(-1), "%d");
	FK_EQ("a 16-bit read straddling the end is refused", -1,
	      blk_le16(511), "%d");
	FK_EQ("a 32-bit read straddling the end is refused", -1LL,
	      (long long)blk_le32(509), "%lld");

	/* Sector 2 is the superblock's first sector, so byte 56 within it is
	 * s_magic -- read little-endian, and against the value the vendor's own
	 * magic.h gives. */
	FK_EQ("the magic reads little-endian", 0xEF53, blk_le16(56), "%d");
	FK_EQ("and byte-wise agrees", 0x53, blk_u8(56), "%d");
	FK_EQ("and byte-wise agrees", 0xEF, blk_u8(57), "%d");

	/* A FAILED READ MUST NOT LEAVE THE PREVIOUS BLOCK ADDRESSABLE. That is
	 * how a filesystem parses the block it wanted out of the block it got. */
	submit_fail = 1;
	FK_EQ("a failing device is reported", 1, blk_read(0, 1) != 0, "%d");
	FK_EQ("and the stale block is no longer readable", -1, blk_u8(0), "%d");
	submit_fail = 0;

	/* Sector 0 still carries roadmap 5.3's prologue: ext2 reserves the
	 * first 1024 bytes and this is the proof the two milestones share one
	 * disk without either standing on the other. */
	FK_EQ("sector 0 is 5.3's prologue", 0, blk_read(0, 1), "%d");
	for (int k = 0; k < 16; k++)
		FK_EQ("5.3's prologue byte", k, blk_u8(k), "%d");
	FK_EQ("5.3's boot signature", 0xAA55, blk_le16(510), "%d");

	blk_detach();
	FK_EQ("a detached device reads nothing", 1, blk_read(0, 1) != 0, "%d");
	FK_EQ("and has no capacity", 0LL, (long long)blk_capacity(), "%lld");
}

/* THE RECURSION GUARD. vfs_add calls vfs_lookup to enforce -EEXIST, and the
 * filler's job is to call vfs_add; without the guard in fk_vfs.f90 the two call
 * each other until the stack is gone. This does not assert a value so much as
 * assert that control comes back at all. */
static void test_fill_reentry(void)
{
	int32_t root;

	remount();
	root = vfs_root(ext2_mounted_sb());
	FK_EQ("adding a name that is already on the disk is -EEXIST", -17,
	      vfs_add(root, "bin", 3, S_IFDIR_ | 0755, 0), "%d");
	FK_EQ("adding one that is not succeeds", 1,
	      vfs_add(root, "zz", 2, S_IFREG_ | 0644, 7) > 0, "%d");
	FK_EQ("and the tree still resolves through the disk", 1,
	      vfs_resolve("/bin/init") > 0, "%d");
}

int main(void)
{
	test_layout();
	load_disk();
	test_mount();
	test_stat();
	test_seam();
	test_blkdev();
	test_super_refusals();
	test_dir_refusals();
	test_fill_reentry();
	return fk_report("ext2");
}
