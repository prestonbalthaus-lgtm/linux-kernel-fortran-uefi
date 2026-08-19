/* SPDX-License-Identifier: GPL-2.0 */
/* Test for src/fs/fk_vfs.f90 and fk_vfs_types.f90: roadmap 6.1's VFS.
 *
 * THERE IS NO FUNCTION ORACLE, and mk/vfs.mk says why. What this file has
 * instead is three channels, and they are not the same kind of evidence:
 *
 *   (1) THE CONSTANTS ARE THE KERNEL'S. asm-generic/errno.h, linux/stat.h and
 *       linux/limits.h are included from the vendor tree and every expected
 *       value below is spelled ENOTDIR, S_IFDIR, NAME_MAX. Nothing is
 *       transcribed, and the Fortran side is tested WHERE THE CONSTANT IS USED
 *       rather than through an accessor that would only compare a number to
 *       itself.
 *
 *   (2) THE LAYOUT ORACLE IS THE C COMPILER. The four pools are bind(c) arrays
 *       published under their own names; this file declares its own mirror
 *       structs over the same bytes, writes through them at several indices and
 *       reads back through the Fortran accessors. A disagreement in a field
 *       offset OR in the array stride comes back as a wrong value. That is
 *       stronger than comparing offsetof numbers, and it needs no enumeration.
 *
 *   (3) THE WALK IS A TABLE, and every row cites fs/namei.c. Repeated slashes,
 *       a trailing slash, "." and ".." including at the root, -ENOTDIR through
 *       a file, and NAME_MAX and PATH_MAX at both sides of the boundary. This
 *       is the reference-model channel PHASE2 warns about -- a model and a
 *       module that share a misconception agree -- so the rows carry line
 *       numbers and the mutation table carries the rest of the argument.
 */
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <asm-generic/errno.h>
#include <asm-generic/fcntl.h>
#include <linux/stat.h>
#include <linux/limits.h>
#include "fk_test.h"

#define VFS_INODES	64
#define VFS_DENTRIES	64
#define VFS_FILES	16
#define VFS_SUPERS	4

/* THE MISS PATH (roadmap 6.2). vfs_lookup now asks a filesystem about a name
 * the dentry tree does not have; src/fs/fk_ext2.f90 defines this symbol for the
 * kernel and tests/fs/test_ext2.c defines it over a real ext2 image. Here it is
 * a STUB THAT ALWAYS MISSES, which is what makes every 6.1 assertion below mean
 * the same thing it meant before the seam existed -- a tree with no filesystem
 * under it behaves exactly as it always did.
 *
 * It counts, and the count is not decoration: it is the only evidence that the
 * seam is reached at all. A vfs_lookup that stopped calling it would leave
 * every other check in this file green. */
static long fill_calls;
static int32_t fill_last_len;
static char fill_last_name[NAME_MAX + 1];

int32_t fk_vfs_fill(int32_t parent, const char *name, int32_t len)
{
	(void)parent;
	fill_calls++;
	fill_last_len = len;
	if (len > 0 && len <= NAME_MAX) {
		memcpy(fill_last_name, name, (size_t)len);
		fill_last_name[len] = '\0';
	}
	return 0;
}

/* The mirrors. Field for field with src/fs/fk_vfs_types.f90. */
struct fk_inode {
	int32_t i_mode, i_nlink;
	int64_t i_ino, i_size, i_priv;
	int32_t i_uid, i_gid, i_sb, i_flags;
};
struct fk_dentry {
	int32_t d_parent, d_inode, d_sb, d_child, d_sib, d_len, d_flags;
	char    d_name[NAME_MAX + 1];
};
struct fk_file {
	int64_t f_pos;
	int32_t f_dentry, f_inode, f_flags, f_state;
};
struct fk_super {
	int64_t s_magic, s_blocksize, s_priv;
	int32_t s_root, s_dev, s_ninodes, s_flags;
};

extern struct fk_inode  fk_vfs_inodes[VFS_INODES];
extern struct fk_dentry fk_vfs_dentries[VFS_DENTRIES];
extern struct fk_file   fk_vfs_files[VFS_FILES];
extern struct fk_super  fk_vfs_supers[VFS_SUPERS];

