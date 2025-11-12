#!/bin/bash

set -e  # Exit on error

echo "=== Starting validation and update process ==="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if we should only validate changed files
VALIDATE_MODE="all"
if [ ! -z "$1" ] && [ "$1" == "--changed-only" ]; then
    VALIDATE_MODE="changed"
fi

# Function to check if _index.cfg was manually modified
check_index_modified() {
    # Determine the default branch (master or main)
    local default_branch=""
    if git rev-parse --verify origin/main >/dev/null 2>&1; then
        default_branch="origin/main"
    elif git rev-parse --verify origin/master >/dev/null 2>&1; then
        default_branch="origin/master"
    else
        echo -e "${YELLOW}WARNING: Could not find origin/main or origin/master. Skipping _index.cfg check.${NC}" >&2
        return
    fi
    
    # Check if _index.cfg was modified in this branch
    local index_modified=$(git diff --name-only $default_branch...HEAD | grep '^_index\.cfg$' || true)
    
    if [ ! -z "$index_modified" ]; then
        echo -e "${RED}ERROR: _index.cfg has been manually modified!${NC}" >&2
        echo -e "${RED}This file should only be updated automatically by the validation script.${NC}" >&2
        echo -e "${RED}Please revert changes to _index.cfg and let the bot update it.${NC}" >&2
        exit 1
    fi
}

# If in changed-only mode, check that _index.cfg wasn't manually modified
if [ "$VALIDATE_MODE" == "changed" ]; then
    echo ""
    echo "=== Checking _index.cfg for manual modifications ==="
    check_index_modified
    echo -e "${GREEN}✓ _index.cfg has not been manually modified${NC}" >&2
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
        echo -e "${YELLOW}WARNING: Could not find origin/main or origin/master. Validating all files.${NC}" >&2
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

