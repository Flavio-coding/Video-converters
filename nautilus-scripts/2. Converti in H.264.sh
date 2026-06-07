#!/bin/bash
# Nautilus Script: Converti in H.264
# Installa con: ./install.sh  oppure copia in ~/.local/share/nautilus/scripts/
# Priorità encoder: Intel QuickSync (QSV) → VAAPI → NVIDIA NVENC → libx264

TITLE="H.264"
FFMPEG=$(command -v ffmpeg 2>/dev/null || true)
FFPROBE=$(command -v ffprobe 2>/dev/null || true)

# ── Dipendenze ───────────────────────────────────────────────────────────────
missing=()
[[ -z "$FFMPEG" ]]  && missing+=("ffmpeg")
[[ -z "$FFPROBE" ]] && missing+=("ffprobe")
command -v zenity &>/dev/null || missing+=("zenity")

if [[ ${#missing[@]} -gt 0 ]]; then
    zenity --error --title="$TITLE — Dipendenze mancanti" --width=380 \
        --text="$(printf 'Programmi necessari non trovati:\n\n'
                  printf '  • %s\n' "${missing[@]}"
                  printf '\n  sudo apt install ffmpeg zenity\n'
                  printf '  sudo pacman -S ffmpeg zenity')" 2>/dev/null
    exit 1
fi

[[ $# -eq 0 ]] && {
    zenity --error --title="$TITLE" --width=280 \
        --text="Nessun file selezionato." 2>/dev/null
    exit 1
}

# ── Rilevamento encoder hardware ─────────────────────────────────────────────
ENCODER=""
HW_INFO=""
VAAPI_DEV=$(ls /dev/dri/renderD* 2>/dev/null | sort | head -1 || true)

zenity --progress --pulsate --no-cancel \
    --title="$TITLE" --text="Rilevamento encoder..." \
    --width=340 2>/dev/null &
DETECT_DLG=$!

if "$FFMPEG" -hide_banner -loglevel quiet \
    -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
    -c:v h264_qsv -f null - 2>/dev/null; then
    ENCODER="h264_qsv"; HW_INFO="Intel QuickSync (QSV)"

elif [[ -n "$VAAPI_DEV" ]] && "$FFMPEG" -hide_banner -loglevel quiet \
    -vaapi_device "$VAAPI_DEV" \
    -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
    -vf "format=nv12,hwupload" -c:v h264_vaapi -f null - 2>/dev/null; then
    ENCODER="h264_vaapi"; HW_INFO="Intel/AMD VAAPI"

elif "$FFMPEG" -hide_banner -loglevel quiet \
    -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
    -c:v h264_nvenc -f null - 2>/dev/null; then
    ENCODER="h264_nvenc"; HW_INFO="NVIDIA NVENC"

else
    ENCODER="libx264"; HW_INFO="Software (CPU)"
fi

kill "$DETECT_DLG" 2>/dev/null; wait "$DETECT_DLG" 2>/dev/null

# ── Selezione qualità ────────────────────────────────────────────────────────
QUALITY_LABEL=$(zenity --list \
    --title="$TITLE" \
    --text="Encoder: <b>$HW_INFO</b>" \
    --radiolist \
    --column="" --column="Qualità" \
    FALSE "Alta" \
    TRUE  "Media" \
    FALSE "Bassa" \
    --width=340 --height=220 2>/dev/null) || exit 0
[[ -z "$QUALITY_LABEL" ]] && exit 0

case "$QUALITY_LABEL" in
    Alta)  QUALITY=18 ;;
    Media) QUALITY=23 ;;
    Bassa) QUALITY=28 ;;
    *)     exit 0 ;;
esac

# ── Funzioni ─────────────────────────────────────────────────────────────────

