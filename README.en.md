# EX Emulators: build for the Samsung Galaxy Pocket Plus (GT-S5301L)

*[Español](README.md) · English*

Fork of [EX Emulators (emu-ex-plus-alpha)](https://github.com/Rakashazi/emu-ex-plus-alpha) by
**Robert Broglia** with the changes needed to build **GBA.emu** and **GBC.emu** with a current
toolchain (Clang 23 / C++26 / CMake 4.4) and get them running smoothly on a
**Samsung Galaxy Pocket Plus (GT-S5301L)** with Android 4.0.4.

- Base: upstream `1c12fac5c` (v1.5.85). The changes live in the `pocket-plus` branch.
- Fork maintainer: Bautista D. Fiori.
- The project's original README is in [`README.upstream.md`](README.upstream.md).

> If your device is a normal, modern Android, use the author's official builds (Google Play
> or the nightlies; the links are in [`README.upstream.md`](README.upstream.md)) and support his work. This fork only makes sense for
> old single-core ARMv7 hardware like the Pocket Plus.

This repository **does not include or distribute ROMs**. Only use copies of games you own.

---

## Target device

| | |
|---|---|
| Model / board | Samsung `GT-S5301L` (`rhea_ss_coriplus`) |
| SoC | Broadcom BCM21654 |
| CPU | ARM Cortex-A9 r2p9, **single core** @ 850 MHz |
| `/proc/cpuinfo` | `swp half thumb fastmult vfp edsp neon vfpv3`: **no `idiva`/`idivt`** |
| Cache / RAM | 32 KB L1i + 32 KB L1d, 512 MB RAM |
| GPU / display | Broadcom VideoCore IV (OpenGL ES 2.0), 240×320 TFT |
| OS | Android 4.0.4 Ice Cream Sandwich (API 15) |

## Status

| App | Status on the GT-S5301L |
|---|---|
| GBC.emu | Tested on the device: runs smoothly and every touch button responds. |
| GBA.emu | Tested on the device with the performance tweaks below: works well. |

Audit of the generated `libmain.so` files (with [`pocket-plus/check-symbols.fish`](pocket-plus/check-symbols.fish)):

- Every undefined dynamic symbol (260 in GBA.emu, 241 in GBC.emu) exists in the
  `libc.so`, `libm.so`, `libEGL.so` and `libGLESv2.so` pulled from the phone itself.
- 0 `udiv`/`sdiv` instructions.
- APKs signed with *APK Signature Scheme v1* (JAR signing), in addition to v2.

---

## Download

