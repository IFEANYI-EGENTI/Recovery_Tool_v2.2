#!/bin/bash
# =============================================================================
# recover.sh — Interactive Flash Drive Forensic Recovery Tool
# Author   : Ifeanyi Egenti David
# Version  : 2.2
# GitHub   : https://github.com/IFEANYI-EGENTI
# Description:
#   Automates forensic recovery of photos and videos from reformatted or
#   corrupted flash drives using PhotoRec, Bulk Extractor, Scalpel, and ffmpeg.
#   Includes auto-unmount, custom folder naming, permission fixing,
#   and automatic markdown report generation.
# Usage    : sudo bash recover.sh
# =============================================================================

# Strict mode — exit immediately on unhandled errors
# Individual tool failures are caught explicitly with || true
set -euo pipefail

# -----------------------------------------------------------------------------
# COLORS & FORMATTING
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# GLOBALS
# -----------------------------------------------------------------------------
SCRIPT_START=$(date +%s)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TARGET_DRIVE=""
FOLDER_NAME=""
OUTPUT_BASE=""
PHOTOREC_OUT=""
BULK_OUT=""
SCALPEL_OUT=""
FFMPEG_OUT=""
REPORT_FILE=""
DRIVE_WAS_MOUNTED=false
TOOLS_INSTALLED=()
TOOLS_MISSING=()

# Recovery stats
PHOTOREC_COUNT=0
BULK_COUNT=0
SCALPEL_COUNT=0
FFMPEG_FIXED=0
FFMPEG_FAILED=0
DETECTED_FS=""

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS
# -----------------------------------------------------------------------------

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       🔍  Storage Drive Forensic Recovery Tool  v2.2         ║"
    echo "║              Created by Ifeanyi Egenti David                 ║"
    echo "║         github.com/IFEANYI-EGENTI  |  x.com/PROJECT_IFEANYI  ║"
    echo "║                      |  PROJECT MAFIA  |                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()  { echo -e "${BLUE}[INFO]${NC}    $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}      $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_error() { echo -e "${RED}[ERROR]${NC}   $1"; }
