#!/usr/bin/env bash
#
# Markdown Link Checker
#
# Validates external URLs, internal file links, and heading anchors (fragments)
# found in Markdown files. Also covers HTML <a href> / <img src>, reference-style
# and autolink markdown. Skips links inside fenced code blocks, inline code spans
# and HTML comments (single- and multi-line) so code samples and commented-out
# drafts are never false positives. Emits a JSON report.
#
# Designed to run as a GitHub Action (INPUT_* env vars) or standalone.
# See README.md for configuration and `--help` for CLI options.

set -uo pipefail

# Bash 5.2+ expands & in ${var//pat/repl} to the matched text.
shopt -u patsub_replacement 2>/dev/null || true

# bash >= 4 needed for associative arrays and ${var,,}
if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
	echo "Error: bash >= 4 required (found $BASH_VERSION)" >&2
	exit 2
fi

VERSION="1.5"

usage() {
	cat <<'EOF'
Markdown Link Checker

Usage: check-links.sh [options] [files...]

Options:
  -p, --path DIR          Directory to scan (default: .)
  -f, --files FILES       Explicit files, comma or space separated
  -e, --exclude LIST      Path substrings to skip
      --ignore-urls LIST  URL substrings or globs to skip
  -t, --timeout SECONDS   Connect timeout (default: 10)
      --retry-count N     Max attempts per URL (default: 3)
  -c, --config-file FILE  Config file that overrides options
  -U, --user-agent STR    User-Agent header
  -v, --verbose           Show skipped and successful links
  -q, --quiet             Only print broken links and the summary
      --no-recursive      Do not scan subdirectories
  -h, --help              Show this help
  -V, --version           Show the version

Environment: INPUT_PATH, INPUT_FILES, INPUT_EXCLUDE, INPUT_RECURSIVE,
INPUT_TIMEOUT, INPUT_RETRY_COUNT, INPUT_VERBOSE, INPUT_QUIET,
INPUT_CONFIG_FILE, INPUT_IGNORE_URLS, INPUT_USER_AGENT

Exit codes: 0 all links valid, 1 broken links, 2 configuration error.
EOF
}

cli_error() {
	echo "Error: $*" >&2
	echo "Run with --help for usage." >&2
	exit 2
}

# CLI options override INPUT_* env vars; a config file still wins afterwards.
# Values stay in the same variables so the rest of the script is unchanged.
parse_args() {
	while [ "$#" -gt 0 ]; do
		# Accept --flag=value as well as --flag value.
		if [[ "$1" == --*=* ]]; then
			set -- "${1%%=*}" "${1#*=}" "${@:2}"
		fi
		case "$1" in
		-p | --path)
			[ "$#" -ge 2 ] || cli_error "$1 needs a value"
			INPUT_PATH="$2"
			shift 2
			;;
		-f | --files)
			[ "$#" -ge 2 ] || cli_error "$1 needs a value"
			INPUT_FILES="$2"
			shift 2
			;;
		-e | --exclude)
			[ "$#" -ge 2 ] || cli_error "$1 needs a value"
			INPUT_EXCLUDE="$2"
			shift 2
			;;
		--ignore-urls)
			[ "$#" -ge 2 ] || cli_error "$1 needs a value"
			INPUT_IGNORE_URLS="$2"
			shift 2
			;;
		-t | --timeout)
			[ "$#" -ge 2 ] || cli_error "$1 needs a value"
			INPUT_TIMEOUT="$2"
			shift 2
			;;
		--retry-count)
			[ "$#" -ge 2 ] || cli_error "$1 needs a value"
			INPUT_RETRY_COUNT="$2"
			shift 2
			;;
		-c | --config-file)
			[ "$#" -ge 2 ] || cli_error "$1 needs a value"
			INPUT_CONFIG_FILE="$2"
			shift 2
			;;
		-U | --user-agent)
			[ "$#" -ge 2 ] || cli_error "$1 needs a value"
			INPUT_USER_AGENT="$2"
			shift 2
			;;
		-v | --verbose)
			INPUT_VERBOSE=true
			shift
			;;
		-q | --quiet)
			INPUT_QUIET=true
			shift
			;;
		--recursive)
			INPUT_RECURSIVE=true
			shift
			;;
		--no-recursive)
			INPUT_RECURSIVE=false
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		-V | --version)
			printf 'check-links.sh %s\n' "$VERSION"
			exit 0
			;;
		--)
			shift
			while [ "$#" -gt 0 ]; do
				INPUT_FILES="${INPUT_FILES:+$INPUT_FILES }$1"
				shift
			done
			break
			;;
		-*) cli_error "unknown option '$1'" ;;
		*)
			# Bare arguments are files, like most linters.
			INPUT_FILES="${INPUT_FILES:+$INPUT_FILES }$1"
			shift
			;;
		esac
	done
}
parse_args "$@"

