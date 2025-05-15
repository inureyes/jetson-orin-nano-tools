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
    -f          Force resize even for mounted root/boot partitions (DANGEROUS)

EXAMPLES:
    $0 /dev/sdb                    # Extend to use all available space
    $0 -s 10G /dev/sdb            # Extend by 10 GB
    $0 -s 50% /dev/sdb            # Extend by 50% of unallocated space
    $0 -y /dev/sdb                # Extend automatically without confirmation
    $0 -f /dev/sdb                # Force resize even for root partition (RISKY)

NOTES:
    - This script requires root privileges
    - Always backup your data before resizing partitions
    - The script automatically detects the main partition to extend
    - Supports both GPT and MBR partition tables
    - Use -f flag only if you understand the risks for mounted root/boot partitions

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
    local fstype
    fstype=$(lsblk -no FSTYPE "$partition" 2>/dev/null)
    
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
    local info
    local unallocated
    info=$(parted "$device" unit MB print free 2>/dev/null)
    unallocated=$(echo "$info" | awk '/Free Space/ {gsub(/MB/, "", $3); total+=$3} END {print total+0}')
    echo "$unallocated"
}

# Show progress bar (simple implementation)
show_progress() {
    local duration="$1"
    local message="$2"
    
    echo -n "$message"
    for ((i=0; i<=100; i+=2)); do
        printf "\r$message [%3d%%] " "$i"
        printf "["
        for ((j=0; j<i/2; j++)); do printf "="; done
        printf ">"
        for ((j=i/2; j<50; j++)); do printf " "; done
        printf "]"
        sleep 0.1
    done
    printf "\n"
}

# Extend filesystem with progress indication
extend_filesystem() {
    local partition="$1"
    local fstype="$2"
    local verbose="$3"
    
    info "Extending filesystem on $partition (type: $fstype)..."
    
    case "$fstype" in
        ext2|ext3|ext4)
            # Check if partition is mounted
            local mountpoint
            mountpoint=$(lsblk -no MOUNTPOINT "$partition" 2>/dev/null)
            
            if [[ -n "$mountpoint" ]]; then
                # For mounted ext4 filesystems, skip filesystem check and do online resize
                info "Partition is mounted at $mountpoint. Performing online resize..."
                info "Skipping filesystem check for mounted partition."
                
                # Direct resize for mounted filesystem
                info "Resizing filesystem... This may take several minutes."
                local resize_exit_code
                if [[ "$verbose" == "true" ]]; then
                    # Use -p flag for progress bar
                    resize2fs -p "$partition"
                    resize_exit_code=$?
                else
                    # Run resize2fs with progress to a log file and show our progress
                    (resize2fs -p "$partition" > /tmp/resize_progress.log 2>&1) &
                    local resize_pid=$!
                    
                    # Monitor progress from log file
                    while kill -0 "$resize_pid" 2>/dev/null; do
                        if [[ -f /tmp/resize_progress.log ]]; then
                            # Extract progress percentage if available
                            local progress
                            progress=$(tail -n1 /tmp/resize_progress.log 2>/dev/null | grep -oE '[0-9]+\.[0-9]+%' | tail -n1)
                            if [[ -n "$progress" ]]; then
                                printf "\rProgress: %s" "$progress"
                            else
                                printf "."
                            fi
                        else
                            printf "."
                        fi
                        sleep 1
                    done
                    printf "\n"
                    wait "$resize_pid"
                    resize_exit_code=$?
                    rm -f /tmp/resize_progress.log
                fi
            else
                # For unmounted ext filesystems, check filesystem first
                info "Checking filesystem integrity..."
                local check_exit_code
                if [[ "$verbose" == "true" ]]; then
                    e2fsck -f "$partition"
                    check_exit_code=$?
                else
                    # Show progress during filesystem check
                    e2fsck -f -C 0 "$partition" 2>/dev/null &
                    local check_pid=$!
                    
                    # Show a simple progress indicator
                    while kill -0 "$check_pid" 2>/dev/null; do
                        printf "."
                        sleep 1
                    done
                    wait "$check_pid"
                    check_exit_code=$?
                    printf "\n"
                fi
                
                # Check if filesystem check was successful
                if [[ $check_exit_code -ne 0 && $check_exit_code -ne 1 ]]; then
                    # Exit code 1 is normal for corrected errors
                    echo "Filesystem check failed (exit code: $check_exit_code)"
                    return 1
                fi
                
                # Extend filesystem with progress
                info "Resizing filesystem... This may take several minutes."
                local resize_exit_code
                if [[ "$verbose" == "true" ]]; then
                    # Use -p flag for progress bar
                    resize2fs -p "$partition"
                    resize_exit_code=$?
                else
                    # Run resize2fs with progress to a log file and show our progress
                    (resize2fs -p "$partition" > /tmp/resize_progress.log 2>&1) &
                    local resize_pid=$!
                    
                    # Monitor progress from log file
                    while kill -0 "$resize_pid" 2>/dev/null; do
                        if [[ -f /tmp/resize_progress.log ]]; then
                            # Extract progress percentage if available
                            local progress
                            progress=$(tail -n1 /tmp/resize_progress.log 2>/dev/null | grep -oE '[0-9]+\.[0-9]+%' | tail -n1)
                            if [[ -n "$progress" ]]; then
                                printf "\rProgress: %s" "$progress"
                            else
                                printf "."
                            fi
                        else
                            printf "."
                        fi
                        sleep 1
                    done
                    printf "\n"
                    wait "$resize_pid"
                    resize_exit_code=$?
                    rm -f /tmp/resize_progress.log
                fi
            fi
            
            if [[ $resize_exit_code -ne 0 ]]; then
                echo "Failed to resize ext filesystem (exit code: $resize_exit_code)"
                return 1
            fi
            ;;
        xfs)
            # For XFS filesystem (must be mounted)
            local mountpoint
            mountpoint=$(lsblk -no MOUNTPOINT "$partition" | head -n1)
            if [[ -n "$mountpoint" ]]; then
                info "Extending XFS filesystem (online resize)..."
                local xfs_exit_code
                if [[ "$verbose" == "true" ]]; then
                    xfs_growfs -d "$mountpoint"
                    xfs_exit_code=$?
                else
                    # XFS resize is usually very quick
                    show_progress 3 "Extending XFS filesystem"
                    xfs_growfs -d "$mountpoint" &>/dev/null &
                    wait $!
                    xfs_exit_code=$?
                fi
                
                if [[ $xfs_exit_code -ne 0 ]]; then
                    echo "Failed to extend XFS filesystem (exit code: $xfs_exit_code)"
                    return 1
                fi
            else
                echo "XFS filesystem needs to be mounted to extend. Please mount and run xfs_growfs manually."
                return 1
            fi
            ;;
        btrfs)
            # For Btrfs filesystem
            local mountpoint
            mountpoint=$(lsblk -no MOUNTPOINT "$partition" | head -n1)
            if [[ -n "$mountpoint" ]]; then
                info "Extending Btrfs filesystem (online resize)..."
                local btrfs_exit_code
                if [[ "$verbose" == "true" ]]; then
                    btrfs filesystem resize max "$mountpoint"
                    btrfs_exit_code=$?
                else
                    # Btrfs resize is usually very quick
                    show_progress 2 "Extending Btrfs filesystem"
                    btrfs filesystem resize max "$mountpoint" &>/dev/null &
                    wait $!
                    btrfs_exit_code=$?
                fi
                
                if [[ $btrfs_exit_code -ne 0 ]]; then
                    echo "Failed to extend Btrfs filesystem (exit code: $btrfs_exit_code)"
                    return 1
                fi
            else
                echo "Btrfs filesystem needs to be mounted to extend. Please mount and run btrfs resize manually."
                return 1
            fi
            ;;
        *)
            warning "Unsupported filesystem type: $fstype. Partition extended but filesystem not resized."
            warning "You may need to resize the filesystem manually."
            return 1
            ;;
    esac
    
    success "Filesystem extended successfully"
    return 0
}

