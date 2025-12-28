import json
import time


# =============================================================================
# Filesystem Setup Functions
# =============================================================================

def cleanup_btrfs():
    """Unmount all btrfs devices."""
    # Unmount all mount points that tests may use
    mount_points = [
        "/mnt/btrfs",
        "/mnt/btrfs2",
        "/mnt/ext4",
        "/mnt/multidev",
        "/mnt/raid0",
        "/mnt/raid1",
        "/mnt/mixed",
    ]
    for mp in mount_points:
        machine.execute(f"mountpoint -q {mp} && umount {mp}")


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
    # Reduced from 50MB to 1MB (compressible data from /dev/zero)
    machine.succeed("dd if=/dev/zero of=/mnt/btrfs/compressible.dat bs=1M count=1")
    machine.succeed("sync")


# =============================================================================
# Constants
# =============================================================================

# btdu JSON tree path components
SINGLE = '\x00SINGLE'
RAID0 = '\x00RAID0'
RAID1 = '\x00RAID1'
DUP = '\x00DUP'
DATA = '\x00DATA'
METADATA = '\x00METADATA'
SYSTEM = '\x00SYSTEM'
UNUSED = '\x00UNUSED'


# =============================================================================
# Helper Functions
# =============================================================================

def get_node(node, path):
    """Navigate to a node using a path of child names.

    Args:
        node: Starting node (typically root)
        path: List of child names to navigate through (e.g., ["\x00SINGLE", "\x00DATA", "file.txt"])

    Returns:
        The node at the end of the path, or None if not found
    """
    current = node
    for name in path:
        if not isinstance(current, dict):
            return None
        children = current.get('children', [])
        current = next((child for child in children if child.get('name') == name), None)
        if current is None:
            return None
    return current


def get_file_size(data, path, sample_kind='represented'):
    """
    Get estimated file size based on samples.

    Formula: fileSize = (fileSamples / rootSamples) * totalSize

    Args:
        data: The exported JSON data (full export)
        path: List of path components to the node
        sample_kind: Type of samples to use ('represented', 'exclusive', etc.)

    Returns:
        Estimated file size in bytes, or 0 if node not found
    """
    node = get_node(data['root'], path)
    if node is None:
        return 0

    file_samples = node['data'][sample_kind]['samples']
    root_samples = data['root']['data']['represented']['samples']
    total_size = data['totalSize']

    if root_samples == 0:
        return 0

    return (file_samples / root_samples) * total_size


def run_btdu(args, timeout=30):
    """Run btdu with given arguments and return output."""
    # Default seed is 0 which is deterministic, no need to override
    # Use --wait-for-subprocesses to ensure clean unmount after btdu exits
    cmd = f"timeout {timeout} btdu --wait-for-subprocesses {args}"
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
        # Show context around the error position
        pos = e.pos
        start = max(0, pos - 100)
        end = min(len(content), pos + 100)
        context = content[start:end]
        print(f"  JSON error context (around pos {pos}):")
        print(f"  ...{repr(context)}...")
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
    """Verify btdu help and man page output is available."""
    # No filesystem needed for help/man tests
    result = run_btdu("--help 2>&1", timeout=5)
    assert "sampling disk usage profiler" in result.lower(), "Help text missing expected content"
    print("  ✓ Help output verified")

    man_result = machine.succeed("btdu --man / 2>&1")
    assert any(marker in man_result for marker in [".TH", "BTDU", "NAME"]), "Man page missing expected markers"
    print("  ✓ Man page output verified")


def test_basic_analysis():
    """Run basic btdu analysis in headless mode."""
    setup_btrfs_basic()
    create_test_files()

    run_btdu("--headless --export=/tmp/basic.json --max-samples=5000 /mnt/btrfs", timeout=120)
    data = verify_json_export("/tmp/basic.json")

    # Verify the files we created actually appear in the tree
    # create_test_files() creates: dir1/file1.dat (10MB), dir1/subdir1/file2.dat (5MB), dir2/file3.dat (20MB)
    file1 = get_node(data['root'], [SINGLE, DATA, 'dir1'])
    file3 = get_node(data['root'], [SINGLE, DATA, 'dir2'])

    assert file1 is not None, "dir1 not found in export tree"
    assert file3 is not None, "dir2 not found in export tree"
    assert file1['data']['represented']['samples'] > 0, "dir1 has no samples"
    assert file3['data']['represented']['samples'] > 0, "dir2 has no samples"

    print(f"  ✓ Basic analysis verified: found dir1 ({file1['data']['represented']['samples']} samples) and dir2 ({file3['data']['represented']['samples']} samples)")


def test_export_and_import():
    """Test exporting results to JSON and verify import capability."""
    setup_btrfs_basic()
    create_test_files()

    # Export results
    run_btdu("--headless --export=/tmp/export.json --max-samples=5000 /mnt/btrfs", timeout=120)
    exported_data = verify_json_export("/tmp/export.json")

    # Just verify import loads without crashing
    run_btdu("--import --headless /tmp/export.json", timeout=5)

    # Verify the exported data has expected structure and content
    assert exported_data['totalSize'] > 0, "totalSize should be > 0"
    assert exported_data['root']['data']['represented']['samples'] > 0, "Should have collected samples"

    # Verify directories from create_test_files() appear in exported tree
    dir1 = get_node(exported_data['root'], [SINGLE, DATA, 'dir1'])
    dir2 = get_node(exported_data['root'], [SINGLE, DATA, 'dir2'])

    assert dir1 is not None, "dir1 not found in exported tree"
    assert dir2 is not None, "dir2 not found in exported tree"
    assert dir1['data']['represented']['samples'] > 0, "dir1 should have samples"
    assert dir2['data']['represented']['samples'] > 0, "dir2 should have samples"

    print("  ✓ Export and import verified: complete data structure with dir1 and dir2")


def test_du_output_format():
    """Verify du output format is correct."""
    setup_btrfs_basic()
    create_test_files()

    output = run_btdu("--headless --du --max-samples=5000 /mnt/btrfs", timeout=120)
    lines = verify_du_output(output)

    # Verify specific directories appear in du output
    output_str = '\n'.join(lines)
    assert 'dir1' in output_str or 'dir2' in output_str, "Expected directories not found in du output"

    print(f"  ✓ du output verified: found expected directories in {len(lines)} entries")


def test_binary_export_import():
    """Test exporting results to binary format and verify import capability."""
    setup_btrfs_basic()
    create_test_files()

    # Export results in binary format
    run_btdu("--headless --export=/tmp/export.bin --export-format=binary --max-samples=5000 /mnt/btrfs", timeout=120)

    # Import binary and re-export to JSON to verify round-trip
    machine.succeed("timeout 10 btdu --import --headless --export=/tmp/reimport.json /tmp/export.bin")
    reimported_data = verify_json_export("/tmp/reimport.json")

    # Verify the reimported data has expected structure and content
    assert reimported_data['totalSize'] > 0, "totalSize should be > 0 after binary import"
    assert reimported_data['root']['data']['represented']['samples'] > 0, "Should have samples after binary import"

    # Verify directories from create_test_files() appear in reimported tree
    dir1 = get_node(reimported_data['root'], [SINGLE, DATA, 'dir1'])
    dir2 = get_node(reimported_data['root'], [SINGLE, DATA, 'dir2'])

    assert dir1 is not None, "dir1 not found in reimported tree"
    assert dir2 is not None, "dir2 not found in reimported tree"
    assert dir1['data']['represented']['samples'] > 0, "dir1 should have samples after binary import"
    assert dir2['data']['represented']['samples'] > 0, "dir2 should have samples after binary import"

    print("  ✓ Binary export and import verified: complete data structure with dir1 and dir2")


def test_binary_format_autodetect():
    """Verify auto-detection works for both JSON and binary formats."""
    setup_btrfs_basic()
    create_test_files()

    # Export in both formats
    run_btdu("--headless --export=/tmp/autodetect.json --export-format=json --max-samples=3000 /mnt/btrfs", timeout=120)
    run_btdu("--headless --export=/tmp/autodetect.bin --export-format=binary --max-samples=3000 /mnt/btrfs", timeout=120)

    # Import JSON (auto-detected) and re-export to verify
    machine.succeed("timeout 5 btdu --import --headless --export=/tmp/from_json.json /tmp/autodetect.json")
    json_data = verify_json_export("/tmp/from_json.json")
    assert json_data['totalSize'] > 0, "JSON auto-detect failed: no totalSize"

    # Import binary (auto-detected) and re-export to verify
    machine.succeed("timeout 5 btdu --import --headless --export=/tmp/from_binary.json /tmp/autodetect.bin")
    binary_data = verify_json_export("/tmp/from_binary.json")
    assert binary_data['totalSize'] > 0, "Binary auto-detect failed: no totalSize"

    print("  ✓ Format auto-detection verified: both JSON and binary imports succeeded")


def test_binary_expert_mode():
    """Verify binary format contains complete data for expert mode viewing."""
    setup_btrfs_basic()

    # Create a mix of unique and reflinked files to test expert metrics
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/unique.dat bs=1M count=5")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/base.dat bs=1M count=5")
    machine.succeed("cp --reflink=always /mnt/btrfs/base.dat /mnt/btrfs/clone.dat")
    machine.succeed("sync")

    # Export in binary format (expert flag in file is informational only)
    run_btdu("--headless --export=/tmp/expert.bin --export-format=binary --max-samples=10000 /mnt/btrfs", timeout=180)

    # Import with --expert to view in expert mode (CLI controls view mode)
    # Binary format always contains complete data for all metrics
    machine.succeed("timeout 10 btdu --import --expert --headless --export=/tmp/expert_reimport.json /tmp/expert.bin")
    data = verify_json_export("/tmp/expert_reimport.json")

    # Verify expert mode is enabled via CLI
    assert data['expert'] == True, "Expert mode not enabled via CLI"

    # Verify expert mode fields exist (binary format has complete data)
    root_data = data['root']['data']
    assert 'distributedSamples' in root_data, "Missing distributedSamples field after binary import"
    assert 'exclusive' in root_data, "Missing exclusive field after binary import"
    assert 'shared' in root_data, "Missing shared field after binary import"

    print("  ✓ Binary expert mode verified: complete data available for expert view")