# ----- Inputs -----
PATH_TO_CHECK="${INPUT_PATH:-.}"
FILES="${INPUT_FILES:-}"
EXCLUDE="${INPUT_EXCLUDE:-}"
RECURSIVE="${INPUT_RECURSIVE:-true}"
TIMEOUT="${INPUT_TIMEOUT:-10}"
RETRY_COUNT="${INPUT_RETRY_COUNT:-3}"
VERBOSE="${INPUT_VERBOSE:-false}"
QUIET="${INPUT_QUIET:-false}"
CONFIG_FILE="${INPUT_CONFIG_FILE:-}"
IGNORE_URLS="${INPUT_IGNORE_URLS:-}"
USER_AGENT="${INPUT_USER_AGENT:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36}"

# A newline in a custom User-Agent would become a second HTTP header.
USER_AGENT="${USER_AGENT//$'\r'/ }"
USER_AGENT="${USER_AGENT//$'\n'/ }"

# ----- Output helpers -----

fatal() {
	echo "::error::❌ $*" >&2
	exit 2
}
warn() { echo "⚠️  $*" >&2; }

# Escape data for a workflow command. Keep the message on one line.
gh_escape() {
	local s=${1-}
	s=${s//'%'/'%25'}
	s=${s//$'\r'/'%0D'}
	s=${s//$'\n'/'%0A'}
	printf '%s' "$s"
}

# Escape a workflow-command property (file, line, title).
gh_prop() {
	local s
	s=$(gh_escape "${1-}")
	s=${s//','/'%2C'}
	s=${s//':'/'%3A'}
	printf '%s' "$s"
}

is_actions() { [ "${GITHUB_ACTIONS:-}" = "true" ]; }

# Annotate a broken link in the GitHub UI. Local runs stay plain.
annotate() { # <file> <line> <message>
	if is_actions; then
		printf '::error file=%s,line=%s,title=Broken link::%s\n' \
			"$(gh_prop "$1")" "$2" "$(gh_escape "$3")"
	fi
}

write_output() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
	else
		printf '%s=%s\n' "$1" "$2"
	fi
}

# Make a value safe for a Markdown table cell.
md_cell() {
	local s=${1-} pipe='|' tick='`'
	s=${s//$'\r'/}
	s=${s//$'\n'/ }
	s=${s//$pipe/\\|}
	s=${s//$tick/\'}
	printf '%s' "$s"
}

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
		QUIET) QUIET="$value" ;;
		IGNORE_URLS) IGNORE_URLS="$value" ;;
		USER_AGENT) USER_AGENT="$value" ;;
		*) warn "unknown key '$key' in config file $cfg, ignoring" ;;
		esac
	done <"$cfg"
}
if [ -n "$CONFIG_FILE" ]; then
	if [ -f "$CONFIG_FILE" ]; then
		echo "⚙️  Loading configuration from $CONFIG_FILE"
		load_config "$CONFIG_FILE"
	else
		warn "config file '$CONFIG_FILE' not found, using inputs"
	fi
fi

# ----- Input validation (bad input gets a sane default) -----
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [ "$TIMEOUT" -lt 1 ]; then
	warn "invalid TIMEOUT '$TIMEOUT', using 10"
	TIMEOUT=10
fi
[[ "$RETRY_COUNT" =~ ^[0-9]+$ ]] || {
	warn "invalid RETRY_COUNT '$RETRY_COUNT', using 3"
	RETRY_COUNT=3
}
for bool_var in RECURSIVE VERBOSE QUIET; do
	case "${!bool_var}" in
	true | false) ;;
	*)
		if [ "$bool_var" = "RECURSIVE" ]; then
			warn "invalid RECURSIVE '${!bool_var}', using true"
			RECURSIVE=true
		else
			warn "invalid $bool_var '${!bool_var}', using false"
			printf -v "$bool_var" '%s' false
		fi
		;;
	esac
done

# Fail fast on missing tools with an actionable message.
command -v perl >/dev/null 2>&1 || fatal "perl is required to parse Markdown"
command -v jq >/dev/null 2>&1 || fatal "jq is required to build the JSON report"

# Split once, so every link does not re-parse the ignore list.
declare -a IGNORE_PATTERNS=()
[ -n "$IGNORE_URLS" ] && IFS=', ' read -ra IGNORE_PATTERNS <<<"${IGNORE_URLS//$'\n'/ }"

# ----- Output colors -----
# NO_COLOR and dumb terminals win; GitHub Actions logs render ANSI.
if [ -n "${NO_COLOR+x}" ] || [ "${TERM:-}" = "dumb" ] ||
	{ [ ! -t 1 ] && ! is_actions && { [ -z "${FORCE_COLOR:-}" ] || [ "${FORCE_COLOR}" = "0" ]; }; }; then
	RED='' GREEN='' YELLOW='' BLUE='' NC=''
else
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[0;33m'
	BLUE='\033[0;34m'
	NC='\033[0m'
fi

# ----- Statistics -----
START=$SECONDS
TOTAL_LINKS=0
BROKEN_LINKS=0
CHECKED_FILES=0

# Caches (associative arrays) so repeated work is done once
declare -A EXT_URL_CACHE # url -> final http status code
declare -A HEAD_SLUGS    # file -> newline separated heading slugs
BROKEN=()                # one JSON object per broken link occurrence
LAST_ERROR_STATUS=""

[ "$QUIET" = "true" ] || {
	echo -e "${BLUE}🔗 Markdown Link Checker${NC}"
	echo -e "${BLUE}🚀 Starting link check process...${NC}"
}

# Decode %XX escapes once. Written out so %25 cannot double-decode.
urldecode() {
	local s=${1-} out='' hex
	while [[ "$s" == *%* ]]; do
		out+="${s%%%*}"
		s="${s#*%}"
		hex="${s:0:2}"
		if [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]]; then
			printf -v hex '%b' "\\x$hex"
			out+="$hex"
			s="${s:2}"
		else
			out+='%'
		fi
	done
	printf '%s%s' "$out" "$s"
}

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

is_markdown() {
	case "${1,,}" in
	*.md | *.markdown) return 0 ;;
	*) return 1 ;;
	esac
}