void    vfs_reset(void);
int32_t vfs_mount(int64_t magic, int64_t blocksize, int32_t dev);
int32_t vfs_root(int32_t sb);
int32_t vfs_add(int32_t parent, const char *name, int32_t len, int32_t mode,
		int64_t size);
int32_t vfs_remove(int32_t d);
int32_t vfs_lookup(int32_t parent, const char *name, int32_t len);
int32_t vfs_resolve(const char *path);
int32_t vfs_resolve_at(int32_t base, const char *path);
int32_t vfs_open(int32_t d, int32_t flags);
int32_t vfs_close(int32_t f);
int32_t vfs_is_dir(int32_t d);
int32_t vfs_dentry_parent(int32_t d);
int32_t vfs_dentry_inode(int32_t d);
int32_t vfs_dentry_child(int32_t d);
int32_t vfs_dentry_sib(int32_t d);
int32_t vfs_dentry_len(int32_t d);
int32_t vfs_dentry_name(int32_t d, int32_t k);
int32_t vfs_inode_mode(int32_t i);
int64_t vfs_inode_size(int32_t i);
int64_t vfs_inode_ino(int32_t i);
int32_t vfs_inode_nlink(int32_t i);
int32_t vfs_file_inode(int32_t f);
int64_t vfs_file_pos(int32_t f);
int64_t vfs_super_magic(int32_t sb);
int64_t vfs_fills(void);
int32_t vfs_dentries_used(void);
int32_t vfs_inodes_used(void);
int32_t vfs_files_used(void);

static const char *lbl(const char *fmt, ...)
{
	static char buf[96];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(buf, sizeof buf, fmt, ap);
	va_end(ap);
	return buf;
}

#define FK_MAGIC	0x464B5646534C0601LL	/* "FKVFS" + 6.1 */

static int32_t root, bin, etc_, init_, sh, conf, readme;

static int32_t add(int32_t p, const char *n, int32_t mode, int64_t size)
{
	return vfs_add(p, n, (int32_t)strlen(n), mode, size);
}

/*      /
 *      +-- bin/            +-- init  (4096 bytes)
 *      |                   +-- sh
 *      +-- etc/            +-- conf
 *      +-- README
 */
static void build(void)
{
	int32_t sb;

	vfs_reset();
	sb = vfs_mount(FK_MAGIC, 4096, 1);
	FK_EQ("mount returns a superblock", 1, sb > 0, "%d");
	FK_EQ("the magic survives", FK_MAGIC, (long long)vfs_super_magic(sb), "%lld");
	root = vfs_root(sb);
	FK_EQ("the mount made a root", 1, root > 0, "%d");

	bin    = add(root, "bin",    S_IFDIR | 0755, 0);
	etc_   = add(root, "etc",    S_IFDIR | 0755, 0);
	readme = add(root, "README", S_IFREG | 0644, 11);
	init_  = add(bin,  "init",   S_IFREG | 0755, 4096);
	sh     = add(bin,  "sh",     S_IFREG | 0755, 512);
	conf   = add(etc_, "conf",   S_IFREG | 0644, 64);
	FK_EQ("every node was created", 6,
	      (bin > 0) + (etc_ > 0) + (readme > 0) + (init_ > 0) + (sh > 0) +
	      (conf > 0), "%d");
}

/* ---- (1) the constants, tested where they are used ---------------------- */

