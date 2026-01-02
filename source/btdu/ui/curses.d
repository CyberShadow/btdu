/*
 * Copyright (C) 2023, 2024, 2025  Vladimir Panteleev <btdu@cy.md>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License v2 as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program; if not, write to the
 * Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 021110-1307, USA.
 */

/// ncurses wrapper
module btdu.ui.curses;

import core.lifetime : forward;
import core.stdc.stddef : wchar_t;
import core.sys.posix.locale;
import core.sys.posix.stdio : FILE;

import std.algorithm.comparison : min, max;
import std.conv;
import std.exception;
import std.meta;
import std.socket;
import std.stdio : File;
import std.typecons;

import ae.utils.text.functor : stringifiable, fmtSeq;
import ae.utils.functor.primitives : functor;
import ae.utils.typecons : require;

import btdu.ui.ncurses;

struct Curses
{
	@disable this(this);

	Socket stdinSocket;

	void start()
	{
		initLocale();

		// Smarter alternative to initscr()
		{
			import core.stdc.stdlib : getenv;
			import core.sys.posix.unistd : isatty, STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO;
			import core.sys.posix.fcntl : open, O_RDWR, O_NOCTTY;
			import core.sys.posix.stdio : fdopen;

			int inputFD = {
				if (isatty(STDIN_FILENO))
					return STDIN_FILENO;
				ttyFD = open("/dev/tty", O_RDWR);
				if (ttyFD >= 0 && isatty(ttyFD))
					return ttyFD;
				throw new Exception("Could not detect a TTY to read interactive input from.");
			}();
			int outputFD = {
				if (isatty(STDOUT_FILENO))
					return STDOUT_FILENO;
				if (isatty(STDERR_FILENO))
					return STDERR_FILENO;
				if (ttyFD < 0)
					ttyFD = open("/dev/tty", O_RDWR);
				if (ttyFD >= 0 && isatty(ttyFD))
					return ttyFD;
				throw new Exception("Could not detect a TTY to display interactive UI on.");
			}();

			inputFile.fdopen(inputFD, "rb");
			outputFile.fdopen(outputFD, "wb");
			auto screen = newterm(getenv("TERM"), outputFile.getFP(), inputFile.getFP());
			enforce(screen,
				"Could not create the ncurses screen object. " ~
				"Are terminfo files installed for your terminal? " ~
				"Perhaps try running with \"TERM=xterm\"."
			);

			stdinSocket = new Socket(cast(socket_t)inputFD, AddressFamily.UNSPEC);
			stdinSocket.blocking = false;
		}

		timeout(0); // Use non-blocking read
		cbreak(); // Disable line buffering
		noecho(); // Disable keyboard echo
		keypad(stdscr, true); // Enable arrow keys
		curs_set(0); // Hide cursor
		leaveok(stdscr, true); // Don't bother moving the physical cursor
	}

	~this()
	{
		endwin();

		{
			import core.stdc.stdio : fclose;
			import core.sys.posix.unistd : close;

			if (stdinSocket)
				stdinSocket.blocking = true;
			inputFile.close();
			outputFile.close();
			if (ttyFD >= 0)
				close(ttyFD);
		}
	}

	/// A tool used to fling curses at unsuspecting terminal emulators.
	struct Wand
	{
	private:
		// --- State

		alias xy_t = int; // Type for cursor coordinates

		/// What to do when the cursor goes beyond the window width.
		enum XOverflow
		{
			/// Text will never exceed the window width - the caller ensures it.
			/// If it does happen, raise an assertion and truncate.
			never,

			/// Silently truncate.
			hidden,

			/// Wrap characters (dumb wrapping).
			chars,

			/// Wrap words.
			words,

			/// Wrap paths (like words, but break on /); hyphenate.
			path,

			/// Do not wrap, but draw ellipses if truncation occurred.
			ellipsis,
		}
		XOverflow xOverflow = XOverflow.never; /// ditto

		/// What to do when the cursor goes beyond the window height.
		enum YOverflow
		{
			/// Text will never exceed the window height - the caller ensures it.
			/// If it does happen, raise an assertion and truncate.
			never,