# Avvia ffmpeg in background — FFMPEG_PID viene impostato nel chiamante con $!
# NON usare command substitution $(...) per chiamare questa funzione:
# ffmpeg deve restare figlio diretto della shell corrente per wait/kill corretti.
_launch() {
    local input="$1" output="$2" quality="$3" prog="$4" err="$5"
    case "$ENCODER" in
        h264_qsv)
            "$FFMPEG" -hide_banner -loglevel warning -nostats \
                -i "$input" \
                -c:v h264_qsv -global_quality "$quality" -look_ahead 1 \
                -pix_fmt yuv420p \
                -c:a aac -b:a 192k -movflags +faststart \
                -progress "$prog" -y "$output" 2>"$err" &
            ;;
        h264_vaapi)
            "$FFMPEG" -hide_banner -loglevel warning -nostats \
                -vaapi_device "$VAAPI_DEV" \
                -i "$input" \
                -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=nv12,hwupload" \
                -c:v h264_vaapi -qp "$quality" \
                -c:a aac -b:a 192k -movflags +faststart \
                -progress "$prog" -y "$output" 2>"$err" &
            ;;
        h264_nvenc)
            "$FFMPEG" -hide_banner -loglevel warning -nostats \
                -i "$input" \
                -c:v h264_nvenc -preset p4 -cq "$quality" -b:v 0 \
                -pix_fmt yuv420p \
                -c:a aac -b:a 192k -movflags +faststart \
                -progress "$prog" -y "$output" 2>"$err" &
            ;;
        libx264|*)
            "$FFMPEG" -hide_banner -loglevel warning -nostats \
                -i "$input" \
                -c:v libx264 -crf "$quality" -preset medium \
                -pix_fmt yuv420p \
                -c:a aac -b:a 192k -movflags +faststart \
                -progress "$prog" -y "$output" 2>"$err" &
            ;;
    esac
}

_progress() {
    local pid="$1" prog="$2" dur="$3" title="$4" text="$5"
    (
        while kill -0 "$pid" 2>/dev/null; do
            val=$(grep "^out_time_ms=" "$prog" 2>/dev/null \
                | tail -1 | cut -d= -f2 | tr -d '[:space:]')
            if [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]]; then
                pct=$(( val * 100 / dur ))
                [[ $pct -gt 99 ]] && pct=99
                echo "$pct"
            fi
            sleep 0.4
        done
        echo 100
    ) | zenity --progress \
        --title="$title" --text="$text" \
        --percentage=0 --auto-close --cancel-label="Annulla" \
        --width=460 2>/dev/null
    return "${PIPESTATUS[1]}"
}

# ── Elaborazione file ─────────────────────────────────────────────────────────
TOTAL=$#
COUNT=0
ERRORS=()
CONVERTED=()
CURRENT_ENCODER="$ENCODER"  # può cambiare nel fallback, ripristiniamo dopo

