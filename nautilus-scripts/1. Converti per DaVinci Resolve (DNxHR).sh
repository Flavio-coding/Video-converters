#!/bin/bash
# Nautilus Script: Converti per DaVinci Resolve (DNxHR)
# Installa con: ./install.sh  oppure copia manualmente in ~/.local/share/nautilus/scripts/
#
# Converte qualsiasi video in DNxHR/MOV — formato di editing professionale
# nativamente supportato da DaVinci Resolve Free su Linux.
# DNxHR è un codec intra-frame (ogni frame è un keyframe): seek istantaneo,
# nessun problema con codec non supportati da Resolve Free.
# Audio: PCM non compresso (standard professionale per l'editing).
# Nota: DNxHR non dispone di encoder hardware; la decodifica del sorgente
# può sfruttare l'accelerazione hardware se disponibile.

TITLE="Converti per DaVinci Resolve"
FFMPEG=$(command -v ffmpeg 2>/dev/null || true)
FFPROBE=$(command -v ffprobe 2>/dev/null || true)

# ── Dipendenze ──────────────────────────────────────────────────────────────
missing=()
[[ -z "$FFMPEG" ]]  && missing+=("ffmpeg")
[[ -z "$FFPROBE" ]] && missing+=("ffprobe  (pacchetto: ffmpeg)")
command -v zenity &>/dev/null || missing+=("zenity")

if [[ ${#missing[@]} -gt 0 ]]; then
    zenity --error --title="$TITLE — Dipendenze mancanti" --width=400 \
        --text="$(printf 'Programmi necessari non trovati:\n\n'; printf '  • %s\n' "${missing[@]}"; printf '\nInstalla con:\n  sudo apt install ffmpeg zenity')" 2>/dev/null
    exit 1
fi

if [[ $# -eq 0 ]]; then
    zenity --error --title="$TITLE" --width=300 \
        --text="Nessun file selezionato.\n\nSeleziona uno o più file video in Nautilus." 2>/dev/null
    exit 1
fi

# ── Rilevamento accelerazione HW per la decodifica ──────────────────────────
HW_DECODE_ARGS=()
VAAPI_DEV=$(ls /dev/dri/renderD* 2>/dev/null | sort | head -1 || true)

if "$FFMPEG" -hide_banner -loglevel quiet \
    -init_hw_device qsv=qsv:MFX_IMPL_hw \
    -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
    -c:v h264_qsv -f null - 2>/dev/null; then
    HW_DECODE_ARGS=(-hwaccel qsv)
    HW_DEC_INFO="Intel QuickSync (decodifica)"
elif [[ -n "$VAAPI_DEV" ]] && "$FFMPEG" -hide_banner -loglevel quiet \
    -hwaccel vaapi -hwaccel_device "$VAAPI_DEV" \
    -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
    -f null - 2>/dev/null; then
    HW_DECODE_ARGS=(-hwaccel vaapi -hwaccel_device "$VAAPI_DEV" -hwaccel_output_format nv12)
    HW_DEC_INFO="VAAPI (decodifica)"
else
    HW_DEC_INFO="Software (CPU)"
fi

# ── Selezione profilo ────────────────────────────────────────────────────────
PROFILE=$(zenity --list \
    --title="$TITLE" \
    --text="<b>Formato di editing professionale per DaVinci Resolve Free su Linux</b>

DNxHR: codec intra-frame → seeking istantaneo, compatibilità totale con Resolve.
L'audio viene convertito in PCM non compresso (48 kHz, 16-bit).
Encoder video: CPU — Decodifica sorgente: <b>$HW_DEC_INFO</b>
Output: <i>nomefile_DNxHR-HQ.mov</i>" \
    --radiolist \
    --column="" --column="Profilo" --column="Descrizione" \
    TRUE  "dnxhr_hq"  "Alta qualità 8-bit — consigliato per la maggior parte dei video" \
    FALSE "dnxhr_sq"  "Qualità standard 8-bit — file più piccoli" \
    FALSE "dnxhr_hqx" "Alta qualità 10-bit — per video LOG/HDR (richiede più spazio)" \
    FALSE "dnxhr_444" "4:4:4 12-bit — color grading professionale avanzato" \
    FALSE "dnxhr_lb"  "Bassa qualità — proxy veloci per montaggio (non per la consegna)" \
    --width=640 --height=350 2>/dev/null) || exit 0

[[ -z "$PROFILE" ]] && exit 0

# Label per il nome del file di output
case "$PROFILE" in
    dnxhr_hq)  LABEL="DNxHR-HQ"  ; PIX_FMT="yuv422p"      ;;
    dnxhr_sq)  LABEL="DNxHR-SQ"  ; PIX_FMT="yuv422p"      ;;
    dnxhr_hqx) LABEL="DNxHR-HQX" ; PIX_FMT="yuv422p10le"  ;;
    dnxhr_444) LABEL="DNxHR-444" ; PIX_FMT="yuv444p12le"  ;;
    dnxhr_lb)  LABEL="DNxHR-LB"  ; PIX_FMT="yuv422p"      ;;
    *)         LABEL="DNxHR"     ; PIX_FMT="yuv422p"      ;;