# All heading anchors of a markdown file (cached per file).
# Handles ATX and setext headings, closing hashes, inline code/links, explicit
# HTML id/name anchors and repeated headings (-1, -2... suffixes like GitHub).
heading_slugs() {
	local file="$1"
	if [[ -z "${HEAD_SLUGS[$file]+_}" ]]; then
		HEAD_SLUGS[$file]=$(perl -CS -e '
            my (%used, %anchors, $fence_char, $fence_len);
            $fence_char = ""; $fence_len = 0;

            sub in_fence {
                my ($l) = @_;
                if ($fence_len) {
                    if ($l =~ /^\s{0,3}(`{3,}|~{3,})\s*$/) {
                        my $f = $1;
                        $fence_len = 0
                            if substr($f, 0, 1) eq $fence_char && length($f) >= $fence_len;
                    }
                    return 1;
                }
                if ($l =~ /^\s{0,3}(`{3,}|~{3,})/) {
                    $fence_char = substr($1, 0, 1);
                    $fence_len  = length($1);
                    return 1;
                }
                return 0;
            }

            sub heading_text {
                my ($s) = @_;
                $s =~ s/!\[([^\]]*)\]\([^)]*\)/$1/g; # image -> alt text
                $s =~ s/\[([^\]]*)\]\([^)]*\)/$1/g;  # link -> link text
                $s =~ s/<[^>]+>//g;                  # inline HTML
                $s =~ s/`+//g;                       # code ticks
                $s =~ s/&amp;/&/g;
                $s =~ s/&lt;/</g;
                $s =~ s/&gt;/>/g;
                $s =~ s/&quot;/"/g;
                $s =~ s/&#39;/\x27/g;
                return $s;
            }

            sub push_heading {
                my ($s) = @_;
                $s = lc heading_text($s);
                $s =~ s/[^\p{L}\p{N}\s_-]+//g;
                $s =~ s/\s+/-/g;
                $s =~ s/^-+|-+$//g;
                return if $s eq "";
                my ($b, $i) = ($s, 0);
                while ($used{$s}++) { $s = "$b-" . ++$i; }
                print "$s\n";
            }

            # <a id="x"> / <a name="x"> provide manual anchors. Kept separate
            # from %used so they do not shift heading dedup suffixes.
            sub add_anchor {
                my ($s) = @_;
                $s = lc $s;
                $s =~ s/[^\p{L}\p{N}\s_-]+//g;
                $s =~ s/\s+/-/g;
                $s =~ s/^-+|-+$//g;
                $anchors{$s} = 1 if $s ne "";
            }

            my @lines = <>;
            for (my $i = 0; $i <= $#lines; $i++) {
                my $l = $lines[$i];
                next if in_fence($l);
                if ($l =~ /</) {
                    while ($l =~ /\s(?:id|name)\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27)/gi) {
                        add_anchor(defined $1 ? $1 : $2);
                    }
                }
                if ($l =~ /^\s{0,3}#{1,6}\s+(.*?)(?:\s+#+\s*)?$/) {
                    push_heading($1);
                    next;
                }
                # setext heading: text line directly above === or ---
                if ($i < $#lines && $l =~ /\S/ && $l !~ /^\s{0,3}(?:[-*+]\s|\d+[.)]\s|>|#{1,6}\s)/) {
                    if ($lines[$i + 1] =~ /^\s{0,3}(?:=+|-+)\s*$/) {
                        push_heading($l);
                        $i++;
                    }
                }
            }
            print "$_\n" for keys %anchors;
        ' <"$file")
	fi
	printf '%s' "${HEAD_SLUGS[$file]}"
}

# Single jq call per broken link (O(n) total, not the old O(n^2) rewrite).
broken_json() {
	jq -nc --arg link "$1" --arg file "${2#./}" --argjson line_num "$3" --arg status "$4" \
		'{link: $link, file: $file, line_num: $line_num, status: $status}'
}

# 000, timeouts, rate limits and server errors are worth another try.
# Other 4xx answers (404, 403, 410...) will not change on a retry.
retryable_status() {
	case "$1" in
	000 | 408 | 425 | 429 | 5[0-9][0-9]) return 0 ;;
	*) return 1 ;;
	esac
}

# Ignore entries are substrings, or shell globs when they contain * or ?.
# [[ == ]] does pattern matching, so no eval/untrusted execution happens.
url_ignored() {
	local url="$1" pattern
	for pattern in "${IGNORE_PATTERNS[@]}"; do
		[ -z "$pattern" ] && continue
		if [[ "$pattern" == *'*'* || "$pattern" == *'?'* ]]; then
			# shellcheck disable=SC2053 # glob matching is the point
			[[ "$url" == $pattern ]] && return 0
		elif [[ "$url" == *"$pattern"* ]]; then
			return 0
		fi
	done
	return 1
}

# Check one URL found in `file` on `line`.
check_url() {
	local url="$1" file="$2" line="$3"
	local base target fragment status_code code attempt attempts request_url

	# HTML entities are common in href attributes: ?a=1&amp;b=2
	url="${url//&amp;/&}"

	if url_ignored "$url"; then
		[ "$VERBOSE" = "true" ] && echo -e "${YELLOW}⏭️  Skipped (ignored): $url${NC}"
		return 0
	fi

	# ----- External URL (scheme comparison is case-insensitive) -----
	case "${url,,}" in
	http://* | https://* | //*)
		if [[ "${url,,}" == //* ]]; then
			request_url="https:${url%%#*}"
		else
			request_url="${url%%#*}"
		fi
		# Browsers accept literal spaces; curl does not.
		request_url="${request_url// /%20}"

		command -v curl >/dev/null 2>&1 || fatal "curl is required to check external links"

		if [[ -n "${EXT_URL_CACHE[$request_url]+_}" ]]; then
			code="${EXT_URL_CACHE[$request_url]}"
			if [ "$code" -gt 0 ] && [ "$code" -lt 400 ]; then
				[ "$VERBOSE" = "true" ] && echo -e "${GREEN}✅ Link OK (cached): $url${NC}"
				return 0
			fi
			echo -e "${RED}❌ $file:$line - Broken link: $url (Status: $code) [cached]${NC}"
			LAST_ERROR_STATUS="$code"
			return 1
		fi

		attempt=0
		attempts=$((RETRY_COUNT > 0 ? RETRY_COUNT : 1))
		status_code=""
		while [ "$attempt" -lt "$attempts" ]; do
			attempt=$((attempt + 1))
			status_code=$(curl -sS -L --globoff -o /dev/null -w "%{http_code}" \
				--proto "=http,https" --proto-redir "=http,https" \
				--connect-timeout "$TIMEOUT" --max-time "$((TIMEOUT * 2))" \
				-A "$USER_AGENT" -- "$request_url" 2>/dev/null) || status_code=""
			[[ "$status_code" =~ ^[0-9]{3}$ ]] || status_code="000"
			if [ "$status_code" -ge 200 ] && [ "$status_code" -lt 400 ]; then
				break
			fi
			if [ "$attempt" -ge "$attempts" ] || ! retryable_status "$status_code"; then
				break
			fi
			echo -e "${YELLOW}🔁 Attempt $attempt failed for $url (Status: $status_code). Retrying...${NC}"
			sleep 1
		done
		EXT_URL_CACHE["$request_url"]="$status_code"

		if [ "$status_code" -ge 200 ] && [ "$status_code" -lt 400 ]; then
			[ "$VERBOSE" = "true" ] && echo -e "${GREEN}✅ Link OK: $url${NC}"
			return 0
		fi
		echo -e "${RED}❌ $file:$line - Broken link: $url (Status: $status_code)${NC}"
		LAST_ERROR_STATUS="$status_code"
		return 1
		;;
	esac

	# ----- Other schemes (mailto:, tel:, ftp:, data:, javascript:) -----
	if [[ "${url,,}" =~ ^[a-z][a-z0-9+.-]*: ]]; then
		[ "$VERBOSE" = "true" ] && echo -e "${YELLOW}⏭️  Skipped (unsupported scheme): $url${NC}"
		return 0
	fi

	# ----- Internal link -----
	# Split fragment first, then query, then percent-decode each part.
	base="$(dirname "$file")"
	target=""
	fragment=""
	local path_part="$url"
	if [[ "$path_part" == *#* ]]; then
		fragment="${path_part#*#}"
		path_part="${path_part%%#*}"
	fi
	path_part="${path_part%%[?]*}"
	path_part="$(urldecode "$path_part")"
	fragment="$(urldecode "$fragment")"

	if [ -z "$path_part" ]; then
		# fragment-only link, e.g. [jump](#section) - target is the current file
		target="$file"
	elif [[ "$path_part" == /* ]]; then
		# absolute path inside the repo
		target=".$path_part"
	else
		target="$base/$path_part"
	fi

	if [ -n "$path_part" ] && [ ! -e "$target" ]; then
		echo -e "${RED}❌ $file:$line - Broken link: $url (File not found: $target)${NC}"
		LAST_ERROR_STATUS="File not found"
		return 1
	fi

	if [ -n "$fragment" ] && is_markdown "$target"; then
		local frag_slug slugs
		frag_slug="$(slug "$fragment")"
		slugs="$(heading_slugs "$target")"
		if [ "$frag_slug" != "top" ] && [[ $'\n'"$slugs"$'\n' != *$'\n'"$frag_slug"$'\n'* ]]; then
			echo -e "${RED}❌ $file:$line - Broken link: $url#$fragment (Fragment not found in $target)${NC}"
			LAST_ERROR_STATUS="Fragment not found"
			return 1
		fi
	fi

	[ "$VERBOSE" = "true" ] && echo -e "${GREEN}✅ Link OK: $path_part${NC}"
	return 0
}

# Extract and check every link from one file.
check_file() {
	local file="$1" links_found=0 line_data
	[ "$QUIET" = "true" ] || echo -e "${BLUE}📄 Checking links in $file${NC}"
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
				annotate "${file#./}" "$line_num" "Broken link: $link ($LAST_ERROR_STATUS)"
			fi
		fi
	}

	# Single perl pass extracts every link form and prints "line:url" lines:
	#   - markdown [text](url), incl. titles, <url> angle form and badges
	#   - images ![alt](url)
	#   - reference style [text][id], [text][]
	#   - HTML <a href="..."> / <img src="...">, quoted or bare
	#   - autolinks <scheme:...>
	# Fenced blocks, inline code spans and HTML comments are skipped.
	# shortcut: 4-space indented code blocks are still scanned; add masking
	# only if they cause real false positives (list nesting makes it risky).
	while IFS= read -r line_data; do
		process_link "$line_data"
	done < <(perl -CS -e '
        use strict;
        use warnings;
        my @lines = <>;
        my (%refs, $fence_char, $fence_len, $dest, $title, $in_comment);
        ($fence_char, $fence_len, $in_comment) = ("", 0, 0);
        $dest    = qr{(?:<[^<>\n]*>|(?:[^()<>\n]|\([^()\n]*\))+)};
        $title   = qr{(?:"[^"\n]*"|\x27[^\x27\n]*\x27|\([^()\n]*\))?};

        sub in_fence {
            my ($l) = @_;
            if ($fence_len) {
                if ($l =~ /^\s{0,3}(`{3,}|~{3,})\s*$/) {
                    my $f = $1;
                    $fence_len = 0
                        if substr($f, 0, 1) eq $fence_char && length($f) >= $fence_len;
                }
                return 1;
            }
            if ($l =~ /^\s{0,3}(`{3,}|~{3,})/) {
                $fence_char = substr($1, 0, 1);
                $fence_len  = length($1);
                return 1;
            }
            return 0;
        }

        # Remove HTML comments (including multi-line) and inline code spans.
        sub mask {
            my ($l) = @_;
            my $out = "";
            while (length $l) {
                if ($in_comment) {
                    if ($l =~ /-->/) {
                        $l =~ s/^.*?-->//s;
                        $in_comment = 0;
                    } else {
                        $l = "";
                    }
                    next;
                }
                if ($l =~ /^(.*?)<!--/s) {
                    $out .= $1;
                    $l = substr($l, length($1) + 4);
                    $in_comment = 1;
                    next;
                }
                $out .= $l;
                last;
            }
            $out =~ s/(`+)(?:(?!\1).)*?\1//g;
            return $out;
        }

        sub emit {
            my ($n, $u) = @_;
            print "$n:$u\n" if length $u;
        }

        # pass 1: reference definitions (outside fences)
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            next if in_fence($l);
            # Footnotes ([^1]: note) are not reference definitions.
            if ($l =~ /^\s{0,3}\[(?!\^)([^\]\n]+)\]:\s*(<[^<>\n]*>|\S+)(?:\s+(?:"[^"\n]*"|\x27[^\x27\n]*\x27|\([^()\n]*\)))?\s*$/) {
                (my $d = $2) =~ s/^<(.*)>$/$1/;
                $refs{lc $1} = $d;
            }
        }

        # pass 2: emit links
        ($fence_char, $fence_len) = ("", 0);
        for my $i (0 .. $#lines) {
            my $l = $lines[$i];
            next if in_fence($l);
            my $n = $i + 1;
            my $m = mask($l);

            # Each loop works on its own copy: /g match positions are shared
            # per scalar, so reusing a scalar across loops would make pos()
            # stale and later loops could spin forever.
            {
                my $s = $m;
                while ($s =~ /(?<!!)(?<!\\)\[([^\]\n]+)\]\(\s*($dest)(?:\s+$title)?\s*\)/g) {
                    next if $1 =~ /\\/;
                    (my $d = $2) =~ s/^<(.*)>$/$1/;
                    emit($n, $d);
                }
            }
            {
                my $s = $m;
                while ($s =~ /(?<!\\)!\[([^\]\n]*)\]\(\s*($dest)(?:\s+$title)?\s*\)/g) {
                    (my $d = $2) =~ s/^<(.*)>$/$1/;
                    emit($n, $d);
                }
            }
            {
                # badge link wrapper: [![alt](img)](target)
                my $s = $m;
                while ($s =~ /(?<!\\)\[!\[[^\]\n]*\]\([^()\n]*\)\]\(\s*($dest)(?:\s+$title)?\s*\)/g) {
                    (my $d = $1) =~ s/^<(.*)>$/$1/;
                    emit($n, $d);
                }
            }
            {
                my $s = $m;
                while ($s =~ /(?<!\\)\[([^\]\n]+)\]\s*\[\s*([^\]\n]*)\s*\]/g) {
                    my $id = $2;
                    $id = $1 if $id eq "";
                    emit($n, $refs{lc $id}) if exists $refs{lc $id};
                }
            }
            {
                # shortcut reference `[id]` (or image `![id]`): not followed
                # by `(`/`[`, escaped, or the second label of a full reference.
                my $s = $m;
                while ($s =~ /(?<![\\\]])\[([^\]\n]+)\](?![\[(:])/g) {
                    emit($n, $refs{lc $1}) if exists $refs{lc $1};
                }
            }
            {
                my $s = $m;
                while ($s =~ /(?i)<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27|([^\s>]+))/g) {
                    my $u = defined $1 ? $1 : defined $2 ? $2 : $3;
                    emit($n, $u);
                }
            }
            {
                my $s = $m;
                while ($s =~ /(?i)<img\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27|([^\s>]+))/g) {
                    my $u = defined $1 ? $1 : defined $2 ? $2 : $3;
                    emit($n, $u);
                }
            }
            {
                my $s = $m;
                while ($s =~ /<([a-z][a-z0-9+.-]*:[^<>\n]*)>/ig) {
                    emit($n, $1);
                }
            }
        }
    ' <"$file")

	[ "$QUIET" = "true" ] || echo -e "${BLUE}🔍 Found $links_found links in $file${NC}"
}

