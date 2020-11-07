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
	string selection;
	string[] items;
	bool done;

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

		erase();
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

		mvhline(1, 0, '-', w);
		mvprintw(1, 3,
			" %s ",
			text(fsPath.asNormalizedPath, currentPath.pointerWriter).toStringz()
		);

		items = currentPath.children.keys;
		items.sort();
		if (!selection && items.length)
			selection = items[0];

		auto mostSamples = currentPath.children.byValue.fold!((a, b) => max(a, b.samples))(0UL);

		foreach (i, item; items)
		{
			auto y = 2 + cast(int)i;

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
			mvprintw(y, 0,
				"%12s [%.10s] %c%s",
				size.toStringz(),
				bar.ptr,
				child.children is null ? ' ' : '/',
				item.toStringz(),
			);
		}

		refresh();
	}

	void handleInput()
	{
		auto ch = getch();

		if (ch != ERR)
			message = null;
		switch (ch)
		{
			case ERR:
				break; // timeout - refresh only
			case KEY_LEFT:
				if (currentPath.parent)
				{
					selection = currentPath.name;
					currentPath = currentPath.parent;
				}
				else
					showMessage("Already at top-level");
				break;
			case KEY_RIGHT:
				if (selection)
				{
					currentPath = currentPath.children[selection];
					selection = null;
				}
				else
					showMessage("Nowhere to descend into");
				break;
			case KEY_UP:
			{
				auto i = items.countUntil(selection);
				if (i >= 0 && i - 1 >= 0)
					selection = items[i - 1];
				break;
			}
			case KEY_DOWN:
			{
				auto i = items.countUntil(selection);
				if (i >= 0 && i + 1 < items.length)
					selection = items[i + 1];
				break;
			}
			case KEY_HOME:
				if (items.length)
					selection = items[0];
				break;
			case KEY_END:
				if (items.length)
					selection = items[$ - 1];
				break;
			case 'q':
				done = true;
				break;
			default:
				// TODO: show message
				break;
		}
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