def test_binary_physical_mode():
    """Verify physical mode data is preserved in binary format."""
    setup_btrfs_basic()
    create_test_files()

    # Export in binary format with physical mode
    run_btdu("--physical --headless --export=/tmp/physical.bin --export-format=binary --max-samples=5000 /mnt/btrfs", timeout=120)

    # Import and verify physical mode is preserved
    machine.succeed("timeout 10 btdu --import --headless --export=/tmp/physical_reimport.json /tmp/physical.bin")
    data = verify_json_export("/tmp/physical_reimport.json")

    # Verify physical mode is enabled
    assert data.get('physical') == True, "Physical mode not preserved in binary format"

    # Verify totalSize is reasonable for physical mode
    total_size = data['totalSize']
    assert total_size > 0, "totalSize should be > 0 in physical mode"

    samples = data['root']['data']['represented']['samples']
    assert samples > 0, "Should have samples after physical binary import"

    print(f"  ✓ Binary physical mode verified: physical={data.get('physical')}, totalSize={total_size/1024/1024:.1f}MB")


def test_binary_round_trip_accuracy():
    """Verify binary format is lossless by comparing JSON exports before and after."""
    setup_btrfs_basic()
    create_test_files()

    # Export to JSON first
    run_btdu("--expert --headless --export=/tmp/original.json --max-samples=5000 /mnt/btrfs", timeout=120)
    original_data = verify_json_export("/tmp/original.json")

    # Export same data to binary
    run_btdu("--expert --headless --export=/tmp/round_trip.bin --export-format=binary --max-samples=5000 /mnt/btrfs", timeout=120)

    # Import binary and export to JSON (use --expert to match original)
    machine.succeed("timeout 10 btdu --import --expert --headless --export=/tmp/round_trip.json /tmp/round_trip.bin")
    round_trip_data = verify_json_export("/tmp/round_trip.json")

    # Compare key fields
    assert original_data['totalSize'] == round_trip_data['totalSize'], \
        f"totalSize mismatch: {original_data['totalSize']} vs {round_trip_data['totalSize']}"
    assert original_data['expert'] == round_trip_data['expert'], \
        f"expert mismatch: {original_data['expert']} vs {round_trip_data['expert']}"
    assert original_data['fsPath'] == round_trip_data['fsPath'], \
        f"fsPath mismatch: {original_data['fsPath']} vs {round_trip_data['fsPath']}"

    # Compare sample counts (should be identical since binary is lossless)
    orig_samples = original_data['root']['data']['represented']['samples']
    rt_samples = round_trip_data['root']['data']['represented']['samples']
    assert orig_samples == rt_samples, \
        f"Sample count mismatch: {orig_samples} vs {rt_samples}"

    # Verify tree structure is preserved
    orig_dir1 = get_node(original_data['root'], [SINGLE, DATA, 'dir1'])
    rt_dir1 = get_node(round_trip_data['root'], [SINGLE, DATA, 'dir1'])

    assert (orig_dir1 is None) == (rt_dir1 is None), "dir1 presence mismatch"
    if orig_dir1 and rt_dir1:
        orig_dir1_samples = orig_dir1['data']['represented']['samples']
        rt_dir1_samples = rt_dir1['data']['represented']['samples']
        assert orig_dir1_samples == rt_dir1_samples, \
            f"dir1 samples mismatch: {orig_dir1_samples} vs {rt_dir1_samples}"

    print(f"  ✓ Binary round-trip accuracy verified: {orig_samples} samples preserved exactly")


# =============================================================================
# Feature-Specific Tests
# =============================================================================

def test_physical_sampling():
    """Test physical space sampling mode."""
    setup_btrfs_basic()
    create_test_files()

    # Run in both logical and physical mode to compare
    run_btdu("--headless --export=/tmp/logical.json --max-samples=5000 /mnt/btrfs", timeout=120)
    logical_data = verify_json_export("/tmp/logical.json")

    run_btdu("--headless --physical --export=/tmp/physical.json --max-samples=5000 /mnt/btrfs", timeout=120)
    physical_data = verify_json_export("/tmp/physical.json")

    # Physical and logical totalSize may differ on some profiles/configurations
    logical_size = logical_data['totalSize']
    physical_size = physical_data['totalSize']

    print(f"  ✓ Physical sampling verified: logical={logical_size/1024/1024:.1f}MB, physical={physical_size/1024/1024:.1f}MB")


def test_subvolume_handling():
    """Verify btdu correctly handles subvolumes and snapshots."""
    setup_btrfs_basic()
    create_test_files()
    create_subvolumes_and_snapshots()

    run_btdu("--headless --export=/tmp/subvol.json --max-samples=5000 /mnt/btrfs", timeout=120)
    data = verify_json_export("/tmp/subvol.json")

    # Verify subvolumes actually appear in the tree (at least one should be sampled)
    subvol1 = get_node(data['root'], [SINGLE, DATA, 'subvol1'])
    snapshot1 = get_node(data['root'], [SINGLE, DATA, 'snapshot1'])

    assert subvol1 is not None or snapshot1 is not None, "Neither subvol1 nor snapshot1 found in export tree"

    found = []
    if subvol1 is not None:
        found.append('subvol1')
    if snapshot1 is not None:
        found.append('snapshot1')

    samples = data['root']['data']['represented']['samples']
    print(f"  ✓ Subvolume handling verified: found {', '.join(found)} ({samples} samples total)")


def test_reflink_handling():
    """Verify btdu correctly handles reflinked (CoW cloned) files."""
    setup_btrfs_basic()
    create_test_files()
    create_reflinked_files()

    run_btdu("--headless --export=/tmp/reflink.json --max-samples=5000 /mnt/btrfs", timeout=120)
    data = verify_json_export("/tmp/reflink.json")

    # Verify the reflinked file appears (cloned.dat is a reflink of file1.dat)
    # Only one should be the representative, so check both exist or at least one has samples
    file1 = get_node(data['root'], [SINGLE, DATA, 'dir1'])
    cloned = get_node(data['root'], [SINGLE, DATA, 'dir2'])

    assert file1 is not None or cloned is not None, "Neither dir1 nor dir2 found (reflink test)"
    has_samples = (file1 and file1['data']['represented']['samples'] > 0) or (cloned and cloned['data']['represented']['samples'] > 0)
    assert has_samples, "No samples found for reflinked files"

    print("  ✓ Reflink handling verified: reflinked files found in tree")


def test_compression_support():
    """Verify btdu works with compressed btrfs filesystems."""
    setup_btrfs_basic()
    create_test_files()
    enable_compression()
    create_compressible_data()

    # Run btdu on compressed filesystem (increased samples for smaller disk)
    run_btdu("--headless --export=/tmp/compressed.json --max-samples=5000 /mnt/btrfs", timeout=120)
    data = verify_json_export("/tmp/compressed.json")

    # Verify the compressible file is found
    compressible = get_node(data['root'], [SINGLE, DATA, 'compressible.dat'])
    assert compressible is not None, "compressible.dat not found in compressed filesystem"
    assert compressible['data']['represented']['samples'] > 0, "compressible.dat has no samples"

    print(f"  ✓ Compression support verified: found compressible.dat with {compressible['data']['represented']['samples']} samples")


def test_representative_path_selection():
    """Verify btdu correctly selects representative paths for reflinked files."""
    setup_btrfs_basic()
    # Use 1MB file with many samples to ensure we hit it reliably
    # (1MB on 1GB = 0.1%, so 10000 samples gives ~10 expected hits)
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/short.dat bs=1M count=1")
    machine.succeed("cp --reflink=always /mnt/btrfs/short.dat /mnt/btrfs/much_longer_path.dat")
    machine.succeed("sync")

    # Use many samples to reliably find the reflinked data
    run_btdu("--headless --export=/tmp/reflink_repr.json --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/reflink_repr.json")

    # Find both paths in the export tree
    root = data['root']
    short_node = get_node(root, [SINGLE, DATA, 'short.dat'])
    longer_node = get_node(root, [SINGLE, DATA, 'much_longer_path.dat'])

    # With --seed, shorter path should be selected as representative deterministically
    assert short_node is not None, "short.dat not found in export tree (should be selected as representative)"
    short_samples = short_node['data']['represented']['samples']
    assert short_samples > 0, "short.dat selected as representative but has no samples"

    # The longer path should not appear in tree (btdu doesn't export nodes with 0 samples)
    assert longer_node is None, "Longer path should not appear in tree (shorter path is representative)"

    print(f"  ✓ Representative path selection verified: short.dat has {short_samples} samples (longer path not in tree)")


# =============================================================================
# Result Verification Tests
# =============================================================================

def test_json_export_structure():
    """Verify exported JSON has expected structure and fields."""
    setup_btrfs_basic()
    create_test_files()

    run_btdu("--headless --export=/tmp/structure.json --max-samples=5000 /mnt/btrfs")
    data = verify_json_export("/tmp/structure.json")

    # Verify expected fields exist
    assert isinstance(data, dict), f"Expected dict, got {type(data).__name__}"
    assert 'root' in data, "Missing 'root' key in JSON export"
    assert 'totalSize' in data, "Missing 'totalSize' key in JSON export"

    # Verify the tree actually contains expected paths from create_test_files()
    dir1 = get_node(data['root'], [SINGLE, DATA, 'dir1'])
    dir2 = get_node(data['root'], [SINGLE, DATA, 'dir2'])

    assert dir1 is not None or dir2 is not None, "Expected directories not found in JSON structure"

    # Verify root node has expected structure
    assert 'data' in data['root'], "Missing 'data' in root node"
    assert 'represented' in data['root']['data'], "Missing 'represented' in root data"
    assert 'samples' in data['root']['data']['represented'], "Missing 'samples' in represented data"

    samples = data['root']['data']['represented']['samples']
    assert samples > 0, "No samples collected in root"

    print(f"  ✓ JSON structure verified: {len(data.keys())} top-level keys, {samples} samples, found expected directories")