static void test_mode_and_links(void)
{
	int32_t ri = vfs_dentry_inode(root);
	int32_t bi = vfs_dentry_inode(bin);
	int32_t ii = vfs_dentry_inode(init_);

	FK_EQ("the root is a directory", S_IFDIR,
	      vfs_inode_mode(ri) & S_IFMT, "%d");
	FK_EQ("...and vfs_is_dir agrees", 1, vfs_is_dir(root), "%d");
	FK_EQ("a file is S_IFREG", S_IFREG, vfs_inode_mode(ii) & S_IFMT, "%d");
	FK_EQ("...and vfs_is_dir does not", 0, vfs_is_dir(init_), "%d");
	FK_EQ("the permission bits survive", 0755,
	      vfs_inode_mode(ii) & (S_IRWXU | S_IRWXG | S_IRWXO), "%d");

	/* A directory is two links -- its name and its "." -- and gives its
	 * parent one more for the ".." that now points at it. The root has
	 * two subdirectories, so it is 2 + 2. */
	FK_EQ("a directory starts at two links", 2, vfs_inode_nlink(bi), "%d");
	FK_EQ("a regular file at one", 1, vfs_inode_nlink(ii), "%d");
	FK_EQ("the root gained one per subdirectory", 4,
	      vfs_inode_nlink(ri), "%d");

	FK_EQ("the size survives", 4096LL, (long long)vfs_inode_size(ii), "%lld");
	FK_EQ("a directory has no size", 0LL,
	      (long long)vfs_inode_size(bi), "%lld");
	FK_EQ("inode numbers are distinct and non-zero",
	      1, vfs_inode_ino(ri) != vfs_inode_ino(ii) &&
	         vfs_inode_ino(ri) > 0, "%d");
}

static void test_name_limits(void)
{
	static char big[PATH_MAX + 64];
	int32_t d;

	memset(big, 'x', sizeof big);

	/* NAME_MAX is a limit on the component, and both sides of it matter. */
	d = vfs_add(root, big, NAME_MAX + 1, S_IFREG | 0644, 0);
	FK_EQ("a component of NAME_MAX+1 is refused", -ENAMETOOLONG, d, "%d");
	d = vfs_add(root, big, NAME_MAX, S_IFREG | 0644, 0);
	FK_EQ("a component of exactly NAME_MAX is accepted", 1, d > 0, "%d");

	big[NAME_MAX] = 0;
	FK_EQ("...and resolves", d, vfs_resolve_at(root, big), "%d");
	FK_EQ("removing it succeeds", 0, vfs_remove(d), "%d");

	/* PATH_MAX counts the terminator, so a strlen of PATH_MAX is one too
	 * many and PATH_MAX-1 is the longest legal path. */
	memset(big, 'x', sizeof big);
	big[0] = '/';
	big[PATH_MAX] = 0;
	FK_EQ("a path of PATH_MAX bytes is refused", -ENAMETOOLONG,
	      vfs_resolve(big), "%d");
	big[PATH_MAX - 1] = 0;
	FK_EQ("a path of PATH_MAX-1 gets as far as the component limit",
	      -ENAMETOOLONG, vfs_resolve(big), "%d");

	/* A legal-length component that is simply not there is -ENOENT, not
	 * -ENAMETOOLONG. The two errors are one byte apart in the input. */
	memset(big, 'x', sizeof big);
	big[0] = '/';
	big[1 + NAME_MAX] = 0;
	FK_EQ("a NAME_MAX component that does not exist is -ENOENT",
	      -ENOENT, vfs_resolve(big), "%d");
	/* One byte longer, and the two errors are one byte apart in the input. */
	big[1 + NAME_MAX] = 'x';
	big[1 + NAME_MAX + 1] = 0;
	FK_EQ("one byte longer is -ENAMETOOLONG", -ENAMETOOLONG,
	      vfs_resolve(big), "%d");
}

static void test_add_refusals(void)
{
	FK_EQ("a duplicate name is -EEXIST", -EEXIST,
	      add(root, "bin", S_IFDIR | 0755, 0), "%d");
	FK_EQ("a name with a separator in it is -EINVAL", -EINVAL,
	      add(root, "a/b", S_IFREG | 0644, 0), "%d");
	FK_EQ("an empty name is -EINVAL", -EINVAL,
	      vfs_add(root, "", 0, S_IFREG | 0644, 0), "%d");
	FK_EQ("adding into a regular file is -ENOTDIR", -ENOTDIR,
	      add(init_, "x", S_IFREG | 0644, 0), "%d");
	FK_EQ("adding into a dead handle is -EINVAL", -EINVAL,
	      add(0, "x", S_IFREG | 0644, 0), "%d");
	FK_EQ("...and past the end of the pool too", -EINVAL,
	      add(VFS_DENTRIES + 1, "x", S_IFREG | 0644, 0), "%d");
}

/* ---- (2) the layout, with the C compiler as the oracle ------------------ */

