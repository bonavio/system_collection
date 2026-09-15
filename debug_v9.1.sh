#!/bin/bash
#
# Hardware & System debug collection script
# V3 (03/17/2026)
# V4 (03/18/2026) - Added network info + NVME link status
# V5 (03/19/2026) - Added GPU diagnostics
# V6 (03/25/2026) - Added Memory Error diagnostics (EDAC + rasdaemon)
# V7 (03/25/2026) - Added mcelog support
# V8 (03/25/2026) - Added basic DIMM slot mapping
# V9 (03/25/2026) - Major revision of DIMM mapping using ras-mc-ctl + improved correlation
# V10 (09/10/2026) - added nvidia-smi -q output

# i.e. sudo OUTPUT_DIR=/tmp KEEP_INTERMEDIATE=yes ./debug_v9.sh

set -u -o pipefail

# ────────────────────────────────────────────────
#  Config / tunable section
# ────────────────────────────────────────────────

OUTPUT_DIR="${OUTPUT_DIR:-.}"               
KEEP_INTERMEDIATE="${KEEP_INTERMEDIATE:-no}" 
USE_HOSTNAME="${USE_HOSTNAME:-yes}"         
AUTO_REGISTER_LABELS="${AUTO_REGISTER_LABELS:-no}"  # Set to "yes" to auto-run ras-mc-ctl --register-labels

# ────────────────────────────────────────────────
#  Early checks & preparation
# ────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR" 2>/dev/null || {
    echo "Cannot create/write to directory: $OUTPUT_DIR" >&2
    exit 2
}

# ────────────────────────────────────────────────
#  Basic identifiers
# ────────────────────────────────────────────────

DATE=$(date +"%Y%m%d_%H%M%S")
HOST_SHORT=$(hostname -s 2>/dev/null || echo "unknown")
CHASSIS_SN=$(cat /sys/class/dmi/id/chassis_serial 2>/dev/null | tr -d '\000' || echo "NA")
BOARD_SN=$(cat /sys/class/dmi/id/board_serial   2>/dev/null | tr -d '\000' || echo "NA")
PRODUCT=$(cat /sys/class/dmi/id/product_name    2>/dev/null | tr -d '\000' || echo "NA")

SN="${BOARD_SN}"
[[ $SN == "NA" || -z $SN ]] && SN="${CHASSIS_SN}"
[[ $SN == "NA" || -z $SN ]] && SN="NOSN"

PREFIX="${HOST_SHORT}_${SN}_${DATE}"
if [[ $USE_HOSTNAME != "yes" ]]; then
    PREFIX="${SN}_${DATE}"
fi

LOG_PREFIX="${OUTPUT_DIR}/${PREFIX}"

# ────────────────────────────────────────────────
#  Helper functions
# ────────────────────────────────────────────────

run() {
    local outfile="$1"; shift
    echo "Collecting $(basename "$outfile") ..."
    "$@" > "$outfile" 2>&1 || {
        echo "Warning: command failed → $(basename "$outfile")" >&2
        echo "→ $*" >> "$outfile"
    }
}

# ────────────────────────────────────────────────
#  Main collection
# ────────────────────────────────────────────────

echo "Starting debug collection → prefix: ${PREFIX}"

# Basic system & hardware info
run "${LOG_PREFIX}_01_os-release.log"       cat /etc/os-release
run "${LOG_PREFIX}_02_uname.log"            uname -a
run "${LOG_PREFIX}_03_uptime.log"           uptime
run "${LOG_PREFIX}_04_lscpu.log"            lscpu
run "${LOG_PREFIX}_05_free-h.log"           free -h
run "${LOG_PREFIX}_06_df-h.log"             df -hT
run "${LOG_PREFIX}_07_lsblk-f.log"          lsblk -f -o NAME,FSTYPE,LABEL,SIZE,FSUSED,MOUNTPOINT,SERIAL,MODEL
run "${LOG_PREFIX}_08_ip-a.log"             ip -d addr show
run "${LOG_PREFIX}_09_ip-route.log"         ip route show table all
run "${LOG_PREFIX}_10_dmidecode-full.log"   dmidecode
run "${LOG_PREFIX}_11_dmidecode-bios.log"   dmidecode -t bios
run "${LOG_PREFIX}_12_dmidecode-memory.log" dmidecode -t memory
run "${LOG_PREFIX}_13_lspci-vvv.log"        lspci -vvv 
run "${LOG_PREFIX}_14_lshw.log"             lshw || lshw -short
run "${LOG_PREFIX}_15_lsof-net.log"         lsof -i -P -n || true
run "${LOG_PREFIX}_16_CPU_usage.log"        mpstat -P ALL 1 1 
run "${LOG_PREFIX}_17_nvidia_smi-q.log"     nvidia-smi -q

