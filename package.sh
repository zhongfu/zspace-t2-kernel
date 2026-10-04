#!/usr/bin/env bash
#
# Build the three ZSpace T2 kernel Debian packages from build.sh's output.
#
# A hand-written DEBIAN/ control directory plus `dpkg-deb --build`, exactly the
# style the t2-utils package's build.sh (in the utils repository) uses and for
# the same reasons: the build image has dpkg but not dpkg-dev, and the payloads
# are file trees plus one maintainer script, so debhelper's dh_* machinery would
# add a build dependency and a source package nobody builds.
# `--root-owner-group` normalises the uid/gid, and SOURCE_DATE_EPOCH pins every
# ar/tar member mtime, so the same inputs build the same .deb bytes.
#
# Inputs (all build.sh outputs, all read-only here):
#   $T2_KERNEL_TREE/include/config/auto.conf   the configured tree
#   $T2_KERNEL_OUT/Image, rk3568-t2.dtb        the kernel and the board DTB
#   $T2_KERNEL_OUT/modules/lib/modules/<rel>/  the module tree
# The headers come from the kernel tree itself, through the kernel's own
# scripts/package/install-extmod-build (the same script `make deb-pkg` uses):
# it copies the Kbuild files, the headers and the built host programs, and
# knows which of them a module build needs.
#
# Usage: package.sh
#   T2_KERNEL_TREE     kernel tree           (default: <repo>/build/kernel)
#   T2_KERNEL_OUT      build.sh's output dir (default: <repo>/build/out)
#   T2_KERNEL_MODULES  module tree to package (default: <out>/modules/lib/modules/<rel>)
#   T2_KERNEL_DEBS     where the .debs go    (default: <repo>/build/debs)
#   T2_KERNEL_ABI      Debian revision       (default: 1)
#
# The release string and the Debian version are derived, never configured; see
# README.md.  A config-only rebuild that must supersede the previous packages
# bumps T2_KERNEL_ABI (T2_KERNEL_ABI=2 package.sh).
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

tree=${T2_KERNEL_TREE:-$here/build/kernel}
out=${T2_KERNEL_OUT:-$here/build/out}
debs=${T2_KERNEL_DEBS:-$here/build/debs}
abi=${T2_KERNEL_ABI:-1}
arch=arm64

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Build the ZSpace T2 kernel Debian packages from build.sh's output.

Environment:
  T2_KERNEL_TREE     kernel tree            (default: $tree)
  T2_KERNEL_OUT      build.sh output dir    (default: $out)
  T2_KERNEL_MODULES  module tree to package (default: $out/modules/lib/modules/<rel>)
  T2_KERNEL_DEBS     where the .debs go     (default: $debs)
  T2_KERNEL_ABI      Debian revision        (default: $abi)
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

case ${1:-} in
    -h|--help)
        usage
        exit 0
        ;;
    '')
        ;;
    *)
        echo "error: unexpected argument: $1" >&2
        usage >&2
        exit 2
        ;;
esac

case $abi in
    ''|*[!0-9]*) die "T2_KERNEL_ABI must be a number, got '$abi'" ;;
esac

[ -f "$tree/Makefile" ] || die "no kernel tree at $tree - run fetch.sh then build.sh"
[ -f "$tree/include/config/auto.conf" ] ||
    die "$tree is not configured - run build.sh first"
[ -f "$out/Image" ] || die "no $out/Image - run build.sh first"
[ -f "$out/rk3568-t2.dtb" ] || die "no $out/rk3568-t2.dtb - run build.sh first"

# --- release string --------------------------------------------------------
# `make kernelrelease` is the one authority for the release string (contract
# §3.3).  LOCALVERSION= matches build.sh: it stops scripts/setlocalversion from
# appending -g<hash>/+ for a git tree that is not exactly at the tagged commit.
# The result names the packages, the module directory and the vermagic, so
# refuse anything that could not be a directory name.
rel=$(make -s -C "$tree" ARCH="$arch" LOCALVERSION= kernelrelease 2>/dev/null | tail -n1)
case $rel in
    ''|*[!0-9A-Za-z._-]*) die "make kernelrelease gave '$rel', not a usable release string" ;;
