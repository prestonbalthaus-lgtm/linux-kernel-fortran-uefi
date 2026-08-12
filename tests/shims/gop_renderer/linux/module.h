/* Minimal <linux/module.h> for building lib/fonts/font_8x16.c as an oracle.
 * The font file needs nothing from module.h except EXPORT_SYMBOL and the
 * __packed attribute used by struct font_data in lib/fonts/font.h. */
#ifndef _FK_SHIM_GOP_MODULE_H
#define _FK_SHIM_GOP_MODULE_H
#include <linux/types.h>
#include <linux/export.h>
#ifndef __packed
#define __packed __attribute__((packed))
#endif
#endif
