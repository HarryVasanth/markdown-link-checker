# 🔗 Markdown Link Checker

A fast, dependency-light GitHub Action that finds broken links in Markdown files:
external URLs, internal file references and heading anchors. No Node, no `npm
install` — one bash script, a tiny Alpine image and a JSON report.

## ✨ Features

- ⚡️ **Fast and cached.** Identical external URLs are fetched once, even across files.
- 🕵️ **Real link detection.** `[text](url)` with titles, `![image](url)`,
  reference links `[text][id]` / `[id]` / `![id]`, autolinks `<https://…>`, badge wrappers
  `[![alt](img)](target)` and HTML `<a href>` / `<img src>` (quoted or bare).
- 🧠 **Knows what is code.** Fenced blocks (matching fence character and
  length), inline code spans and HTML comments (single- and multi-line) are
  ignored.
- 🙈 **Ignore rules.** `ignore-urls` accepts substrings (`localhost`) or globs
  (`https://*.example.com/*`) so noisy hosts are skipped without fetching.
- 🎯 **Fragment validation.** GitHub-compatible slugs from ATX and setext
  headings, closing `#` sequences, Unicode, inline formatting, explicit HTML
  `id`/`name` anchors, `#top`, and `-1`/`-2` deduplication for repeated
  headings.
- 📁 **File references.** `./relative`, `../relative` and `/absolute` links are
  checked against the filesystem. Query strings are ignored for file lookup.
- 🔤 **Encoding aware.** `%20` paths and fragments and `&amp;` entities are
  decoded before checking. `HTTPS://…` and `//host/path` count as external.
- 🛡️ **Scheme aware.** `mailto:`, `tel:`, `ftp:`, `data:`, `javascript:` and
  other non-HTTP schemes are valid and never fetched.
- 🔁 **Smart retries.** Only transient answers (`000`, `408`, `425`, `429`,
  `5xx`) are retried; a `404` fails immediately.
- 📊 **Human + machine output.** Emoji console output, inline PR annotations,
  a Markdown step summary, count outputs and a machine-readable JSON list.
  Runs print their duration, and `quiet: "true"` keeps only failures.
- 🖥️ **Action and CLI.** Same script works as a GitHub Action, in Docker, or
  standalone with `--help`, flags and positional files.
- 🤖 **Agent-friendly.** Stable exit codes and actionable errors for bad paths,
  missing tools and invalid configuration.
- 🪶 **Portable.** Linux, macOS and Windows (Git Bash) with bash ≥ 4.
- 🧪 **Offline tests.** 55 black-box cases against a fake `curl`, no network.

## 🚀 Usage

### Basic

```yml
name: Check Markdown links

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  schedule:
    - cron: "0 0 * * 0" # weekly

jobs:
  check-links:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7.0.1
      - name: Check Markdown Links
        uses: harryvasanth/markdown-link-checker@v1.5
```

### Advanced

```yml
name: Check Markdown links

on:
  push:
    branches: [main]

jobs:
  check-links:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7.0.1
      - name: Check Markdown Links
        uses: harryvasanth/markdown-link-checker@v1.5
        with:
          path: "docs"
          files: "README.md CONTRIBUTING.md"
          exclude: "node_modules vendor"
          ignore-urls: "localhost,127.0.0.1,example.com"
          recursive: "true"
          timeout: "15"
          retry-count: "3"
          verbose: "true"
          user-agent: "MyCustomAgent/1.0"
```

`files` and `exclude` accept commas, spaces, or both:

```yml
with:
  files: "README.md, CONTRIBUTING.md docs/guide.md"
  exclude: "node_modules, vendor dist"
```

When `path` is set and a `files` entry is not found from the working
directory, it is resolved inside `path` (`docs` + `README.md` →
`docs/README.md`). Entries may also be newline separated.

### Standalone CLI

```sh
./check-links.sh --help
./check-links.sh README.md docs/guide.md
./check-links.sh --path docs --retry-count 0 --quiet
./check-links.sh --ignore-urls "localhost,https://*.example.com/*" --verbose
```

Every action input has a matching flag (`--path`, `--files`, `--exclude`,
`--ignore-urls`, `--timeout`, `--retry-count`, `--config-file`,
`--user-agent`, `--verbose`, `--quiet`, `--recursive`, `--no-recursive`).
Flags override
`INPUT_*` environment variables; a config file still wins. Colors turn off
automatically for non-terminals, `NO_COLOR` and `TERM=dumb`.

## 📥 Inputs

