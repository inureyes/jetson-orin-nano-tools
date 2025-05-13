#!/bin/bash
# MIT License
#
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

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEFAULT_SWAP_SIZE="16G"
SWAP_DIR="/swap"

# Function to display usage
show_usage() {
    echo -e "${BLUE}=== Swap Configuration Script Usage ===${NC}"
    echo
    echo "SYNOPSIS:"
    echo "    $0 [OPTIONS]"
    echo
    echo "DESCRIPTION:"
    echo "    This script configures swap on your system by:"
    echo "    - Disabling ZRAM service"
    echo "    - Creating a swap file with specified size"
    echo "    - Adding swap configuration to /etc/fstab for persistence"
    echo
    echo "OPTIONS:"
    echo "    -s, --size <SIZE>    Specify swap size (default: ${DEFAULT_SWAP_SIZE})"
    echo "                         Examples: 8G, 16G, 32G, etc."
    echo "    -h, --help           Display this help message"
    echo
    echo "EXAMPLES:"
    echo "    $0                   # Create 16G swap (default)"
    echo "    $0 -s 8G             # Create 8G swap"
    echo "    $0 --size 32G        # Create 32G swap"
    echo "    $0 -h                # Show this help"
    echo
    echo "NOTE:"
    echo "    This script requires root privileges (sudo)."
    echo
}

# Parse command line arguments
SWAP_SIZE="$DEFAULT_SWAP_SIZE"

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--size)
            SWAP_SIZE="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option '$1'${NC}"
            echo -e "${YELLOW}Use '$0 -h' for help.${NC}"
            exit 1
            ;;
    esac
done

# Validate swap size format
if ! [[ "$SWAP_SIZE" =~ ^[0-9]+[MG]$ ]]; then
    echo -e "${RED}Error: Invalid swap size format. Use format like '16G' or '512M'${NC}"
    exit 1
fi

SWAP_FILE="$SWAP_DIR/${SWAP_SIZE}.swap"

echo -e "${BLUE}=== Swap Configuration Script Started ===${NC}"
echo -e "${GREEN}Configuring swap with size: ${SWAP_SIZE}${NC}"

# 1. Disable ZRAM service
echo -e "${YELLOW}[1/5] Disabling ZRAM service...${NC}"
if sudo systemctl is-enabled nvzramconfig &>/dev/null; then
    sudo systemctl disable nvzramconfig
    echo -e "${GREEN}✓ ZRAM service has been disabled.${NC}"
else
    echo -e "${YELLOW}- ZRAM service is already disabled or does not exist.${NC}"
fi

# 2. Create swap directory
echo -e "${YELLOW}[2/5] Creating swap directory...${NC}"
if [ ! -d "$SWAP_DIR" ]; then
    sudo mkdir -p "$SWAP_DIR"
    echo -e "${GREEN}✓ Swap directory ($SWAP_DIR) has been created.${NC}"
else
    echo -e "${YELLOW}- Swap directory already exists.${NC}"
fi

# 3. Create swap file
echo -e "${YELLOW}[3/5] Creating swap file (${SWAP_SIZE})...${NC}"
if [ ! -f "$SWAP_FILE" ]; then
    sudo fallocate -l $SWAP_SIZE "$SWAP_FILE"
    # Fallback to dd command if fallocate fails
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}- fallocate failed, retrying with dd command...${NC}"
        # Convert size to MB for dd command
        if [[ "$SWAP_SIZE" =~ ([0-9]+)G ]]; then
            SIZE_IN_MB=$((${BASH_REMATCH[1]} * 1024))
        elif [[ "$SWAP_SIZE" =~ ([0-9]+)M ]]; then
            SIZE_IN_MB=${BASH_REMATCH[1]}
        fi
        sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$SIZE_IN_MB
    fi
    echo -e "${GREEN}✓ Swap file has been created.${NC}"
else
    echo -e "${YELLOW}- Swap file already exists.${NC}"
fi

# 4. Setup swap file
echo -e "${YELLOW}[4/5] Setting up swap file...${NC}"
sudo mkswap "$SWAP_FILE"
sudo swapon "$SWAP_FILE"
echo -e "${GREEN}✓ Swap has been activated.${NC}"

# 5. Add permanent mount to /etc/fstab
echo -e "${YELLOW}[5/5] Adding swap mount to /etc/fstab...${NC}"
FSTAB_LINE="$SWAP_FILE  none  swap  sw 0  0"

# Check if the line already exists
if grep -Fxq "$FSTAB_LINE" /etc/fstab; then
    echo -e "${YELLOW}- Swap configuration already exists in /etc/fstab.${NC}"
else
    echo "$FSTAB_LINE" | sudo tee -a /etc/fstab > /dev/null
    echo -e "${GREEN}✓ Swap configuration has been added to /etc/fstab.${NC}"
fi

# Check swap status
echo -e "\n${BLUE}=== Current Swap Status ===${NC}"
swapon -s
echo

# Script completion
echo -e "${GREEN}=== Swap Configuration Complete! ===${NC}"
echo -e "${GREEN}Script has been executed successfully.${NC}"
echo -e "${YELLOW}Recommendation: Reboot and verify that swap is automatically mounted.${NC}"