#!/usr/bin/env bash
#
# Test runner for the Markdown Link Checker.
# No framework, just deterministic black-box scenarios against a fake `curl`
# shim, so every run is offline, fast, and repeatable.
#
# Usage: bash test/run-tests.sh

set -uo pipefail

cd "$(dirname "$0")" || exit 1
ROOT="$(cd .. && pwd)"
CHECK="$ROOT/check-links.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mlc-tests.XXXXXX")"

PASS=0
FAIL=0
FAILED=()

# A deterministic curl replacement. Host-based canned responses; every real
# invocation is appended to a log for call-count assertions.
write_shim() {
	local sb="$1"
	mkdir -p "$sb/bin" "$sb/.state"
	cat >"$sb/bin/curl" <<'SHIM'
#!/usr/bin/env bash
url=""
for a in "$@"; do url="$a"; done
log="${FAKE_CURL_LOG:-/dev/null}"
{
    printf 'ARGS'
    for a in "$@"; do printf ' <%s>' "$a"; done
    printf '\n'
} >> "$log"
state="${FAKE_CURL_STATE:-/tmp}"
case "$url" in
    *ok.example*)       echo 200 ;;
    *broken.example*)   echo 404 ;;
    *servererr.example*) echo 500 ;;
    *flaky.example*)
        n=0; [ -f "$state/flaky" ] && n="$(cat "$state/flaky")"
        n=$((n + 1)); echo "$n" > "$state/flaky"
        [ "$n" -ge 2 ] && echo 200 || echo 500
        ;;
    *timeout.example*)  echo 000 ;;
    *)                  echo 200 ;;
esac
SHIM
	chmod +x "$sb/bin/curl"
}

# Run the checker in a sandbox. Extra env vars passed as KEY=VAL args.
run_check() {
	local sb="$1"
	shift
	(
		cd "$sb" || exit 99
		env -i \
			PATH="$sb/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
			HOME="$sb" \
			GITHUB_OUTPUT="$sb/gh.out" \
			FAKE_CURL_LOG="$sb/curl.log" \
			FAKE_CURL_STATE="$sb/.state" \
			"$@" \
			bash "$CHECK" >"$sb/stdout" 2>"$sb/stderr"
		echo $? >"$sb/exit"
	)
}

assert_exit() { [ "$(cat "$2/exit")" = "$1" ] || fail "$3 (exit=$(cat "$2/exit") want=$1)"; }
assert_grep() { grep -q -- "$1" "$2" || fail "$3 (missing '$1' in $2)"; }
# jq filter against sandbox/gh.out (strip the `json=` prefix) must be truthy
assert_json() { sed 's/^json=//' "$2/gh.out" | jq -e "$1" >/dev/null 2>&1 || fail "$3 (jq '$1' failed)"; }
assert_crlog() {
	local c=0
	[ -s "$2/curl.log" ] && c=$(grep -c '^ARGS' "$2/curl.log")
	[ "$c" = "$1" ] || fail "$3 (curl calls=$c want=$1)"
}
assert_arg() { grep -q -- "$1" "$2/curl.log" || fail "$3 (curl missing arg '$1')"; }

ok() {
	PASS=$((PASS + 1))
	echo "    ok: $1"
}
fail() {
	FAIL=$((FAIL + 1))
	FAILED+=("$1")
	echo "  FAIL: $1"
}

test_case() { echo "== $1 =="; }

gen_sb() {
	local sb="$TMP/case-$1"
	rm -rf "$sb"
	mkdir -p "$sb"
	write_shim "$sb"
	echo "$sb"
}
gen_md() { printf '%b' "$2" >"$1"; }

# ---------------------------------------------------------------- tests

test_case "external ok + internal file + exit 0"
t() {
	local sb
	sb="$(gen_sb ok)"
	gen_md "$sb/README.md" 'Home\n\n- [external](https://ok.example/a)\n- [internal](./docs/guide.md)\n'
	mkdir -p "$sb/docs"
	gen_md "$sb/docs/guide.md" 'Guide\n'
	run_check "$sb" INPUT_PATH=. INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "ok repo must exit 0"
	assert_grep "All links are valid" "$sb/stdout" "missing success message"
	assert_json '. == []' "$sb" "ok repo must emit empty json"
	ok "external+internal ok, exit 0"
}
t

