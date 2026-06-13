#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Reizsh
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

set -euo pipefail

readonly REG_DRT0=0x110
readonly REG_DRT1=0x114
readonly REG_DRT2=0x118
readonly REG_CLKCFG=0xC00
readonly VENDOR_INTEL=0x8086
readonly DEVICE_945GSE=0x27ac

check_environment() {
    if [[ $EUID -ne 0 ]]; then
        echo "Root privileges are required to access /dev/mem and PCI configuration."
        exit 1
    fi
    if ! command -v python3 &> /dev/null; then
        echo "Error: python3 package not found."
        exit 1
    fi
    if [[ ! -r /dev/mem || ! -w /dev/mem ]]; then
        echo "Make sure the kernel has CONFIG_STRICT_DEVMEM disabled and the /dev/mem character device is enabled."
        echo "You can add the 'iomem=relaxed' parameter to GRUB_CMDLINE_LINUX_DEFAULT and update grub."
        exit 1
    fi
}

check_chipset() {
    local vid did
    vid=$(setpci -s 00:00.0 0x00.w 2>/dev/null) || { echo "Error reading Vendor ID"; exit 1; }
    did=$(setpci -s 00:00.0 0x02.w 2>/dev/null) || { echo "Error reading Device ID"; exit 1; }
    vid=$((16#$vid))
    did=$((16#$did))
    if [[ $vid -ne $VENDOR_INTEL ]] || [[ $did -ne $DEVICE_945GSE ]]; then
        echo "Current chipset is not suitable for this script (VID=$vid, DID=$did). It is designed only for 945GSE."
        exit 1
    fi
    echo "Chipset identified as 945GSE"
}

init_mchbar() {
    echo "Locating MCHBAR..."
    local raw=$(setpci -s 00:00.0 0x44.L 2>/dev/null) || {
        echo "Error reading MCHBAR register."
        exit 1
    }
    local val=$((16#${raw#0x}))
    if (( (val & 1) == 0 )); then
        echo "MCHBAR is disabled. Trying to enable..."
        local new_val=$(( val | 1 ))
        local new_hex=$(printf '%08x' $new_val)
        setpci -s 00:00.0 0x44.L=$new_hex
        raw=$(setpci -s 00:00.0 0x44.L 2>/dev/null)
        val=$((16#${raw#0x}))
        if (( (val & 1) == 0 )); then
            echo "Failed to enable MCHBAR. Hardware does not support MCHBAR."
            exit 1
        fi
        echo "MCHBAR successfully enabled."
    fi
    base=$(( val & 0xFFFFC000 ))
    echo "MCHBAR found at: 0x$(printf '%X' $base)"
    echo ""
}

read_mem32() {
    local offset=$1
    python3 - "$offset" <<'PYEOF'
import mmap, os, sys
offset = int(sys.argv[1])
page_size = os.sysconf('SC_PAGESIZE')
page_start = (offset // page_size) * page_size
page_offset = offset - page_start
try:
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    mm = mmap.mmap(fd, page_size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=page_start)
    mm.seek(page_offset)
    data = mm.read(4)
    mm.close()
    os.close(fd)
    print(int.from_bytes(data, 'little'))
except Exception:
    sys.exit(1)
PYEOF
}

write_mem32() {
    local offset=$1 val=$2
    python3 - "$offset" "$val" <<'PYEOF'
import mmap, os, sys
offset = int(sys.argv[1])
val = int(sys.argv[2])
page_size = os.sysconf('SC_PAGESIZE')
page_start = (offset // page_size) * page_size
page_offset = offset - page_start
try:
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    mm = mmap.mmap(fd, page_size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=page_start)
    mm.seek(page_offset)
    mm.write(val.to_bytes(4, 'little'))
    mm.close()
    os.close(fd)
except Exception:
    sys.exit(1)
PYEOF
}

decode_tcl()   { case $1 in 0) echo 5;; 1) echo 4;; 2) echo 3;; 3) echo 6;; *) echo "?";; esac; }
decode_rcd_rp() { case $1 in 0) echo 2;; 1) echo 3;; 2) echo 4;; 3) echo 5;; 4) echo 6;; *) echo "?";; esac; }
decode_trtp()   { case $1 in 0) echo 4;; 1) echo 5;; *) echo "?";; esac; }
decode_cke() {
    case $(( ($1 >> 30) & 0x3 )) in
        0) echo 1;; 1) echo "reserved";; 2) echo 3;; 3) echo "reserved";;
    esac
}