log_step()  {
    echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

confirm() {
    local prompt="$1"
    local response
    echo -e "${YELLOW}[?]${NC} $prompt ${BOLD}[y/N]${NC}: \c"
    read -r response
    [[ "$response" =~ ^[Yy]$ ]]
}

press_enter() {
    echo -e "${YELLOW}[↵]${NC}  Press ENTER to continue or Ctrl+C to abort..."
    read -r
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root."
        echo -e "       Usage: ${BOLD}sudo bash recover.sh${NC}"
        exit 1
    fi
}

# Fix permissions on a path — always called after creating/writing output
fix_permissions() {
    local target="$1"
    if [[ -e "$target" ]]; then
        chmod -R 777 "$target"
        chown -R "$(logname)":"$(logname)" "$target" 2>/dev/null || true
    fi
}

# Create a directory and immediately verify it exists — abort if it doesn't
make_dir() {
    local dir="$1"
    mkdir -p "$dir"
    if [[ ! -d "$dir" ]]; then
        log_error "Failed to create directory: $dir"
        log_error "Check disk space and permissions, then try again."
        exit 1
    fi
    fix_permissions "$dir"
    log_ok "Created: $dir"
}

# -----------------------------------------------------------------------------
# STEP 1 — CHECK & INSTALL DEPENDENCIES
# -----------------------------------------------------------------------------

check_dependencies() {
    log_step "STEP 1: Checking Dependencies"

    local required_tools=("photorec" "bulk_extractor" "scalpel" "ffmpeg" "mediainfo" "lsblk" "blkid" "fdisk")

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            log_ok "$tool is installed"
            TOOLS_INSTALLED+=("$tool")
        else
            log_warn "$tool is NOT installed"
            TOOLS_MISSING+=("$tool")
        fi
    done

    if [[ ${#TOOLS_MISSING[@]} -gt 0 ]]; then
        echo ""
        log_warn "Missing tools: ${TOOLS_MISSING[*]}"
        if confirm "Install missing tools now?"; then
            log_info "Updating package list..."
            apt-get update -qq
            for tool in "${TOOLS_MISSING[@]}"; do
                local pkg="$tool"
                [[ "$tool" == "photorec" ]]       && pkg="testdisk"
                [[ "$tool" == "bulk_extractor" ]] && pkg="bulk-extractor"
                log_info "Installing $pkg..."
                if apt-get install -y "$pkg" &>/dev/null; then
                    log_ok "$tool installed successfully"
                else
                    log_error "Failed to install $pkg — please install manually and rerun."
                    exit 1
                fi
            done
        else
            log_error "Cannot proceed without required tools. Exiting."
            exit 1
        fi
    else
        log_ok "All dependencies satisfied."
    fi
}

# -----------------------------------------------------------------------------
# STEP 2 — SELECT TARGET DRIVE & AUTO-UNMOUNT
# -----------------------------------------------------------------------------

select_drive() {
    log_step "STEP 2: Select Target Drive"

    echo ""
    log_info "Available block devices:"
    echo ""
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE,VENDOR,MODEL | grep -v "loop"
    echo ""
    log_warn "DO NOT select your system drive (usually sda)."
    log_warn "Only select the external flash drive you want to recover from."
    echo ""

    while true; do
        echo -e "${YELLOW}[?]${NC}  Enter drive name (e.g. sdb, sdc) — no /dev/ prefix needed: \c"
        read -r drive_input
        drive_input="${drive_input#/dev/}"
        TARGET_DRIVE="/dev/${drive_input}"

        if [[ ! -b "$TARGET_DRIVE" ]]; then
            log_error "$TARGET_DRIVE is not a valid block device. Try again."
            continue
        fi

        # Detect filesystem — check partition first, then whole disk
        DETECTED_FS=$(blkid "${TARGET_DRIVE}1" -o value -s TYPE 2>/dev/null \
            || blkid "${TARGET_DRIVE}" -o value -s TYPE 2>/dev/null \
            || lsblk -no FSTYPE "${TARGET_DRIVE}1" 2>/dev/null | grep -v '^$' | head -1 \
            || echo "")

        local drive_size
        drive_size=$(lsblk -dn -o SIZE "$TARGET_DRIVE")

        log_info "Selected  : $TARGET_DRIVE"
        log_info "Size      : $drive_size"
        log_info "Filesystem: ${DETECTED_FS:-Not detected}"

        if confirm "Confirm this is the correct drive?"; then
            break
        fi
    done

    # Auto-unmount all mounted partitions on this drive
    # Skip the parent disk itself — umount only works on partitions (e.g. sdb1 not sdb)
    local any_mounted=false
    while IFS= read -r partition; do
        [[ -z "$partition" ]] && continue
        [[ "$partition" == "$TARGET_DRIVE" ]] && continue
        local mp
        mp=$(lsblk -no MOUNTPOINTS "$partition" 2>/dev/null | grep -v "^$" || true)
        if [[ -n "$mp" ]]; then
            any_mounted=true
            log_warn "$partition is mounted at: $mp"
            log_info "Auto-unmounting $partition..."
            if umount "$partition" 2>/dev/null; then
                log_ok "Unmounted $partition successfully"
            elif umount -l "$partition" 2>/dev/null; then
                log_ok "Lazy-unmounted $partition (detaches cleanly in background)"
            else
                log_warn "Could not auto-unmount $partition"
                log_warn "Try running: sudo umount $partition"
                confirm "Continue anyway (not recommended)?" || exit 1
            fi
        fi
    done < <(lsblk -lno NAME "$TARGET_DRIVE" | sed "s|^|/dev/|")

    if $any_mounted; then
        DRIVE_WAS_MOUNTED=true
        log_ok "Drive unmounted. Safe to proceed."
    else
        log_ok "Drive is not mounted. Ready to proceed."
    fi
}

# -----------------------------------------------------------------------------
# STEP 3 — SET UP OUTPUT DIRECTORIES
# -----------------------------------------------------------------------------

setup_output() {
    log_step "STEP 3: Setting Up Output Directories"

    echo ""
    echo -e "${YELLOW}[?]${NC}  Enter a name for this recovery session."
    echo -e "     Examples: aurelia_birthday_party_recovery, johns_usb_2025"
    echo -e "     Leave blank to use: recovery_${TIMESTAMP}"
    echo -e "${YELLOW}[?]${NC}  Session name: \c"
    read -r FOLDER_NAME

    if [[ -z "$FOLDER_NAME" ]]; then
        FOLDER_NAME="recovery_${TIMESTAMP}"
    else
        # Sanitize — replace spaces with underscores, strip special chars
        FOLDER_NAME=$(echo "$FOLDER_NAME" | tr ' ' '_' | tr -cd '[:alnum:]_-')
    fi

    OUTPUT_BASE="/home/kali/Desktop/${FOLDER_NAME}"

    # Avoid overwriting an existing session
    if [[ -d "$OUTPUT_BASE" ]]; then
        log_warn "Folder '$FOLDER_NAME' already exists on Desktop."
        OUTPUT_BASE="${OUTPUT_BASE}_${TIMESTAMP}"
        FOLDER_NAME="$(basename "$OUTPUT_BASE")"
        log_info "Using: $OUTPUT_BASE instead."
    fi

    PHOTOREC_OUT="${OUTPUT_BASE}/photorec"
    BULK_OUT="${OUTPUT_BASE}/bulk_extractor"
    SCALPEL_OUT="${OUTPUT_BASE}/scalpel"
    FFMPEG_OUT="${OUTPUT_BASE}/ffmpeg_repaired"
    REPORT_FILE="${OUTPUT_BASE}/recovery_report_${TIMESTAMP}.md"

    # Create and verify each directory
    log_info "Creating session directories..."
    make_dir "$OUTPUT_BASE"
    make_dir "$PHOTOREC_OUT"
    make_dir "$BULK_OUT"
    make_dir "$FFMPEG_OUT"
    # Note: do NOT pre-create SCALPEL_OUT — Scalpel requires it to not exist

    # Final verification
    for dir in "$OUTPUT_BASE" "$PHOTOREC_OUT" "$BULK_OUT" "$FFMPEG_OUT"; do
        if [[ ! -d "$dir" ]]; then
            log_error "Directory verification failed: $dir"
            log_error "Cannot continue — please check disk space and permissions."
            exit 1
        fi
    done

    # Check available disk space
    local available_gb
    available_gb=$(df -BG "$OUTPUT_BASE" | awk 'NR==2 {print $4}' | tr -d 'G')
    log_info "Available disk space: ${available_gb}GB"

    if [[ "$available_gb" -lt 10 ]]; then
        log_warn "Less than 10GB free. Large video files may not be fully carved."
        confirm "Continue anyway?" || exit 1
    fi

    echo ""
    log_ok "Session name     : $FOLDER_NAME"
    log_ok "Output folder    : $OUTPUT_BASE"
    log_ok "Permissions      : rwxrwxrwx (all users and groups)"
    echo ""
    log_info "Verifying folder exists on disk right now..."
    if ls -ld "$OUTPUT_BASE"; then
        log_ok "Confirmed — session folder is real and accessible."
    else
        log_error "Session folder does not exist on disk despite mkdir succeeding."
        log_error "Something is seriously wrong with the filesystem. Aborting."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# STEP 4 — AUTOMATED DRIVE ANALYSIS
# -----------------------------------------------------------------------------

analyze_drive() {
    log_step "STEP 4: Drive Analysis"

    log_info "Analyzing $TARGET_DRIVE — no user input required..."
    echo ""

    echo -e "${BOLD}── Partition Table ──────────────────────────────${NC}"
    fdisk -l "$TARGET_DRIVE" 2>/dev/null || true
    echo ""

    echo -e "${BOLD}── Filesystem & Label Info ──────────────────────${NC}"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS "$TARGET_DRIVE" 2>/dev/null || true
    echo ""

    echo -e "${BOLD}── Block Device Signatures ──────────────────────${NC}"
    blkid "${TARGET_DRIVE}"* 2>/dev/null || true
    echo ""

    log_info "Filesystem detected: ${DETECTED_FS:-Unknown}"
    case "${DETECTED_FS,,}" in
        ntfs)
            log_ok "NTFS — original Windows/camera format detected."
            log_info "PhotoRec will use NTFS mode for best recovery results."
            ;;
        vfat|fat32|fat16)
            log_warn "FAT32/vFAT — drive may have been reformatted (e.g. by Android)."
            log_info "Original files may still be recoverable in the underlying sectors."
            ;;
        exfat)
            log_warn "exFAT — common for drives reformatted by Android or Windows."
            ;;
        ""|unknown)
            log_warn "No filesystem signature detected on the partition."
            log_info "This is common after a full reformat — recovery is still possible."
            ;;
        *)
            log_info "Filesystem type: $DETECTED_FS"
            ;;
    esac

    echo ""
    log_ok "Drive analysis complete."
    press_enter
}

