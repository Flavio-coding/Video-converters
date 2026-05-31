#!/bin/bash
# Installa gli script Nautilus per la conversione video
# Uso: bash install.sh

set -uo pipefail

SCRIPTS_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nautilus-scripts"
NAUTILUS_SCRIPTS_DIR="$HOME/.local/share/nautilus/scripts"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Nautilus Video Converter Scripts — Installazione  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Verifica dipendenze ──────────────────────────────────────────────────────
echo -e "${BOLD}Verifica dipendenze...${NC}"
ALL_OK=true

check_dep() {
    local cmd="$1" label="${2:-$1}" install_hint="${3:-}"
    if command -v "$cmd" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $label  ($(command -v "$cmd"))"
    else
        echo -e "  ${RED}✗${NC} $label — NON TROVATO"
        [[ -n "$install_hint" ]] && echo -e "      ${YELLOW}→ $install_hint${NC}"
        ALL_OK=false
    fi
}

check_dep ffmpeg   "ffmpeg"  "sudo apt install ffmpeg"
check_dep ffprobe  "ffprobe" "sudo apt install ffmpeg"
check_dep zenity   "zenity"  "sudo apt install zenity"

echo
echo -e "${BOLD}Rilevamento accelerazione hardware...${NC}"

if command -v ffmpeg &>/dev/null; then
    VAAPI_DEV=$(ls /dev/dri/renderD* 2>/dev/null | sort | head -1 || true)

    # QSV
    if ffmpeg -hide_banner -loglevel quiet \
        -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
        -c:v h264_qsv -f null - 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Intel QuickSync (QSV) disponibile"
        HW_FOUND=true
    else
        echo -e "  ${YELLOW}○${NC} Intel QuickSync (QSV) non disponibile"
        echo -e "      ${YELLOW}→ sudo apt install intel-media-va-driver-non-free${NC}"
    fi

    # VAAPI
    if [[ -n "$VAAPI_DEV" ]] && ffmpeg -hide_banner -loglevel quiet \
        -vaapi_device "$VAAPI_DEV" \
        -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
        -vf "format=nv12,hwupload" \
        -c:v h264_vaapi -f null - 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} VAAPI disponibile ($VAAPI_DEV)"
        HW_FOUND=true
    elif [[ -e /dev/dri ]]; then
        echo -e "  ${YELLOW}○${NC} VAAPI: dispositivo trovato ma encoder non disponibile"
    else
        echo -e "  ${YELLOW}○${NC} VAAPI non disponibile (nessun /dev/dri)"
    fi

    # NVENC
    if ffmpeg -hide_banner -loglevel quiet \
        -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
        -c:v h264_nvenc -f null - 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} NVIDIA NVENC disponibile"
        HW_FOUND=true
    fi

    echo -e "  ${GREEN}✓${NC} libx264 (software, sempre disponibile come fallback)"
    echo -e "  ${GREEN}✓${NC} libx265 (software, sempre disponibile come fallback)"
    echo -e "  ${GREEN}✓${NC} DNxHR (CPU, encoder professionale per DaVinci Resolve)"
fi

echo

# ── Avviso dipendenze mancanti ──────────────────────────────────────────────
if [[ "$ALL_OK" == "false" ]]; then
    echo -e "${YELLOW}⚠  Alcune dipendenze non sono installate.${NC}"
    echo -e "   Gli script saranno installati ma potrebbero non funzionare."
    echo -e "   Installa le dipendenze con: ${BOLD}sudo apt install ffmpeg zenity${NC}"
    echo
    read -rp "Continuare con l'installazione? [s/N] " CONT
    [[ "${CONT,,}" == "s" ]] || { echo "Installazione annullata."; exit 1; }
    echo
fi

# ── Installazione script ─────────────────────────────────────────────────────
echo -e "${BOLD}Installazione script in:${NC}"
echo -e "  ${CYAN}$NAUTILUS_SCRIPTS_DIR${NC}"
echo

mkdir -p "$NAUTILUS_SCRIPTS_DIR"

INSTALLED=0
FAILED=0

while IFS= read -r -d '' script; do
    SCRIPT_NAME=$(basename "$script")
    DEST="$NAUTILUS_SCRIPTS_DIR/$SCRIPT_NAME"
    if cp "$script" "$DEST" && chmod +x "$DEST"; then
        echo -e "  ${GREEN}✓${NC} $SCRIPT_NAME"
        INSTALLED=$((INSTALLED + 1))
    else
        echo -e "  ${RED}✗${NC} $SCRIPT_NAME — errore durante la copia"
        FAILED=$((FAILED + 1))
    fi
done < <(find "$SCRIPTS_SRC_DIR" -name "*.sh" -print0 | sort -z)

echo
echo -e "${BOLD}Risultato: ${GREEN}$INSTALLED installati${NC}"
[[ $FAILED -gt 0 ]] && echo -e "          ${RED}$FAILED falliti${NC}"

# ── Riavvio Nautilus ─────────────────────────────────────────────────────────
echo
echo -e "${BOLD}Per attivare gli script, riavvia Nautilus:${NC}"
echo -e "  ${CYAN}nautilus -q && nautilus &${NC}"
echo
echo -e "${BOLD}Come usare gli script:${NC}"
echo -e "  1. Apri Nautilus (il file manager)"
echo -e "  2. Seleziona uno o più file video"
echo -e "  3. Tasto destro → ${CYAN}Script${NC}"
echo -e "  4. Scegli lo script desiderato:"
echo -e "     ${CYAN}1. Converti per DaVinci Resolve (DNxHR)${NC} — per importare in Resolve"
echo -e "     ${CYAN}2. Converti in H.264${NC}                    — per esportare/condividere"
echo -e "     ${CYAN}3. Converti in H.265 (HEVC)${NC}             — file più piccoli"
echo
echo -e "${BOLD}File di output:${NC}"
echo -e "  video.mp4 → video_DNxHR-HQ.mov  (stessa cartella del sorgente)"
echo -e "  video.mov → video_H264.mp4"
echo -e "  video.mkv → video_H265.mp4"
echo

# ── Nota per Intel QuickSync ─────────────────────────────────────────────────
echo -e "${YELLOW}Nota per Intel QuickSync (laptop Intel):${NC}"
echo -e "  Se QSV non è rilevato, installa i driver:"
echo -e "  ${CYAN}sudo apt install intel-media-va-driver-non-free libmfx1${NC}"
echo -e "  Poi aggiungi il tuo utente al gruppo video:"
echo -e "  ${CYAN}sudo usermod -aG video \$USER${NC}  (richiede logout/login)"
echo