# ----- Main -----
if [ -n "$FILES" ]; then
	IFS=', ' read -ra FILE_LIST <<<"${FILES//$'\n'/ }"
	for file in "${FILE_LIST[@]}"; do
		[ -z "$file" ] && continue
		if [ -f "$file" ]; then
			check_file "$file"
		# Allow `path: docs` + `files: README.md` to mean docs/README.md.
		elif [ "$PATH_TO_CHECK" != "." ] && [ -f "$PATH_TO_CHECK/$file" ]; then
			check_file "$PATH_TO_CHECK/$file"
		elif [ -e "$file" ]; then
			warn "'$file' is not a regular file, skipping"
		else
			echo -e "${YELLOW}⚠️  File $file not found${NC}"
		fi
	done
else
	[ -e "$PATH_TO_CHECK" ] || fatal "path '$PATH_TO_CHECK' does not exist"
	FIND_ARGS=("$PATH_TO_CHECK")
	[ "$RECURSIVE" != "true" ] && FIND_ARGS+=("-maxdepth" "1")
	FIND_ARGS+=("-type" "f" "(" "-iname" "*.md" "-o" "-iname" "*.markdown" ")")
	if [ -n "$EXCLUDE" ]; then
		IFS=', ' read -ra EXCLUDES <<<"${EXCLUDE//$'\n'/ }"
		for pattern in "${EXCLUDES[@]}"; do
			[ -z "$pattern" ] && continue
			FIND_ARGS+=("!" "-path" "*$pattern*")
		done
	fi
	# -print0 + sort -z keeps paths with spaces safe and output deterministic
	while IFS= read -r -d '' file; do
		check_file "$file"
	done < <(find "${FIND_ARGS[@]}" -print0 | sort -z)