# -----------------------------------------------------------------------------
# STEP 5 — PHOTOREC RECOVERY
# -----------------------------------------------------------------------------

run_photorec() {
    log_step "STEP 5: PhotoRec — File Recovery"

    log_info "PhotoRec will scan $TARGET_DRIVE and recover files by signature."
    echo ""
    echo -e "${BOLD}  Follow these steps in the PhotoRec interactive menu:${NC}"
    echo -e "  ${CYAN}1.${NC} Select the partition shown (NOT 'No partition / Whole disk')"
    echo -e "  ${CYAN}2.${NC} Filesystem type → choose [ Other ] for FAT32 or NTFS"
    echo -e "  ${CYAN}3.${NC} Scan area → choose [ Whole ]"
    echo -e "  ${CYAN}4.${NC} Navigate to: ${BOLD}$PHOTOREC_OUT${NC}"
    echo -e "  ${CYAN}5.${NC} Press ${BOLD}C${NC} to start"
    echo ""
    log_warn "PhotoRec will create a 'recup_dir.X' subfolder inside your destination."
    log_warn "Make sure you navigate INTO $PHOTOREC_OUT before pressing C."
    echo ""

    if confirm "Run PhotoRec now?"; then
        # Change into PHOTOREC_OUT so PhotoRec defaults to saving there
        pushd "$PHOTOREC_OUT" > /dev/null
        press_enter
        photorec "$TARGET_DRIVE" || true
        popd > /dev/null

        # Fix permissions on everything PhotoRec created
        fix_permissions "$PHOTOREC_OUT"

        # Verify the folder actually has content
        PHOTOREC_COUNT=$(find "$PHOTOREC_OUT" -type f ! -name "*.se2" 2>/dev/null | wc -l)
        log_ok "PhotoRec complete. Total files recovered: $PHOTOREC_COUNT"

        if [[ "$PHOTOREC_COUNT" -gt 0 ]]; then
            echo ""
            log_info "Verifying files are inside session folder..."
            ls -lh "$PHOTOREC_OUT"
            echo ""
            log_info "File type breakdown:"
            find "$PHOTOREC_OUT" -type f ! -name "*.se2" | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -15 | \
                while read -r count ext; do
                    printf "    ${CYAN}%-10s${NC} %s files\n" "$ext" "$count"
                done
        else
            log_warn "No files found in $PHOTOREC_OUT after PhotoRec completed."
            log_warn "Check if you navigated to the correct folder before pressing C."
            log_warn "Look on your Desktop for any stray recup_dir.* folders."
        fi
    else
        log_warn "Skipping PhotoRec."
    fi
}