# Function to validate a single .cfg file
validate_cfg_file() {
    local file=$1
    echo "Validating $file..." >&2
    
    # Check if file exists
    if [ ! -f "$file" ]; then
        echo -e "${RED}ERROR: File $file does not exist${NC}" >&2
        exit 1
    fi
    
    # Parse the file and validate each section
    local sections=$(grep -E '^\[link_[0-9]+\]' "$file" | sed 's/\[//g' | sed 's/\]//g')
    local link_num=0
    
    for section in $sections; do
        # Check naming format (link_n)
        if ! [[ "$section" =~ ^link_[0-9]+$ ]]; then
            echo -e "${RED}ERROR in $file: Invalid section name '$section' (should be link_N)${NC}" >&2
            exit 1
        fi
        
        # Extract section number and verify it matches expected sequence
        local num=$(echo "$section" | sed 's/link_//')
        if [ "$num" != "$link_num" ]; then
            echo -e "${YELLOW}WARNING in $file: Expected link_$link_num but found $section${NC}" >&2
        fi
        
        # Extract the entire section content (everything between this [link_n] and the next section or EOF)
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
        
        # Count total lines in the section (including empty lines, invalid lines, etc.)
        local total_lines=$(echo "$section_content" | wc -l)
        
        # Check if there are exactly 4 lines and they are all valid fields
        if [ "$total_lines" -ne 4 ]; then
            echo -e "${RED}ERROR in $file [$section]: Section must contain exactly 4 lines (found $total_lines)${NC}" >&2
            exit 1
        fi
        
        # Check each line matches exactly one of the 4 allowed patterns
        # Field name must be exactly: url, developer, dev_link, or preview_image
        # Format must be: fieldname="value" (value wrapped in double quotes)
        local has_url=0
        local has_developer=0
        local has_dev_link=0
        local has_preview_image=0
        
        while IFS= read -r line; do
            # Check if value is wrapped in double quotes
            if [[ "$line" =~ ^url=\".*\"$ ]]; then
                ((has_url++))
            elif [[ "$line" =~ ^developer=\".*\"$ ]]; then
                ((has_developer++))
            elif [[ "$line" =~ ^dev_link=\".*\"$ ]]; then
                ((has_dev_link++))
            elif [[ "$line" =~ ^preview_image=\".*\"$ ]]; then
                ((has_preview_image++))
            else
                if [ -z "$line" ]; then
                    echo -e "${RED}ERROR in $file [$section]: Empty line not allowed${NC}" >&2
                elif [[ "$line" =~ ^(url|developer|dev_link|preview_image)= ]]; then
                    echo -e "${RED}ERROR in $file [$section]: Value must be wrapped in double quotes: '$line'${NC}" >&2
                else
                    echo -e "${RED}ERROR in $file [$section]: Invalid line: '$line'${NC}" >&2
                fi
                exit 1
            fi
        done <<< "$section_content"
        
        # Check all 4 required fields are present exactly once
        if [ "$has_url" -ne 1 ]; then
            echo -e "${RED}ERROR in $file [$section]: Must have exactly 1 'url' field (found $has_url)${NC}" >&2
            exit 1
        fi
        if [ "$has_developer" -ne 1 ]; then
            echo -e "${RED}ERROR in $file [$section]: Must have exactly 1 'developer' field (found $has_developer)${NC}" >&2
            exit 1
        fi
        if [ "$has_dev_link" -ne 1 ]; then
            echo -e "${RED}ERROR in $file [$section]: Must have exactly 1 'dev_link' field (found $has_dev_link)${NC}" >&2
            exit 1
        fi
        if [ "$has_preview_image" -ne 1 ]; then
            echo -e "${RED}ERROR in $file [$section]: Must have exactly 1 'preview_image' field (found $has_preview_image)${NC}" >&2
            exit 1
        fi
        
        ((link_num++))
    done
    
    # Check if file has more than 100 links
    if [ "$link_num" -gt 100 ]; then
        echo -e "${RED}ERROR in $file: Contains $link_num links (max 100 allowed)${NC}" >&2
        echo -e "${RED}ERROR Please add a new file: file_*.cfg put the new link(s) there.${NC}" >&2
        exit 1
    fi
    
    echo -e "${GREEN}✓ $file validated ($link_num links)${NC}" >&2
    echo "$link_num"
}

# Find all file_*.cfg files
echo ""
echo "=== Step 1: Validating file_*.cfg files ==="

if [ "$VALIDATE_MODE" == "changed" ]; then
    CHANGED_FILES=$(get_changed_files)
    if [ -z "$CHANGED_FILES" ]; then
        echo -e "${GREEN}No changed files to validate. Skipping validation step.${NC}" >&2
        # Still need to count all files for index update
        FILES=($(ls file_*.cfg 2>/dev/null | sort -V))
    else
        FILES=($CHANGED_FILES)
        echo -e "${BLUE}Validating only changed files...${NC}" >&2
    fi
else
    FILES=($(ls file_*.cfg 2>/dev/null | sort -V))
    echo -e "${BLUE}Validating all files...${NC}" >&2
fi

if [ ${#FILES[@]} -eq 0 ]; then
    echo -e "${YELLOW}No files to validate${NC}" >&2
    # Count all files for the index
    ALL_FILES=($(ls file_*.cfg 2>/dev/null | sort -V))
    if [ ${#ALL_FILES[@]} -eq 0 ]; then
        echo -e "${RED}ERROR: No file_*.cfg files found${NC}" >&2
        exit 1
    fi
else
    # Validate each file
    for file in "${FILES[@]}"; do
        link_count=$(validate_cfg_file "$file")
    done
fi

echo ""
echo "=== Step 2: Updating _index.cfg ==="

# Always count ALL files for the index, not just changed ones
ALL_FILES=($(ls file_*.cfg 2>/dev/null | sort -V))
TOTAL_LINKS=0

echo "Counting links across all files..." >&2
for file in "${ALL_FILES[@]}"; do
    # Count links in each file
    file_link_count=$(grep -c '^\[link_[0-9]*\]' "$file" || echo "0")
    TOTAL_LINKS=$((TOTAL_LINKS + file_link_count))
    echo "  $file: $file_link_count links" >&2
done

# Count file_*.cfg files
FILE_COUNT=${#ALL_FILES[@]}
echo "" >&2
echo "Total files: $FILE_COUNT" >&2
echo "Total links: $TOTAL_LINKS" >&2

# Update _index.cfg
cat > _index.cfg << EOF
# DO NOT EDIT THIS FILE MANUALLY
[index]
file_count="$FILE_COUNT"
link_count="$TOTAL_LINKS"
links_per_file="100"
EOF

echo -e "${GREEN}✓ _index.cfg updated${NC}"

echo ""
echo -e "${GREEN}=== Validation and update completed successfully ===${NC}" >&2
echo "Summary:" >&2
echo "  - Files validated: $FILE_COUNT" >&2
echo "  - Total links: $TOTAL_LINKS" >&2
echo "  - Errors: 0" >&2