esac

modtree=${T2_KERNEL_MODULES:-$out/modules/lib/modules/$rel}
[ -d "$modtree" ] ||
    die "no module tree at $modtree (release $rel) - run build.sh first, or point T2_KERNEL_MODULES at one"
if [ "${modtree##*/}" != "$rel" ]; then
    # The package always installs the tree as /lib/modules/$rel, so a tree
    # whose own directory name differs was built with a different release
    # string and its modules carry that vermagic.  Say so: the Image and the
    # modules only pair up when both were built with this release.
    echo "warning: module tree '$modtree' is named '${modtree##*/}', not '$rel';" >&2
    echo "         installing it as /lib/modules/$rel anyway" >&2
fi

# --- Debian version --------------------------------------------------------
# VERSION/PATCHLEVEL/SUBLEVEL/EXTRAVERSION are the kernel's own, so the version
# follows a base-version bump without anyone remembering to edit it.  The
# sublevel is dropped when it is 0, and EXTRAVERSION goes behind a `~`: an rc
# must sort *before* the final release, so 7.3.0-rc5 is 7.3~rc5 (dpkg orders
# '~' before the empty string), not 7.3rc5 (which would sort after 7.3).
# T2_KERNEL_ABI is the Debian revision - the knob a config-only rebuild bumps.
kv=$(sed -n 's/^VERSION = //p' "$tree/Makefile" | head -n1)
kp=$(sed -n 's/^PATCHLEVEL = //p' "$tree/Makefile" | head -n1)
ks=$(sed -n 's/^SUBLEVEL = //p' "$tree/Makefile" | head -n1)
ke=$(sed -n 's/^EXTRAVERSION = //p' "$tree/Makefile" | head -n1)
[ -n "$kv" ] && [ -n "$kp" ] && [ -n "$ks" ] ||
    die "cannot read VERSION/PATCHLEVEL/SUBLEVEL from $tree/Makefile"

upstream=$kv.$kp
[ "$ks" = 0 ] || upstream=$upstream.$ks
if [ -n "$ke" ]; then
    extra=$(printf '%s' "${ke#-}" | sed 's/[^0-9A-Za-z.]//g')
    [ -n "$extra" ] && upstream=$upstream~$extra
fi
version=$upstream-$abi

# The package names are the contract §4 artefact names -
# linux-image-7.3.0-rc5-t2_7.3~rc5-1_arm64.deb.  $rel already ends in the local
# version (-t2, from CONFIG_LOCALVERSION), so the `-t2` in §5's
# "linux-image-<rel>-t2" template is that suffix, not a second one.
image_name=linux-image-$rel
modules_name=linux-modules-$rel
headers_name=linux-headers-$rel

echo "== kernel packages =="
echo "  release : $rel"
echo "  version : $version"
echo "  modules : $modtree"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

# build_deb DIR NAME: put DIR's DEBIAN/control.in through sed (it carries
# @REL@, @VERSION@ and @INSTALLED_SIZE@), then build the package.
build_deb() { # DIR NAME
    dir=$1
    name=$2
    # --apparent-size: Installed-Size is the size of the installed files, and a
    # plain `du -sk` reports the *allocated* blocks, which lies when the staging
    # directory sits on a filesystem that reports compressed/sparse usage (ZFS
    # gives the 27 MB Image a handful of KiB) instead of the file sizes.
    size=$(du -sk --apparent-size "$dir" | cut -f1)
    sed -e "s/@REL@/$rel/g" \
        -e "s/@VERSION@/$version/g" \
        -e "s/@INSTALLED_SIZE@/$size/g" \
        "$dir/DEBIAN/control.in" > "$dir/DEBIAN/control"
    rm -f "$dir/DEBIAN/control.in"
    : "${SOURCE_DATE_EPOCH:=0}"
    export SOURCE_DATE_EPOCH
    dpkg-deb --root-owner-group --build "$dir" "$debs/${name}_${version}_${arch}.deb" >/dev/null
    echo "$debs/${name}_${version}_${arch}.deb"
}