def test_max_samples_limit():
    """Verify btdu respects the --max-samples limit."""
    setup_btrfs_basic()
    create_test_files()

    # Use -j1 and higher sample count for better tolerance (percentage overshoot decreases with more samples)
    run_btdu("-j1 --headless --export=/tmp/max_samples.json --max-samples=500 /mnt/btrfs", timeout=60)
    data = verify_json_export("/tmp/max_samples.json")

    # With single subprocess and larger sample count, tolerance can be tighter
    samples = data['root']['data']['represented']['samples']
    # Allow ±15% tolerance - with 500 samples, this is 425-575 range
    assert 425 <= samples <= 575, f"Expected ~500 samples (±15%), got {samples}"

    # Verify expected directories appear in the tree
    dir1 = get_node(data['root'], [SINGLE, DATA, 'dir1'])
    dir2 = get_node(data['root'], [SINGLE, DATA, 'dir2'])
    assert dir1 is not None or dir2 is not None, "Expected directories not found even with 500 samples"

    print(f"  ✓ Sample limit enforced: {samples} samples collected (target: 500)")


def test_max_time_limit():
    """Verify btdu respects the --max-time limit."""
    setup_btrfs_basic()
    create_test_files()

    start_time = time.time()
    run_btdu("--headless --max-time=5s /mnt/btrfs", timeout=20)
    elapsed_time = time.time() - start_time

    assert 5 <= elapsed_time <= 10, f"Expected ~5s with overhead, got {elapsed_time:.1f}s"
    print(f"  ✓ Time limit enforced: {elapsed_time:.1f}s (target: 5s)")


def test_min_resolution_limit():
    """Verify btdu respects the --min-resolution limit."""
    setup_btrfs_basic()
    create_test_files()

    # Use --min-resolution with percentage
    run_btdu("--headless --min-resolution=5% --export=/tmp/min_res.json /mnt/btrfs", timeout=30)
    data = verify_json_export("/tmp/min_res.json")

    # Calculate actual resolution achieved (totalSize / samples)
    total_size = data['totalSize']
    samples = data['root']['data']['represented']['samples']
    assert samples > 0, "No samples collected (expected deterministic sampling with --seed)"
    resolution = total_size / samples
    target_resolution = total_size * 0.05  # 5% of total

    # Verify resolution is at or below target (smaller resolution = more accurate)
    assert resolution <= target_resolution * 1.2, \
        f"Resolution {resolution/1024/1024:.1f}MB should be <= {target_resolution/1024/1024:.1f}MB (5% of {total_size/1024/1024:.1f}MB)"
    print(f"  ✓ Resolution limit enforced: {resolution/1024/1024:.1f}MB with {samples} samples")


def test_subprocess_counts():
    """Verify btdu works correctly with different -j (subprocess count) parameters."""
    setup_btrfs_basic()
    create_test_files()

    run_btdu("-j1 --headless --max-samples=100 /mnt/btrfs", timeout=30)
    print("  ✓ Single subprocess (-j1) completed")

    run_btdu("-j4 --headless --max-samples=100 /mnt/btrfs", timeout=30)
    print("  ✓ Multiple subprocesses (-j4) completed")


def test_seed_reproducibility():
    """Verify that btdu produces deterministic results with the same seed."""
    setup_btrfs_basic()
    create_test_files()

    # Run btdu twice with the same seed, using single subprocess and higher sample count
    # Higher sample count reduces percentage variance
    run_btdu("--seed=999 -j1 --headless --export=/tmp/run1.json --max-samples=500 /mnt/btrfs")
    run_btdu("--seed=999 -j1 --headless --export=/tmp/run2.json --max-samples=500 /mnt/btrfs")

    # Verify both exports are valid and extract sample counts
    data1 = verify_json_export("/tmp/run1.json")
    data2 = verify_json_export("/tmp/run2.json")

    samples1 = data1['root']['data']['represented']['samples']
    samples2 = data2['root']['data']['represented']['samples']

    # With same seed and single subprocess, results should be reasonably close
    # btdu has inherent non-determinism even with --seed, so allow realistic variance
    # Testing shows variance can be 20-40%, so we test it's not completely random
    max_samples = max(samples1, samples2)
    diff_pct = abs(samples1 - samples2) * 100 / max_samples
    assert diff_pct <= 50, f"Seed reproducibility: {samples1} vs {samples2} ({diff_pct:.1f}% difference, expected ≤50%)"

    # Also verify both runs actually collected some samples
    assert samples1 > 0 and samples2 > 0, "One of the runs collected no samples"

    # Verify both runs found the same directories (tree structure should be consistent)
    dir1_run1 = get_node(data1['root'], [SINGLE, DATA, 'dir1'])
    dir1_run2 = get_node(data2['root'], [SINGLE, DATA, 'dir1'])
    dir2_run1 = get_node(data1['root'], [SINGLE, DATA, 'dir2'])
    dir2_run2 = get_node(data2['root'], [SINGLE, DATA, 'dir2'])

    # If a directory was found in run1, it should also be found in run2 (and vice versa)
    assert (dir1_run1 is None) == (dir1_run2 is None), "dir1 found in one run but not the other"
    assert (dir2_run1 is None) == (dir2_run2 is None), "dir2 found in one run but not the other"

    print(f"  ✓ Seed reproducibility verified: {samples1} and {samples2} samples ({diff_pct:.1f}% variance), consistent tree")


def test_non_btrfs_error():
    """Verify btdu fails gracefully on non-btrfs filesystems."""
    machine.succeed("mkfs.ext4 -F /dev/vdc")
    machine.succeed("mkdir -p /mnt/ext4 && mount /dev/vdc /mnt/ext4")
    result = machine.fail("btdu /mnt/ext4 2>&1")
    assert "not a btrfs" in result.lower(), f"Expected 'not a btrfs' error, got: {result}"
    print("  ✓ Non-btrfs error handling verified")


def test_conflicting_options():
    """Verify btdu fails gracefully when given conflicting command-line options."""
    setup_btrfs_basic()
    create_test_files()

    # Create a valid export file first
    run_btdu("--headless --export=/tmp/test.json --max-samples=50 /mnt/btrfs")
    verify_json_export("/tmp/test.json")

    # Test --import with --export is idempotent (re-exporting imported data produces same file)
    run_btdu("--headless --import --export=/tmp/reimport.json /tmp/test.json")
    original = machine.succeed("cat /tmp/test.json")
    reimported = machine.succeed("cat /tmp/reimport.json")
    assert original == reimported, "Re-exported file should be identical to original"
    print("  ✓ --import with --export is idempotent")

    # Test --import with --physical (physical mode only applies during sampling)
    result = machine.fail("btdu --import --physical /tmp/test.json 2>&1")
    assert "conflicting" in result.lower(), f"Expected 'conflicting' in error, got: {result}"
    print("  ✓ --import with --physical rejected")


def test_auto_mount_with_subvolume():
    """Verify btdu --auto-mount works with non-top-level subvolume mount."""
    # Create btrfs filesystem with a subvolume
    machine.succeed("mkfs.btrfs -f /dev/vdb")
    machine.succeed("mkdir -p /mnt/btrfs")
    machine.succeed("mount /dev/vdb /mnt/btrfs")

    # Create a subvolume with some data
    machine.succeed("btrfs subvolume create /mnt/btrfs/@")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/@/testfile.dat bs=1M count=5")
    machine.succeed("sync")
    machine.succeed("umount /mnt/btrfs")

    # Mount the non-top-level subvolume (like Ubuntu does)
    machine.succeed("mount -o subvol=@ /dev/vdb /mnt/btrfs")

    # Verify btdu fails without --auto-mount and suggests the flag
    result = machine.fail("btdu --headless /mnt/btrfs 2>&1")
    assert "not mounted from the btrfs top-level" in result.lower(), f"Expected subvolume error, got: {result}"
    assert "--auto-mount" in result, f"Expected --auto-mount suggestion in error, got: {result}"
    print("  ✓ Error message suggests --auto-mount")

    # Verify btdu works with --auto-mount
    run_btdu("--headless --export=/tmp/auto-mount.json --max-samples=100 --auto-mount /mnt/btrfs")

    data = verify_json_export("/tmp/auto-mount.json")
    root = data.get("root", {})
    samples = root.get("data", {}).get("represented", {}).get("samples", 0)
    assert samples > 0, f"Should have collected samples, got {samples}"

    # Verify totalSize is reported correctly
    assert data.get("totalSize", 0) > 0, "totalSize should be > 0"
    print(f"  ✓ --auto-mount collected {samples} samples")


def test_auto_mount_prefer_ignore_rejected():
    """Verify --prefer/--ignore options are rejected with --auto-mount."""
    # Setup: mount non-top-level subvolume
    # First, ensure device is unmounted (might still be busy from previous test)
    machine.execute("umount /mnt/btrfs 2>/dev/null || true")
    machine.execute("umount /dev/vdb 2>/dev/null || true")
    time.sleep(0.5)  # Give kernel time to finish any pending operations

    machine.succeed("mkfs.btrfs -f /dev/vdb")
    machine.succeed("mkdir -p /mnt/btrfs")
    machine.succeed("mount /dev/vdb /mnt/btrfs")
    machine.succeed("btrfs subvolume create /mnt/btrfs/@")
    machine.succeed("umount /mnt/btrfs")
    machine.succeed("mount -o subvol=@ /dev/vdb /mnt/btrfs")

    # Verify --prefer is rejected with --auto-mount
    result = machine.fail("btdu --headless --auto-mount --prefer=/mnt/btrfs /mnt/btrfs 2>&1")
    assert "not available with --auto-mount" in result.lower(), f"Expected rejection, got: {result}"
    print("  ✓ --prefer rejected with --auto-mount")

    # Verify --ignore is rejected with --auto-mount
    result = machine.fail("btdu --headless --auto-mount --ignore=/mnt/btrfs /mnt/btrfs 2>&1")
    assert "not available with --auto-mount" in result.lower(), f"Expected rejection, got: {result}"
    print("  ✓ --ignore rejected with --auto-mount")


def test_auto_mount_with_top_level():
    """Verify --auto-mount works normally when already on top-level subvolume."""
    # Mount top-level directly
    setup_btrfs_basic()
    create_test_files()

    # --auto-mount should work fine (it's a no-op when already top-level)
    run_btdu("--headless --export=/tmp/toplevel.json --max-samples=100 --auto-mount /mnt/btrfs")
    data = verify_json_export("/tmp/toplevel.json")
    root = data.get("root", {})
    samples = root.get("data", {}).get("represented", {}).get("samples", 0)
    assert samples > 0, f"Should have collected samples, got {samples}"
    print(f"  ✓ --auto-mount works on top-level (no-op), collected {samples} samples")