			/// Silently truncate.
			hidden,
		}
		YOverflow yOverflow = YOverflow.never; /// ditto

		/// Current attributes.
		// Though we could use the ones in WINDOW (via wattr_get, wattr_set, wattr_on etc.),
		// we never use any ncurses APIs which use them, and this way is simpler.
		attr_t attr;
		NCURSES_PAIRS_T color;

		/// Set `value` to `newValue`, then run `fn`, and restore the old value on exit.
		void withState(T)(ref T value, T newValue, scope void delegate() fn)
		{
			auto oldValue = value;
			scope(exit) value = oldValue;
			value = newValue;
			fn();
		}

		/// Run `fn`, restoring the cursor position on exit.
		void saveCursor(scope void delegate() fn)
		{
			auto x = this.x;
			auto y = this.y;
			scope(exit)
			{
				this.x = x;
				this.y = y;
			}
			fn();
		}

		// --- ncurses primitives

		/// Absolute coordinates of current window top-left and bottom-right.
		/// These control the logical geometry, e.g. at which word wrapping happens.
		xy_t x0, y0, x1, y1;

		/// Rectangle of where we may actually draw now.
		/// Subset of current window (relative to x0/y0).
		xy_t maskX0, maskY0, maskX1, maskY1;

		void withNCWindow(scope void delegate(WINDOW*) fn)
		{
			auto win = derwin(stdscr, height, width, y0, x0);
			scope(exit) delwin(win);
			fn(win);
		}

		/// Returns `true` if `x` and `y` are within the bounds of the current window.
		bool inBounds(xy_t x, xy_t y) { return x >= 0 && x < width && y >= 0 && y < height; }

		/// Returns `true` if `x` and `y` are within the drawable rectangle.
		bool inMask(xy_t x, xy_t y) { x += x0; y += y0; return x >= maskX0 && x < maskX1 && y >= maskY0 && y < maskY1; }

		/// Low-level write primitive
		void poke(xy_t x, xy_t y, cchar_t c)
		{
			assert(inMask(x, y));
			x += x0; y += y0;
			mvwadd_wchnstr(stdscr, y.to!int, x.to!int, &c, 1).ncenforce("mvwadd_wchnstr");
		}

		/// Low-level read primitive
		cchar_t peek(xy_t x, xy_t y)
		{
			assert(inMask(x, y));
			cchar_t wch;
			x += x0; y += y0;
			mvwin_wch(stdscr, y.to!int, x.to!int, &wch).ncenforce("mvwin_wch");
			return wch;
		}

		// --- Output implementation

		void wordWrap()
		{
			// A "clever" way to do word-wrap without requiring
			// dynamic memory allocation is to blit strings
			// immediately directly to the screen, then whenever we
			// find that we are running out of horizontal space, move
			// any half-written word by reading what we wrote back
			// from screen.

			// Move the cursor to the next line. This happens regardless.
			auto origX = x;
			auto origY = y;
			// Update maxX to reflect that the line filled up to the wrap point.
			// This is needed for measure() to correctly calculate the content width
			// when wrapping occurs at natural break points (words/paths).
			maxX = max(maxX, width);
			newLine();

			auto space = " "d.ptr.toCChar(attr, color);
			if (lastSpaceY == origY)
			{
				assert(lastSpaceX < origX);
				// There is a space at X coordinate `lastSpaceX`.
				// Move everything after it to a new line.
				xy_t startX = lastSpaceX + 1;
				// Skip any additional spaces at the start
				while (startX < origX && inMask(startX, origY) && peek(startX, origY) == space)
				{
					poke(startX, origY, space);
					startX++;
				}
				foreach (j; startX .. origX)
				{
					// auto ok = prePut();
					// put(ok ? peek(j, origY) : space);
					if (inMask(j, origY))
					{
						put(peek(j, origY), 1);
						poke(j, origY, space);
					}
					else
					{
						// The word that needs to be wrapped is off-screen, so we lost those characters,
						// and therefore can't copy them to the potentially-now-visible row.
						// But that's OK, because btdu draws overflow markers on the top line of
						// scrollable views anyway.
						put("•");
					}
				}
				// The cursor is now after the last character, and we are ready to write more.
				return;
			}

			// We did not find a blank, so just put a hyphen if we can.
			if (origX >= 2 && inMask(origX - 1, origY))
			{
				put(peek(origX - 1, origY), 1);
				poke(origX - 1, origY, "‐"d.ptr.toCChar(attr, color));
			}
		}

