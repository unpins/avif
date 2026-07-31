{
  description = "the AVIF image tools (avifenc / avifdec) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # libavif ships its CLI tools (avifenc / avifdec / avifgainmaputil) as
  # "apps". The shared nix-lib overlay used by chafa builds the library
  # decode-only (apps off — chafa just wants libavif.a to read AVIF); here we
  # turn the apps back on, keep the aom encoder, and post-link all three into a
  # single `avif` binary (multicall.nix). The image-codec chain
  # (libyuv/aom/dav1d/sharpyuv + png/jpeg/zlib/webp/xml2) is the SAME one chafa
  # proved across all nine targets, so the deps are cache hits.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # libavif with apps ON, wired onto a (static) pkgs scope. Codec-chain
      # fixes are a subset of chafa's: libyuv (drops its SHARED target, fails
      # vanilla under pkgsStatic) everywhere; dav1d on darwin (meson
      # cpu_family='arm64' literal). Each is identity off its gate, so the
      # other targets keep the cache-hit lib. aom (the encoder) needs no fix —
      # chafa already cross-built it on every target via libavif's SYSTEM codec.
      # `eng` (engine path only): the unpin-llvm adapter stdenv.
      # On the engine we must defeat the tier-2 wall: libavif's apps link the
      # SYSTEM codec libs, two of which carry C++ (libaom: rate control;
      # libyuv: .cc) built with gcc/libstdc++, which can't resolve against the
      # engine's libc++. Rebuild THOSE two with the engine so their C++ becomes
      # libc++, matching libavif. All of them take the LTO stdenv: nasm/asm
      # objects simply stay native inside an otherwise-bitcode archive, and the
      # mega link reads mixed archives fine. The pure-C codec/image libs
      # (dav1d/sharpyuv/webp/png/zlib/jpeg/xml2) stay gcc: C ABI links cleanly
      # into a libc++ binary, no rebuild needed.
      mkAvifApps = eng: scope:
        let
          lib = scope.lib;
          host = scope.stdenv.hostPlatform;
          p = scope.extend (final: prev:
            {
              libyuv =
                let base = ulib.nativeFixes.libyuv prev;
                in if eng != null then base.override { stdenv = eng.lto; } else base;
            } // lib.optionalAttrs (eng != null) {
              # Base on the shared nix-lib fix, not raw nixpkgs: on darwin it
              # patches merge_static_libs.cmake's `if(APPLE)` branch, which
              # hardcodes `xcrun libtool -static` — absent from the engine's
              # darwin toolchain (`xcrun: command not found`, exit 127). Our
              # overrideAttrs below replaces its cmakeFlags (apps back ON) but
              # CONCATENATES postPatch, so the patch rides along. chafa consumes
              # libavif the same way; the overlay is not auto-wired, so a
              # consumer that names `prev.libavif` gets the unpatched one.
              libavif = (ulib.nativeFixes.libavif prev).override { stdenv = eng.lto; };
              # Engine-rebuilt libaom: avif only consumes libaom.a, but nixpkgs'
              # libaom also builds aom's OWN example CLIs (aomenc/aomdec) — which
              # link libvmaf, an external gcc/libstdc++ lib that can't resolve
              # against the engine's libc++ (the std::basic_filebuf wall). Just
              # disable the optional VMAF tuning so those example links (and
              # libaom.a itself) carry no libvmaf reference; keep ENABLE_EXAMPLES
              # so nixpkgs' `bin` output stays populated (disabling them would
              # leave `bin` empty → "failed to produce output path").
              libaom = (prev.libaom.override { stdenv = eng.lto; }).overrideAttrs (o: {
                cmakeFlags = (o.cmakeFlags or [ ]) ++ [
                  "-DENABLE_TESTS=OFF"
                  "-DCONFIG_TUNE_VMAF=0"
                ];
              });
              # NB: libavif's gain-map path links libxml2.a, which bakes its
              # default catalog path (…-libxml2/etc/xml/catalog) into a .data
              # string → one retained runtime store-ref. It is benign (a fallback
              # string; the binary runs fine and XML_CATALOG_FILES overrides it)
              # and PRE-EXISTING (the off-engine avif links the same libxml2).
              # Do NOT try to drop it by rebuilding libxml2 --without-catalog in
              # this scope: the overlay propagates to the build-time docbook
              # toolchain (asciidoc/a2x), which NEEDS XML catalogs, breaking it
              # and rebuilding the world. Left as-is, matching upstream.
            } // lib.optionalAttrs host.isDarwin {
              dav1d = ulib.nativeFixes.dav1d prev;
            });
          # nixpkgs' libavif pulls gdk-pixbuf (the loader module we disable),
          # gtest (tests, off) and — on mingw — make-shell-wrapper-hook (spliced
          # to a mingw bash that can't cross-compile: `unknown type name
          # 'sigset_t'`). None are needed for the apps, so drop them. gdk-pixbuf
          # also transitively drags libtiff whose static CMake export breaks
          # find_package(TIFF). Gated drops keep native/darwin cache hits.
          dropApps = lib.filter
            (x: !(builtins.elem (x.pname or x.name or "")
              [ "gdk-pixbuf" "gtest" "make-shell-wrapper-hook" ]));
          # Libs libxml2.a (gain-map path) pulls in that find_package(LibXml2)
          # does NOT put on the link: mingw's BCryptGenRandom (bcrypt, used for
          # libxml2's hash randomization). musl folds iconv into libc and has
          # getrandom, so Linux needs nothing; darwin's separate static iconv is
          # supplied automatically by nix-lib's withDarwinIconv (-liconv on
          # NIX_LDFLAGS + pkgsStatic.libiconv), appended after libxml2.a.
          xmlExtraLibs =
            if host.isMinGW then "-lbcrypt"
            else "";
        in
        p.libavif.overrideAttrs (old: {
          pname = "avif-apps";
          nativeBuildInputs =
            if host.isMinGW then dropApps (old.nativeBuildInputs or [ ])
            else (old.nativeBuildInputs or [ ]);
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
          postPatch = (old.postPatch or "") + ''
            # Findaom.cmake reflects aom.pc's `Libs.private: -lm` into a
            # find_library(_aom_dep_lib_m m). On mingw there is no standalone
            # libm (math lives in the C runtime), so the lookup yields the
            # literal `_aom_dep_lib_m-NOTFOUND` and the apps try to link
            # `-l_aom_dep_lib_m-NOTFOUND`. Guard the interface-link on a
            # successful find (no-op on platforms where libm exists).
            substituteInPlace cmake/Modules/Findaom.cmake \
              --replace-fail 'target_link_libraries(aom INTERFACE ''${_aom_dep_lib_''${_lib}})' \
                             'if(_aom_dep_lib_''${_lib})
            target_link_libraries(aom INTERFACE ''${_aom_dep_lib_''${_lib}})
        endif()'
          '' + lib.optionalString (xmlExtraLibs != "") ''
            # Append libxml2.a's extra deps after LibXml2 in avif_apps' link so
            # they propagate to every app that pulls libxml2.a (darwin: -liconv
            # binds static via pkgsStatic.libiconv on buildInputs, no dylib load;
            # mingw: -lbcrypt resolves BCryptGenRandom from the win32 sysroot).
            substituteInPlace CMakeLists.txt \
              --replace-fail 'target_link_libraries(avif_apps''${suffix} PRIVATE LibXml2::LibXml2)' \
                             'target_link_libraries(avif_apps''${suffix} PRIVATE LibXml2::LibXml2 ${xmlExtraLibs})'
          '';
          cmakeFlags = [
            "-DBUILD_SHARED_LIBS=OFF"
            "-DAVIF_CODEC_AOM=SYSTEM"      # encoder (avifenc)
            "-DAVIF_CODEC_DAV1D=SYSTEM"    # decoder (avifdec)
            "-DAVIF_BUILD_APPS=ON"
            "-DAVIF_BUILD_GDK_PIXBUF=OFF"
            "-DAVIF_LIBSHARPYUV=SYSTEM"
            # libxml2 enables avifenc's gain-map-from-JPEG conversion and is
            # required by avifgainmaputil (the HDR gain-map tool, shipped as the
            # third applet). libxml2.a references iconv; on darwin that is folded
            # in via -liconv (see postPatch + buildInputs above).
            "-DAVIF_LIBXML2=SYSTEM"
            "-DAVIF_BUILD_TESTS=OFF"
          ];
          doCheck = false;
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

      mk = pkgs: scope: extra:
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          ({ pkgs = scope; libavifApps = mkAvifApps null scope; } // extra);

      # Engine path (native Linux): build the two C++ codec libs + libavif with
      # the unpin-llvm adapter so the whole link is libc++, full-LTO throughout.
      engStdenvs = pkgs:
        let sp = pkgs.pkgsStatic;
        in {
          lto = ulib.unpinAdapterStdenv {
            inherit pkgs;
            target = sp.stdenv.hostPlatform.config;
            native = pkgs.stdenv.buildPlatform.system == pkgs.stdenv.hostPlatform.system;
            cxx = true;
            lto = true;
            captureLinks = true;
          };
        };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "avif";
      # gc (function/data-sections + --gc-sections, on by default in nix-lib)
      # needs pkgsAttr = the real lib so the overlay rebuilds it + the codec
      # chain (aom/dav1d/libyuv) with section granularity; the multicall link
      # then prunes the dead paths the three tools can't reach.
      pkgsAttr = "libavif";
      # Multicall: `avif <applet> [args]` dispatches by argv[0]; the bare
      # binary takes the applet as its first arg. Smoke through that form.
      smoke = [ "--unpin-program=avifenc" "--version" ];
      smokePattern = "Version:";

      # Engine + bitcode self-fold (native Linux): libavif (apps on) compiles to
      # bitcode and avifenc/avifdec/avifgainmaputil self-fold into one `avif`.
      # The C++ comes from libavif (engine→libc++) AND the SYSTEM codec libs
      # libaom/libyuv (rebuilt with the engine → libc++); avifgainmaputil's main
      # is C++ → requires.cxx. darwin/windows keep the objcopy fold below.
      engine = "unpin-llvm";
      multicall = {
        programs = [
          { name = "avifenc"; }
          { name = "avifdec"; }
          { name = "avifgainmaputil"; }
        ];
        requires.cxx = true;
      };

      # Linux AND darwin go through the engine self-fold. darwin used to take
      # multicall.nix, but the engine reaches darwin too, so its objects are
      # bitcode and the fold's `llvm-objcopy --redefine-sym` cannot read them
      # ("not recognized as a valid object file"). requires.cxx folds libc++
      # statically, which also settles the /usr/lib/libc++.1.dylib the darwin
      # allowlist rejects. (libxml2.a's iconv dep is folded into the cmake app
      # link itself — see the -liconv injection in mkAvifApps.)
      build = pkgs: mkAvifApps (engStdenvs pkgs) pkgs.pkgsStatic;

      # mingw cross: -all-static folds the C++/thread runtime into the .exe so
      # no libstdc++-6 / libgcc_s / libwinpthread DLLs ride alongside.
      windowsBuild = pkgs:
        let cross = ulib.mingwStaticCross pkgs; in
        mk pkgs cross {
          extraLinkFlags = "-static -static-libgcc -static-libstdc++";
        };
    };
}
