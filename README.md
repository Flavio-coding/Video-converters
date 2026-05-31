# Nautilus Video Converter Scripts

Script per il tasto destro di Nautilus (file manager GNOME) che convertono video da e verso formati compatibili con **DaVinci Resolve Free su Linux**, con rilevamento automatico dell'accelerazione hardware.

---

## Indice

- [Perché questi script](#perché-questi-script)
- [Formati e scelte tecniche](#formati-e-scelte-tecniche)
- [Requisiti](#requisiti)
- [Installazione](#installazione)
- [Utilizzo](#utilizzo)
- [Gli script](#gli-script)
  - [1. Converti per DaVinci Resolve (DNxHR)](#1-converti-per-davinci-resolve-dnxhr)
  - [2. Converti in H.264](#2-converti-in-h264)
  - [3. Converti in H.265 HEVC](#3-converti-in-h265-hevc)
- [Accelerazione hardware](#accelerazione-hardware)
- [Naming dei file di output](#naming-dei-file-di-output)
- [Risoluzione dei problemi](#risoluzione-dei-problemi)

---

## Perché questi script

DaVinci Resolve Free su Linux non supporta nativamente molti codec comuni (H.265, VP9, AV1, alcuni profili H.264, ecc.). Aprire questi file in Resolve causa errori di importazione o video corrotti.

Il flusso di lavoro tipico è:

```
File originale (H.264, H.265, VP9, AV1, MKV, ecc.)
        ↓  Script 1
  DNxHR/MOV  ← importa in DaVinci Resolve Free
        ↓  esporta da Resolve
  File montato (DaVinci render)
        ↓  Script 2 o 3  (opzionale, per ridurre dimensioni)
  H.264 o H.265 per distribuzione/archivio
```

---

## Formati e scelte tecniche

### Perché DNxHR e non AV1 (o altri codec)

| Codec | Editing in Resolve Free su Linux | Dimensione file | Velocità decode |
|-------|----------------------------------|-----------------|-----------------|
| **DNxHR HQ** | ✅ Nativo, affidabile al 100% | Grande | Istantanea |
| H.264 | ⚠️ Inaffidabile — vedi nota | Medio | Lenta (inter-frame) |
| H.265/HEVC | ❌ Non supportato in Free | Piccolo | Molto lenta |
| AV1 | ❌ Non supportato | Minimo | Molto lenta |
| VP9 | ❌ Non supportato | Piccolo | Lenta |
| ProRes | ⚠️ Limitato su Linux | Grande | Istantanea |

> **Nota su H.264:** DaVinci Resolve Free su Linux dichiara il supporto H.264, ma in pratica è inaffidabile:
> - Usa il decoder hardware GPU: senza driver corretti (o su GPU non supportata) l'importazione fallisce anche con file H.264 normalissimi
> - I profili "non standard" non funzionano: Hi10P (10-bit), High 4:2:2, alcuni profili da mirrorless/action cam → errore di importazione
> - Anche quando funziona, H.264 è un codec inter-frame con compressione pesante: seeking lento, frame drop durante il playback nella timeline, crash sui tagli precisi
>
> In sintesi: H.264 potrebbe aprirsi, oppure no. DNxHR funziona sempre.

**DNxHR** è un codec *intra-frame*: ogni fotogramma è codificato in modo indipendente, senza riferimenti ai fotogrammi precedenti o successivi. Questo significa:

- **Seeking istantaneo** durante il montaggio (vai a qualsiasi punto del video senza aspettare)
- **Nessun artefatto** da decompressione inter-frame durante i tagli
- **Compatibilità garantita** con DaVinci Resolve Free su Linux, indipendentemente dai driver GPU
- **Qualità di editing** professionale (usato nelle produzioni broadcast)

**AV1** è ottimo per la distribuzione/streaming ma è il peggior formato possibile per l'editing:
- DaVinci Resolve Free non lo decodifica
- Anche se lo decodificasse, la decompressione è computazionalmente pesante → lag durante il montaggio
- È un codec inter-frame → seeking lento

### Profili DNxHR disponibili

| Profilo | Bit depth | Chroma | Uso consigliato |
|---------|-----------|--------|-----------------|
| **HQ** | 8-bit | 4:2:2 | Montaggio standard — consigliato per la maggior parte dei video |
| SQ | 8-bit | 4:2:2 | File leggermente più piccoli, qualità leggermente inferiore |
| HQX | 10-bit | 4:2:2 | Video LOG, HDR o con ampio range dinamico |
| 444 | 12-bit | 4:4:4 | Color grading professionale avanzato |
| LB | 8-bit | 4:2:2 | Proxy per il montaggio (non per la consegna finale) |

---

## Requisiti

### Obbligatori

| Pacchetto | Uso | Installazione |
|-----------|-----|---------------|
| `ffmpeg` | Motore di conversione video | `sudo apt install ffmpeg` |
| `ffprobe` | Analisi metadati video (incluso in ffmpeg) | (incluso in ffmpeg) |
| `zenity` | Interfaccia grafica dialoghi | `sudo apt install zenity` |

### Per l'accelerazione hardware (opzionali ma consigliati)

#### Intel QuickSync (QSV) — per laptop/desktop Intel
```bash
sudo apt install intel-media-va-driver-non-free libmfx1
sudo usermod -aG video $USER
# Poi esegui logout e login per applicare il gruppo
```

> **Nota:** Su sistemi più vecchi (Intel gen. 6 o precedente) usa `i965-va-driver` invece di `intel-media-va-driver-non-free`.

#### AMD (VAAPI)
```bash
sudo apt install mesa-va-drivers
sudo usermod -aG video $USER
```

#### NVIDIA (NVENC)
```bash
# I driver proprietari NVIDIA includono già il supporto NVENC
# Verifica che ffmpeg sia compilato con --enable-nvenc
ffmpeg -hide_banner -encoders | grep nvenc
```

---

## Installazione

### Metodo automatico (consigliato)

```bash
# Clona il repository
git clone https://github.com/flavio-coding/video-converters.git
cd video-converters

# Installa le dipendenze
sudo apt install ffmpeg zenity

# Esegui lo script di installazione
bash install.sh
```

Lo script `install.sh`:
1. Verifica le dipendenze installate
2. Rileva gli encoder hardware disponibili
3. Copia gli script in `~/.local/share/nautilus/scripts/`
4. Imposta i permessi di esecuzione
5. Mostra le istruzioni per attivare Intel QuickSync se non rilevato

Dopo l'installazione, riavvia Nautilus:
```bash
nautilus -q && nautilus &
```

### Metodo manuale

```bash
SCRIPTS_DIR="$HOME/.local/share/nautilus/scripts"
mkdir -p "$SCRIPTS_DIR"
cp nautilus-scripts/*.sh "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/"*.sh
nautilus -q && nautilus &
```

### Verifica installazione

Apri Nautilus, seleziona un file video qualsiasi, tasto destro. Deve apparire il sottomenu **Script** con i tre script.

---

## Utilizzo

1. **Apri Nautilus** (il file manager di GNOME)
2. **Naviga** nella cartella contenente i tuoi video
3. **Seleziona uno o più file** video (Ctrl+clic per selezione multipla)
4. **Tasto destro** → **Script**
5. **Scegli lo script** desiderato
6. **Configura le opzioni** nel dialogo che appare
7. **Attendi** la conversione (barra di avanzamento in tempo reale)
8. Il file convertito appare **nella stessa cartella** del sorgente

---

## Gli script

### 1. Converti per DaVinci Resolve (DNxHR)

**Scopo:** Prepara qualsiasi video per l'importazione in DaVinci Resolve Free su Linux.

**Quando usarlo:** Quando Resolve rifiuta di importare un file, lo importa senza audio, o mostra frame corrotti.

**Flusso:**
```
Qualsiasi video (H.265, VP9, AV1, MKV, ecc.)
    ↓
[Dialogo selezione profilo DNxHR]
    ↓
ffmpeg decode (HW se disponibile) → encode DNxHR (CPU)
    ↓
video_DNxHR-HQ.mov nella stessa cartella
```

**Dettagli tecnici:**
- **Encoder:** `dnxhd` con profilo DNxHR (sempre CPU — non esistono encoder HW per DNxHR)
- **Decodifica sorgente:** Tenta QSV → VAAPI → CPU software
- **Pixel format:** yuv422p (HQ/SQ/LB), yuv422p10le (HQX), yuv444p12le (444)
- **Audio:** PCM 16-bit 48kHz non compresso (standard broadcast)
- **Container:** MOV (massima compatibilità con Resolve su Linux)
- **Dimensioni:** Automaticamente allineate a valori pari (requisito DNxHR)
- **Fallback:** Se la decodifica HW fallisce, riprova automaticamente con CPU

**Dimensioni file indicative** (1 ora di video 1080p 25fps):

| Profilo | Dimensione approssimativa |
|---------|--------------------------|
| DNxHR LB | ~27 GB |
| DNxHR SQ | ~54 GB |
| DNxHR HQ | ~81 GB |
| DNxHR HQX | ~108 GB |
| DNxHR 444 | ~162 GB |

> I file DNxHR sono grandi per design — sono pensati per l'editing su disco locale, non per la distribuzione.

---

### 2. Converti in H.264

**Scopo:** Converte qualsiasi video in H.264/MP4 con la migliore accelerazione hardware disponibile.

**Quando usarlo:** Per esportare il montaggio finito, condividere video, ridurre le dimensioni per l'archivio.

**Flusso:**
```
Qualsiasi video
    ↓
[Rilevamento encoder HW: QSV → VAAPI → NVENC → libx264]
    ↓
[Dialogo selezione qualità]
    ↓
ffmpeg encode H.264
    ↓
video_H264.mp4 nella stessa cartella
```

**Dettagli tecnici:**

| Encoder | Condizione | Opzioni qualità |
|---------|-----------|----------------|
| `h264_qsv` | Intel QuickSync disponibile | `-global_quality N -look_ahead 1` |
| `h264_vaapi` | Dispositivo VAAPI trovato e funzionante | `-qp N` + filtro hwupload |
| `h264_nvenc` | Driver NVIDIA con NVENC | `-preset p4 -cq N -b:v 0` |
| `libx264` | Fallback software sempre disponibile | `-crf N -preset medium` |

**Scala di qualità (CRF/QP equivalente):**

| Opzione dialogo | Valore | Note |
|----------------|--------|------|
| Alta qualità | 18 | File grandi, qualità quasi-lossless visivamente |
| Qualità media | 23 | Bilanciato — default consigliato |
| Qualità ridotta | 28 | File piccoli, qualità ridotta |

**Fallback automatico:** Se l'encoder hardware rileva ma poi fallisce durante la conversione (es. formato sorgente non supportato dall'HW), lo script riprova automaticamente con `libx264` (CPU) senza richiedere intervento dell'utente.

**Audio:** AAC 192 kbps — formato universale, compatibile con tutti i dispositivi.

**Container:** MP4 con `-movflags +faststart` — ottimizzato per lo streaming web (i metadati sono all'inizio del file).

---

### 3. Converti in H.265 (HEVC)

**Scopo:** Converte qualsiasi video in H.265/MP4 — circa il 40-50% più piccolo di H.264 a parità di qualità visiva.

**Quando usarlo:** Per l'archivio a lungo termine, condivisione di file grandi, o quando la compatibilità con H.265 non è un problema.

**Funzionamento identico allo script H.264**, con le seguenti differenze:

| Parametro | H.264 | H.265 |
|-----------|-------|-------|
| Encoder HW Intel QSV | `h264_qsv` | `hevc_qsv` |
| Encoder VAAPI | `h264_vaapi` | `hevc_vaapi` |
| Encoder NVIDIA | `h264_nvenc` | `hevc_nvenc` |
| Encoder software | `libx264` | `libx265` |
| Scala qualità Alta | CRF 18 | CRF 20 |
| Scala qualità Media | CRF 23 | CRF 26 |
| Scala qualità Bassa | CRF 28 | CRF 32 |
| Tag compatibilità | — | `-tag:v hvc1` (per Apple/QuickTime) |

> **Nota:** H.265 richiede più CPU per la decodifica. Su hardware vecchio o dispositivi mobili meno potenti potrebbe non essere fluido. H.264 rimane più compatibile universalmente.

---

## Accelerazione hardware

### Come funziona il rilevamento

Gli script H.264 e H.265 eseguono un **test reale** all'avvio: generano un breve video di test (160x120px, 0.1 secondi) con ciascun encoder hardware nell'ordine di priorità. Se il test riesce, quell'encoder viene usato per la conversione.

**Ordine di priorità:**
```
Intel QuickSync (QSV)  →  VAAPI (Intel/AMD)  →  NVIDIA NVENC  →  libx264/libx265
```

Il rilevamento richiede circa 1-2 secondi e viene mostrato un dialog "Rilevamento..." durante questa fase.

### Intel QuickSync (QSV) — raccomandato per laptop Intel

QuickSync è l'encoder hardware integrato nei processori Intel dal 2011 in poi. È generalmente il più efficiente in termini di consumo energetico (importante per laptop) e di velocità.

**Requisiti su Ubuntu/Debian:**
```bash
# Intel Gen. 8+ (Coffee Lake e successivi)
sudo apt install intel-media-va-driver-non-free libmfx1

# Intel Gen. 6-7 (Skylake, Kaby Lake)
sudo apt install intel-media-va-driver libmfx1

# Intel Gen. 5 e precedenti
sudo apt install i965-va-driver
```

**Verifica che QSV funzioni:**
```bash
ffmpeg -hide_banner -loglevel quiet \
    -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
    -c:v h264_qsv -f null - && echo "QSV OK" || echo "QSV non disponibile"
```

### VAAPI (Intel/AMD via VA-API)

Se QSV non è disponibile, gli script tentano l'encoding tramite VA-API, che è il layer di accelerazione hardware standard su Linux per Intel e AMD.

**Verifica dispositivi disponibili:**
```bash
ls /dev/dri/
# Deve mostrare: card0  renderD128  (o numerazioni simili)
```

**Verifica encoder VAAPI:**
```bash
vainfo 2>/dev/null | grep -i "h264\|hevc"
```

### Rilevamento nell'install.sh

Lo script `install.sh` esegue gli stessi test e mostra un report completo degli encoder disponibili sul sistema, con suggerimenti per attivare quelli mancanti.

---

## Naming dei file di output

I file convertiti vengono salvati **nella stessa cartella del file sorgente** con un suffisso che indica il formato:

| File sorgente | Script usato | File di output |
|---------------|-------------|----------------|
| `video.mp4` | DNxHR HQ | `video_DNxHR-HQ.mov` |
| `video.mkv` | DNxHR SQ | `video_DNxHR-SQ.mov` |
| `clip.mov` | DNxHR HQX | `clip_DNxHR-HQX.mov` |
| `film.avi` | H.264 | `film_H264.mp4` |
| `ripresa.mp4` | H.265 | `ripresa_H265.mp4` |

**Protezione dalla sovrascrittura:** Se il file di output esiste già, viene aggiunto un contatore progressivo:
```
video_H264.mp4       ← primo file
video_H264_1.mp4     ← secondo (se il primo esiste)
video_H264_2.mp4     ← terzo, ecc.
```

---

## Risoluzione dei problemi

### Gli script non appaiono nel menu tasto destro

```bash
# Verifica che gli script siano nella cartella giusta
ls ~/.local/share/nautilus/scripts/

# Verifica i permessi di esecuzione
ls -la ~/.local/share/nautilus/scripts/

# Riavvia Nautilus
nautilus -q && nautilus &
```

Se il sottomenu "Script" non compare, assicurati che Nautilus abbia la funzione script abilitata:
- Apri Nautilus → menu → Preferenze → (assicurati di non essere in modalità amministratore)

---

### Errore: "ffmpeg non trovato"

```bash
sudo apt update && sudo apt install ffmpeg
# Verifica
ffmpeg -version
```

---

### Intel QuickSync non rilevato

1. Verifica che i driver siano installati:
   ```bash
   sudo apt install intel-media-va-driver-non-free libmfx1
   ```

2. Verifica che il tuo utente sia nel gruppo `video`:
   ```bash
   groups $USER | grep video
   # Se non compare 'video':
   sudo usermod -aG video $USER
   # Poi esegui logout e login
   ```

3. Verifica che il modulo kernel sia caricato:
   ```bash
   ls /dev/dri/
   # Deve mostrare renderD128 o simile
   ```

4. Test diretto:
   ```bash
   ffmpeg -hide_banner -loglevel verbose \
       -f lavfi -i "color=size=160x120:duration=0.1:rate=25" \
       -c:v h264_qsv -f null - 2>&1 | tail -20
   ```

---

### La conversione DNxHR fallisce con errori di pixel format

Se vedi errori tipo `Could not find a supported codec for profile dnxhr_hq`, verifica la versione di ffmpeg:
```bash
ffmpeg -version | head -1
# Consigliata: 4.4 o superiore
```

Con ffmpeg vecchio, prova ad aggiornare:
```bash
# Ubuntu: usa il PPA ufficiale per una versione più recente
sudo add-apt-repository ppa:savoury1/ffmpeg4
sudo apt update && sudo apt install ffmpeg
```

---

### File di output con dimensioni zero o corrotti

Questo indica che ffmpeg ha fallito silenziosamente. Per diagnosticare, esegui manualmente il comando ffmpeg corrispondente:

```bash
# Test DNxHR manuale
ffmpeg -i "tuo_video.mp4" \
    -c:v dnxhd -profile:v dnxhr_hq -pix_fmt yuv422p \
    -c:a pcm_s16le -ar 48000 \
    output_test.mov

# Controlla l'output per messaggi di errore
```

---

### La barra di avanzamento non si aggiorna

La barra di avanzamento si aggiorna ogni 0.4 secondi leggendo il file di progresso di ffmpeg. Se rimane ferma:
- La conversione è comunque in corso (ffmpeg lavora in background)
- Potrebbe essere un video molto corto dove la conversione finisce prima del primo aggiornamento
- Attendi il completamento naturale — lo script funziona correttamente

---

### Dipendenza da zenity non disponibile (es. KDE/XFCE)

`zenity` è specifico per GTK/GNOME. Su altri ambienti desktop:

```bash
# KDE: usa kdialog (richiede modifica degli script)
sudo apt install kdialog

# Alternativa universale
sudo apt install zenity  # funziona anche fuori GNOME
```

Gli script usano `zenity` che funziona su qualsiasi ambiente purché GTK sia installato (di solito è già presente su tutti i sistemi Linux desktop).

---

## Struttura del repository

```
video-converters/
├── README.md                                  ← questo file
├── install.sh                                 ← script di installazione
└── nautilus-scripts/
    ├── 1. Converti per DaVinci Resolve (DNxHR).sh
    ├── 2. Converti in H.264.sh
    └── 3. Converti in H.265 (HEVC).sh
```

---

## Licenza

MIT — usa, modifica e distribuisci liberamente.
