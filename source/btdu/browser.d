/*  Copyright (C) 2020  Vladimir Panteleev <btdu@cy.md>
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Affero General Public License as
 *  published by the Free Software Foundation, either version 3 of the
 *  License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Affero General Public License for more details.
 *
 *  You should have received a copy of the GNU Affero General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/// ncurses interface for browsing results
module btdu.browser;

import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.conv;
import std.path;
import std.string;

import core.stdc.config;
import core.time;

import btdu.common;
import btdu.state;
import btdu.paths;

import deimos.ncurses;

void runBrowser()
{
	auto window = initscr();
	scope(exit) endwin();

	timeout(500); // Refresh every 500 milliseconds if idle
	cbreak(); // Disable line buffering
	noecho(); // Disable keyboard echo
	keypad(stdscr, true);
	curs_set(0); // Hide cursor

	BrowserPath* currentPath;
	withGlobalState((ref g) {
		currentPath = &g.browserRoot;
	});
	string selection;

	string message; MonoTime showMessageUntil;
	void showMessage(string s)
	{
		message = s;
		showMessageUntil = MonoTime.currTime() + (100.msecs * s.length);
	}

	bool done;
	while (!done)
	{
		string[] items;

		withGlobalState((ref g) {
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
				mvprintw(h - 1, 0,
					" Samples: %lld  Resolution: ~%s",
					cast(cpp_longlong)currentPath.samples,
					(globalParams.totalSize / g.browserRoot.samples).humanSize().toStringz()
				);
			attroff(A_REVERSE);

			mvhline(1, 0, '-', w);
			mvprintw(1, 3,
				" %s ",
				text(globalParams.fsPath.asNormalizedPath, currentPath.pointerWriter).toStringz()
			);

			auto children = currentPath.getChildren(g);
			items = children.keys;
			items.sort();
			if (!selection && items.length)
				selection = items[0];

			auto mostSamples = children.byValue.fold!((a, b) => max(a, b.samples))(0UL);

			foreach (i, item; items)
			{
				auto y = 2 + cast(int)i;

				if (item is selection)
					attron(A_REVERSE);
				else
					attroff(A_REVERSE);
				mvhline(y, 0, ' ', w);

				auto child = children[item];
				char[10] bar;
				auto barPos = 10 * child.samples / mostSamples;
				bar[0 .. barPos] = '#';
				bar[barPos .. $] = ' ';

				mvprintw(y, 0,
					"%12s [%.10s] %c%s",
					("~" ~ humanSize(child.samples * globalParams.totalSize / g.browserRoot.samples)).toStringz(),
					bar.ptr,
					child.getChildren(g) is null ? ' ' : '/',
					item.toStringz(),
				);
			}
		});

		refresh();
		auto ch = getch();

		withGlobalState((ref g) {
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
						currentPath = currentPath.getChildren(g)[selection];
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
		});
	}
}
