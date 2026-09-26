/// Filesystem target validation and auto-mount.
module btdu.mount;

import core.runtime : Runtime;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.conv;
import std.exception;
import std.format;
import std.path;
import std.string;
import std.typecons;

import ae.sys.file : getMounts, getPathMountInfo, MountInfo;
import btdu.state : autoMountMode, fsPath, fsid;

// System call bindings for mount namespace operations
private extern (C) nothrow @nogc
{
	int unshare(int flags);
	int mount(const(char)* source, const(char)* target,
	          const(char)* filesystemtype, ulong mountflags, const(void)* data);
}
private enum CLONE_NEWNS = 0x00020000;
private enum MS_REC = 0x4000;
private enum MS_PRIVATE = 1 << 18;

/// Check if path is a block device
private bool isBlockDevice(string path)
{
	import core.sys.posix.sys.stat : stat_t, stat, S_IFMT, S_IFBLK;
	import std.string : toStringz;

	stat_t st;
	if (stat(path.toStringz, &st) != 0)
		return false;
	return (st.st_mode & S_IFMT) == S_IFBLK;
}

/// Result of checking btrfs filesystem
private struct BtrfsCheckResult
{
	bool needsAutoMount;   /// True if path is btrfs but not top-level subvolume
	string device;         /// Block device path
}

/// Check if path is btrfs and return info about whether auto-mount is needed
private BtrfsCheckResult checkBtrfsStatus(string fsPath, MountInfo[] mounts)
{
	import core.sys.posix.fcntl : open, O_RDONLY;
	import core.sys.posix.unistd : close;
	import std.string : toStringz;
	import btrfs : isBTRFS, isSubvolume, getSubvolumeID;
	import btrfs.c.kernel_shared.ctree : BTRFS_FS_TREE_OBJECTID;

	BtrfsCheckResult result;

	int fd = open(fsPath.toStringz, O_RDONLY);
	errnoEnforce(fd >= 0, "open");
	scope(exit) close(fd);

	enforce(fd.isBTRFS,
		fsPath ~ " is not a btrfs filesystem");

	enforce(fd.isSubvolume, {
		auto rootPath = mounts.getPathMountInfo(fsPath).file;
		if (!rootPath)
			rootPath = "/";
		return format(
			"%s is not the root of a btrfs subvolume - " ~
			"please specify the path to the subvolume root" ~
			"\n" ~
			"E.g.: %s",
			fsPath,
			[Runtime.args[0], rootPath].escapeShellCommand,
		);
	}());

	if (fd.getSubvolumeID() != BTRFS_FS_TREE_OBJECTID)
	{
		result.needsAutoMount = true;
		auto mountInfo = mounts.getPathMountInfo(fsPath);
		result.device = mountInfo.spec;
	}

	return result;
}

/// Set up auto-mount: create mount namespace, temporary directory, and mount top-level subvolume
private string setupAutoMount(string device)
{
	import core.stdc.errno : errno, EPERM, EINVAL;
	import std.file : mkdirRecurse, tempDir;
	import std.string : toStringz;

	// Create mount namespace
	if (unshare(CLONE_NEWNS) != 0)
	{
		if (errno == EPERM)
			throw new Exception(
				"Cannot create mount namespace: permission denied.\n" ~
				"Try running with sudo.");
		errnoEnforce(false, "unshare(CLONE_NEWNS)");
	}

	// Make all mounts private so they don't propagate to parent namespace
	errnoEnforce(mount(null, "/".toStringz, null, MS_REC | MS_PRIVATE, null) == 0,
		"mount(MS_PRIVATE)");

	// Create mount point directory. We share the same path across
	// instances since the mount is private to each instance.
	auto mountPoint = tempDir.buildPath("btdu-auto-mount");
	mkdirRecurse(mountPoint);

	// Mount top-level subvolume
	if (mount(device.toStringz, mountPoint.toStringz,
	          "btrfs".toStringz, 0, "subvol=/".toStringz) != 0)
	{
		auto mountErrno = errno;

		import std.file : rmdir;
		try rmdir(mountPoint); catch (Exception) {}

		if (mountErrno == EPERM)
			throw new Exception("Cannot mount " ~ device ~ ": permission denied.");
		if (mountErrno == EINVAL)
			throw new Exception(device ~ " does not appear to be a valid btrfs filesystem.");

		errno = mountErrno;
		errnoEnforce(false, "mount(top-level subvolume at " ~ mountPoint ~ ")");
	}

	return mountPoint;
}

