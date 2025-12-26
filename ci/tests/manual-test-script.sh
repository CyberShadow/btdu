#!/usr/bin/env bash
# Manual testing script for btdu
# Creates an isolated btrfs filesystem with various test scenarios

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

set -eEuo pipefail

if [[ ! -v BTDU_IN_UNSHARE ]] ; then

    echo -e "${BLUE}Building btdu...${NC}"
    dub build --build=checked

    echo -e "${BLUE}Entering mount namespace...${NC}"

    # Use unshare to create a private mount namespace
    # This allows us to create mounts that will be automatically cleaned up when btdu exits
    sudo env BTDU_IN_UNSHARE=1 unshare --mount "$0" "$@"
fi

echo -e "${BLUE}Creating isolated filesystem environment...${NC}"

# Create a working directory for our test filesystem
mkdir -p /tmp/btdu-test
mount -t tmpfs -o size=2G tmpfs /tmp/btdu-test

echo "Creating 1.5GB filesystem image..."
dd if=/dev/zero of=/tmp/btdu-test/fs.img bs=1M count=1536 status=progress

echo "Setting up loopback device..."
LOOP_DEV=$(losetup -f --show /tmp/btdu-test/fs.img)

# Ensure cleanup on script exit
cleanup() {
    echo "Cleaning up..."
    sync || true
    umount /mnt/btdu-test 2>/dev/null || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
}
trap cleanup EXIT

echo "Formatting as btrfs..."
mkfs.btrfs -f "$LOOP_DEV" >/dev/null

echo "Mounting filesystem..."
mkdir -p /mnt/btdu-test
mount "$LOOP_DEV" /mnt/btdu-test

echo "Creating test files and scenarios..."

# 1. Basic directory structure with various file sizes
echo "  - Creating basic files..."
mkdir -p /mnt/btdu-test/documents
mkdir -p /mnt/btdu-test/media/photos
mkdir -p /mnt/btdu-test/code/src

dd if=/dev/urandom of=/mnt/btdu-test/documents/report.pdf bs=1M count=5 2>/dev/null
dd if=/dev/urandom of=/mnt/btdu-test/documents/spreadsheet.xlsx bs=1M count=2 2>/dev/null
dd if=/dev/urandom of=/mnt/btdu-test/media/photos/vacation.jpg bs=1M count=3 2>/dev/null
dd if=/dev/urandom of=/mnt/btdu-test/code/src/main.cpp bs=512K count=1 2>/dev/null

# 2. Reflinked (CoW cloned) files - demonstrates sharing
echo "  - Creating reflinked files (shared extents)..."
dd if=/dev/urandom of=/mnt/btdu-test/original.bin bs=1M count=10 2>/dev/null
cp --reflink=always --sparse=auto /mnt/btdu-test/original.bin /mnt/btdu-test/clone1.bin
cp --reflink=always --sparse=auto /mnt/btdu-test/original.bin /mnt/btdu-test/clone2.bin
cp --reflink=always --sparse=auto /mnt/btdu-test/original.bin /mnt/btdu-test/media/clone3.bin

# 3. Enable compression and create compressible data
echo "  - Enabling compression and creating compressible files..."
mount -o remount,compress=zstd /mnt/btdu-test
dd if=/dev/zero of=/mnt/btdu-test/zeros.dat bs=1M count=20 2>/dev/null
dd if=/dev/urandom of=/mnt/btdu-test/random.dat bs=1M count=20 2>/dev/null

# 4. Subvolumes
echo "  - Creating subvolumes..."
btrfs subvolume create /mnt/btdu-test/home >/dev/null
btrfs subvolume create /mnt/btdu-test/backups >/dev/null

dd if=/dev/urandom of=/mnt/btdu-test/home/user_data.db bs=1M count=15 2>/dev/null
dd if=/dev/urandom of=/mnt/btdu-test/backups/backup_2024.tar bs=1M count=25 2>/dev/null

# 5. Snapshots - demonstrate snapshot sharing
echo "  - Creating snapshots..."
btrfs subvolume snapshot /mnt/btdu-test/home /mnt/btdu-test/home-snapshot-2024-01 >/dev/null
btrfs subvolume snapshot /mnt/btdu-test/home /mnt/btdu-test/home-snapshot-2024-02 >/dev/null

# Modify the original after snapshot to create some unique data
dd if=/dev/urandom of=/mnt/btdu-test/home/new_file.dat bs=1M count=5 2>/dev/null

# 5b. Subvolumes that cannot be deleted (for testing deletion error handling)
echo "  - Creating undeletable subvolumes..."
# Nested subvolume - parent can't be deleted while child exists
btrfs subvolume create /mnt/btdu-test/undeletable-parent >/dev/null
btrfs subvolume create /mnt/btdu-test/undeletable-parent/nested-child >/dev/null
dd if=/dev/urandom of=/mnt/btdu-test/undeletable-parent/parent-data.dat bs=1M count=2 2>/dev/null
dd if=/dev/urandom of=/mnt/btdu-test/undeletable-parent/nested-child/child-data.dat bs=1M count=2 2>/dev/null

