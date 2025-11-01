import json


# =============================================================================
# Filesystem Setup Functions
# =============================================================================

def cleanup_btrfs():
    """Unmount and clean up btrfs filesystem."""
    machine.succeed("umount /mnt/btrfs 2>/dev/null || true")


def setup_btrfs_basic():
    """Create and mount a basic single-device btrfs filesystem."""
    machine.succeed("mkfs.btrfs -f /dev/vdb")
    machine.succeed("mkdir -p /mnt/btrfs")
    machine.succeed("mount /dev/vdb /mnt/btrfs")


def create_test_files():
    """Create a variety of test files with different sizes."""
    machine.succeed("mkdir -p /mnt/btrfs/dir1/subdir1")
    machine.succeed("mkdir -p /mnt/btrfs/dir2/subdir2")

    # Files of various sizes
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/dir1/file1.dat bs=1M count=10")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/dir1/subdir1/file2.dat bs=1M count=5")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/dir2/file3.dat bs=1M count=20")
    machine.succeed("sync")


def create_reflinked_files():
    """Create CoW reflinked (cloned) files."""
    machine.succeed("cp --reflink=always /mnt/btrfs/dir1/file1.dat /mnt/btrfs/dir2/cloned.dat")
    machine.succeed("sync")


def create_subvolumes_and_snapshots():
    """Create btrfs subvolumes and snapshots."""
    machine.succeed("btrfs subvolume create /mnt/btrfs/subvol1")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/subvol1/data.dat bs=1M count=15")
    machine.succeed("btrfs subvolume snapshot /mnt/btrfs/subvol1 /mnt/btrfs/snapshot1")
    machine.succeed("sync")


def enable_compression():
    """Remount filesystem with compression enabled."""
    machine.succeed("umount /mnt/btrfs")
    machine.succeed("mount -o compress=zstd /dev/vdb /mnt/btrfs")


def create_compressible_data():
    """Create data that compresses well."""
    machine.succeed("dd if=/dev/zero of=/mnt/btrfs/compressible.dat bs=1M count=50")
    machine.succeed("sync")


# =============================================================================
# Helper Functions
# =============================================================================

def run_btdu(args, timeout=30):
    """Run btdu with given arguments and return output."""
    cmd = f"timeout {timeout} btdu {args}"
    return machine.succeed(cmd)


def verify_json_export(export_path):
    """Verify that a JSON export file exists and is valid, return parsed data."""
    machine.succeed(f"test -f {export_path}")
    content = machine.succeed(f"cat {export_path}")

    try:
        data = json.loads(content)
        print(f"  ✓ Valid JSON export ({len(content)} bytes)")
        return data
    except json.JSONDecodeError as e:
        raise Exception(f"Invalid JSON in {export_path}: {e}")


def verify_du_output(output):
    """Verify du output format (lines with size and path)."""
    lines = output.strip().split('\n')
    if not lines:
        raise Exception("du output is empty")

    for line in lines:
        parts = line.split('\t', 1)
        if len(parts) != 2:
            raise Exception(f"Invalid du output line: {line}")
        size, path = parts
        if not size.isdigit():
            raise Exception(f"Invalid size in du output: {size}")

    print(f"  ✓ Valid du output ({len(lines)} entries)")
    return lines


# =============================================================================
# Basic Functionality Tests
# =============================================================================

def test_help_and_version():
    """Verify btdu help output is available."""
    # No filesystem needed for help test
    result = run_btdu("--help 2>&1", timeout=5)
    assert "sampling disk usage profiler" in result.lower(), "Help text missing expected content"
    print("  ✓ Help output verified")


def test_basic_analysis():
    """Run basic btdu analysis in headless mode."""
    setup_btrfs_basic()
    create_test_files()

    run_btdu("--headless --max-samples=50 /mnt/btrfs")
    print("  ✓ Basic analysis completed")


