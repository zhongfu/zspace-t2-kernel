# Kernel

The Linux kernel for the ZSpace T2 (Rockchip RK3568): the mainline tree at tag
**v7.3-rc5** plus five patches, the board config, and the `linux-image`,
`linux-modules` and `linux-headers` Debian packages. [`patches/README.md`](patches/README.md)
documents the patches.

## Patch set

| Patch | Purpose |
|---|---|
| `0001-pci-dw-rockchip-power-cycle-endpoint-on-link-retry` | power-cycle the PCIe endpoint and retry link training (AP6275P WiFi quirk) |
| `0002-arm64-dts-rockchip-add-rk3568-t2` | the `rk3568-t2` board device tree and its `Makefile` entry |
| `0003-media-dt-bindings-rockchip-add-rk3568-video-decoder` | device-tree bindings for the RK3568 VDPU346 video decoder |
| `0004-media-rkvdec-add-support-for-the-vdpu346-variant` | `rkvdec` driver support for the VDPU346 variant (HEVC) |
| `0005-arm64-dts-rockchip-add-the-vdpu346-video-decoders-on-rk356x` | enable the VDPU346 decoders in `rk356x-base.dtsi` |

## Build

You need `git`, GNU make, `bc`, `bison`, `flex`, `libssl-dev`, `libelf-dev`,
`zstd` and a compiler. On an arm64 host it is native (`CROSS_COMPILE=`); on any
other host the `aarch64-linux-gnu-` cross toolchain (the default).

```sh
./fetch.sh      # clone mainline v7.3-rc5 into build/kernel (depth 1)
./build.sh      # apply the patches, configure, build, install into build/out
./package.sh    # build the three .deb packages into build/debs
```

`build.sh` applies `patches/*.patch` with `git am`, copies
`config/kernel.config` over `build/kernel/.config`, runs `make olddefconfig`,
builds `Image`, `dtbs` and `modules`, and installs into `build/out/`:

* `Image` — the plain arm64 kernel image
* `rk3568-t2.dtb` — the board device tree
* `modules/lib/modules/<rel>/` — the module tree

`ARCH` (default `arm64`), `CROSS_COMPILE` (default `aarch64-linux-gnu-`; empty
selects a native arm64 build), and `JOBS` can be overridden in the environment.
`build.sh` re-runs on a tree that already carries every patch, so a failed or
partial build can be restarted; a tree carrying only some of them is an error.

## Why the Image carries no initramfs

`CONFIG_INITRAMFS_SOURCE` is empty and `build.sh` never points it at a tree.
Two boot FITs — kernel + device tree + one ramdisk each — are assembled at
image-build time, and by the `linux-image` postinst for on-board upgrades, with
`t2-mkfit` (which `t2-utils` ships): the card's `/Image` carries the installer
ramdisk, the eMMC's `/Image` (from `/Image.emmc`) carries the initramfs-tools
image.
The reason is coupling: the installer ramdisk carries the installer, which is
iterated constantly and is tied to the rootfs image format, so embedding it
would make every installer tweak a kernel rebuild and make the two repositories
depend on each other. The kernel repository builds a kernel; the boot FITs are
someone else's build step.

The installer ramdisk itself lives in the image repository (`t2-initramfs`,
installed on the board as `/boot/initramfs-t2.gz`). The `linux-image` packages
here `Depends: t2-initramfs` so the postinst has a ramdisk to fall back on: it
prefers the distribution's `/boot/initrd.img-<rel>`, which the rootfs build and
`update-initramfs` provide.

## Release string and package version

The release string is whatever `make kernelrelease` prints, and the config pins
it: `CONFIG_LOCALVERSION="-t2"` and `CONFIG_LOCALVERSION_AUTO=n`, so it is
`7.3.0-rc5-t2` for this base. It names the module directory, the packages'
`<rel>` and the vermagic, so it has to be stable across commits — that is why
`LOCALVERSION_AUTO` is off (`-g<hash>` would change every commit).

