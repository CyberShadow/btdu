/// D wrapper for ncurses via ImportC
/// Re-exports ImportC declarations with original ncurses names
module btdu.ui.ncurses;

// Import the C shim - all ncurses declarations become available
// Most ncurses macros (KEY_*, OK, ERR, CCHARW_MAX, KEY_F()) work directly.
// Only A_* attributes need aliasing due to (chtype) casts ImportC can't evaluate.
public import btdu_ncurses_importc;

// Re-export wchar_t type for compatibility with existing D code
public import core.stdc.stddef : wchar_t;

// Wrapper for stdscr - on reentrant ncurses builds (NCURSES_REENTRANT=1),
// stdscr is a macro that expands to a function call which ImportC doesn't export
@property WINDOW* stdscr() @trusted
{
    return _nc_get_stdscr();
}

// Attributes - alias internal names to standard ncurses names
// These need shims because they use NCURSES_BITS macro with (chtype) cast
alias A_NORMAL = _NC_A_NORMAL;
alias A_STANDOUT = _NC_A_STANDOUT;
alias A_UNDERLINE = _NC_A_UNDERLINE;
alias A_REVERSE = _NC_A_REVERSE;
alias A_BLINK = _NC_A_BLINK;
alias A_DIM = _NC_A_DIM;
alias A_BOLD = _NC_A_BOLD;
alias A_ALTCHARSET = _NC_A_ALTCHARSET;
alias A_INVIS = _NC_A_INVIS;
alias A_PROTECT = _NC_A_PROTECT;
alias A_HORIZONTAL = _NC_A_HORIZONTAL;
alias A_LEFT = _NC_A_LEFT;
alias A_LOW = _NC_A_LOW;
alias A_RIGHT = _NC_A_RIGHT;
alias A_TOP = _NC_A_TOP;
alias A_VERTICAL = _NC_A_VERTICAL;
alias A_ITALIC = _NC_A_ITALIC;

// NCURSES_PAIRS_T is a macro that expands to 'short'
alias NCURSES_PAIRS_T = short;

// ============================================================================
// Wrapper functions for type compatibility
// ImportC uses raw C types; these wrappers adapt to D's type system
// ============================================================================

import core.sys.posix.stdio : FILE;

// Wrapper for newterm - handles FILE* type difference
// D's std.stdio.File.getFP() returns shared(_IO_FILE)* but ncurses wants _IO_FILE*
SCREEN* newterm(const(char)* term, FILE* outfd, FILE* infd) @trusted
{
    return btdu_ncurses_importc.newterm(term,
        cast(btdu_ncurses_importc._IO_FILE*) outfd,
        cast(btdu_ncurses_importc._IO_FILE*) infd);
}

// Wrapper for setcchar - handles wchar_t type difference
// D's wchar_t is dchar (4 bytes), but ImportC sees platform-specific wchar_t
// (int on x86_64 glibc, unsigned int on aarch64)
int setcchar(cchar_t* wcval, const(wchar_t)* wch, uint attrs, short color_pair, const(void)* opts) @trusted
{
    // Cast to ImportC's wchar_t type to handle platform differences
    return btdu_ncurses_importc.setcchar(wcval,
        cast(const(btdu_ncurses_importc.wchar_t)*) wch,
        attrs, color_pair, opts);
}
