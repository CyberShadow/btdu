/// D wrapper for ncurses via ImportC
/// Re-exports ImportC declarations with original ncurses names
module btdu.ui.ncurses;

// Import the C shim - all ncurses declarations become available
public import btdu_ncurses_importc;

// Re-export wchar_t type for compatibility with existing D code
public import core.stdc.stddef : wchar_t;

// Attributes - alias internal names to standard ncurses names
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

// Return codes
alias OK = _NC_OK;
alias ERR = _NC_ERR;

// Configuration
alias CCHARW_MAX = _NC_CCHARW_MAX;

// KEY_F as a CTFE function (matches ncurses KEY_F(n) macro calling convention)
int KEY_F(int n) pure nothrow @nogc @safe
{
    return _NC_KEY_F0 + n;
}

// Basic navigation keys
alias KEY_DOWN = _NC_KEY_DOWN;
alias KEY_UP = _NC_KEY_UP;
alias KEY_LEFT = _NC_KEY_LEFT;
alias KEY_RIGHT = _NC_KEY_RIGHT;
alias KEY_HOME = _NC_KEY_HOME;
alias KEY_BACKSPACE = _NC_KEY_BACKSPACE;
alias KEY_DL = _NC_KEY_DL;
alias KEY_IL = _NC_KEY_IL;
alias KEY_DC = _NC_KEY_DC;
alias KEY_IC = _NC_KEY_IC;
alias KEY_EIC = _NC_KEY_EIC;
alias KEY_CLEAR = _NC_KEY_CLEAR;
alias KEY_EOS = _NC_KEY_EOS;
alias KEY_EOL = _NC_KEY_EOL;
alias KEY_SF = _NC_KEY_SF;
alias KEY_SR = _NC_KEY_SR;
alias KEY_NPAGE = _NC_KEY_NPAGE;
alias KEY_PPAGE = _NC_KEY_PPAGE;
alias KEY_STAB = _NC_KEY_STAB;
alias KEY_CTAB = _NC_KEY_CTAB;
alias KEY_CATAB = _NC_KEY_CATAB;
alias KEY_ENTER = _NC_KEY_ENTER;
alias KEY_PRINT = _NC_KEY_PRINT;
alias KEY_LL = _NC_KEY_LL;
alias KEY_A1 = _NC_KEY_A1;
alias KEY_A3 = _NC_KEY_A3;
alias KEY_B2 = _NC_KEY_B2;
alias KEY_C1 = _NC_KEY_C1;
alias KEY_C3 = _NC_KEY_C3;
alias KEY_BTAB = _NC_KEY_BTAB;
alias KEY_BEG = _NC_KEY_BEG;
alias KEY_CANCEL = _NC_KEY_CANCEL;
alias KEY_CLOSE = _NC_KEY_CLOSE;
alias KEY_COMMAND = _NC_KEY_COMMAND;
alias KEY_COPY = _NC_KEY_COPY;
alias KEY_CREATE = _NC_KEY_CREATE;
alias KEY_END = _NC_KEY_END;
alias KEY_EXIT = _NC_KEY_EXIT;
alias KEY_FIND = _NC_KEY_FIND;
alias KEY_HELP = _NC_KEY_HELP;
alias KEY_MARK = _NC_KEY_MARK;
alias KEY_MESSAGE = _NC_KEY_MESSAGE;
alias KEY_MOVE = _NC_KEY_MOVE;
alias KEY_NEXT = _NC_KEY_NEXT;
alias KEY_OPEN = _NC_KEY_OPEN;
alias KEY_OPTIONS = _NC_KEY_OPTIONS;
alias KEY_PREVIOUS = _NC_KEY_PREVIOUS;
alias KEY_REDO = _NC_KEY_REDO;
alias KEY_REFERENCE = _NC_KEY_REFERENCE;
alias KEY_REFRESH = _NC_KEY_REFRESH;
alias KEY_REPLACE = _NC_KEY_REPLACE;
alias KEY_RESTART = _NC_KEY_RESTART;
alias KEY_RESUME = _NC_KEY_RESUME;
alias KEY_SAVE = _NC_KEY_SAVE;
alias KEY_SUSPEND = _NC_KEY_SUSPEND;
alias KEY_UNDO = _NC_KEY_UNDO;
alias KEY_MOUSE = _NC_KEY_MOUSE;

// Shifted keys
alias KEY_SBEG = _NC_KEY_SBEG;
alias KEY_SCANCEL = _NC_KEY_SCANCEL;
alias KEY_SCOMMAND = _NC_KEY_SCOMMAND;
alias KEY_SCOPY = _NC_KEY_SCOPY;
alias KEY_SCREATE = _NC_KEY_SCREATE;
alias KEY_SDC = _NC_KEY_SDC;
alias KEY_SDL = _NC_KEY_SDL;
alias KEY_SELECT = _NC_KEY_SELECT;
alias KEY_SEND = _NC_KEY_SEND;
alias KEY_SEOL = _NC_KEY_SEOL;
alias KEY_SEXIT = _NC_KEY_SEXIT;
alias KEY_SFIND = _NC_KEY_SFIND;
alias KEY_SHELP = _NC_KEY_SHELP;
alias KEY_SHOME = _NC_KEY_SHOME;
alias KEY_SIC = _NC_KEY_SIC;
alias KEY_SLEFT = _NC_KEY_SLEFT;
alias KEY_SMESSAGE = _NC_KEY_SMESSAGE;
alias KEY_SMOVE = _NC_KEY_SMOVE;
alias KEY_SNEXT = _NC_KEY_SNEXT;
alias KEY_SOPTIONS = _NC_KEY_SOPTIONS;
alias KEY_SPREVIOUS = _NC_KEY_SPREVIOUS;
alias KEY_SPRINT = _NC_KEY_SPRINT;
alias KEY_SREDO = _NC_KEY_SREDO;
alias KEY_SREPLACE = _NC_KEY_SREPLACE;
alias KEY_SRIGHT = _NC_KEY_SRIGHT;
alias KEY_SRSUME = _NC_KEY_SRSUME;
alias KEY_SSAVE = _NC_KEY_SSAVE;
alias KEY_SSUSPEND = _NC_KEY_SSUSPEND;
alias KEY_SUNDO = _NC_KEY_SUNDO;

// Function key aliases for convenience
alias KEY_F0 = _NC_KEY_F0;
alias KEY_F1 = _NC_KEY_F1;
alias KEY_F2 = _NC_KEY_F2;
alias KEY_F3 = _NC_KEY_F3;
alias KEY_F4 = _NC_KEY_F4;
alias KEY_F5 = _NC_KEY_F5;
alias KEY_F6 = _NC_KEY_F6;
alias KEY_F7 = _NC_KEY_F7;
alias KEY_F8 = _NC_KEY_F8;
alias KEY_F9 = _NC_KEY_F9;
alias KEY_F10 = _NC_KEY_F10;
alias KEY_F11 = _NC_KEY_F11;
alias KEY_F12 = _NC_KEY_F12;

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
