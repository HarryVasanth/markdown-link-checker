#!/bin/bash

# Input variables
PATH_TO_CHECK="${INPUT_PATH:-.}"
FILES="${INPUT_FILES}"
EXCLUDE="${INPUT_EXCLUDE}"
RECURSIVE="${INPUT_RECURSIVE:-true}"
TIMEOUT="${INPUT_TIMEOUT:-10}"
RETRY_COUNT="${INPUT_RETRY_COUNT:-3}"
VERBOSE="${INPUT_VERBOSE:-false}"
CONFIG_FILE="${INPUT_CONFIG_FILE}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Statistics
TOTAL_LINKS=0
BROKEN_LINKS=0
CHECKED_FILES=0

echo -e "${BLUE}=== Markdown Link Checker ===${NC}"
echo -e "${BLUE}Starting link check process...${NC}"

# Load configuration from file if provided
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    echo -e "${BLUE}Loading configuration from $CONFIG_FILE${NC}"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Function to add a link/file/line_num as a JSON dict to the JSON list of broken links
add_to_json() {
    local link="$1"
    local file="${2#./}" # filename should not have a leading dot-slash. Eg. we want 'README.md' instead of './README.md'
    local line_num="$3"

    cat $FILE_LIST | jq \
      --arg link "$link" \
      --arg file "$file" \
      --argjson line_num "$line_num" \
      '. + [{"link": $link, "file": $file, "line_num": $line_num}]' > "$FILE_LIST".new
    mv "$FILE_LIST".new "$FILE_LIST"
}