# -----------------------------------------------------------------------------
# STEP 6 — BULK EXTRACTOR
# -----------------------------------------------------------------------------

run_bulk_extractor() {
    log_step "STEP 6: Bulk Extractor — Deep Forensic Scan"

    log_info "Bulk Extractor performs a deep scan of raw disk sectors."
    log_info "It finds file fragments, GPS coordinates, URLs, emails,"
    log_info "and embedded metadata that other tools may miss."
    log_info "No configuration needed — fully automated."
    echo ""

    if confirm "Run Bulk Extractor now?"; then
        log_info "Starting Bulk Extractor scan on $TARGET_DRIVE..."
        log_info "Running silently in background — this may take 10–30 minutes..."
        echo ""

        # Bulk extractor requires output dir to NOT exist — remove if present
        if [[ -d "$BULK_OUT" ]]; then
            rm -rf "$BULK_OUT"
        fi

        # Run bulk_extractor silently in background, log output to file
        local bulk_log="${OUTPUT_BASE}/bulk_extractor.log"
        bulk_extractor "$TARGET_DRIVE" -o "$BULK_OUT" > "$bulk_log" 2>&1 &
        local bulk_pid=$!

        # Show a live spinner on a single line while bulk_extractor runs
        local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while kill -0 "$bulk_pid" 2>/dev/null; do
            printf "\r    ${CYAN}%s${NC}  Bulk Extractor scanning... (check bulk_extractor.log for details)" "${spin[$i]}"
            i=$(( (i+1) % 10 ))
            sleep 0.2
        done
        printf "\r    %-70s\n" "Done!" 

        # Wait for process to fully finish and capture exit code
        wait "$bulk_pid" || true

        # Verify output was actually created
        if [[ ! -d "$BULK_OUT" ]]; then
            log_error "Bulk Extractor output folder was not created: $BULK_OUT"
            log_warn "Check $bulk_log for error details. Continuing to next step."
            make_dir "$BULK_OUT"
            return
        fi

        fix_permissions "$BULK_OUT"

        BULK_COUNT=$(find "$BULK_OUT" -type f 2>/dev/null | wc -l)
        log_ok "Bulk Extractor complete. Output files: $BULK_COUNT"
        log_info "Full log saved to: $bulk_log"

        echo ""
        # Highlight interesting finds
        log_info "Notable findings:"
        local found_anything=false
        for feat in gps url email domain; do
            local f="$BULK_OUT/${feat}.txt"
            if [[ -f "$f" ]]; then
                local lines
                lines=$(wc -l < "$f" 2>/dev/null || echo "0")
                if [[ "$lines" -gt 0 ]]; then
                    log_ok "${feat}.txt — $lines entries found"
                    found_anything=true
                fi
            fi
        done
        $found_anything || log_info "No notable metadata entries found in this scan."
    else
        log_warn "Skipping Bulk Extractor."
    fi
}

