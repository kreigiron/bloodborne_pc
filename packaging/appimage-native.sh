#!/usr/bin/env bash
# Builds dist/Bloodborne-bbport-x86_64.AppImage: a native (non-Nix) AppImage of the prebuilt port.
#
# Unlike packaging/appimage.sh (Nix closure + bundled Mesa drivers), this image relies on the host
# for Mesa/RADV, the Vulkan loader, X11/Wayland, audio and (later) GTK4/python, but ships:
#   * usr/lib:            the app-private shared-library closure of the port binaries, and
#   * usr/lib/bbport-glibc: the host's glibc 2.44 runtime and loader,
# so it runs on a glibc-2.41 host such as SteamOS. The port binaries name the bundled loader as
# their ELF interpreter (PT_INTERP), so the KERNEL starts them through it (like packaging/bbport-entry.c
# does for the Nix build); the wrapper scripts keep using the host's python3/bash. Starting them
# through an explicit loader instead deadlocks the port's main guest thread and leaves the window
# black (see the engine section below), so nothing routes them through ld.so.
# Build the port first: bash build.sh.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
root=$PWD

[[ -f out/bb-probe && -f out/gpu/libbbgpu.so ]] || { echo 'Build first: bash build.sh' >&2; exit 1; }

appdir=$root/out/appimage-native/AppDir
payload=$appdir/usr/share/bbport
libdir=$appdir/usr/lib
glibcdir=$libdir/bbport-glibc
# The GTK4 launcher's private libraries (libadwaita) live in their own directory so that no bundled
# glib/GTK can shadow the host's (AppRun below keeps usr/lib off the launcher's library path).
launcherdir=$libdir/launcher
distdir=$root/dist
image=$distdir/Bloodborne-bbport-x86_64.AppImage

# --- Stable engine dir (single source of truth) -------------------------------------------------
# The port binaries are patched below so the KERNEL starts them through the bundled glibc loader:
# their PT_INTERP names the loader and their RUNPATH points at this flat engine directory. Both are
# fixed absolute paths (PT_INTERP cannot be relative) while the AppImage mount path changes every
# run, so AppRun recreates the engine directory of symlinks into the current mount on every launch.
# BB_ENGINE_DIR overrides the default; a build done with a different value bakes that path into the
# binaries, so the same value must be present at run time.
engine_dir=${BB_ENGINE_DIR:-/tmp/bbport-engine}
engine_loader=$engine_dir/ld-linux-x86-64.so.2

# --- AppDir layout: mirror the Nix payload (packaging/default.nix, $out/share/bbport) ---
rm -rf "$root/out/appimage-native"
mkdir -p "$payload/bin/gpu" "$libdir" "$glibcdir" "$launcherdir/girepository-1.0" "$distdir"
cp -a run.sh scripts patches launcher tools "$payload/"
# Prune Python caches from every copied tree (scripts/, launcher/ and tools/): they are build-host
# artifacts and would only bloat the image.
find "$payload/scripts" "$payload/launcher" "$payload/tools" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$payload/scripts" "$payload/launcher" "$payload/tools" -type f -name '*.py[co]' -delete 2>/dev/null || true
# DLSS artifacts of the Nix package (packaging/default.nix: libbbport_dlss.so and NVIDIA's
# libnvidia-ngx-dlss.so.*) are intentionally omitted: the AMD-Deck target has no RTX GPU.
install -m755 out/bb-probe "$payload/bin/bb-probe"
install -m755 out/bb-gpu-capabilities "$payload/bin/bb-gpu-capabilities"
# Libraries are only mapped (read), never executed: 0644. Only the port binaries and the loader
# (below) are executed and stay 0755.
install -m644 out/gpu/libbbgpu.so "$payload/bin/gpu/libbbgpu.so"
if [[ -f out/gpu/libbbnet.so ]]; then
    install -m644 out/gpu/libbbnet.so "$payload/bin/gpu/libbbnet.so"
fi

# --- App-private library closure ------------------------------------------------------------------
# Resolve an ELF's libraries with ldd and print only the resolved absolute paths. LD_LIBRARY_PATH
# names the binaries' gpu directory and usr/lib, so the port's own libraries resolve there.
resolved_libraries() {
    LC_ALL=C ldd "$1" 2>/dev/null | sed -n 's/.*=> \(\/[^ ]*\).*/\1/p'
}