# Function to check a single URL
check_url() {
    local url=$1
    local file=$2
    local line=$3
    local attempts=0
    local max_attempts=$RETRY_COUNT
    local status_code
    local success=false

    # Handle different URL types
    if [[ $url == http* ]]; then
        # External URL
        while [ $attempts -lt "$max_attempts" ] && [ "$success" = false ]; do
            attempts=$((attempts + 1))

            if [ "$VERBOSE" = "true" ]; then
                echo -e "${BLUE}Checking external URL: $url${NC}"
            fi

            status_code=$(curl -s -L -o /dev/null -w "%{http_code}" --connect-timeout "$TIMEOUT" "$url")

            if [ "$status_code" -lt 400 ]; then
                success=true
            else
                if [ $attempts -lt "$max_attempts" ]; then
                    echo -e "${YELLOW}Attempt $attempts failed for $url (Status: $status_code). Retrying...${NC}"
                    sleep 1
                fi
            fi
        done

        if [ "$success" = false ]; then
            echo -e "${RED}✖ $file:$line - Broken link: $url (Status: $status_code)${NC}"
            BROKEN_LINKS=$((BROKEN_LINKS + 1))
            return 1
        elif [ "$VERBOSE" = "true" ]; then
            echo -e "${GREEN}✓ Link OK: $url${NC}"
        fi
    else
        # Internal link (file or anchor)
        local base_dir
        base_dir=$(dirname "$file")
        local target_path=""
        local fragment=""

        # Extract fragment if exists
        if [[ $url == *#* ]]; then
            fragment=$(echo "$url" | cut -d'#' -f2)
            url=$(echo "$url" | cut -d'#' -f1)
        fi

        # Handle empty URL with just fragment
        if [ -z "$url" ]; then
            target_path="$file"
        # Handle absolute paths
        elif [[ $url == /* ]]; then
            target_path=".$url"
        # Handle relative paths
        else
            target_path="$base_dir/$url"
        fi

        # Normalize path
        target_path=$(realpath --relative-to="$(pwd)" "$target_path" 2>/dev/null || echo "$target_path")

        if [ "$VERBOSE" = "true" ]; then
            echo -e "${BLUE}Checking internal link: $url (resolved to $target_path)${NC}"
        fi

        # Check if file exists
        if [ ! -e "$target_path" ] && [ -n "$url" ]; then
            echo -e "${RED}✖ $file:$line - Broken link: $url (File not found: $target_path)${NC}"
            BROKEN_LINKS=$((BROKEN_LINKS + 1))
            return 1
        fi

        # Check fragment if exists
        if [ -n "$fragment" ] && [[ $target_path == *.md ]]; then
            # Normalize fragment: lowercase, replace non-alphanumeric characters with space, trim whitespace
            fragment_normalized=$(echo "$fragment" | awk '{print tolower($0)}' | sed -E 's/[^a-z0-9]+/ /g' | xargs)
            found_fragment=false
            while IFS= read -r heading; do
                # Remove '#' and leading/trailing spaces from heading, normalize as above
                heading_fragment=$(echo "$heading" | sed -E 's/^#+\\s*//')
                heading_normalized=$(echo "$heading_fragment" | awk '{print tolower($0)}' | sed -E 's/[^a-z0-9]+/ /g' | xargs)
                if [ "$heading_normalized" = "$fragment_normalized" ]; then
                    found_fragment=true
                    break
                fi
            done < <(grep -E '^#+ ' "$target_path")

            if ! $found_fragment; then
                echo -e "${RED}✖ $file:$line - Broken link: $url#$fragment (Fragment not found in $target_path)${NC}"
                BROKEN_LINKS=$((BROKEN_LINKS + 1))
                return 1
            fi
        fi

        if [ "$VERBOSE" = "true" ]; then
            echo -e "${GREEN}✓ Link OK: $url${NC}"
        fi
    fi

    return 0
}

# Function to extract and check links from a file
check_file() {
    local file=$1
    local links_found=0

    echo -e "${BLUE}Checking links in $file${NC}"
    CHECKED_FILES=$((CHECKED_FILES + 1))

    # Extract markdown links [text](url) and [text](<url>)
    while IFS= read -r line_data; do
        line_num=$(echo "$line_data" | cut -d':' -f1)
        link=$(echo "$line_data" | cut -d':' -f2-)

        # Remove surrounding angle brackets if present
        link=$(echo "$link" | sed -E 's/^<(.+)>$/\1/')

        # Skip empty links
        if [ -z "$link" ]; then
            continue
        fi

        links_found=$((links_found + 1))
        TOTAL_LINKS=$((TOTAL_LINKS + 1))

        check_url "$link" "$file" "$line_num"
        if [ "$?" -eq 1 ]; then
            add_to_json "$link" "$file" "$line_num"
        fi
    done < <(perl -ne '
        while (/\[([^\]]+)\]\(\s*(<)?((?:[^()<>]|<[^<>]*>|\([^()]*\))*)(?(2)>)\s*\)/g) {
            print "$.:$3\n";
        }
    ' "$file")

    # Extract HTML links <a href="url">
    while IFS= read -r line_data; do
        line_num=$(echo "$line_data" | cut -d':' -f1)
        link=$(echo "$line_data" | cut -d':' -f2-)

        # Skip empty links
        if [ -z "$link" ]; then
            continue
        fi

        links_found=$((links_found + 1))
        TOTAL_LINKS=$((TOTAL_LINKS + 1))

        check_url "$link" "$file" "$line_num"
        if [ "$?" -eq 1 ]; then
            add_to_json "$link" "$file" "$line_num"
        fi
    done < <(grep -n -o '<a [^>]*href="[^"]*"[^>]*>' "$file" | sed -E 's/([0-9]+):.*href="([^"]*)".*>/\1:\2/g')

    # Extract image links ![alt](url)
    while IFS= read -r line_data; do
        line_num=$(echo "$line_data" | cut -d':' -f1)
        link=$(echo "$line_data" | cut -d':' -f2-)

        # Remove surrounding angle brackets if present
        link=$(echo "$link" | sed -E 's/^<(.+)>$/\1/')

        # Skip empty links
        if [ -z "$link" ]; then
            continue
        fi

        links_found=$((links_found + 1))
        TOTAL_LINKS=$((TOTAL_LINKS + 1))

        check_url "$link" "$file" "$line_num"
        if [ "$?" -eq 1 ]; then
            add_to_json "$link" "$file" "$line_num"
        fi
    done < <(perl -ne '
        while (/!\[[^\]]*\]\(\s*(<)?((?:[^()<>]|<[^<>]*>|\([^()]*\))*)(?(1)>)\s*\)/g) {
            print "$.:$2\n";
        }
    ' "$file")

    echo -e "${BLUE}Found $links_found links in $file${NC}"
}

# Build find command based on inputs
FIND_CMD="find \"$PATH_TO_CHECK\""

if [ "$RECURSIVE" != "true" ]; then
    FIND_CMD="$FIND_CMD -maxdepth 1"
fi

FIND_CMD="$FIND_CMD -type f -name \"*.md\""

# Add exclude patterns
if [ -n "$EXCLUDE" ]; then
    # Normalize: replace commas with spaces, then iterate
    EXCLUDE_NORMALIZED=$(echo "$EXCLUDE" | tr ',' ' ')
    for pattern in $EXCLUDE_NORMALIZED; do
        FIND_CMD="$FIND_CMD -not -path \"*$pattern*\""
    done
fi

FILE_LIST=$(mktemp /tmp/file_list.XXXXXX.json)
trap 'rm -f "$FILE_LIST"' EXIT
echo '[]' > "$FILE_LIST"

# Get list of files to check
if [ -n "$FILES" ]; then
    FILES_NORMALIZED=$(echo "$FILES" | tr ',' ' ')
    for file in $FILES_NORMALIZED; do
        if [ -f "$file" ]; then
            check_file "$file"
        else
            echo -e "${YELLOW}Warning: File $file not found${NC}"
        fi
    done
else
    # Use find command to get markdown files
    while IFS= read -r file; do
        check_file "$file"
    done < <(eval "$FIND_CMD")
fi

# Echo the JSON list of broken links to the GitHub output
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "json=$(cat "$FILE_LIST" | jq -c .)" >> "$GITHUB_OUTPUT"
fi

# Print summary
echo -e "${BLUE}=== Link Check Summary ===${NC}"
echo -e "${BLUE}Files checked: $CHECKED_FILES${NC}"
echo -e "${BLUE}Total links: $TOTAL_LINKS${NC}"

if [ $BROKEN_LINKS -eq 0 ]; then
    echo -e "${GREEN}✓ All links are valid!${NC}"
    exit 0
else
    echo -e "${RED}✖ Found $BROKEN_LINKS broken links!${NC}"
    exit 1
fi