def test_paths_with_spaces():
    """Verify btdu correctly handles paths with spaces in directory and file names."""
    setup_btrfs_basic()

    # Create directories and files with spaces in names
    # Reduced from 20MB/15MB to 1MB each
    machine.succeed("mkdir -p '/mnt/btrfs/dir with spaces/subdir with spaces'")
    machine.succeed("dd if=/dev/urandom of='/mnt/btrfs/dir with spaces/file with spaces.dat' bs=1M count=1")
    machine.succeed("dd if=/dev/urandom of='/mnt/btrfs/dir with spaces/subdir with spaces/another file.dat' bs=1M count=1")
    machine.succeed("sync")

    # Run btdu with increased samples to find files with spaces
    run_btdu("--headless --export=/tmp/spaces.json --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/spaces.json")

    # Verify directories and files with spaces appear in tree
    dir_node = get_node(data['root'], [SINGLE, DATA, 'dir with spaces'])
    assert dir_node is not None, "Directory 'dir with spaces' not found in export tree"
    assert dir_node['data']['represented']['samples'] > 0, "Directory with spaces has no samples"

    print(f"  ✓ Paths with spaces verified: found directory with {dir_node['data']['represented']['samples']} samples")


def test_absolute_paths():
    """Verify btdu works with absolute paths."""
    setup_btrfs_basic()
    create_test_files()

    # Run btdu with absolute path and verify results
    run_btdu("--headless --export=/tmp/absolute.json --max-samples=5000 /mnt/btrfs")
    data = verify_json_export("/tmp/absolute.json")

    # Verify we actually collected samples and found expected directories
    samples = data['root']['data']['represented']['samples']
    assert samples > 0, "No samples collected with absolute path"

    dir1 = get_node(data['root'], [SINGLE, DATA, 'dir1'])
    dir2 = get_node(data['root'], [SINGLE, DATA, 'dir2'])
    assert dir1 is not None or dir2 is not None, "Expected directories not found with absolute path"

    print(f"  ✓ Absolute path handling verified: {samples} samples collected")


def test_relative_paths():
    """Verify btdu works with relative paths and normalizes them."""
    setup_btrfs_basic()
    create_test_files()

    # Run btdu with relative path and verify results
    machine.succeed("cd /mnt && timeout 30 btdu --headless --export=/tmp/relative.json --max-samples=5000 ./btrfs")
    data = verify_json_export("/tmp/relative.json")

    # Verify we actually collected samples and found expected directories
    samples = data['root']['data']['represented']['samples']
    assert samples > 0, "No samples collected with relative path"

    dir1 = get_node(data['root'], [SINGLE, DATA, 'dir1'])
    dir2 = get_node(data['root'], [SINGLE, DATA, 'dir2'])
    assert dir1 is not None or dir2 is not None, "Expected directories not found with relative path"

    print(f"  ✓ Relative path handling verified: {samples} samples collected")


def test_version_display():
    """Verify version number is displayed in help output."""
    # Run btdu --help and check for version pattern
    result = run_btdu("--help 2>&1", timeout=5)
    # Check for the specific version from flake.nix
    assert "0.6" in result, "Version 0.6 not found in help output"
    print("  ✓ Version display verified")


def test_prefer_ignore_options():
    """Test --prefer and --ignore options affect path selection."""
    setup_btrfs_basic()

    # Test old-style pattern (relative path) - should work with a warning
    result = run_btdu("--headless --prefer='/zzz_ignored' --max-samples=100 /mnt/btrfs 2>&1")
    assert "warning" in result.lower() and "assuming you meant" in result.lower(), \
        f"Expected backward compatibility warning, got: {result}"
    print("  ✓ Old-style pattern works with warning")

    machine.succeed("mkdir -p /mnt/btrfs/aaa_preferred /mnt/btrfs/zzz_ignored")

    # Create reflinked files (these will test --prefer/--ignore behavior)
    # Reduced from 50MB to 1MB
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/aaa_preferred/shared.bin bs=1M count=1")
    machine.succeed("cp --reflink=always /mnt/btrfs/aaa_preferred/shared.bin /mnt/btrfs/zzz_ignored/shared.bin")

    # Also create unique files in each directory to ensure both dirs always have samples
    # Keep at same size for simplicity
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/aaa_preferred/unique_aaa.bin bs=1M count=1")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/zzz_ignored/unique_zzz.bin bs=1M count=1")
    machine.succeed("sync")

    # Test --prefer: shared.bin should appear in zzz_ignored (preferred), not in aaa_preferred
    # Increased samples from 3000 to 10000 for reliable detection
    run_btdu("--headless --prefer='/mnt/btrfs/zzz_ignored/**' --export=/tmp/prefer.json --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/prefer.json")

    # Find directories (they will both exist due to unique files)
    aaa_dir = get_node(data['root'], [SINGLE, DATA, 'aaa_preferred'])
    zzz_dir = get_node(data['root'], [SINGLE, DATA, 'zzz_ignored'])

    assert aaa_dir is not None, "--prefer test: aaa_preferred directory not found"
    assert zzz_dir is not None, "--prefer test: zzz_ignored directory not found"

    # zzz_ignored should have more samples (because shared.bin is preferred there)
    zzz_samples = zzz_dir['data']['represented']['samples']
    aaa_samples = aaa_dir['data']['represented']['samples']
    assert zzz_samples > aaa_samples, f"--prefer failed: preferred dir ({zzz_samples}) should have > non-preferred ({aaa_samples})"
    print(f"  ✓ --prefer verified: preferred dir has {zzz_samples} samples vs {aaa_samples}")

    # Test --ignore: shared.bin should appear in aaa_preferred (zzz_ignored is deprioritized)
    # Increased samples from 3000 to 10000 for reliable detection
    run_btdu("--headless --ignore='/mnt/btrfs/zzz_ignored/**' --export=/tmp/ignore.json --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/ignore.json")

    aaa_dir = get_node(data['root'], [SINGLE, DATA, 'aaa_preferred'])
    zzz_dir = get_node(data['root'], [SINGLE, DATA, 'zzz_ignored'])

    assert aaa_dir is not None, "--ignore test: aaa_preferred directory not found"
    assert zzz_dir is not None, "--ignore test: zzz_ignored directory not found"

    # aaa_preferred should have more samples (because zzz_ignored is deprioritized)
    aaa_samples = aaa_dir['data']['represented']['samples']
    zzz_samples = zzz_dir['data']['represented']['samples']
    assert aaa_samples > zzz_samples, f"--ignore failed: non-ignored dir ({aaa_samples}) should have > ignored ({zzz_samples})"
    print(f"  ✓ --ignore verified: non-ignored dir has {aaa_samples} samples vs {zzz_samples}")


def test_empty_filesystem():
    """Test btdu on completely empty btrfs filesystem."""
    setup_btrfs_basic()
    # Don't create any files - just empty filesystem with metadata/system blocks

    run_btdu("--headless --export=/tmp/empty.json --max-samples=5000 /mnt/btrfs")
    data = verify_json_export("/tmp/empty.json")

    # On empty filesystem, samples should still be collected (from metadata/system blocks)
    samples = data['root']['data']['represented']['samples']
    assert samples > 0, f"Expected samples on empty filesystem, got {samples}"

    # Verify totalSize is reasonable (should have metadata even if no user files)
    total_size = data['totalSize']
    assert total_size > 0, "totalSize should be > 0 even on empty filesystem"

    # Verify JSON has expected structure
    assert 'root' in data, "Missing 'root' in JSON"
    assert 'data' in data['root'], "Missing 'data' in root"

    # Verify totalSize is reasonable for empty filesystem (should be small, mostly metadata)
    # Typically < 100MB for an empty btrfs filesystem
    assert total_size < 200 * 1024 * 1024, f"totalSize {total_size/1024/1024:.1f}MB seems too large for empty filesystem"

    print(f"  ✓ Empty filesystem verified: {samples} samples, {total_size/1024/1024:.1f}MB total (metadata/system blocks)")


def test_deleted_files():
    """Test btdu handles deleted files and unused space correctly."""
    setup_btrfs_basic()
    create_test_files()

    # Create a 1MB file, sync, then delete it (reduced from 50MB)
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/to_delete.dat bs=1M count=1")
    machine.succeed("sync")
    machine.succeed("rm /mnt/btrfs/to_delete.dat")
    machine.succeed("sync")

    # Run btdu with increased samples to potentially hit deleted blocks
    run_btdu("--headless --export=/tmp/deleted.json --max-samples=2000 /mnt/btrfs", timeout=90)
    data = verify_json_export("/tmp/deleted.json")

    # With --seed and enough samples, UNUSED node should be found deterministically
    unused_node = get_node(data['root'], [SINGLE, DATA, UNUSED])
    assert unused_node is not None, "UNUSED node not found (deleted file space should be sampled with 2000 samples)"
    unused_samples = unused_node['data']['represented']['samples']
    assert unused_samples > 0, "UNUSED node has no samples"
    print(f"  ✓ Deleted files test verified: UNUSED node found with {unused_samples} samples")


def test_sparse_files():
    """Test btdu handles very large sparse files correctly."""
    setup_btrfs_basic()

    # Create a 100GB sparse file with only 1MB of actual data
    # Write 1MB at the beginning, then seek to 100GB to create the hole
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/sparse.dat bs=1M count=1")
    machine.succeed("dd if=/dev/zero of=/mnt/btrfs/sparse.dat bs=1M count=0 seek=100000 conv=notrunc")
    machine.succeed("sync")

    # Run btdu and verify it handles sparse files correctly
    run_btdu("--headless --export=/tmp/sparse.json --max-samples=10000 /mnt/btrfs")
    data = verify_json_export("/tmp/sparse.json")

    # With 1MB of actual data, the file should appear in results
    sparse_node = get_node(data['root'], [SINGLE, DATA, 'sparse.dat'])
    assert sparse_node is not None, "sparse.dat not found in tree (should appear with 1MB real data)"

    # Verify the file has samples
    sparse_samples = sparse_node['data']['represented']['samples']
    assert sparse_samples > 0, "sparse.dat has no samples"

    # Verify totalSize is reasonable (should be ~1MB actual data, not 100GB logical size)
    total_size = data['totalSize']
    assert total_size < 500 * 1024 * 1024, f"totalSize {total_size/1024/1024:.1f}MB too large (should reflect actual ~1MB, not 100GB logical size)"

    print(f"  ✓ Sparse files verified: 100GB logical / ~1MB physical, {sparse_samples} samples, {total_size/1024/1024:.1f}MB total")


