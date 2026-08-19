/* Test for src/drivers/usb/fk_usb_hid.f90: the boot-report decode.
 *
 * THERE IS NO ORACLE FOR "WHAT CHARACTER IS THIS", and saying so precisely is
 * most of what this file is for.  Linux maps a HID usage to a KEYCODE; going
 * from keycode to character is a userspace keymap, so the kernel tree has no
 * function this table could be diffed against.  What it does have is
 * usb_kbd_keycode[256] in drivers/hid/usbhid/usbkbd.c, extracted by
 * tools/gen-hid-oracle.py, and that array is a real oracle for two relations
 * the Fortran table must satisfy:
 *
 *   (1) COVERAGE.  Where Linux says a usage is not a key at all, this table
 *       must produce no character.  The converse does NOT hold and is not
 *       asserted: F1 and the arrows are keys with no ASCII.
 *   (2) IDENTITY.  Two usages Linux maps to the SAME keycode are the same
 *       physical key, so they must decode to the same character.  0x31 and
 *       0x32 are the case that exists -- both are keycode 43 -- and a table
 *       that gave them different characters would be claiming the machine has
 *       two backslash keys.
 *
 * The rest is the HID Usage Tables' own ordering (Keyboard/Keypad page 0x07,
 * section 10), which is a specification and not an invention: 0x04..0x1D are
 * a..z in order, 0x1E..0x26 are 1..9, and 0x27 is 0 -- LAST, not first, which
 * is the off-by-one this range exists to pin.
 *
 * The shifted characters and the US punctuation layout are this kernel's own
 * choice and are checked against a reference model here, with the weakness
 * HARNESS-VALIDATION-PHASE2.md names: a model and a module that share a
 * misconception agree.  The mutation table is the evidence they do not.
 */
#include <stdint.h>
#include <string.h>
#include "fk_test.h"
#include "hid-oracle.h"

int32_t hid_ascii(int32_t usage, int32_t mods, int32_t caps);
int32_t hid_is_shift(int32_t mods);
int32_t hid_is_ctrl(int32_t mods);

#define MOD_LCTRL  (1 << 0)
#define MOD_LSHIFT (1 << 1)
#define MOD_RSHIFT (1 << 5)
#define MOD_RCTRL  (1 << 4)

/* The reference model, from the HID Usage Tables and a US layout. */
static const char *ALNUM       = "abcdefghijklmnopqrstuvwxyz1234567890";
static const char *ALNUM_SHIFT = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()";
static const char *PUNCT       = "-=[]\\\\;'`,./";
static const char *PUNCT_SHIFT = "_+{}||:\"~<>?";

static int32_t model(int32_t usage, int32_t mods, int32_t caps)
{
	int shifted = (mods & (MOD_LSHIFT | MOD_RSHIFT)) != 0;

	if (usage >= 0x04 && usage <= 0x27) {
		int i = usage - 0x04;
		int upper = shifted;
		if (usage < 0x04 + 26 && caps)
			upper = !shifted;
		return (unsigned char)(upper ? ALNUM_SHIFT[i] : ALNUM[i]);
	}
	if (usage >= 0x2D && usage <= 0x38) {
		int i = usage - 0x2D;
		return (unsigned char)(shifted ? PUNCT_SHIFT[i] : PUNCT[i]);
	}
	switch (usage) {
	case 0x28: return 10;   /* Enter     */
	case 0x2A: return 8;    /* Backspace */
	case 0x2B: return 9;    /* Tab       */
	case 0x2C: return 32;   /* Space     */
	default:   return 0;
	}
}

/* (1) Linux's not-a-key set is a lower bound on ours. */
static void test_coverage_against_linux(void)
{
	for (int u = 0; u < 256; u++) {
		if (usb_kbd_keycode[u] != 0)
			continue;
		FK_EQ("usage Linux calls not-a-key decodes to nothing",
		      0, hid_ascii(u, 0, 0), "%d");
		FK_EQ("...and nothing under shift either",
		      0, hid_ascii(u, MOD_LSHIFT, 0), "%d");
	}
}

/* (2) One physical key is one character, however many usages name it. */
static void test_identity_against_linux(void)
{
	for (int a = 0; a < 256; a++) {
		if (usb_kbd_keycode[a] == 0)
			continue;
		for (int b = a + 1; b < 256; b++) {
			if (usb_kbd_keycode[b] != usb_kbd_keycode[a])
				continue;
			FK_EQ("two usages that are the same key agree",
			      hid_ascii(a, 0, 0), hid_ascii(b, 0, 0), "%d");
			FK_EQ("...and agree under shift",
			      hid_ascii(a, MOD_LSHIFT, 0),
			      hid_ascii(b, MOD_LSHIFT, 0), "%d");
		}
	}
}