		xy_t lastSpaceX = xy_t.min, lastSpaceY = xy_t.min;

		/// We are about to write a single character.
		/// Perform any upkeep on the current state to ensure
		/// that the next write will go to the resulting (x, y).
		/// Return true if the write at the resulting (x, y) will be valid;
		/// otherwise, the caller should just advance the cursor and give up.
		bool prePut()
		out (result; result == inBounds(x, y))
		{
			if (x < 0)
				return false;

			if (x >= width)
				final switch (xOverflow)
				{
					case XOverflow.never:
						assert(x < width, "X overflow");
						return false;
					case XOverflow.hidden:
						return false;
					case XOverflow.chars:
						newLine();
						return prePut(); // retry
					case XOverflow.words:
					case XOverflow.path:
						wordWrap();
						return prePut(); // retry
					case XOverflow.ellipsis:
						if (x == width) // only print the ellipsis this once
						{
							saveCursor({
								x = width - 1;
								put("…");
							});
						}
						return false;
				}

			if (y < 0 || y >= height)
				final switch (yOverflow)
				{
					case YOverflow.never:
						assert(y >= 0 && y < height, "Y overflow");
						return false;

					case YOverflow.hidden:
						return false;
				}

			return true;
		}

		/// Put a raw `cchar_t`, obeying overflow and advancing the cursor.
		void put(cchar_t c, int width)
		{
			bool ok = prePut();

			auto breakChar = xOverflow == XOverflow.path ? '/' : ' ';
			if (c.chars[0] == breakChar && c.chars[1] == 0)
			{
				lastSpaceX = x;
				lastSpaceY = y;
			}

			if (inMask(x, y))
				poke(x, y, c);
			x += width;
			maxX = max(maxX, x);
		}

		// --- Text output (low-level)

		alias Sink = typeof(&put);

		void put(const(char)[] str)
		{
			toCChars(str, &put, attr, color);
		}

		@property void delegate(const(char)[] str) sink() return { return &put; }

		void newLine(dchar filler = ' ')
		{
			// Fill with current background color / attributes
			auto fillerCChar = filler.toCChar(attr, color);
			auto oldMaxX = maxX;
			while (x + x0 < maskX0 || inMask(x, y))
				put(fillerCChar, 1);
			maxX = oldMaxX;
			x = xMargin; // CR
			y++;   // LF
		}

	public:

		// --- Lifetime

		@disable this();
		@disable this(this);

		this(ref Curses curses)
		{
			erase();
			x0 = y0 = maskX0 = maskY0 = x = y = xMargin = 0;
			x1 = maskX1 = getmaxx(stdscr).to!xy_t;
			y1 = maskY1 = getmaxy(stdscr).to!xy_t;
		}

		~this()
		{
			refresh();
		}

		// --- Geometry

		@property xy_t width() { return x1 - x0; }
		@property xy_t height() { return y1 - y0; }

		/// Cursor coordinates used by `put` et al.
		/// Relative to `x0` / `y0`.
		// ncurses does not allow the cursor to go beyond the window
		// geometry, but we need that to detect and handle overflow.
		// This is why we maintain our own cursor coordinates, and
		// only use ncurses' window cursor coordinates for ncurses
		// read/write operations.
		xy_t x, y;

		/// `x` will be reset to this value when going to a new line.
		// TODO: this is probably redundant with simply opening a window at a negative x.
		xy_t xMargin;

		/// High water mark for highest seen X; used by `measure`.
		/// Like `x`, relative to `x0`.
		xy_t maxX;

