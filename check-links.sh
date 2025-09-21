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
IGNORE_URLS="${INPUT_IGNORE_URLS}"
USER_AGENT="${INPUT_USER_AGENT:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36}"

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

# Cache for External URLs to vastly speed up redundant links
declare -A EXT_URL_CACHE
LAST_ERROR_STATUS=""

echo -e "${BLUE}=== Markdown Link Checker ===${NC}"
echo -e "${BLUE}Starting link check process...${NC}"

# Load configuration from file if provided
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
	echo -e "${BLUE}Loading configuration from $CONFIG_FILE${NC}"
	# shellcheck disable=SC1090
	source "$CONFIG_FILE"
fi

# Function to add a link/file/line_num/status as a JSON dict to the JSON list
add_to_json() {
	local link="$1"
	local file="${2#./}"
	local line_num="$3"
	local status="$4"

	jq --arg link "$link" \
		--arg file "$file" \
		--argjson line_num "$line_num" \
		--arg status "$status" \
		'. + [{"link": $link, "file": $file, "line_num": $line_num, "status": $status}]' \
		"$FILE_LIST" >"${FILE_LIST}.new" && mv "${FILE_LIST}.new" "$FILE_LIST"
}

# Function to check a single URL
check_url() {
	local url="$1"
	local file="$2"
	local line="$3"
	local attempts=0
	local max_attempts="$RETRY_COUNT"
	local status_code
	local success=false

	# Handle URL ignores
	if [ -n "$IGNORE_URLS" ]; then
		for pattern in ${IGNORE_URLS//,/ }; do
			if [[ "$url" == *"$pattern"* ]]; then
				[[ "$VERBOSE" == "true" ]] && echo -e "${YELLOW}⚠ Skipped ignored URL: $url${NC}"
				return 0
			fi
		done
	fi

	# Handle different URL types
	if [[ "$url" == http* ]]; then
		# Check Cache First
		if [[ -n "${EXT_URL_CACHE["$url"]}" ]]; then
			status_code="${EXT_URL_CACHE["$url"]}"
			if [ "$status_code" -lt 400 ]; then
				[[ "$VERBOSE" == "true" ]] && echo -e "${GREEN}✓ Link OK (cached): $url${NC}"
				return 0
			else
				echo -e "${RED}✖ $file:$line - Broken link: $url (Status: $status_code) [Cached]${NC}"
				BROKEN_LINKS=$((BROKEN_LINKS + 1))
				LAST_ERROR_STATUS="$status_code"
				return 1
			fi
		fi

		# External URL Check Loop
		while [ "$attempts" -lt "$max_attempts" ] && [ "$success" = false ]; do
			attempts=$((attempts + 1))

			[[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}Checking external URL: $url${NC}"

			status_code=$(curl -s -L -o /dev/null -w "%{http_code}" -A "$USER_AGENT" \
				--connect-timeout "$TIMEOUT" --max-time "$((TIMEOUT * 2))" "$url")

			if [ "$status_code" -lt 400 ] && [ "$status_code" -gt 0 ]; then
				success=true
			else
				if [ "$attempts" -lt "$max_attempts" ]; then
					echo -e "${YELLOW}Attempt $attempts failed for $url (Status: $status_code). Retrying...${NC}"
					sleep 1
				fi
			fi
		done

		# Store in cache
		EXT_URL_CACHE["$url"]="$status_code"

		if [ "$success" = false ]; then
			echo -e "${RED}✖ $file:$line - Broken link: $url (Status: $status_code)${NC}"
			BROKEN_LINKS=$((BROKEN_LINKS + 1))
			LAST_ERROR_STATUS="$status_code"
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
		if [[ "$url" == *#* ]]; then
			fragment="${url#*#}"
			url="${url%%#*}"
		fi

		# Handle empty URL with just fragment
		if [ -z "$url" ]; then
			target_path="$file"
		elif [[ "$url" == /* ]]; then # Handle absolute paths
			target_path=".$url"
		else # Handle relative paths
			target_path="$base_dir/$url"
		fi

		# Normalize path safely
		target_path=$(realpath --relative-to="$(pwd)" "$target_path" 2>/dev/null || echo "$target_path")

		[[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}Checking internal link: $url (resolved to $target_path)${NC}"

		# Check if file exists
		if [ ! -e "$target_path" ] && [ -n "$url" ]; then
			echo -e "${RED}✖ $file:$line - Broken link: $url (File not found: $target_path)${NC}"
			BROKEN_LINKS=$((BROKEN_LINKS + 1))
			LAST_ERROR_STATUS="File not found"
			return 1
		fi

		# Check fragment if exists
		if [ -n "$fragment" ] && [[ "$target_path" == *.md ]]; then
			# Normalize fragment
			local fragment_normalized
			fragment_normalized=$(echo "$fragment" | awk '{print tolower($0)}' | sed -E 's/[^a-z0-9]+/ /g' | xargs)
			local found_fragment=false

			while IFS= read -r heading; do
				local heading_normalized
				heading_normalized=$(echo "$heading" | sed -E 's/^#+\s*//' | awk '{print tolower($0)}' | sed -E 's/[^a-z0-9]+/ /g' | xargs)
				if [ "$heading_normalized" = "$fragment_normalized" ]; then
					found_fragment=true
					break
				fi
			done < <(grep -E '^#+ ' "$target_path")

			if ! $found_fragment; then
				echo -e "${RED}✖ $file:$line - Broken link: $url#$fragment (Fragment not found in $target_path)${NC}"
				BROKEN_LINKS=$((BROKEN_LINKS + 1))
				LAST_ERROR_STATUS="Fragment not found"
				return 1
			fi
		fi

		[[ "$VERBOSE" == "true" ]] && echo -e "${GREEN}✓ Link OK: $url${NC}"
	fi

	return 0
}

# Function to extract and check links from a file
check_file() {
	local file="$1"
	local links_found=0

	echo -e "${BLUE}Checking links in $file${NC}"
	CHECKED_FILES=$((CHECKED_FILES + 1))

	# Helper wrapper to test and accumulate links
	process_link() {
		local line_data="$1"
		local line_num="${line_data%%:*}"
		local link="${line_data#*:}"

		# Remove surrounding angle brackets if present
		link=$(echo "$link" | sed -E 's/^<(.+)>$/\1/')

		if [ -n "$link" ]; then
			links_found=$((links_found + 1))
			TOTAL_LINKS=$((TOTAL_LINKS + 1))

			if ! check_url "$link" "$file" "$line_num"; then
				add_to_json "$link" "$file" "$line_num" "$LAST_ERROR_STATUS"
			fi
		fi
	}

	# Extract markdown links
	while IFS= read -r line_data; do
		process_link "$line_data"
	done < <(perl -ne '
        while (/\[([^\]]+)\]\(\s*(<)?((?:[^()<>]|<[^<>]*>|\([^()]*\))*)(?(2)>)\s*\)/g) { print "$.:$3\n"; }
    ' "$file")

	# Extract HTML links
	while IFS= read -r line_data; do
		process_link "$line_data"
	done < <(grep -n -o '<a [^>]*href="[^"]*"[^>]*>' "$file" | sed -E 's/([0-9]+):.*href="([^"]*)".*>/\1:\2/g')

	# Extract image links
	while IFS= read -r line_data; do
		process_link "$line_data"
	done < <(perl -ne '
        while (/!\[[^\]]*\]\(\s*(<)?((?:[^()<>]|<[^<>]*>|\([^()]*\))*)(?(1)>)\s*\)/g) { print "$.:$2\n"; }
    ' "$file")

	echo -e "${BLUE}Found $links_found links in $file${NC}"
}

FILE_LIST=$(mktemp /tmp/file_list.XXXXXX.json)
trap 'rm -f "$FILE_LIST"' EXIT
echo '[]' >"$FILE_LIST"

# Main processing
if [ -n "$FILES" ]; then
	for file in ${FILES//,/ }; do
		if [ -f "$file" ]; then
			check_file "$file"
		else
			echo -e "${YELLOW}Warning: File $file not found${NC}"
		fi
	done
else
	# Build safe find command parameters
	FIND_ARGS=("$PATH_TO_CHECK")
	if [ "$RECURSIVE" != "true" ]; then
		FIND_ARGS+=("-maxdepth" "1")
	fi
	FIND_ARGS+=("-type" "f" "-name" "*.md")

	if [ -n "$EXCLUDE" ]; then
		for pattern in ${EXCLUDE//,/ }; do
			FIND_ARGS+=("-not" "-path" "*$pattern*")
		done
	fi

	# Use print0 to safely handle spaces in filenames
	while IFS= read -r -d '' file; do
		check_file "$file"
	done < <(find "${FIND_ARGS[@]}" -print0)
fi

# Echo the JSON list of broken links to the GitHub output
if [ -n "$GITHUB_OUTPUT" ]; then
	echo "json=$(jq -c . "$FILE_LIST")" >>"$GITHUB_OUTPUT"
fi

# Print summary
echo -e "${BLUE}=== Link Check Summary ===${NC}"
echo -e "${BLUE}Files checked: $CHECKED_FILES${NC}"
echo -e "${BLUE}Total links: $TOTAL_LINKS${NC}"

if [ "$BROKEN_LINKS" -eq 0 ]; then
	echo -e "${GREEN}✓ All links are valid!${NC}"
	exit 0
else
	echo -e "${RED}✖ Found $BROKEN_LINKS broken links!${NC}"
	exit 1
fi