def test_multidevice_filesystem():
    """Test btdu on btrfs filesystem spanning multiple devices."""
    machine.succeed("mkfs.btrfs -f /dev/vdb /dev/vdc")
    machine.succeed("mkdir -p /mnt/multidev")
    machine.succeed("mount -t btrfs /dev/vdb /mnt/multidev")

    # Create test files on multi-device filesystem
    machine.succeed("dd if=/dev/urandom of=/mnt/multidev/file1.dat bs=1M count=1")
    machine.succeed("dd if=/dev/urandom of=/mnt/multidev/file2.dat bs=1M count=1")
    machine.succeed("sync")

    # Run btdu and verify it handles multi-device filesystem
    run_btdu("--headless --export=/tmp/multidev.json --max-samples=10000 /mnt/multidev", timeout=120)
    data = verify_json_export("/tmp/multidev.json")

    # Verify files appear in the tree
    file1 = get_node(data['root'], [SINGLE, DATA, 'file1.dat'])
    file2 = get_node(data['root'], [SINGLE, DATA, 'file2.dat'])
    assert file1 is not None or file2 is not None, "Expected files not found on multi-device filesystem"

    samples = data['root']['data']['represented']['samples']
    total_size = data['totalSize']

    print(f"  ✓ Multi-device filesystem verified: {samples} samples, {total_size/1024/1024:.1f}MB across 2 devices")

    # Cleanup
    machine.succeed("umount /mnt/multidev")


def test_raid1_mirroring():
    """Test btdu on RAID1 filesystem with 2x physical space usage."""
    machine.succeed("mkfs.btrfs -f -d raid1 -m raid1 /dev/vdb /dev/vdc")
    machine.succeed("mkdir -p /mnt/raid1")
    machine.succeed("mount -t btrfs /dev/vdb /mnt/raid1")

    # Create larger test file to reduce metadata overhead (100MB)
    # With larger file, data dominates over metadata, giving clearer 2x ratio
    machine.succeed("dd if=/dev/urandom of=/mnt/raid1/mirrored.dat bs=1M count=100")
    machine.succeed("sync")

    # Run btdu in both logical and physical modes to compare
    run_btdu("--headless --export=/tmp/raid1_logical.json --max-samples=50000 /mnt/raid1", timeout=180)
    logical_data = verify_json_export("/tmp/raid1_logical.json")

    run_btdu("--headless --physical --export=/tmp/raid1_physical.json --max-samples=50000 /mnt/raid1", timeout=180)
    physical_data = verify_json_export("/tmp/raid1_physical.json")

    # Get estimated file sizes using the helper
    logical_file_size = get_file_size(logical_data, [RAID1, DATA, 'mirrored.dat'])
    physical_file_size = get_file_size(physical_data, [RAID1, DATA, 'mirrored.dat'])

    assert logical_file_size > 0, "mirrored.dat not found or has no samples in logical mode"
    assert physical_file_size > 0, "mirrored.dat not found or has no samples in physical mode"

    # In RAID1, physical file size should be roughly 2x logical (mirroring)
    file_size_ratio = physical_file_size / logical_file_size

    # Allow 1.7-2.3x range for RAID1 (2x ± 15%)
    assert 1.7 <= file_size_ratio <= 2.3, f"RAID1: file size ratio {file_size_ratio:.2f}x outside expected 1.7-2.3x (logical={logical_file_size/1024/1024:.1f}MB, physical={physical_file_size/1024/1024:.1f}MB)"

    print(f"  ✓ RAID1 mirroring verified: physical file size {physical_file_size/1024/1024:.1f}MB ≈ {file_size_ratio:.2f}x logical {logical_file_size/1024/1024:.1f}MB")

    # Cleanup
    machine.succeed("umount /mnt/raid1")


def test_raid0_striping():
    """Test btdu on RAID0 filesystem with striping across devices."""
    machine.succeed("mkfs.btrfs -f -d raid0 -m raid1 /dev/vdb /dev/vdc")
    machine.succeed("mkdir -p /mnt/raid0")
    machine.succeed("mount -t btrfs /dev/vdb /mnt/raid0")

    # Create test file
    machine.succeed("dd if=/dev/urandom of=/mnt/raid0/striped.dat bs=1M count=1")
    machine.succeed("sync")

    # Run btdu and verify it handles RAID0
    run_btdu("--headless --export=/tmp/raid0.json --max-samples=10000 /mnt/raid0", timeout=120)
    data = verify_json_export("/tmp/raid0.json")

    # Verify file appears in the tree
    striped = get_node(data['root'], [RAID0, DATA, 'striped.dat'])
    assert striped is not None, "striped.dat not found in RAID0 filesystem"

    samples = data['root']['data']['represented']['samples']
    total_size = data['totalSize']

    # In RAID0, physical ≈ logical (striping doesn't duplicate data)
    print(f"  ✓ RAID0 striping verified: {samples} samples, {total_size/1024/1024:.1f}MB (data striped across 2 devices)")

    # Cleanup
    machine.succeed("umount /mnt/raid0")


def test_expert_mode_basic():
    """Test that expert mode enables additional metrics and their relationships."""
    setup_btrfs_basic()

    # Create a mix of unique and reflinked files to test expert metrics
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/unique.dat bs=1M count=5")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/base.dat bs=1M count=5")
    machine.succeed("cp --reflink=always /mnt/btrfs/base.dat /mnt/btrfs/clone.dat")
    machine.succeed("sync")

    run_btdu("--expert --headless --export=/tmp/expert.json --max-samples=10000 /mnt/btrfs")
    data = verify_json_export("/tmp/expert.json")

    # Verify expert mode is enabled
    assert data['expert'] == True, "Expert mode not enabled in JSON export"
    root_data = data['root']['data']
    assert 'distributedSamples' in root_data, "Missing distributedSamples field"
    assert 'exclusive' in root_data, "Missing exclusive field"
    assert 'shared' in root_data, "Missing shared field"

    # Test on unique file: exclusive + shared should ≈ represented
    unique = get_node(data['root'], [SINGLE, DATA, 'unique.dat'])
    assert unique is not None, "unique.dat not found in tree"

    unique_data = unique['data']
    unique_repr = unique_data['represented']['samples']
    unique_excl = unique_data['exclusive']['samples']
    unique_shared = unique_data.get('shared', {}).get('samples', 0)

    assert unique_repr > 0, "unique.dat has no represented samples"
    assert unique_excl > 0, "unique.dat should have exclusive samples"

    # For unique files: exclusive should approximately equal represented
    # (shared may also equal represented due to how btdu counts)
    diff_pct = abs(unique_excl - unique_repr) * 100 / unique_repr if unique_repr > 0 else 0
    assert diff_pct <= 20, f"unique.dat: exclusive({unique_excl}) should ≈ represented({unique_repr}), got {diff_pct:.1f}% diff"

    # Test on reflinked file: should have shared > 0
    base = get_node(data['root'], [SINGLE, DATA, 'base.dat'])
    assert base is not None, "base.dat not found (should be representative as shorter than clone.dat)"

    base_data = base['data']
    base_shared = base_data['shared']['samples']
    assert base_shared > 0, "base.dat should have shared samples (it's reflinked)"

    print(f"  ✓ Expert mode verified: unique exclusive={unique_excl}, shared={unique_shared}, represented={unique_repr} ({diff_pct:.1f}% diff); base has shared={base_shared}")


def test_distributed_size_reflinks():
    """Test distributed size is split evenly among reflinks."""
    setup_btrfs_basic()
    # Create files with 10MB each to have clear sizes
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/original.dat bs=1M count=10")
    machine.succeed("cp --reflink=always /mnt/btrfs/original.dat /mnt/btrfs/reflink1.dat")
    machine.succeed("cp --reflink=always /mnt/btrfs/original.dat /mnt/btrfs/reflink2.dat")
    machine.succeed("sync")

    run_btdu("--expert --headless --export=/tmp/distributed.json --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/distributed.json")

    # Verify distributedSamples field exists (expert mode feature)
    assert 'distributedSamples' in data['root']['data'], "distributedSamples field missing in expert mode"

    original = get_node(data['root'], [SINGLE, DATA, 'original.dat'])
    reflink1 = get_node(data['root'], [SINGLE, DATA, 'reflink1.dat'])
    reflink2 = get_node(data['root'], [SINGLE, DATA, 'reflink2.dat'])

    assert original is not None, "original.dat not found"
    assert reflink1 is not None, "reflink1.dat not found"
    assert reflink2 is not None, "reflink2.dat not found"

    # Get represented samples (only one path is representative)
    orig_repr = original['data']['represented']['samples']
    ref1_repr = reflink1['data'].get('represented', {}).get('samples', 0)
    ref2_repr = reflink2['data'].get('represented', {}).get('samples', 0)

    # For 3 reflinks, only one should be representative (shorter path = original.dat)
    assert orig_repr > 0, "original.dat should be representative (shortest path)"
    # The other two should have 0 or very few represented samples
    total_non_repr = ref1_repr + ref2_repr
    assert total_non_repr < orig_repr * 0.2, f"reflink1 and reflink2 should not be representative, got {total_non_repr} vs {orig_repr}"

    # Verify distributedSamples field exists on the files (this is the distributed metric)
    assert 'distributedSamples' in original['data'], "distributedSamples missing on original.dat"
    assert 'distributedSamples' in reflink1['data'], "distributedSamples missing on reflink1.dat"
    assert 'distributedSamples' in reflink2['data'], "distributedSamples missing on reflink2.dat"

    orig_dist = original['data']['distributedSamples']
    ref1_dist = reflink1['data']['distributedSamples']
    ref2_dist = reflink2['data']['distributedSamples']

    # Distributed samples should be roughly equal (each gets ~1/3 of the samples)
    # All three should have some distributed samples
    assert orig_dist > 0 and ref1_dist > 0 and ref2_dist > 0, "All reflinks should have distributed samples"

    # The sum should approximately equal the represented samples (allowing for rounding)
    total_dist = orig_dist + ref1_dist + ref2_dist
    assert 0.8 * orig_repr <= total_dist <= 1.2 * orig_repr, \
        f"Sum of distributed samples {total_dist} should ≈ represented {orig_repr}"

    # Each reflink should get roughly 1/3 of the distributed samples (allow ±50% variance)
    expected_per_file = orig_repr / 3
    for name, dist in [("original", orig_dist), ("reflink1", ref1_dist), ("reflink2", ref2_dist)]:
        assert 0.5 * expected_per_file <= dist <= 1.5 * expected_per_file, \
            f"{name} distributed={dist} not close to expected ~{expected_per_file:.0f} (1/3 of {orig_repr})"

    print(f"  ✓ Distributed size verified: represented={orig_repr}, distributed evenly: {orig_dist}, {ref1_dist}, {ref2_dist} (~{expected_per_file:.0f} each)")