encode_tcl()   { case $1 in 3) echo 2;; 4) echo 1;; 5) echo 0;; 6) echo 3;; esac; }
encode_rcd_rp(){ case $1 in 2) echo 0;; 3) echo 1;; 4) echo 2;; 5) echo 3;; 6) echo 4;; esac; }
encode_trtp()  { case $1 in 4) echo 0;; 5) echo 1;; esac; }
encode_cke()   { case $1 in 1) echo 0;; 3) echo 2;; esac; }

get_field() {
    local reg=$1 bits=$2 shift=$3
    echo $(( (reg >> shift) & ((1 << bits) - 1) ))
}
set_field() {
    local reg=$1 bits=$2 shift=$3 value=$4
    local mask=$(( ~(((1 << bits) - 1) << shift) ))
    echo $(( (reg & mask) | (value << shift) ))
}

parse_dash_input() {
    local input="$1"
    local -n result=$2
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"

    if [[ -z "$input" ]]; then
        result=()
        return 0
    fi

    if [[ ! "$input" =~ ^[0-9[:space:]-]+$ ]]; then
        echo "Invalid input, use only digits and spaces."
        return 1
    fi

    if [[ "$input" == *"--"* ]]; then
        echo "Invalid input, do not use two dashes in a row."
        return 1
    fi

    IFS='-' read -ra parts <<< "$input"
    result=()
    for part in "${parts[@]}"; do
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        if [[ -n "$part" && ! "$part" =~ ^[0-9]+$ ]]; then
            echo "Error: value '$part' is not a number."
            return 1
        fi
        result+=("$part")
    done
    return 0
}

check_tras() {
    local tras=$1 tcl_input=$2 trcd_input=$3
    local tcl trcd
    if [[ -z "$tcl_input" ]]; then
        tcl=$(decode_tcl $(( (cur_drt1 >> 8) & 0x3 )) )
    else
        tcl=$tcl_input
    fi
    if [[ -z "$trcd_input" ]]; then
        trcd=$(decode_rcd_rp $(( (cur_drt1 >> 4) & 0x7 )) )
    else
        trcd=$trcd_input
    fi
    if (( tras < tcl + trcd )); then
        echo "Timing tRAS ($tras) must be at least tCL+$tcl + tRCD+$trcd = $((tcl+trcd))."
        return 1
    fi
    return 0
}

show_timings() {
    echo -e "\n[Reading MCHBAR registers]"
    echo ""
    local drt0=$(read_mem32 $((base + REG_DRT0)))
    local drt1=$(read_mem32 $((base + REG_DRT1)))
    local drt2=$(read_mem32 $((base + REG_DRT2)))
    local clk=$(read_mem32 $((base + REG_CLKCFG)))

    local freq=$(( (clk >> 4) & 0x7 ))
    case $freq in
        2) freq_mhz=400;; 3) freq_mhz=533;; *) freq_mhz="?";;
    esac

    local tcl=$(decode_tcl $(( (drt1 >> 8) & 0x3 )) )
    local trcd=$(decode_rcd_rp $(( (drt1 >> 4) & 0x7 )) )
    local trp=$(decode_rcd_rp $(( drt1 & 0x7 )) )
    local tras=$(( (drt1 >> 19) & 0x1F ))
    local trfc=$(( (drt1 >> 10) & 0x3F ))
    local trd=$(( (drt0 >> 11) & 0x1F ))
    (( trd < 3 || trd > 7 )) && trd="?"
    local trtp=$(decode_trtp $(( (drt1 >> 28) & 0x3 )) )
    local bbwr2pre=$(( (drt0 >> 24) & 0xFF ))
    local bbwr2rd=$(( (drt0 >> 20) & 0xF ))
    local cke=$(decode_cke $drt2)

    echo "================================="
    echo "========= RAM Frequency ========="
    echo "Frequency   : ${freq_mhz} MHz"
    echo "=========== Primary ============="
    echo "tCL        : ${tcl}"
    echo "tRCD       : ${trcd}"
    echo "tRP        : ${trp}"
    echo "tRAS       : ${tras}"
    echo "=========== Secondary ==========="
    echo "tRFC       : ${trfc}"
    echo "tRD        : ${trd}"
    echo "tRTP       : ${trtp}"
    echo "BBWR2PRE   : ${bbwr2pre}"
    echo "BBWR2RD    : ${bbwr2rd}"
    echo "=========== Tertiary ============"
    echo "CKE Deassert: ${cke}"
    echo "================================="
}

