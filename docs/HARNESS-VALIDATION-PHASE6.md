# Does the VFS's test actually catch bugs?

Roadmap 6.1 has no C function to diff against. `fs/namei.c` is entangled with
the mount table, RCU, credentials and the dcache hash, and nothing standalone
survives being pulled out of it, so `mk/vfs.mk` declares no `ORACLE_` and joins
`mk/serial.mk`, `mk/pcie.mk` and `mk/usb_hid.mk` as a fragment diffed against a
reference model written into its own test.

`docs/HARNESS-VALIDATION-PHASE2.md` says exactly what is wrong with that: a
model and a module that share a misconception agree. So this document is mostly
about the three things that are NOT the model.

## Four channels, and what each is the only one to see

### 1. The constants are the kernel's, and they are tested where they are used

`tests/fs/test_vfs.c` includes three vendor headers directly:

    vendor/linux-7.1.8/include/uapi/asm-generic/errno.h
    vendor/linux-7.1.8/include/uapi/linux/stat.h
    vendor/linux-7.1.8/include/uapi/linux/limits.h

Every expected value in the file is spelled `ENOTDIR`, `S_IFDIR`, `NAME_MAX`.
Nothing is transcribed.

`-D__KERNEL__` is required and is not decoration: `uapi/linux/stat.h:7` hides
the whole `S_IF*` block from anything built against glibc 2. That pulls in a
chain ending at `linux/compiler_types.h`, which `tests/shims/vfs` supplies
empty, and `linux/types.h`, which `tests/shims` already shadows for every test
and which gained the `__s*` and `__kernel_*` typedefs at this milestone.
Measured: that is the entire shim set.

**No constant is read back through an accessor.** A function returning
`FK_S_IFDIR` so the test can compare it to `S_IFDIR` proves the two agree and
nothing else. Instead: a 256-byte component must come back `-ENAMETOOLONG`, the
root's mode must have `S_IFDIR` set, opening a directory for write must be
`-EISDIR`. A constant that only ever appears in an assertion about itself is not
tested at all.

### 2. The layout oracle is the C compiler

The four pools are `bind(c)` arrays published under their own names. The test
declares its own mirror `struct`s over the same bytes, writes through them and
reads back through the Fortran accessors:

```c
fk_vfs_inodes[i].i_ino = 0x1122334455667788LL + i;
FK_EQ(..., 0x1122334455667788LL + i, (long long)vfs_inode_ino(i + 1), "%lld");
```

The indices are `0`, `1` and `N-1`, chosen so a wrong **stride** misses even
when every offset is right.

This is stronger than comparing `offsetof` numbers -- a disagreement in either
the field offset or the array stride comes back as a wrong value -- and it needs
no enumeration of field ids to keep in step with the struct.

M109 is the mutation for this channel and nothing else sees it: an
`integer(c_int64_t) :: i_spare` inserted into `fk_inode_t` between `i_ino` and
`i_size`. Every accessor still compiles, every behavioural test still passes,
and the tree still resolves `/bin/init`.

### 3. The walk is a table, and every row cites `fs/namei.c`

Twenty-nine rows plus fourteen direct calls. Repeated slashes leading and
between components (`:2583-2587`, `:2635-2637`), a trailing slash on a directory
and on a file (`:2782`), `.` as a no-op (`:2258`), `..` including at the root
(`:2217-2220`), `-ENOTDIR` through a file on a non-final component
(`:2662-2667`), and `NAME_MAX` and `PATH_MAX` at both sides of the boundary.

Three rows exist because they are the ones a resolver gets wrong quietly:

| row | why it is there |
|---|---|
| `/bin/init/` -> `-ENOTDIR` | a tokeniser that strips the trailing slash loses this and looks correct everywhere else |
| `/bin/init/..` -> `-ENOTDIR` | the non-final check has to be on the RESULT of a component, not on the directory it was looked up in; checking it first answers the root |
| `/READM` -> `-ENOENT` | the compare is `(length, bytes)`; drop the length and a prefix matches |

### 4. The boot, and its claim is narrow

`fk_vfs_state` is read out of guest physical memory over QMP and asserted by
`tools/qmp-sentinel.py vfs`. There is nothing outside the guest to diff a
memory-resident tree against -- 6.2 is the milestone that puts one on a disk --
so what the boot adds over the host suite is stated rather than inflated: the
same walk ran **under KFLAGS**, against the **real `fk_strlen`**, on a machine
that was **taking timer interrupts** while it did it, and produced the same
answers.

The state block carries the `/bin/init/` probe explicitly, because a refusal
that is not published is a refusal the gate cannot check.