static void test_layout(void)
{
	/* Indices chosen so a wrong STRIDE misses even when every offset is
	 * right: the first, the second and the last. */
	static const int idx[] = { 0, 1, VFS_INODES - 1 };
	unsigned k;

	vfs_reset();
	for (k = 0; k < sizeof idx / sizeof *idx; k++) {
		int i = idx[k];

		fk_vfs_inodes[i].i_flags = 1;
		fk_vfs_inodes[i].i_mode  = S_IFREG | 0640;
		fk_vfs_inodes[i].i_nlink = 7 + i;
		fk_vfs_inodes[i].i_ino   = 0x1122334455667788LL + i;
		fk_vfs_inodes[i].i_size  = 0x00DEADBEEFCAFE00LL + i;

		FK_EQ(lbl("inode[%d] i_mode", i), S_IFREG | 0640,
		      vfs_inode_mode(i + 1), "%d");
		FK_EQ(lbl("inode[%d] i_nlink", i), 7 + i,
		      vfs_inode_nlink(i + 1), "%d");
		FK_EQ(lbl("inode[%d] i_ino", i), 0x1122334455667788LL + i,
		      (long long)vfs_inode_ino(i + 1), "%lld");
		FK_EQ(lbl("inode[%d] i_size", i), 0x00DEADBEEFCAFE00LL + i,
		      (long long)vfs_inode_size(i + 1), "%lld");
	}

	for (k = 0; k < sizeof idx / sizeof *idx; k++) {
		int i = idx[k];

		fk_vfs_dentries[i].d_flags  = 1;
		fk_vfs_dentries[i].d_parent = 11 + i;
		fk_vfs_dentries[i].d_inode  = 22 + i;
		fk_vfs_dentries[i].d_child  = 33 + i;
		fk_vfs_dentries[i].d_sib    = 44 + i;
		fk_vfs_dentries[i].d_len    = 3;
		fk_vfs_dentries[i].d_name[0] = 'a' + (char)i;
		fk_vfs_dentries[i].d_name[1] = 'b';
		fk_vfs_dentries[i].d_name[2] = (char)0x80;

		FK_EQ(lbl("dentry[%d] d_parent", i), 11 + i, vfs_dentry_parent(i + 1), "%d");
		FK_EQ(lbl("dentry[%d] d_inode", i), 22 + i, vfs_dentry_inode(i + 1), "%d");
		FK_EQ(lbl("dentry[%d] d_child", i), 33 + i, vfs_dentry_child(i + 1), "%d");
		FK_EQ(lbl("dentry[%d] d_sib", i), 44 + i, vfs_dentry_sib(i + 1), "%d");
		FK_EQ("dentry d_len", 3, vfs_dentry_len(i + 1), "%d");
		FK_EQ(lbl("dentry[%d] name byte 1", i), 'a' + i,
		      vfs_dentry_name(i + 1, 1), "%d");
		/* 0x80 comes back as 128, not -128: the name is char[] in C and
		 * iachar()'s domain in Fortran, and a sign here would mean the
		 * two disagree about the type. */
		FK_EQ("dentry name byte 3, high bit set", 0x80,
		      vfs_dentry_name(i + 1, 3), "%d");
	}

	fk_vfs_files[VFS_FILES - 1].f_state = 1;
	fk_vfs_files[VFS_FILES - 1].f_inode = 9;
	fk_vfs_files[VFS_FILES - 1].f_pos   = 0x7EDCBA9876543210LL;
	FK_EQ("file f_inode", 9, vfs_file_inode(VFS_FILES), "%d");
	FK_EQ("file f_pos", 0x7EDCBA9876543210LL,
	      (long long)vfs_file_pos(VFS_FILES), "%lld");

	fk_vfs_supers[VFS_SUPERS - 1].s_flags = 1;
	fk_vfs_supers[VFS_SUPERS - 1].s_magic = FK_MAGIC;
	FK_EQ("super s_magic", FK_MAGIC,
	      (long long)vfs_super_magic(VFS_SUPERS), "%lld");
	FK_EQ("super s_root, through vfs_root", 0,
	      vfs_root(VFS_SUPERS), "%d");

	vfs_reset();
	FK_EQ("reset empties every pool", 0,
	      vfs_dentries_used() + vfs_inodes_used() + vfs_files_used(), "%d");
}