esac

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
    OUTPUT_FILE="$DIRNAME/${NOEXT}_${LABEL}.mov"

    # Evita sovrascrittura aggiungendo un contatore
    n=1
    while [[ -f "$OUTPUT_FILE" ]]; do
        OUTPUT_FILE="$DIRNAME/${NOEXT}_${LABEL}_${n}.mov"
        n=$((n + 1))
    done

    # Durata sorgente in ms per la progress bar
    DURATION_MS=$("$FFPROBE" -v quiet \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT_FILE" 2>/dev/null | awk '{printf "%.0f", $1 * 1000}' || echo "0")
    [[ -z "$DURATION_MS" || "$DURATION_MS" -le 0 ]] && DURATION_MS=1

    PROGRESS_FILE=$(mktemp /tmp/ffprog_XXXXXX)
    ERR_FILE=$(mktemp /tmp/fferr_XXXXXX)

    # Avvia FFmpeg
    # DNxHR richiede dimensioni pari → scale con trunc
    "$FFMPEG" -hide_banner -loglevel error -nostats \
        "${HW_DECODE_ARGS[@]}" \
        -i "$INPUT_FILE" \
        -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
        -c:v dnxhd -profile:v "$PROFILE" -pix_fmt "$PIX_FMT" \
        -c:a pcm_s16le -ar 48000 \
        -progress "$PROGRESS_FILE" \
        -y "$OUTPUT_FILE" \
        2>"$ERR_FILE" &
    FFMPEG_PID=$!

    # Progress bar
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
        --text="<b>$BASENAME</b>
Profilo: $LABEL
Encoder: CPU  |  Decodifica: $HW_DEC_INFO" \
        --percentage=0 --auto-close --cancel-label="Annulla" \
        --width=500 2>/dev/null
    PIPE_STATUS=("${PIPESTATUS[@]}")
    ZENITY_EXIT=${PIPE_STATUS[1]}

    rm -f "$PROGRESS_FILE"

    if [[ $ZENITY_EXIT -ne 0 ]]; then
        # Utente ha annullato
        kill "$FFMPEG_PID" 2>/dev/null
        wait "$FFMPEG_PID" 2>/dev/null
        rm -f "$OUTPUT_FILE" "$ERR_FILE"
        ERRORS+=("$BASENAME — annullato dall'utente")
        break
    fi

    wait "$FFMPEG_PID"
    FFMPEG_RET=$?

    if [[ $FFMPEG_RET -ne 0 ]]; then
        # Fallback: riprova senza HW decode (alcune sorgenti non lo supportano)
        if [[ ${#HW_DECODE_ARGS[@]} -gt 0 ]]; then
            rm -f "$OUTPUT_FILE"
            "$FFMPEG" -hide_banner -loglevel error -nostats \
                -i "$INPUT_FILE" \
                -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
                -c:v dnxhd -profile:v "$PROFILE" -pix_fmt "$PIX_FMT" \
                -c:a pcm_s16le -ar 48000 \
                -progress "$PROGRESS_FILE" \
                -y "$OUTPUT_FILE" \
                2>"$ERR_FILE" &
            FFMPEG_PID=$!
            PROGRESS_FILE=$(mktemp /tmp/ffprog_XXXXXX)

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
                --title="$TITLE ($COUNT/$TOTAL) — Fallback CPU" \
                --text="<b>$BASENAME</b>
Profilo: $LABEL
Riprova con decodifica software (CPU puro)..." \
                --percentage=0 --auto-close --cancel-label="Annulla" \
                --width=500 2>/dev/null
            PIPE_STATUS=("${PIPESTATUS[@]}")
            ZENITY_EXIT=${PIPE_STATUS[1]}
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
        fi
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
        --text="$(printf '✓ Convertiti con successo:\n'; printf '  %s\n' "${CONVERTED[@]}"; printf '\n✗ Errori:\n'; printf '  %s\n' "${ERRORS[@]}")" 2>/dev/null
elif [[ ${#ERRORS[@]} -gt 0 ]]; then
    zenity --error --title="$TITLE — Errore" --width=540 \
        --text="$(printf 'Conversione fallita per:\n\n'; printf '  • %s\n' "${ERRORS[@]}")" 2>/dev/null
else
    zenity --info --title="$TITLE — Completato!" --width=520 \
        --text="$(printf '✓ Conversione completata!\n\n'; printf '  %s\n' "${CONVERTED[@]}")" 2>/dev/null
fi
