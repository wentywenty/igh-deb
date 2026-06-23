#!/bin/bash
set -e

SRC_DIR="$1"
DST_DIR="$2"
PKG_VER="1.7.1"

if [ -z "$SRC_DIR" ] || [ -z "$DST_DIR" ]; then
    echo "Usage: $0 <ethercat-source-dir> <dkms-staging-dir>"
    exit 1
fi

rm -rf "$DST_DIR"
DST="$DST_DIR"
mkdir -p "$DST"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# --- Copy kernel module source tree (all drivers) ---
copy_src() {
    local sub="$1"
    mkdir -p "$DST/$sub"
    if [ -d "$SRC_DIR/$sub" ]; then
        find "$SRC_DIR/$sub" -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' -o -name 'Kbuild.in' \) \
            ! -name '*.mod.c' ! -name '*.o' ! -name '*-orig.c' ! -name '*-orig.h' | while read f; do
            cp "$f" "$DST/$sub/"
        done
    fi
    # All sub-driver directories
    if [ -d "$SRC_DIR/$sub" ]; then
        for d in "$SRC_DIR/$sub"/*/; do
            [ -d "$d" ] || continue
            local name=$(basename "$d")
            mkdir -p "$DST/$sub/$name"
            find "$d" -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' -o -name 'Kbuild.in' \) \
                ! -name '*.mod.c' ! -name '*.o' ! -name '*-orig.c' ! -name '*-orig.h' | while read f; do
                cp "$f" "$DST/$sub/$name/"
            done
        done
    fi
}

copy_src "master"
copy_src "devices"

mkdir -p "$DST/include"
cp "$SRC_DIR/include/"*.h "$DST/include/" 2>/dev/null || true
cp "$SRC_DIR/globals.h" "$DST/"

# --- Kbuild.in -> Kbuild conversion ---
compute_depth() {
    local rel="$1"
    case "$rel" in
        .) echo "." ;;
        *)   local slash_count=$(echo "$rel" | tr -cd '/' | wc -c)
             local count=$((slash_count + 1))
             local d="" i
             for i in $(seq 1 $count); do d="${d}../"; done
             echo "${d%/}" ;;
    esac
}

convert_kbuild() {
    local infile="$1"
    local outfile="${infile%.in}"
    local rel="${outfile#$DST/}"
    local dir=$(dirname "$rel")
    local depth=$(compute_depth "$dir")

    sed \
        -e "/^src := @abs_srcdir@$/d" \
        -e "s|@abs_srcdir@|\$(src)|g" \
        -e "s|@abs_top_builddir@|\$(src)/$depth|g" \
        -e 's|\$(LINUX_SYMVERS)|Module.symvers|g' \
        -e 's|@RTAI_MODULE_DIR@|/dev/null|g' \
        -e 's|@ENABLE_EOE@||g' \
        -e 's|@ENABLE_RTDM@||g' \
        -e 's|@ENABLE_XENOMAI@||g' \
        -e 's|@ENABLE_XENOMAI_V3@||g' \
        -e 's|@ENABLE_RTAI@||g' \
        -e 's|@ENABLE_DEBUG_IF@||g' \
        -e 's|@ENABLE_TTY@||g' \
        -e 's|@ENABLE_DRIVER_RESOURCE_VERIFYING@||g' \
        -e 's|@LINUX_SYMVERS@|Module.symvers|g' \
        -e 's|@ENABLE_GENERIC@|1|g' \
        -e 's|@ENABLE_IGB@|1|g' \
        -e 's|@ENABLE_8139TOO@|1|g' \
        -e 's|@ENABLE_E100@|1|g' \
        -e 's|@ENABLE_E1000@|1|g' \
        -e 's|@ENABLE_E1000E@||g' \
        -e 's|@ENABLE_IGC@|1|g' \
        -e 's|@ENABLE_R8169@|1|g' \
        -e 's|@ENABLE_GENET@|1|g' \
        -e 's|@ENABLE_STMMAC@|1|g' \
        -e 's|@ENABLE_CCAT@|1|g' \
        -e 's|@KERNEL_[A-Z0-9_]*@|\$(KERNEL_MATCH_DRIVER)|g' \
        -e 's|@R8169_IN_SUBDIR@|1|g' \
        -e 's|@HAS_IGC_LEDS@|\$(shell test -f \$(src)/igc_leds-\$(KERNEL_MATCH_DRIVER)-ethercat.c \&\& echo 1 \|\| echo 0)|g' \
        -e 's|@HAS_R8169_LEDS@|\$(shell test -f \$(src)/r8169_leds-\$(KERNEL_MATCH_DRIVER)-ethercat.c \&\& echo 1 \|\| echo 0)|g' \
        "$infile" > "$outfile"
}

# Top-level Kbuild
if [ -f "$SRC_DIR/Kbuild.in" ]; then
    cp "$SRC_DIR/Kbuild.in" "$DST/Kbuild.in"
    sed -i 's|obj-m := .*|obj-m := master/ devices/|' "$DST/Kbuild.in"
    convert_kbuild "$DST/Kbuild.in"
    rm -f "$DST/Kbuild.in"
fi

# All sub-Kbuild files
find "$DST" -name "Kbuild.in" | while read kbi; do
    [ -f "$kbi" ] || continue
    convert_kbuild "$kbi"
    rm -f "$kbi"
done

# --- Inject kernel version auto-detection into every driver Kbuild ---
DETECT_BLOCK='
_KMAJ := $(word 1,$(subst ., ,$(KERNELRELEASE)))
_KMIN := $(word 2,$(subst ., ,$(KERNELRELEASE)))
_KSHORT := $(_KMAJ).$(_KMIN)

KERNEL_MATCH_DRIVER := $(shell \
	_files=$$(ls $(src)/*-ethercat.c 2>/dev/null); \
	_vers=$$(echo "$$_files" | grep -oE "[0-9]+\.[0-9]+" | sort -uV); \
	if [ -n "$$_vers" ]; then \
		_best=$$(echo "$$_vers" | grep -F "$(_KSHORT)" | head -1); \
	else \
		_best=unknown; \
	fi; \
	[ -z "$$_best" ] && _best=unknown; \
	echo "$$_best"; \
)

ifneq ($(KERNEL_MATCH_DRIVER),unknown)
HAVE_DRIVER := 1
else
HAVE_DRIVER := 0
endif
'

inject_detect_top() {
    local kbuild_file="$1"
    [ -f "$kbuild_file" ] || return
    if ! grep -q 'KERNEL_MATCH_DRIVER' "$kbuild_file"; then return; fi
    local tmp=$(mktemp)
    echo "$DETECT_BLOCK" > "$tmp"
    cat "$kbuild_file" >> "$tmp"
    mv "$tmp" "$kbuild_file"
}

inject_detect_sub() {
    local kbuild_file="$1"
    [ -f "$kbuild_file" ] || return
    if ! grep -q 'KERNEL_MATCH_DRIVER' "$kbuild_file"; then return; fi
    local tmp=$(mktemp)
    echo "$DETECT_BLOCK" > "$tmp"
    sed 's/ifeq (1,1)/ifeq ($(HAVE_DRIVER),1)/' "$kbuild_file" >> "$tmp"
    mv "$tmp" "$kbuild_file"
}

# Top-level devices/Kbuild: inject KERNEL_MATCH_DRIVER but DON'T wrap generic driver
inject_detect_top "$DST/devices/Kbuild"

# Sub-driver Kbuilds: inject detection + HAVE_DRIVER conditional skip
find "$DST/devices" -name Kbuild -path "*/devices/*/Kbuild" | while read kb; do
    inject_detect_sub "$kb"
done

# --- Copy DKMS packaging files ---
cp "$SCRIPT_DIR/../dkms.conf" "$DST/"
cp "$SCRIPT_DIR/../dkms-config.h" "$DST/config.h"
cp "$SCRIPT_DIR/../dkms-makefile" "$DST/Makefile"

echo "DKMS source assembled at $DST"