# -----------------------------------------------------------------------------
# STEP 7 — SCALPEL VIDEO CARVING
# -----------------------------------------------------------------------------

configure_scalpel() {
    local conf="/etc/scalpel/scalpel.conf"

    log_info "Configuring Scalpel..."

    if [[ ! -f "$conf" ]]; then
        log_error "Scalpel config not found at $conf"
        exit 1
    fi

    # Backup original config once
    if [[ ! -f "${conf}.original_backup" ]]; then
        cp "$conf" "${conf}.original_backup"
        log_ok "Config backed up to ${conf}.original_backup"
    fi

    # Uncomment video signatures
    sed -i '/^#.*avi.*RIFF/s/^#//' "$conf"
    sed -i '/^#.*mov.*moov/s/^#//' "$conf"
    sed -i '/^#.*mov.*mdat/s/^#//' "$conf"
    sed -i '/^#.*mpg/s/^#//' "$conf"

    # Increase MOV carve size to 6GB
    sed -i 's/^\(	mov.*moov.*\)	10000000/\1	6000000000/' "$conf"
    sed -i 's/^\(	mov.*mdat.*\)	10000000/\1	6000000000/' "$conf"

    log_ok "AVI, MOV, MPG signatures enabled"
    log_ok "MOV maximum carve size set to 6GB"
}