test_case "broken external 404 reported with line/status in JSON"
t() {
	local sb
	sb="$(gen_sb broken)"
	gen_md "$sb/README.md" '# T\n\nbad [x](https://broken.example/missing)\n'
	run_check "$sb" INPUT_RETRY_COUNT=0 INPUT_VERBOSE=false
	assert_exit 1 "$sb" "broken link must exit 1"
	assert_grep "Broken link: https://broken.example/missing (Status: 404)" "$sb/stdout" "404 not reported"
	assert_json '. | length == 1' "$sb" "json must have 1 row"
	assert_json '.[0].link == "https://broken.example/missing" and .[0].line_num == 3 and .[0].status == "404" and .[0].file == "README.md"' "$sb" "json row fields wrong"
	ok "404 external broken, exit 1, json complete"
}
t

test_case "internal missing file"
t() {
	local sb
	sb="$(gen_sb missfile)"
	gen_md "$sb/README.md" 'bad [x](./gone.md)\n'
	run_check "$sb" INPUT_RETRY_COUNT=0
	assert_exit 1 "$sb" "missing internal file must fail"
	assert_grep "File not found" "$sb/stdout" "missing file not reported"
	assert_json '.[0].status == "File not found" and .[0].link == "./gone.md"' "$sb" "json status wrong"
	ok "internal missing file detected"
}
t

test_case "internal relative + ../-traversal + absolute path"
t() {
	local sb
	sb="$(gen_sb intern)"
	mkdir -p "$sb/docs/sub"
	gen_md "$sb/docs/sub/a.md" 'a\n'
	gen_md "$sb/docs/a.md" 'sibling\n'
	gen_md "$sb/docs/sub/b.md" '[sibling](../a.md)\n'
	gen_md "$sb/README.md" '[abs](/docs/sub/a.md)\n[up](./docs/sub/a.md)\n'
	run_check "$sb" INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "valid internal links must pass"
	ok "..-traversal and absolute internal links resolve"
}
t

test_case "fragment anchors: casing, punctuation, hyphen/underscore, dedup"
t() {
	local sb
	sb="$(gen_sb frag)"
	gen_md "$sb/frag.md" '# Hello World\n\n## Foo, Bar!\n\n### my_section\n\n#### Go Up\n\n#### Go Up\n\n[dash](#hello-world)\n[case](#HELLO-WORLD)\n[punct](#foo-bar)\n[underscore](#my_section)\n[dup](#go-up)\n[dup2](#go-up-1)\n'
	run_check "$sb" INPUT_PATH=frag.md INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "valid fragments must pass"
	ok "fragment slugger: casing, punctuation, underscore, dedup suffixes"
}
t

test_case "fragment missing / wrong hyphen-vs-underscore / on empty dir"
t() {
	local sb
	sb="$(gen_sb fragbad)"
	gen_md "$sb/frag.md" '# Hello\n\n[missing](#nope)\n[underscore-as-hyphen](#my-section)\n'
	run_check "$sb" INPUT_PATH=frag.md INPUT_RETRY_COUNT=0
	assert_exit 1 "$sb" "missing fragments must fail"
	assert_grep "Fragment not found" "$sb/stdout" "fragment failure not reported"
	ok "broken fragment links detected"
}
t

test_case "fragment on another file + fragment-only same-file link"
t() {
	local sb
	sb="$(gen_sb fragcross)"
	mkdir -p "$sb/other"
	gen_md "$sb/other/deep.md" '## My Section\n'
	gen_md "$sb/README.md" '[cross](./other/deep.md#my-section)\n[local](#top)\n\n# top\n'
	run_check "$sb" INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "cross-file and same-file fragments must pass"
	ok "cross-file and fragment-only links ok"
}
t

test_case "heading file with tests for repeated heading suffix -1"
t() {
	local sb
	sb="$(gen_sb fragdup)"
	gen_md "$sb/f.md" '# Foo\n# Foo\n# Foo\n[second](#foo-1)\n[third](#foo-2)\n'
	run_check "$sb" INPUT_PATH=f.md INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "dedup suffixes must resolve"
	ok "dedup suffixes resolve"
}
t