# Estimate filesystem resize time and show it to user
estimate_resize_time() {
    local partition="$1"
    local fstype="$2"
    local size_mb="$3"
    
    case "$fstype" in
        ext2|ext3|ext4)
            # Rough estimate: 1-2 minutes per 100GB on SSD, 3-5 minutes on HDD
            local estimated_minutes=$(( (size_mb / 1024 / 100) * 2 ))
            if [[ $estimated_minutes -lt 1 ]]; then
                estimated_minutes=1
            fi
            info "Estimated time for ext filesystem resize: approximately $estimated_minutes minute(s)"
            info "Actual time may vary depending on disk speed and usage patterns"
            ;;
        xfs|btrfs)
            info "XFS/Btrfs online resize typically completes in seconds to minutes"
            ;;
    esac
}

# Extend filesystem with progress indication
extend_filesystem() {
    local partition="$1"
    local fstype="$2"
    local verbose="$3"
    
    info "Extending filesystem on $partition (type: $fstype)..."
    
    case "$fstype" in
        ext2|ext3|ext4)
            # For ext filesystems, check filesystem first
            info "Checking filesystem integrity..."
            local check_exit_code
            if [[ "$verbose" == "true" ]]; then
                e2fsck -f "$partition"
                check_exit_code=$?
            else
                # Show progress during filesystem check
                e2fsck -f -C 0 "$partition" 2>/dev/null &
                local check_pid=$!
                
                # Show a simple progress indicator
                while kill -0 "$check_pid" 2>/dev/null; do
                    printf "."
                    sleep 1
                done
                wait "$check_pid"
                check_exit_code=$?
                printf "\n"
            fi
            
            # Check if filesystem check was successful
            if [[ $check_exit_code -ne 0 && $check_exit_code -ne 1 ]]; then
                # Exit code 1 is normal for corrected errors
                echo "Filesystem check failed (exit code: $check_exit_code)"
                return 1
            fi
            
            # Extend filesystem with progress
            info "Resizing filesystem... This may take several minutes."
            local resize_exit_code
            if [[ "$verbose" == "true" ]]; then
                # Use -p flag for progress bar
                resize2fs -p "$partition"
                resize_exit_code=$?
            else
                # Run resize2fs with progress to a log file and show our progress
                (resize2fs -p "$partition" > /tmp/resize_progress.log 2>&1) &
                local resize_pid=$!
                
                # Monitor progress from log file
                while kill -0 "$resize_pid" 2>/dev/null; do
                    if [[ -f /tmp/resize_progress.log ]]; then
                        # Extract progress percentage if available
                        local progress
                        progress=$(tail -n1 /tmp/resize_progress.log 2>/dev/null | grep -oE '[0-9]+\.[0-9]+%' | tail -n1)
                        if [[ -n "$progress" ]]; then
                            printf "\rProgress: %s" "$progress"
                        else
                            printf "."
                        fi
                    else
                        printf "."
                    fi
                    sleep 1
                done
                printf "\n"
                wait "$resize_pid"
                resize_exit_code=$?
                rm -f /tmp/resize_progress.log
            fi
            
            if [[ $resize_exit_code -ne 0 ]]; then
                echo "Failed to resize ext filesystem (exit code: $resize_exit_code)"
                return 1
            fi
            ;;
        xfs)
            # For XFS filesystem (must be mounted)
            local mountpoint
            mountpoint=$(lsblk -no MOUNTPOINT "$partition" | head -n1)
            if [[ -n "$mountpoint" ]]; then
                info "Extending XFS filesystem (online resize)..."
                local xfs_exit_code
                if [[ "$verbose" == "true" ]]; then
                    xfs_growfs -d "$mountpoint"
                    xfs_exit_code=$?
                else
                    # XFS resize is usually very quick
                    show_progress 3 "Extending XFS filesystem"
                    xfs_growfs -d "$mountpoint" &>/dev/null &
                    wait $!
                    xfs_exit_code=$?
                fi
                
                if [[ $xfs_exit_code -ne 0 ]]; then
                    echo "Failed to extend XFS filesystem (exit code: $xfs_exit_code)"
                    return 1
                fi
            else
                echo "XFS filesystem needs to be mounted to extend. Please mount and run xfs_growfs manually."
                return 1
            fi
            ;;
        btrfs)
            # For Btrfs filesystem
            local mountpoint
            mountpoint=$(lsblk -no MOUNTPOINT "$partition" | head -n1)
            if [[ -n "$mountpoint" ]]; then
                info "Extending Btrfs filesystem (online resize)..."
                local btrfs_exit_code
                if [[ "$verbose" == "true" ]]; then
                    btrfs filesystem resize max "$mountpoint"
                    btrfs_exit_code=$?
                else
                    # Btrfs resize is usually very quick
                    show_progress 2 "Extending Btrfs filesystem"
                    btrfs filesystem resize max "$mountpoint" &>/dev/null &
                    wait $!
                    btrfs_exit_code=$?
                fi
                
                if [[ $btrfs_exit_code -ne 0 ]]; then
                    echo "Failed to extend Btrfs filesystem (exit code: $btrfs_exit_code)"
                    return 1
                fi
            else
                echo "Btrfs filesystem needs to be mounted to extend. Please mount and run btrfs resize manually."
                return 1
            fi
            ;;
        *)
            warning "Unsupported filesystem type: $fstype. Partition extended but filesystem not resized."
            warning "You may need to resize the filesystem manually."
            return 1
            ;;
    esac
    
    success "Filesystem extended successfully"
    return 0
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
    local force_resize=false
    
    # Parse options
    while getopts "hs:yvf" opt; do
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
            f)
                force_resize=true
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
    
    local main_partition
    local fstype
    local unallocated
    main_partition=$(detect_main_partition "$device")
    fstype=$(detect_filesystem "$main_partition")
    unallocated=$(get_unallocated_space "$device")
    
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
        local parsed_size
        parsed_size=$(parse_size "$size" "$unallocated")
        local size_mb=${parsed_size%MB}
        
        if [[ "$size_mb" -gt "$unallocated" ]]; then
            error_exit "Requested size (${size_mb}MB) exceeds available unallocated space (${unallocated}MB)"
        fi
        
        info "Will extend by $parsed_size"
    else
        info "Will extend by all available space (${unallocated}MB)"
    fi
    
    # Show time estimate before starting
    local total_size_mb
    total_size_mb=$(lsblk -bno SIZE "$main_partition" | head -n1)
    total_size_mb=$((total_size_mb / 1024 / 1024))
    estimate_resize_time "$main_partition" "$fstype" "$total_size_mb"
    
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
    
    # Perform partition extension with force flag
    echo
    if ! extend_partition "$device" "$main_partition" "$size" "$verbose" "$force_resize"; then
        error_exit "Partition extension failed. Aborting script."
    fi
    
    # Extend filesystem
    if ! extend_filesystem "$main_partition" "$fstype" "$verbose"; then
        error_exit "Filesystem extension failed. Partition was resized but filesystem extension failed."
    fi
    
    # Show results only if both operations succeeded
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