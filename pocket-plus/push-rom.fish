#!/usr/bin/env fish
# ==============================================================================
# push-rom.fish — Enviar ROMs (GB/GBC/GBA o .zip/.7z) al Samsung Galaxy Pocket Plus
# ==============================================================================
# Uso:
#   push-rom <archivo1.zip> [archivo2.gba ...]
#   push-rom --gbc <archivo.zip>
#   push-rom --gba <archivo.zip>
# ==============================================================================

set -g ADB (command -v adb); or begin; echo "❌ adb no está en el PATH"; exit 1; end
# Serial opcional: export POCKET_SERIAL=<serial de `adb devices`> si hay más de un equipo conectado
set -g SERIAL "$POCKET_SERIAL"
set -g ADBS $ADB
set -g SERIAL_RE "\\S+"
if test -n "$SERIAL"
    set -a ADBS -s $SERIAL
    set SERIAL_RE (string escape --style=regex -- $SERIAL)
end

if test (count $argv) -eq 0
    echo "Uso: push-rom [--gbc | --gba] <ruta-al-rom-1> [ruta-al-rom-2 ...]"
    echo ""
    echo "Ejemplos:"
    echo "  push-rom ~/ROMs/juego.gbc"
    echo "  push-rom --gbc ~/ROMs/juego.zip"
    echo "  push-rom --gba ~/ROMs/juego-gba.zip"
    exit 1
end

set -l force_system ""
set -l files

for arg in $argv
    switch $arg
        case --gbc -c
            set force_system GBC
        case --gba -a
            set force_system GBA
        case -h --help
            echo "Uso: push-rom [--gbc | --gba] <ruta-al-rom-1> [ruta-al-rom-2 ...]"
            exit 0
        case '*'
            set -a files $arg
    end
end

if test (count $files) -eq 0
    echo "❌ Error: No especificaste ningún archivo ROM."
    exit 1
end

# Verificar conexión ADB y destrabar automáticamente si el USB del Pocket entró en offline/vacío
function ensure_pocket_connected
    set -l state ($ADB devices | string match -r "^$SERIAL_RE\t(\S+)" | tail -n 1)
    if test "$state" != "device"
        echo "🔄 Reconectando transporte ADB con el Galaxy Pocket Plus ($SERIAL)..."
        $ADB kill-server >/dev/null 2>&1
        $ADB start-server >/dev/null 2>&1
        sleep 1
        $ADB reconnect offline >/dev/null 2>&1
        set state ($ADB devices | string match -r "^$SERIAL_RE\t(\S+)" | tail -n 1)
        if test "$state" != "device"
            echo "❌ Error: El Galaxy Pocket Plus ($SERIAL) no aparece conectado por USB."
            return 1
        end
    end
    return 0
end

# Detectar automáticamente si el ROM es GBC o GBA
function detect_system -a filepath
    if test -n "$force_system"
        echo $force_system
        return
    end

    set -l lower_path (string lower -- "$filepath")

    # 1. Por extensión directa
    if string match -q "*.gba" -- "$lower_path"; or string match -q "*.agb" -- "$lower_path"
        echo GBA
        return
    else if string match -q "*.gbc" -- "$lower_path"; or string match -q "*.gb" -- "$lower_path"; or string match -q "*.dmg" -- "$lower_path"
        echo GBC
        return
    end

    # 2. Si es un archivo .zip, inspeccionar su contenido interno
    if string match -q "*.zip" -- "$lower_path"
        set -l inner (unzip -Z1 "$filepath" 2>/dev/null | string lower)
        for entry in $inner
            if string match -q "*.gba" -- "$entry"; or string match -q "*.agb" -- "$entry"
                echo GBA
                return
            else if string match -q "*.gbc" -- "$entry"; or string match -q "*.gb" -- "$entry"; or string match -q "*.dmg" -- "$entry"
                echo GBC
                return
            end
        end
    end

    # 3. Por nombre de carpeta en la ruta (/gbc/ o /gba/)
    if string match -q "*/gba/*" -- "$lower_path"
        echo GBA
        return
    else if string match -q "*/gbc/*" -- "$lower_path"; or string match -q "*/gb/*" -- "$lower_path"
        echo GBC
        return
    end

    echo UNKNOWN
end

ensure_pocket_connected; or exit 1

for f in $files
    if not test -f "$f"
        echo "❌ No existe el archivo: $f"
        continue
    end

    set -l sys (detect_system "$f")
    if test "$sys" = "UNKNOWN"
        echo "⚠️  No se pudo adivinar si '$f' es de GBC o GBA. Usá: push-rom --gbc '$f' o push-rom --gba '$f'"
        continue
    end

    set -l dest_dir "/sdcard/ROMs/$sys"
    set -l fname (basename "$f")

    echo "📲 Enviando [$sys] '$fname' -> $dest_dir/ ..."
    $ADBS shell mkdir -p "$dest_dir"
    if not $ADBS push "$f" "$dest_dir/"
        echo "🔄 Reintentando tras reinicio de ADB..."
        ensure_pocket_connected; and $ADBS push "$f" "$dest_dir/"
    end
    and echo "✅ Listo: $dest_dir/$fname"
end