test_case "image links (md) ok + broken"
t() {
	local sb
	sb="$(gen_sb img)"
	gen_md "$sb/README.md" '![ok](https://ok.example/i.png)\n![bad](https://broken.example/i.png)\n'
	run_check "$sb" INPUT_RETRY_COUNT=0
	assert_exit 1 "$sb" "broken image must fail"
	assert_json '[.[] | select(.link == "https://broken.example/i.png")] | length == 1' "$sb" "broken image not in json"
	ok "markdown image links checked"
}
t

test_case "HTML link variants: double/single quotes, attrs before/after, case"
t() {
	local sb
	sb="$(gen_sb html)"
	gen_md "$sb/f.html" 'see <a href="https://ok.example/x">one</a>\nand <a class=c href='"'"'https://ok.example/y'"'"'>two</a>\n<a id=t href="https://broken.example/z">bad</a>\n<A HREF='"'"'https://broken.example/w'"'"'>BAD</A>\n'
	run_check "$sb" INPUT_FILES="f.html" INPUT_RETRY_COUNT=0
	assert_exit 1 "$sb" "broken html links must fail"
	assert_json '[.[] | select(.link | startswith("https://broken.example"))] | length == 2' "$sb" "bad HTML links missing"
	ok "html href single/double quotes, attr order, case"
}
t

test_case "markdown link titles are handled"
t() {
	local sb
	sb="$(gen_sb titles)"
	gen_md "$sb/t.md" '[a](https://ok.example/x "a title")\n[b](https://broken.example/y '"'"'single title'"'"')\n'
	run_check "$sb" INPUT_PATH=t.md INPUT_RETRY_COUNT=0
	assert_exit 1 "$sb" "titled links must still be checked"
	assert_json '. | length == 1' "$sb" "expected exactly the broken titled link"
	ok "titles (double and single) parsed"
}
t

test_case "reference-style links: [text][id], [text][], defs with/without title"
t() {
	local sb
	sb="$(gen_sb refs)"
	gen_md "$sb/r.md" '[one][id1] and [two][]\n\n[id1]: https://ok.example/a\n[id2]: https://broken.example/b "with title"\n[two]: https://ok.example/c\n'
	run_check "$sb" INPUT_PATH=r.md INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "resolved refs ok; unresolved [two][id2] not checked"
	ok "reference links resolved, unknown ids ignored"
}
t

test_case "autolinks <scheme:...> and mailto/tel schemes never reported broken"
t() {
	local sb
	sb="$(gen_sb autolink)"
	gen_md "$sb/a.md" 'visit <https://ok.example/x>\n\n<a href="mailto:a@b.co">m</a>\n\n[tel](tel:+1-555-0100)\n[data](data:text/plain,hi)\n[mail](mailto:x@y.zz)\n'
	run_check "$sb" INPUT_PATH=a.md INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "mailto/tel/data must not be broken links"
	assert_crlog 1 "$sb" "only the autolink URL should hit curl"
	ok "autolinks checked, non-http schemes skipped"
}
t

test_case "links inside fenced code blocks are skipped"
t() {
	local sb
	sb="$(gen_sb fences)"
	# shellcheck disable=SC2016
	gen_md "$sb/f.md" 'outside [a](https://ok.example/a)\n\n```markdown\n[nope](https://broken.example/fake)\n```\n\nmore ``inline`[x](https://ok.example/b)\n'
	run_check "$sb" INPUT_PATH=f.md INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "code-block links must be ignored"
	assert_crlog 2 "$sb" "exactly the 2 real links hit curl"
	ok "fenced code blocks ignored"
}
t

test_case "external cache: repeated url hits curl once; status kept"
t() {
	local sb
	sb="$(gen_sb cache)"
	gen_md "$sb/c.md" '[a](https://ok.example/dup)\n[b](https://ok.example/dup)\n[img](https://broken.example/d1)\n[img2](https://broken.example/d1)\n'
	run_check "$sb" INPUT_RETRY_COUNT=0
	assert_exit 1 "$sb" "duplicate broken must fail"
	assert_crlog 2 "$sb" "cache must dedupe curl calls (2 unique urls, 4 links)"
	ok "external cache dedupes requests"
}
t

test_case "flaky URL: retry succeeds before exhausting attempts"
t() {
	local sb
	sb="$(gen_sb flaky)"
	gen_md "$sb/f.md" '[x](https://flaky.example/thing)\n'
	run_check "$sb" INPUT_RETRY_COUNT=3
	assert_exit 0 "$sb" "flaky-but-eventually-ok must pass"
	assert_crlog 2 "$sb" "expected 2 attempts"
	ok "retry recovers from transient failures"
}
t

