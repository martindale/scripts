#!/bin/bash

# Script to find wallet.dat files outside of ~/.bitcoin directory
# Uses locate and shasum to identify and checksum wallet files

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Header
echo -e "${BLUE}=== External Wallet Finder ===${NC}"
echo -e "${BLUE}Finding wallet.dat files outside ~/.bitcoin directory${NC}"
echo ""

# Check if locate database exists and is recent
if ! command -v locate &> /dev/null; then
    echo -e "${RED}Error: 'locate' command not found. Please install mlocate or updatedb.${NC}"
    exit 1
fi

# Bitcoin directory path
BITCOIN_DIR="$HOME/.bitcoin"

# Create temporary file for results
TEMP_FILE=$(mktemp)
trap "rm -f $TEMP_FILE" EXIT

echo -e "${YELLOW}Searching for wallet.dat files...${NC}"

# Create temporary files for processing
ALL_WALLETS_FILE=$(mktemp)
BITCOIN_HASHES_FILE=$(mktemp)
trap "rm -f $TEMP_FILE $ALL_WALLETS_FILE $BITCOIN_HASHES_FILE" EXIT

# First pass: collect ALL wallet.dat files with their hashes
locate wallet.dat 2>/dev/null | while read -r wallet_path; do
    # Skip if file doesn't exist (stale locate database)
    if [[ ! -f "$wallet_path" ]]; then
        continue
    fi
    
    # Calculate SHA256 checksum
    checksum=$(shasum -a 256 "$wallet_path" | cut -d' ' -f1)
    
    # Get file size and modification time for additional info
    file_size=$(stat -f%z "$wallet_path" 2>/dev/null || stat -c%s "$wallet_path" 2>/dev/null || echo "unknown")
    mod_time=$(stat -f%Sm -t "%Y-%m-%d %H:%M:%S" "$wallet_path" 2>/dev/null || stat -c%y "$wallet_path" 2>/dev/null | cut -d'.' -f1 || echo "unknown")
    
    # Get the directory containing the wallet
    wallet_dir=$(dirname "$wallet_path")
    
    # Mark if this is in the bitcoin directory
    if [[ "$wallet_dir" == "$BITCOIN_DIR"* ]]; then
        echo "$checksum" >> "$BITCOIN_HASHES_FILE"
    fi
    
    # Store all wallet info
    echo "$wallet_path|$checksum|$file_size|$mod_time|$wallet_dir" >> "$ALL_WALLETS_FILE"
done

# Second pass: filter out duplicates and bitcoin directory files
declare -A seen_hashes
while IFS='|' read -r wallet_path checksum file_size mod_time wallet_dir; do
    # Skip if we've already seen this hash
    if [[ -n "${seen_hashes[$checksum]:-}" ]]; then
        continue
    fi
    
    # Skip if this hash exists in ~/.bitcoin directory
    if grep -q "^$checksum$" "$BITCOIN_HASHES_FILE" 2>/dev/null; then
        continue
    fi
    
    # Mark this hash as seen
    seen_hashes[$checksum]=1
    
    # Only include files NOT in ~/.bitcoin directory
    if [[ "$wallet_dir" != "$BITCOIN_DIR"* ]]; then
        echo "$wallet_path|$checksum|$file_size|$mod_time" >> "$TEMP_FILE"
    fi
done < "$ALL_WALLETS_FILE"

# Check if any external wallets were found
if [[ ! -s "$TEMP_FILE" ]]; then
    echo -e "${GREEN}No wallet.dat files found outside ~/.bitcoin directory.${NC}"
    exit 0
fi

# Display results
echo -e "${YELLOW}External wallet.dat files found:${NC}"
echo ""
printf "%-60s %-66s %-12s %s\n" "Path" "SHA256 Checksum" "Size (bytes)" "Modified"
printf "%-60s %-66s %-12s %s\n" "----" "----------------" "------------" "--------"

while IFS='|' read -r path checksum size mod_time; do
    printf "%-60s %-66s %-12s %s\n" "$path" "$checksum" "$size" "$mod_time"
done < "$TEMP_FILE"

echo ""
echo -e "${GREEN}Total external wallets found: $(wc -l < "$TEMP_FILE")${NC}"

# Optional: Check if ~/.bitcoin directory exists
if [[ ! -d "$BITCOIN_DIR" ]]; then
    echo ""
    echo -e "${YELLOW}Note: ~/.bitcoin directory does not exist.${NC}"
    echo -e "${YELLOW}All wallet.dat files are considered 'external'.${NC}"
fi

# Optional: Suggest updating locate database if it's old
locate_db_path=$(locate -S 2>/dev/null | head -1 | grep -o '/[^:]*' || echo "")
if [[ -n "$locate_db_path" && -f "$locate_db_path" ]]; then
    db_age_days=$(( ($(date +%s) - $(stat -f%m "$locate_db_path" 2>/dev/null || stat -c%Y "$locate_db_path" 2>/dev/null || echo 0)) / 86400 ))
    if [[ $db_age_days -gt 7 ]]; then
        echo ""
        echo -e "${YELLOW}Note: locate database is $db_age_days days old.${NC}"
        echo -e "${YELLOW}Consider running 'sudo updatedb' for more recent results.${NC}"
    fi
fi 