#!/bin/bash

#
# Partition Extension Script
# Copyright (c) 2025 Jeongkyu Shin <jshin@lablup.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Display usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] <device>

Extend main partition to use remaining unallocated space on SSD.

OPTIONS:
    -h          Show this help message
    -s SIZE     Specify the size to extend (e.g., 10G, 500M, 100%)
                Default: use all available unallocated space
    -y          Skip confirmation prompt (auto-yes)
    -v          Verbose output

EXAMPLES:
    $0 /dev/sdb                    # Extend to use all available space
    $0 -s 10G /dev/sdb            # Extend by 10 GB
    $0 -s 50% /dev/sdb            # Extend by 50% of unallocated space
    $0 -y /dev/sdb                # Extend automatically without confirmation

NOTES:
    - This script requires root privileges
    - Always backup your data before resizing partitions
    - The script automatically detects the main partition to extend
    - Supports both GPT and MBR partition tables

EOF
}

# Print error message and exit
error_exit() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

# Print info message
info() {
    echo -e "${BLUE}Info: $1${NC}"
}

# Print success message
success() {
    echo -e "${GREEN}Success: $1${NC}"
}

# Print warning message
warning() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

# Check for root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root. Please use sudo."
    fi
}

# Check for required dependencies
check_dependencies() {
    local deps=("parted" "fdisk" "lsblk" "resize2fs" "xfs_growfs")
    local missing=()
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error_exit "Missing required tools: ${missing[*]}. Please install them first."
    fi
}

# Verify device exists
check_device() {
    local device="$1"
    if [[ ! -b "$device" ]]; then
        error_exit "Device $device does not exist or is not a block device."
    fi
}

# Detect the main partition (largest partition)
detect_main_partition() {
    local device="$1"
    local main_partition=""
    
    # Consider the largest partition as the main partition
    main_partition=$(lsblk -rno NAME,SIZE "$device" | grep -E "^${device#/dev/}p?[0-9]+\s" | \
                    sort -k2 -hr | head -n1 | awk '{print "/dev/"$1}')
    
    if [[ -z "$main_partition" ]]; then
        error_exit "Could not detect main partition on $device"
    fi
    
    echo "$main_partition"
}

# Detect filesystem type
detect_filesystem() {
    local partition="$1"
    local fstype=$(lsblk -no FSTYPE "$partition" 2>/dev/null)
    
    if [[ -z "$fstype" ]]; then
        warning "Could not detect filesystem type for $partition"
        echo "unknown"
    else
        echo "$fstype"
    fi
}

# Calculate unallocated space
get_unallocated_space() {
    local device="$1"
    local info=$(parted "$device" unit MB print free 2>/dev/null)
    local unallocated=$(echo "$info" | awk '/Free Space/ {gsub(/MB/, "", $3); total+=$3} END {print total+0}')
    echo "$unallocated"
}

# Extend partition
extend_partition() {
    local device="$1"
    local partition="$2"
    local size="$3"
    local verbose="$4"
    
    # Extract partition number
    local part_num=$(echo "$partition" | grep -oE '[0-9]+$')
    
    info "Extending partition $partition..."
    
    # Use parted to extend partition
    if [[ "$size" == "100%" || "$size" == "" ]]; then
        parted "$device" resizepart "$part_num" 100% &>/dev/null
    else
        # Get current partition end position
        local current_end=$(parted "$device" unit MB print | awk -v part="$part_num" '$1==part {gsub(/MB/, "", $3); print $3}')
        local new_end=$((current_end + ${size%MB}))
        parted "$device" resizepart "$part_num" "${new_end}MB" &>/dev/null
    fi
    
    if [[ $? -ne 0 ]]; then
        error_exit "Failed to extend partition $partition"
    fi
    
    success "Partition extended successfully"
}