fi

# An empty scan is usually a wrong path/extension, not a clean repo.
if [ "$CHECKED_FILES" -eq 0 ]; then
	warn "no Markdown files were checked (looked for *.md and *.markdown)"
fi

# ----- Report -----
if [ "${#BROKEN[@]}" -gt 0 ]; then
	JSON=$(printf '%s\n' "${BROKEN[@]}" | jq -s -c 'unique_by([.link,.file,.line_num]) | sort_by(.file,.line_num)')
else
	JSON="[]"
fi

write_output json "$JSON"
write_output broken_count "$BROKEN_LINKS"
write_output checked_files "$CHECKED_FILES"
write_output total_links "$TOTAL_LINKS"

ELAPSED=$((SECONDS - START))

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "### 🔗 Markdown Link Checker"
		echo
		echo "| Metric | Value |"
		echo "| --- | --- |"
		printf '| 📄 Files checked | %d |\n' "$CHECKED_FILES"
		printf '| 🔗 Links checked | %d |\n' "$TOTAL_LINKS"
		printf '| ❌ Broken links | %d |\n' "$BROKEN_LINKS"
		printf '| ⏱️ Duration | %ds |\n' "$ELAPSED"
		if [ "${#BROKEN[@]}" -gt 0 ]; then
			echo
			echo "| File | Line | Link | Status |"
			echo "| --- | --- | --- | --- |"
			while IFS=$'\t' read -r row_file row_line row_link row_status; do
				# shellcheck disable=SC2016 # backticks are Markdown, not a command
				printf '| `%s` | %s | `%s` | `%s` |\n' \
					"$(md_cell "$row_file")" "$row_line" \
					"$(md_cell "$row_link")" "$(md_cell "$row_status")"
			done < <(printf '%s\n' "${BROKEN[@]}" |
				jq -sr '.[:50][] | [.file, .line_num, .link, .status] | @tsv')
			if [ "$BROKEN_LINKS" -gt 50 ]; then
				echo
				echo "_…and $((BROKEN_LINKS - 50)) more in the step log._"
			fi
		else
			echo
			echo "🎉 All links are valid."
		fi
	} >>"$GITHUB_STEP_SUMMARY"
fi

echo -e "${BLUE}📊 === Link Check Summary ===${NC}"
echo -e "${BLUE}📄 Files checked: $CHECKED_FILES${NC}"
echo -e "${BLUE}🔗 Total links: $TOTAL_LINKS${NC}"
echo -e "${BLUE}⏱️  Duration: ${ELAPSED}s${NC}"

if [ "$BROKEN_LINKS" -eq 0 ]; then
	echo -e "${GREEN}🎉 All links are valid!${NC}"
	exit 0
else
	echo -e "${RED}💥 Found $BROKEN_LINKS broken links!${NC}"
	exit 1
fi
