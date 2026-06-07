#!/bin/bash
# Nautilus Script: Converti per DaVinci Resolve (DNxHR)
# Installa con: ./install.sh  oppure copia in ~/.local/share/nautilus/scripts/

TITLE="DaVinci Resolve"
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

# ── Rilevamento HW decode ────────────────────────────────────────────────────
HW_DECODE_ARGS=()
VAAPI_DEV=$(ls /dev/dri/renderD* 2>/dev/null | sort | head -1 || true)
HW_DEC_INFO="Software (CPU)"

if "$FFMPEG" -hide_banner -loglevel quiet \
    -init_hw_device qsv=qsv:MFX_IMPL_hw \
    -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
    -c:v h264_qsv -f null - 2>/dev/null; then
    HW_DECODE_ARGS=(-hwaccel qsv)
    HW_DEC_INFO="Intel QuickSync"
elif [[ -n "$VAAPI_DEV" ]] && "$FFMPEG" -hide_banner -loglevel quiet \
    -hwaccel vaapi -hwaccel_device "$VAAPI_DEV" \
    -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
    -f null - 2>/dev/null; then
    HW_DECODE_ARGS=(-hwaccel vaapi -hwaccel_device "$VAAPI_DEV")
    HW_DEC_INFO="VAAPI"
fi

# ── Selezione profilo ────────────────────────────────────────────────────────
PROFILE=$(zenity --list \
    --title="$TITLE — Profilo" \
    --text="Decoder: <b>$HW_DEC_INFO</b>  |  Encoder: CPU" \
    --radiolist \
    --column="" --column="Profilo" --column="Qualità" \
    TRUE  "dnxhr_hq"  "HQ — Alta qualità" \
    FALSE "dnxhr_sq"  "SQ — Standard" \
    FALSE "dnxhr_hqx" "HQX — 10-bit  (LOG / HDR)" \
    FALSE "dnxhr_444" "444 — 4:4:4 12-bit  (color grading)" \
    FALSE "dnxhr_lb"  "LB — Bassa qualità  (proxy)" \
    --width=440 --height=290 2>/dev/null) || exit 0
[[ -z "$PROFILE" ]] && exit 0

case "$PROFILE" in
    dnxhr_hq)  LABEL="DNxHR-HQ"  ; PIX_FMT="yuv422p"     ;;
    dnxhr_sq)  LABEL="DNxHR-SQ"  ; PIX_FMT="yuv422p"     ;;
    dnxhr_hqx) LABEL="DNxHR-HQX" ; PIX_FMT="yuv422p10le" ;;
    dnxhr_444) LABEL="DNxHR-444" ; PIX_FMT="yuv444p12le" ;;
    dnxhr_lb)  LABEL="DNxHR-LB"  ; PIX_FMT="yuv422p"     ;;
    *)         LABEL="DNxHR"     ; PIX_FMT="yuv422p"     ;;
esac

# ── Elaborazione ─────────────────────────────────────────────────────────────
TOTAL=$#
COUNT=0
ERRORS=()
CONVERTED=()