/* The usage page's own ordering, which is a specification. */
static void test_usage_page_order(void)
{
	for (int i = 0; i < 26; i++)
		FK_EQ("0x04..0x1D are a..z in order",
		      'a' + i, hid_ascii(0x04 + i, 0, 0), "%d");
	for (int i = 0; i < 9; i++)
		FK_EQ("0x1E..0x26 are 1..9",
		      '1' + i, hid_ascii(0x1E + i, 0, 0), "%d");
	/* 0x27 is ZERO and it comes after the nine, not before the one. */
	FK_EQ("0x27 is '0', last in the row", '0', hid_ascii(0x27, 0, 0), "%d");
}

static void test_against_model(void)
{
	for (int u = 0; u < 256; u++)
		for (int caps = 0; caps <= 1; caps++)
			for (int m = 0; m < 8; m++) {
				int32_t mods = ((m & 1) ? MOD_LSHIFT : 0) |
					       ((m & 2) ? MOD_RSHIFT : 0) |
					       ((m & 4) ? MOD_LCTRL : 0);
				FK_EQ("decode matches the reference model",
				      model(u, mods, caps),
				      hid_ascii(u, mods, caps), "%d");
			}
}

/* Caps and shift COMBINE by exclusive-or on letters and on letters only. */
static void test_caps(void)
{
	FK_EQ("caps alone gives upper case", 'A', hid_ascii(0x04, 0, 1), "%d");
	FK_EQ("shift alone gives upper case",
	      'A', hid_ascii(0x04, MOD_LSHIFT, 0), "%d");
	FK_EQ("shift AND caps gives lower case",
	      'a', hid_ascii(0x04, MOD_LSHIFT, 1), "%d");
	/* The digit row is not a letter: caps must not touch it. */
	FK_EQ("caps does not shift the digit row",
	      '1', hid_ascii(0x1E, 0, 1), "%d");
	FK_EQ("shift still does, with caps on",
	      '!', hid_ascii(0x1E, MOD_LSHIFT, 1), "%d");
}

static void test_modifiers(void)
{
	FK_EQ("left shift is shift",  1, hid_is_shift(MOD_LSHIFT), "%d");
	FK_EQ("right shift is shift", 1, hid_is_shift(MOD_RSHIFT), "%d");
	FK_EQ("ctrl is not shift",    0, hid_is_shift(MOD_LCTRL), "%d");
	FK_EQ("left ctrl is ctrl",    1, hid_is_ctrl(MOD_LCTRL), "%d");
	FK_EQ("right ctrl is ctrl",   1, hid_is_ctrl(MOD_RCTRL), "%d");
	FK_EQ("shift is not ctrl",    0, hid_is_ctrl(MOD_LSHIFT), "%d");
	FK_EQ("no modifier is neither", 0,
	      hid_is_shift(0) + hid_is_ctrl(0), "%d");
}

/* The two control keys a console needs, and the one that has no character. */
static void test_control_keys(void)
{
	FK_EQ("Enter is LF",       10, hid_ascii(0x28, 0, 0), "%d");
	FK_EQ("Backspace is BS",    8, hid_ascii(0x2A, 0, 0), "%d");
	FK_EQ("Tab is HT",          9, hid_ascii(0x2B, 0, 0), "%d");
	FK_EQ("Space is SP",       32, hid_ascii(0x2C, 0, 0), "%d");
	FK_EQ("Escape has no character", 0, hid_ascii(0x29, 0, 0), "%d");
	/* Caps Lock is a key Linux knows and this table gives no character to:
	 * it is state, and the caller owns it. */
	FK_EQ("Caps Lock has no character", 0, hid_ascii(0x39, 0, 0), "%d");
	FK_EQ("and Linux agrees it IS a key",
	      1, usb_kbd_keycode[0x39] != 0, "%d");
}

/* Out-of-range and the reserved rollover codes produce nothing, not garbage. */
static void test_out_of_range(void)
{
	FK_EQ("usage 0 is nothing",   0, hid_ascii(0x00, 0, 0), "%d");
	FK_EQ("ErrorRollOver (1) is nothing", 0, hid_ascii(0x01, 0, 0), "%d");
	FK_EQ("usage 0xFF is nothing", 0, hid_ascii(0xFF, 0, 0), "%d");
	FK_EQ("a negative usage is nothing", 0, hid_ascii(-1, 0, 0), "%d");
	FK_EQ("a usage past the page is nothing",
	      0, hid_ascii(0x1000, 0, 0), "%d");
}

int main(void)
{
	test_coverage_against_linux();
	test_identity_against_linux();
	test_usage_page_order();
	test_against_model();
	test_caps();
	test_modifiers();
	test_control_keys();
	test_out_of_range();
	return fk_report("usb_hid");
}
