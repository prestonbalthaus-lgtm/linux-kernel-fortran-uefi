/* Private shim for the lib/bcd.c oracle build (Project Fortran-Kernel).
 *
 * The real include/linux/bcd.h pulls in <linux/compiler.h> for
 * __attribute_const__ and defines the const_bcd2bin/const_bin2bcd/
 * const_bcd_is_valid macros plus the bcd2bin()/bin2bcd() dispatch macros.
 * None of that is referenced by lib/bcd.c itself -- the .c only needs the
 * two prototypes so its definitions are checked against a declaration.
 *
 * The algorithm is NOT reimplemented here: this file contains declarations
 * only, so the oracle object is compiled from the unmodified kernel source.
 */
#ifndef _FK_SHIM_BCD_H
#define _FK_SHIM_BCD_H

unsigned _bcd2bin(unsigned char val);
unsigned char _bin2bcd(unsigned val);

#endif /* _FK_SHIM_BCD_H */