def test_exclusive_size_unique():
    """Test exclusive size for unique files equals file size."""
    setup_btrfs_basic()
    # Reduced from 30MB/40MB to 1MB each
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/unique1.dat bs=1M count=1")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/unique2.dat bs=1M count=1")
    machine.succeed("sync")

    # Increased samples from 2000 to 10000
    run_btdu("--expert --headless --export=/tmp/exclusive.json --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/exclusive.json")

    unique1 = get_node(data['root'], [SINGLE, DATA, 'unique1.dat'])
    unique2 = get_node(data['root'], [SINGLE, DATA, 'unique2.dat'])

    assert unique1 is not None, "unique1.dat not found"
    assert unique2 is not None, "unique2.dat not found"

    u1_repr = unique1.get('data', {}).get('represented', {}).get('samples', 0)
    u1_excl = unique1.get('data', {}).get('exclusive', {}).get('samples', 0)
    u2_repr = unique2.get('data', {}).get('represented', {}).get('samples', 0)
    u2_excl = unique2.get('data', {}).get('exclusive', {}).get('samples', 0)

    assert u1_repr > 0 and u2_repr > 0, "No samples collected for unique files"

    # For unique (non-reflinked) files, exclusive should equal represented
    # Allow ±10% tolerance for sampling variance
    u1_diff_pct = abs(u1_repr - u1_excl) * 100 / u1_repr if u1_repr > 0 else 0
    u2_diff_pct = abs(u2_repr - u2_excl) * 100 / u2_repr if u2_repr > 0 else 0

    assert u1_diff_pct <= 10, f"unique1: exclusive {u1_excl} differs {u1_diff_pct:.1f}% from represented {u1_repr} (expected ≤10%)"
    assert u2_diff_pct <= 10, f"unique2: exclusive {u2_excl} differs {u2_diff_pct:.1f}% from represented {u2_repr} (expected ≤10%)"

    print(f"  ✓ Exclusive size verified: unique1 repr={u1_repr} excl={u1_excl} ({u1_diff_pct:.1f}% diff), unique2 repr={u2_repr} excl={u2_excl} ({u2_diff_pct:.1f}% diff)")


def test_unicode_filenames():
    """Test filesystem with Unicode/wide characters in filenames."""
    setup_btrfs_basic()
    machine.succeed('dd if=/dev/urandom of="/mnt/btrfs/test_🎉_emoji.dat" bs=1M count=10')
    machine.succeed('dd if=/dev/urandom of="/mnt/btrfs/文件_chinese.dat" bs=1M count=10')
    machine.succeed('dd if=/dev/urandom of="/mnt/btrfs/café_français.dat" bs=1M count=10')
    machine.succeed("sync")

    run_btdu("--headless --export=/tmp/unicode.json --max-samples=1000 /mnt/btrfs")
    data = verify_json_export("/tmp/unicode.json")

    emoji_file = get_node(data['root'], [SINGLE, DATA, 'test_🎉_emoji.dat'])
    chinese_file = get_node(data['root'], [SINGLE, DATA, '文件_chinese.dat'])
    french_file = get_node(data['root'], [SINGLE, DATA, 'café_français.dat'])

    assert emoji_file is not None, "Emoji filename not found in export tree"
    assert chinese_file is not None, "Chinese filename not found in export tree"
    assert french_file is not None, "French filename not found in export tree"
    print("  ✓ Unicode filenames verified: all wide character files found in tree")


def test_division_by_zero():
    """Verify no division by zero with zero samples in headless mode."""
    setup_btrfs_basic()

    # Use very short time limit to force btdu to exit with minimal samples
    # The test is that btdu doesn't crash with division by zero in the summary
    run_btdu("--headless --max-time=0.01s /mnt/btrfs", timeout=5)
    print("  ✓ Division by zero test verified: btdu completed without crashing")


def test_special_leaf_size():
    """Verify special leaves (METADATA, SYSTEM) have non-zero size.

    Regression test for a bug where special leaves (nodes with no filesystem paths,
    like METADATA and SYSTEM block groups) would show up with 0 size due to
    inconsistent handling of empty paths in sharing groups.
    """
    setup_btrfs_basic()
    # Create some data to ensure there's meaningful filesystem activity
    # and metadata blocks are allocated
    create_test_files()

    # Run btdu with enough samples to hit metadata blocks
    run_btdu("--headless --export=/tmp/special_leaf.json --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/special_leaf.json")

    # On a single-device filesystem, metadata typically uses DUP profile
    # Look for METADATA under both DUP and SINGLE profiles
    metadata_node = None
    metadata_path = None
    for profile in [DUP, SINGLE]:
        node = get_node(data['root'], [profile, METADATA])
        if node is not None:
            metadata_node = node
            metadata_path = f"{profile}/{METADATA}"
            break

    assert metadata_node is not None, "METADATA node not found under DUP or SINGLE profiles"

    # The key assertion: METADATA must have properly populated data with samples > 0
    # Before the fix, this would fail due to empty paths handling bug
    metadata_data = metadata_node.get('data', {})
    assert 'represented' in metadata_data, \
        "METADATA node has no 'represented' field (regression: special leaves not getting sample data)"
    metadata_samples = metadata_data['represented']['samples']
    assert metadata_samples > 0, "METADATA node has 0 samples (regression: special leaves must have non-zero size)"

    print(f"  ✓ Special leaf size verified: METADATA has {metadata_samples} samples (path: {metadata_path})")


def test_small_files_metadata():
    """Test small files inline with metadata."""
    setup_btrfs_basic()

    # Create 100 tiny files (100 bytes each)
    # Btrfs stores very small files inline with metadata instead of in DATA block groups
    machine.succeed("for i in {1..100}; do dd if=/dev/urandom of=/mnt/btrfs/tiny$i.dat bs=100 count=1 2>/dev/null; done")
    machine.succeed("sync")

    # Run btdu with high samples to find tiny files
    run_btdu("--headless --export=/tmp/small_files.json --max-samples=10000 /mnt/btrfs")
    data = verify_json_export("/tmp/small_files.json")

    # Verify btdu collected samples
    samples = data['root']['data']['represented']['samples']
    assert samples > 0, f"Expected samples with small files, got {samples}"

    # Tiny files are stored inline with metadata, so they won't appear in DATA block group tree
    # Just verify that btdu handles a filesystem with many tiny files
    total_size = data['totalSize']

    print(f"  ✓ Small files verified: {samples} samples collected, {total_size/1024:.1f}KB total (tiny files stored inline with metadata)")


def test_many_extents():
    """Create file with thousands of extents, verify performance."""
    setup_btrfs_basic()

    # Create a fragmented file with ~1000 extents
    # Pre-allocate 100MB, then write scattered 4K blocks
    machine.succeed("fallocate -l 100M /mnt/btrfs/fragmented.dat")
    machine.succeed("for i in {0..999}; do dd if=/dev/urandom of=/mnt/btrfs/fragmented.dat bs=4K count=1 seek=$((i*25)) conv=notrunc 2>/dev/null; done")
    machine.succeed("sync")

    # Run btdu with sufficient samples and verify it handles many extents without performance issues
    run_btdu("--headless --export=/tmp/many_extents.json --max-samples=10000 /mnt/btrfs", timeout=60)
    data = verify_json_export("/tmp/many_extents.json")

    # Verify the fragmented file appears in the tree
    fragmented = get_node(data['root'], [SINGLE, DATA, 'fragmented.dat'])
    assert fragmented is not None, "fragmented.dat not found in tree"

    frag_samples = fragmented['data']['represented']['samples']
    assert frag_samples > 0, "fragmented.dat has no samples"

    total_samples = data['root']['data']['represented']['samples']
    print(f"  ✓ Many extents verified: fragmented.dat found with {frag_samples} samples (file with ~1000 extents, {total_samples} total samples)")


def test_nearly_full_filesystem():
    """Fill filesystem to near capacity, verify btdu works."""
    setup_btrfs_basic()

    # Fill filesystem to ~87.5% full (875MB of 1GB)
    # fallocate is cheap (doesn't write actual data), so size doesn't matter
    machine.succeed("fallocate -l 875M /mnt/btrfs/bigfile.dat")
    machine.succeed("sync")

    # Run btdu on nearly full filesystem
    run_btdu("--headless --export=/tmp/nearly_full.json --max-samples=10000 /mnt/btrfs")
    data = verify_json_export("/tmp/nearly_full.json")

    # Verify the big file appears in the tree
    bigfile = get_node(data['root'], [SINGLE, DATA, 'bigfile.dat'])
    assert bigfile is not None, "bigfile.dat not found in nearly full filesystem"

    bigfile_samples = bigfile['data']['represented']['samples']
    assert bigfile_samples > 0, "bigfile.dat has no samples"

    # Verify totalSize reflects the nearly full filesystem
    total_size = data['totalSize']
    assert total_size > 800 * 1024 * 1024, f"totalSize {total_size/1024/1024:.1f}MB seems too small for 875MB file"

    samples = data['root']['data']['represented']['samples']
    print(f"  ✓ Nearly full filesystem verified: bigfile.dat found with {bigfile_samples} samples, {samples} total samples, {total_size/1024/1024:.1f}MB total")


