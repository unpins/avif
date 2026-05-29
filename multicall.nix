# libavif builds two CLI tools — avifenc and avifdec — as "apps". To honour
# the unpins one-pkg-one-bin rule we post-link them into a single multicall
# binary at $out/bin/avif; `lib.withAliases` then embeds the tool names as an
# UNPIN_META block so unpin's installer can recreate the argv[0] shims.
#
# Link mechanics (vs libvpx/recursive-make, srt/CMake-query, rtmpdump/Makefile):
#
#   * libavif uses the CMake "Unix Makefiles" generator (no ninja in
#     nativeBuildInputs), so every target gets a `CMakeFiles/<t>.dir/link.txt`
#     holding its exact link command — compiler, flags, object, and the full
#     codec/image lib list (avif_apps.a, libavif.a, aom, dav1d, libyuv,
#     sharpyuv, png, jpeg, zlib, webp, xml2, …) resolved correctly for the
#     platform. We reuse avifenc's link.txt verbatim and just splice in
#     avifdec's main object + the dispatcher, retargeting the output. That
#     sidesteps re-deriving the per-platform lib list by hand (the e2fsprogs
#     landmine).
#
#   * The shared app helpers (avifutil/avifjpeg/avifpng/y4m/…) live in a single
#     static archive (avif_apps.a) that both tools link, so they are pulled
#     on-demand from the archive — NOT duplicated as loose objects. The only
#     symbol both .c.o files define is `main` (avifdec also defines
#     avifWriteToFile, but avifenc does not). So a plain main-rename is enough;
#     the iterative pass below is insurance against any future strong clash.
#
#   * avifenc/avifdec link the vendored libyuv (C++) and pull aom (C++), so the
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

      # Tool mains and avifenc's link recipe. Existence gates a platform that
      # ever drops a tool.
      apps=()
      for a in avifenc avifdec; do
        obj="$(find . -path "*$a.dir/apps/$a.c.$oext" | head -1)"
        [ -n "$obj" ] && apps+=("$a")
      done
      [ ''${#apps[@]} -eq 2 ] || { echo "multicall: expected avifenc+avifdec objects, got ''${apps[*]:-none}" >&2; exit 1; }
      printf '%s\n' "''${apps[@]}" > multicall/apps.list

      encobj="$(find . -path "*avifenc.dir/apps/avifenc.c.$oext" | head -1)"
      decobj="$(find . -path "*avifdec.dir/apps/avifdec.c.$oext" | head -1)"
      linktxt="$(find . -path '*avifenc.dir/link.txt' | head -1)"
      [ -n "$linktxt" ] || { echo "multicall: avifenc link.txt not found (non-Makefile generator?)" >&2; exit 1; }

      # Symbol prefix (Mach-O leads C symbols with '_'), read once from a main.
      if $NM --defined-only "$encobj" | awk '$3=="_main"{f=1} END{exit !f}'; then
        up=_
      else
        up=""
      fi

      # Distinct entry points: rename each tool's main → <tool>_main.
      $OBJCOPY --redefine-sym "''${up}main=''${up}avifenc_main" "$encobj"
      $OBJCOPY --redefine-sym "''${up}main=''${up}avifdec_main" "$decobj"

      # Dispatcher: basename(argv[0]) → <tool>_main, '.exe' stripped, plus a
      # `${name} <applet> [args]` form so the bare binary stays callable.
      {
        echo '#include <string.h>'
        echo '#include <stdio.h>'
        for a in "''${apps[@]}"; do echo "int ''${a}_main(int, char **);"; done
        echo 'struct applet { const char *name; int (*fn)(int, char **); };'
        echo 'static const struct applet applets[] = {'
        for a in "''${apps[@]}"; do echo "    {\"$a\", ''${a}_main},"; done
        cat <<'CBODY'
    {0, 0}
};
static void copy_basename(char *dst, size_t cap, const char *src) {
    const char *p = src, *s;
    s = strrchr(p, '/'); if (s) p = s + 1;
#ifdef _WIN32
    s = strrchr(p, '\\'); if (s) p = s + 1;
#endif
    size_t n = strlen(p); if (n >= cap) n = cap - 1;
    memcpy(dst, p, n); dst[n] = 0;
    if (n > 4 && strcmp(dst + n - 4, ".exe") == 0) dst[n - 4] = 0;
}
CBODY
        cat <<CBODY
static int usage(const char *a0) {
    fprintf(stderr, "${name}: multicall binary; usage: %s <applet> [args]\n", a0);
    fprintf(stderr, "applets:");
    for (const struct applet *a = applets; a->name; a++)
        fprintf(stderr, " %s", a->name);
    fprintf(stderr, "\n");
    return 1;
}
int main(int argc, char **argv) {
    char base[64];
    const char *a0 = (argc > 0 && argv[0]) ? argv[0] : "${name}";
    copy_basename(base, sizeof base, a0);
    if (strcmp(base, "${name}") == 0) {
        if (argc < 2) return usage(a0);
        copy_basename(base, sizeof base, argv[1]);
        argv++; argc--;
    }
    for (const struct applet *a = applets; a->name; a++)
        if (strcmp(base, a->name) == 0) return a->fn(argc, argv);
    fprintf(stderr, "${name}: unknown applet '%s'\n", base);
    return usage(a0);
}
CBODY
      } > multicall/dispatcher.c
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Reuse avifenc's link command: splice avifdec's main object + the
      # dispatcher in front of the output, retarget to multicall/${name}, and
      # append the runtime-folding flags. The encobj is already in the command
      # (renamed in place); decobj/dispatcher resolve avifdec_main + main.
      linkbase="$(sed -E "s| -o (\"?)avifenc(\.exe)?(\"?)| $decobj multicall/dispatcher.o -o multicall/${name}|" "$linktxt") ${extraLinkFlags}"

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
          for pair in "avifenc:$encobj" "avifdec:$decobj"; do
            a="''${pair%%:*}"; obj="''${pair#*:}"
            raw=$($NM --defined-only "$obj" | awk -v s="$sym" '$3==s {print $3; exit}')
            [ -n "$raw" ] || continue
            $OBJCOPY --redefine-sym "$raw=''${up}''${a}__''${raw#"$up"}" "$obj"
            hit=1
          done
          [ "$hit" = 1 ] || { echo "multicall: clashing symbol '$sym' not defined by any tool object" >&2; exit 1; }
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