void checkBtrfs(string fsPath, bool autoMount)
{
	// Get mount info early so it's available for both code paths
	MountInfo[] mounts;
	try
		mounts = getMounts().array;
	catch (Exception) {}

	// Check if the path is a block device
	if (isBlockDevice(fsPath))
	{
		if (autoMount)
		{
			.autoMountMode = true;
			.fsPath = setupAutoMount(fsPath);
		}
		else
		{
			throw new Exception(formatBlockDeviceError(fsPath, mounts));
		}
		return;
	}

	auto status = checkBtrfsStatus(fsPath, mounts);

	if (status.needsAutoMount)
	{
		if (autoMount)
		{
			.autoMountMode = true;
			.fsPath = setupAutoMount(status.device);
		}
		else
		{
			throw new Exception(formatSubvolumeError(fsPath, mounts));
		}
	}
}

/// Pick a suitable mount root directory
private string pickMountRoot(MountInfo[] mounts = null)
{
	import std.file : exists;
	import std.algorithm.searching : canFind;

	return
		"/mnt".exists && (mounts is null || !mounts.canFind!(m => m.file == "/mnt")) ? "/mnt" :
		"/media".exists ? "/media" :
		"/mnt";
}

private string formatBlockDeviceError(string device, MountInfo[] mounts)
{
	import std.format : format;

	string msg = format("'%s' is a block device, not a mounted filesystem.\n\n", device);

	auto tmpName = pickMountRoot(mounts) ~ "/btrfs-root";

	msg ~= "To analyze this device, either:\n\n" ~
		"  1. Mount it first and run btdu on the mount point:\n\n" ~
		format("     sudo %s\n", ["mkdir", "-p", tmpName].escapeShellCommand) ~
		format("     sudo %s\n", ["mount", "-o", "subvol=/", device, tmpName].escapeShellCommand) ~
		format("     sudo %s\n\n", [Runtime.args[0], tmpName].escapeShellCommand) ~
		"  2. Or use --auto-mount to let btdu mount it temporarily\n" ~
		"     (some features will be disabled):\n\n" ~
		format("     sudo %s\n",
			[Runtime.args[0], "--auto-mount", device].escapeShellCommand);

	return msg;
}