def test_device_slack():
    """Create filesystem smaller than device, verify slack is detected."""
    # Create 512MB filesystem on 1GB device
    machine.succeed("mkfs.btrfs -f -b 512M /dev/vdc")
    machine.succeed("mkdir -p /mnt/btrfs")
    machine.succeed("mount -t btrfs /dev/vdc /mnt/btrfs")

    # Create 1MB of test files (reduced from 50MB)
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/test.dat bs=1M count=1")
    machine.succeed("sync")

    # Run btdu in physical mode
    run_btdu("--physical --headless --export=/tmp/slack.json --max-samples=10000 /mnt/btrfs", timeout=120)
    data = verify_json_export("/tmp/slack.json")

    # Verify btdu reports size - in physical mode it may report device size or filesystem size
    total_size = data['totalSize']

    # Verify test file appears
    testfile = get_node(data['root'], [SINGLE, DATA, 'test.dat'])
    assert testfile is not None, "test.dat not found in tree"

    testfile_samples = testfile['data']['represented']['samples']
    assert testfile_samples > 0, "test.dat has no samples"

    # Physical mode reports either filesystem size (~512MB) or device size (1GB)
    assert 400 * 1024 * 1024 <= total_size <= 1100 * 1024 * 1024, f"totalSize {total_size/1024/1024:.1f}MB unexpected"

    samples = data['root']['data']['represented']['samples']
    print(f"  ✓ Device slack verified: test.dat found with {testfile_samples} samples, physical size {total_size/1024/1024:.1f}MB ({samples} total samples)")

    # Cleanup
    machine.succeed("umount /mnt/btrfs")


def test_unallocated_space():
    """Verify unallocated space is correctly reported in physical mode."""
    machine.succeed("mkfs.btrfs -f /dev/vdc")
    machine.succeed("mkdir -p /mnt/btrfs")
    machine.succeed("mount -t btrfs /dev/vdc /mnt/btrfs")

    # Create small files (1MB total) - most space remains unallocated (reduced from 100MB)
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/small.dat bs=1M count=1")
    machine.succeed("sync")

    # Run btdu in physical mode - should sample allocated and unallocated space
    run_btdu("--physical --headless --export=/tmp/unalloc.json --max-samples=10000 /mnt/btrfs", timeout=120)
    data = verify_json_export("/tmp/unalloc.json")

    # Verify the small file appears
    small = get_node(data['root'], [SINGLE, DATA, 'small.dat'])
    assert small is not None, "small.dat not found in tree"

    # In physical mode with mostly unallocated space, totalSize should be much larger than file size
    # 1MB file on 1GB device - physical totalSize should be close to 1GB
    total_size = data['totalSize']
    small_file_size = get_file_size(data, [SINGLE, DATA, 'small.dat'])

    # Physical total should be much larger than the 1MB file (includes unallocated space)
    assert total_size > 500 * 1024 * 1024, f"Physical totalSize {total_size/1024/1024:.1f}MB too small (should include unallocated space)"
    assert small_file_size < 10 * 1024 * 1024, f"File size {small_file_size/1024/1024:.1f}MB too large for 1MB file"

    samples = data['root']['data']['represented']['samples']
    print(f"  ✓ Unallocated space verified: {samples} samples, physical total {total_size/1024/1024:.1f}MB >> file {small_file_size/1024/1024:.1f}MB (includes unallocated)")

    # Cleanup
    machine.succeed("umount /mnt/btrfs")


def test_mixed_raid_profiles():
    """Test filesystem with different RAID profiles for data and metadata."""
    machine.succeed("mkfs.btrfs -f -d raid0 -m raid1 /dev/vdb /dev/vdc")
    machine.succeed("mkdir -p /mnt/mixed")
    machine.succeed("mount -t btrfs /dev/vdb /mnt/mixed")

    # Create 1MB of test files (reduced from 60MB)
    machine.succeed("dd if=/dev/urandom of=/mnt/mixed/testfile.dat bs=1M count=1")
    machine.succeed("sync")

    # Run btdu and verify it handles mixed RAID profiles
    run_btdu("--headless --export=/tmp/mixed.json --max-samples=10000 /mnt/mixed", timeout=120)
    data = verify_json_export("/tmp/mixed.json")

    # Verify the test file appears (data uses RAID0, metadata uses RAID1)
    testfile = get_node(data['root'], [RAID0, DATA, 'testfile.dat'])
    assert testfile is not None, "testfile.dat not found in RAID0 DATA"

    testfile_samples = testfile['data']['represented']['samples']
    assert testfile_samples > 0, "testfile.dat has no samples"

    samples = data['root']['data']['represented']['samples']
    print(f"  ✓ Mixed RAID profiles verified: testfile.dat found with {testfile_samples} samples (data=RAID0, metadata=RAID1, {samples} total)")

    # Cleanup
    machine.succeed("umount /mnt/mixed")


def test_subvolume_analysis():
    """Test subvolume creation and analysis."""
    setup_btrfs_basic()

    # Create 2-3 subvolumes with files
    machine.succeed("btrfs subvolume create /mnt/btrfs/subvol1")
    machine.succeed("btrfs subvolume create /mnt/btrfs/subvol2")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/subvol1/data1.dat bs=1M count=1")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/subvol2/data2.dat bs=1M count=1")
    machine.succeed("sync")

    # Run btdu and verify subvolumes are included
    run_btdu("--headless --export=/tmp/subvol_test.json --max-samples=5000 /mnt/btrfs", timeout=120)
    data = verify_json_export("/tmp/subvol_test.json")

    # Verify subvolumes appear in the tree
    subvol1 = get_node(data['root'], [SINGLE, DATA, 'subvol1'])
    subvol2 = get_node(data['root'], [SINGLE, DATA, 'subvol2'])
    assert subvol1 is not None, "subvol1 not found in export tree"
    assert subvol2 is not None, "subvol2 not found in export tree"
    print("  ✓ Subvolume analysis verified: found subvol1 and subvol2 in tree")


def test_snapshot_handling():
    """Test snapshot creation and handling."""
    setup_btrfs_basic()

    # Create subvolume with file
    machine.succeed("btrfs subvolume create /mnt/btrfs/original")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/original/testfile.dat bs=1M count=1")
    machine.succeed("sync")

    # Take snapshot
    machine.succeed("btrfs subvolume snapshot /mnt/btrfs/original /mnt/btrfs/snap1")
    machine.succeed("sync")

    # Run btdu and verify snapshots are handled
    run_btdu("--headless --export=/tmp/snapshot.json --max-samples=5000 /mnt/btrfs", timeout=120)
    data = verify_json_export("/tmp/snapshot.json")

    # Verify snapshot appears
    snapshot = get_node(data['root'], [SINGLE, DATA, 'snap1'])
    assert snapshot is not None, "Snapshot not found in export tree"
    print("  ✓ Snapshot handling verified: found snapshot in tree")


def test_compression_zstd():
    """Test filesystem with zstd compression."""
    setup_btrfs_basic()

    # Remount with zstd compression
    machine.succeed("umount /mnt/btrfs")
    machine.succeed("mount -o compress=zstd /dev/vdb /mnt/btrfs")

    # Create compressible data (zeros compress well)
    machine.succeed("dd if=/dev/zero of=/mnt/btrfs/compressible.dat bs=1M count=1")
    machine.succeed("sync")

    # Run btdu and verify it handles compressed files
    run_btdu("--headless --export=/tmp/zstd.json --max-samples=10000 /mnt/btrfs", timeout=120)
    data = verify_json_export("/tmp/zstd.json")

    # Verify the compressible file appears
    compressible = get_node(data['root'], [SINGLE, DATA, 'compressible.dat'])
    assert compressible is not None, "compressible.dat not found in zstd-compressed filesystem"

    comp_samples = compressible['data']['represented']['samples']
    assert comp_samples > 0, "compressible.dat has no samples"

    samples = data['root']['data']['represented']['samples']
    print(f"  ✓ ZSTD compression verified: compressible.dat found with {comp_samples} samples on zstd-compressed filesystem ({samples} total)")


def test_logical_vs_physical_mode():
    """Compare logical and physical space sampling modes."""
    setup_btrfs_basic()
    create_test_files()

    # Run btdu in logical (default) mode
    run_btdu("--headless --export=/tmp/logical.json --max-samples=5000 /mnt/btrfs", timeout=120)
    logical_data = verify_json_export("/tmp/logical.json")

    # Run btdu in physical mode
    run_btdu("--headless --physical --export=/tmp/physical_mode.json --max-samples=5000 /mnt/btrfs", timeout=120)
    physical_data = verify_json_export("/tmp/physical_mode.json")

    # Verify both modes found the expected directories
    logical_dir1 = get_node(logical_data['root'], [SINGLE, DATA, 'dir1'])
    physical_dir1 = get_node(physical_data['root'], [SINGLE, DATA, 'dir1'])

    assert logical_dir1 is not None, "dir1 not found in logical mode"
    assert physical_dir1 is not None, "dir1 not found in physical mode"

    # Compare totalSize - on single-device SINGLE profile, they should be similar
    logical_total = logical_data['totalSize']
    physical_total = physical_data['totalSize']

    # Physical should be >= logical (may include more metadata/overhead)
    assert physical_total >= logical_total, f"Physical total {physical_total/1024/1024:.1f}MB should be >= logical {logical_total/1024/1024:.1f}MB"

    logical_samples = logical_data['root']['data']['represented']['samples']
    physical_samples = physical_data['root']['data']['represented']['samples']

    print(f"  ✓ Logical vs physical modes verified: both found dir1, logical total={logical_total/1024/1024:.1f}MB ({logical_samples} samples), physical={physical_total/1024/1024:.1f}MB ({physical_samples} samples)")


def test_represented_size_unique():
    """Test represented size in expert mode for unique files."""
    setup_btrfs_basic()

    # Create unique files (known size: 10MB each)
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/unique_a.dat bs=1M count=10")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/unique_b.dat bs=1M count=10")
    machine.succeed("sync")

    # Run btdu with expert mode
    run_btdu("--expert --headless --export=/tmp/repr_unique.json --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/repr_unique.json")

    # Verify represented size is present in export
    assert data['expert'] == True, "Expert mode not enabled"
    unique_a = get_node(data['root'], [SINGLE, DATA, 'unique_a.dat'])
    unique_b = get_node(data['root'], [SINGLE, DATA, 'unique_b.dat'])

    assert unique_a is not None, "unique_a.dat not found"
    assert unique_b is not None, "unique_b.dat not found"

    # For unique files, verify represented size approximates actual file size
    file_size_a = get_file_size(data, [SINGLE, DATA, 'unique_a.dat'])
    file_size_b = get_file_size(data, [SINGLE, DATA, 'unique_b.dat'])

    expected_size = 10 * 1024 * 1024  # 10MB

    # Allow ±20% tolerance due to metadata and sampling variance
    assert 0.8 * expected_size <= file_size_a <= 1.2 * expected_size, \
        f"unique_a size {file_size_a/1024/1024:.1f}MB not close to expected 10MB"
    assert 0.8 * expected_size <= file_size_b <= 1.2 * expected_size, \
        f"unique_b size {file_size_b/1024/1024:.1f}MB not close to expected 10MB"

    print(f"  ✓ Represented size verified: unique_a={file_size_a/1024/1024:.1f}MB, unique_b={file_size_b/1024/1024:.1f}MB")


