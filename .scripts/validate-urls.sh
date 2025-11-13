#!/bin/bash

set -e  # Exit on error

echo "=== Starting URL validation process ==="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if we should validate all files
VALIDATE_MODE="changed"
if [ ! -z "$1" ] && [ "$1" == "--all" ]; then
    VALIDATE_MODE="all"
fi

# Function to get changed file_*.cfg files compared to master/main
get_changed_files() {
    # Determine the default branch (master or main)
    local default_branch=""
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
        default_branch="origin/main"
    elif git rev-parse --verify origin/master >/dev/null 2>&1; then
        default_branch="origin/master"
    else
        echo -e "${YELLOW}WARNING: Could not find origin/main or origin/master. Checking all files.${NC}" >&2
        echo ""
        return
    fi
    
    echo -e "${BLUE}Comparing with $default_branch...${NC}" >&2
    
    # Get changed/added file_*.cfg files
    local changed_files=$(git diff --name-only $default_branch...HEAD | grep '^file_.*\.cfg$' || true)
    
    if [ -z "$changed_files" ]; then
        echo -e "${BLUE}No file_*.cfg files changed in this branch${NC}" >&2
    else
        echo -e "${BLUE}Changed files:${NC}" >&2
        echo "$changed_files" | while read -r file; do
            echo -e "${BLUE}  - $file${NC}" >&2
        done
    fi
    
    echo "$changed_files"
}

