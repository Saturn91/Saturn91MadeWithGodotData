#!/bin/bash

set -e  # Exit on error

echo "=== Starting validation and update process ==="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ERRORS=0

# Function to validate a single .cfg file
validate_cfg_file() {
    local file=$1
    echo "Validating $file..." >&2
    
    # Check if file exists
    if [ ! -f "$file" ]; then
        echo -e "${RED}ERROR: File $file does not exist${NC}" >&2
        ((ERRORS++))
        return 1
    fi
    
    # Parse the file and validate each section
    local sections=$(grep -E '^\[link_[0-9]+\]' "$file" | sed 's/\[//g' | sed 's/\]//g')
    local link_num=0
    
    for section in $sections; do
        # Check naming format (link_n)
        if ! [[ "$section" =~ ^link_[0-9]+$ ]]; then
            echo -e "${RED}ERROR in $file: Invalid section name '$section' (should be link_N)${NC}" >&2
            ((ERRORS++))
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
            ((ERRORS++))
        fi
        
        # Check each line matches exactly one of the 4 allowed patterns
        # Field name must be exactly: url, developer, dev_link, or preview_image
        # Format must be: fieldname=value (no spaces around =)
        local has_url=0
        local has_developer=0
        local has_dev_link=0
        local has_preview_image=0
        local line_errors=0
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^url= ]]; then
                ((has_url++))
            elif [[ "$line" =~ ^developer= ]]; then
                ((has_developer++))
            elif [[ "$line" =~ ^dev_link= ]]; then
                ((has_dev_link++))
            elif [[ "$line" =~ ^preview_image= ]]; then
                ((has_preview_image++))
            else
                if [ -z "$line" ]; then
                    echo -e "${RED}ERROR in $file [$section]: Empty line not allowed${NC}" >&2
                else
                    echo -e "${RED}ERROR in $file [$section]: Invalid line: '$line'${NC}" >&2
                fi
                ((line_errors++))
            fi
        done <<< "$section_content"
        
        # Check all 4 required fields are present exactly once
        if [ "$has_url" -ne 1 ]; then
            echo -e "${RED}ERROR in $file [$section]: Must have exactly 1 'url' field (found $has_url)${NC}" >&2
            ((ERRORS++))
        fi
        if [ "$has_developer" -ne 1 ]; then
            echo -e "${RED}ERROR in $file [$section]: Must have exactly 1 'developer' field (found $has_developer)${NC}" >&2
            ((ERRORS++))
        fi
        if [ "$has_dev_link" -ne 1 ]; then
            echo -e "${RED}ERROR in $file [$section]: Must have exactly 1 'dev_link' field (found $has_dev_link)${NC}" >&2
            ((ERRORS++))
        fi
        if [ "$has_preview_image" -ne 1 ]; then
            echo -e "${RED}ERROR in $file [$section]: Must have exactly 1 'preview_image' field (found $has_preview_image)${NC}" >&2
            ((ERRORS++))
        fi
        
        ERRORS=$((ERRORS + line_errors))
        
        ((link_num++))
    done
    
    # Check if file has more than 100 links
    if [ "$link_num" -gt 100 ]; then
        echo -e "${RED}ERROR in $file: Contains $link_num links (max 100 allowed)${NC}" >&2
        ((ERRORS++))
    fi
    
    echo -e "${GREEN}✓ $file validated ($link_num links)${NC}" >&2
    echo "$link_num"
}

# Find all file_*.cfg files
echo ""
echo "=== Step 1: Validating all file_*.cfg files ==="
FILES=($(ls file_*.cfg 2>/dev/null | sort -V))

if [ ${#FILES[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No file_*.cfg files found${NC}"
    exit 1
fi

# Validate each file and count total links
TOTAL_LINKS=0
declare -A FILE_LINK_COUNTS

for file in "${FILES[@]}"; do
    link_count=$(validate_cfg_file "$file")
    FILE_LINK_COUNTS[$file]=$link_count
    TOTAL_LINKS=$((TOTAL_LINKS + link_count))
done

# Check for validation errors
if [ $ERRORS -gt 0 ]; then
    echo ""
    echo -e "${RED}=== Validation failed with $ERRORS error(s) ===${NC}"
    exit 1
fi

echo ""
echo "=== Step 2: Updating _index.cfg ==="

# Count file_*.cfg files
FILE_COUNT=${#FILES[@]}
echo "Total files: $FILE_COUNT"
echo "Total links: $TOTAL_LINKS"

# Update _index.cfg
cat > _index.cfg << EOF
[index]
file_count="$FILE_COUNT"
link_count="$TOTAL_LINKS"
links_per_file="100"
EOF

echo -e "${GREEN}✓ _index.cfg updated${NC}"

echo ""
echo -e "${GREEN}=== Validation and update completed successfully ===${NC}"
echo "Summary:"
echo "  - Files validated: $FILE_COUNT"
echo "  - Total links: $TOTAL_LINKS"
echo "  - Errors: 0"