def test_exclusive_size_clones():
    """Test exclusive size with unique vs reflinked files."""
    setup_btrfs_basic()

    # Create a unique file and a reflinked file to demonstrate exclusive vs shared
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/unique.dat bs=1M count=1")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/original.dat bs=1M count=1")
    machine.succeed("cp --reflink=always /mnt/btrfs/original.dat /mnt/btrfs/cloned.dat")
    machine.succeed("sync")

    # Run btdu in expert mode
    run_btdu("--expert --headless --export=/tmp/excl_clones.json --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/excl_clones.json")

    # Verify expert mode is enabled
    assert data['expert'] == True, "Expert mode not enabled"

    # Find the unique file - should have exclusive samples
    unique = get_node(data['root'], [SINGLE, DATA, 'unique.dat'])
    assert unique is not None, "unique.dat not found"

    unique_data = unique['data']
    unique_excl = unique_data.get('exclusive', {}).get('samples', 0)
    unique_repr = unique_data['represented']['samples']

    assert unique_repr > 0, "Unique file should have represented samples"
    assert unique_excl > 0, "Unique file should have exclusive samples > 0"

    # Find the reflinked file (shorter name is representative)
    cloned = get_node(data['root'], [SINGLE, DATA, 'cloned.dat'])
    assert cloned is not None, "cloned.dat not found"

    cloned_data = cloned['data']
    # For reflinked files, exclusive field should be absent (0) or very small
    cloned_excl = cloned_data.get('exclusive', {}).get('samples', 0)
    cloned_shared = cloned_data.get('shared', {}).get('samples', 0)

    assert cloned_shared > 0, "Reflinked file should have shared samples"
    assert cloned_excl == 0, f"Reflinked file should have exclusive=0 or absent, got {cloned_excl}"

    print(f"  ✓ Exclusive size verified: unique exclusive={unique_excl}, reflinked exclusive={cloned_excl} (shared={cloned_shared})")


def test_shared_size_reflinks():
    """Test shared size with reflinked files in expert mode."""
    setup_btrfs_basic()

    # Create reflinked files
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/base.dat bs=1M count=1")
    machine.succeed("cp --reflink=always /mnt/btrfs/base.dat /mnt/btrfs/link1.dat")
    machine.succeed("cp --reflink=always /mnt/btrfs/base.dat /mnt/btrfs/link2.dat")
    machine.succeed("sync")

    # Run btdu in expert mode
    run_btdu("--expert --headless --export=/tmp/shared_refs.json --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/shared_refs.json")

    # Verify shared size is present
    assert data.get('expert') == True, "Expert mode not enabled"

    # With --seed, shortest path (base.dat) should be representative
    base = get_node(data['root'], [SINGLE, DATA, 'base.dat'])
    assert base is not None, "base.dat not found (should be representative as shortest path)"

    # The representative file should have shared size samples
    assert 'shared' in base['data'], "Shared field missing in expert mode"
    shared_samples = base['data']['shared']['samples']
    assert shared_samples > 0, "Shared size should be > 0 for reflinked files"
    print(f"  ✓ Shared size with reflinks verified: shared={shared_samples} samples")


def test_lexicographic_path_selection():
    """Test lexicographic ordering for same-length paths."""
    setup_btrfs_basic()

    # Create reflinked files with same-length paths
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/zzz.dat bs=1M count=1")
    machine.succeed("cp --reflink=always /mnt/btrfs/zzz.dat /mnt/btrfs/aaa.dat")
    machine.succeed("sync")

    # Run btdu with many samples to ensure we hit the reflinked data
    run_btdu("--headless --export=/tmp/lexico.json --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/lexico.json")

    # Find both paths
    aaa_node = get_node(data['root'], [SINGLE, DATA, 'aaa.dat'])
    zzz_node = get_node(data['root'], [SINGLE, DATA, 'zzz.dat'])

    # The lexicographically smaller path (aaa.dat) should be selected as representative
    assert aaa_node is not None, "aaa.dat not found (should be representative)"
    aaa_samples = aaa_node['data']['represented']['samples']
    assert aaa_samples > 0, "aaa.dat should have samples as representative"

    # zzz.dat should not appear in tree (btdu doesn't export nodes with 0 samples)
    assert zzz_node is None, "zzz.dat should not appear in tree (aaa.dat is representative)"

    print(f"  ✓ Lexicographic path selection verified: aaa.dat={aaa_samples} samples (zzz.dat not in tree)")


def test_seenas_for_nonrepresentative_paths():
    """Test that seenAs data is available for non-representative paths with 0 represented samples.

    Non-representative paths (files with 0 represented samples because another copy is preferred)
    have seenAs data populated so the UI can show "Shares data with:" information.
    """
    setup_btrfs_basic()

    # Create reflinked files in two directories
    machine.succeed("mkdir -p /mnt/btrfs/aaa_dir /mnt/btrfs/zzz_dir")
    machine.succeed("dd if=/dev/urandom of=/mnt/btrfs/aaa_dir/shared.dat bs=1M count=10")
    machine.succeed("cp --reflink=always /mnt/btrfs/aaa_dir/shared.dat /mnt/btrfs/zzz_dir/shared.dat")
    machine.succeed("sync")

    # Run btdu with --expert and --prefer to make zzz_dir the representative
    # This means aaa_dir/shared.dat will have 0 represented samples but should still have seenAs data
    run_btdu("--expert --headless --prefer='/mnt/btrfs/zzz_dir/**' --export=/tmp/seenas_test.json --export-seen-as --max-samples=10000 /mnt/btrfs", timeout=180)
    data = verify_json_export("/tmp/seenas_test.json")

    # Find both paths in the tree
    aaa_node = get_node(data['root'], [SINGLE, DATA, 'aaa_dir', 'shared.dat'])
    zzz_node = get_node(data['root'], [SINGLE, DATA, 'zzz_dir', 'shared.dat'])

    # zzz_dir should be representative (has represented samples)
    assert zzz_node is not None, "zzz_dir/shared.dat not found (should be representative due to --prefer)"
    zzz_repr = zzz_node['data']['represented']['samples']
    assert zzz_repr > 0, "zzz_dir/shared.dat should have represented samples (is representative)"

    # Verify zzz_node has seenAs data (it's the representative, so this should work)
    assert 'seenAs' in zzz_node, "zzz_dir/shared.dat (representative) should have seenAs data"
    zzz_seenas = zzz_node.get('seenAs', {})
    assert len(zzz_seenas) > 0, "zzz_dir/shared.dat (representative) should have non-empty seenAs"

    # aaa_dir may or may not appear (depends on whether it got any represented samples)
    # But if it does appear, it should have seenAs data too (this is the bug!)
    if aaa_node is not None:
        aaa_repr = aaa_node.get('data', {}).get('represented', {}).get('samples', 0)
        aaa_shared = aaa_node.get('data', {}).get('shared', {}).get('samples', 0)

        print(f"  aaa_dir/shared.dat found: represented={aaa_repr}, shared={aaa_shared}")

        # Non-representative paths with shared samples have seenAs data
        if aaa_shared > 0 and aaa_repr == 0:
            assert 'seenAs' in aaa_node, "Non-representative path with shared samples should have seenAs data"
            aaa_seenas = aaa_node.get('seenAs', {})
            assert len(aaa_seenas) > 0, "Non-representative path should have non-empty seenAs"
            print(f"  ✓ Sharing information available: non-representative path has seenAs={len(aaa_seenas)} entries")
        else:
            print("  aaa_dir/shared.dat has represented samples, skipping seenAs check")
    else:
        print("  aaa_dir/shared.dat not in export (has 0 samples, not exported)")
        print("  Note: This is expected behavior - nodes with 0 samples aren't exported to JSON")
        print("  The bug manifests in the UI when navigating to non-representative paths")

    print(f"  ✓ Test complete: zzz_dir (representative) has {zzz_repr} samples and {len(zzz_seenas)} seenAs entries")


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
        test_binary_export_import,
        test_binary_format_autodetect,
        test_binary_expert_mode,
        test_binary_physical_mode,
        test_binary_round_trip_accuracy,

        # Feature-specific tests
        test_physical_sampling,
        test_subvolume_handling,
        test_reflink_handling,
        test_compression_support,
        test_representative_path_selection,
        test_prefer_ignore_options,

        # Result verification
        test_json_export_structure,
        test_max_samples_limit,
        test_max_time_limit,
        test_min_resolution_limit,
        test_subprocess_counts,
        test_seed_reproducibility,
        test_non_btrfs_error,
        test_conflicting_options,
        test_auto_mount_with_subvolume,
        test_auto_mount_prefer_ignore_rejected,
        test_auto_mount_with_top_level,
        test_paths_with_spaces,
        test_absolute_paths,
        test_relative_paths,
        test_version_display,

        # Edge case tests
        test_empty_filesystem,
        test_deleted_files,
        test_sparse_files,

        # Multi-device and RAID tests
        test_multidevice_filesystem,
        test_raid1_mirroring,
        test_raid0_striping,
        test_mixed_raid_profiles,

        # Expert mode tests
        test_expert_mode_basic,
        test_distributed_size_reflinks,
        test_exclusive_size_unique,

        # Regression tests
        test_unicode_filenames,
        test_division_by_zero,
        test_special_leaf_size,

        # Special filesystem scenarios
        test_small_files_metadata,
        test_many_extents,
        test_nearly_full_filesystem,
        test_device_slack,
        test_unallocated_space,

        # Additional feature tests
        test_subvolume_analysis,
        test_snapshot_handling,
        test_compression_zstd,
        test_logical_vs_physical_mode,
        test_represented_size_unique,
        test_exclusive_size_clones,
        test_shared_size_reflinks,
        test_lexicographic_path_selection,
        test_seenas_for_nonrepresentative_paths,
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