for INPUT_FILE in "$@"; do
    COUNT=$((COUNT + 1))

    [[ ! -f "$INPUT_FILE" ]] && {
        ERRORS+=("$(basename "$INPUT_FILE") — file non trovato")
        continue
    }

    BASENAME=$(basename "$INPUT_FILE")
    DIRNAME=$(dirname "$INPUT_FILE")
    NOEXT="${BASENAME%.*}"
    OUTPUT_FILE="$DIRNAME/${NOEXT}_${LABEL}.mov"

    n=1
    while [[ -f "$OUTPUT_FILE" ]]; do
        OUTPUT_FILE="$DIRNAME/${NOEXT}_${LABEL}_${n}.mov"
        n=$((n + 1))
    done

    DURATION_MS=$("$FFPROBE" -v quiet \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT_FILE" 2>/dev/null | awk '{printf "%.0f", $1 * 1000}' || echo 1)
    [[ -z "$DURATION_MS" || "$DURATION_MS" -le 0 ]] && DURATION_MS=1

    _do_convert() {
        local use_hw="$1"
        PROGRESS_FILE=$(mktemp /tmp/ffprog_XXXXXX)
        ERR_FILE=$(mktemp /tmp/fferr_XXXXXX)

        if [[ "$use_hw" == "1" && ${#HW_DECODE_ARGS[@]} -gt 0 ]]; then
            "$FFMPEG" -hide_banner -loglevel warning -nostats \
                "${HW_DECODE_ARGS[@]}" \
                -i "$INPUT_FILE" \
                -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
                -c:v dnxhd -profile:v "$PROFILE" -pix_fmt "$PIX_FMT" \
                -c:a pcm_s16le -ar 48000 \
                -progress "$PROGRESS_FILE" \
                -y "$OUTPUT_FILE" 2>"$ERR_FILE" &
        else
            "$FFMPEG" -hide_banner -loglevel warning -nostats \
                -i "$INPUT_FILE" \
                -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
                -c:v dnxhd -profile:v "$PROFILE" -pix_fmt "$PIX_FMT" \
                -c:a pcm_s16le -ar 48000 \
                -progress "$PROGRESS_FILE" \
                -y "$OUTPUT_FILE" 2>"$ERR_FILE" &
        fi
        FFMPEG_PID=$!  # figlio diretto — wait funziona

        (
            while kill -0 "$FFMPEG_PID" 2>/dev/null; do
                val=$(grep "^out_time_ms=" "$PROGRESS_FILE" 2>/dev/null \
                    | tail -1 | cut -d= -f2 | tr -d '[:space:]')
                if [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]]; then
                    pct=$(( val * 100 / DURATION_MS ))
                    [[ $pct -gt 99 ]] && pct=99
                    echo "$pct"
                fi
                sleep 0.4
            done
            echo 100
        ) | zenity --progress \
            --title="$TITLE ($COUNT/$TOTAL)" \
            --text="$BASENAME
$LABEL  |  Decoder: $HW_DEC_INFO" \
            --percentage=0 --auto-close --cancel-label="Annulla" \
            --width=460 2>/dev/null
        PIPE_RES=("${PIPESTATUS[@]}")
        ZENITY_EXIT=${PIPE_RES[1]}

        rm -f "$PROGRESS_FILE"

        if [[ $ZENITY_EXIT -ne 0 ]]; then
            kill "$FFMPEG_PID" 2>/dev/null
            wait "$FFMPEG_PID" 2>/dev/null
            rm -f "$OUTPUT_FILE" "$ERR_FILE"
            return 2  # annullato
        fi

        wait "$FFMPEG_PID"
        local ret=$?
        if [[ $ret -ne 0 ]]; then
            cat "$ERR_FILE" >&2  # propaga errori al chiamante
            rm -f "$ERR_FILE"
            return 1
        fi
        rm -f "$ERR_FILE"
        return 0
    }

    # Primo tentativo (con HW decode se disponibile)
    _do_convert 1
    RESULT=$?

    if [[ $RESULT -eq 2 ]]; then
        ERRORS+=("$BASENAME — annullato")
        break
    fi

    # Fallback: CPU puro se la decodifica HW ha fallito
    if [[ $RESULT -ne 0 && ${#HW_DECODE_ARGS[@]} -gt 0 ]]; then
        rm -f "$OUTPUT_FILE"
        _do_convert 0
        RESULT=$?
        if [[ $RESULT -eq 2 ]]; then
            ERRORS+=("$BASENAME — annullato")
            break
        fi
    fi

    if [[ $RESULT -ne 0 ]]; then
        ERR_MSG=$(cat /dev/stderr 2>/dev/null | tail -6 | tr '\n' ' ')
        ERRORS+=("$BASENAME — errore di conversione")
        rm -f "$OUTPUT_FILE"
    else
        SIZE=$(du -sh "$OUTPUT_FILE" 2>/dev/null | cut -f1 || echo "?")
        CONVERTED+=("$BASENAME  →  $(basename "$OUTPUT_FILE")  [$SIZE]")
    fi
done

# ── Riepilogo ─────────────────────────────────────────────────────────────────
if [[ ${#CONVERTED[@]} -gt 0 && ${#ERRORS[@]} -gt 0 ]]; then
    zenity --warning --title="$TITLE — Completato con errori" --width=500 \
        --text="$(printf '✓ Convertiti:\n'; printf '  %s\n' "${CONVERTED[@]}"
                  printf '\n✗ Errori:\n'; printf '  %s\n' "${ERRORS[@]}")" 2>/dev/null
elif [[ ${#ERRORS[@]} -gt 0 ]]; then
    zenity --error --title="$TITLE — Errore" --width=500 \
        --text="$(printf 'Conversione fallita:\n\n'
                  printf '  • %s\n' "${ERRORS[@]}")" 2>/dev/null
else
    zenity --info --title="$TITLE — Completato" --width=480 \
        --text="$(printf '✓ Completato!\n\n'
                  printf '  %s\n' "${CONVERTED[@]}")" 2>/dev/null
fi
