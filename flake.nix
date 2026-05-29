{
  description = "Standalone build of the AVIF image tools (avifenc / avifdec)";

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
      # vanilla under pkgsStatic) everywhere; libjpeg-turbo on riscv (RVV SIMD
      # helper miscompiles, pulled via the JPEG reader); dav1d on darwin (meson
      # cpu_family='arm64' literal). Each is identity off its gate, so the
      # other targets keep the cache-hit lib. aom (the encoder) needs no fix —
      # chafa already cross-built it on every target via libavif's SYSTEM codec.
      mkAvifApps = scope:
        let
          lib = scope.lib;
          host = scope.stdenv.hostPlatform;
          p = scope.extend (final: prev:
            {
              libyuv = ulib.nativeFixes.libyuv prev;
            } // lib.optionalAttrs host.isRiscV {
              libjpeg = ulib.nativeFixes."libjpeg-turbo" prev;
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
          # does NOT put on the link: darwin's separate static iconv; mingw's
          # BCryptGenRandom (bcrypt, used for libxml2's hash randomization).
          # musl folds iconv into libc and has getrandom, so Linux needs nothing.
          xmlExtraLibs =
            if host.isDarwin then "-liconv"
            else if host.isMinGW then "-lbcrypt"
            else "";
        in
        p.libavif.overrideAttrs (old: {
          pname = "avif-apps";
          nativeBuildInputs =
            if host.isMinGW then dropApps (old.nativeBuildInputs or [ ])
            else (old.nativeBuildInputs or [ ]);
          # darwin: libxml2.a (gain-map path) calls iconv, which lives in a
          # separate static libiconv (musl folds it into libc → Linux needs
          # nothing). Prepend pkgsStatic.libiconv so the linker sees libiconv.a
          # ahead of the SDK's libiconv.tbd — `-liconv` then resolves static and
          # emits no /usr/lib/libiconv.2.dylib load command (same lever as the
          # unpin CLI; the explicit `-liconv` is injected in postPatch below).
          buildInputs = lib.optional host.isDarwin p.libiconv
            ++ dropApps (old.buildInputs or [ ])
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
          ({ pkgs = scope; libavifApps = mkAvifApps scope; } // extra);
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "avif";
      # Multicall: `avif <applet> [args]` dispatches by argv[0]; the bare
      # binary takes the applet as its first arg. Smoke through that form.
      smoke = [ "avifenc" "--version" ];
      smokePattern = "Version:";

      # Linux pkgsStatic links libstdc++ statically already. darwin: the C++
      # codec libs (aom/libyuv) pull `-lc++` → /usr/lib/libc++.1.dylib, which
      # the unpins darwin allowlist rejects; fold libc++ in statically (same
      # branch as vpx/srt/x265/chafa). (libxml2.a's iconv dep is folded into the
      # cmake app link itself — see the -liconv injection in mkAvifApps — so it
      # rides the reused link.txt and needs nothing here.)
      build = pkgs:
        let sp = pkgs.pkgsStatic; in
        mk pkgs sp (pkgs.lib.optionalAttrs sp.stdenv.hostPlatform.isDarwin {
          extraLinkFlags = "-nostdlib++ ${sp.libcxx}/lib/libc++.a ${sp.libcxx}/lib/libc++abi.a";
        });

      # mingw cross: -all-static folds the C++/thread runtime into the .exe so
      # no libstdc++-6 / libgcc_s / libwinpthread DLLs ride alongside.
      windowsBuild = pkgs:
        let cross = ulib.mingwStaticCross pkgs; in
        mk pkgs cross {
          extraLinkFlags = "-static -static-libgcc -static-libstdc++";
        };
    };
}
