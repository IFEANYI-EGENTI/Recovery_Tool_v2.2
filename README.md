# 🔍 Storage Drive Forensic Recovery Tool

**Version:** 2.2
**Author:** Ifeanyi Egenti David
**GitHub:** [@IFEANYI-EGENTI](https://github.com/IFEANYI-EGENTI)
**X (Twitter):** [@OnyeDot69](https://x.com/OnyeDot69)
**Project:** PROJECT MAFIA

---

## 📖 Overview

The **Storage Drive Forensic Recovery Tool** is an interactive, menu-driven bash script designed for Kali Linux that automates the forensic recovery of photos, videos, and other files from reformatted, corrupted, or accidentally wiped flash drives and storage media.

Built from a real-world recovery case — successfully recovering irreplaceable burial ceremony footage from a flash drive that had been reformatted by an Android device — this tool packages a professional forensic workflow into a single, beginner-friendly script.

---

## ✨ Features

- 🔒 **Auto-unmount** — detects and safely unmounts the target drive before scanning
- 📁 **Custom session naming** — organizes all output into a named folder on the Desktop
- 🔑 **Auto-permissions** — sets `rwxrwxrwx` on all recovered files automatically
- 🛠️ **Multi-tool pipeline** — runs PhotoRec, Bulk Extractor, Scalpel, and ffmpeg in sequence
- 🔇 **Silent background scanning** — Bulk Extractor runs with a live spinner instead of cluttering the terminal
- 🎬 **Video repair** — attempts ffmpeg remux on carved MOV/MP4/AVI files to restore playability
- 📊 **Auto-generated report** — produces a full markdown recovery report at the end of every session
- ✅ **Folder verification** — confirms all output directories exist on disk before proceeding

---

## 🛠️ Tools Used

| Tool | Purpose |
|------|---------|
| **PhotoRec** | Signature-based file recovery (photos, documents, videos) |
| **Bulk Extractor** | Deep forensic sector scan — extracts URLs, emails, GPS, metadata |
| **Scalpel** | Raw byte-signature video carving for files PhotoRec misses |
| **ffmpeg** | Remuxes and repairs carved MOV/MP4 video files |
| **mediainfo** | Validates recovered video streams |
| **blkid / fdisk** | Drive analysis and filesystem detection |

---

## 📋 Requirements

- **OS:** Kali Linux (tested on Kali 6.10)
- **Privileges:** Must be run as root (`sudo`)
- **VirtualBox users:** USB 2.0/3.0 passthrough requires the VirtualBox Extension Pack

All required tools can be installed automatically by the script if they are missing.

---

## 🚀 Installation & Usage

### 1. Clone the repository

```bash
git clone https://github.com/IFEANYI-EGENTI/Recovery_Tool_v2.2.git
```

### 2. Navigate into the tool folder

```bash
cd Recovery_Tool_v2.2
cd IFEANYI-EGENTI_Recovery_Tool_v2.2
```

### 3. Make the script executable

```bash
chmod +x recover.sh
```

### 4. Run the script

```bash
sudo bash recover.sh
```

> ⚠️ The script **must** be run with `sudo`. It will exit with an error if run without root privileges.

---

## 🔄 How It Works

The script guides you through 9 interactive steps:

```
STEP 1 → Dependency check & auto-install
STEP 2 → Drive selection & auto-unmount
STEP 3 → Session folder setup & verification
STEP 4 → Automated drive analysis (fdisk, blkid, lsblk)
STEP 5 → PhotoRec file recovery (interactive)
STEP 6 → Bulk Extractor deep scan (silent background)
STEP 7 → Scalpel video carving
STEP 8 → ffmpeg video repair
STEP 9 → Markdown recovery report generation
```

Each step asks for your confirmation before proceeding. You can skip any step by entering `N`.

---

## 📁 Output Structure

Every session creates a named folder on your Desktop:

```
/home/kali/Desktop/<session_name>/
├── photorec/
│   └── recup_dir.1/          # Files recovered by PhotoRec
├── bulk_extractor/
│   ├── url.txt               # URLs found on the drive
│   ├── email.txt             # Email addresses found
│   ├── domain.txt            # Domains found
│   └── gps.txt               # GPS coordinates (if any)
├── scalpel/
│   ├── mov-1-0/              # MOV files (moov header)
│   ├── mov-2-0/              # MOV files (mdat header)
│   ├── mpg-3-0/              # MPEG video files
│   └── audit.txt             # Scalpel carving log
├── ffmpeg_repaired/          # Successfully repaired videos
├── bulk_extractor.log        # Full Bulk Extractor output log
└── recovery_report_<timestamp>.md   # Auto-generated session report
```

---

## 💡 Tips for Best Results

- **Do not write anything to the target drive** before recovery — every write reduces the chance of getting files back
- In the **PhotoRec menu**, select the detected partition (not "No partition"), choose `[ Other ]` for filesystem type, then `[ Whole ]` for scan area
- If recovered MOV files won't play, they may have a missing `moov atom`. Use [untrunc](https://github.com/ponchio/untrunc) with a healthy reference file from the same device to repair them
- Always ensure you have **at least 10GB of free space** on your Kali system before running — video carving can produce large output files

---

## ⚠️ Legal & Ethical Use

This tool is intended **exclusively** for lawful data recovery on devices you own or have explicit legal authority to access. Unauthorized use against devices you do not own may constitute a criminal offence.

Please read the full **[Legal Notice & Ethical Use Policy](IFEANYI-EGENTI_Recovery_Tool_v2.2/README.md)** included in the tool folder before use.

---

## 📄 License

All rights reserved. © Ifeanyi Egenti David — PROJECT MAFIA.

Unauthorized redistribution, rebranding, or commercial use of this tool without written permission from the author is prohibited and will be pursued legally.

---

## 🤝 Contributing

Found a bug or want to suggest an improvement? Open an issue on GitHub. Pull requests are welcome for non-breaking improvements.

---

## 📬 Contact

- **GitHub:** https://github.com/IFEANYI-EGENTI
- **X (Twitter):** https://x.com/OnyeDot69
- **Gmail:** projectmafiaofficial3@gmail.com

---

*Built with 🔥 on Kali Linux — PROJECT MAFIA*
