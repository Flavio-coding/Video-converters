#!/bin/bash
# Nautilus Script: Converti in H.264
# Installa con: ./install.sh  oppure copia manualmente in ~/.local/share/nautilus/scripts/
#
# Converte qualsiasi video in H.264/MP4 con accelerazione hardware automatica.
# Priorità encoder: Intel QuickSync (QSV) → VAAPI → NVIDIA NVENC → libx264 (CPU)
# Fallback automatico a software se l'encoder hardware fallisce.

TITLE="Converti in H.264"
FFMPEG=$(command -v ffmpeg 2>/dev/null || true)
FFPROBE=$(command -v ffprobe 2>/dev/null || true)

# ── Dipendenze ──────────────────────────────────────────────────────────────
missing=()
[[ -z "$FFMPEG" ]]  && missing+=("ffmpeg")
[[ -z "$FFPROBE" ]] && missing+=("ffprobe  (pacchetto: ffmpeg)")
command -v zenity &>/dev/null || missing+=("zenity")

if [[ ${#missing[@]} -gt 0 ]]; then
    zenity --error --title="$TITLE — Dipendenze mancanti" --width=420 \
        --text="$(printf 'Programmi necessari non trovati:\n\n'; printf '  • %s\n' "${missing[@]}"; printf '\nInstalla con:\n  sudo apt install ffmpeg zenity\n\nPer QuickSync su Intel:\n  sudo apt install intel-media-va-driver-non-free')" 2>/dev/null
    exit 1
fi

if [[ $# -eq 0 ]]; then
    zenity --error --title="$TITLE" --width=300 \
        --text="Nessun file selezionato.\n\nSeleziona uno o più file video in Nautilus." 2>/dev/null
    exit 1
fi

# ── Rilevamento encoder hardware ─────────────────────────────────────────────
ENCODER=""
HW_INFO=""
VAAPI_DEV=$(ls /dev/dri/renderD* 2>/dev/null | sort | head -1 || true)

zenity --progress --pulsate --no-cancel \
    --title="$TITLE" --text="Rilevamento accelerazione hardware..." \
    --width=400 2>/dev/null &
DETECT_DLG=$!

# Tenta Intel QuickSync (QSV) — priorità massima per laptop Intel
if "$FFMPEG" -hide_banner -loglevel quiet \
    -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
    -c:v h264_qsv -f null - 2>/dev/null; then
    ENCODER="h264_qsv"
    HW_INFO="Intel QuickSync (QSV) ✓"
fi

# Tenta VAAPI (Intel/AMD tramite VA-API)
if [[ -z "$ENCODER" && -n "$VAAPI_DEV" ]] && \
    "$FFMPEG" -hide_banner -loglevel quiet \
    -vaapi_device "$VAAPI_DEV" \
    -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
    -vf "format=nv12,hwupload" \
    -c:v h264_vaapi -f null - 2>/dev/null; then
    ENCODER="h264_vaapi"
    HW_INFO="Intel/AMD VAAPI ✓  ($VAAPI_DEV)"
fi

# Tenta NVIDIA NVENC
if [[ -z "$ENCODER" ]] && \
    "$FFMPEG" -hide_banner -loglevel quiet \
    -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
    -c:v h264_nvenc -f null - 2>/dev/null; then
    ENCODER="h264_nvenc"
    HW_INFO="NVIDIA NVENC ✓"
fi

# Fallback software
if [[ -z "$ENCODER" ]]; then
    ENCODER="libx264"
    HW_INFO="Software x264 (CPU) — nessun encoder HW trovato"
fi

kill "$DETECT_DLG" 2>/dev/null
wait "$DETECT_DLG" 2>/dev/null

# ── Selezione qualità ────────────────────────────────────────────────────────
QUALITY=$(zenity --list \
    --title="$TITLE" \
    --text="<b>Encoder rilevato: $HW_INFO</b>

Seleziona la qualità H.264:
(CRF/QP più basso = qualità più alta = file più grande)
Output: <i>nomefile_H264.mp4</i>" \
    --radiolist \
    --column="" --column="Qualità" --column="Descrizione" \
    FALSE "18" "Alta qualità — ottima per archivio (file grandi)" \
    TRUE  "23" "Qualità media — bilanciato, consigliato" \
    FALSE "28" "Qualità ridotta — file piccoli per condivisione" \
    --width=560 --height=280 2>/dev/null) || exit 0

[[ -z "$QUALITY" ]] && exit 0

# ── Funzioni di conversione per encoder ─────────────────────────────────────

start_ffmpeg_h264() {
    local input="$1" output="$2" quality="$3" prog_file="$4" err_file="$5"
    case "$ENCODER" in
        h264_qsv)
            "$FFMPEG" -hide_banner -loglevel error -nostats \
                -i "$input" \
                -c:v h264_qsv -global_quality "$quality" -look_ahead 1 \
                -c:a aac -b:a 192k \
                -movflags +faststart \
                -progress "$prog_file" -y "$output" 2>"$err_file" &
            ;;
        h264_vaapi)
            "$FFMPEG" -hide_banner -loglevel error -nostats \
                -vaapi_device "$VAAPI_DEV" \
                -i "$input" \
                -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=nv12,hwupload" \
                -c:v h264_vaapi -qp "$quality" \
                -c:a aac -b:a 192k \
                -movflags +faststart \
                -progress "$prog_file" -y "$output" 2>"$err_file" &
            ;;
        h264_nvenc)
            "$FFMPEG" -hide_banner -loglevel error -nostats \
                -i "$input" \
                -c:v h264_nvenc -preset p4 -cq "$quality" -b:v 0 \
                -c:a aac -b:a 192k \
                -movflags +faststart \
                -progress "$prog_file" -y "$output" 2>"$err_file" &
            ;;
        libx264|*)
            "$FFMPEG" -hide_banner -loglevel error -nostats \
                -i "$input" \
                -c:v libx264 -crf "$quality" -preset medium \
                -c:a aac -b:a 192k \
                -movflags +faststart \
                -progress "$prog_file" -y "$output" 2>"$err_file" &
            ;;
    esac
    echo $!
}

show_progress_bar() {
    local ffmpeg_pid="$1" prog_file="$2" duration_ms="$3"
    local title="$4" text="$5"
    (
        while kill -0 "$ffmpeg_pid" 2>/dev/null; do
            val=$(grep "^out_time_ms=" "$prog_file" 2>/dev/null \
                | tail -1 | cut -d= -f2 | tr -d '[:space:]')
            if [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]]; then
                pct=$(( val * 100 / duration_ms ))
                [[ $pct -gt 99 ]] && pct=99
                echo "$pct"
            fi
            sleep 0.4
        done
        echo 100
    ) | zenity --progress \
        --title="$title" --text="$text" \
        --percentage=0 --auto-close --cancel-label="Annulla" \
        --width=510 2>/dev/null
    # Restituisce l'exit code di zenity
    return "${PIPESTATUS[1]}"
}

# ── Elaborazione file ────────────────────────────────────────────────────────
TOTAL=$#
COUNT=0
ERRORS=()
CONVERTED=()

for INPUT_FILE in "$@"; do
    COUNT=$((COUNT + 1))

    if [[ ! -f "$INPUT_FILE" ]]; then
        ERRORS+=("$(basename "$INPUT_FILE") — file non trovato")
        continue
    fi

    BASENAME=$(basename "$INPUT_FILE")
    DIRNAME=$(dirname "$INPUT_FILE")
    NOEXT="${BASENAME%.*}"
    OUTPUT_FILE="$DIRNAME/${NOEXT}_H264.mp4"

    n=1
    while [[ -f "$OUTPUT_FILE" ]]; do
        OUTPUT_FILE="$DIRNAME/${NOEXT}_H264_${n}.mp4"
        n=$((n + 1))
    done

    DURATION_MS=$("$FFPROBE" -v quiet \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT_FILE" 2>/dev/null | awk '{printf "%.0f", $1 * 1000}' || echo "0")
    [[ -z "$DURATION_MS" || "$DURATION_MS" -le 0 ]] && DURATION_MS=1

    PROGRESS_FILE=$(mktemp /tmp/ffprog_XXXXXX)
    ERR_FILE=$(mktemp /tmp/fferr_XXXXXX)

    # Prima tentata con encoder rilevato (HW o SW)
    FFMPEG_PID=$(start_ffmpeg_h264 "$INPUT_FILE" "$OUTPUT_FILE" "$QUALITY" \
        "$PROGRESS_FILE" "$ERR_FILE")

    PROG_TEXT="<b>$BASENAME</b>
Qualità: CRF/QP $QUALITY  |  Encoder: $HW_INFO"

    show_progress_bar "$FFMPEG_PID" "$PROGRESS_FILE" "$DURATION_MS" \
        "$TITLE ($COUNT/$TOTAL)" "$PROG_TEXT"
    ZENITY_EXIT=$?

    rm -f "$PROGRESS_FILE"

    if [[ $ZENITY_EXIT -ne 0 ]]; then
        kill "$FFMPEG_PID" 2>/dev/null
        wait "$FFMPEG_PID" 2>/dev/null
        rm -f "$OUTPUT_FILE" "$ERR_FILE"
        ERRORS+=("$BASENAME — annullato dall'utente")
        break
    fi

    wait "$FFMPEG_PID"
    FFMPEG_RET=$?

    # ── Fallback software se l'encoder HW ha fallito ─────────────────────────
    if [[ $FFMPEG_RET -ne 0 && "$ENCODER" != "libx264" ]]; then
        rm -f "$OUTPUT_FILE"
        ORIGINAL_ENCODER="$ENCODER"
        ENCODER="libx264"

        PROGRESS_FILE=$(mktemp /tmp/ffprog_XXXXXX)
        ERR_FILE=$(mktemp /tmp/fferr_XXXXXX)

        FFMPEG_PID=$(start_ffmpeg_h264 "$INPUT_FILE" "$OUTPUT_FILE" "$QUALITY" \
            "$PROGRESS_FILE" "$ERR_FILE")

        show_progress_bar "$FFMPEG_PID" "$PROGRESS_FILE" "$DURATION_MS" \
            "$TITLE ($COUNT/$TOTAL) — Fallback CPU" \
            "<b>$BASENAME</b>
⚠ HW encoder ($ORIGINAL_ENCODER) fallito — riprovo con libx264 (CPU)"

        ZENITY_EXIT=$?
        rm -f "$PROGRESS_FILE"

        if [[ $ZENITY_EXIT -ne 0 ]]; then
            kill "$FFMPEG_PID" 2>/dev/null
            wait "$FFMPEG_PID" 2>/dev/null
            rm -f "$OUTPUT_FILE" "$ERR_FILE"
            ENCODER="$ORIGINAL_ENCODER"
            ERRORS+=("$BASENAME — annullato dall'utente")
            break
        fi

        wait "$FFMPEG_PID"
        FFMPEG_RET=$?
        ENCODER="$ORIGINAL_ENCODER"  # Ripristina per i file successivi
    fi

    if [[ $FFMPEG_RET -ne 0 ]]; then
        ERR_MSG=$(tail -5 "$ERR_FILE" 2>/dev/null | tr '\n' ' ')
        ERRORS+=("$BASENAME\n    ↳ $ERR_MSG")
        rm -f "$OUTPUT_FILE"
    else
        SIZE=$(du -sh "$OUTPUT_FILE" 2>/dev/null | cut -f1 || echo "?")
        CONVERTED+=("$BASENAME  →  $(basename "$OUTPUT_FILE")  [$SIZE]")
    fi
    rm -f "$ERR_FILE"
done

# ── Riepilogo ────────────────────────────────────────────────────────────────
if [[ ${#CONVERTED[@]} -gt 0 && ${#ERRORS[@]} -gt 0 ]]; then
    zenity --warning --title="$TITLE — Completato con errori" --width=560 \
        --text="$(printf '✓ Convertiti:\n'; printf '  %s\n' "${CONVERTED[@]}"; printf '\n✗ Errori:\n'; printf '  %s\n' "${ERRORS[@]}")" 2>/dev/null
elif [[ ${#ERRORS[@]} -gt 0 ]]; then
    zenity --error --title="$TITLE — Errore" --width=540 \
        --text="$(printf 'Conversione fallita per:\n\n'; printf '  • %s\n' "${ERRORS[@]}")" 2>/dev/null
else
    zenity --info --title="$TITLE — Completato!" --width=520 \
        --text="$(printf '✓ Conversione completata!\nEncoder: %s\n\n' "$HW_INFO"; printf '  %s\n' "${CONVERTED[@]}")" 2>/dev/null
fi
