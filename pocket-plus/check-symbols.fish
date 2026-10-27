#!/usr/bin/env fish
# Audita un libmain.so ARMv7 contra las librerías reales de un Samsung Galaxy Pocket Plus
# (GT-S5301L, Android 4.0.4 / API 15, Cortex-A9 r2p9 sin idiv).
#
# Uso: check-symbols.fish <ruta/a/libmain.so> <directorio-con-las-libs-del-teléfono>
#
# El directorio de libs se obtiene con:
#   mkdir device-dump; for l in libc libm libEGL libGLESv2; adb pull /system/lib/$l.so device-dump/; end
# Requiere IMAGINE_PATH apuntando a imagine/ (para los stubs de Bionic API 9).

if test (count $argv) -lt 2
    echo "Uso: check-symbols.fish <ruta/a/libmain.so> <device-dump-dir>"
    exit 1
end

set SO_FILE $argv[1]
set DUMP_DIR $argv[2]
if not test -f "$SO_FILE"
    echo "Error: No existe el archivo $SO_FILE"
    exit 1
end
if not test -d "$DUMP_DIR"
    echo "Error: No existe el directorio $DUMP_DIR"
    exit 1
end
if not set -q IMAGINE_PATH
    echo "Error: definí IMAGINE_PATH (ruta a imagine/)"
    exit 1
end

set STUBS_DIR $IMAGINE_PATH/bundle/android/arm-linux-androideabi/9/usr/lib
set TMP (mktemp -d)

echo "=== Auditando binario: $SO_FILE ==="

# 1. Verificar librerías NEEDED
echo "[1/4] Librerías dinámicas requeridas (DT_NEEDED):"
llvm-readelf -d "$SO_FILE" | grep NEEDED

# 2. Verificar símbolos contra las libs reales del teléfono y los stubs API 9
echo "[2/4] Verificando símbolos contra las libs de $DUMP_DIR y los stubs API 9..."
llvm-nm -u -D "$SO_FILE" | awk '{print $2}' | sed 's/@.*//' | sort -u > $TMP/undef.txt
llvm-nm -D --defined-only $DUMP_DIR/*.so $STUBS_DIR/libandroid.so $STUBS_DIR/libOpenSLES.so $STUBS_DIR/libz.so $STUBS_DIR/libjnigraphics.so $STUBS_DIR/libdl.so $STUBS_DIR/liblog.so | awk '{print $3}' | sed 's/@.*//' | sort -u > $TMP/defined.txt

set MISSING (comm -23 $TMP/undef.txt $TMP/defined.txt)
if test -n "$MISSING"
    echo "❌ ERROR: Símbolos indefinidos NO encontrados en el dispositivo:"
    for s in $MISSING
        echo "  - $s"
    end
    rm -r $TMP
    exit 1
else
    set TOTAL_UNDEF (wc -l < $TMP/undef.txt | string trim)
    echo "✅ OK: Los $TOTAL_UNDEF símbolos dinámicos existen en el dispositivo."
end
rm -r $TMP

# 3. Verificar ausencia de instrucciones de división por hardware (udiv / sdiv)
echo "[3/4] Verificando ausencia de instrucciones udiv/sdiv (prohibidas en Cortex-A9 r2p9)..."
set IDIV_COUNT (llvm-objdump -d "$SO_FILE" | grep -cE "\b(udiv|sdiv)\b")
if test "$IDIV_COUNT" -gt 0
    echo "❌ ERROR CRÍTICO: Se detectaron $IDIV_COUNT instrucciones udiv/sdiv."
    exit 1
else
    echo "✅ OK: 0 instrucciones udiv/sdiv detectadas."
end

# 4. Verificar uso de NEON / VFPv3 y Thumb-2
echo "[4/4] Verificando atributos de arquitectura ELF (ARMv7 + Thumb-2 + NEON)..."
llvm-readelf -A "$SO_FILE" | grep -E "Tag_(CPU_name|CPU_arch|THUMB_ISA_use|FP_arch|Advanced_SIMD_arch|ABI_VFP_args)"
echo "=== Auditoría completada exitosamente ==="