# Libraries the host must provide (Mesa/RADV, the Vulkan loader, the window systems and audio) and
# glibc itself, which is bundled separately below. The window-system entry names the full
# X11/Wayland *client* family the port's SDL3/FFmpeg/GTK code may link against: naming only
# libX11/libXext/libxcb/libwayland was not self-consistent, because the closure walk then bundled
# libXau/libXrender/libXfixes/... anyway. (libxcb-* and libwayland-* are covered by the libxcb and
# libwayland prefixes.) Everything else is bundled.
never_bundle=(
    libvulkan.so libGL libEGL libGLX libOpenGL libGLdispatch
    libdrm libgbm libxcb libX11 libXext libwayland libasound
    libpipewire libjack libfontconfig libfreetype libharfbuzz
    libXau libXdmcp libXrender libXfixes libXi libXcursor libXrandr libXcomposite libXdamage
    libXtst libXScrnSaver libXxf86vm libxshmfence libxkbcommon
)
glibc_core='^(libc|libm|libmvec|libpthread|libdl|librt|libutil|libresolv|libanl)\.so|^(ld-linux-x86-64\.so|libnss_.*\.so|libgcc_s\.so|libstdc\+\+\.so)'

is_host_owned() {
    local soname=$1 prefix
    for prefix in "${never_bundle[@]}"; do
        [[ $soname == "$prefix"* ]] && return 0
    done
    [[ $soname =~ $glibc_core ]] && return 0
    return 1
}

# Host directories searched for glibc runtime files, the OpenCL loader and the NSS modules: the
# usual locations plus the Debian/Ubuntu multiarch directories.
host_library_dirs=(/usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib /lib /usr/lib64 /lib64)

find_library_file() {
    local name=$1 dir
    for dir in "${host_library_dirs[@]}"; do
        [[ -e $dir/$name ]] && { printf '%s\n' "$dir/$name"; return 0; }
    done
    return 1
}

# Walk NEEDED transitively and copy every library the host does not own into usr/lib, flattened by
# SONAME. The seeds themselves stay in bin/.
seeds=("$payload/bin/bb-probe" "$payload/bin/bb-gpu-capabilities" "$payload/bin/gpu/libbbgpu.so")
if [[ -f $payload/bin/gpu/libbbnet.so ]]; then
    seeds+=("$payload/bin/gpu/libbbnet.so")
