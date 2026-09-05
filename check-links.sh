#!/usr/bin/env bash
#
# Markdown Link Checker
#
# Validates external URLs, internal file links, and heading anchors (fragments)
# found in Markdown files. Also covers HTML <a href> / <img src>, reference-style
# and autolink markdown. Skips links inside fenced code blocks so code samples
# are never false positives. Emits a JSON report of broken links.
#
# Designed to run as a GitHub Action (INPUT_* env vars) or standalone.
# See README.md for configuration.

set -uo pipefail

# bash >= 4 needed for associative arrays
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
	echo "Error: bash >= 4 required (found $BASH_VERSION)" >&2
	exit 2
fi

# ----- Inputs -----
PATH_TO_CHECK="${INPUT_PATH:-.}"
FILES="${INPUT_FILES:-}"
EXCLUDE="${INPUT_EXCLUDE:-}"
RECURSIVE="${INPUT_RECURSIVE:-true}"
TIMEOUT="${INPUT_TIMEOUT:-10}"
RETRY_COUNT="${INPUT_RETRY_COUNT:-3}"
VERBOSE="${INPUT_VERBOSE:-false}"
CONFIG_FILE="${INPUT_CONFIG_FILE:-}"
IGNORE_URLS="${INPUT_IGNORE_URLS:-}"
USER_AGENT="${INPUT_USER_AGENT:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36}"

# ----- Config file -----
# Hardened parser: only known keys, values never evaluated as shell code,
# so a config file can not execute anything. Overrides the INPUT_* settings.
load_config() {
	local cfg="$1" line key value
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=([[:space:]]*)(.*)$ ]] || continue
		key="${BASH_REMATCH[1]}"
		value="${BASH_REMATCH[3]%$'\r'}"
		if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
			value="${BASH_REMATCH[1]}"
		fi
		case "$key" in
		PATH_TO_CHECK) PATH_TO_CHECK="$value" ;;
		FILES) FILES="$value" ;;
		EXCLUDE) EXCLUDE="$value" ;;
		RECURSIVE) RECURSIVE="$value" ;;
		TIMEOUT) TIMEOUT="$value" ;;
		RETRY_COUNT) RETRY_COUNT="$value" ;;
		VERBOSE) VERBOSE="$value" ;;
		IGNORE_URLS) IGNORE_URLS="$value" ;;
		USER_AGENT) USER_AGENT="$value" ;;
		*) echo "Warning: unknown key '$key' in config file $cfg, ignoring" >&2 ;;
		esac
	done <"$cfg"
}
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
	echo -e "Loading configuration from $CONFIG_FILE"
	load_config "$CONFIG_FILE"
fi

# ----- Input validation (bad input gets a sane default) -----
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || {
	echo "Warning: invalid TIMEOUT '$TIMEOUT', using 10" >&2
	TIMEOUT=10
}
[[ "$RETRY_COUNT" =~ ^[0-9]+$ ]] || {
	echo "Warning: invalid RETRY_COUNT '$RETRY_COUNT', using 3" >&2
	RETRY_COUNT=3
}
if [ "$RECURSIVE" != "true" ] && [ "$RECURSIVE" != "false" ]; then
	echo "Warning: invalid RECURSIVE '$RECURSIVE', using true" >&2
	RECURSIVE=true
fi
if [ "$VERBOSE" != "true" ] && [ "$VERBOSE" != "false" ]; then
	echo "Warning: invalid VERBOSE '$VERBOSE', using false" >&2
	VERBOSE=false
fi

# ----- Output colors -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ----- Statistics -----
TOTAL_LINKS=0
BROKEN_LINKS=0
CHECKED_FILES=0

# Caches (associative arrays) so repeated work is done once
declare -A EXT_URL_CACHE # url -> final http status code
declare -A HEAD_SLUGS    # file -> newline separated heading slugs
BROKEN=()                # one JSON object per broken link occurrence
LAST_ERROR_STATUS=""

echo -e "${BLUE}=== Markdown Link Checker ===${NC}"
echo -e "${BLUE}Starting link check process...${NC}"

