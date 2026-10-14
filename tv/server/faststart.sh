#!/usr/bin/env bash
#
# Sposta l'indice (atom `moov`) all'inizio degli mp4/m4v di una cartella,
# così i player in streaming (TV, iPhone, Mac) partono subito invece di dover
# prima scaricare la fine del file. Nessuna ricodifica: `ffmpeg -c copy`,
# stesse tracce (video, audio, sottotitoli), stessa qualità.
#
# Sicuro da rilanciare (salta i file già a posto) e pensato per un cron:
#   faststart.sh /percorso/dei/video
# - un file alla volta, priorità bassa (nice/ionice);
# - salta i file modificati negli ultimi 30 minuti (magari si stanno copiando);
# - scrive una copia temporanea accanto all'originale e la sostituisce solo se
#   ha la stessa durata e lo stesso numero di tracce;
# - una sola esecuzione per volta (lock).
#
# Richiede ffmpeg/ffprobe e python3.

set -u
ROOT="${1:?uso: faststart.sh CARTELLA}"
LOCK="${TMPDIR:-/tmp}/curfs-faststart.lock"
exec 9>"$LOCK"
flock -n 9 || { echo "già in esecuzione"; exit 0; }

# 0 = moov dopo mdat (da sistemare), 1 = già a posto, 2 = non leggibile
needs_fix() {
    python3 - "$1" <<'EOF'
import os, struct, sys
path = sys.argv[1]
size = os.path.getsize(path)
order, pos = [], 0
with open(path, "rb") as f:
    while pos < size and len(order) < 16:
        f.seek(pos)
        head = f.read(16)
        if len(head) < 8:
            break
        n, kind = struct.unpack(">I4s", head[:8])
        if n == 1:
            n = struct.unpack(">Q", head[8:16])[0]
        elif n == 0:
            n = size - pos
        if n < 8:
            break
        order.append(kind)
        pos += n
if b"moov" not in order or b"mdat" not in order:
    sys.exit(2)
sys.exit(0 if order.index(b"moov") > order.index(b"mdat") else 1)
EOF
}

duration() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null; }
# Tracce video/audio/sottotitoli (quelle "dati", es. timecode, non si copiano).
streams() { ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$1" 2>/dev/null | grep -c -v '^data'; }

fixed=0; skipped=0; failed=0
while IFS= read -r -d '' file; do
    needs_fix "$file"
    case $? in
        1) continue ;;
        2) echo "illeggibile: $file"; failed=$((failed + 1)); continue ;;
    esac
    if [ -n "$(find "$file" -mmin -30)" ]; then
        echo "recente, salto: $file"; skipped=$((skipped + 1)); continue
    fi

    tmp="${file%.*}.faststart-tmp.${file##*.}"
    rm -f "$tmp"
    if ! nice -n 19 ionice -c3 ffmpeg -nostdin -v error -i "$file" -map 0 -map -0:d? -c copy \
            -map_metadata 0 -movflags +faststart "$tmp"; then
        echo "ffmpeg non riuscito: $file"; rm -f "$tmp"; failed=$((failed + 1)); continue
    fi

    before=$(duration "$file"); after=$(duration "$tmp")
    if [ "$(streams "$file")" -ne "$(streams "$tmp")" ] || \
       ! python3 -c "import sys; a,b=float(sys.argv[1]),float(sys.argv[2]); sys.exit(0 if abs(a-b) < 1.0 else 1)" "$before" "$after"; then
        echo "verifica non superata ($before s / $after s): $file"; rm -f "$tmp"; failed=$((failed + 1)); continue
    fi
    needs_fix "$tmp"
    if [ $? -ne 1 ]; then
        echo "indice ancora in fondo: $file"; rm -f "$tmp"; failed=$((failed + 1)); continue
    fi

    touch -r "$file" "$tmp"
    chmod --reference="$file" "$tmp" 2>/dev/null
    mv -f "$tmp" "$file"
    echo "ok: $file"
    fixed=$((fixed + 1))
done < <(find "$ROOT" -type f \( -iname '*.mp4' -o -iname '*.m4v' \) ! -name '*.faststart-tmp.*' -print0)

echo "fatto: $fixed sistemati, $skipped saltati (recenti), $failed con problemi"