/* ---- (3) the walk ------------------------------------------------------- */

struct row { const char *path; int32_t *want; int32_t err; const char *why; };

static void test_walk(void)
{
	const struct row rows[] = {
	  { "/",                &root,  0, "the root alone, namei.c:2588-2591" },
	  { "//",               &root,  0, "a run of leading slashes, :2583-2587" },
	  { "/////",            &root,  0, "any number of them" },
	  { "",                 NULL,   ENOENT, "an empty path resolves to nothing" },
	  { "/bin",             &bin,   0, "one component" },
	  { "/bin/",            &bin,   0, "a trailing slash on a directory is fine" },
	  { "//bin//",          &bin,   0, "runs on both sides, :2635-2637" },
	  { "/bin/init",        &init_, 0, "two components" },
	  { "/bin/sh",          &sh,    0, "the second child, so the list is walked" },
	  { "/etc/conf",        &conf,  0, "a different subtree" },
	  { "/README",          &readme,0, "a file at the root" },
	  { "/readme",          NULL,   ENOENT, "the compare is case sensitive" },
	  { "/READM",           NULL,   ENOENT, "a prefix is not a match: d_len" },
	  { "/READMEE",         NULL,   ENOENT, "nor is an extension of it" },
	  { "/.",               &root,  0, "\".\" stays put, namei.c:2258" },
	  { "/..",              &root,  0, "\"..\" at the root is the root, :2217" },
	  { "/../../..",        &root,  0, "...however many times" },
	  { "/bin/..",          &root,  0, "\"..\" from a subdirectory" },
	  { "/bin/../etc/conf", &conf,  0, "and the walk continues after it" },
	  { "/./bin/./init",    &init_, 0, "\".\" anywhere" },
	  { "/bin/./../bin/sh", &sh,    0, "both, mixed" },
	  { "/nosuch",          NULL,   ENOENT, "a missing final component" },
	  { "/bin/nosuch",      NULL,   ENOENT, "a missing leaf" },
	  { "/nosuch/init",     NULL,   ENOENT, "a missing directory is ENOENT, not ENOTDIR" },
	  { "/bin/init/",       NULL,   ENOTDIR, "trailing slash on a FILE, :2782" },
	  { "/bin/init/x",      NULL,   ENOTDIR, "walking through a file" },
	  { "/bin/init/.",      NULL,   ENOTDIR, "\".\" after a file is still through it" },
	  { "/bin/init/..",     NULL,   ENOTDIR, "and so is \"..\", :2662-2667" },
	  { "/README/",         NULL,   ENOTDIR, "the same at the root" },
	};
	unsigned i;

	for (i = 0; i < sizeof rows / sizeof *rows; i++) {
		int32_t got = vfs_resolve(rows[i].path);
		int32_t want = rows[i].want ? *rows[i].want : -rows[i].err;

		FK_EQ(rows[i].why, want, got, "%d");
	}

	/* Relative, which is what vfs_resolve_at exists for. There is no cwd in
	 * this kernel, so the base is the caller's and absolute paths ignore it. */
	FK_EQ("relative from the root", bin, vfs_resolve_at(root, "bin"), "%d");
	FK_EQ("relative, two deep", init_,
	      vfs_resolve_at(root, "bin/init"), "%d");
	FK_EQ("relative from a subdirectory", init_,
	      vfs_resolve_at(bin, "init"), "%d");
	FK_EQ("\"..\" from a subdirectory", root,
	      vfs_resolve_at(bin, ".."), "%d");
	FK_EQ("an absolute path ignores the base", conf,
	      vfs_resolve_at(bin, "/etc/conf"), "%d");
	FK_EQ("a relative path from a FILE is -ENOTDIR", -ENOTDIR,
	      vfs_resolve_at(init_, "x"), "%d");
	FK_EQ("...but an absolute one from a file still works", bin,
	      vfs_resolve_at(init_, "/bin"), "%d");
	FK_EQ("a dead base is -EINVAL", -EINVAL, vfs_resolve_at(0, "bin"), "%d");

	/* The seam, called directly: (len, bytes), never a NUL. */
	FK_EQ("vfs_lookup finds a child", init_, vfs_lookup(bin, "init", 4), "%d");
	FK_EQ("...and honours the length", 0, vfs_lookup(bin, "init", 3), "%d");
	FK_EQ("...in the other direction too", 0,
	      vfs_lookup(bin, "initx", 5), "%d");
	FK_EQ("a length of zero finds nothing", 0, vfs_lookup(bin, "init", 0), "%d");
	FK_EQ("a miss is FK_VFS_NONE, not an errno", 0,
	      vfs_lookup(bin, "zzz", 3), "%d");
}