test_case "persistent 500 honours retry then fails"
t() {
	local sb
	sb="$(gen_sb p500)"
	gen_md "$sb/f.md" '[x](https://servererr.example/thing)\n'
	run_check "$sb" INPUT_RETRY_COUNT=2
	assert_exit 1 "$sb" "persistent server errors must fail"
	assert_crlog 2 "$sb" "retry count must be honoured"
	assert_json '.[0].status == "500"' "$sb" "status must be last attempt"
	ok "failure after retries, final status recorded"
}
t

test_case "timeout (000) reported broken"
t() {
	local sb
	sb="$(gen_sb tmo)"
	gen_md "$sb/f.md" '[x](https://timeout.example/x)\n'
	run_check "$sb" INPUT_RETRY_COUNT=1
	assert_exit 1 "$sb" "timeout must fail"
	assert_json '.[0].status == "000"' "$sb" "timeout status 000"
	ok "connect timeouts treated as broken"
}
t

test_case "ignore-urls substring skips matching links"
t() {
	local sb
	sb="$(gen_sb ig)"
	gen_md "$sb/README.md" '[a](https://example.com/ignored)\n[b](http://localhost:8080/x)\n'
	run_check "$sb" INPUT_IGNORE_URLS="example.com,localhost" INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "ignored urls must pass"
	assert_crlog 0 "$sb" "no curl calls expected"
	ok "ignore-urls works"
}
t

test_case "files= input: commas, spaces, missing-file warning"
t() {
	local sb
	sb="$(gen_sb files)"
	gen_md "$sb/a.md" 'ok [x](https://ok.example/x)\n'
	gen_md "$sb/b.md" 'ok [y](https://ok.example/y)\n'
	run_check "$sb" INPUT_FILES="a.md, b.md, nope.md" INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "explicit file list must pass"
	assert_grep "File nope.md not found" "$sb/stdout" "missing file warning expected"
	assert_grep "Checking links in a.md" "$sb/stdout" "a.md not checked"
	assert_grep "Checking links in b.md" "$sb/stdout" "b.md not checked"
	ok "files input with mixed separators + warning"
}
t

test_case "recursive=false limits to top level"
t() {
	local sb
	sb="$(gen_sb norec)"
	mkdir -p "$sb/sub"
	gen_md "$sb/top.md" 'a\n'
	gen_md "$sb/sub/deep.md" '[x](https://broken.example/deep)\n'
	run_check "$sb" INPUT_RECURSIVE=false INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "nested file must not be scanned when non-recursive"
	assert_grep "Checking links in ./top.md" "$sb/stdout" "top file not scanned"
	ok "recursive=false works"
}
t

test_case "exclude filters paths"
t() {
	local sb
	sb="$(gen_sb excl)"
	mkdir -p "$sb/node_modules"
	gen_md "$sb/README.md" 'ok [a](https://ok.example/x)\n'
	gen_md "$sb/node_modules/deep.md" '[x](https://broken.example/y)\n'
	run_check "$sb" INPUT_EXCLUDE="node_modules" INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "excluded dir must be skipped"
	ok "exclude pattern works"
}
t

test_case ".markdown and case-insensitive extensions"
t() {
	local sb
	sb="$(gen_sb ext)"
	gen_md "$sb/A.MD" '[x](https://ok.example/x)\n'
	gen_md "$sb/B.markdown" '[y](https://ok.example/y)\n'
	run_check "$sb" INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "extensions must be scanned"
	assert_grep "Checking links in ./A.MD" "$sb/stdout" "A.MD not scanned"
	assert_grep "Checking links in ./B.markdown" "$sb/stdout" "B.markdown not scanned"
	ok ".markdown and .MD scanned"
}
t

