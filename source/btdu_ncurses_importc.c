// ImportC shim for ncurses
// Captures system ncurses configuration (NCURSES_OPAQUE, etc.) automatically.
//
// This file is compiled by ImportC to extract ncurses declarations.
// Most ncurses macros are directly accessible via ImportC, but some
// (like A_BOLD) contain casts to typedef types that ImportC can't evaluate.
// We export those as C enums which become D manifest constants.

// Disable glibc inline functions that cause infinite recursion with ImportC.
// These inlines (like wctob) shadow libc functions and call themselves.
// __NO_INLINE__ prevents features.h from defining __USE_EXTERN_INLINES.
#define __NO_INLINE__ 1

// Feature test macros - enables wide character support (NCURSES_WIDECHAR=1)
#define _DEFAULT_SOURCE 1
#define _XOPEN_SOURCE 600
#define _XOPEN_SOURCE_EXTENDED 1

#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0

// Try ncursesw first (wide character support), fall back to ncurses
// Note: dub's "libs" uses pkg-config only for linking, not for C preprocessing,
// so we use __has_include to find the correct header path
#if __has_include(<ncursesw/ncurses.h>)
#include <ncursesw/ncurses.h>
#else
#include <ncurses.h>
#endif

// Wrapper for stdscr - on reentrant ncurses builds (NCURSES_REENTRANT=1),
// stdscr is a macro that expands to a function call which ImportC doesn't export
static inline WINDOW* _nc_get_stdscr(void) { return stdscr; }

// Attributes - these macros use NCURSES_BITS which contains a (chtype) cast
// that ImportC can't evaluate, so we export them as enum constants
enum {
    _NC_A_NORMAL = A_NORMAL,
    _NC_A_STANDOUT = A_STANDOUT,
    _NC_A_UNDERLINE = A_UNDERLINE,
    _NC_A_REVERSE = A_REVERSE,
    _NC_A_BLINK = A_BLINK,
    _NC_A_DIM = A_DIM,
    _NC_A_BOLD = A_BOLD,
    _NC_A_ALTCHARSET = A_ALTCHARSET,
    _NC_A_INVIS = A_INVIS,
    _NC_A_PROTECT = A_PROTECT,
    _NC_A_HORIZONTAL = A_HORIZONTAL,
    _NC_A_LEFT = A_LEFT,
    _NC_A_LOW = A_LOW,
    _NC_A_RIGHT = A_RIGHT,
    _NC_A_TOP = A_TOP,
    _NC_A_VERTICAL = A_VERTICAL,
    _NC_A_ITALIC = A_ITALIC,
};