for INPUT_FILE in "$@"; do
    COUNT=$((COUNT + 1))
    ENCODER="$CURRENT_ENCODER"  # ripristina encoder per ogni file

    [[ ! -f "$INPUT_FILE" ]] && {
        ERRORS+=("$(basename "$INPUT_FILE") — file non trovato")
        continue
    }

    BASENAME=$(basename "$INPUT_FILE")
    DIRNAME=$(dirname "$INPUT_FILE")
    NOEXT="${BASENAME%.*}"
    OUTPUT_FILE="$DIRNAME/${NOEXT}_H264.mp4"

    n=1
    while [[ -f "$OUTPUT_FILE" ]]; do
        OUTPUT_FILE="$DIRNAME/${NOEXT}_H264_${n}.mp4"; n=$((n + 1))
    done

    DURATION_MS=$("$FFPROBE" -v quiet \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT_FILE" 2>/dev/null | awk '{printf "%.0f", $1 * 1000}' || echo 1)
    [[ -z "$DURATION_MS" || "$DURATION_MS" -le 0 ]] && DURATION_MS=1

    PROGRESS_FILE=$(mktemp /tmp/ffprog_XXXXXX)
    ERR_FILE=$(mktemp /tmp/fferr_XXXXXX)

    _launch "$INPUT_FILE" "$OUTPUT_FILE" "$QUALITY" "$PROGRESS_FILE" "$ERR_FILE"
    FFMPEG_PID=$!  # figlio diretto — wait funziona correttamente

    _progress "$FFMPEG_PID" "$PROGRESS_FILE" "$DURATION_MS" \
        "$TITLE ($COUNT/$TOTAL)" "$BASENAME
$HW_INFO"
    ZENITY_EXIT=$?
    rm -f "$PROGRESS_FILE"

    if [[ $ZENITY_EXIT -ne 0 ]]; then
        kill "$FFMPEG_PID" 2>/dev/null; wait "$FFMPEG_PID" 2>/dev/null
        rm -f "$OUTPUT_FILE" "$ERR_FILE"
        ERRORS+=("$BASENAME — annullato")
        break
    fi

    wait "$FFMPEG_PID"; FFMPEG_RET=$?

    # ── Fallback software ─────────────────────────────────────────────────────
    if [[ $FFMPEG_RET -ne 0 && "$ENCODER" != "libx264" ]]; then
        rm -f "$OUTPUT_FILE" "$ERR_FILE"
        ENCODER="libx264"
        PROGRESS_FILE=$(mktemp /tmp/ffprog_XXXXXX)
        ERR_FILE=$(mktemp /tmp/fferr_XXXXXX)

        _launch "$INPUT_FILE" "$OUTPUT_FILE" "$QUALITY" "$PROGRESS_FILE" "$ERR_FILE"
        FFMPEG_PID=$!

        _progress "$FFMPEG_PID" "$PROGRESS_FILE" "$DURATION_MS" \
            "$TITLE ($COUNT/$TOTAL) — Fallback CPU" "$BASENAME
Software (CPU)"
        ZENITY_EXIT=$?
        rm -f "$PROGRESS_FILE"

        if [[ $ZENITY_EXIT -ne 0 ]]; then
            kill "$FFMPEG_PID" 2>/dev/null; wait "$FFMPEG_PID" 2>/dev/null
            rm -f "$OUTPUT_FILE" "$ERR_FILE"
            ERRORS+=("$BASENAME — annullato")
            break
        fi

        wait "$FFMPEG_PID"; FFMPEG_RET=$?
    fi

    if [[ $FFMPEG_RET -ne 0 ]]; then
        ERR_MSG=$(tail -8 "$ERR_FILE" 2>/dev/null | tr '\n' ' ')
        ERRORS+=("$BASENAME
    ↳ $ERR_MSG")
        rm -f "$OUTPUT_FILE"
    else
        SIZE=$(du -sh "$OUTPUT_FILE" 2>/dev/null | cut -f1 || echo "?")
        CONVERTED+=("$BASENAME  →  $(basename "$OUTPUT_FILE")  [$SIZE]")
    fi
    rm -f "$ERR_FILE"
done

# ── Riepilogo ─────────────────────────────────────────────────────────────────
if [[ ${#CONVERTED[@]} -gt 0 && ${#ERRORS[@]} -gt 0 ]]; then
    zenity --warning --title="$TITLE — Completato con errori" --width=500 \
        --text="$(printf '✓ Convertiti:\n'; printf '  %s\n' "${CONVERTED[@]}"
                  printf '\n✗ Errori:\n'; printf '  %s\n' "${ERRORS[@]}")" 2>/dev/null
elif [[ ${#ERRORS[@]} -gt 0 ]]; then
    zenity --error --title="$TITLE — Errore" --width=560 \
        --text="$(printf 'Conversione fallita:\n\n'
                  printf '  • %s\n' "${ERRORS[@]}")" 2>/dev/null
else
    zenity --info --title="$TITLE — Completato" --width=480 \
        --text="$(printf '✓ Completato!  Encoder: %s\n\n' "$CURRENT_ENCODER"
                  printf '  %s\n' "${CONVERTED[@]}")" 2>/dev/null
fi