run_scalpel() {
    log_step "STEP 7: Scalpel — Video File Carving"

    log_info "Scalpel carves files using raw byte signatures."
    log_info "Especially effective for video files PhotoRec may miss."
    echo ""

    if confirm "Run Scalpel now?"; then
        configure_scalpel

        # Scalpel REQUIRES the output dir to not exist — remove if present
        if [[ -d "$SCALPEL_OUT" ]]; then
            log_warn "Removing existing Scalpel output folder for fresh run..."
            rm -rf "$SCALPEL_OUT"
        fi

        log_info "Starting Scalpel scan on $TARGET_DRIVE..."
        log_warn "This may take 20–60 minutes. Please wait..."
        echo ""

        scalpel "$TARGET_DRIVE" -o "$SCALPEL_OUT" || true

        # Verify Scalpel actually created the output folder
        if [[ ! -d "$SCALPEL_OUT" ]]; then
            log_error "Scalpel did not create its output folder: $SCALPEL_OUT"
            log_error "Scalpel may have failed silently. Check if the drive is readable."
            return
        fi

        fix_permissions "$SCALPEL_OUT"

        SCALPEL_COUNT=$(find "$SCALPEL_OUT" -type f ! -name "audit.txt" 2>/dev/null | wc -l)
        log_ok "Scalpel complete. Files carved: $SCALPEL_COUNT"

        echo ""
        log_info "Verifying carved files are inside session folder..."
        ls -lh "$SCALPEL_OUT"
        echo ""

        log_info "Carved file breakdown:"
        for dir in "$SCALPEL_OUT"/*/; do
            [[ -d "$dir" ]] || continue
            local count size name
            count=$(find "$dir" -type f 2>/dev/null | wc -l)
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            name=$(basename "$dir")
            printf "    ${CYAN}%-20s${NC} %s files  (%s)\n" "$name" "$count" "$size"
        done
    else
        log_warn "Skipping Scalpel."
    fi
}

# -----------------------------------------------------------------------------
# STEP 8 — FFMPEG VIDEO REPAIR
# -----------------------------------------------------------------------------

run_ffmpeg_repair() {
    log_step "STEP 8: ffmpeg — Video File Repair"

    log_info "ffmpeg will attempt to remux carved video files."
    log_info "This fixes missing stream headers (moov atom issues) in MOV/MP4 files."
    echo ""

    if [[ ! -d "$SCALPEL_OUT" ]]; then
        log_warn "No Scalpel output found. Skipping ffmpeg repair."
        return
    fi

    local video_files=()
    while IFS= read -r -d '' f; do
        video_files+=("$f")
    # MPG files are raw MPEG stream chunks without container headers —
    # ffmpeg cannot remux them, so we skip them entirely to avoid noise.
    # Only MOV, MP4, AVI and 3GP are attempted.
    done < <(find "$SCALPEL_OUT" -type f \( \
        -iname "*.mov" -o -iname "*.mp4" -o \
        -iname "*.avi" -o -iname "*.3gp" \) -print0 2>/dev/null)

    if [[ ${#video_files[@]} -eq 0 ]]; then
        log_warn "No video files found in Scalpel output to repair."
        return
    fi

    log_info "Found ${#video_files[@]} video file(s) to attempt repair on."
    echo ""

    if confirm "Attempt ffmpeg repair on all carved video files?"; then

        for video in "${video_files[@]}"; do
            local fname output
            fname=$(basename "$video")
            output="${FFMPEG_OUT}/fixed_${fname}"

            log_info "Repairing: $fname"

            if ffmpeg -v quiet -i "$video" -c copy "$output" 2>/dev/null; then
                local duration
                duration=$(mediainfo "$output" 2>/dev/null | grep "^Duration" | head -1 | awk -F': ' '{print $2}' | xargs)
                if [[ -n "$duration" ]]; then
                    log_ok "  ✅ Fixed: $fname  (Duration: $duration)"
                    ((FFMPEG_FIXED++)) || true
                else
                    log_warn "  ⚠️  Remuxed but no playable streams: $fname"
                    rm -f "$output" 2>/dev/null || true
                    ((FFMPEG_FAILED++)) || true
                fi
            else
                log_warn "  ❌ Could not repair: $fname"
                rm -f "$output" 2>/dev/null || true
                ((FFMPEG_FAILED++)) || true
            fi
        done

        fix_permissions "$FFMPEG_OUT"

        echo ""
        log_ok "ffmpeg repair complete."
        log_info "Verifying repaired files are inside session folder..."
        ls -lh "$FFMPEG_OUT"
        echo ""
        log_ok "  Successfully fixed : $FFMPEG_FIXED"
        log_warn "  Could not repair   : $FFMPEG_FAILED"
    else
        log_warn "Skipping ffmpeg repair."
    fi
}

# -----------------------------------------------------------------------------
# STEP 9 — GENERATE MARKDOWN REPORT
# -----------------------------------------------------------------------------

generate_report() {
    log_step "STEP 9: Generating Recovery Report"

    local script_end elapsed elapsed_fmt date_str
    script_end=$(date +%s)
    elapsed=$(( script_end - SCRIPT_START ))
    elapsed_fmt=$(printf '%02dh %02dm %02ds' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))
    date_str=$(date +"%B %d, %Y at %H:%M")

    # PhotoRec breakdown
    local photorec_breakdown="| (none) | 0 |"
    if [[ -d "$PHOTOREC_OUT" ]] && [[ "$PHOTOREC_COUNT" -gt 0 ]]; then
        photorec_breakdown=$(find "$PHOTOREC_OUT" -type f ! -name "*.se2" \
            | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -15 \
            | awk '{print "| "$2" | "$1" |"}')
    fi

    # Scalpel breakdown
    local scalpel_breakdown="| (none) | 0 | 0 |"
    if [[ -d "$SCALPEL_OUT" ]]; then
        scalpel_breakdown=""
        for dir in "$SCALPEL_OUT"/*/; do
            [[ -d "$dir" ]] || continue
            local count size name
            count=$(find "$dir" -type f 2>/dev/null | wc -l)
            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            name=$(basename "$dir")
            scalpel_breakdown+="| $name | $count | $size |"$'\n'
        done
        [[ -z "$scalpel_breakdown" ]] && scalpel_breakdown="| (none) | 0 | 0 |"
    fi

    # Bulk Extractor highlights
    local bulk_highlights="| (none found) | — |"
    if [[ -d "$BULK_OUT" ]]; then
        local tmp_bulk=""
        for feat in gps url email domain; do
            local f="$BULK_OUT/${feat}.txt"
            if [[ -f "$f" ]]; then
                local lines
                lines=$(wc -l < "$f" 2>/dev/null || echo "0")
                [[ "$lines" -gt 0 ]] && tmp_bulk+="| ${feat}.txt | $lines entries |"$'\n'
            fi
        done
        [[ -n "$tmp_bulk" ]] && bulk_highlights="$tmp_bulk"
    fi

    cat > "$REPORT_FILE" << EOF
# 🗂️ Flash Drive Forensic Recovery Report

**Tool:** Storage Drive Forensic Recovery Tool v2.2
**Author:** Ifeanyi Egenti David
**GitHub:** https://github.com/IFEANYI-EGENTI
**Generated:** $date_str
**Total Runtime:** $elapsed_fmt

---

## 📋 Case Summary

| Field | Details |
|-------|---------|
| **Session Name** | $FOLDER_NAME |
| **Target Drive** | $TARGET_DRIVE |
| **Detected Filesystem** | ${DETECTED_FS:-Unknown} |
| **Drive Auto-Unmounted** | $DRIVE_WAS_MOUNTED |
| **Output Directory** | $OUTPUT_BASE |
| **Recovery Date** | $date_str |
| **Total Runtime** | $elapsed_fmt |

---

## 🛠️ Tools Used

| Tool | Purpose | Status |
|------|---------|--------|
| PhotoRec | Signature-based file recovery (photos, docs) | $(command -v photorec &>/dev/null && echo "✅ Available" || echo "❌ Not found") |
| Bulk Extractor | Deep forensic sector scan & metadata extraction | $(command -v bulk_extractor &>/dev/null && echo "✅ Available" || echo "❌ Not found") |
| Scalpel | Raw video file carving by byte signatures | $(command -v scalpel &>/dev/null && echo "✅ Available" || echo "❌ Not found") |
| ffmpeg | Video file remux & repair | $(command -v ffmpeg &>/dev/null && echo "✅ Available" || echo "❌ Not found") |
| mediainfo | File stream analysis & validation | $(command -v mediainfo &>/dev/null && echo "✅ Available" || echo "❌ Not found") |
| blkid / fdisk | Drive & filesystem analysis | ✅ Built-in |

---

## 📊 Recovery Results

### PhotoRec

| Metric | Value |
|--------|-------|
| Total files recovered | $PHOTOREC_COUNT |
| Output location | \`$PHOTOREC_OUT\` |

**File Type Breakdown:**

| Extension | Count |
|-----------|-------|
$photorec_breakdown

---

### Bulk Extractor

| Metric | Value |
|--------|-------|
| Output files generated | $BULK_COUNT |
| Output location | \`$BULK_OUT\` |

**Notable Findings:**

| Feature File | Entries |
|-------------|---------|
$bulk_highlights

---

### Scalpel

| Metric | Value |
|--------|-------|
| Total files carved | $SCALPEL_COUNT |
| Output location | \`$SCALPEL_OUT\` |

**Carved Files by Folder:**

| Folder | Files | Size |
|--------|-------|------|
$scalpel_breakdown

---

### ffmpeg Repair

| Metric | Value |
|--------|-------|
| Successfully repaired | $FFMPEG_FIXED |
| Failed / unplayable | $FFMPEG_FAILED |
| Output location | \`$FFMPEG_OUT\` |

---

## 💡 Technical Notes

- If MOV files are still unplayable, the \`moov atom\` (video index) is missing.
  Repair using \`untrunc\` with a healthy reference file from the same device:
  \`\`\`bash
  git clone https://github.com/ponchio/untrunc && cd untrunc && make
  ./untrunc reference_healthy.mov broken_carved.mov
  \`\`\`
- MPG files from Scalpel may include false positives — verify with \`mediainfo\`.
- All output folders were automatically set to \`rwxrwxrwx\` permissions.

---

## 🔄 Recommended Next Steps

1. **Back up all recovered files** to an external drive or cloud storage immediately
2. **Review photos** in \`photorec/recup_dir.1/\` using any image viewer
3. **Play repaired videos** in \`ffmpeg_repaired/\` using VLC
4. **For still-broken MOV files** — use \`untrunc\` with a healthy reference file
5. **Review Bulk Extractor output** in \`bulk_extractor/\` for metadata and embedded data
6. Run \`mediainfo <filename>\` on any video to verify it has valid playable streams

---

## 📁 Output Structure

\`\`\`
$OUTPUT_BASE/
├── photorec/
│   └── recup_dir.1/          # PhotoRec recovered files (created automatically)
├── bulk_extractor/
│   ├── gps.txt               # GPS coordinates found on drive
│   ├── url.txt               # URLs extracted from drive
│   ├── email.txt             # Email addresses found
│   └── report.xml            # Full Bulk Extractor report
├── scalpel/
│   ├── mov-1-0/              # MOV files (moov header)
│   ├── mov-2-0/              # MOV files (mdat header)
│   ├── mpg-3-0/              # MPEG video files
│   └── audit.txt             # Scalpel carving log
├── ffmpeg_repaired/          # Successfully repaired videos
└── recovery_report_${TIMESTAMP}.md
\`\`\`

---

*Generated by Storage Drive Forensic Recovery Tool v2.2*
*Author: Ifeanyi Egenti David — github.com/IFEANYI-EGENTI*
EOF

    chmod 666 "$REPORT_FILE" 2>/dev/null || true
    fix_permissions "$OUTPUT_BASE"
    log_ok "Report saved to: $REPORT_FILE"

    echo ""
    log_info "Final session folder contents:"
    ls -lh "$OUTPUT_BASE"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

main() {
    clear
    print_banner

    echo -e "${BOLD}${GREEN}  Loading Script...${NC}"
    echo -e "${BOLD}  Welcome! This tool will guide you through a full forensic"
    echo -e "  recovery process to retrieve deleted or lost files.${NC}"
    echo -e "  Each major step will ask for your confirmation before proceeding."
    echo ""
    press_enter

    check_root
    check_dependencies
    select_drive
    setup_output
    analyze_drive
    run_photorec
    run_bulk_extractor
    run_scalpel
    run_ffmpeg_repair
    generate_report

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    ✅  Recovery Complete                     ║${NC}"
    echo -e "${CYAN}║              Storage Drive Forensic Recovery Tool            ║${NC}"
    echo -e "${CYAN}║                  by Ifeanyi Egenti David                     ║${NC}"
    echo -e "${CYAN}║         github.com/IFEANYI-EGENTI  |  x.com/PROJECT_IFEANYI  ║${NC}"
    echo -e "${CYAN}║                      |  PROJECT MAFIA  |                     ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_ok "Session name             : $FOLDER_NAME"
    log_ok "PhotoRec files recovered : $PHOTOREC_COUNT"
    log_ok "Bulk Extractor outputs   : $BULK_COUNT"
    log_ok "Scalpel files carved     : $SCALPEL_COUNT"
    log_ok "Videos repaired (ffmpeg) : $FFMPEG_FIXED"
    log_ok "Output directory         : $OUTPUT_BASE"
    log_ok "Recovery report          : $REPORT_FILE"
    echo ""
    log_warn "Remember to back up all recovered files to a safe location!"
    echo ""
    echo -e "${BOLD}${GREEN}  Vielen Dank!!!${NC}"
}

main "$@"