		void withWindow(xy_t x0, xy_t y0, xy_t width, xy_t height, scope void delegate() fn)
		{
			alias vars = AliasSeq!(
				this.x, this.y,
				this.x0, this.y0,
				this.x1, this.y1,
				this.xMargin, this.maxX,
				this.maskX0, maskY0,
				this.maskX1, maskY1,
			);
			auto newX0 = this.x0 + x0;
			auto newY0 = this.y0 + y0;
			auto newX1 = newX0 + width;
			auto newY1 = newY0 + height;
			auto newMaskX0 = max(this.maskX0, newX0);
			auto newMaskY0 = max(this.maskY0, newY0);
			auto newMaskX1 = min(this.maskX1, newX0 + width);
			auto newMaskY1 = min(this.maskY1, newY0 + height);
			alias newVars = AliasSeq!(
				0, 0,
				newX0, newY0,
				newX1, newY1,
				0, 0,
				newMaskX0, newMaskY0,
				newMaskX1, newMaskY1,
			);
			auto oldVars = vars;
			scope(exit)
				vars = oldVars;
			vars = newVars;
			this.lastSpaceX = this.lastSpaceY = xy_t.min;
			fn();
		}

		void eraseWindow() { withNCWindow(w => .werase(w).ncenforce()); }

		// --- State

		void at(xy_t x, xy_t y, scope void delegate() fn)
		{
			saveCursor({
				this.x = x;
				this.y = y;
				fn();
			});
		}

		void xOverflowHidden  (scope void delegate() fn) { withState(xOverflow, XOverflow.hidden  , fn); }
		void xOverflowChars   (scope void delegate() fn) { withState(xOverflow, XOverflow.chars   , fn); }
		void xOverflowWords   (scope void delegate() fn) { withState(xOverflow, XOverflow.words   , fn); }
		void xOverflowPath    (scope void delegate() fn) { withState(xOverflow, XOverflow.path    , fn); }
		void xOverflowEllipsis(scope void delegate() fn) { withState(xOverflow, XOverflow.ellipsis, fn); }
		void yOverflowHidden  (scope void delegate() fn) { withState(yOverflow, YOverflow.hidden  , fn); }

		enum Attribute : attr_t
		{
			reverse = A_REVERSE,
			bold = A_BOLD,
			dim = A_DIM,
		}

		void attrSet(Attribute attribute, bool set, scope void delegate() fn)
		{
			withState(attr, set ? attr | attribute : attr & ~attribute, fn);
		}

		void attrOn (Attribute attribute, scope void delegate() fn) { attrSet(attribute, true , fn); }
		void attrOff(Attribute attribute, scope void delegate() fn) { attrSet(attribute, false, fn); }
		void reverse(scope void delegate() fn) { attrOn(Attribute.reverse, fn); }
		void dim    (scope void delegate() fn) { attrOn(Attribute.dim    , fn); }

		// --- Text output (high-level)

		/// Write some stringifiable objects.
		void write(Args...)(auto ref Args args)
		{
			import std.format : formattedWrite;
			foreach (ref arg; args)
				formattedWrite!"%s"(sink, arg);
		}

		/// Special stringifiable object. `write` this to end the current line.
		auto endl(dchar filler = ' ') { return functor!((self, filler, sink) { self.newLine(filler); })(&this, filler).stringifiable; }

		/// Special stringifiable objects which temporarily change attributes.
		auto withAttr(Args...)(Attribute attribute, bool set, auto ref Args args)
		{
			auto content = fmtSeq(args);
			return functor!((self, attribute, set, ref content, ref sink) {
				self.attrSet(attribute, set, {
					content.toString(sink);
				});
			})(&this, attribute, set, content).stringifiable;
		}
		auto bold    (Args...)(auto ref Args args) { return withAttr(Attribute.bold   , true, forward!args); }
		auto reversed(Args...)(auto ref Args args) { return withAttr(Attribute.reverse, true, forward!args); }
		auto dimmed  (Args...)(auto ref Args args) { return withAttr(Attribute.dim    , true, forward!args); }

		/// Get the width (in coordinates) of the given stringifiables.
		size_t getTextWidth(Args...)(auto ref Args args)
		{
			struct Sink
			{
				size_t count;
				void charSink(cchar_t, int width) { count += width; }
				void put(const(char)[] str)
				{
					toCChars(str, &charSink, 0, 0);
				}
			}
			Sink sink;
			import std.format : formattedWrite;
			foreach (ref arg; args)
				formattedWrite!"%s"(&sink, arg);
			return sink.count;
		}