Unlike 4.2's and 5.x's, these lines are PASS lines on **every** machine
including `FK_MACHINE=pc`. The VFS touches no bus and no device, so there is no
board on which it does not come up, and that is asserted rather than assumed.

## Mutations

`tools/mutate-hostlib.sh`, the host runner shared with roadmap 1.1. Every case
rebuilds and runs `build/run-vfs` alone, so the whole VFS half is minutes.

| # | Injected defect | Detected? | How it surfaced |
|---|---|---|---|
| M99 | the root's `d_parent` is not itself | **yes** | `".." at the root is the root, :2217: C=1 F=0` -- the walk left the tree |
| M100 | only one separator is skipped between components | **yes** | `runs on both sides, :2635-2637: C=2 F=-2` -- `//bin//` became `-ENOENT` |
| M101 | the trailing-slash fact is dropped | **yes** | `trailing slash on a FILE, :2782: C=-20 F=5` -- `/bin/init/` resolved |
| M102 | a non-final non-directory is walked through | **yes** | `walking through a file: C=-20 F=-2` -- `-ENOENT` where `-ENOTDIR` belongs |
| M103 | the name compare ignores `d_len` | **yes** | `a prefix is not a match: d_len: C=-2 F=4` -- `/READM` found README |
| M104 | `NAME_MAX` checked as `>=` rather than `>` | **yes** | `...and resolves: C=8 F=-36` -- a legal 255-byte name refused |
| M105 | `vfs_remove` never clears `d_flags` | **yes** | `the pool shrank: C=63 F=64`, then `and the slot comes back: C=1 F=0` |
| M106 | `vfs_remove` leaves the dentry on its parent's child list | **yes, by TIMEOUT** | the freed slot is reallocated, the list closes into a CYCLE, and `vfs_lookup` walks it forever |
| M107 | `vfs_remove` does not drop the parent's link | **yes** | `and the parent loses the link its ".." held: C=3 F=4` |
| M108 | a directory can be opened for write | **yes** | `opening a directory for write is -EISDIR: C=-21 F=2` |
| M109 | an `i_spare` field inserted into `fk_inode_t` | **yes** | `inode[0] i_mode: C=33184 F=0` -- **the layout channel only** |

Twenty-six cases across both milestones in this script; twenty-five refused, one
escape (1.1's M93, which is a provably equivalent transformation and is recorded
with the proof in `docs/HARNESS-VALIDATION.md`).

## M109 is the layout channel's whole justification

`i_spare` moves `i_size` and every field after it. Every accessor still compiles.
Every behavioural test still passes -- the tree is built and walked entirely
through `vfs_add` and `vfs_resolve`, which never see the C mirror. `/bin/init`
still resolves, `/bin/init/` is still `-ENOTDIR`, the pool still recycles.

The only thing that notices is the channel that writes through a C `struct` and
reads back through a Fortran accessor. That is the same evidentiary shape as
1.1's M97 -- one mutation that exactly one channel can see -- and it is why the
channel is there rather than being a `sizeof` assertion that would have to be
kept in step by hand.

## Two harness defects this milestone found, both watched failing

### 1. `run_case` had no timeout, and M106 is why it needs one

M106 does not return a wrong answer. It leaves a removed dentry on its parent's
child list; the slot is then reallocated, the list closes into a cycle, and
`vfs_lookup` walks it forever. The table stopped at M106 and never reported.

`docs/HARNESS-VALIDATION.md`'s first recorded lesson, from the `int_pow` suite,
is exactly this: *"defect #1 fails by hanging, not by returning a wrong answer.
Any CI runner for this project must impose a per-test timeout."* Written in
Phase 1, unheeded until a mutation table needed it.

`run_case` now runs under `timeout -k 10 300` and reports `TIMED OUT (caught)` as
a distinct outcome, because a hang and a mismatch are different evidence and
collapsing them would hide which one happened. The `-k` matters: a SIGKILL
straight to the podman client leaves the container running.

### 2. `restore()` rewound to the INDEX, and restored the defect

`tools/mutate-phase3.sh` and `-phase45.sh` both restore with
`git checkout -- $FILES` and argue in their headers that only UNSTAGED edits are
fatal, since restore rewinds to the index and staged work survives untouched.

That holds only while nothing stages **during** a run. A `git add -A` landed with
M106's deletion live in the working tree; the deletion went into the index, and
from then on every `restore()` faithfully put the defect back. The next run's
BASELINE hung. Nothing looked wrong at any point, because the worktree and the
index agreed with each other -- `git status` was clean and `git diff` was empty.

