/*
 * Copyright (C) 2020, 2021, 2022, 2023  Vladimir Panteleev <btdu@cy.md>
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

/// Global state definitions
module btdu.state;

import core.lifetime : moveEmplace;

import std.traits : EnumMembers;

import ae.utils.functor.primitives;
import ae.utils.json;
import ae.utils.meta : enumLength;

import btrfs.c.ioctl : btrfs_ioctl_dev_info_args;
import btrfs.c.kerncompat : u64;

import btdu.paths;
import btdu.subproc : Subprocess;

// Global variables

__gshared: // btdu is single-threaded

bool imported;
string fsPath;
ulong totalSize;
btrfs_ioctl_dev_info_args[] devices;

SubPath subPathRoot;
GlobalPath*[u64] globalRoots;
BrowserPathPtr browserRoot;

shared static this() { browserRoot.setMark(false); }

BrowserPathPtr marked;  /// A fake `BrowserPath` used to represent all marked nodes.
ulong markTotalSamples; /// Number of seen samples since the mark was invalidated.

/// Called when something is marked or unmarked.
void invalidateMark()
{
	markTotalSamples = 0;
	if (samplingConfiguration.has.allSampleTypes)
		marked.clearSamples(SampleType.exclusive);
}

/// Update stats in `marked` for a redisplay.
void updateMark()
{
	marked.enter!((p) {
		static foreach (sampleType; SampleType.init .. p.maxSampleType)
			static if (sampleType != SampleType.exclusive)
				p.clearSamples(SampleType.exclusive);
		static if (p.config.has.distributed)
			marked.distributedSamples = marked.distributedDuration = 0;
	});

	browserRoot.enumerateMarks(
		(/*const*/ BrowserPathPtr path, bool isMarked)
		{
			if (path is browserRoot)
				return;
			path.enter!((p) {
				if (isMarked)
				{
					static foreach (sampleType; SampleType.init .. p.maxSampleType)
						marked.get!(p.config).addSamples(sampleType, p.data[sampleType]);
					marked.addDistributedSample(p.distributedSamples, p.distributedDuration);
				}
				else
				{
					static foreach (sampleType; SampleType.init .. p.maxSampleType)
						marked.get!(p.config).removeSamples(sampleType, p.data[sampleType]);
					marked.removeDistributedSample(p.distributedSamples, p.distributedDuration);
				}
			});
		}
	);
}

Subprocess[] subprocesses;
bool paused;
debug bool importing;

bool toFilesystemPath(BrowserPathPtr path, void delegate(const(char)[]) sink)
{
	sink(fsPath);
	bool recurse(BrowserPathPtr path)
	{
		string name = path.name[];
		if (name.skipOverNul())
			switch (name)
			{
				case "DATA":
				case "UNREACHABLE":
					return true;
				default:
					return false;
			}
		if (path.parent)
		{
			if (!recurse(path.parent))
				return false;
		}
		else
		{
			if (path is marked)
				return false;
		}
		sink("/");
		sink(name);
		return true;
	}
	return recurse(path);
}

auto toFilesystemPath(BrowserPathPtr path)
{
	import ae.utils.functor.primitives : functor;
	import ae.utils.text.functor : stringifiable;
	return path
		.functor!((path, writer) => path.toFilesystemPath(writer))
		.stringifiable;
}

SamplingConfiguration samplingConfiguration;
public import ae.utils.meta : has;

/// BrowserPath implementation selector
struct BrowserPathPtr
{
private:
	void* ptr;

	this(SamplingConfiguration config)(BrowserPath!config* ptr) { assert(samplingConfiguration == config); this.ptr = ptr; }

	template transformArgument(SamplingConfiguration ptrConfig)
	{
		static auto transformArgument(T)(auto ref T value)
		{
			static if (is(T == BrowserPathPtr))
				return cast(BrowserPath!ptrConfig*)value.ptr;
			else
			static if (is(T == U[], U))
				return cast(typeof(transformArgument(value[0]))[])value;
			else
				return value;
		}
	}

	static auto transformArguments(SamplingConfiguration ptrConfig, Args...)(auto ref Args args)
	{
		static auto tupleMap(alias pred, Values...)(auto ref Values values)
		{
			import std.typecons : tuple;
			static if (values.length == 0)
				return tuple();
			else
				return tuple(pred(values[0]), tupleMap!pred(values[1 .. $]).expand);
		}

		return tupleMap!(transformArgument!ptrConfig)(args);
	}

public:
	template get(SamplingConfiguration config)
	{
		auto get()       { assert(config == samplingConfiguration); return cast(      BrowserPath!config *)ptr; }
		auto get() const { assert(config == samplingConfiguration); return cast(const(BrowserPath!config)*)ptr; }
	}

	void opAssign(typeof(null)) { this.ptr = null; }