		/// Measure how much space writes done by `fn` will take,
		/// assuming current window size and wrapping mode.
		xy_t[2] measure(scope void delegate() fn)
		{
			xy_t[2] result;
			// Start at `height` so that the text is guaranteed to be off-screen
			// and thus invisible for the sake of this measurement.
			auto oldMaxX = maxX;
			scope(success) maxX = oldMaxX;
			at(xMargin, height, {
				maxX = xMargin;
				yOverflowHidden({
					fn();
				});
				assert(y >= height);
				if (x != xMargin) y++;
				auto localMaxX = maxX - xMargin;
				auto localMaxY = y - height;
				result = [localMaxX, localMaxY];
			});
			return result;
		}

		enum Alignment : byte { left = -1, center = 0, right = 1 }

		/// Tables!
		void writeTable(
			int columns, int rows,
			scope void delegate(int, int) writeCell,
			scope Alignment delegate(int, int) getAlignment,
		)
		{
			auto columnX = this.x;
			auto rowY(int row) { return y + row + (row >= 1 ? 1 : 0); }
			foreach (column; 0 .. columns)
			{
				if (column > 0)
				{
					foreach (row; 0 .. rows)
						withWindow(columnX, rowY(row), 3, 1, { write(" │ "); });
					withWindow(columnX, y + 1, 3, 1, { write("─┼─"); });
					columnX += 3;
				}
				int maxWidth = 0;
				foreach (row; 0 .. rows)
					withWindow(columnX, rowY(row), xy_t.max / 2, 1, {
						auto cellSize = measure({ writeCell(column, row); });
						assert(cellSize[1] <= 1, "Multi-line table cells not supported");
						maxWidth = max(maxWidth, cellSize[0]);
					});
				foreach (row; 0 .. rows)
					withWindow(columnX, rowY(row), maxWidth, 1, {
						final switch (getAlignment(column, row))
						{
							case Alignment.left:
								writeCell(column, row);
								break;
							case Alignment.center:
								auto cellSize = measure({ writeCell(column, row); });
								x += (width - cellSize[0]) / 2;
								writeCell(column, row);
								break;
							case Alignment.right:
								auto cellSize = measure({ writeCell(column, row); });
								x += width - cellSize[0];
								writeCell(column, row);
								assert(x == width);
								break;
						}
					});
				withWindow(columnX, y + 1, maxWidth, 1, { write(endl('─')); });
				columnX += maxWidth;
			}
			maxX = max(maxX, columnX);
			y += rows + 1;
		}

		void middleTruncate(scope void delegate() fn)
		{
			// This should be used in a fresh window, and will span the entire width
			assert(x == 0 && maxX == 0);
			xOverflowHidden({
				fn();
				assert(maxX >= x);
				auto totalWidth = maxX;
				if (totalWidth > width)
				{
					auto ellipsis = /*width >= 9 ? "..."d : */"…"d;
					auto ellipsisWidth = ellipsis.length.to!xy_t;
					auto leftWidth = (width - ellipsisWidth) / 2;
					auto rightWidth = width - ellipsisWidth - leftWidth;
					at(leftWidth, 0, {
						write(ellipsis);
					});
					withWindow(leftWidth + ellipsisWidth, 0, rightWidth, 1, {
						x -= totalWidth - rightWidth;
						fn();
					});
				}
			});
		}
	}

	Wand getWand() { return Wand(this); }

	static struct Key
	{
		enum : int
		{
			none        = ERR             , /// No key - try again

