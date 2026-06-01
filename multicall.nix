# libavif builds three CLI tools — avifenc, avifdec and avifgainmaputil — as
# "apps". To honour the unpins one-pkg-one-bin rule we post-link them into a
# single multicall binary at $out/bin/avif; `lib.withAliases` then embeds the
# tool names as an UNPIN_META block so unpin's installer can recreate the
# argv[0] shims.
#
# Link mechanics (vs libvpx/recursive-make, srt/CMake-query, rtmpdump/Makefile):
#
#   * libavif uses the CMake "Unix Makefiles" generator (no ninja in
#     nativeBuildInputs), so every target gets a `CMakeFiles/<t>.dir/link.txt`
#     holding its exact link command — compiler, flags, object, and the full
#     codec/image lib list (avif_apps.a, libavif.a, aom, dav1d, libyuv,
#     sharpyuv, png, jpeg, zlib, webp, xml2, libargparse, …) resolved correctly
#     for the platform. avifgainmaputil's link.txt is the superset (it pulls
#     libargparse + the gain-map/xml2 path the other two don't), so we reuse IT
#     as the template and splice in avifenc's + avifdec's main objects + the
#     dispatcher, retargeting the output. That sidesteps re-deriving the
#     per-platform lib list by hand (the e2fsprogs landmine).
#
#   * The shared app helpers (avifutil/avifjpeg/avifpng/y4m/…) live in a single
#     static archive (avif_apps.a) that all three tools link, so they are pulled
#     on-demand from the archive — NOT duplicated as loose objects. The only
#     symbol the spliced mains share with each other / the template is `main`
#     (renamed per-tool up front); the iterative pass below renames any further
#     strong clash in the spliced (non-template) objects only.
#
#   * the tools link the vendored libyuv (C++) and pull aom (C++), so the
#     link is C++ — link.txt already drives g++/clang++. On darwin clang++
#     would resolve -lc++ to /usr/lib/libc++.1.dylib (forbidden by the
#     single-binary policy); `extraLinkFlags` folds the static libc++ in. On
#     mingw `-static -static-libgcc -static-libstdc++` keeps the runtime out of
#     companion DLLs.
{ lib }:
{ pkgs, libavifApps, name ? "avif", extraLinkFlags ? "" }:
let
  multicall = libavifApps.overrideAttrs (old: {
    pname = "avif-multi";

    # Ship only the multicall binary.
    outputs = [ "out" ];
    separateDebugInfo = false;
    postInstall = "";

    postBuild = (old.postBuild or "") + ''
      mkdir -p multicall

      # CMake names compiled objects `.c.o` on ELF/Mach-O but `.c.obj` when
      # targeting Windows (mingw). Detect which this build produced.
      oext=o
      [ -n "$(find . -path '*avifenc.dir/apps/avifenc.c.obj' -print -quit)" ] && oext=obj

      # Each tool's main translation-unit object. avifenc/avifdec are a single
      # main backed by the shared avif_apps.a; avifgainmaputil (C++) is many
      # objects but main() lives in avifgainmaputil.cc — and its link recipe
      # already pulls avif_apps.a + libavif + the whole codec chain + libargparse
      # + xml2, so it is the superset *template* we splice the other two mains
      # into. A tool's absence (a platform that ever drops one) just shrinks the
      # applet set.
      declare -A OBJ
      OBJ[avifenc]="$(find . -path "*avifenc.dir/apps/avifenc.c.$oext" | head -1)"
      OBJ[avifdec]="$(find . -path "*avifdec.dir/apps/avifdec.c.$oext" | head -1)"
      OBJ[avifgainmaputil]="$(find . -path "*avifgainmaputil.dir/apps/avifgainmaputil/avifgainmaputil.cc.$oext" | head -1)"

      apps=()
      for a in avifenc avifdec avifgainmaputil; do
        [ -n "''${OBJ[$a]}" ] && apps+=("$a")
      done
      [ ''${#apps[@]} -ge 2 ] || { echo "multicall: expected >=2 app objects, got ''${apps[*]:-none}" >&2; exit 1; }
      printf '%s\n' "''${apps[@]}" > multicall/apps.list

      # Template = the app with the richest link line: avifgainmaputil if built
      # (its link.txt is a superset of enc/dec's), else avifenc.
      tmpl=avifenc
      for a in "''${apps[@]}"; do [ "$a" = avifgainmaputil ] && tmpl=avifgainmaputil; done
      linktxt="$(find . -path "*$tmpl.dir/link.txt" | head -1)"
      [ -n "$linktxt" ] || { echo "multicall: $tmpl link.txt not found (non-Makefile generator?)" >&2; exit 1; }

      # Symbol prefix (Mach-O leads C symbols with '_'), read once from a main.
      if $NM --defined-only "''${OBJ[$tmpl]}" | awk '$3=="_main"{f=1} END{exit !f}'; then
        up=_
      else
        up=""
      fi

      # Distinct entry points: rename each tool's main → <tool>_main.
      for a in "''${apps[@]}"; do
        $OBJCOPY --redefine-sym "''${up}main=''${up}''${a}_main" "''${OBJ[$a]}"
      done

      # Dispatcher (shared canonical generator — see nix-lib
      # lib.multicallDispatcherC). Reads multicall/apps.list (written above).
${lib.multicallDispatcherC { inherit name; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Reuse the template's link command: splice every NON-template tool's main
      # object + the dispatcher in front of the output, retarget to
      # multicall/${name}, and append the runtime-folding flags. The template's
      # own objects + the full lib list are already in its link.txt; the spliced
      # mains resolve their avif_apps.a/libavif references off that line.
      splice=""
      for a in "''${apps[@]}"; do [ "$a" = "$tmpl" ] || splice="$splice ''${OBJ[$a]}"; done
      linkbase="$(sed -E "s| -o (\"?)$tmpl(\.exe)?(\"?)|$splice multicall/dispatcher.o -o multicall/${name}|" "$linktxt") ${extraLinkFlags}"

      # Iterative link: each failed attempt names remaining strong duplicates;
      # rename those per-tool and relink. Pure-C mains here, so this normally
      # converges on the first pass (only `main`, already renamed above).
      converged=0
      for _ in $(seq 1 20); do
        if eval "$linkbase" 2>multicall/link.err; then converged=1; break; fi
        cat multicall/link.err >&2
        sed -nE "s/.*multiple definition of [\`']([^']+)'.*/\1/p; s/.*duplicate symbol '([^']+)'.*/\1/p" \
          multicall/link.err | sort -u > multicall/clash.syms
        [ -s multicall/clash.syms ] || { echo "multicall: link failed without a duplicate-symbol diagnostic" >&2; exit 1; }
        while IFS= read -r sym; do
          hit=0
          for a in "''${apps[@]}"; do
            [ "$a" = "$tmpl" ] && continue   # template objects are sacrosanct:
                                             # renaming one breaks its siblings'
                                             # references (def+ref split across
                                             # the template's many .cc objects).
            obj="''${OBJ[$a]}"
            raw=$($NM --defined-only "$obj" | awk -v s="$sym" '$3==s {print $3; exit}')
            [ -n "$raw" ] || continue
            $OBJCOPY --redefine-sym "$raw=''${up}''${a}__''${raw#"$up"}" "$obj"
            hit=1
          done
          [ "$hit" = 1 ] || { echo "multicall: clashing symbol '$sym' not renamable (defined only in template '$tmpl'?)" >&2; exit 1; }
        done < multicall/clash.syms
      done
      [ "$converged" = 1 ] || { echo "multicall: link did not converge in 20 passes" >&2; exit 1; }

      # mingw gcc may auto-append .exe; normalize to the suffixless name
      # installPhase + withAliases expect (Windows postFixup re-adds .exe).
      [ -f multicall/${name} ] || mv multicall/${name}.exe multicall/${name}
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 multicall/${name} "$out/bin/${name}"
      while IFS= read -r a; do
        [ -n "$a" ] && ln -s ${name} "$out/bin/$a"
      done < multicall/apps.list
      runHook postInstall
    '';
  });
  aliased = lib.withAliases pkgs
    {
      primary = name;
      aliasesFromSymlinksIn = "bin";
    }
    multicall;
in
if pkgs.stdenv.hostPlatform.isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/${name}" ] && mv "$out/bin/${name}" "$out/bin/${name}.exe"
  '';
})
else aliased
