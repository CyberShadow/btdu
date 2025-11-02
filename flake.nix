{
  description = "btdu - sampling disk usage profiler for btrfs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Filter source to only include files needed for building
        # This prevents rebuilds when test files or docs change
        btduSrc = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let
              baseName = baseNameOf path;
              relPath = pkgs.lib.removePrefix (toString ./. + "/") (toString path);
            in
              # Include source directory and all its contents
              (relPath == "source" || pkgs.lib.hasPrefix "source/" relPath) ||
              # Include build configuration
              (baseName == "dub.sdl");
        };

        # Build btdu from local source
        btdu = pkgs.buildDubPackage {
          pname = "btdu";
          version = "0.6.1";

          src = btduSrc;

          dubLock = ./dub-lock.json;

          buildInputs = with pkgs; [
            ncurses
            zlib
          ];

          installPhase = ''
            runHook preInstall
            install -Dm755 btdu -t $out/bin
            # Generate man page from btdu itself
            ./btdu --man "" > btdu.1
            install -Dm644 btdu.1 -t $out/share/man/man1
            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Sampling disk usage profiler for btrfs";
            homepage = "https://github.com/CyberShadow/btdu";
            license = licenses.gpl2Only;
            platforms = platforms.linux;
            mainProgram = "btdu";
          };
        };
      in
      {
        packages = {
          default = btdu;
          btdu = btdu;
        };

        apps.default = {
          type = "app";
          program = "${btdu}/bin/btdu";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            dmd
            dub
            ncurses
            zlib
          ];
        };

        # Integration tests as checks (only on Linux systems)
        checks = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          integration = import ./ci/tests/nixos-test.nix {
            inherit (pkgs) lib;
            inherit pkgs;
            inherit btdu;
          };
        };
      }
    );
}