# 6. Sparse files
echo "  - Creating sparse files..."
dd if=/dev/urandom of=/mnt/btdu-test/sparse.dat bs=1M count=1 2>/dev/null
dd if=/dev/zero of=/mnt/btdu-test/sparse.dat bs=1M count=0 seek=1000 conv=notrunc 2>/dev/null

# 7. Fragmented file with many extents
echo "  - Creating fragmented file..."
fallocate -l 50M /mnt/btdu-test/fragmented.dat
for i in {0..99}; do
    dd if=/dev/urandom of=/mnt/btdu-test/fragmented.dat bs=4K count=1 seek=$((i*125)) conv=notrunc 2>/dev/null
done

# 8. Small files (stored inline with metadata)
echo "  - Creating many small files..."
mkdir -p /mnt/btdu-test/config
for i in {1..50}; do
    dd if=/dev/urandom of=/mnt/btdu-test/config/setting$i.conf bs=100 count=1 2>/dev/null
done

# 9. Files with spaces and special characters
echo "  - Creating files with special names..."
mkdir -p "/mnt/btdu-test/My Documents/Project Files"
dd if=/dev/urandom of="/mnt/btdu-test/My Documents/Important Report.pdf" bs=1M count=3 2>/dev/null
dd if=/dev/urandom of="/mnt/btdu-test/My Documents/Project Files/Code Review.txt" bs=512K count=1 2>/dev/null

# 10. Unicode filenames
echo "  - Creating files with Unicode names..."
dd if=/dev/urandom of="/mnt/btdu-test/café_français.dat" bs=1M count=2 2>/dev/null
dd if=/dev/urandom of="/mnt/btdu-test/文件_chinese.dat" bs=1M count=2 2>/dev/null
dd if=/dev/urandom of="/mnt/btdu-test/test_🎉_emoji.dat" bs=1M count=2 2>/dev/null

# 11. Create and delete a file to demonstrate UNUSED space
echo "  - Creating unused space..."
dd if=/dev/urandom of=/mnt/btdu-test/to_be_deleted.dat bs=1M count=30 2>/dev/null
sync -f /mnt/btdu-test
rm /mnt/btdu-test/to_be_deleted.dat

# 12. Partial extent sharing (overwrite part of a reflinked file)
echo "  - Creating partial extent sharing..."
dd if=/dev/urandom of=/mnt/btdu-test/base_file.dat bs=1M count=10 2>/dev/null
cp --reflink=always --sparse=auto /mnt/btdu-test/base_file.dat /mnt/btdu-test/partial_clone.dat
# Overwrite the middle of the clone, creating a mix of shared and unique extents
dd if=/dev/urandom of=/mnt/btdu-test/partial_clone.dat bs=1M count=3 seek=3 conv=notrunc 2>/dev/null

# 13. Deeply nested file (for testing path wrapping in UI)
echo "  - Creating deeply nested file..."
DEEP_PATH="/mnt/btdu-test/very/deeply/nested/directory/structure/that/goes/on/and/on/for/quite/a/while/to/test/path/wrapping/in/dialogs"
mkdir -p "$DEEP_PATH"
dd if=/dev/urandom of="$DEEP_PATH/important_data.bin" bs=1M count=3 2>/dev/null

# Final sync
sync -f /mnt/btdu-test

echo -e "\n${GREEN}Test filesystem ready!${NC}"
echo "Location: /mnt/btdu-test"
echo "Device: $LOOP_DEV"
echo ""
echo "Test scenarios created:"
echo "  • Basic files in various directories"
echo "  • Reflinked files (4 copies of original.bin sharing data)"
echo "  • Compressed files (zeros.dat compresses well, random.dat does not)"
echo "  • Subvolumes (home, backups)"
echo "  • Undeletable subvolume (undeletable-parent with nested-child)"
echo "  • Snapshots (2 snapshots of home subvolume)"
echo "  • Sparse file (1GB logical, ~1MB physical)"
echo "  • Fragmented file (~100 extents)"
echo "  • Many small files (50 tiny config files)"
echo "  • Files with spaces and special characters"
echo "  • Unicode filenames (emoji, Chinese, French)"
echo "  • Deleted file space (UNUSED)"
echo "  • Partial extent sharing (partial_clone.dat)"
echo "  • Deeply nested file (for path wrapping tests)"
echo ""
echo -e "${BLUE}Starting btdu...${NC}"
echo ""

# Execute btdu with sudo, passing through all script arguments
# Using exec ensures the namespace dies when btdu exits, cleaning up everything
exec ./btdu "$@" /mnt/btdu-test
