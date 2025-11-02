{ lib, pkgs, btdu }:

pkgs.testers.nixosTest {
  name = "btdu-integration";

  meta = with lib.maintainers; {
    maintainers = [ ];
  };

  nodes.machine = { config, pkgs, ... }: {
    # Enable btrfs module
    boot.supportedFilesystems = [ "btrfs" ];

    # Install btdu
    environment.systemPackages = [ btdu ];

    # Create virtual disks for btrfs and ext4 testing
    virtualisation = {
      emptyDiskImages = [ 1024 1024 ]; # 1GB for btrfs/ext4, 1GB for multi-device/RAID
      memorySize = 2048;
    };
  };

  testScript = builtins.readFile ./test_script.py;
}
