TESTS                 += pcie
# ORDER IS SEMANTIC: fk_pcie USEs fk_pcie_types_m for the ECAM shifts, the
# header-type field and the class triples, so that .mod has to exist first.
FSRC_pcie             := src/drivers/bus/fk_pcie_types.f90 \
                         src/drivers/bus/fk_pcie.f90
DRV_pcie              := tests/drivers/bus/test_pcie.c

# No ORACLE_pcie: Linux's drivers/pci/probe.c walks a live bus through an
# ioremap and a pci_host_bridge, so it is a second opinion on the layout and
# not a function that can be linked and diffed against this one.
#
# The reference model is the configuration space this project's own firmware
# presents -- QEMU q35, five functions, verified against 'info pci' on the boot
# gate -- laid into an arena poisoned to 0xFF.  The poison is not tidiness: an
# absent function returns all ones on every dword, so an unpopulated slot is
# absent by construction and a walk that strays into one sees what the silicon
# would show it.
#
# The test supplies fk_readl itself, the way tests/cpu/test_ioapic.c does.
# fk_pcie_m reaches config space through that and nothing else, because a
# volatile Fortran pointer is narrowed by -O2 when only some of a load's bits
# are used -- see tools/mmiocheck.sh.