`mutate-hostlib.sh` now rewinds to HEAD and its guard refuses unless the files it
mutates already match HEAD. The cost is one rule: commit before running the
table. In exchange, no concurrent `git add` can poison it.

The concurrent run itself came from `pkill -f mutate-hostlib`, which matched the
killing shell's own command line, killed that, and left the real script running.
Kill by PID.


## What is NOT claimed

- **This is not a filesystem.** Nothing here reads a block. `s_priv` and
  `i_priv` are declared and unread; they are 6.2's, and saying so is the whole
  of the seam.
- **There is no ops table**, and its absence is a decision. Linux dispatches
  `lookup` through `inode_operations` because it has many filesystems to
  dispatch between. `vfs_lookup` is one function walking one list, and 6.2 is
  the first caller for which a miss means "read the directory off the disk".
- **Names are inline at `NAME_MAX`**, where `dcache.h:72-87` inlines 40 bytes
  and allocates for the rest. There is nothing to allocate from, so the limit a
  caller meets is the vendor's 255 rather than an artefact at 40.
- **The pools are 64/64/16/4 and that is a capacity, not a semantic.** The
  exhaustion test discovers the number rather than asserting a constant, so the
  test and the module cannot get it wrong together.
- **There is no cwd**, so a relative path needs an explicit base.
  `vfs_resolve_at` takes one; inventing a per-process one here would be a
  Phase 7 decision made by accident.
- **No symlinks.** `S_IFLNK` is declared and no walk follows one. Linux's
  `link_path_walk` is half symlink machinery and none of it is here.
- **Concurrency is not addressed at all.** The pools take no lock, exactly as
  `fk_heap_m` does not, and the bring-up runs before `sched_start` for the same
  reason.

---

# Roadmap 6.2: does the ext2 driver's test actually catch bugs?

6.1 had no C function to diff against and said so. 6.2 has something better,
and the difference is the whole reason this section is short: **the filesystem
was built by someone else.**

`tools/gen-ext2-oracle.sh` makes the fixture with `mke2fs` and reads the
expected inode numbers, sizes and block numbers back out with `debugfs`.
`tools/qmp-sentinel.py` walks the same image AGAIN, in Python, sharing no line
with `src/fs/fk_ext2.f90`. Three readers of the same bytes have to agree.

`docs/HARNESS-VALIDATION-PHASE2.md`'s warning -- a model and a module that
share a misconception agree -- does not apply to a model written by e2fsprogs.

## Four channels

### 1. The fixture, and it is not this tree's

Every expected value in `build/ext2-fixture.h` came out of `debugfs` and
`dumpe2fs`. The guest's printed answer on a live NVMe controller
(`/bin/init ino/size/LBA 0x0000000D/0x0000001C/0x00000066`) is inode 13, 28
bytes, LBA 102 -- and `debugfs` says inode 13, 28 bytes, block 51, which at a
1 KiB block is LBA 102.

**The fixture is formatted with 256-byte inodes on purpose.** A driver that
hardcodes `EXT2_GOOD_OLD_INODE_SIZE` reads every inode after the first at the
wrong offset, and only a filesystem whose inodes are not 128 bytes can tell.
That is M115.

### 2. The layout oracle is the vendor's own structs

`gen-ext2-oracle.sh` CUTS the four on-disk structs verbatim out of
`fs/ext2/ext2.h` and the test diffs every offset the driver uses against
`offsetof` over them. `ext2.h` cannot be included -- it pulls in `linux/fs.h`,
`linux/mm.h` and `linux/highmem.h` -- so extraction is what gets its layout
without its dependencies. A vendor bump that moves a field turns this red rather
than turning the parse subtly wrong.

**The extraction is counted, not assumed.** The first draft lost nine of
twenty-six constants to a `"[ \t]"` that reached `grep` as backslash-t rather
than as a tab, and the generated header looked perfectly healthy: the missing
constants simply were not asserted on, so the suite stayed green while proving
less than it claimed. That is roadmap 1.1's oracle falling through to glibc, in
a new costume. Every name is now checked by name and the total is checked as a
count.

### 3. The refusals are `dir.c`'s, and each names which one fired

`ext2_check_folio` (`dir.c:118-131`) makes five checks; the driver makes the
same five in the same order, and `ext2_last_status()` reports which one.

That accessor exists because a mutation table demanded it. The first version of
the corruption rows asserted only that the walk did not resolve, and TWO defects
escaped: with the alignment refusal removed, and with the spans-the-block
refusal removed, the walk still failed -- for a DIFFERENT reason. An assertion
that cannot tell two mechanisms apart cannot notice that the right one is gone.

### 4. The seam is exercised from above, and counted