test_case "config file applies keys and warns on unknown"
t() {
	local sb
	sb="$(gen_sb cfg)"
	gen_md "$sb/README.md" '[x](https://ok.example/x)\n'
	mkdir -p "$sb" && printf 'PATH_TO_CHECK="."\nRETRY_COUNT=0\nBOGUS_KEY=1\n' >"$sb/linkcheck.conf"
	run_check "$sb" INPUT_CONFIG_FILE="$sb/linkcheck.conf" INPUT_PATH=/nonexistent INPUT_RETRY_COUNT=9
	assert_exit 0 "$sb" "config must override inputs"
	assert_grep "unknown key 'BOGUS_KEY'" "$sb/stderr" "unknown key must warn"
	assert_crlog 1 "$sb" "config RETRY_COUNT=0 => 1 attempt"
	ok "config file parsing (override + unknown key warning)"
}
t

test_case "github output json is written, listed, exit reflects results"
t() {
	local sb
	sb="$(gen_sb out)"
	gen_md "$sb/README.md" 'a [x](https://broken.example/a) b [y](https://broken.example/a"@@)\n'
	run_check "$sb" INPUT_RETRY_COUNT=0
	assert_exit 1 "$sb" "must exit 1"
	assert_json '. | type == "array"' "$sb" "gh.out must be json array"
	ok "github output json"
}
t

test_case "empty repo is a pass"
t() {
	local sb
	sb="$(gen_sb empty)"
	mkdir -p "$sb"
	run_check "$sb"
	assert_exit 0 "$sb" "no files must pass"
	assert_json '. == []' "$sb" "empty json"
	ok "empty repo exit 0"
}
t

test_case "malformed link forms produce no crashes and no phantom failures"
t() {
	local sb
	sb="$(gen_sb malformed)"
	gen_md "$sb/m.md" '# h\n\n[empty]()\n[no-close](https://ok.example/a\n[escaped](https://ok.example/a_(1))\n[junk](#)\n[paren](https://ok.example/p_(1))\n[scheme](javascript:alert(1))\n'
	run_check "$sb" INPUT_PATH=m.md INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "malformed links must not crash or fail"
	ok "malformed/escaped/scheme links tolerated"
}
t

test_case "unicode headings resolve correctly"
t() {
	local sb
	sb="$(gen_sb uni)"
	gen_md "$sb/u.md" '## Über µ, Testing!\n\n[go](#über-µ-testing)\n'
	run_check "$sb" INPUT_PATH=u.md INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "unicode headings must resolve"
	ok "unicode heading anchors"
}
t

test_case "crlf file text handled"
t() {
	local sb
	sb="$(gen_sb crlf)"
	gen_md "$sb/c.md" '# Foo\r\n\r\n[a](#foo)\r\n'
	run_check "$sb" INPUT_PATH=c.md INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "crlf headings must resolve"
	ok "crlf line endings handled"
}
t

test_case "empty-link line numbers correct with multiple links per line"
t() {
	local sb
	sb="$(gen_sb multli)"
	gen_md "$sb/m.md" 'text [a](https://broken.example/x) [b](https://broken.example/y)\n'
	run_check "$sb" INPUT_PATH=m.md INPUT_RETRY_COUNT=0
	assert_exit 1 "$sb" "multiple broken links must fail"
	assert_json 'map(.line_num) == [1,1]' "$sb" "both links on line 1"
	ok "multiple links per line, same line number"
}
t

test_case "timeout and user-agent forwarded to curl"
t() {
	local sb
	sb="$(gen_sb ua)"
	gen_md "$sb/README.md" '[x](https://ok.example/x)\n'
	run_check "$sb" INPUT_TIMEOUT=7 INPUT_USER_AGENT="TestAgent/9.9" INPUT_RETRY_COUNT=0
	assert_exit 0 "$sb" "must pass"
	assert_arg "--connect-timeout" "$sb" "connect timeout flag"
	assert_arg "7" "$sb" "timeout value 7"
	assert_arg "--max-time" "$sb" "max time flag"
	assert_arg "14" "$sb" "2x timeout max-time"
	assert_arg "TestAgent/9.9" "$sb" "user agent"
	assert_arg "--proto" "$sb" "scheme guard flag"
	ok "curl flags verified"
}
t

# ---------------------------------------------------------------- summary

echo
echo "========== Results: $PASS passed, $FAIL failed =========="
if [ "$FAIL" -gt 0 ]; then
	printf 'Failed cases:\n'
	for f in "${FAILED[@]}"; do echo "  - $f"; done
	echo "Temp dir kept at: $TMP"
	exit 1
fi
rm -rf "$TMP"
exit 0
