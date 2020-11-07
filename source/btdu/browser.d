/*
 * Copyright (C) 2020  Vladimir Panteleev <btdu@cy.md>
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

/// ncurses interface for browsing results
module btdu.browser;

import core.stdc.config;
import core.time;

import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.conv;
import std.path;
import std.string;

import deimos.ncurses;

import btdu.common;
import btdu.state;
import btdu.paths;

struct Browser
{
	BrowserPath* currentPath;
	sizediff_t top; // Scroll offset (row number, in the content, corresponding to the topmost displayed line)
	sizediff_t contentAreaHeight; // Number of rows where scrolling content is displayed
	string selection;
	string[] items, info;
	bool done;

	enum Mode
	{
		browser,
		info,
	}
	Mode mode;

	void start()
	{
		initscr();

		timeout(0); // Use non-blocking read
		cbreak(); // Disable line buffering
		noecho(); // Disable keyboard echo
		keypad(stdscr, true); // Enable arrow keys
		curs_set(0); // Hide cursor

		currentPath = &browserRoot;
	}

	~this()
	{
		endwin();
	}

	@disable this(this);

	string message; MonoTime showMessageUntil;
	void showMessage(string s)
	{
		message = s;
		showMessageUntil = MonoTime.currTime() + (100.msecs * s.length);
	}

	void update()
	{
		int h, w;
		getmaxyx(stdscr, h, w); h++; w++;

		items = currentPath.children.keys;
		items.sort();
		if (!selection && items.length)
			selection = items[0];
		if (!items.length && mode == Mode.browser && currentPath !is &browserRoot)
			mode = Mode.info;

		// Build info
		{
			info = null;

			if (!currentPath.seenAs.empty)
			{
				info ~= ["", "--- Shares data with:"];
				foreach (path; currentPath.seenAs.keys.sort)
					info ~= "- " ~ path.text;
			}

			if (mode == Mode.info && !info.length)
			{
				if (items.length)
					info ~= "  (no info for this node - press i or q to exit)";
				else
					info ~= "  (empty node)";
			}
			// TODO: word-wrap info
		}

		// Scrolling and cursor upkeep
		{
			contentAreaHeight = h - 3;
			size_t contentHeight;
			final switch (mode)
			{
				case Mode.browser:
					contentHeight = items.length;
					break;
				case Mode.info:
					contentHeight = info.length;
					break;
			}

			// Ensure there is no unnecessary space at the bottom
			if (top + contentAreaHeight > contentHeight)
				top = contentHeight - contentAreaHeight;
			// Ensure we are never scrolled "above" the first row
			if (top < 0)
				top = 0;

			final switch (mode)
			{
				case Mode.browser:
				{
					// Ensure the selected item is visible
					auto pos = selection && items ? items.countUntil(selection) : 0;
					top = top.clamp(
						pos - contentAreaHeight + 1,
						pos,
					);
					break;
				}
				case Mode.info:
					break;
			}
		}

		// Rendering
		{
			erase();

			if (h < 10 || w < 32)
			{
				mvprintw(0, 0, "Window too small");
				refresh();
				return;
			}

			attron(A_REVERSE);
			mvhline(0, 0, ' ', w);
			mvprintw(0, 0, "btdu v" ~ btduVersion ~ " ~ Use the arrow keys to navigate");
			mvhline(h - 1, 0, ' ', w);
			if (message && MonoTime.currTime < showMessageUntil)
				mvprintw(h - 1, 0, " %s", message.toStringz);
			else
			{
				auto resolution = browserRoot.samples
					? "~" ~ (totalSize / browserRoot.samples).humanSize()
					: "-";
				mvprintw(h - 1, 0,
					" Samples: %lld  Resolution: %s",
					cast(cpp_longlong)currentPath.samples,
					resolution.toStringz()
				);
			}
			attroff(A_REVERSE);

			auto displayedPath = text(fsPath.asNormalizedPath, currentPath.pointerWriter);
			auto prefix = ["", "INFO: "][mode];
			auto maxPathWidth = w - 8 - prefix.length;
			if (displayedPath.length > maxPathWidth)
				displayedPath = "..." ~ displayedPath[$ - (maxPathWidth - 3) .. $];

			mvhline(1, 0, '-', w);
			mvprintw(1, 3,
				" %s%s ",
				prefix.ptr,
				displayedPath.toStringz()
			);
		}

		final switch (mode)
		{
			case Mode.browser:
			{
				auto mostSamples = currentPath.children.byValue.fold!((a, b) => max(a, b.samples))(0UL);

				foreach (i, item; items)
				{
					auto y = cast(int)(i - top);
					if (y < 0 || y >= contentAreaHeight)
						continue;
					y += 2;

					if (item is selection)
						attron(A_REVERSE);
					else
						attroff(A_REVERSE);
					mvhline(y, 0, ' ', w);

					auto child = currentPath.children[item];
					char[10] bar;
					if (mostSamples)
					{
						auto barPos = 10 * child.samples / mostSamples;
						bar[0 .. barPos] = '#';
						bar[barPos .. $] = ' ';
					}
					else
						bar[] = '-';

					auto size = browserRoot.samples
						? "~" ~ humanSize(child.samples * totalSize / browserRoot.samples)
						: "?";
					auto displayedItem = item;
					auto maxItemWidth = w - 27;
					if (displayedItem.length > maxItemWidth)
					{
						auto leftLength = (maxItemWidth - "...".length) / 2;
						auto rightLength = maxItemWidth - "...".length - leftLength;
						displayedItem =
							displayedItem[0 .. leftLength] ~ "..." ~
							displayedItem[$ - rightLength .. $];
					}
					mvprintw(y, 0,
						"%12s [%.10s] %c%s",
						size.toStringz(),
						bar.ptr,
						child.children is null ? ' ' : '/',
						displayedItem.toStringz(),
					);
				}
				break;
			}

			case Mode.info:
				foreach (i, line; info)
				{
					auto y = cast(int)(i - top);
					if (y < 0 || y >= contentAreaHeight)
						continue;
					y += 2;
					mvprintw(y, 0, "%s", line.toStringz());
				}
				break;
		}

		refresh();
	}

	void moveCursor(sizediff_t delta)
	{
		if (!items.length)
			return;
		auto pos = items.countUntil(selection);
		if (pos < 0)
			return;
		pos += delta;
		if (pos < 0)
			pos = 0;
		if (pos > items.length - 1)
			pos = items.length - 1;
		selection = items[pos];
	}

	bool handleInput()
	{
		auto ch = getch();

		if (ch == ERR)
			return false; // no events - would have blocked
		else
			message = null;

		final switch (mode)
		{
			case Mode.browser:
				switch (ch)
				{
					case KEY_LEFT:
						if (currentPath.parent)
						{
							selection = currentPath.name;
							currentPath = currentPath.parent;
							top = 0;
						}
						else
							showMessage("Already at top-level");
						break;
					case KEY_RIGHT:
						if (selection)
						{
							currentPath = currentPath.children[selection];
							selection = null;
							top = 0;
						}
						else
							showMessage("Nowhere to descend into");
						break;
					case KEY_UP:
						moveCursor(-1);
						break;
					case KEY_DOWN:
						moveCursor(+1);
						break;
					case KEY_PPAGE:
						moveCursor(-contentAreaHeight);
						break;
					case KEY_NPAGE:
						moveCursor(+contentAreaHeight);
						break;
					case KEY_HOME:
						moveCursor(-items.length);
						break;
					case KEY_END:
						moveCursor(+items.length);
						break;
					case 'i':
						mode = Mode.info;
						top = 0;
						break;
					case 'q':
						done = true;
						break;
					default:
						// TODO: show message
						break;
				}
				break;

			case Mode.info:
				switch (ch)
				{
					case KEY_LEFT:
						mode = Mode.browser;
						if (currentPath.parent)
						{
							selection = currentPath.name;
							currentPath = currentPath.parent;
							top = 0;
						}
						break;
					case 'q':
						if (items.length)
							goto case 'i';
						else
							goto case KEY_LEFT;
					case 'i':
						mode = Mode.browser;
						top = 0;
						break;
					case KEY_UP:
						top += -1;
						break;
					case KEY_DOWN:
						top += +1;
						break;
					case KEY_PPAGE:
						top += -contentAreaHeight;
						break;
					case KEY_NPAGE:
						top += +contentAreaHeight;
						break;
					case KEY_HOME:
						top -= info.length;
						break;
					case KEY_END:
						top += info.length;
						break;
					default:
						// TODO: show message
						break;
				}
				break;
		}

		return true;
	}
}

private:

string humanSize(ulong size)
{
	static immutable prefixChars = " KMGTPEZY";
	double fpSize = size;
	size_t power = 0;
	while (fpSize > 1024 && power + 1 < prefixChars.length)
	{
		fpSize /= 1024;
		power++;
	}
	return format("%3.1f %s%sB", fpSize, prefixChars[power], prefixChars[power] == ' ' ? ' ' : 'i');
}

/// Helper type for formatting pointers without passing their contents by-value.
/// Helps preserve the SubPath invariant (which would be broken by copying).
struct PointerWriter(T)
{
	T* ptr;
	void toString(scope void delegate(const(char)[]) sink) const
	{
		ptr.toString(sink);
	}
}
PointerWriter!T pointerWriter(T)(T* ptr) { return PointerWriter!T(ptr); }
