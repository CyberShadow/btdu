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

/// Common definitions
module btdu.common;

import std.format;

enum btduVersion = "0.0.1";

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

struct PointerWriter(T)
{
	T* ptr;
	void toString(scope void delegate(const(char)[]) sink) const
	{
		ptr.toString(sink);
	}
}
PointerWriter!T pointerWriter(T)(T* ptr) { return PointerWriter!T(ptr); }