# System logs
if [[ -d /var/log/journal || -d /run/systemd/journal ]]; then
    run "${LOG_PREFIX}_20_journal-last-50k.log" journalctl --no-pager -n 50000
fi
   
if [[ -f /var/log/syslog ]]; then
    run "${LOG_PREFIX}_21_syslog.log" cat /var/log/syslog
elif [[ -f /var/log/messages ]]; then
    run "${LOG_PREFIX}_21_varlog.log" cat /var/log/messages
fi

run "${LOG_PREFIX}_22_dmesg.log"            dmesg -T --color=never || dmesg

# IPMI / BMC
command -v ipmitool >/dev/null && {
    run "${LOG_PREFIX}_30_ipmi-sel.log"         ipmitool sel elist
    run "${LOG_PREFIX}_31_ipmi-sensor.log"      ipmitool sensor
    run "${LOG_PREFIX}_32_ipmi-fru.log"         ipmitool fru
    run "${LOG_PREFIX}_33_ipmi-lan-print.log"   ipmitool lan print
    run "${LOG_PREFIX}_34_ipmi-mc-info.log"     ipmitool mc info
}

# ── Storage ─────────────────────

# SATA / SAS
mapfile -t SATA_DISKS < <(smartctl --scan-open | awk '/sd/ {print $1}' | sort -u)

for dev in "${SATA_DISKS[@]}"; do
    echo "Collecting SMART → $dev"
    {
        echo "========================================"
        echo "Device: $dev"
        echo "========================================"
        smartctl -H -i "$dev" 2>&1
        echo ""
        smartctl -a -d sat "$dev" 2>&1 || smartctl -a "$dev" 2>&1
        echo ""
        smartctl -l selftest "$dev" 2>&1
        smartctl -l error   "$dev" 2>&1
    } >> "${LOG_PREFIX}_40_smart_sata.log"
done

# NVMe
mapfile -t NVME_DISKS < <(nvme list 2>/dev/null | awk 'NR>1 && $1~/^\/dev\/nvme/ {print $1}' | sort -u)

for dev in "${NVME_DISKS[@]}"; do
    echo "Collecting NVMe → $dev"

    NVME_MODEL=$(nvme id-ctrl "$dev" -o json 2>/dev/null | grep -i '"mn"' | cut -d'"' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "Unknown")
    NVME_SN=$(nvme id-ctrl "$dev" -o json 2>/dev/null | grep -i '"sn"' | cut -d'"' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "Unknown")
    NVME_FW=$(nvme id-ctrl "$dev" -o json 2>/dev/null | grep -i '"fr"' | cut -d'"' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "Unknown")
    NVME_ADDRESS=$(cat /sys/class/nvme/$(basename "$dev" | sed 's|n[0-9]\+.*||')/address)

    {
        echo "========================================"
        echo "Device: $dev"
        echo "Model: $NVME_MODEL"
        echo "Serial: $NVME_SN"
        echo "Firmware: $NVME_FW"
        echo "========================================"
        echo ""
        echo "***Link Stat***"
        echo ""
        lspci -vv -s "$NVME_ADDRESS"  2>/dev/null | grep -E 'Lnk(Sta|Cap)'
        echo ""
        echo "***SMART Log***"
        echo ""
        nvme smart-log      "$dev" -H 2>&1
        echo ""
        echo "***Controller***"
        echo ""
        nvme id-ctrl        "$dev" -H 2>&1
        echo ""
        echo "***Error Log***"
        echo ""
        nvme error-log      "$dev"     2>&1
        echo ""
        echo "***Namespace Info***"
        echo ""
        nvme id-ns          "$dev" -H 2>&1
        echo ""
#        echo "***Endurance Log***"
#        echo ""
#        nvme endurance-log  "$dev" 2>&1 || true
#        echo ""
#        echo "***Temperature Stats***"  
#        echo ""
#        nvme temp-stats     "$dev" 2>&1 || true
    } >> "${LOG_PREFIX}_41_nvme_info.log"