Ready-to-install APKs are in [Releases](https://github.com/bafif/emu-ex-plus-alpha/releases)
(armeabi-v7a only, Android 2.3+, tested on the GT-S5301L). How to install them: see
[Installing on the Pocket Plus](#instalar-en-el-pocket-plus). If you'd rather build them yourself, follow
[Building](#compilar).

---

## Diagnosis

Everything that had to be solved to get a working build, in case it helps you with a similar
device.

### 1. The CPU has no hardware integer division

The BCM21654's Cortex-A9 r2p9 doesn't expose `idiva`/`idivt`. Any `udiv`/`sdiv` in the
binary ends in **`SIGILL`** as soon as it runs. That's why it's built with
`-march=armv7-a -mtune=cortex-a9` and **never** with `-march=armv7ve` or tuning for
Cortex-A7/A15. `check-symbols.fish` disassembles the `.so` and fails if it finds any.

### 2. Android 4.0 only accepts v1 signatures

Android 4.0's Package Manager rejects APKs signed only with the v2/v3 scheme
(`INSTALL_PARSE_FAILED_NO_CERTIFICATES`). With `minSdk 9`, `apksigner` adds the v1 signature. To
check:

```sh
apksigner verify --verbose app.apk   # it should say: Verified using v1 scheme (JAR signing): true
```

### 3. Binary compatibility with Bionic API 15

The build compiles against the NDK headers (`armv7-none-linux-androideabi21`,
`-DANDROID_COMPAT_API=9`) but links against the Bionic API 9 stubs shipped in
`imagine/bundle/android/`, with static `libc++`. To make sure no symbol the phone doesn't have
slips in, the undefined symbols in `libmain.so` are compared against the real libraries pulled
from the device with `adb pull` (see [Auditing the binary](#auditar-el-binario)).

### 4. Toolchain: the NDK's Clang isn't enough

The project uses **C++26 with standard modules** (`import std;`) and its own `libc++` 22. The
NDK r27c's Clang 18 is too old, so the **system Clang 23** is used with the NDK r27c
*sysroot*. That surfaced several compile errors, which this fork fixes:

- `imagine/src/base/android/surfaceTexture.cc`: the partition has `export namespace IG`, so
  it has to be declared `export module imagine.internal.android:surface;`.
- `imagine/src/base/android/Application.cc`: the `JNINativeMethod` table has `(void*)` casts
  to function pointers (a `reinterpret_cast`), which can't be `constexpr`; it becomes
  `static const`.
- `CMAKE_EXPERIMENTAL_CXX_IMPORT_STD` updated to the CMake 4.4.4 UUID
  (`f35a9ac6-8463-4d38-8eec-5d6008153e7d`) in `imagine/cmake/config.cmake` and
  `imagine/CMakePresets.json`.
- Outside the repo, in NDK r27c:
  `sysroot/usr/include/android/hardware_buffer.h:322` defines
  `AHARDWAREBUFFER_USAGE_FRONT_BUFFER = 1UL << 32`. On ARMv7 `unsigned long` is 32 bits and
  Clang 23 rejects it; it has to be changed to `1ULL << 32` (see [Preparing the host](#2-preparar-el-host)).

### 5. GBA.emu: the touch buttons didn't respond

In the first build, GBA.emu felt sluggish and taps did nothing. `adb logcat` showed:

```
E/NativeActivity: Failed to receive dispatch signal. status=-11
```

The ARM7TDMI interpreter was taking 100% of the single core and, when it fell behind,
`EmuSystemTask::advanceFrames` ran up to 4 frames in a row. That starved Android's main thread
(`ALooper`) of CPU, so it couldn't drain the `InputChannel`. The fixes:

| Change | File | Reason |
|---|---|---|
| At most 2 frames per cycle, always (before: up to 4 when more than 70 ms behind) | `EmuFramework/src/EmuSystemTask.cc` | Keep the emulation thread from starving the UI/input thread |
| Memory accesses (`CPURead*`, `CPUWrite*`, `CPUReadOpenBus`) and wait-state helpers as `noinline` | `GBA.emu/src/core/gba/gbaInline.h`, `gbaCpu.h` | Shrinks `libmain.so`'s `.text` by ~135 KB so the hot loop fits better in the 32 KB L1i |
| `gbaCpuArm.cpp` and `gbaCpuThumb.cpp` with `-Os` | `GBA.emu/src/CMakeLists.txt` | Same reason |
| `BLIP_BUFFER_FAST 1` (2-tap linear interpolation instead of 12-tap *sinc*) | `GBA.emu/src/core/apu/Blip_Buffer.h` | Less CPU spent on audio synthesis |
| One audio flush per frame (`VCOUNT == 159`) instead of 4, and a fixed 22050 Hz | `GBA.emu/src/core/gba/gba.cpp`, `src/main/AppMeta.cc` | Less audio work per frame |
| RGB565 rendering (`canRenderRGBA8888{false}`) | `GBA.emu/src/main/AppMeta.cc` | Half the texture bandwidth to the VideoCore IV and a 128 KB color table instead of 256 KB |

### 6. ADB drops out with the battery at 100%

With a full battery, the Pocket's USB port has micro-dropouts and the ADB transport goes
`offline` or disappears. `adb kill-server && adb start-server` gets it unstuck.
`push-rom.fish` does this on its own.

### Trade-offs of these changes

- The armv7 binaries **require NEON** (`-mfpu=neon`): they don't run on ARMv7 without NEON (Tegra 2, for example).
- The 2-frame limit lives in EmuFramework and affects every emulator built from
  this fork: if the device can't keep up, the game runs slower instead of skipping more frames.
- GBA.emu's audio loses some accuracy in exchange for speed.
- The build's `-j4` flags are meant for a 4-thread host; adjust them if you have more.

---

## Requirements

### On the PC (host)

Tested on Arch Linux x86_64. Any distro with the same versions should work.

- **Clang 23** with `lld` and the LLVM tools (`llvm-nm`, `llvm-readelf`, `llvm-objdump`).
- **CMake 4.4.4** (the `import std` UUID depends on the exact version), **Ninja**, GNU Make, `pkgconf`, GNU tar.
- **Android NDK r27c**.
- **Android SDK command-line tools** with `platform-tools`, `platforms;android-36` and `build-tools;36.0.0`.
- **JDK 17 or later** (Gradle 9).
- `arm-none-eabi-binutils` and `arm-none-eabi-gcc` (used as the GNU ARM assembler).
- `fish` for the scripts in `pocket-plus/`, and `unzip`.
- Plenty of RAM: with full LTO you'll want around 16 GB between RAM and swap/zram.
- A POSIX filesystem (ext4, btrfs…) for the code and the toolchain. **Don't** build
  on NTFS: it breaks symlinks and permissions.

### On the phone

- Samsung Galaxy Pocket Plus GT-S5301L with Android 4.0.4.
- **Settings → Developer options → USB debugging** enabled.
- **Settings → Security → Unknown sources** enabled.
- A USB cable and an SD card for the ROMs.

---

## Building

### 1. Environment variables

Example in `fish`. Replace the paths with your own:

```fish
set -gx IMAGINE_PATH ~/src/emu-ex-plus-alpha/imagine
set -gx IMAGINE_SDK_PATH ~/imagine-sdk
set -gx ANDROID_NDK_PATH ~/android/android-ndk-r27c
set -gx ANDROID_HOME ~/android/sdk
set -gx ANDROID_SDK_ROOT $ANDROID_HOME
set -gx ANDROID_CLANG_TOOLCHAIN_PATH /usr          # use the system Clang 23, not the NDK's
fish_add_path -gP $ANDROID_HOME/cmdline-tools/latest/bin $ANDROID_HOME/platform-tools ~/android/bin
```

### 2. Preparing the host

**a) ARMv7 runtime for Clang 23.** The system Clang doesn't ship `compiler-rt` or `libunwind`
for Android ARM. They're taken from the NDK:

```sh
sudo mkdir -p /usr/lib/clang/23/lib/armv7-none-linux-android21
NDKLIB=$ANDROID_NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/18/lib/linux
sudo ln -s $NDKLIB/libclang_rt.builtins-arm-android.a /usr/lib/clang/23/lib/armv7-none-linux-android21/libclang_rt.builtins.a
sudo ln -s $NDKLIB/arm/libunwind.a                     /usr/lib/clang/23/lib/armv7-none-linux-android21/libunwind.a
```

**b) GNU ARM assembler** under the name the build expects (in a directory on your `PATH`):

```sh
mkdir -p ~/android/bin
ln -s /usr/bin/arm-none-eabi-as  ~/android/bin/arm-none-linux-gnueabi-as
ln -s /usr/bin/arm-none-eabi-gcc ~/android/bin/arm-none-linux-gnueabi-gcc
```

**c) Patch to NDK r27c** (see [diagnosis 4](#4-toolchain-el-clang-del-ndk-no-alcanza)):

```sh
sed -i 's/AHARDWAREBUFFER_USAGE_FRONT_BUFFER = 1UL << 32/AHARDWAREBUFFER_USAGE_FRONT_BUFFER = 1ULL << 32/' \
  $ANDROID_NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/android/hardware_buffer.h
```

**d) Signing key.** To sign the release APK, set up `~/.gradle/gradle.properties`
as explained in [`imagine/doc/INSTALL-Android`](imagine/doc/INSTALL-Android)
(`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_STORE`, `ANDROID_KEY_STORE_PASSWORD`).

### 3. Building the dependencies, Imagine and EmuFramework (armv7 only)

```sh
git clone -b pocket-plus https://github.com/bafif/emu-ex-plus-alpha.git
cd emu-ex-plus-alpha

# Static libraries (libc++, libarchive, FLAC, Vorbis…) → $IMAGINE_SDK_PATH/android-armv7
(cd imagine/bundle/all && bash makeAll-android-armv7.sh install)

# Imagine engine + imagine-v9.aar
(cd imagine && ./android.sh --presets armv7 install)

# EmuFramework
(cd EmuFramework && ./android.sh --presets armv7 install)
```

### 4. Building and packaging the emulator

```sh
cd GBA.emu        # or GBC.emu
make -f android.mk android_arch=armv7 android_minSDK=9 android-apk -j4
```

The APK ends up in `build/android/build/outputs/apk/release/`.

> **Package ID.** By default the app installs with the same ID as the official one
> (`com.explusalpha.GbaEmu` / `com.explusalpha.GbcEmu`). If you already have the official one, uninstall it
> first: since the signature is different, Android won't let you replace it. The build accepts
> `android_metadata_id=<otro.id>` to use your own ID, but that variant hasn't been tested in
> this fork.

### Auditing the binary

Once, pull the libraries from the phone:

```fish
mkdir device-dump
for l in libc libm libEGL libGLESv2; adb pull /system/lib/$l.so device-dump/; end
```

After every build:

```fish
fish pocket-plus/check-symbols.fish GBA.emu/build/android/src/main/jniLibs/armeabi-v7a/libmain.so device-dump
```

It has to end with `Auditoría completada exitosamente`. If it lists missing symbols or
finds `udiv`/`sdiv`, the APK will crash on the phone.

---

## Installing on the Pocket Plus

1. Connect the phone over USB with USB debugging enabled and accept the RSA fingerprint if it shows up.
2. Check that it's visible:
   ```sh
   adb devices          # the device should be listed as "device"
   ```
   If it shows as `offline` or doesn't appear (typical with the battery at 100%):
   `adb kill-server && adb start-server`.
3. Install the APK (the one from [Releases](https://github.com/bafif/emu-ex-plus-alpha/releases) or the one you built):
   ```sh
   adb install -r GbaEmu-9-1.5.85-cortex-a9.apk     # or build/android/build/outputs/apk/release/GbaEmu-release.apk
   adb install -r GbcEmu-9-1.5.85-cortex-a9.apk
   ```
   You can also copy the APK to the SD card and open it from a file manager on the phone.
   If you get `INSTALL_PARSE_FAILED_NO_CERTIFICATES`, the APK is missing the v1 signature
   ([diagnosis 2](#2-android-40-sólo-acepta-firma-v1)). If you get `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
   or `ALREADY_EXISTS`, uninstall the official version first.

## Transferring ROMs: `push-rom`

[`pocket-plus/push-rom.fish`](pocket-plus/push-rom.fish) uploads ROMs to the phone's SD card. It checks
whether the file, or what's inside the `.zip`, is GB/GBC or GBA and copies it to
`/sdcard/ROMs/GBC/` or `/sdcard/ROMs/GBA/`. If ADB dropped out, it restarts the server and retries.

```fish
cp pocket-plus/push-rom.fish ~/.local/bin/push-rom   # optional, to have it as a command

push-rom ~/ROMs/juego.zip              # detects GBC/GBA on its own
push-rom --gbc ~/ROMs/juego.zip        # force the destination
push-rom --gba ~/ROMs/otro.zip
```

It needs `adb` on your `PATH`. If you have more than one device connected, specify which one:
`set -gx POCKET_SERIAL <serial de adb devices>`.

In the emulator, open the ROM from `/sdcard/ROMs/...`.

---

## Changes from the original

Modification notice (GPLv3 §5a). Files modified by Bautista D. Fiori on October 26, 2026
relative to upstream `1c12fac5c`:

- **Clang 23 / C++26 / CMake 4.4 toolchain:** `imagine/cmake/config.cmake`,
  `imagine/CMakePresets.json`, `imagine/src/base/android/surfaceTexture.cc`,
  `imagine/src/base/android/Application.cc`.
- **`-j4` parallelism:** `imagine/bundle/all/runMakefiles.sh`,
  `imagine/bundle/all/src/libcxx/common.mk`, `imagine/make/shortcut/meta-builds/android.mk`.
- **Cortex-A9 + NEON + lld:** `imagine/make/android-armv7-gcc.mk`,
  `imagine/cmake/android-armv7.cmake`, `imagine/make/android-gcc.mk`, `imagine/cmake/android.cmake`.
- **GBA.emu performance:** `EmuFramework/src/EmuSystemTask.cc`, `GBA.emu/src/CMakeLists.txt`,
  `GBA.emu/src/core/apu/Blip_Buffer.h`, `GBA.emu/src/core/gba/gba.cpp`,
  `GBA.emu/src/core/gba/gbaCpu.h`, `GBA.emu/src/core/gba/gbaInline.h`,
  `GBA.emu/src/main/AppMeta.cc`.
- **New:** this `README.md` and `pocket-plus/` (audit and ROM transfer scripts).
  The original README moved to `README.upstream.md`.

The details are in the commit history of the `pocket-plus` branch.

## Credits and license

- **Robert Broglia ([Rakashazi](https://github.com/Rakashazi))**: EX Emulators, Imagine,
  EmuFramework, GBA.emu and GBC.emu. All the underlying work is his.
- **VBA-M**: the Game Boy Advance core used by GBA.emu.
- **Gambatte**: the Game Boy / Game Boy Color core used by GBC.emu.
- **Blip_Buffer** (Shay Green): audio synthesis.
- Galaxy Pocket Plus tweaks: Bautista D. Fiori.

Like the original, it's distributed under the **GNU General Public License v3** (see
[`COPYING.GPL`](COPYING.GPL)). Each component keeps its own copyright and license notices.
"Game Boy" and "Game Boy Advance" are trademarks of Nintendo; this project is not affiliated with
Nintendo or Samsung.