	template opDispatch(string name)
	if (__traits(hasMember, get!(SamplingConfiguration.full)(), name))
	{
		auto ref opDispatch(Args...)(auto ref Args args)
		if (args.length > 0
			// && is(typeof(__traits(getMember, get!(SamplingConfiguration.full)(), name)(args)))
			// && is(typeof(__traits(getMember, get!(SamplingConfiguration.full)(), name)(tupleMap!(transformArgument!(SamplingConfiguration.full), args).expand)))
			&& is(typeof(__traits(getMember, get!(SamplingConfiguration.full)(), name)(transformArguments!(SamplingConfiguration.full)(args).expand)))
			// Not static:
			&& !is(typeof({ cast(void)__traits(getMember, BrowserPath!(SamplingConfiguration.full), name)(transformArguments!(SamplingConfiguration.full)(args).expand); }))
		)
		{
			// __traits(getMember, get!(SamplingConfiguration.full)(), name)(tupleMap!(transformArgument!(SamplingConfiguration.full))(args).expand);
			static auto ref fun(P, TArgs...)(ref TArgs args, P p) { return __traits(getMember, p, name)(transformArguments!(p.config)(args).expand); }
			return this.enter(functor!fun(args));
		}

		// static auto ref opDispatch(string name, Args...)(auto ref Args args)
		// if (args.length > 0 && __traits(hasMember, BrowserPath!(SamplingConfiguration.full), name)/* && is(typeof(__traits(getMember, BrowserPath!ptrExpert, name)(args)))*/)
		// {
		// 	static foreach (ptrExpert; [false, true])
		// 		if (expert == ptrExpert)
		// 		{
		// 			alias R = typeof(__traits(getMember, BrowserPath!ptrExpert, name)(args));
		// 			static if (is(R == BrowserPath!ptrExpert*))
		// 				return BrowserPathPtr(__traits(getMember, BrowserPath!ptrExpert, name)(args));
		// 			else
		// 				return __traits(getMember, BrowserPath!ptrExpert, name)(args);
		// 		}
		// 	assert(false);
		// }

		static auto ref opDispatch(Args...)(auto ref Args args)
		if (args.length > 0
			&& is(typeof({ cast(void)__traits(getMember, BrowserPath!(SamplingConfiguration.full), name)(transformArguments!(SamplingConfiguration.full)(args).expand); }))
		)
		{
			static auto ref fun(P)(ref Args args, P _) { return __traits(getMember, P, name)(transformArguments!(P.config)(args).expand); }
			BrowserPathPtr dummy = void;
			return dummy.enter(functor!fun(args));
		}

		// static BrowserPathPtr commonPrefix(BrowserPathPtr[] paths)
		// {
		// 	static foreach (config; SamplingConfiguration.init .. SamplingConfiguration.length)
		// 		if (config == samplingConfiguration)
		// 			return BrowserPathPtr(BrowserPath!config.commonPrefix(cast(BrowserPath!config*[])paths));
		// 	assert(false);
		// }

		@property auto ref opDispatch()()
		{
			static ref auto fun(P)(P p) { return __traits(getMember, p, name); }
			return this.enter(functor!fun);
		}
	}

	void enumerateMarks(R)(scope R delegate(BrowserPathPtr, bool marked) callback)
	if (is(R == void) || is(R == bool))
	{
		this.enter!(p => p.enumerateMarks((path, marked) { return callback(typeof(this)(path), marked); }));
	}

	bool opCast(T : bool)() const { return !!ptr; }

	void toString(scope void delegate(const(char)[]) sink) const
	{
		this.enter(functor!(p => p.toString(sink)));
	}

	alias opCmp = opDispatch!"opCmp";

	void toJSON(F)(F f)
	{
		//this.enter(f.functor!((f, p) => f(p.toJSON())));
		this.enter!(p => f(p.toJSON()));
	}

	static BrowserPathPtr fromJSON(JSONFragment f)
	{
		BrowserPathPtr p;
		p.enter!((ref p) {
			auto s = f.json.jsonParse!(typeof(p).SerializedForm);
			p = new typeof(*p);
			auto v = typeof(p).fromJSON(s);
			moveEmplace(v, *p);
		});
		return p;
	}
}

unittest
{
	if (false) // test instantiation
	{
		BrowserPathPtr p;
		BrowserPathPtr[] arr;
		p = null;
		cast(void) (p ? 1 : 0); // opCast!bool
		// p.opDispatch!"addSample"(SampleType.represented, Offset.init, 0);
		p.addSample(SampleType.represented, Offset.init, 0);
		// p = p.opDispatch!"appendName"("");
		p = p.appendName("");
		// cast(void) p.opDispatch!"name"[];
		cast(void) p.name[];
		// cast(void) &p.opDispatch!"seenAs";
		cast(void) p.seenAs;
		// p = BrowserPathPtr.opDispatch!"commonPrefix"(arr);
		p = BrowserPathPtr.commonPrefix(arr);
		// cast(void) p.opDispatch!"parent";
		cast(void) p.parent;
		// cast(void) p.opDispatch!"humanName";
		cast(void) p.humanName;
		// cast(void) p.opDispatch!"getSampleCount"(SampleType.represented);
		cast(void) p.getSampleCount(SampleType.represented);
		// cast(void) p.enter!(pp => pp.opCmp(pp));
		// cast(void) p.opDispatch!"opCmp"(p);
		cast(void) (p < p);
	}
}

// These are top-level to avoid a dual context for the alias version.

auto ref enter(Pred, P)(ref P p, Pred pred)
if (is(P : const(BrowserPathPtr)))
{
	static foreach (config; SamplingConfiguration.init .. SamplingConfiguration.length)
		if (config == samplingConfiguration)
		{
			alias BP = BrowserPath!config;
			auto bpp = cast(BP**)&p.ptr;
			alias R = typeof(pred(*bpp));
			static if (is(R == BP*))
				return BrowserPathPtr(pred(*bpp));
			else
			// static if (is(R == typeof(assert(false))))
			// 	assert(false); // https://issues.dlang.org/show_bug.cgi?id=23914
			// else
				return pred(*bpp);
		}
	assert(false);
}

auto ref enter(alias fun, P)(ref P p)
if (is(P : const(BrowserPathPtr)))
{
	return p.enter(functor!fun());
}