| Input         | Description                                                              | Default           |
| ------------- | ------------------------------------------------------------------------ | ----------------- |
| `path`        | 📁 Path to scan for `*.md` / `*.markdown`                                | `.`               |
| `files`       | 📄 Explicit files to check (comma/space separated)                       | all under `path`  |
| `exclude`     | 🚫 Path substrings to skip (comma/space separated)                       | none              |
| `recursive`   | 🔁 Scan subdirectories                                                   | `true`            |
| `timeout`     | ⏱️ Connect timeout in seconds; total time is capped at 2×                | `10`              |
| `retry-count` | 🔁 Max attempts per URL. `0`/`1` = one attempt; only transient errors retry | `3`           |
| `verbose`     | 🗣️ Print skipped and successful links                                    | `false`           |
| `quiet`       | 🔇 Only print broken links and the final summary                         | `false`           |
| `config-file` | ⚙️ Config file that overrides inputs (see below)                          | none              |
| `ignore-urls` | 🙈 Comma-separated URL substrings or globs to skip (e.g. `localhost`)  | none              |
| `user-agent`  | 🕵️ User-Agent header, to avoid 403 blocks                                | Chrome User-Agent |

If `path` does not exist the action fails with exit code `2` instead of
silently reporting success. A missing `config-file` only warns.

## 📤 Outputs

| Output          | Description                                                        |
| --------------- | ------------------------------------------------------------------ |
| `json`          | Broken links as JSON (empty array when everything passes)          |
| `broken_count`  | Number of broken link occurrences                                  |
| `checked_files` | Number of Markdown files scanned                                   |
| `total_links`   | Number of link occurrences scanned                                 |

```yml
- uses: harryvasanth/markdown-link-checker@v1.5
  id: links

- if: steps.links.outputs.broken_count != '0'
  run: echo '${{ steps.links.outputs.json }}'
```

Each broken link also gets an `::error file=…,line=…::` annotation, and the job
summary gets a table of broken links (up to 50 rows; the log lists all).

## ⚙️ Configuration file

```conf
# .linkcheck.conf
PATH_TO_CHECK="docs"
FILES="README.md docs/guide.md"
EXCLUDE="node_modules vendor"
RECURSIVE=true
TIMEOUT=15
RETRY_COUNT=3
VERBOSE=true
QUIET=false
IGNORE_URLS="localhost,mysite.local"
USER_AGENT="MyCustomAgent/1.0"
```

Values take precedence over workflow inputs. Unknown keys produce a warning so
typos are easy to spot. Values are never evaluated as shell code.

```yml
- uses: harryvasanth/markdown-link-checker@v1.5
  with:
    config-file: ".linkcheck.conf"
```

## 🖥️ Output

```console
🔗 Markdown Link Checker
🚀 Starting link check process...
📄 Checking links in ./README.md
❌ ./README.md:25 - Broken link: https://example.com/broken-link (Status: 404)
🔍 Found 15 links in ./README.md
📄 Checking links in ./docs/guide.md
❌ ./docs/guide.md:42 - Broken link: ./non-existent-file.md (File not found: ./docs/non-existent-file.md)
🔍 Found 10 links in ./docs/guide.md
📊 === Link Check Summary ===
📄 Files checked: 2
🔗 Total links: 25
⏱️  Duration: 3s
💥 Found 2 broken links!
```

Skipped links and successful checks appear only with `verbose: "true"`.
`quiet: "true"` hides progress lines but keeps failures and the summary. When
`GITHUB_OUTPUT` is not set (local run), outputs are printed as `key=value`
lines.

## 🚦 Exit codes

| Code | Meaning                                                                 |
| ---- | ----------------------------------------------------------------------- |
| `0`  | All links are valid                                                     |
| `1`  | One or more broken links found                                          |
| `2`  | Configuration or environment error (bash < 4, missing `perl`/`jq`/`curl`, missing path) |

## 🧪 Testing

The suite runs offline against a fake `curl` with canned HTTP responses
(`200`, `404`, `500`, timeouts, flaky servers):

```sh
bash test/run-tests.sh
```

It covers extraction, fragments, caching, retries, ignore rules, config files,
JSON/count outputs, annotations, summaries and the edge cases listed above.

## ⚠️ Limits

- 4-space indented code blocks are still scanned. Fenced blocks, inline code
  spans and HTML comments are masked.
- Links split across lines, and bare URLs in prose (not `<…>` or a Markdown
  link), are not detected.
- `files` is split on commas, newlines and whitespace, so a path containing
  spaces cannot be passed explicitly; scan its directory with `path` instead.
- Links inside footnote definitions (`[^1]: …`) are not checked; the footnote
  marker itself is not treated as a reference link.
- `max-time` is always `2 × timeout`; there is no separate dial for the total
  request time.
- GitHub shows at most 10 `::error::` annotations per step. Every broken link is
  still printed to the log and the step summary.

## 🔐 Security

- **No runtime downloads.** The action runs the script from its own image.
- **HTTP(S) only.** `curl --proto "=http,https"` blocks `file://` and other
  schemes even through redirects.
- **Untrusted text stays text.** URLs and paths are never evaluated. Workflow
  command data is escaped, and Markdown table cells are sanitized.
- **Pin a version.** Reference a release tag, not a branch.