`build.sh` and `package.sh` pass `LOCALVERSION=` to make on purpose. The config
already carries the whole local version, but `scripts/setlocalversion` appends
its own suffix when the build tree is a git checkout that is not exactly at the
tagged commit — and ours never is, because the patches are commits on top of
v7.3-rc5. The empty make variable is the kernel's documented way to say "no VCS
suffix", and it leaves `CONFIG_LOCALVERSION` alone.

The Debian version in `package.sh` is derived from the kernel's own
`VERSION`/`PATCHLEVEL`/`SUBLEVEL`/`EXTRAVERSION`, so a base-version bump needs
no edit here:

| `Makefile` | derived upstream | why |
|---|---|---|
| `7.3.0` | `7.3` | the sublevel is dropped when it is 0 |
| `7.3.0-rc5` | `7.3~rc5` | `~` sorts an rc *before* the final `7.3` |
| `7.4.2` | `7.4.2` | sublevel kept when it is not 0 |

The Debian revision is `T2_KERNEL_ABI`, default `2`
(`linux-image-7.3.0-rc5-t2_7.3~rc5-2_arm64.deb`). It is the knob for a rebuild
that must supersede the packages already installed: bump it
(`T2_KERNEL_ABI=3 ./package.sh`) without changing the source.

## The packages

`package.sh` builds them with a hand-written `DEBIAN/` directory and `dpkg-deb`
(no debhelper), the same way `t2-utils` is built. Their contents are the
contract in `split-contract.md` §5:

* `linux-image-<rel>` — `/boot/Image` (plain, no initramfs) and
  `/boot/rk3568-t2.dtb`; `Depends: t2-utils, t2-initramfs`. Its postinst
  assembles the eMMC boot FIT and installs it into the boot tree, honouring the
  A/B rules (`/Image` primary, the previous kernel promoted to `/Image.old`, the
  boot counter armed only when `/Image.old` exists).
* `linux-modules-<rel>` — `/lib/modules/<rel>/`, `Depends:
  linux-image-<rel> (= <version>)` so the two can never drift.
* `linux-headers-<rel>` — the prepared out-of-tree build tree under
  `/usr/src/linux-headers-<rel>/`, plus `/lib/modules/<rel>/build` pointing at
  it.

`<rel>` is the release string, and it already ends in `-t2` (from
`CONFIG_LOCALVERSION`), so the names are `linux-image-7.3.0-rc5-t2` and
`/lib/modules/7.3.0-rc5-t2/` — the contract §4 artefact names.

### The boot tree (T2_BOOT_DIR)

`/boot` is an ordinary directory in the rootfs; it is **not** the boot
partition. The board's boot partition is FAT, and nothing mounts it at a fixed
path — `t2-utils`' `t2-boot-commit.sh` mounts it on demand. The postinst
therefore addresses the boot tree with `T2_BOOT_DIR`, which has **no default**:
unset (the image-build chroot, and every board today) it logs that it skipped
and exits 0, and the installer writes the boot tree; set, that directory is the
boot tree, which is also how the postinst is tested without a board. Partition
discovery stays out of this package.

In the boot tree the postinst writes only plain files — FAT has no symlinks or
hardlinks: the FIT as `/Image`, the device tree as `/rk3568-t2.dtb`, and
`/extlinux/extlinux.conf`, regenerated the way `images/t2-boot-fat.py` builds it
at image-build time. It skips a directory that is neither empty nor a boot tree
rather than risk filling an unmounted mount point.

`T2_IMAGE`, `T2_DTB`, `T2_INITRAMFS`, `T2_MKFIT` and `T2_MODULES_DIR` point the
postinst's inputs, its FIT assembler and the module check elsewhere, so the
whole script can be exercised against a plain temporary directory with a stub
`t2-mkfit`, no board and no root.

## CI

`.github/workflows/build.yml` runs fetch, build and package on an arm64 runner
and inspects every `.deb` with `dpkg-deb -I`/`-c`. `.github/workflows/release.yml`
does the same on a `v*` tag and publishes the three packages together with the
raw `Image` and `rk3568-t2.dtb`, which the image build needs for its own FIT.