			down        = KEY_DOWN        , /// down-arrow key
			up          = KEY_UP          , /// up-arrow key
			left        = KEY_LEFT        , /// left-arrow key
			right       = KEY_RIGHT       , /// right-arrow key
			home        = KEY_HOME        , /// home key
			// backspace   = KEY_BACKSPACE   , /// backspace key
			// f0          = KEY_F0          , /// Function keys.  Space for 64
			f1          = KEY_F(1)        ,
			// f2          = KEY_F(2)        ,
			// f3          = KEY_F(3)        ,
			// f4          = KEY_F(4)        ,
			// f5          = KEY_F(5)        ,
			// f6          = KEY_F(6)        ,
			// f7          = KEY_F(7)        ,
			// f8          = KEY_F(8)        ,
			// f9          = KEY_F(9)        ,
			// f10         = KEY_F(10)       ,
			// f11         = KEY_F(11)       ,
			// f12         = KEY_F(12)       ,
			// dl          = KEY_DL          , /// delete-line key
			// il          = KEY_IL          , /// insert-line key
			// dc          = KEY_DC          , /// delete-character key
			// ic          = KEY_IC          , /// insert-character key
			// eic         = KEY_EIC         , /// sent by rmir or smir in insert mode
			// clear       = KEY_CLEAR       , /// clear-screen or erase key
			// eos         = KEY_EOS         , /// clear-to-end-of-screen key
			// eol         = KEY_EOL         , /// clear-to-end-of-line key
			// sf          = KEY_SF          , /// scroll-forward key
			// sr          = KEY_SR          , /// scroll-backward key
			pageDown    = KEY_NPAGE       , /// next-page key
			pageUp      = KEY_PPAGE       , /// previous-page key
			// stab        = KEY_STAB        , /// set-tab key
			// ctab        = KEY_CTAB        , /// clear-tab key
			// catab       = KEY_CATAB       , /// clear-all-tabs key
			// enter       = KEY_ENTER       , /// enter/send key
			// print       = KEY_PRINT       , /// print key
			// ll          = KEY_LL          , /// lower-left key (home down)
			// a1          = KEY_A1          , /// upper left of keypad
			// a3          = KEY_A3          , /// upper right of keypad
			// b2          = KEY_B2          , /// center of keypad
			// c1          = KEY_C1          , /// lower left of keypad
			// c3          = KEY_C3          , /// lower right of keypad
			// btab        = KEY_BTAB        , /// back-tab key
			// beg         = KEY_BEG         , /// begin key
			// cancel      = KEY_CANCEL      , /// cancel key
			// close       = KEY_CLOSE       , /// close key
			// command     = KEY_COMMAND     , /// command key
			// copy        = KEY_COPY        , /// copy key
			// create      = KEY_CREATE      , /// create key
			end         = KEY_END         , /// end key
			// exit        = KEY_EXIT        , /// exit key
			// find        = KEY_FIND        , /// find key
			// help        = KEY_HELP        , /// help key
			// mark        = KEY_MARK        , /// mark key
			// message     = KEY_MESSAGE     , /// message key
			// move        = KEY_MOVE        , /// move key
			// next        = KEY_NEXT        , /// next key
			// open        = KEY_OPEN        , /// open key
			// options     = KEY_OPTIONS     , /// options key
			// previous    = KEY_PREVIOUS    , /// previous key
			// redo        = KEY_REDO        , /// redo key
			// reference   = KEY_REFERENCE   , /// reference key
			// refresh     = KEY_REFRESH     , /// refresh key
			// replace     = KEY_REPLACE     , /// replace key
			// restart     = KEY_RESTART     , /// restart key
			// resume      = KEY_RESUME      , /// resume key
			// save        = KEY_SAVE        , /// save key
			// sbeg        = KEY_SBEG        , /// shifted begin key
			// scancel     = KEY_SCANCEL     , /// shifted cancel key
			// scommand    = KEY_SCOMMAND    , /// shifted command key
			// scopy       = KEY_SCOPY       , /// shifted copy key
			// screate     = KEY_SCREATE     , /// shifted create key
			// sdc         = KEY_SDC         , /// shifted delete-character key
			// sdl         = KEY_SDL         , /// shifted delete-line key
			// select      = KEY_SELECT      , /// select key
			// send        = KEY_SEND        , /// shifted end key
			// seol        = KEY_SEOL        , /// shifted clear-to-end-of-line key
			// sexit       = KEY_SEXIT       , /// shifted exit key
			// sfind       = KEY_SFIND       , /// shifted find key
			// shelp       = KEY_SHELP       , /// shifted help key
			// shome       = KEY_SHOME       , /// shifted home key
			// sic         = KEY_SIC         , /// shifted insert-character key
			// sleft       = KEY_SLEFT       , /// shifted left-arrow key
			// smessage    = KEY_SMESSAGE    , /// shifted message key
			// smove       = KEY_SMOVE       , /// shifted move key
			// snext       = KEY_SNEXT       , /// shifted next key
			// soptions    = KEY_SOPTIONS    , /// shifted options key
			// sprevious   = KEY_SPREVIOUS   , /// shifted previous key
			// sprint      = KEY_SPRINT      , /// shifted print key
			// sredo       = KEY_SREDO       , /// shifted redo key
			// sreplace    = KEY_SREPLACE    , /// shifted replace key
			// sright      = KEY_SRIGHT      , /// shifted right-arrow key
			// srsume      = KEY_SRSUME      , /// shifted resume key
			// ssave       = KEY_SSAVE       , /// shifted save key
			// ssuspend    = KEY_SSUSPEND    , /// shifted suspend key
			// sundo       = KEY_SUNDO       , /// shifted undo key
			// suspend     = KEY_SUSPEND     , /// suspend key
			// undo        = KEY_UNDO        , /// undo key
			// mouse       = KEY_MOUSE       , /// Mouse event has occurred
		}

