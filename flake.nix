{
  description = "the AVIF image tools (avifenc / avifdec) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # libavif's programs (avifenc, avifdec, avifgainmaputil) are built from
  # nixpkgs' libavif with its apps on and folded into one `avif` binary.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # libavif with the apps on, over a static pkgs scope. libyuv everywhere
      # and dav1d on darwin take nix-lib's fixes.
      mkAvifApps = scope:
        let
          lib = scope.lib;
          host = scope.stdenv.hostPlatform;
          p = scope.extend (final: prev:
            {
              libyuv = ulib.nativeFixes.libyuv prev;
            } // lib.optionalAttrs (!host.isMinGW) {
              # Base on the shared nix-lib fix, not raw nixpkgs: on darwin it
              # patches merge_static_libs.cmake's `if(APPLE)` branch, which
              # hardcodes `xcrun libtool -static` — absent from the engine's
              # darwin toolchain (`xcrun: command not found`, exit 127). Our
              # overrideAttrs below replaces its cmakeFlags (apps back ON) but
              # CONCATENATES postPatch, so the patch rides along. chafa consumes
              # libavif the same way; the overlay is not auto-wired, so a
              # consumer that names `prev.libavif` gets the unpatched one.
              libavif = ulib.nativeFixes.libavif prev;
            } // lib.optionalAttrs host.isDarwin {
              dav1d = ulib.nativeFixes.dav1d prev;
            });
          # Inputs the programs do not use: gdk-pixbuf (the loader module, off),
          # gtest where the suite does not run, and on mingw
          # make-shell-wrapper-hook (spliced to a mingw bash that cannot
          # cross-compile). Only mingw filters nativeBuildInputs, so the other
          # targets keep nixpkgs' list there.
          dropApps = lib.filter
            (x: !(builtins.elem (x.pname or x.name or "")
              ([ "gdk-pixbuf" "make-shell-wrapper-hook" ]
               ++ lib.optional (!runTests) "gtest")));
          # libavif's gtest suite, where the build can run it.
          runTests = scope.stdenv.buildPlatform.canExecute host;
        in
        p.libavif.overrideAttrs (old: {
          pname = "avif-apps";
          # pandoc renders upstream's avifenc.1/avifdec.1 (AVIF_BUILD_MAN_PAGES).
          nativeBuildInputs =
            (if host.isMinGW then dropApps (old.nativeBuildInputs or [ ])
             else (old.nativeBuildInputs or [ ]))
            ++ [ scope.buildPackages.pandoc ];
          # darwin: libxml2.a (gain-map path) calls iconv, which lives in a
          # separate static libiconv (musl folds it into libc → Linux needs
          # nothing). nix-lib's withDarwinIconv prepends pkgsStatic.libiconv to
          # buildInputs and appends -liconv on every darwin build, so the linker
          # resolves it static (no /usr/lib/libiconv.2.dylib load command) with
          # no per-package wiring here.
          buildInputs = dropApps (old.buildInputs or [ ])
            # mingw: aom.pc `Requires: libvmaf`, and libvmaf.a calls
            # pthread_mutex_*; the cmake apps link then needs winpthreads on the
            # path (`-lpthread`). Adding it lets Findaom.cmake's find_library
            # loop resolve pthread into aom's INTERFACE link, after libvmaf.a.
            ++ lib.optionals host.isMinGW [ p.windows.pthreads ];
          propagatedBuildInputs = dropApps (old.propagatedBuildInputs or [ ]);
          patches = (old.patches or [ ]) ++ [ ./findaom-skip-missing-libs.patch ]
            ++ lib.optional host.isMinGW ./mingw-apps-bcrypt.patch;
          cmakeFlags = [
            "-DBUILD_SHARED_LIBS=OFF"
            "-DAVIF_CODEC_AOM=SYSTEM"      # encoder (avifenc)
            "-DAVIF_CODEC_DAV1D=SYSTEM"    # decoder (avifdec)
            "-DAVIF_BUILD_APPS=ON"
            "-DAVIF_BUILD_MAN_PAGES=ON"
            "-DAVIF_BUILD_GDK_PIXBUF=OFF"
            "-DAVIF_LIBSHARPYUV=SYSTEM"
            # libxml2 enables avifenc's gain-map-from-JPEG conversion and is
            # required by avifgainmaputil (the HDR gain-map tool, shipped as the
            # third applet). Its iconv on darwin: see above.
            "-DAVIF_LIBXML2=SYSTEM"
          ] ++ (if runTests
                then [ "-DAVIF_BUILD_TESTS=ON" "-DAVIF_GTEST=SYSTEM" ]
                else [ "-DAVIF_BUILD_TESTS=OFF" ]);
          doCheck = runTests;
          # The loader-cache + thumbnailer wrapper postInstall is meaningless
          # without the gdk-pixbuf module; the apps install themselves via the
          # cmake install rule.
          postInstall = "";
          # Static-only drops libavif's install(EXPORT) (it rides the shared
          # target), so nixpkgs' postFixup _IMPORT_PREFIX rewrite hits a missing
          # libavif-config.cmake and aborts. Guard it.
          postFixup = ''
            cfg="$dev/lib/cmake/libavif/libavif-config.cmake"
            if [ -f "$cfg" ]; then
              substituteInPlace "$cfg" \
                --replace-quiet "_IMPORT_PREFIX \"$out\"" "_IMPORT_PREFIX \"$dev\""
            fi
          '';
        });

    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "avif";
      # There is no `avif` in nixpkgs; the programs live in `libavif`.
      pkgsAttr = "libavif";
      # A program is selected with --unpin-program=; the bare binary prints the
      # list. The pattern names the codecs on purpose -- a libavif linked
      # against no codec at all still prints "Version: 1.4.1 ()" and would pass
      # a bare "Version:", while this package is the codec chain. avifenc's
      # banner reports what is actually compiled in.
      smoke = [ "--unpin-program=avifenc" "--version" ];
      smokePattern = "Version: .*dav1d \\[dec\\]:.*aom \\[enc/dec\\]:";

      # The engine builds libavif and its C++ codec libs (libaom, libyuv)
      # against its own libc++, Windows included; avifgainmaputil's main is
      # C++ too, hence requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        windows = true;
        programs = [
          { name = "avifenc"; }
          { name = "avifdec"; }
          # Upstream writes no page for it; `--help` is the whole doc.
          { name = "avifgainmaputil"; noMan = true; }
        ];
        requires.cxx = true;
      };

      # Linux AND darwin go through the engine self-fold. requires.cxx folds
      # libc++ statically, which also settles the /usr/lib/libc++.1.dylib the
      # darwin allowlist rejects.
      build = pkgs: mkAvifApps pkgs.pkgsStatic;

      windowsBuild = pkgs: mkAvifApps (ulib.mingwStaticCross pkgs);
    };
}