# Extend filesystem
extend_filesystem() {
    local partition="$1"
    local fstype="$2"
    local verbose="$3"
    
    info "Extending filesystem on $partition (type: $fstype)..."
    
    case "$fstype" in
        ext2|ext3|ext4)
            # For ext filesystems, check filesystem first
            if [[ "$verbose" == "true" ]]; then
                e2fsck -f "$partition"
            else
                e2fsck -f "$partition" &>/dev/null
            fi
            
            # Extend filesystem
            if [[ "$verbose" == "true" ]]; then
                resize2fs "$partition"
            else
                resize2fs "$partition" &>/dev/null
            fi
            ;;
        xfs)
            # For XFS filesystem (must be mounted)
            local mountpoint=$(lsblk -no MOUNTPOINT "$partition" | head -n1)
            if [[ -n "$mountpoint" ]]; then
                if [[ "$verbose" == "true" ]]; then
                    xfs_growfs "$mountpoint"
                else
                    xfs_growfs "$mountpoint" &>/dev/null
                fi
            else
                warning "XFS filesystem needs to be mounted to extend. Please mount and run xfs_growfs manually."
                return 1
            fi
            ;;
        btrfs)
            # For Btrfs filesystem
            local mountpoint=$(lsblk -no MOUNTPOINT "$partition" | head -n1)
            if [[ -n "$mountpoint" ]]; then
                if [[ "$verbose" == "true" ]]; then
                    btrfs filesystem resize max "$mountpoint"
                else
                    btrfs filesystem resize max "$mountpoint" &>/dev/null
                fi
            else
                warning "Btrfs filesystem needs to be mounted to extend. Please mount and run btrfs resize manually."
                return 1
            fi
            ;;
        *)
            warning "Unsupported filesystem type: $fstype. Partition extended but filesystem not resized."
            warning "You may need to resize the filesystem manually."
            return 1
            ;;
    esac
    
    if [[ $? -eq 0 ]]; then
        success "Filesystem extended successfully"
    else
        error_exit "Failed to extend filesystem"
    fi
}

# Parse and validate size
parse_size() {
    local size="$1"
    local unallocated="$2"
    
    if [[ "$size" =~ ^[0-9]+%$ ]]; then
        # Percentage size
        local percent=${size%\%}
        local calculated=$((unallocated * percent / 100))
        echo "${calculated}MB"
    elif [[ "$size" =~ ^[0-9]+[GMK]B?$ ]]; then
        # Absolute size
        echo "$size"
    else
        error_exit "Invalid size format: $size. Use formats like 10G, 500M, or 50%"
    fi
}

# Main function
main() {
    local device=""
    local size=""
    local auto_yes=false
    local verbose=false
    
    # Parse options
    while getopts "hs:yv" opt; do
        case $opt in
            h)
                show_usage
                exit 0
                ;;
            s)
                size="$OPTARG"
                ;;
            y)
                auto_yes=true
                ;;
            v)
                verbose=true
                ;;
            \?)
                echo "Invalid option: -$OPTARG" >&2
                show_usage
                exit 1
                ;;
        esac
    done
    
    shift $((OPTIND-1))
    
    # Check device argument
    if [[ $# -ne 1 ]]; then
        error_exit "Please specify a device. Use -h for help."
    fi
    
    device="$1"
    
    # Pre-validation checks
    check_root
    check_dependencies
    check_device "$device"
    
    # Collect device information
    info "Analyzing device $device..."
    
    local main_partition=$(detect_main_partition "$device")
    local fstype=$(detect_filesystem "$main_partition")
    local unallocated=$(get_unallocated_space "$device")
    
    if [[ "$verbose" == "true" ]]; then
        info "Main partition: $main_partition"
        info "Filesystem type: $fstype"
        info "Unallocated space: ${unallocated}MB"
    fi
    
    # Check unallocated space
    if [[ "$unallocated" -le 0 ]]; then
        info "No unallocated space found. Nothing to extend."
        exit 0
    fi
    
    # Validate size
    if [[ -n "$size" ]]; then
        local parsed_size=$(parse_size "$size" "$unallocated")
        local size_mb=${parsed_size%MB}
        
        if [[ "$size_mb" -gt "$unallocated" ]]; then
            error_exit "Requested size (${size_mb}MB) exceeds available unallocated space (${unallocated}MB)"
        fi
        
        info "Will extend by $parsed_size"
    else
        info "Will extend by all available space (${unallocated}MB)"
    fi
    
    # Confirmation prompt
    if [[ "$auto_yes" != "true" ]]; then
        echo
        warning "This operation will modify partition table and filesystem."
        warning "Please ensure you have backed up your data."
        echo
        read -p "Do you want to continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Operation cancelled by user."
            exit 0
        fi
    fi
    
    # Perform partition extension
    echo
    extend_partition "$device" "$main_partition" "$size" "$verbose"
    
    # Extend filesystem
    extend_filesystem "$main_partition" "$fstype" "$verbose"
    
    # Show results
    echo
    success "Partition extension completed successfully!"
    
    if [[ "$verbose" == "true" ]]; then
        echo
        info "Updated partition information:"
        lsblk "$device"
    fi
}

# Execute script
main "$@"