/* ---- lifecycle ---------------------------------------------------------- */

static void test_lifecycle(void)
{
	char name[16];
	int32_t d, first = 0, n = 0, sb, r;

	vfs_reset();
	sb = vfs_mount(FK_MAGIC, 4096, 1);
	r = vfs_root(sb);

	/* Fill the pool. The count is discovered, not asserted from a constant
	 * the test would be free to get wrong alongside the module. */
	for (;;) {
		snprintf(name, sizeof name, "f%d", n);
		d = add(r, name, S_IFREG | 0644, 0);
		if (d < 0)
			break;
		if (!first)
			first = d;
		n++;
	}
	FK_EQ("the pool refuses with -ENOMEM, not something else",
	      -ENOMEM, d, "%d");
	FK_EQ("the root plus every child is the whole pool", VFS_DENTRIES,
	      vfs_dentries_used(), "%d");
	FK_EQ("and one inode each", VFS_DENTRIES, vfs_inodes_used(), "%d");
	FK_EQ("which is the pool minus the root", VFS_DENTRIES - 1, n, "%d");

	/* THE LIFECYCLE CLAIM, measured. A pool that never recycles passes
	 * every test above and fails this one. */
	FK_EQ("freeing one succeeds", 0, vfs_remove(first), "%d");
	FK_EQ("the pool shrank", VFS_DENTRIES - 1, vfs_dentries_used(), "%d");
	FK_EQ("and so did the inodes", VFS_DENTRIES - 1, vfs_inodes_used(), "%d");
	d = add(r, "recycled", S_IFREG | 0644, 0);
	FK_EQ("and the slot comes back", 1, d > 0, "%d");
	FK_EQ("the removed name is gone", -ENOENT, vfs_resolve("/f0"), "%d");
	FK_EQ("the new one is there", d, vfs_resolve("/recycled"), "%d");
	FK_EQ("full again", VFS_DENTRIES, vfs_dentries_used(), "%d");
}

static void test_remove(void)
{
	int32_t ri, bi, empty;

	build();
	ri = vfs_dentry_inode(root);
	bi = vfs_dentry_inode(bin);

	FK_EQ("the root cannot be removed", -EBUSY, vfs_remove(root), "%d");
	FK_EQ("a non-empty directory cannot be", -ENOTEMPTY,
	      vfs_remove(bin), "%d");
	FK_EQ("a dead handle is -EBADF", -EBADF, vfs_remove(0), "%d");

	FK_EQ("a leaf can", 0, vfs_remove(init_), "%d");
	FK_EQ("it is gone from the tree", -ENOENT, vfs_resolve("/bin/init"), "%d");
	FK_EQ("its sibling is not", sh, vfs_resolve("/bin/sh"), "%d");
	FK_EQ("removing a file does not touch the parent's links", 2,
	      vfs_inode_nlink(bi), "%d");

	FK_EQ("...and then the directory can", 0, vfs_remove(sh), "%d");
	FK_EQ("an empty directory can be removed", 0, vfs_remove(bin), "%d");
	FK_EQ("and the parent loses the link its \"..\" held", 3,
	      vfs_inode_nlink(ri), "%d");
	FK_EQ("bin is gone", -ENOENT, vfs_resolve("/bin"), "%d");
	FK_EQ("etc is untouched", conf, vfs_resolve("/etc/conf"), "%d");

	/* An unlink that forgot to take the dentry out of its parent's child
	 * list leaves a cycle or a dangling handle; walking the list is what
	 * finds it. */
	empty = vfs_dentry_child(root);
	{
		int hops = 0;

		while (empty != 0 && hops < VFS_DENTRIES + 2) {
			empty = vfs_dentry_sib(empty);
			hops++;
		}
		FK_EQ("the root's child list terminates", 0, empty, "%d");
		FK_EQ("...with exactly the survivors on it", 2, hops, "%d");
	}
}