		typeof(none) key; alias key this;
		this(typeof(none) key) { this.key = key; }
	}

	Key readKey() { return Key(getch()); }

	void suspend(scope void delegate(File input, File output) fn)
	{
		def_prog_mode();
		endwin();
		stdinSocket.blocking = true;
		scope (exit)
		{
			stdinSocket.blocking = false;
			reset_prog_mode();
			refresh();
		}
		fn(inputFile, outputFile);
	}

	void beep()
	{
		.beep();
	}

	enum ClipboardResult
	{
		system,   /// Copied via system clipboard tool (xclip, xsel, wl-copy)
		terminal, /// Copied via OSC 52 terminal escape sequence
	}

	/// Copy text to the system clipboard.
	/// Tries xclip, xsel, wl-copy in order, then falls back to OSC 52.
	ClipboardResult copyToClipboard(const(char)[] text)
	{
		import std.process : spawnProcess, wait, environment, pipe;

		bool tryCommand(string[] cmd)
		{
			try
			{
				auto devNull = File("/dev/null", "w");
				auto stdinPipe = pipe();
				auto pid = spawnProcess(cmd, stdinPipe.readEnd, devNull, devNull);
				stdinPipe.readEnd.close();
				stdinPipe.writeEnd.write(text);
				stdinPipe.writeEnd.close();
				return wait(pid) == 0;
			}
			catch (Exception)
				return false;
		}

		// Try Wayland clipboard tool
		if ("WAYLAND_DISPLAY" in environment)
		{
			if (tryCommand(["wl-copy"]))
				return ClipboardResult.system;
		}

		// Try X11 clipboard tools
		if ("DISPLAY" in environment)
		{
			if (tryCommand(["xclip", "-selection", "clipboard"]))
				return ClipboardResult.system;
			if (tryCommand(["xsel", "--clipboard", "--input"]))
				return ClipboardResult.system;
		}

		// Fall back to OSC 52 escape sequence
		import std.base64 : Base64;
		outputFile.write("\033]52;c;");
		outputFile.write(Base64.encode(cast(const(ubyte)[])text));
		outputFile.write("\007");
		outputFile.flush();
		return ClipboardResult.terminal;
	}

private:
	int ttyFD = -1;
	File inputFile, outputFile;
}

private:

// TODO: upstream into Druntime
extern (C) int wcwidth(wchar_t c);

/// Replacement character used when wcwidth returns -1 (non-printable or invalid).
/// Must be ASCII to guarantee it works in any locale.
enum safeReplacementChar = '?';

/// Unicode characters used in the btdu UI that must be renderable.
/// These should all have wcwidth == 1 in a proper UTF-8 locale.
immutable dchar[] uiTestChars = [
	'│', '├', '└', '─', '┼', '┬', '┴',  // Box drawing
	'↑', '↓', '←', '→', '↵',            // Arrows
	'█', '▓', '▒', '░',                  // Block elements
];