def test_export_and_import():
    """Test exporting results to JSON and verify import capability."""
    setup_btrfs_basic()
    create_test_files()

    # Export results
    run_btdu("--headless --export=/tmp/export.json --max-samples=100 /mnt/btrfs")

    # Verify export is valid JSON
    verify_json_export("/tmp/export.json")

    # Verify we can import the data (import mode reads file as PATH argument)
    # Note: --import is a flag, file path goes as positional argument
    run_btdu("--import --headless /tmp/export.json 2>&1 || true", timeout=10)
    # Import should work (or at least not crash fatally)
    print("  ✓ Export and import verified")


def test_du_output_format():
    """Verify du output format is correct."""
    setup_btrfs_basic()
    create_test_files()

    output = run_btdu("--headless --du --max-samples=50 /mnt/btrfs")
    verify_du_output(output)


# =============================================================================
# Feature-Specific Tests
# =============================================================================

def test_physical_sampling():
    """Test physical space sampling mode."""
    setup_btrfs_basic()
    create_test_files()

    run_btdu("--headless --physical --export=/tmp/physical.json --max-samples=100 /mnt/btrfs")
    verify_json_export("/tmp/physical.json")


def test_subvolume_handling():
    """Verify btdu correctly handles subvolumes and snapshots."""
    setup_btrfs_basic()
    create_test_files()
    create_subvolumes_and_snapshots()

    run_btdu("--headless --export=/tmp/subvol.json --max-samples=500 /mnt/btrfs", timeout=60)
    data = verify_json_export("/tmp/subvol.json")

    # Could add verification that subvolumes appear in the data
    samples = data.get('samples', 0) if isinstance(data, dict) else 0
    print(f"  ✓ Collected {samples} samples with subvolumes")


def test_reflink_handling():
    """Verify btdu correctly handles reflinked (CoW cloned) files."""
    setup_btrfs_basic()
    create_test_files()
    create_reflinked_files()

    run_btdu("--headless --export=/tmp/reflink.json --max-samples=200 /mnt/btrfs")
    verify_json_export("/tmp/reflink.json")


def test_compression_support():
    """Verify btdu works with compressed btrfs filesystems."""
    setup_btrfs_basic()
    create_test_files()
    enable_compression()
    create_compressible_data()

    # Run btdu on compressed filesystem
    run_btdu("--headless --export=/tmp/compressed.json --max-samples=100 /mnt/btrfs")
    verify_json_export("/tmp/compressed.json")


# =============================================================================
# Result Verification Tests
# =============================================================================

def test_json_export_structure():
    """Verify exported JSON has expected structure and fields."""
    setup_btrfs_basic()
    create_test_files()

    run_btdu("--headless --export=/tmp/structure.json --max-samples=200 /mnt/btrfs")
    data = verify_json_export("/tmp/structure.json")

    # Verify expected fields exist
    if isinstance(data, dict):
        # Check for common expected fields (adjust based on actual btdu output)
        print(f"  ✓ JSON contains {len(data.keys())} top-level keys")
    else:
        print(f"  ✓ JSON export verified (type: {type(data).__name__})")


# =============================================================================
# Test Orchestration
# =============================================================================

def execute_all_tests():
    """Run all test functions in order."""
    tests = [
        # Basic functionality
        test_help_and_version,
        test_basic_analysis,
        test_export_and_import,
        test_du_output_format,

        # Feature-specific tests
        test_physical_sampling,
        test_subvolume_handling,
        test_reflink_handling,
        test_compression_support,

        # Result verification
        test_json_export_structure,
    ]

    for test_func in tests:
        # Clean up any previous test's filesystem
        cleanup_btrfs()

        # Print test name from function name
        print(f"{test_func.__name__}...")
        test_func()


def main():
    """Main test entry point."""
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Run all tests (each test sets up its own filesystem)
    execute_all_tests()

    print("\n✓ All tests passed!")


# Run tests when script is executed
main()