mkdir -p "$debs"

# --- linux-image -----------------------------------------------------------
# The rootfs files are plain: /boot/Image with no initramfs, and the DTB next
# to it.  The postinst turns them (plus the t2-initramfs package's initramfs)
# into the boot tree's FIT.
img_dir=$work/image
mkdir -p "$img_dir/DEBIAN" "$img_dir/boot"
cp "$here/packaging/linux-image/control.in" "$img_dir/DEBIAN/control.in"
sed -e "s/@REL@/$rel/g" "$here/packaging/linux-image/postinst.in" > "$img_dir/DEBIAN/postinst"
chmod 755 "$img_dir/DEBIAN/postinst"
cp "$out/Image" "$img_dir/boot/Image"
cp "$out/rk3568-t2.dtb" "$img_dir/boot/rk3568-t2.dtb"

# --- linux-modules ---------------------------------------------------------
# The module tree keeps the release directory name; `build`/`source` are
# symlinks modules_install leaves pointing at the build host's tree, and the
# headers package owns /lib/modules/<rel>/build (as Debian's does), so drop
# them here.
mod_dir=$work/modules
mkdir -p "$mod_dir/DEBIAN" "$mod_dir/lib/modules"
cp -a "$modtree" "$mod_dir/lib/modules/$rel"
rm -f "$mod_dir/lib/modules/$rel/build" "$mod_dir/lib/modules/$rel/source"
cp "$here/packaging/linux-modules/control.in" "$mod_dir/DEBIAN/control.in"

# --- linux-headers ---------------------------------------------------------
# install-extmod-build wants to run from the tree (it reads include/config/
# auto.conf relative to the cwd and tars from $srctree), and it only ever
# writes to the destination.  CC=HOSTCC keeps it from rebuilding the host
# programs for a cross target; the tree already carries them built.
hdr_dir=$work/headers
mkdir -p "$hdr_dir/DEBIAN" "$hdr_dir/usr/src/linux-headers-$rel"
cc=${HOSTCC:-cc}
if ! ( cd "$tree" && srctree="$tree" SRCARCH="$arch" CC="$cc" HOSTCC="$cc" MAKE=make \
        scripts/package/install-extmod-build "$hdr_dir/usr/src/linux-headers-$rel" ); then
    die "the kernel's scripts/package/install-extmod-build failed"
fi

# The release baked into the headers must be the one the package is named
# after, or a module built against them would carry a vermagic the Image
# rejects.  In a normal build the tree already says $rel and this is a no-op;
# it also repairs a tree whose config metadata predates the change.
printf '%s\n' "$rel" > "$hdr_dir/usr/src/linux-headers-$rel/include/config/kernel.release"
printf '#define UTS_RELEASE "%s"\n' "$rel" \
    > "$hdr_dir/usr/src/linux-headers-$rel/include/generated/utsrelease.h"
# Build out-of-tree modules against the same config the Image was built with.
cp "$here/config/kernel.config" "$hdr_dir/usr/src/linux-headers-$rel/.config"

# The conventional entry point: what /lib/modules/<rel>/build has always
# pointed at (a rootfs symlink, unlike the boot tree - the FAT rule does not
# apply here).
mkdir -p "$hdr_dir/lib/modules/$rel"
ln -s "/usr/src/linux-headers-$rel" "$hdr_dir/lib/modules/$rel/build"
cp "$here/packaging/linux-headers/control.in" "$hdr_dir/DEBIAN/control.in"

echo "== building the packages =="
build_deb "$img_dir" "$image_name"
build_deb "$mod_dir" "$modules_name"
build_deb "$hdr_dir" "$headers_name"
