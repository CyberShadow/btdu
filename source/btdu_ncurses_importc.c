// ImportC shim for ncurses
// Captures system ncurses configuration (NCURSES_OPAQUE, etc.) automatically.
//
// This file is compiled by ImportC to extract ncurses declarations.
// C enums export macro constants as D manifest constants.

// Disable glibc inline functions that cause infinite recursion with ImportC
// These inlines (like wctob) shadow libc functions and call themselves
// __NO_INLINE__ prevents features.h from defining __USE_EXTERN_INLINES
#define __NO_INLINE__ 1

#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#define _XOPEN_SOURCE_EXTENDED 1
#include <ncurses.h>

// Export macro constants as C enums (become D manifest constants)
// Using _NC_ prefix; D wrapper aliases these to original names
enum {
    // Attributes
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

    // Return codes
    _NC_OK = OK,
    _NC_ERR = ERR,

    // Configuration (from autoconf)
    _NC_CCHARW_MAX = CCHARW_MAX,

    // Key codes - basic navigation
    _NC_KEY_DOWN = KEY_DOWN,
    _NC_KEY_UP = KEY_UP,
    _NC_KEY_LEFT = KEY_LEFT,
    _NC_KEY_RIGHT = KEY_RIGHT,
    _NC_KEY_HOME = KEY_HOME,
    _NC_KEY_BACKSPACE = KEY_BACKSPACE,
    _NC_KEY_DL = KEY_DL,
    _NC_KEY_IL = KEY_IL,
    _NC_KEY_DC = KEY_DC,
    _NC_KEY_IC = KEY_IC,
    _NC_KEY_EIC = KEY_EIC,
    _NC_KEY_CLEAR = KEY_CLEAR,
    _NC_KEY_EOS = KEY_EOS,
    _NC_KEY_EOL = KEY_EOL,
    _NC_KEY_SF = KEY_SF,
    _NC_KEY_SR = KEY_SR,
    _NC_KEY_NPAGE = KEY_NPAGE,
    _NC_KEY_PPAGE = KEY_PPAGE,
    _NC_KEY_STAB = KEY_STAB,
    _NC_KEY_CTAB = KEY_CTAB,
    _NC_KEY_CATAB = KEY_CATAB,
    _NC_KEY_ENTER = KEY_ENTER,
    _NC_KEY_PRINT = KEY_PRINT,
    _NC_KEY_LL = KEY_LL,
    _NC_KEY_A1 = KEY_A1,
    _NC_KEY_A3 = KEY_A3,
    _NC_KEY_B2 = KEY_B2,
    _NC_KEY_C1 = KEY_C1,
    _NC_KEY_C3 = KEY_C3,
    _NC_KEY_BTAB = KEY_BTAB,
    _NC_KEY_BEG = KEY_BEG,
    _NC_KEY_CANCEL = KEY_CANCEL,
    _NC_KEY_CLOSE = KEY_CLOSE,
    _NC_KEY_COMMAND = KEY_COMMAND,
    _NC_KEY_COPY = KEY_COPY,
    _NC_KEY_CREATE = KEY_CREATE,
    _NC_KEY_END = KEY_END,
    _NC_KEY_EXIT = KEY_EXIT,
    _NC_KEY_FIND = KEY_FIND,
    _NC_KEY_HELP = KEY_HELP,
    _NC_KEY_MARK = KEY_MARK,
    _NC_KEY_MESSAGE = KEY_MESSAGE,
    _NC_KEY_MOVE = KEY_MOVE,
    _NC_KEY_NEXT = KEY_NEXT,
    _NC_KEY_OPEN = KEY_OPEN,
    _NC_KEY_OPTIONS = KEY_OPTIONS,
    _NC_KEY_PREVIOUS = KEY_PREVIOUS,
    _NC_KEY_REDO = KEY_REDO,
    _NC_KEY_REFERENCE = KEY_REFERENCE,
    _NC_KEY_REFRESH = KEY_REFRESH,
    _NC_KEY_REPLACE = KEY_REPLACE,
    _NC_KEY_RESTART = KEY_RESTART,
    _NC_KEY_RESUME = KEY_RESUME,
    _NC_KEY_SAVE = KEY_SAVE,
    _NC_KEY_SUSPEND = KEY_SUSPEND,
    _NC_KEY_UNDO = KEY_UNDO,
    _NC_KEY_MOUSE = KEY_MOUSE,

    // Shifted keys
    _NC_KEY_SBEG = KEY_SBEG,
    _NC_KEY_SCANCEL = KEY_SCANCEL,
    _NC_KEY_SCOMMAND = KEY_SCOMMAND,
    _NC_KEY_SCOPY = KEY_SCOPY,
    _NC_KEY_SCREATE = KEY_SCREATE,
    _NC_KEY_SDC = KEY_SDC,
    _NC_KEY_SDL = KEY_SDL,
    _NC_KEY_SELECT = KEY_SELECT,
    _NC_KEY_SEND = KEY_SEND,
    _NC_KEY_SEOL = KEY_SEOL,
    _NC_KEY_SEXIT = KEY_SEXIT,
    _NC_KEY_SFIND = KEY_SFIND,
    _NC_KEY_SHELP = KEY_SHELP,
    _NC_KEY_SHOME = KEY_SHOME,
    _NC_KEY_SIC = KEY_SIC,
    _NC_KEY_SLEFT = KEY_SLEFT,
    _NC_KEY_SMESSAGE = KEY_SMESSAGE,
    _NC_KEY_SMOVE = KEY_SMOVE,
    _NC_KEY_SNEXT = KEY_SNEXT,
    _NC_KEY_SOPTIONS = KEY_SOPTIONS,
    _NC_KEY_SPREVIOUS = KEY_SPREVIOUS,
    _NC_KEY_SPRINT = KEY_SPRINT,
    _NC_KEY_SREDO = KEY_SREDO,
    _NC_KEY_SREPLACE = KEY_SREPLACE,
    _NC_KEY_SRIGHT = KEY_SRIGHT,
    _NC_KEY_SRSUME = KEY_SRSUME,
    _NC_KEY_SSAVE = KEY_SSAVE,
    _NC_KEY_SSUSPEND = KEY_SSUSPEND,
    _NC_KEY_SUNDO = KEY_SUNDO,

    // Function keys - KEY_F(n) macro
    _NC_KEY_F0 = KEY_F(0),
    _NC_KEY_F1 = KEY_F(1),
    _NC_KEY_F2 = KEY_F(2),
    _NC_KEY_F3 = KEY_F(3),
    _NC_KEY_F4 = KEY_F(4),
    _NC_KEY_F5 = KEY_F(5),
    _NC_KEY_F6 = KEY_F(6),
    _NC_KEY_F7 = KEY_F(7),
    _NC_KEY_F8 = KEY_F(8),
    _NC_KEY_F9 = KEY_F(9),
    _NC_KEY_F10 = KEY_F(10),
    _NC_KEY_F11 = KEY_F(11),
    _NC_KEY_F12 = KEY_F(12),
};