# GitHub-style anchor slug generation.
# Mirrors github-slugger behaviour: lowercase, punctuation stripped, runs of
# whitespace become a single hyphen, hyphens/underscores kept as-is.
slug() {
	printf '%s\n' "$1" | perl -CS -pe '
        $_ = lc;
        s/[^\p{L}\p{N}\s_-]+//g;
        s/\s+/-/g;
        s/^-+|-+$//g;
    '
}

# All heading anchors of a markdown file (cached per file).
# Repeated headings get -1, -2... suffixes exactly like GitHub.
heading_slugs() {
	local file="$1"
	if [[ -z "${HEAD_SLUGS[$file]+_}" ]]; then
		HEAD_SLUGS[$file]=$(perl -CS -e '
            my %used;
            while (<>) {
                next unless /^\s{0,3}#{1,6}\s+(.+)/;
                my $s = lc $1;
                $s =~ s/[^\p{L}\p{N}\s_-]+//g;
                $s =~ s/\s+/-/g;
                $s =~ s/^-+|-+$//g;
                next if $s eq "";
                my ($b, $i) = ($s, 0);
                while ($used{$s}++) { $s = "$b-" . ++$i; }
                print "$s\n";
            }
        ' <"$file")
	fi
	printf '%s' "${HEAD_SLUGS[$file]}"
}

# Single jq call per broken link (O(n) total, not the old O(n^2) rewrite).
broken_json() {
	jq -nc --arg link "$1" --arg file "${2#./}" --argjson line_num "$3" --arg status "$4" \
		'{link: $link, file: $file, line_num: $line_num, status: $status}'
}

# Check one URL found in `file` on `line`.
check_url() {
	local url="$1" file="$2" line="$3"
	local base target fragment status_code code attempt attempts

	# Ignore list (substring match on the raw URL)
	if [ -n "$IGNORE_URLS" ]; then
		# word splitting on commas and whitespace is intended
		# shellcheck disable=SC2086
		for pattern in ${IGNORE_URLS//,/ }; do
			[ -z "$pattern" ] && continue
			if [[ "$url" == *"$pattern"* ]]; then
				[[ "$VERBOSE" == "true" ]] && echo -e "${YELLOW}Skipped (ignored): $url${NC}"
				return 0
			fi
		done
	fi

	# ----- External URL -----
	if [[ "$url" =~ ^https?:// ]]; then
		if [[ -n "${EXT_URL_CACHE[$url]+_}" ]]; then
			code="${EXT_URL_CACHE[$url]}"
			if [ "$code" -gt 0 ] && [ "$code" -lt 400 ]; then
				[[ "$VERBOSE" == "true" ]] && echo -e "${GREEN}Link OK (cached): $url${NC}"
				return 0
			fi
			echo -e "${RED}x $file:$line - Broken link: $url (Status: $code) [Cached]${NC}"
			LAST_ERROR_STATUS="$code"
			return 1
		fi

		attempt=0
		attempts=$((RETRY_COUNT > 0 ? RETRY_COUNT : 1))
		status_code=""
		while [ "$attempt" -lt "$attempts" ]; do
			attempt=$((attempt + 1))
			status_code=$(curl -sS -L -o /dev/null -w "%{http_code}" \
				--proto "=http,https" \
				--connect-timeout "$TIMEOUT" --max-time "$((TIMEOUT * 2))" \
				-A "$USER_AGENT" "$url")
			if [ "$status_code" -gt 0 ] && [ "$status_code" -lt 400 ]; then
				break
			fi
			if [ "$attempt" -lt "$attempts" ]; then
				echo -e "${YELLOW}Attempt $attempt failed for $url (Status: $status_code). Retrying...${NC}"
				sleep 1
			fi
		done
		EXT_URL_CACHE["$url"]="$status_code"

		if [ "$status_code" -gt 0 ] && [ "$status_code" -lt 400 ]; then
			[[ "$VERBOSE" == "true" ]] && echo -e "${GREEN}Link OK: $url${NC}"
			return 0
		fi
		echo -e "${RED}x $file:$line - Broken link: $url (Status: $status_code)${NC}"
		LAST_ERROR_STATUS="$status_code"
		return 1
	fi

	# ----- Other schemes (mailto:, tel:, ftp:, data:, custom:) -----
	# Not verifiable over HTTP - never report them as broken.
	if [[ "$url" =~ ^[a-z][a-z0-9+.-]*: ]]; then
		[[ "$VERBOSE" == "true" ]] && echo -e "${YELLOW}Skipped (unsupported scheme): $url${NC}"
		return 0
	fi

	# ----- Internal link -----
	base="$(dirname "$file")"
	target=""
	fragment=""
	if [[ "$url" == *#* ]]; then
		fragment="${url#*#}"
		url="${url%%#*}"
	fi

	if [ -z "$url" ]; then
		# fragment-only link, e.g. [jump](#section) - target is the current file
		target="$file"
	elif [[ "$url" == /* ]]; then
		# absolute path inside the repo
		target=".$url"
	else
		target="$base/$url"
	fi

	if [ -n "$url" ] && [ ! -e "$target" ]; then
		echo -e "${RED}x $file:$line - Broken link: $url (File not found: $target)${NC}"
		LAST_ERROR_STATUS="File not found"
		return 1
	fi

	if [ -n "$fragment" ] && [[ "$target" == *.md ]]; then
		local frag_slug
		frag_slug="$(slug "$fragment")"
		if ! printf '%s\n' "$(heading_slugs "$target")" | grep -Fxq -- "$frag_slug"; then
			echo -e "${RED}x $file:$line - Broken link: $url#$fragment (Fragment not found in $target)${NC}"
			LAST_ERROR_STATUS="Fragment not found"
			return 1
		fi
	fi

	[[ "$VERBOSE" == "true" ]] && echo -e "${GREEN}Link OK: $url${NC}"
	return 0
}

# Extract and check every link from one file.
check_file() {
	local file="$1" links_found=0 line_data
	echo -e "${BLUE}Checking links in $file${NC}"
	CHECKED_FILES=$((CHECKED_FILES + 1))

	process_link() {
		local line_data="$1" line_num link
		line_num="${line_data%%:*}"
		link="${line_data#*:}"
		if [ -n "$link" ]; then
			links_found=$((links_found + 1))
			TOTAL_LINKS=$((TOTAL_LINKS + 1))
			if ! check_url "$link" "$file" "$line_num"; then
				BROKEN_LINKS=$((BROKEN_LINKS + 1))
				BROKEN+=("$(broken_json "$link" "$file" "$line_num" "$LAST_ERROR_STATUS")")
			fi
		fi
	}

	# Single perl pass extracts every link form and prints "line:url" lines:
	#   - markdown [text](url), incl. titles and <url> angle form
	#   - images ![alt](url)
	#   - reference style [text][id], [text][]
	#   - HTML <a href="..."> / <img src="..."> (either quote style)
	#   - autolinks <scheme:...>
	# Links inside fenced code blocks are skipped.
	while IFS= read -r line_data; do
		process_link "$line_data"
	done < <(perl -CS -e '
        use strict;
        use warnings;
        my @lines = <>;
        my (%refs, $fence, $dest, $title);
        $fence   = 0;
        $dest    = qr{(?:<[^<>\n]*>|(?:[^()<>\n]|\([^()\n]*\))+)};
        $title   = qr{(?:"[^"\n]*"|\x27[^\x27\n]*\x27|\([^()\n]*\))?};

        # pass 1: code fences and reference definitions
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            if ($l =~ /^\s{0,3}(?:`{3,}|~{3,})/) { $fence = !$fence; next; }
            next if $fence;
            if ($l =~ /^\s{0,3}\[([^\]\n]+)\]:\s*(<[^<>\n]*>|\S+)(?:\s+(?:"[^"\n]*"|\x27[^\x27\n]*\x27|\([^()\n]*\)))?\s*$/) {
                (my $d = $2) =~ s/^<(.*)>$/$1/;
                $refs{lc $1} = $d;
            }
        }
        sub emit {
            my ($n, $u) = @_;
            print "$n:$u\n" if length $u;
        }

        # pass 2: emit links
        $fence = 0;
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            if ($l =~ /^\s{0,3}(?:`{3,}|~{3,})/) { $fence = !$fence; next; }
            next if $fence;
            my $n = $i + 1;

            # Each loop works on its own copy: /g match positions are shared
            # per scalar, so reusing $l across loops would make pos() stale
            # and later loops could spin forever.
            {
                my $s = $l;
                while ($s =~ /(?<!!)\[([^\]\n]+)\]\(\s*($dest)(?:\s+$title)?\s*\)/g) {
                    next if $1 =~ /\\/;
                    (my $d = $2) =~ s/^<(.*)>$/$1/;
                    emit($n, $d);
                }
            }
            {
                my $s = $l;
                while ($s =~ /!\[([^\]\n]*)\]\(\s*($dest)(?:\s+$title)?\s*\)/g) {
                    (my $d = $2) =~ s/^<(.*)>$/$1/;
                    emit($n, $d);
                }
            }
            {
                my $s = $l;
                while ($s =~ /\[([^\]\n]+)\]\s*\[\s*([^\]\n]*)\s*\]/g) {
                    my $id = $2;
                    $id = $1 if $id eq "";
                    emit($n, $refs{lc $id}) if exists $refs{lc $id};
                }
            }
            {
                my $s = $l;
                while ($s =~ /(?i)<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27)/g) {
                    my $u = defined $1 ? $1 : $2;
                    emit($n, $u);
                }
            }
            {
                my $s = $l;
                while ($s =~ /(?i)<img\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27)/g) {
                    my $u = defined $1 ? $1 : $2;
                    emit($n, $u);
                }
            }
            {
                my $s = $l;
                while ($s =~ /<([a-z][a-z0-9+.-]*:[^<>\n]*)>/ig) {
                    emit($n, $1);
                }
            }
        }
    ' <"$file")

	echo -e "${BLUE}Found $links_found links in $file${NC}"
}

# ----- Main -----
if [ -n "$FILES" ]; then
	# shellcheck disable=SC2086
	for file in ${FILES//,/ }; do
		[ -z "$file" ] && continue
		if [ -f "$file" ]; then
			check_file "$file"
		else
			echo -e "${YELLOW}Warning: File $file not found${NC}"
		fi
	done
else
	FIND_ARGS=("$PATH_TO_CHECK")
	[ "$RECURSIVE" != "true" ] && FIND_ARGS+=("-maxdepth" "1")
	FIND_ARGS+=("-type" "f" "(" "-iname" "*.md" "-o" "-iname" "*.markdown" ")")
	if [ -n "$EXCLUDE" ]; then
		# shellcheck disable=SC2086
		for pattern in ${EXCLUDE//,/ }; do
			[ -z "$pattern" ] && continue
			FIND_ARGS+=("!" "-path" "*$pattern*")
		done
	fi
	# -print0 + sort -z keeps paths with spaces safe and output deterministic
	while IFS= read -r -d '' file; do
		check_file "$file"
	done < <(find "${FIND_ARGS[@]}" -print0 | sort -z)
fi

# ----- Report -----
if [ "${#BROKEN[@]}" -gt 0 ]; then
	JSON=$(printf '%s\n' "${BROKEN[@]}" | jq -s -c 'unique_by([.link,.file,.line_num]) | sort_by(.file,.line_num)')
else
	JSON="[]"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "json=$JSON" >>"$GITHUB_OUTPUT"
elif [ "$BROKEN_LINKS" -gt 0 ]; then
	echo -e "${BLUE}Broken links (JSON):${NC} $JSON"
fi

echo -e "${BLUE}=== Link Check Summary ===${NC}"
echo -e "${BLUE}Files checked: $CHECKED_FILES${NC}"
echo -e "${BLUE}Total links: $TOTAL_LINKS${NC}"

if [ "$BROKEN_LINKS" -eq 0 ]; then
	echo -e "${GREEN}All links are valid!${NC}"
	exit 0
else
	echo -e "${RED}Found $BROKEN_LINKS broken links!${NC}"
	exit 1
fi