`vfs_resolve("/bin/init")` is called with NOTHING in the dentry tree, so every
component is a cache miss that had to reach the disk. `blk_reads()` and
`vfs_fills()` are what turn "it returned the right handle" into "it read the
disk to get it" -- a driver that invented the answer returns the same handle.

## Mutations

`tools/mutate-ext2.sh`. 21 cases; 20 refused, 1 documented escape.

| # | Injected defect | Detected? | How it surfaced |
|---|---|---|---|
| M110 | no lower bound on `rec_len` at all | **yes, by TIMEOUT** | the offset never advances; the walk does not answer wrongly, it never answers |
| M111 | `rec_len & 3` accepted | **no -- and rightly** | see below |
| M112 | a name may run past its own record | yes | `a name_len too big for its rec_len is refused: C=1 F=0` |
| M113 | a record may span the block end | yes | `...as corruption: C=-9 F=-10` |
| M114 | an entry may name an impossible inode | yes | `an inode past s_inodes_count is refused: C=1 F=0` |
| M115 | the inode size is hardcoded to 128 | yes | `inode size, against dumpe2fs: C=256 F=128` |
| M116 | an unimplemented incompat feature accepted | yes | `META_BG is refused: C=-5 F=2` |
| M117 | a dirty filesystem is mounted | yes | `a filesystem that is not clean is refused: C=-3 F=2` |
| M118 | the descriptor table is sought in the wrong block | yes | `inode table block, against dumpe2fs: C=5 F=51` |
| M119 | a reserved inode can be handed out | yes | `inode 1 is reserved and refused: C=-8 F=0` |
| M120 | a directory joins `i_dir_acl` into its size | yes | needed a fixture with a NON-ZERO one; see below |
| M121 | a filesystem larger than its device is mounted | yes | `a block count with the top bit set is refused: C=-7 F=2` |
| M122 | a failed read leaves the previous block readable | yes | `and the stale block is no longer readable: C=-1 F=128` |
| M123 | an offset past the block reads as 0, not as absent | yes | `the byte above it does not: C=-1 F=0` |
| M124 | a 32-bit on-disk count is read SIGNED | yes | `a block count with the top bit set is refused: C=-7 F=-1` |
| M125 | the miss path can re-enter itself | **yes** | `vfs_add` calls `vfs_lookup` calls the filler; the stack is gone |
| M126 | a file is asked for its directory entries | yes | **the fill COUNTER only** -- the answer is identical |
| M127 | the filler's errno is returned as a dentry | yes | **the vfs suite only** -- `fk_ext2.f90` never returns a negative |
| M128 | the starting LBA is a block number | yes | `the starting LBA: C=102 F=51` |
| M129 | a directory needing indirection is truncated | yes | the name is there and the driver cannot see it |

### M111 escapes and it is right to

Same shape as 1.1's M93 and 5.2's M71. `dir.c:124` refuses a `rec_len` that is
not a multiple of four because no `EXT2_DIR_REC_LEN` can produce one -- it is an
INTEGRITY SIGNAL, not a bound. With the other four refusals present, a `rec_len`
of 13 is accepted by this check's absence and then caught downstream: the walk
lands mid-record, reads a garbage header, and fails as corruption anyway. The
OUTCOME is identical, so no assertion this suite can make separates the two.

Manufacturing a fixture where it differs would be testing the fixture. The
check is kept because the vendor keeps it and because it is one comparison.

### Six escapes on the first run, and five were the suite's fault

The table earned its keep the first time it ran: 14 caught, 6 through. Four of
the six were one mistake -- an assertion too coarse to distinguish mechanisms --
and the fixes are what the channels above describe. The other two were bugs in
the RUNNER, and both are worth carrying forward:

**`run_case` restores the tree before it returns.** A second `run_case` in the
same case function therefore runs against a CLEAN tree: it tests the baseline
and reports the pass as an escape. M126-vfs and M127 were both that, and both
were fine.

**`nohup ... &` inside a backgrounded wrapper gets orphaned and killed.** A run
launched that way died mid-case with M110 applied, and the next invocation
correctly refused to start because the tree differed from HEAD. The guard that
6.1 added is what turned a silent corruption into a loud refusal.

### M120 needed a fixture change, not a test change

Every directory `mke2fs` produces carries a zero in `i_dir_acl`, so joining it
as a size's high half changed nothing and the defect escaped. `i_size_high` and
`i_dir_acl` are the SAME WORD (`ext2.h:344`): a directory with an ACL block has
a block number where a regular file keeps the top 32 bits of its size. mke2fs
will not produce one without xattrs, so the test writes one.

---