static void test_open(void)
{
	int32_t f[VFS_FILES + 2];
	int i;

	build();
	FK_EQ("opening a directory for write is -EISDIR", -EISDIR,
	      vfs_open(root, O_WRONLY), "%d");
	FK_EQ("...and for read/write too", -EISDIR,
	      vfs_open(root, O_RDWR), "%d");
	FK_EQ("reading one is allowed", 1, vfs_open(root, O_RDONLY) > 0, "%d");
	FK_EQ("a dead handle is -EBADF", -EBADF, vfs_open(0, O_RDONLY), "%d");

	vfs_reset();
	build();
	for (i = 0; i < VFS_FILES + 1; i++)
		f[i] = vfs_open(init_, O_RDONLY);
	FK_EQ("the file table runs out with -EMFILE", -EMFILE,
	      f[VFS_FILES], "%d");
	FK_EQ("every earlier one succeeded", VFS_FILES, vfs_files_used(), "%d");
	FK_EQ("a new file starts at offset zero", 0LL,
	      (long long)vfs_file_pos(f[0]), "%lld");
	FK_EQ("and names the right inode", vfs_dentry_inode(init_),
	      vfs_file_inode(f[0]), "%d");

	FK_EQ("closing works", 0, vfs_close(f[0]), "%d");
	FK_EQ("closing twice is -EBADF", -EBADF, vfs_close(f[0]), "%d");
	FK_EQ("and the slot comes back", 1, vfs_open(init_, O_RDONLY) > 0, "%d");
}

/* Roadmap 6.2 added a call out of vfs_lookup, and this is what proves it is
 * reached, reached with the right arguments, and reached only when it should
 * be. Nothing else in this file would notice if it stopped happening. */
static void test_miss_path(void)
{
	int32_t sb, r, f, before;
	int64_t fills_before;

	vfs_reset();
	fill_calls = 0;
	sb = vfs_mount(0x5A, 4096, 1);
	r = vfs_root(sb);

	before = (int32_t)fill_calls;
	fills_before = vfs_fills();
	FK_EQ("a name in an empty root misses", 0, vfs_lookup(r, "bin", 3),
	      "%d");
	FK_EQ("and the filesystem was asked exactly once", before + 1,
	      (int32_t)fill_calls, "%d");
	FK_EQ("vfs_fills counts it too", fills_before + 1, vfs_fills(), "%lld");
	FK_EQ("with the component's length", 3, fill_last_len, "%d");
	FK_EQ("and its bytes, which are NOT NUL-terminated on the way in", 0,
	      strcmp(fill_last_name, "bin"), "%d");

	/* A name that IS in the tree must not reach the disk at all -- that is
	 * the whole reason a dentry cache exists. */
	FK_EQ("adding it works", 1, add(r, "bin", S_IFDIR | 0755, 0) > 0, "%d");
	before = (int32_t)fill_calls;
	FK_EQ("looking it up now hits", 1, vfs_lookup(r, "bin", 3) > 0, "%d");
	FK_EQ("without asking the filesystem", before, (int32_t)fill_calls,
	      "%d");

	/* A NON-DIRECTORY IS NEVER FILLED FROM. Its i_priv is a file's inode
	 * number and its contents are not directory records. */
	f = add(r, "f", S_IFREG | 0644, 9);
	before = (int32_t)fill_calls;
	FK_EQ("a name inside a file misses", 0, vfs_lookup(f, "x", 1), "%d");
	FK_EQ("and the filesystem is not asked", before, (int32_t)fill_calls,
	      "%d");

	/* vfs_reset must clear the counter, or a second mount inherits the
	 * first one's tally. */
	vfs_reset();
	FK_EQ("reset clears the fill count", 0LL, (long long)vfs_fills(),
	      "%lld");
}

int main(void)
{
	test_layout();
	build();
	test_mode_and_links();
	test_walk();
	test_name_limits();
	test_add_refusals();
	test_remove();
	test_open();
	test_lifecycle();
	test_miss_path();
	return fk_report("vfs");
}
