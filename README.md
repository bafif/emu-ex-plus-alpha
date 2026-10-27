# EX Emulators — build para Samsung Galaxy Pocket Plus (GT-S5301L)

Fork de [EX Emulators (emu-ex-plus-alpha)](https://github.com/Rakashazi/emu-ex-plus-alpha) de
**Robert Broglia** con los ajustes necesarios para compilar **GBA.emu** y **GBC.emu** con un
toolchain actual (Clang 23 / C++26 / CMake 4.4) y hacerlos correr fluidos en un
**Samsung Galaxy Pocket Plus (GT-S5301L)** con Android 4.0.4.

- Base: upstream `1c12fac5c` (v1.5.85). Los cambios están en la rama `pocket-plus`.
- Mantenedor del fork: Bautista D. Fiori.
- El README original del proyecto está en [`README.upstream.md`](README.upstream.md).

> Si tu equipo es un Android normal y moderno, usá las builds oficiales del autor (Google Play
> o las nightly; los enlaces están en [`README.upstream.md`](README.upstream.md)) y apoyá su trabajo. Este fork sólo tiene sentido para hardware
> ARMv7 viejo de un solo núcleo como el Pocket Plus.

Este repositorio **no incluye ni distribuye ROMs**. Usá sólo copias de juegos que tengas.

---

## Equipo objetivo

| | |
|---|---|
| Modelo / placa | Samsung `GT-S5301L` (`rhea_ss_coriplus`) |
| SoC | Broadcom BCM21654 |
| CPU | ARM Cortex-A9 r2p9, **un solo núcleo** @ 850 MHz |
| `/proc/cpuinfo` | `swp half thumb fastmult vfp edsp neon vfpv3` — **sin `idiva`/`idivt`** |
| Caché / RAM | 32 KB L1i + 32 KB L1d, 512 MB RAM |
| GPU / pantalla | Broadcom VideoCore IV (OpenGL ES 2.0), TFT 240×320 |
| Sistema | Android 4.0.4 Ice Cream Sandwich (API 15) |

## Estado

| App | Estado en el GT-S5301L |
|---|---|
| GBC.emu | Probada en el equipo: corre fluida y responden todos los botones táctiles. |
| GBA.emu | Probada en el equipo con los ajustes de rendimiento de abajo: funciona bien. |

Auditoría de los `libmain.so` generados (con [`pocket-plus/check-symbols.fish`](pocket-plus/check-symbols.fish)):

- Todos los símbolos dinámicos indefinidos (260 en GBA.emu, 241 en GBC.emu) existen en
  `libc.so`, `libm.so`, `libEGL.so` y `libGLESv2.so` extraídos del propio teléfono.
- 0 instrucciones `udiv`/`sdiv`.
- APK firmados con *APK Signature Scheme v1* (JAR signing), además de v2.

---

## Descargar

Los APK listos para instalar están en [Releases](https://github.com/bafif/emu-ex-plus-alpha/releases)
(sólo armeabi-v7a, Android 2.3+ y probados en el GT-S5301L). Cómo instalarlos: ver
[Instalar en el Pocket Plus](#instalar-en-el-pocket-plus). Si preferís compilarlos vos, seguí
[Compilar](#compilar).

---

## Diagnóstico

Todo lo que hubo que resolver para llegar a una build que funcione, por si te sirve para otro
equipo parecido.

### 1. El CPU no tiene división entera por hardware

El Cortex-A9 r2p9 del BCM21654 no expone `idiva`/`idivt`. Cualquier `udiv`/`sdiv` en el
binario termina en **`SIGILL`** apenas se ejecuta. Por eso se compila con
`-march=armv7-a -mtune=cortex-a9` y **nunca** con `-march=armv7ve` ni tuning para
Cortex-A7/A15. `check-symbols.fish` desensambla el `.so` y falla si encuentra alguna.

### 2. Android 4.0 sólo acepta firma v1

El Package Manager de Android 4.0 rechaza APKs firmados sólo con el esquema v2/v3
(`INSTALL_PARSE_FAILED_NO_CERTIFICATES`). Con `minSdk 9`, `apksigner` agrega la firma v1. Para
comprobarlo:

```sh
apksigner verify --verbose app.apk   # tiene que decir: Verified using v1 scheme (JAR signing): true
```

### 3. Compatibilidad binaria con Bionic API 15

El build compila contra las cabeceras del NDK (`armv7-none-linux-androideabi21`,
`-DANDROID_COMPAT_API=9`) pero enlaza contra los stubs de Bionic API 9 que trae
`imagine/bundle/android/`, con `libc++` estático. Para estar seguro de que no se cuela ningún
símbolo que el teléfono no tiene, se comparan los símbolos indefinidos del `libmain.so` con las
librerías reales sacadas del equipo por `adb pull` (ver [Auditar el binario](#auditar-el-binario)).

### 4. Toolchain: el Clang del NDK no alcanza

El proyecto usa **C++26 con módulos estándar** (`import std;`) y su propio `libc++` 22. El
Clang 18 del NDK r27c es demasiado viejo, así que se usa el **Clang 23 del sistema** con el
*sysroot* del NDK r27c. Eso destapó varios errores de compilación, que este fork corrige:

- `imagine/src/base/android/surfaceTexture.cc`: la partición tiene `export namespace IG`, así
  que tiene que declararse `export module imagine.internal.android:surface;`.
- `imagine/src/base/android/Application.cc`: la tabla `JNINativeMethod` tiene casts `(void*)`
  a punteros de función (un `reinterpret_cast`), que no puede ir en `constexpr`; pasa a
  `static const`.
- `CMAKE_EXPERIMENTAL_CXX_IMPORT_STD` actualizado al UUID de CMake 4.4.4
  (`f35a9ac6-8463-4d38-8eec-5d6008153e7d`) en `imagine/cmake/config.cmake` y
  `imagine/CMakePresets.json`.
- Fuera del repo, en el NDK r27c:
  `sysroot/usr/include/android/hardware_buffer.h:322` define
  `AHARDWAREBUFFER_USAGE_FRONT_BUFFER = 1UL << 32`. En ARMv7 `unsigned long` mide 32 bits y
  Clang 23 lo rechaza; hay que cambiarlo a `1ULL << 32` (ver [Preparar el host](#2-preparar-el-host)).

### 5. GBA.emu: los botones táctiles no respondían

En la primera build, GBA.emu se sentía trabado y los toques no hacían nada. En `adb logcat`
aparecía:

```
E/NativeActivity: Failed to receive dispatch signal. status=-11
```

El intérprete ARM7TDMI ocupaba el 100 % del único núcleo y, cuando se atrasaba,
`EmuSystemTask::advanceFrames` corría hasta 4 cuadros seguidos. Eso dejaba sin CPU al hilo
principal de Android (`ALooper`), que no llegaba a vaciar el `InputChannel`. Los ajustes:

| Cambio | Archivo | Motivo |
|---|---|---|
| Máximo 2 cuadros por ciclo, siempre (antes: hasta 4 cuando iba >70 ms atrasado) | `EmuFramework/src/EmuSystemTask.cc` | Que el hilo de emulación no deje sin CPU al de UI/input |
| Accesos a memoria (`CPURead*`, `CPUWrite*`, `CPUReadOpenBus`) y helpers de wait-states como `noinline` | `GBA.emu/src/core/gba/gbaInline.h`, `gbaCpu.h` | Achica `.text` de `libmain.so` ~135 KB para que el bucle caliente entre mejor en los 32 KB de L1i |
| `gbaCpuArm.cpp` y `gbaCpuThumb.cpp` con `-Os` | `GBA.emu/src/CMakeLists.txt` | Mismo motivo |
| `BLIP_BUFFER_FAST 1` (interpolación lineal de 2 taps en vez de *sinc* de 12) | `GBA.emu/src/core/apu/Blip_Buffer.h` | Menos CPU en síntesis de audio |
| Un flush de audio por cuadro (`VCOUNT == 159`) en vez de 4, y 22050 Hz fijos | `GBA.emu/src/core/gba/gba.cpp`, `src/main/AppMeta.cc` | Menos trabajo de audio por cuadro |
| Render en RGB565 (`canRenderRGBA8888{false}`) | `GBA.emu/src/main/AppMeta.cc` | La mitad de ancho de banda de textura hacia la VideoCore IV y tabla de colores de 128 KB en vez de 256 KB |

### 6. ADB se cae con la batería al 100 %

Con la batería llena, el puerto USB del Pocket hace micro-cortes y el transporte ADB queda
`offline` o desaparece. Se destraba con `adb kill-server && adb start-server`.
`push-rom.fish` lo hace solo.

### Compromisos de estos cambios

- Los binarios armv7 **requieren NEON** (`-mfpu=neon`): no corren en ARMv7 sin NEON (por ejemplo, Tegra 2).
- El límite de 2 cuadros está en EmuFramework y afecta a todos los emuladores compilados desde
  este fork: si el equipo no da abasto, el juego va más lento en vez de saltear más cuadros.
- El audio de GBA.emu pierde algo de precisión a cambio de velocidad.
- Los `-j4` del build están pensados para un host de 4 hilos; ajustalos si tenés más.

---

## Qué hace falta

### En la PC (host)

Probado en Arch Linux x86_64. Cualquier distro con las mismas versiones debería andar.

- **Clang 23** con `lld` y las herramientas LLVM (`llvm-nm`, `llvm-readelf`, `llvm-objdump`).
- **CMake 4.4.4** (el UUID de `import std` depende de la versión exacta), **Ninja**, GNU Make, `pkgconf`, GNU tar.
- **Android NDK r27c**.
- **Android SDK command-line tools** con `platform-tools`, `platforms;android-36` y `build-tools;36.0.0`.
- **JDK 17 o superior** (Gradle 9).
- `arm-none-eabi-binutils` y `arm-none-eabi-gcc` (se usan como ensamblador GNU ARM).
- `fish` para los scripts de `pocket-plus/`, y `unzip`.
- Bastante RAM: con LTO completo conviene tener unos 16 GB entre RAM y swap/zram.
- Un sistema de archivos POSIX (ext4, btrfs…) para el código y el toolchain. **No** compiles
  en NTFS: rompe symlinks y permisos.

### En el teléfono

- Samsung Galaxy Pocket Plus GT-S5301L con Android 4.0.4.
- **Ajustes → Opciones de desarrollador → Depuración USB** activada.
- **Ajustes → Seguridad → Orígenes desconocidos** activado.
- Cable USB y una tarjeta SD para los ROMs.

---

## Compilar

### 1. Variables de entorno

Ejemplo en `fish`. Cambiá las rutas por las tuyas:

```fish
set -gx IMAGINE_PATH ~/src/emu-ex-plus-alpha/imagine
set -gx IMAGINE_SDK_PATH ~/imagine-sdk
set -gx ANDROID_NDK_PATH ~/android/android-ndk-r27c
set -gx ANDROID_HOME ~/android/sdk
set -gx ANDROID_SDK_ROOT $ANDROID_HOME
set -gx ANDROID_CLANG_TOOLCHAIN_PATH /usr          # usar el Clang 23 del sistema, no el del NDK
fish_add_path -gP $ANDROID_HOME/cmdline-tools/latest/bin $ANDROID_HOME/platform-tools ~/android/bin
```

### 2. Preparar el host

**a) Runtime ARMv7 para Clang 23.** El Clang del sistema no trae `compiler-rt` ni `libunwind`
para Android ARM. Se toman los del NDK:

```sh
sudo mkdir -p /usr/lib/clang/23/lib/armv7-none-linux-android21
NDKLIB=$ANDROID_NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/18/lib/linux
sudo ln -s $NDKLIB/libclang_rt.builtins-arm-android.a /usr/lib/clang/23/lib/armv7-none-linux-android21/libclang_rt.builtins.a
sudo ln -s $NDKLIB/arm/libunwind.a                     /usr/lib/clang/23/lib/armv7-none-linux-android21/libunwind.a
```

**b) Ensamblador GNU ARM** con el nombre que espera el build (en un directorio que esté en el `PATH`):

```sh
mkdir -p ~/android/bin
ln -s /usr/bin/arm-none-eabi-as  ~/android/bin/arm-none-linux-gnueabi-as
ln -s /usr/bin/arm-none-eabi-gcc ~/android/bin/arm-none-linux-gnueabi-gcc
```

**c) Parche al NDK r27c** (ver [diagnóstico 4](#4-toolchain-el-clang-del-ndk-no-alcanza)):

```sh
sed -i 's/AHARDWAREBUFFER_USAGE_FRONT_BUFFER = 1UL << 32/AHARDWAREBUFFER_USAGE_FRONT_BUFFER = 1ULL << 32/' \
  $ANDROID_NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/android/hardware_buffer.h
```

**d) Clave de firma.** Para firmar el APK de release, configurá `~/.gradle/gradle.properties`
como explica [`imagine/doc/INSTALL-Android`](imagine/doc/INSTALL-Android)
(`ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_STORE`, `ANDROID_KEY_STORE_PASSWORD`).

### 3. Compilar las dependencias, Imagine y EmuFramework (sólo armv7)

```sh
git clone -b pocket-plus https://github.com/bafif/emu-ex-plus-alpha.git
cd emu-ex-plus-alpha

# Librerías estáticas (libc++, libarchive, FLAC, Vorbis…) → $IMAGINE_SDK_PATH/android-armv7
(cd imagine/bundle/all && bash makeAll-android-armv7.sh install)

# Motor Imagine + imagine-v9.aar
(cd imagine && ./android.sh --presets armv7 install)

# EmuFramework
(cd EmuFramework && ./android.sh --presets armv7 install)
```

### 4. Compilar y empaquetar el emulador

```sh
cd GBA.emu        # o GBC.emu
make -f android.mk android_arch=armv7 android_minSDK=9 android-apk -j4
```

El APK queda en `build/android/build/outputs/apk/release/`.

> **Package ID.** Por defecto la app se instala con el mismo ID que la oficial
> (`com.explusalpha.GbaEmu` / `com.explusalpha.GbcEmu`). Si ya tenés la oficial, desinstalala
> primero: como la firma es otra, Android no deja reemplazarla. El build acepta
> `android_metadata_id=<otro.id>` para usar un ID propio, pero esa variante no está probada en
> este fork.

### Auditar el binario

Una vez, sacá las librerías del teléfono:

```fish
mkdir device-dump
for l in libc libm libEGL libGLESv2; adb pull /system/lib/$l.so device-dump/; end
```

Después de cada build:

```fish
fish pocket-plus/check-symbols.fish GBA.emu/build/android/src/main/jniLibs/armeabi-v7a/libmain.so device-dump
```

Tiene que terminar en `Auditoría completada exitosamente`. Si lista símbolos faltantes o
encuentra `udiv`/`sdiv`, el APK va a crashear en el teléfono.

---

## Instalar en el Pocket Plus

1. Conectá el teléfono por USB con la depuración USB activada y aceptá la huella RSA si aparece.
2. Comprobá que se ve:
   ```sh
   adb devices          # el equipo tiene que figurar como "device"
   ```
   Si figura `offline` o no aparece (típico con la batería al 100 %):
   `adb kill-server && adb start-server`.
3. Instalá el APK (el de [Releases](https://github.com/bafif/emu-ex-plus-alpha/releases) o el que compilaste):
   ```sh
   adb install -r GbaEmu-9-1.5.85-cortex-a9.apk     # o build/android/build/outputs/apk/release/GbaEmu-release.apk
   adb install -r GbcEmu-9-1.5.85-cortex-a9.apk
   ```
   También podés copiar el APK a la SD y abrirlo desde un explorador de archivos en el teléfono.
   Si da `INSTALL_PARSE_FAILED_NO_CERTIFICATES`, al APK le falta la firma v1
   ([diagnóstico 2](#2-android-40-sólo-acepta-firma-v1)). Si da `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
   o `ALREADY_EXISTS`, desinstalá antes la versión oficial.

## Pasar ROMs: `push-rom`

[`pocket-plus/push-rom.fish`](pocket-plus/push-rom.fish) sube ROMs a la SD del teléfono. Se fija
si el archivo, o lo que hay dentro del `.zip`, es de GB/GBC o de GBA y lo copia a
`/sdcard/ROMs/GBC/` o `/sdcard/ROMs/GBA/`. Si ADB se cayó, reinicia el servidor y reintenta.

```fish
cp pocket-plus/push-rom.fish ~/.local/bin/push-rom   # opcional, para tenerlo como comando

push-rom ~/ROMs/juego.zip              # detecta GBC/GBA solo
push-rom --gbc ~/ROMs/juego.zip        # forzar destino
push-rom --gba ~/ROMs/otro.zip
```

Necesita `adb` en el `PATH`. Si tenés más de un equipo conectado, indicá cuál:
`set -gx POCKET_SERIAL <serial de adb devices>`.

En el emulador, abrí el ROM desde `/sdcard/ROMs/...`.

---

## Cambios respecto del original

Aviso de modificación (GPLv3 §5a). Archivos modificados por Bautista D. Fiori el 2026-10-26
respecto de upstream `1c12fac5c`:

- **Toolchain Clang 23 / C++26 / CMake 4.4:** `imagine/cmake/config.cmake`,
  `imagine/CMakePresets.json`, `imagine/src/base/android/surfaceTexture.cc`,
  `imagine/src/base/android/Application.cc`.
- **Paralelismo `-j4`:** `imagine/bundle/all/runMakefiles.sh`,
  `imagine/bundle/all/src/libcxx/common.mk`, `imagine/make/shortcut/meta-builds/android.mk`.
- **Cortex-A9 + NEON + lld:** `imagine/make/android-armv7-gcc.mk`,
  `imagine/cmake/android-armv7.cmake`, `imagine/make/android-gcc.mk`, `imagine/cmake/android.cmake`.
- **Rendimiento de GBA.emu:** `EmuFramework/src/EmuSystemTask.cc`, `GBA.emu/src/CMakeLists.txt`,
  `GBA.emu/src/core/apu/Blip_Buffer.h`, `GBA.emu/src/core/gba/gba.cpp`,
  `GBA.emu/src/core/gba/gbaCpu.h`, `GBA.emu/src/core/gba/gbaInline.h`,
  `GBA.emu/src/main/AppMeta.cc`.
- **Nuevos:** este `README.md` y `pocket-plus/` (scripts de auditoría y de transferencia de ROMs).
  El README original pasó a `README.upstream.md`.

El detalle está en el historial de commits de la rama `pocket-plus`.

## Créditos y licencia

- **Robert Broglia ([Rakashazi](https://github.com/Rakashazi))**: EX Emulators, Imagine,
  EmuFramework, GBA.emu y GBC.emu. Todo el trabajo de fondo es suyo.
- **VBA-M**: el core de Game Boy Advance que usa GBA.emu.
- **Gambatte**: el core de Game Boy / Game Boy Color que usa GBC.emu.
- **Blip_Buffer** (Shay Green): síntesis de audio.
- Ajustes para el Galaxy Pocket Plus: Bautista D. Fiori.

Igual que el original, se distribuye bajo la **GNU General Public License v3** (ver
[`COPYING.GPL`](COPYING.GPL)). Cada componente conserva sus avisos de copyright y licencia.
"Game Boy" y "Game Boy Advance" son marcas de Nintendo; este proyecto no tiene relación con
Nintendo ni con Samsung.
