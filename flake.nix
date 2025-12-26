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
              # Include build configuration (all dub files)
              (baseName == "dub.sdl") ||
              (baseName == "dub-lock.json") ||
              (baseName == "dub.selections.json");
        };

        # Common btdu build configuration
        btduCommon = {
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

        # Build btdu from local source (release build)
        btdu = pkgs.buildDubPackage btduCommon;

        # Debug build with extra assertions for testing
        btduDebug = pkgs.buildDubPackage (btduCommon // {
          # Use custom "checked" build type defined in dub.sdl
          # This enables debugMode and passes -d-debug=check to enable debug(check) blocks
          dubBuildType = "checked";
        });

        # ============================================================
        # Static build infrastructure (musl-based, no runtime deps)
        # ============================================================

        # LDC source for building runtime (with ARM musl patch applied)
        ldcSrcUnpatched = pkgs.fetchFromGitHub {
          owner = "ldc-developers";
          repo = "ldc";
          tag = "v${pkgs.ldc.version}";
          hash = "sha256-6LcpY3LSFK4KgEiGrFp/LONu5Vr+/+vI04wEEpF3s+s=";
          fetchSubmodules = true;
        };

        # Apply ARM musl patches to LDC source
        # - stat.d: Add stat_t for musl ARM (correct struct size)
        # - types.d: Force 64-bit off_t for musl (LFS by default)
        ldcSrc = pkgs.runCommand "ldc-src-patched-${pkgs.ldc.version}" {
          nativeBuildInputs = [ pkgs.patch ];
        } ''
          cp -r ${ldcSrcUnpatched} $out
          chmod -R u+w $out
          cd $out
          patch -p1 < ${./ci/patches/0001-core.sys.posix.sys.stat-Add-stat_t-definition-for-mu.patch}
          patch -p1 < ${./ci/patches/0004-core.sys.posix.sys.types-Use-64-bit-off_t-for-CRunti.patch}
        '';

        # Fetch dub dependencies for static builds
        dubDeps = pkgs.importDubLock {
          pname = "btdu";
          version = btduCommon.version;
          lock = ./dub-lock.json;
        };

        # Build static btdu for a given cross target
        mkStaticBuild = { crossPkgs, arch }:
          let
            # Use pkgsStatic to get static libraries
            staticPkgs = crossPkgs.pkgsStatic;
            targetTriple = crossPkgs.stdenv.hostPlatform.config;
            crossCC = crossPkgs.stdenv.cc;

            # Musl sysroot for cross-compilation
            muslLibc = staticPkgs.stdenv.cc.libc;

            # Build zlib with Clang LTO for the target
            # Use unwrapped clang to avoid cc-wrapper adding incompatible flags for cross-compilation
            zlibLto = pkgs.stdenv.mkDerivation {
              pname = "zlib-lto-${arch}";
              version = pkgs.zlib.version;
              src = pkgs.zlib.src;

              nativeBuildInputs = [ pkgs.llvmPackages.clang-unwrapped pkgs.lld ];

              configurePhase = ''
                # Use musl headers and disable glibc's FORTIFY_SOURCE
                # Note: -w suppresses all warnings, needed because zlib's configure checks for any stderr output
                export CC="${pkgs.llvmPackages.clang-unwrapped}/bin/clang --target=${targetTriple}"
                export AR="${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar"
                export RANLIB="${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ranlib"
                export CFLAGS="-isystem ${muslLibc.dev}/include -flto=thin -O2 -U_FORTIFY_SOURCE -w"
                export LDFLAGS="-fuse-ld=lld -L${muslLibc}/lib"
                ./configure --static --prefix=$out
              '';

              buildPhase = ''
                make libz.a
              '';

              installPhase = ''
                mkdir -p $out/lib $out/include
                cp libz.a $out/lib/
                cp zlib.h zconf.h $out/include/
              '';
            };

            # Build ncurses with Clang LTO for the target
            # Use unwrapped clang to avoid cc-wrapper adding incompatible flags for cross-compilation
            ncursesLto = pkgs.stdenv.mkDerivation {
              pname = "ncurses-lto-${arch}";
              version = pkgs.ncurses.version;
              src = pkgs.ncurses.src;

              nativeBuildInputs = [ pkgs.llvmPackages.clang-unwrapped pkgs.lld ];

              configurePhase = ''
                # Use musl headers and disable glibc's FORTIFY_SOURCE
                # Must provide both include and library paths for cross-compilation
                export CC="${pkgs.llvmPackages.clang-unwrapped}/bin/clang"
                export CPP="${pkgs.llvmPackages.clang-unwrapped}/bin/clang -E"
                export AR="${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ar"
                export RANLIB="${pkgs.llvmPackages.bintools-unwrapped}/bin/llvm-ranlib"
                export CFLAGS="--target=${targetTriple} -isystem ${muslLibc.dev}/include -flto=thin -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
                export CPPFLAGS="--target=${targetTriple} -isystem ${muslLibc.dev}/include"
                export LDFLAGS="-fuse-ld=lld --target=${targetTriple} -L${muslLibc}/lib -nostdlib ${muslLibc}/lib/crt1.o ${muslLibc}/lib/crti.o -lc ${muslLibc}/lib/crtn.o"

                ./configure \
                  --prefix=$out \
                  --without-shared \
                  --without-debug \
                  --without-ada \
                  --enable-widec \
                  --without-cxx-binding \
                  --without-cxx \
                  --without-progs \
                  --without-tests \
                  --without-manpages \
                  --host=${targetTriple} \
                  --build=${pkgs.stdenv.buildPlatform.config}
              '';

              buildPhase = ''
                make -C include
                make -C ncurses
              '';

              installPhase = ''
                make -C include install
                make -C ncurses install
                # Create libncursesw.a symlink if needed
                if [ -f $out/lib/libncursesw.a ]; then
                  true  # already exists
                elif [ -f $out/lib/libncurses.a ]; then
                  ln -s libncurses.a $out/lib/libncursesw.a
                fi
              '';
            };

            # Build LDC runtime for target
            ldcRuntime = pkgs.runCommand "ldc-runtime-${arch}-${pkgs.ldc.version}" {
              nativeBuildInputs = [
                pkgs.ldc
                pkgs.cmake
                pkgs.ninja
                crossCC
              ];
            } ''
              export CC=${crossCC}/bin/${crossCC.targetPrefix}cc
              export HOME=$TMPDIR

              ${pkgs.ldc}/bin/ldc-build-runtime \
                --ninja \
                --ldcSrcDir=${ldcSrc} \
                --dFlags="-mtriple=${targetTriple};-flto=full;-O;--release" \
                BUILD_SHARED_LIBS=OFF

              mkdir -p $out/lib
              cp -r ldc-build-runtime.tmp/lib/* $out/lib/
            '';
          in pkgs.stdenv.mkDerivation {
            pname = "btdu-static-${arch}";
            version = btduCommon.version;

            src = btduSrc;

            inherit dubDeps;

            nativeBuildInputs = [
              pkgs.ldc
              pkgs.dub
              pkgs.jq
              pkgs.dubSetupHook
              crossCC
              pkgs.lld
              pkgs.patch
            ];

            buildInputs = [
              ncursesLto
              zlibLto
            ];

            dontConfigure = true;

            buildPhase = ''
              echo "Building btdu static for ${targetTriple}"

              # Get import paths from dub (now works with fetched packages)
              importPaths=$(${pkgs.dub}/bin/dub describe | ${pkgs.jq}/bin/jq -r '.targets[] | select(.rootPackage=="btdu") | .buildSettings.importPaths[]')

              importFlags=""
              for path in $importPaths; do
                importFlags="$importFlags -I$path"
              done

              # Use the cross-compiler's gcc wrapper for linking
              # Note: -I for patched druntime must come first to override host LDC's includes
              ${pkgs.ldc}/bin/ldc2 \
                -mtriple ${targetTriple} \
                --gcc=${crossCC}/bin/${crossCC.targetPrefix}cc \
                --linker=lld \
                -i \
                -i=-deimos \
                -of btdu \
                -I${ldcSrc}/runtime/druntime/src \
                -L-L${ldcRuntime}/lib \
                -L-L${ncursesLto}/lib \
                -L-L${zlibLto}/lib \
                -L-L${staticPkgs.stdenv.cc.libc}/lib \
                -L-l:libncursesw.a \
                -L-l:libz.a \
                -L--Map=btdu.map \
                -flto=full \
                -O \
                --release \
                -static \
                $importFlags \
                source/btdu/main

              # Save unstripped binary for analysis, then strip for distribution
              cp btdu btdu.unstripped
              ${crossCC.targetPrefix}strip btdu
            '';

            installPhase = ''
              runHook preInstall
              install -Dm755 btdu -t $out/bin
              install -Dm644 btdu.map -t $out/share
              install -Dm755 btdu.unstripped -t $out/share
              runHook postInstall
            '';

            meta = btduCommon.meta // {
              description = "Sampling disk usage profiler for btrfs (static ${arch} build)";
            };
          };

        # Define static builds for supported architectures
        # ARM musl support requires patched LDC druntime (see ci/patches/)
        staticBuilds = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux (
          pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            btdu-static-x86_64 = mkStaticBuild {
              crossPkgs = pkgs.pkgsCross.musl64;
              arch = "x86_64";
            };
            btdu-static-aarch64 = mkStaticBuild {
              crossPkgs = pkgs.pkgsCross.aarch64-multiplatform-musl;
              arch = "aarch64";
            };
            btdu-static-armv6l = mkStaticBuild {
              crossPkgs = pkgs.pkgsCross.muslpi;
              arch = "armv6l";
            };
          }
        );

      in
      {
        packages = {
          default = btdu;
          btdu = btdu;
          btdu-debug = btduDebug;
        } // staticBuilds;

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
        # Uses btduDebug build with -debug=check for extra assertions
        checks = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          integration = import ./ci/tests/nixos-test.nix {
            inherit (pkgs) lib;
            inherit pkgs;
            btdu = btduDebug;
          };
        };
      }
    );
}