done

#NIC

mapfile -t NIC < <(ls -d /sys/class/net/*/device | cut -d/ -f5)

for dev in "${NIC[@]}"; do
    echo "Collecting NIC INFO → $dev"

    NIC_ADDRESS=$(readlink -f /sys/class/net/$dev/device | xargs basename)
    NIC_MODEL=$(lspci -s $NIC_ADDRESS)
    NIC_MAC=$(cat /sys/class/net/$dev/address)

    {
        echo "========================================"
        echo "Device: $dev"
        echo "$NIC_MODEL"
        echo "MAC: $NIC_MAC"
        echo "========================================"
        echo ""
        echo "***Link Cap & Status***"
        echo ""
        lspci -vv -s "$NIC_ADDRESS" 2>/dev/null | grep -E 'Lnk(Sta|Cap)'
        echo ""
        echo "***Driver & FW info for $dev***"
        echo ""
        ethtool -i "$dev" 2>&1
        echo ""
        echo "***Statistics for $dev***"
        echo ""
        ethtool -S "$dev" 2>&1 || true
        echo ""
              
    } >> "${LOG_PREFIX}_42_nic_info.log"
done

# ── Memory Error Diagnostics - V9 Improved DIMM Mapping ─────────────────────
echo "Collecting Memory Error diagnostics with improved DIMM mapping ..."

{
    echo "========================================="
    echo "MEMORY ERROR DIAGNOSTICS - V9 (Improved DIMM Mapping)"
    echo "========================================="
    echo ""

    # 0. Full DIMM Inventory from SMBIOS
    echo "=== 0. DIMM Inventory (dmidecode Type 17) ==="
    echo "Populated DIMMs:"
    dmidecode -t 17 2>/dev/null | grep -E 'Locator:|Bank Locator:|Size:|Speed:|Manufacturer:|Serial Number:|Part Number:' || echo "dmidecode Type 17 failed"
    echo ""
    echo "Summary of installed DIMMs:"
    dmidecode -t 17 2>/dev/null | awk '/^Handle/ {print ""; next} /Locator:|Size:|Manufacturer:|Serial Number:/ {print}' | cat
    echo ""

    # Optional: Auto-register DIMM labels (very useful on many motherboards)
    if [[ "$AUTO_REGISTER_LABELS" == "yes" ]] && command -v ras-mc-ctl >/dev/null; then
        echo "=== Auto-registering DIMM labels (ras-mc-ctl) ==="
        echo "Running: ras-mc-ctl --register-labels"
        ras-mc-ctl --register-labels 2>&1
        echo "Label registration completed."
        echo ""
    fi

    # 1. EDAC with current labels
    echo "=== 1. EDAC Counters + Current DIMM Labels ==="
    if [[ -d /sys/devices/system/edac/mc ]]; then
        echo "EDAC is active"
        for mc in /sys/devices/system/edac/mc/mc*; do
            if [[ -d "$mc" ]]; then
                mc_name=$(basename "$mc")
                ce=$(cat "$mc/ce_count" 2>/dev/null || echo "N/A")
                ue=$(cat "$mc/ue_count" 2>/dev/null || echo "N/A")
                echo "[$mc_name]  Correctable: $ce   Uncorrectable: $ue"
                echo ""

                for csrow in "$mc"/csrow*; do
                    if [[ -d "$csrow" ]]; then
                        cs_name=$(basename "$csrow")
                        ce_cs=$(cat "$csrow/ce_count" 2>/dev/null || echo "N/A")
                        ue_cs=$(cat "$csrow/ue_count" 2>/dev/null || echo "N/A")
                        echo "  $cs_name:  CE=$ce_cs  UE=$ue_cs"

                        # Show any registered DIMM labels
                        for label_file in "$csrow"/ch*_dimm_label; do
                            if [[ -f "$label_file" ]]; then
                                label=$(cat "$label_file" 2>/dev/null | tr -d '\000')
                                if [[ -n "$label" && "$label" != " " ]]; then
                                    echo "         Label: $label"
                                fi
                            fi
                        done
                        echo ""
                    fi
                done
            fi
        done
    else
        echo "EDAC not available on this system"
    fi
    echo ""

    # 2. ras-mc-ctl - Best human-readable DIMM mapping and errors
    echo "=== 2. ras-mc-ctl (Best DIMM-to-Error Mapping) ==="
    if command -v ras-mc-ctl >/dev/null; then
        echo "ras-mc-ctl status:"
        ras-mc-ctl --status 2>&1
        echo ""

        echo "Current DIMM labels:"
        ras-mc-ctl --print-labels 2>&1 || echo "No labels configured"
        echo ""

        echo "Error counts per DIMM label:"
        ras-mc-ctl --error-count 2>&1 || echo "No error count data"
        echo ""

        echo "Memory layout summary:"
        ras-mc-ctl --summary 2>&1 || echo "No summary available"
        echo ""

        echo "Recent errors:"
        ras-mc-ctl --errors 2>&1 | tail -n 40 || echo "No recent errors logged"
    else
        echo "ras-mc-ctl not installed."
        echo "Recommendation: apt install rasdaemon   or   dnf install rasdaemon"
        echo "(This package provides the best DIMM label mapping)"
    fi
    echo ""

    # 3. mcelog
    echo "=== 3. mcelog (Machine Check Events) ==="
    if command -v mcelog >/dev/null; then
        echo "mcelog installed"
        if [[ -f /var/log/mcelog ]]; then
            echo "Last 100 lines of /var/log/mcelog:"
            tail -n 100 /var/log/mcelog 2>/dev/null | grep -E 'MEMORY|CE|UE|HARDWARE|BANK' || echo "No memory-related entries"
        fi
        echo ""
        mcelog --summary 2>/dev/null || true
    else
        echo "mcelog not installed (useful on Intel systems)"
    fi
    echo ""

    # 4. dmesg summary
    echo "=== 4. dmesg Memory Error Summary ==="
    dmesg -T 2>/dev/null | grep -E 'EDAC|rasdaemon|mcelog|ECC|correctable|uncorrectable|DIMM|Chan|Bank Locator' | tail -n 60 || echo "No memory errors in recent dmesg"

} > "${LOG_PREFIX}_51_memory_errors.log" 2>&1

# GPU Diagnostics (unchanged)
echo "Collecting GPU diagnostics ..."

{
    echo "========================================="
    echo "GPU DIAGNOSTICS"
    echo "========================================="
    echo ""

    echo "=== All GPUs detected by lspci ==="
    lspci -d ::0300 -vvv | grep -E '^(..:..|.*VGA|.*3D|.*Display|Subsystem|Lnk(Cap|Sta))' || echo "No discrete GPUs found"

    if command -v nvidia-smi >/dev/null; then
        echo -e "\n=== NVIDIA GPUs ==="
        nvidia-smi -L
        nvidia-smi -q -d ECC,POWER,CLOCK,PERFORMANCE,COMPUTE,PIDS
    else
        echo -e "\nNVIDIA: nvidia-smi not available"
    fi

    if command -v rocm-smi >/dev/null; then
        echo -e "\n=== AMD GPUs ==="
        rocm-smi --showall || rocm-smi
    elif lsmod | grep -q amdgpu; then
        echo -e "\nAMD: amdgpu module loaded (rocm-smi not found)"
    fi

    echo -e "\n=== PCIe Link Status for all GPUs ==="
    for gpu in $(lspci -d ::030[02] -s | cut -d' ' -f1 2>/dev/null); do
        echo "GPU at $gpu:"
        lspci -vv -s "$gpu" | grep -E 'Lnk(Cap|Sta)' | sed 's/^/  /' || true
        echo ""
    done

} > "${LOG_PREFIX}_50_gpu_info.log" 2>&1

# ────────────────────────────────────────────────
#  Packaging & cleanup
# ────────────────────────────────────────────────

echo "Creating archive ..."

ARCHIVE="${OUTPUT_DIR}/debug_${PREFIX}.tar.gz"

find "$OUTPUT_DIR" -maxdepth 1 -type f -name "${PREFIX}*" -print0 \
    | tar -cvzf "$ARCHIVE" --null --files-from=- --transform "s|^./||"

echo "Archive created: $ARCHIVE"

if [[ $KEEP_INTERMEDIATE != "yes" ]]; then
    rm -f "${LOG_PREFIX}"_*.log
fi

echo "Done."
ls -lh "$ARCHIVE"

exit 0