# Function to check URL returns 200 OK
check_url() {
    local url=$1
    local field_name=$2
    local section=$3
    local file=$4
    
    echo -n "  Checking $field_name: $url ... " >&2
    
    # Use curl to get HTTP status code
    # -L: follow redirects
    # -s: silent mode
    # -o /dev/null: discard output
    # -w "%{http_code}": output only the HTTP status code
    # --max-time 10: timeout after 10 seconds
    local http_code=$(curl -L -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
    
    if [ "$http_code" == "200" ]; then
        echo -e "${GREEN}✓ OK (200)${NC}" >&2
        return 0
    else
        echo -e "${RED}✗ FAILED (HTTP $http_code)${NC}" >&2
        echo -e "${RED}ERROR in $file [$section]: $field_name returned HTTP $http_code${NC}" >&2
        echo -e "${RED}URL: $url${NC}" >&2
        return 1
    fi
}

# Function to check image URL returns 200 OK and is an image
check_image_url() {
    local url=$1
    local field_name=$2
    local section=$3
    local file=$4
    
    echo -n "  Checking $field_name: $url ... " >&2
    
    # Use curl to get HTTP status code and content type
    # -L: follow redirects
    # -s: silent mode
    # -o /dev/null: discard output
    # -w "%{http_code}|%{content_type}": output HTTP status code and content type
    # --max-time 10: timeout after 10 seconds
    local response=$(curl -L -s -o /dev/null -w "%{http_code}|%{content_type}" --max-time 10 "$url" 2>/dev/null || echo "000|unknown")
    local http_code=$(echo "$response" | cut -d'|' -f1)
    local content_type=$(echo "$response" | cut -d'|' -f2)
    
    if [ "$http_code" != "200" ]; then
        echo -e "${RED}✗ FAILED (HTTP $http_code)${NC}" >&2
        echo -e "${RED}ERROR in $file [$section]: $field_name returned HTTP $http_code${NC}" >&2
        echo -e "${RED}URL: $url${NC}" >&2
        return 1
    fi
    
    # Check if content type starts with "image/"
    if [[ "$content_type" =~ ^image/ ]]; then
        # Download image to temporary file to check dimensions
        local temp_file=$(mktemp)
        if curl -L -s --max-time 30 -o "$temp_file" "$url" 2>/dev/null; then
            # Check if ImageMagick identify is available
            if command -v identify >/dev/null 2>&1; then
                # Get image dimensions using ImageMagick
                local dimensions=$(identify -format "%wx%h" "$temp_file" 2>/dev/null || echo "")
                if [ ! -z "$dimensions" ]; then
                    local width=$(echo "$dimensions" | cut -d'x' -f1)
                    local height=$(echo "$dimensions" | cut -d'x' -f2)
                    
                    # Debug: Print dimensions
                    echo -e "${BLUE}    📏 Image dimensions: ${width}x${height}${NC}" >&2
                    
                    # Calculate aspect ratio (width/height)
                    local aspect_ratio=$(echo "scale=4; $width / $height" | bc 2>/dev/null || echo "0")
                    
                    # Debug: Print calculated aspect ratio
                    echo -e "${BLUE}    📐 Aspect ratio: ${aspect_ratio}:1 (target: ~2.1395:1)${NC}" >&2
                    
                    # Target aspect ratio: 460/215 ≈ 2.1395
                    local target_ratio="2.1395"
                    
                    # Check if aspect ratio is within tolerance (±0.1)
                    local ratio_diff=$(echo "scale=4; ($aspect_ratio - $target_ratio)^2" | bc 2>/dev/null || echo "1")
                    local tolerance="0.1"
                    
                    if (( $(echo "$ratio_diff < $tolerance^2" | bc -l 2>/dev/null || echo "0") )); then
                        echo -e "${GREEN}✓ OK (200, $content_type, ${width}x${height})${NC}" >&2
                        rm -f "$temp_file"
                        return 0
                    else
                        echo -e "${RED}✗ FAILED (wrong aspect ratio: ${width}x${height} = ${aspect_ratio}:1, expected ~${target_ratio}:1)${NC}" >&2
                        echo -e "${RED}ERROR in $file [$section]: $field_name has wrong aspect ratio (expected 460:215)${NC}" >&2
                        echo -e "${RED}URL: $url${NC}" >&2
                        rm -f "$temp_file"
                        return 1
                    fi
                else
                    echo -e "${YELLOW}⚠ WARNING: Could not determine image dimensions (identify command failed)${NC}" >&2
                    echo -e "${GREEN}✓ OK (200, $content_type, dimensions unknown)${NC}" >&2
                    rm -f "$temp_file"
                    return 0
                fi
            else
                echo -e "${YELLOW}⚠ WARNING: ImageMagick not available, skipping dimension check${NC}" >&2
                echo -e "${YELLOW}    💡 Install ImageMagick to enable aspect ratio validation${NC}" >&2
                echo -e "${GREEN}✓ OK (200, $content_type)${NC}" >&2
                rm -f "$temp_file"
                return 0
            fi
        else
            echo -e "${RED}✗ FAILED (could not download image)${NC}" >&2
            echo -e "${RED}ERROR in $file [$section]: Could not download $field_name${NC}" >&2
            echo -e "${RED}URL: $url${NC}" >&2
            rm -f "$temp_file"
            return 1
        fi
    else
        echo -e "${RED}✗ FAILED (not an image, Content-Type: $content_type)${NC}" >&2
        echo -e "${RED}ERROR in $file [$section]: $field_name is not an image (Content-Type: $content_type)${NC}" >&2
        echo -e "${RED}URL: $url${NC}" >&2
        return 1
    fi
}

# Function to validate URLs in a single .cfg file
validate_urls_in_file() {
    local file=$1
    echo -e "${BLUE}Validating URLs in $file...${NC}" >&2
    
    # Check if file exists
    if [ ! -f "$file" ]; then
        echo -e "${RED}ERROR: File $file does not exist${NC}" >&2
        exit 1
    fi
    
    local has_errors=0
    
    # Parse the file and check each section
    local sections=$(grep -E '^\[link_[0-9]+\]' "$file" | sed 's/\[//g' | sed 's/\]//g')
    
    for section in $sections; do
        echo -e "${BLUE}[$section]${NC}" >&2
        
        # Extract the entire section content
        local section_content=$(awk -v section="$section" '
            /^\[/ { 
                if (in_section) exit
                current=$0; gsub(/[\[\]]/, "", current)
                if (current == section) {
                    in_section=1
                    next
                }
            }
            in_section { print }
        ' "$file")
        
        # Extract URLs
        local url=$(echo "$section_content" | grep '^url=' | cut -d'=' -f2-)
        local dev_link=$(echo "$section_content" | grep '^dev_link=' | cut -d'=' -f2-)
        local preview_image=$(echo "$section_content" | grep '^preview_image=' | cut -d'=' -f2-)
        
        # Check each URL
        if [ ! -z "$url" ]; then
            if ! check_url "$url" "url" "$section" "$file"; then
                has_errors=1
            fi
        fi
        
        if [ ! -z "$dev_link" ]; then
            if ! check_url "$dev_link" "dev_link" "$section" "$file"; then
                has_errors=1
            fi
        fi
        
        if [ ! -z "$preview_image" ]; then
            if ! check_image_url "$preview_image" "preview_image" "$section" "$file"; then
                has_errors=1
            fi
        fi
        
        echo "" >&2
    done
    
    return $has_errors
}

# Main execution
echo ""
echo "=== Finding changed files ==="

if [ "$VALIDATE_MODE" == "all" ]; then
    echo -e "${BLUE}Validating all files...${NC}" >&2
    ALL_FILES=($(ls file_*.cfg 2>/dev/null | sort -V))
    
    if [ ${#ALL_FILES[@]} -eq 0 ]; then
        echo -e "${RED}ERROR: No file_*.cfg files found${NC}" >&2
        exit 1
    fi
    
    CHANGED_FILES="${ALL_FILES[*]}"
else
    CHANGED_FILES=$(get_changed_files)
fi

if [ -z "$CHANGED_FILES" ]; then
    echo -e "${GREEN}No changed files to validate. All URLs are OK!${NC}" >&2
    exit 0
fi

FILES=($CHANGED_FILES)

echo ""
echo "=== Validating URLs in changed files ==="

TOTAL_ERRORS=0

for file in "${FILES[@]}"; do
    if ! validate_urls_in_file "$file"; then
        TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi
done

echo ""
if [ $TOTAL_ERRORS -eq 0 ]; then
    echo -e "${GREEN}=== URL validation completed successfully ===${NC}" >&2
    echo -e "${GREEN}All URLs returned HTTP 200 OK${NC}" >&2
    exit 0
else
    echo -e "${RED}=== URL validation failed ===${NC}" >&2
    echo -e "${RED}Files with errors: $TOTAL_ERRORS${NC}" >&2
    exit 1
fi