/// A CJK character to verify wcwidth returns 2 (not just 1 for everything).
enum cjkTestChar = '漢';  // U+6F22, should be width 2

/// Initialize locale for UTF-8 support.
/// Tries user's locale first, then falls back to explicit UTF-8 locales.
/// Throws if no working UTF-8 locale can be found.
void initLocale()
{
	import std.exception : enforce;

	// Locales to try in order of preference
	static immutable locales = ["", "C.UTF-8", "en_US.UTF-8"];

	foreach (locale; locales)
	{
		if (tryLocale(locale.ptr))
			return;
	}

	throw new Exception(
		"Cannot initialize a UTF-8 locale for rendering the UI.\n" ~
		"Tried: (default), C.UTF-8, en_US.UTF-8\n" ~
		"Please ensure a UTF-8 locale is available and try setting LANG=C.UTF-8 or LANG=en_US.UTF-8"
	);
}

/// Try to set the given locale and verify wcwidth works correctly.
/// Returns true if the locale is usable, false otherwise.
bool tryLocale(scope const(char)* locale)
{
	if (setlocale(LC_CTYPE, locale) is null)
		return false;

	// Verify wcwidth works for all UI characters (should return 1)
	foreach (c; uiTestChars)
	{
		if (wcwidth(c) != 1)
			return false;
	}

	// Verify CJK character returns width 2 (confirms wcwidth is truly working)
	if (wcwidth(cjkTestChar) != 2)
		return false;

	// Verify our safe replacement character has width 1
	if (wcwidth(safeReplacementChar) != 1)
		return false;

	return true;
}

void ncenforce(int value, string message = "ncurses call failed")
{
	enforce(value == OK, message);
}

/// Convert nul-terminated string of wchar_t `c` to `cchar_t`, using `setcchar`.
cchar_t toCChar(const(wchar_t)* c, uint attr, NCURSES_PAIRS_T color = 0)
{
	import std.utf : replacementDchar;
	static immutable wchar_t[2] fallback = [replacementDchar, 0];
	cchar_t cchar;
	if (setcchar(&cchar, c, attr, color, null) != OK)
		enforce(setcchar(&cchar, fallback.ptr, attr, color, null) == OK, "Can't encode replacement character");
	return cchar;
}

/// Convert a single (spacing) character to `cchar_t`.
cchar_t toCChar(dchar c, uint attr, NCURSES_PAIRS_T color = 0)
{
	wchar_t[2] wchars = [c, 0];
	return toCChar(wchars.ptr, attr, color);
}

/// Decode UTF-8 string `str`, passing resulting `cchar_t`s to the provided sink.
void toCChars(const(char)[] str, scope void delegate(cchar_t, int) sink, uint attr, NCURSES_PAIRS_T color = 0)
{
	import std.utf : byDchar;
	auto dchars = str.byDchar(); // This will also replace bad UTF-8 with replacementDchar.
	while (!dchars.empty)
	{
		// Discard leading nonspacing characters. ncurses cannot accept them anyway.
		while (!dchars.empty && wcwidth(dchars.front) == 0)
			dchars.popFront();
		if (dchars.empty)
			break;
		auto width = wcwidth(dchars.front);
		wchar_t[CCHARW_MAX + /*nul-terminator*/ 1] wchars;
		size_t i = 0;
		if (width == -1)
		{
			// Non-printable character - replace with visible marker
			wchars[i++] = safeReplacementChar;
			width = 1;
			dchars.popFront();
		}
		else
		{
			// Copy one spacing and up to CCHARW_MAX-1 nonspacing characters
			assert(width > 0);
			wchars[i++] = dchars.front;
			dchars.popFront();
			while (i < CCHARW_MAX && !dchars.empty && wcwidth(dchars.front) == 0)
			{
				wchars[i++] = dchars.front;
				dchars.popFront();
			}
		}
		wchars[i] = 0;
		sink(toCChar(wchars.ptr, attr, color), width);
	}
}