fi
declare -A seen=()
seen[bb-probe]=1 seen[bb-gpu-capabilities]=1 seen[libbbgpu.so]=1 seen[libbbnet.so]=1
export LD_LIBRARY_PATH="$payload/bin/gpu:$libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
queue=("${seeds[@]}")
while ((${#queue[@]})); do
    elf=${queue[0]}
    queue=("${queue[@]:1}")
    while IFS= read -r lib; do
        [[ -n $lib && -e $lib ]] || continue
        soname=$(basename "$lib")
        [[ -n ${seen[$soname]:-} ]] && continue
        seen[$soname]=1
        is_host_owned "$soname" && continue
        install -m644 "$lib" "$libdir/$soname"
        queue+=("$libdir/$soname")
    done < <(resolved_libraries "$elf")
done
unset LD_LIBRARY_PATH

# C2: readelf -d shows that libavutil.so.61 (the bundled FFmpeg) has a real DT_NEEDED on
# libOpenCL.so.1, so it is not just a hypothetical. Bundle the host's generic ICD loader
# (ocl-icd: libc + ld-linux only, no driver) so the dependency is always satisfied; at run time
# it reads the target's own vendor ICDs from /etc/OpenCL/vendors, so no OpenCL driver is bundled.
# libOpenCL is intentionally NOT in never_bundle; ld.so.cache may have offered a CUDA copy from
# /opt/cuda, so install the system one explicitly.
opencl_loader=$(find_library_file libOpenCL.so.1) \
    || { echo 'Missing host libOpenCL.so.1 (needed by libavutil); install ocl-icd' >&2; exit 1; }
install -m644 "$opencl_loader" "$libdir/libOpenCL.so.1"

# Verification runs after the bundled glibc is staged (the final --list needs the bundled loader).
verify_image() {
# --- C1: fail fast on unresolved libraries -----------------------------------------------------
# Drive from readelf DT_NEEDED: every NEEDED of a port binary or a staged usr/lib library must be
# satisfied by a staged library (usr/lib, usr/lib/bbport-glibc, or the seeds' own bin/gpu RUNPATH)
# or by the documented host allowlist. An unresolved name fails the build: a silently broken image
# must never be emitted. The host-delegated names are printed so the delegation stays explicit.
needed_names() {
    readelf -d "$1" 2>/dev/null | awk '$2 == "(NEEDED)" { gsub(/[][]/, "", $5); print $5 }'
}

staged_library_dirs=("$libdir" "$glibcdir" "$payload/bin/gpu")
is_staged() {
    local soname=$1 dir
    for dir in "${staged_library_dirs[@]}"; do
        [[ -e $dir/$soname ]] && return 0
    done
    return 1
}

declare -A host_delegated=()
check_needed() {
    local elf=$1 name
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        if is_staged "$name"; then
            continue
        elif is_host_owned "$name"; then
            host_delegated[$name]=1
            continue
        fi
        echo "UNRESOLVED dependency: $name" >&2
        echo "  needed by: $elf" >&2
        echo "  not staged in usr/lib, usr/lib/bbport-glibc or bin/gpu, and not host-provided" >&2
        exit 1
    done < <(needed_names "$elf")
}

verify_elfs=("$payload/bin/bb-probe" "$payload/bin/bb-gpu-capabilities" "$payload/bin/gpu/libbbgpu.so")
[[ -f $payload/bin/gpu/libbbnet.so ]] && verify_elfs+=("$payload/bin/gpu/libbbnet.so")
shopt -s nullglob
verify_elfs+=("$libdir"/*.so*)
shopt -u nullglob
for elf in "${verify_elfs[@]}"; do
    check_needed "$elf"
done

# ldd must also resolve everything: a nonzero status or a "not found" line is a build failure.
verify_library_path="$glibcdir:$libdir:$payload/bin/gpu"
for elf in "${verify_elfs[@]}"; do
    if ! ldd_out=$(LD_LIBRARY_PATH="$verify_library_path" LC_ALL=C ldd "$elf" 2>&1); then
        echo "ldd failed for $elf:" >&2
        printf '%s\n' "$ldd_out" >&2
        exit 1
    fi
    if [[ $ldd_out == *'not found'* ]]; then
        echo "ldd reports unresolved libraries for $elf:" >&2
        while IFS= read -r line; do
            [[ $line == *'not found'* ]] && printf '%s\n' "$line" >&2
        done <<<"$ldd_out"
        exit 1
    fi
done

# Final sanity: the bundled loader's own --list view of the port binaries.
for elf in "${seeds[@]}"; do
    if ! list_out=$("$glibcdir/ld-linux-x86-64.so.2" --library-path "$verify_library_path" --list "$elf" 2>&1); then
        echo "Bundled loader failed on $elf:" >&2
        printf '%s\n' "$list_out" >&2
        exit 1
    fi
    if [[ $list_out == *'not found'* || $list_out =~ GLIBC_2\.4[0-9]\ not\ found ]]; then
        echo "Bundled loader cannot resolve $elf:" >&2
        while IFS= read -r line; do
            [[ $line == *'not found'* ]] && printf '%s\n' "$line" >&2
        done <<<"$list_out"
        exit 1
    fi
done

if (( ${#host_delegated[@]} )); then
    printf 'Host-delegated dependencies (documented allowlist): %s\n' \
        "$(printf '%s\n' "${!host_delegated[@]}" | LC_ALL=C sort | tr '\n' ' ')"
fi

# --- M3: residual risk of host-delegated symbol versions ---------------------------------------
# A bundled library linked against a host-provided library may require a symbol version the
# target's (older) copy lacks. Report those requirements; warn only, never fail.
declare -A host_version_risk=()
for lib in "$libdir"/*.so*; do
    host_lib= in_version_needs=0
    while IFS= read -r line; do
        if [[ $line == *".gnu.version_r"* ]]; then
            in_version_needs=1 host_lib=
        elif [[ $line == *".gnu.version_d"* ]]; then
            in_version_needs=0 host_lib=
        elif (( in_version_needs )); then
            if [[ $line =~ File:\ ([^ ]+) ]]; then
                host_lib=${BASH_REMATCH[1]}
            elif [[ $line =~ Name:\ ([^ ]+) ]] && [[ -n $host_lib ]] \
                    && is_host_owned "$host_lib" && ! is_staged "$host_lib"; then
                host_version_risk["${lib#"$libdir"/} <- $host_lib (${BASH_REMATCH[1]})"]=1
            fi
        fi
    done < <(readelf --version-info "$lib" 2>/dev/null)
done
if (( ${#host_version_risk[@]} )); then
    echo 'Host-delegated symbol-version risks (warn only; a target older than these symbols breaks):'
    printf '  %s\n' "${!host_version_risk[@]}" | LC_ALL=C sort
else
    echo 'Host-delegated symbol-version risks: none (host X11/Wayland/Vulkan symbols are unversioned)'
fi
}  # verify_image

# --- Bundled glibc 2.44 runtime ---------------------------------------------------------------
# The loader and glibc runtime, plus the C++ runtime the port's libstdc++ ABI needs. Libraries are
# mapped, not executed, so they are 0644; only the loader is executed directly and stays 0755.
glibc_runtime=(
    ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libmvec.so.1 libpthread.so.0 libdl.so.2
    librt.so.1 libutil.so.1 libresolv.so.2 libanl.so.1 libgcc_s.so.1 libstdc++.so.6
)
for name in "${glibc_runtime[@]}"; do
    src=$(find_library_file "$name") || { echo "Missing host glibc runtime file: $name" >&2; exit 1; }
    mode=644
    [[ $name == ld-linux-x86-64.so.2 ]] && mode=755
    install -m"$mode" "$src" "$glibcdir/$name"
done
# NSS modules: getaddrinfo/getpwnam through the bundled libc. They live in different directories
# across distributions (Arch: /usr/lib, Debian: /usr/lib/x86_64-linux-gnu), so search them all and
# fail loudly when none is found: a silently module-less libc breaks DNS at run time.
declare -A nss_modules=()
for dir in "${host_library_dirs[@]}"; do
    shopt -s nullglob
    for src in "$dir"/libnss_*.so.2; do
        nss_modules[$(basename "$src")]=$src
    done
    shopt -u nullglob
done
if (( ${#nss_modules[@]} == 0 )); then
    echo 'No NSS modules (libnss_*.so.2) found in the host library directories:' >&2
    printf '  %s\n' "${host_library_dirs[@]}" >&2
    echo 'DNS and user lookups through the bundled glibc would break; install the NSS packages.' >&2
    exit 1
fi
for name in "${!nss_modules[@]}"; do
    install -m644 "${nss_modules[$name]}" "$glibcdir/$name"
done

# usr/lib (the closure), the bundled glibc and the port binaries are complete: prove the image is
# not silently broken (C1) and report host-delegated symbol-version risk (M3).
verify_image

# --- Kernel-invoked bundled loader (stable engine dir) -----------------------------------------
# A binary's PT_INTERP is resolved by the KERNEL, so starting these binaries through the bundled
# loader this way matches how the Nix build starts them through its /nix/store loader. Starting
# them through an EXPLICIT loader instead (ld-linux --library-path ... bb-probe) deterministically
# deadlocks the port's main guest thread (src/runtime_sema.c:84, semaphore 3 is never signalled):
# the SDL/Vulkan window opens and stays black. Hence: bake the loader in as the interpreter and
# keep every search path stable, then never invoke the port binaries through ld.so at run time.
patchelf --set-interpreter "$engine_loader" "$payload/bin/bb-probe"
patchelf --set-interpreter "$engine_loader" "$payload/bin/bb-gpu-capabilities"
# RPATH = the stable engine dir (every bundled glibc and closure library, flattened) plus the
# original $ORIGIN semantics: bb-probe finds libbbgpu.so through $ORIGIN/gpu, the other two keep
# $ORIGIN. --force-rpath keeps it as the obsolete but TRANSITIVE DT_RPATH instead of DT_RUNPATH:
# DT_RUNPATH covers only the object's direct dependencies, so a closure library of a closure
# library (libavformat -> libxml2) would fall back to the host and fail on a target that lacks it
# (the debian:13 cross-check catches exactly this). DT_RPATH is searched for the whole tree, which
# is what the old global --library-path was for. --set-rpath also drops the stale absolute
# build-path entry baked into bb-probe, which would not exist on a target.
patchelf --force-rpath --set-rpath "\$ORIGIN/gpu:$engine_dir" "$payload/bin/bb-probe"
patchelf --force-rpath --set-rpath "\$ORIGIN:$engine_dir" "$payload/bin/bb-gpu-capabilities"
# The gpu directory's libraries carry the same stale build path and load sibling closure
# libraries; the online module (libbbnet) is only present in some builds.
for lib in "$payload/bin/gpu/"*.so; do
    patchelf --force-rpath --set-rpath "\$ORIGIN:$engine_dir" "$lib"
done

# AppRun recreates the engine dir at run time; create the same farm here and prove the bundled
# loader resolves every dependency through the patched RUNPATHs alone (no --library-path), then
# remove it: a leftover farm would point into a mount that no longer exists.
rm -rf "$engine_dir"
mkdir -p "$engine_dir"
ln -sf "$glibcdir"/* "$engine_dir"/
ln -sf "$libdir"/*.so* "$engine_dir"/
for elf in "$payload/bin/bb-probe" "$payload/bin/bb-gpu-capabilities"; do
    [[ $(patchelf --print-interpreter "$elf") == "$engine_loader" ]] || {
        echo "PT_INTERP not the stable loader on $elf" >&2; exit 1; }
done
for elf in "${seeds[@]}"; do
    # DT_RPATH, not DT_RUNPATH: only RPATH is searched for the transitive closure. A build host
    # usually has the closure libraries too, so a broken RUNPATH would pass the resolution check
    # below by accident; assert the tag itself.
    readelf -d "$elf" | grep -q '(RPATH)' || {
        echo "Missing transitive DT_RPATH on $elf" >&2; exit 1; }
    if ! list_out=$("$glibcdir/ld-linux-x86-64.so.2" --list "$elf" 2>&1); then
        echo "Kernel-invoked loader path cannot resolve $elf:" >&2
        printf '%s\n' "$list_out" >&2
        exit 1
    fi
    if [[ $list_out == *'not found'* ]]; then
        echo "Patched RUNPATH is incomplete for $elf:" >&2
        while IFS= read -r line; do
            [[ $line == *'not found'* ]] && printf '%s\n' "$line" >&2
        done <<<"$list_out"
        exit 1
    fi
done
echo "Engine: PT_INTERP=$engine_loader, RPATH=\$ORIGIN[:/gpu]:$engine_dir (resolved with no --library-path)"
rm -rf "$engine_dir"

# --- Bundled libadwaita for the GTK4 launcher --------------------------------------------------
# The launcher uses the host's python3/PyGObject/GTK4/gdk-pixbuf (the target, a SteamOS-class
# device, has them), but libadwaita is absent there: bundle just it and its GI typelib. They go to
# usr/lib/launcher, never usr/lib, so no bundled glib/GTK can shadow the host's; AppRun runs the
# launcher through the bundled loader with only bbport-glibc and this directory on its path.
find_data_file() {
    local name=$1 dir
    for dir in /usr/lib/girepository-1.0 /usr/lib/x86_64-linux-gnu/girepository-1.0 \
               /usr/lib64/girepository-1.0 /usr/local/lib/girepository-1.0; do
        [[ -e $dir/$name ]] && { printf '%s\n' "$dir/$name"; return 0; }
    done
    return 1
}

# A build host's libadwaita may be built against a newer GTK than the target's 4.18 and use symbols
# it lacks (Arch 1.10: gtk_symbolic_paintable_snapshot_with_weight, plus the Arch-only
# libministream), so it cannot run on a stock SteamOS. Take a libadwaita built for the target's
# glibc 2.41 / GTK 4.18 instead: from a debian:13 container (extracted once into the build tree),
# or from BB_ADW_DIR when set; without docker the host's is used and a warning is printed.
acquire_debian_libadwaita() {
    local dest=$1
    command -v docker >/dev/null 2>&1 || return 1
    mkdir -p "$dest"
    if docker run --rm -v "$dest":/out debian:13 sh -c '
            set -e
            apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libadwaita-1-0 gir1.2-adw-1 >/dev/null 2>&1
            cp -aL /usr/lib/x86_64-linux-gnu/libadwaita-1.so.0 /out/libadwaita-1.so.0
            cp -aL /usr/lib/x86_64-linux-gnu/girepository-1.0/Adw-1.typelib /out/Adw-1.typelib
        ' >/dev/null 2>&1; then
        [[ -f $dest/libadwaita-1.so.0 && -f $dest/Adw-1.typelib ]]
    else
        return 1
    fi
}

adw_name=libadwaita-1.so.0
adw_cache=$root/out/debian-libadwaita
if [[ -n ${BB_ADW_DIR:-} ]]; then
    adw_lib=$BB_ADW_DIR/$adw_name
    adw_typelib_src=$BB_ADW_DIR/Adw-1.typelib
elif [[ -f $adw_cache/$adw_name && -f $adw_cache/Adw-1.typelib ]]; then
    adw_lib=$adw_cache/$adw_name
    adw_typelib_src=$adw_cache/Adw-1.typelib
    echo "libadwaita: cached debian:13 build ($adw_cache)"
elif acquire_debian_libadwaita "$adw_cache"; then
    adw_lib=$adw_cache/$adw_name
    adw_typelib_src=$adw_cache/Adw-1.typelib
    echo "libadwaita: extracted a debian:13 build (glibc 2.41 / GTK 4.18) into $adw_cache"
else
    adw_lib=$(find_library_file "$adw_name") || { echo "Missing libadwaita: $adw_name" >&2; exit 1; }
    adw_typelib_src=$(find_data_file Adw-1.typelib) || { echo 'Missing Adw-1.typelib' >&2; exit 1; }
    echo 'WARNING: libadwaita: no debian:13 build available (docker missing?); using the host build, which may need a newer GTK than the target has' >&2
fi
[[ -f $adw_lib && -f $adw_typelib_src ]] || { echo "Missing libadwaita files: $adw_lib / $adw_typelib_src" >&2; exit 1; }
adw_real=$(readlink -f -- "$adw_lib")
# Copy the real file under its SONAME (the loader looks it up by SONAME).
install -m644 "$adw_real" "$launcherdir/$adw_name"
install -m644 "$adw_typelib_src" "$launcherdir/girepository-1.0/Adw-1.typelib"

# Some libadwaita builds link libappstream for the about dialog's release notes only (Debian 1.7:
# libappstream.so.5), which a SteamOS-class target lacks. Stand in with a tiny shim that defines
# exactly the symbols libadwaita references: the launcher never opens that dialog, so the stubs are
# never called, but a full RELRO/BIND_NOW libadwaita needs the names to load.
shim_symbols=$(objdump -T "$adw_real" | awk '$3 == "*UND*" && $NF ~ /^as_/ { print $NF }' | sort -u)
if [[ -n $shim_symbols ]]; then
    command -v cc >/dev/null 2>&1 || { echo 'libadwaita links libappstream; a C compiler is needed for the shim' >&2; exit 1; }
    shim_c=$root/out/appimage-native/libappstream-shim.c
    {
        echo '/* Generated: the appstream symbols libadwaita references (about-dialog release notes).'
        echo '   The launcher never opens that dialog, so these are never called. */'
        while IFS= read -r sym; do
            [[ -n $sym ]] && printf 'void *%s(void) { return 0; }\n' "$sym"
        done <<<"$shim_symbols"
    } > "$shim_c"
    cc -shared -fPIC -O2 -Wl,-soname,libappstream.so.5 -o "$launcherdir/libappstream.so.5" "$shim_c"
    chmod 644 "$launcherdir/libappstream.so.5"
    echo 'libadwaita: shimmed libappstream (release-notes path only)'
fi

# libadwaita's other NEEDED libraries are the host's GTK4/glib/pango/... (relied on above); report
# any that a stock SteamOS GTK4 stack would not provide (e.g. a distribution-specific helper).
adw_host_stack='^lib(gtk-4|glib-2\.0|gio-2\.0|gobject-2\.0|gmodule-2\.0|pango-1\.0|pangocairo-1\.0|graphene-1\.0|fribidi|harfbuzz|gdk_pixbuf-2\.0)\.so|^lib(c|m|pthread|dl|rt|resolv|util)\.so|^ld-linux'
for needed in $(objdump -p "$adw_real" | awk '$1 == "NEEDED" { print $2 }'); do
    if [[ $needed == libappstream.so.5 && -n $shim_symbols ]]; then
        continue  # provided by the shim above
    fi
    [[ $needed =~ $adw_host_stack ]] || printf 'WARNING: libadwaita needs %s, not part of the stock GTK4 stack; verify the target has it\n' "$needed" >&2
done

# GSettings schemas shipped by libadwaita (none upstream, some distributions may add them): bundle
# them and a merged gschemas.compiled. The host's own schemas stay visible through the default
# search path, so only libadwaita's are copied.
shopt -s nullglob
adw_schemas=(/usr/share/glib-2.0/schemas/*adw*.gschema.xml \
             /usr/share/glib-2.0/schemas/*adwaita*.gschema.xml)
shopt -u nullglob
if ((${#adw_schemas[@]})); then
    schema_out=$appdir/usr/share/glib-2.0/schemas
    mkdir -p "$schema_out"
    cp "${adw_schemas[@]}" "$schema_out/"
    glib-compile-schemas "$schema_out" || echo 'glib-compile-schemas failed for the bundled libadwaita schemas' >&2
fi

# --- AppRun -----------------------------------------------------------------------------------
# Host-injection variables dropped before AppRun sets its own environment. Keep this list in sync
# with host_only[] in packaging/bbport-entry.c (the Nix wrapper's static entry point), which drops
# exactly the same names and sets the same two Vulkan-layer disables.
host_only_vars=(LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT GTK_PATH GTK_MODULES GTK_EXE_PREFIX
                GIO_EXTRA_MODULES GDK_PIXBUF_MODULEDIR PYTHONHOME PYTHONPATH)

{
cat <<'APPEOF'
#!/usr/bin/env bash
# The AppImage's entry point. Without arguments it starts the GTK4 launcher; with --play it runs the
# game directly (the settings-only, launcher-less path). The port binaries name the bundled glibc
# 2.44 loader as their PT_INTERP, so the KERNEL starts them through it and the image does not depend
# on the host's glibc version; the launcher process uses the host's python3/PyGObject/GTK4 with the
# bundled libadwaita, run through that same loader.
set -euo pipefail
APPDIR=${APPDIR:-$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)}
APPIMAGE=${APPIMAGE:-$APPDIR}
export APPDIR APPIMAGE

# Steam starts non-Steam games with LD_PRELOAD (its overlay), LD_LIBRARY_PATH and the like; those
# name host libraries incompatible with the bundled glibc. run.sh shells out to the host's python3,
# so PYTHONHOME/PYTHONPATH matter too (packaging/bbport-entry.c does the same before the Nix
# wrapper starts). Strip them before setting our own variables.
APPEOF
# The dropped-variable list lives once, in host_only_vars above.
printf 'unset'
printf ' %s' "${host_only_vars[@]}"
printf '\n'
cat <<'APPEOF'

# Steam's Vulkan layers (overlay, fossilize) are host libraries incompatible with the bundled
# glibc too: disable them, as packaging/bbport-entry.c does.
export DISABLE_VK_LAYER_VALVE_steam_overlay_1=1
export DISABLE_VK_LAYER_VALVE_steam_fossilize_1=1

export BB_PREBUILT=1
APPEOF
# The engine directory path is baked in here and by the patchelf calls above: one source of truth.
# PT_INTERP cannot be relative and the mount path changes every run, so AppRun (re)creates this
# exact path as a flat symlink farm of the bundled loader and every bundled library before any port
# binary starts. Symlinks resolve through the image's executable mount, so a noexec /tmp is fine.
printf 'engine_dir=${BB_ENGINE_DIR:-%s}\n' "$engine_dir"
cat <<'APPEOF'
rm -rf "$engine_dir"
mkdir -p "$engine_dir"
ln -sf "$APPDIR"/usr/lib/bbport-glibc/* "$engine_dir"/
ln -sf "$APPDIR"/usr/lib/*.so* "$engine_dir"/
# The patched port binaries must never be routed through an explicit loader (their PT_INTERP names
# the bundled loader already): keep run.sh's bb_ld hook and the launcher's staged_tool_command
# plain by leaving these unset, even if the host injected them.
unset BB_LD BB_LD_LIBRARY_PATH

export BB_DATA_DIR=${BB_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bbport}
mkdir -p "$BB_DATA_DIR"

# Game data sidecar: a folder next to the AppImage (never copied into the image). Hand the first
# layout that actually holds the game to run.sh and to the launcher (BB_GAME_DIR).
if [[ -z ${BB_GAME_DIR:-} ]]; then
    for candidate in "$(dirname -- "$APPIMAGE")/gamedata/CUSA03173" \
                     "$(dirname -- "$APPIMAGE")/CUSA03173" \
                     "$APPDIR/usr/share/CUSA03173"; do
        if [[ -f $candidate/eboot.bin ]]; then
            export BB_GAME_DIR=$candidate
            break
        fi
    done
fi

pkg=$APPDIR/usr/share/bbport

# --play: the game alone, exactly as Stage 1 (settings from bbport.ini and the environment).
if [[ ${1:-} == --play ]]; then
    exec bash "$pkg/run.sh" "${@:2}"
fi

# --- GTK4 launcher ----------------------------------------------------------------------------
# The launcher uses the host's python3/PyGObject/GTK4/gdk-pixbuf; libadwaita is bundled in
# usr/lib/launcher and the whole process runs through the bundled glibc loader so the bundled
# libadwaita works everywhere. usr/lib (the app-private Arch libraries) must NOT be on the
# launcher's library path: it would shadow the host's GTK4/glib. Only bbport-glibc and
# usr/lib/launcher are.
gui_libs="$APPDIR/usr/lib/bbport-glibc:$APPDIR/usr/lib/launcher"
# The bundled Adw typelib first: gi.require_version("Adw", "1") must find it even though the host
# (SteamOS) has none. Gtk comes from the host's default typelib search path.
export GI_TYPELIB_PATH="$APPDIR/usr/lib/launcher/girepository-1.0${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
if [[ -d $APPDIR/usr/share/glib-2.0/schemas ]]; then
    export GSETTINGS_SCHEMA_DIR="$APPDIR/usr/share/glib-2.0/schemas${GSETTINGS_SCHEMA_DIR:+:$GSETTINGS_SCHEMA_DIR}"
fi
# gamescope/XWayland safety on the Deck; an explicit GDK_BACKEND still wins.
export GDK_BACKEND=${GDK_BACKEND:-x11}

# First python3 with PyGObject and GTK4. Adw is the one bundled here: only its typelib is required
# (found through GI_TYPELIB_PATH above), never a host libadwaita.
gui_python=${BB_LAUNCHER_PYTHON:-}
if [[ -z $gui_python ]]; then
    for candidate in /usr/bin/python3 python3; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        if "$candidate" -c 'import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk; gi.require_version("Adw", "1")' >/dev/null 2>&1; then
            gui_python=$(command -v "$candidate")
            break
        fi
    done
fi
if [[ -z $gui_python ]]; then
    echo 'bbport: no python3 with PyGObject/GTK4 found; set BB_LAUNCHER_PYTHON' >&2
    exit 1
fi

# bbport_vulkan.py <program> [args...]: it configures the Vulkan ICDs and then execs <program> (the
# same contract packaging/default.nix uses), so the game started from the window inherits the
# prepared environment. Here <program> is the bundled loader running the host python3, keeping the
# launcher on the bundled glibc; bbport_vulkan re-execs through the loader the same way. The port
# binaries the launcher starts are patched (PT_INTERP) and run directly: BB_LD is never set.
gui_loader="$engine_dir/ld-linux-x86-64.so.2"
exec "$gui_loader" --library-path "$gui_libs" "$gui_python" \
    "$pkg/launcher/bbport_vulkan.py" \
    "$gui_loader" --library-path "$gui_libs" "$gui_python" "$pkg/launcher/bbport_launcher.py" "$@"
APPEOF
} > "$appdir/AppRun"
chmod 755 "$appdir/AppRun"

# --- Desktop entry and icon -------------------------------------------------------------------
mkdir -p "$appdir/usr/share/applications"
cat > "$appdir/usr/share/applications/bbport.desktop" <<'DESKTOPEOF'
[Desktop Entry]
Type=Application
Name=Bloodborne (bbport)
Comment=Bloodborne port (experimental)
Exec=bbport
Icon=bbport
Categories=Game;
Terminal=false
DESKTOPEOF
ln -sf usr/share/applications/bbport.desktop "$appdir/bbport.desktop"

# Placeholder icon: no icon asset in the repository, so generate a 256x256 PNG (never fail for it).
icon_src=
for candidate in "$root"/launcher/bbport.png "$root"/launcher/*.png "$root"/docs/*.png; do
    [[ -f $candidate ]] && { icon_src=$candidate; break; }
done
if [[ -n $icon_src ]]; then
    install -m644 "$icon_src" "$appdir/bbport.png"
elif command -v python3 >/dev/null 2>&1; then
    # The placeholder generation must never fail the build (there is no icon asset in the repo).
    python3 - "$appdir/bbport.png" <<'PYEOF' || echo 'icon: placeholder generation failed; building without an icon' >&2
import math, struct, sys, zlib
path = sys.argv[1]
size = 256
raw = bytearray()
for y in range(size):
    raw.append(0)  # PNG filter: none
    for x in range(size):
        d = min(1.0, math.hypot((x - size / 2) / (size / 2), (y - size / 2) / (size / 2)))
        raw += bytes((int(150 * (1 - d) + 20), int(20 * (1 - d)), int(25 * (1 - d))))

def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)

png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
       + chunk(b'IEND', b''))
with open(path, 'wb') as f:
    f.write(png)
PYEOF
else
    echo 'icon: no icon asset and no python3; building without an icon' >&2
fi
if [[ -f $appdir/bbport.png ]]; then
    ln -sf bbport.png "$appdir/.DirIcon"
fi

# --- Package ----------------------------------------------------------------------------------
# The installed appimagetool (2020) only understands gzip/xz; try zstd first as requested and fall
# back to its default when the compression options are unsupported.
log=$root/out/appimage-native/appimagetool.log
if ! ARCH=x86_64 appimagetool --comp zstd -Xcompression-level 3 "$appdir" "$image" >"$log" 2>&1; then
    echo 'appimagetool: zstd options unavailable, using its default compression' >&2
    if ! ARCH=x86_64 appimagetool "$appdir" "$image" >>"$log" 2>&1; then
        echo 'appimagetool failed:' >&2
        cat "$log" >&2
        exit 1
    fi
fi

echo "AppDir: $(du -sh "$appdir" | cut -f1) ($appdir)"
echo "Artifact: $image ($(du -h "$image" | cut -f1))"
