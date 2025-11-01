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

    # Create a virtual disk for btrfs
    virtualisation = {
      emptyDiskImages = [ 4096 ]; # 4GB disk
      memorySize = 2048;
    };
  };

  testScript = builtins.readFile ./test_script.py;
}