change_timings() {
    cur_drt0=$(read_mem32 $((base + REG_DRT0)))
    cur_drt1=$(read_mem32 $((base + REG_DRT1)))
    cur_drt2=$(read_mem32 $((base + REG_DRT2)))
    local prim_modified=false sec_modified=false tert_modified=false

    echo -e "\n====== PRIMARY TIMINGS ======"
    echo "Format: tCL-tRCD-tRP-tRAS (Like: 4-3-3-12 or 4- -4-12)"
    read -rp "Enter values: " prim_input
    if [[ -n "$prim_input" ]]; then
        if ! parse_dash_input "$prim_input" fields; then
            return 1
        fi
        if [[ ${#fields[@]} -ne 4 ]]; then
            echo "ERROR: expected 4 fields separated by dashes."
            return 1
        fi

        if [[ -n "${fields[0]}" ]]; then
            val=${fields[0]}
            (( val >= 3 && val <= 6 )) || { echo "tCL out of range 3-6."; return 1; }
            cur_drt1=$(set_field $cur_drt1 3 8 $(encode_tcl $val))
            prim_modified=true
        fi

        if [[ -n "${fields[1]}" ]]; then
            val=${fields[1]}
            (( val >= 2 && val <= 6 )) || { echo "tRCD out of range 2-6."; return 1; }
            cur_drt1=$(set_field $cur_drt1 3 4 $(encode_rcd_rp $val))
            prim_modified=true
        fi

        if [[ -n "${fields[2]}" ]]; then
            val=${fields[2]}
            (( val >= 2 && val <= 6 )) || { echo "tRP out of range 2-6."; return 1; }
            cur_drt1=$(set_field $cur_drt1 3 0 $(encode_rcd_rp $val))
            prim_modified=true
        fi

        if [[ -n "${fields[3]}" ]]; then
            val=${fields[3]}
            (( val >= 4 && val <= 18 )) || { echo "tRAS out of range 4-18."; return 1; }
            local tcl_set=${fields[0]} trcd_set=${fields[1]}
            check_tras $val "$tcl_set" "$trcd_set" || return 1
            cur_drt1=$(set_field $cur_drt1 5 19 $val)
            prim_modified=true
        fi
    fi

    echo -e "\n====== SECONDARY TIMINGS ======"
    echo "Format: tRFC-tRD-tRTP-BBWR2PRE-BBWR2RD (28-5-4-185-5)"
    read -rp "Enter values: " sec_input
    if [[ -n "$sec_input" ]]; then
        if ! parse_dash_input "$sec_input" fields; then
            return 1
        fi
        if [[ ${#fields[@]} -ne 5 ]]; then
            echo "ERROR: expected 5 fields."
            return 1
        fi

        if [[ -n "${fields[0]}" ]]; then
            val=${fields[0]}
            (( val >= 3 && val <= 63 )) || { echo "tRFC out of range 3-63."; return 1; }
            cur_drt1=$(set_field $cur_drt1 6 10 $val)
            sec_modified=true
        fi

        if [[ -n "${fields[1]}" ]]; then
            val=${fields[1]}
            (( val >= 3 && val <= 7 )) || { echo "tRD out of range 3-7."; return 1; }
            cur_drt0=$(set_field $cur_drt0 5 11 $val)
            sec_modified=true
        fi

        if [[ -n "${fields[2]}" ]]; then
            val=${fields[2]}
            (( val == 4 || val == 5 )) || { echo "tRTP must be 4 or 5."; return 1; }
            cur_drt1=$(set_field $cur_drt1 2 28 $(encode_trtp $val))
            sec_modified=true
        fi

        if [[ -n "${fields[3]}" ]]; then
            val=${fields[3]}
            (( val >= 4 && val <= 255 )) || { echo "BBWR2PRE out of range 4-255."; return 1; }
            cur_drt0=$(set_field $cur_drt0 8 24 $val)
            sec_modified=true
        fi

        if [[ -n "${fields[4]}" ]]; then
            val=${fields[4]}
            (( val >= 4 && val <= 15 )) || { echo "BBWR2RD out of range 4-15."; return 1; }
            cur_drt0=$(set_field $cur_drt0 4 20 $val)
            sec_modified=true
        fi
    fi

    echo -e "\n====== TERTIARY TIMINGS ======"
    echo "CKE Deassert Duration (1 or 3)"
    read -rp "Enter value: " tert_input
    if [[ -n "$tert_input" ]]; then
        tert_input="${tert_input//[[:space:]]/}"
        if [[ -n "$tert_input" ]]; then
            val="$tert_input"
            (( val == 1 || val == 3 )) || { echo "Allowed values are 1 or 3."; return 1; }
            cur_drt2=$(set_field $cur_drt2 2 30 $(encode_cke $val))
            tert_modified=true
        fi
    fi

    if ! $prim_modified && ! $sec_modified && ! $tert_modified; then
        echo "No timings were changed. Exiting."
        return 0
    fi

    echo -e "\nThe following writes will be performed to MCHBAR:"
    if $prim_modified || $sec_modified; then
        echo "  CODRT0 (0x$(printf '%X' $REG_DRT0)) -> 0x$(printf '%08X' $cur_drt0)"
        echo "  CODRT1 (0x$(printf '%X' $REG_DRT1)) -> 0x$(printf '%08X' $cur_drt1)"
    fi
    if $tert_modified; then
        echo "  CODRT2 (0x$(printf '%X' $REG_DRT2)) -> 0x$(printf '%08X' $cur_drt2)"
    fi
    read -rp "Changing timings may cause system instability. Continue? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Canceled."; return 0; }

    if $prim_modified || $sec_modified; then
        write_mem32 $((base + REG_DRT0)) $cur_drt0
        verify=$(read_mem32 $((base + REG_DRT0)))
        (( verify == cur_drt0 )) || { echo "ERROR writing CODRT0!"; return 1; }
        write_mem32 $((base + REG_DRT1)) $cur_drt1
        verify=$(read_mem32 $((base + REG_DRT1)))
        (( verify == cur_drt1 )) || { echo "ERROR writing CODRT1!"; return 1; }
    fi
    if $tert_modified; then
        write_mem32 $((base + REG_DRT2)) $cur_drt2
        verify=$(read_mem32 $((base + REG_DRT2)))
        (( verify == cur_drt2 )) || { echo "ERROR writing CODRT2!"; return 1; }
    fi

    echo "Timings successfully changed!"
}

check_environment
check_chipset
init_mchbar

echo "===================================="
echo "    945GSE RAM OC Timings v1.0.0"
echo "===================================="
echo "1. View current RAM timings."
echo "2. Set new RAM timings."
echo ""
read -rp "Your choice: " choice

case "$choice" in
    1) show_timings ;;
    2) change_timings ;;
    *) echo "Invalid input, choose 1 or 2."; exit 1 ;;
esac

exit 0
