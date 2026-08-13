TESTS                 += heap
FSRC_heap             := src/mm/fk_heap.f90
DRV_heap              := tests/mm/test_heap.c

# No ORACLE_heap.  An allocator is not a function, it is a DATA STRUCTURE with
# a history, and there is nothing under $(KDIR) to compile that would answer
# the same question.  The kernel's kmalloc is SLUB -- mm/slub.c over
# mm/page_alloc.c -- a per-CPU cache of size-class slabs, so the nearest
# candidate is not a different implementation of what fk_heap.f90 does but a
# different ALGORITHM entirely: it has no boundary tags to coalesce, its
# returned sizes are rounded to a class rather than split from a neighbour, and
# every one of its entry points needs a gfp_t, a struct kmem_cache and a live
# page allocator underneath it.  Diffing an implicit free list against it would
# compare two data structures, not two answers.
#
# What replaces the oracle is that an allocator can be checked against its
# CONTRACT instead, which a pure function cannot: the test keeps a model of
# every pointer that is out on loan -- address, requested size, and a fill byte
# per block -- and after every single operation re-asserts alignment, that
# heap_size_of covers the request, that no two live ranges intersect, that
# every block still holds its own fill (two blocks handed the same memory fail
# here), and that the sizes the model can see add up to the module's own USED
# word.  Layout is left to heap_check(), which the module already runs on every
# boot.
#
# The workload is randomised from a constant seed rather than enumerated,
# because a heap defect is a defect about a SEQUENCE and a fixed list of calls
# only finds the sequences somebody already imagined.
#
# FSRC_heap is one file: fk_heap.f90 USEs nothing from this tree.  Its one
# external is heap_sbrk(), which the driver supplies over a single aligned
# arena -- the same boundary the kernel implements out of PMM frames, and the
# reason the module under test on the host is the module that runs in the
# guest rather than a stand-in for it.