private string formatSubvolumeError(string fsPath, MountInfo[] mounts)
{
	import std.algorithm.searching : canFind;

	// Get mount info and detect common layouts
	auto mountInfo = mounts.getPathMountInfo(fsPath);
	auto options = mountInfo.mntops
		.split(",")
		.map!(o => o.findSplit("="))
		.map!(p => tuple(p[0], p[2]))
		.assocArray;

	string currentSubvol;
	bool mountIsTopLevel = true;
	if (auto subvol = "subvol" in options)
	{
		currentSubvol = *subvol;
		mountIsTopLevel = currentSubvol == "/";
	}
	if (auto subvolid = "subvolid" in options)
		mountIsTopLevel = mountIsTopLevel || *subvolid == "5";

	string msg;
	if (mountIsTopLevel)
	{
		msg = "The specified path is not the top-level subvolume of its btrfs filesystem.\n\n";
		msg ~= "> WHAT WENT WRONG:\n\n" ~
			"  The path you specified (\"" ~ fsPath ~ "\") is located inside a nested\n" ~
			"  subvolume, not the top-level subvolume.\n\n" ~
			"  btdu must be given the mount point of the top-level subvolume itself,\n" ~
			"  not a path within it.\n\n" ~
			"> WHY THIS MATTERS:\n\n" ~
			"  btdu analyzes the entire filesystem and needs the top-level subvolume\n" ~
			"  to reach all subvolumes and snapshots.\n\n" ~
			"> WHAT TO DO:\n\n" ~
			"  The top-level subvolume of this filesystem is already mounted at\n" ~
			"  \"" ~ mountInfo.file ~ "\". Run btdu there instead:\n\n" ~
			format("     sudo %s",
				[Runtime.args[0], mountInfo.file].escapeShellCommand);
		return msg;
	}

	msg = "The specified path is not mounted from the btrfs top-level subvolume.\n\n";
	msg ~= "> WHAT WENT WRONG:\n\n";
	if (fsPath == "/")
		msg ~= "  Your root filesystem \"/\" is a btrfs subvolume, but not the top-level one.\n";
	else
		msg ~= "  The path you specified (\"" ~ fsPath ~ "\") is a btrfs subvolume, but not the top-level one.\n";
	if (currentSubvol.length > 0)
		msg ~= format("  It is mounted from the \"%s\" subvolume (subvol=%s), but\n", currentSubvol, currentSubvol);
	msg ~= "  btdu requires the top-level subvolume (subvol=/).\n\n";

	msg ~= "> WHY THIS MATTERS:\n\n" ~
		"  btdu needs access to the top-level subvolume to analyze all subvolumes\n" ~
		"  and snapshots. Your current path only shows part of the filesystem.\n\n";

	msg ~= "> HOW THIS HAPPENED:\n\n";
	if (currentSubvol.canFind("@"))
		msg ~=
			"  Your system uses the common \"@\" subvolume layout (Ubuntu, Fedora, etc.).\n" ~
			"  This layout was probably created automatically during installation.\n";
	else
		msg ~=
			"  Your system was configured to mount a subvolume rather than the\n" ~
			"  top-level filesystem. This is common for systems using btrfs snapshots.\n";

	// Check if this is configured in /etc/fstab
	bool inFstab = {
		try
		{
			import std.stdio : File;
			foreach (line; File("/etc/fstab").byLine)
			{
				auto l = line.idup.strip;
				if (l.length == 0 || l[0] == '#')
					continue;
				auto fields = l.split;
				if (fields.length >= 2 && fields[1] == fsPath)
					return true;
			}
		}
		catch (Exception) {}
		return false;
	}();

	if (inFstab)
		msg ~= "  This configuration is set in /etc/fstab.\n";
	msg ~= "\n";

	// Provide step-by-step fix
	auto device = mountInfo.spec;
	if (!device)
		device = "<your-btrfs-device>"; // More descriptive placeholder
	auto tmpName = pickMountRoot(mounts) ~ "/btrfs-root";

	msg ~= "> WHAT TO DO:\n\n" ~
		"  Mount the top-level subvolume and run btdu there:\n\n" ~
		format("  1. Create a mount point:\n     sudo %s\n\n",
			["mkdir", "-p", tmpName].escapeShellCommand) ~
		format("  2. Mount the top-level subvolume:\n     sudo %s\n\n",
			["mount", "-o", "subvol=/", device, tmpName].escapeShellCommand) ~
		format("  3. Run btdu:\n     sudo %s\n\n",
			[Runtime.args[0], tmpName].escapeShellCommand) ~
		"  This is safe: mounting the same filesystem at a second location is a normal\n" ~
		"  operation and won't affect your existing mounts or data.\n\n";

	// Add hint about what they'll see
	if (currentSubvol.canFind("@"))
		msg ~= "  From there, you'll see all subvolumes such as @, @home, snapshots, etc.\n\n";
	else
		msg ~= "  From there, you'll see all subvolumes and snapshots on this filesystem.\n\n";

	msg ~= "  Alternatively, use --auto-mount to let btdu handle this automatically\n" ~
		"  (some features will be disabled):\n\n" ~
		format("     sudo %s",
			[Runtime.args[0], "--auto-mount", fsPath].escapeShellCommand);

	return msg;
}

private string escapeShellCommand(string[] args)
{
	import std.process : escapeShellFileName;
	import std.algorithm.searching : all;
	import ae.utils.array : isOneOf;

	foreach (ref arg; args)
		if (!arg.representation.all!(c => c.isOneOf("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/.=:@%")))
			arg = arg.escapeShellFileName;
	return args.join(" ");
}

/// Verify that live sampling can start on a mounted btrfs top-level
/// subvolume, and that its UUID matches the imported data when known.
/// Throws with a user-facing message otherwise. Never auto-mounts.
void checkLiveTarget(string path, in typeof(fsid) expectedFsid)
{
	import core.sys.posix.fcntl : open, O_RDONLY;
	import core.sys.posix.unistd : close;
	import btrfs : getInfo;
	import std.uuid : UUID;

	MountInfo[] mounts;
	try
		mounts = getMounts().array;
	catch (Exception) {}

	enforce(!isBlockDevice(path), path ~ " is a block device, not a mounted filesystem");
	auto status = checkBtrfsStatus(path, mounts);
	enforce(!status.needsAutoMount,
		path ~ " is not the top-level subvolume of its btrfs filesystem");

	if (expectedFsid != typeof(expectedFsid).init)
	{
		int fd = open(path.toStringz, O_RDONLY);
		errnoEnforce(fd >= 0, "open");
		scope(exit) close(fd);
		auto info = getInfo(fd);
		enforce(info.fsid == expectedFsid,
			format("%s is a different filesystem (UUID %s) than the imported data (UUID %s)",
				path, UUID(info.fsid), UUID(expectedFsid)));
	}
}

unittest
{
	import std.exception : assertThrown;
	assertThrown!Exception(checkLiveTarget("/nonexistent/btdu-test", typeof(fsid).init));
}
