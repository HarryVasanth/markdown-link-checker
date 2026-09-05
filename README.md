# Markdown Link Checker

This GitHub action checks all hyperlinks in Markdown files for broken links and reports their status. It's designed to be lightweight, fast, and compatible across different environments.

## Features

- **URL Caching**: Identical external links shared across files are only pinged once.
- **Evades 403 Blocks**: Uses a modern User-Agent default so stringent sites don't block the request.
- **Retries**: Failed requests are retried (configurable count) before being reported as broken.
- **Rich link detection**: Extract links from standard `[text](url)` forms, link titles, reference-style links `[text][id]`, autolinks `<https://...>`, images `![alt](url)`, and HTML `<a href>` / `<img src>` tags.
- **Fenced code ignored**: Links inside ` ``` ` code blocks are skipped so tooling snippets and examples don't produce false positives.
- **Fragment validation**: Heading anchors are checked against the real heading structure, with GitHub-compatible slugs (lowercase, punctuation stripped, `-` for spaces) and `-1`/`-2` deduplication suffixes for repeated headings. Unicode headings are supported.
- **File reference validation**: Internal `./relative`, `../relative`, and `/absolute` file links are checked against the filesystem.
- **Scheme awareness**: `mailto:`, `tel:`, `ftp:`, `data:`, `javascript:`, and other non-HTTP schemes are treated as valid and never fetched.
- **Configuration**: All options can be set via workflow inputs or a configuration file.
- **Human + machine output**: Colored console output plus a machine-readable JSON list of broken links written to `$GITHUB_OUTPUT`.
- **Deterministic**: Results are deduplicated and sorted for stable output.

## Usage

### Basic Usage

```yml
name: Check Markdown links

on:
  push:
    branches: [main]

  pull_request:
    branches: [main]

  schedule:
    # Run weekly on Sundays
    - cron: "0 0 * * 0"

jobs:
  check-links:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4
      - name: Check Markdown Links
        uses: harryvasanth/markdown-link-checker@v1
```

### Advanced Usage

```yml
name: Check Markdown links

on:
  push:
    branches: [main]

jobs:
  check-links:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check Markdown Links
        uses: harryvasanth/markdown-link-checker@v1
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

You can also use commas, or mix commas and spaces, for `files` and `exclude`:

```yml
with:
  files: "README.md,CONTRIBUTING.md"
  exclude: "node_modules,vendor"
```

or even

```yml
with:
  files: "README.md, CONTRIBUTING.md docs/guide.md"
  exclude: "node_modules, vendor dist"
```

## Inputs

| Input         | Description                                                            | Required | Default           |
| ------------- | ---------------------------------------------------------------------- | -------- | ----------------- |
| `path`        | Path to check for markdown files                                       | No       | `.`               |
| `files`       | Specific files to check (`.md`/`.markdown`, comma, space, or both)     | No       |                   |
| `exclude`     | Files or directories to exclude (comma, space, or both as separators)  | No       |                   |
| `recursive`   | Check files recursively                                                | No       | `true`            |
| `timeout`     | Timeout for HTTP requests in seconds (connect + max)                   | No       | `10`              |
| `retry-count` | Number of retries for failed requests                                  | No       | `3`               |
| `verbose`     | Show detailed output                                                   | No       | `false`           |
| `config-file` | Path to configuration file (overrides workflow inputs)                 | No       |                   |
| `ignore-urls` | Comma-separated list of URL substrings to skip (e.g. `localhost`)      | No       |                   |
| `user-agent`  | Custom User-Agent to prevent 403 Forbidden drops from strict firewalls | No       | Chrome User-Agent |

## Outputs

| Output | Description                                                                                                                                                     | Required | Default |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ------- |
| `json` | JSON output of broken links. Example: `[{"link":"https://example.com/broken.html","file":"README.md","line_num":5,"status":"404"}]`. Empty list if none broken. | No       | `.`     |

## Configuration File

You can use a configuration file to set options for the link checker. Create a file (e.g., `.linkcheck.conf`) with the following format:

```conf
# Link Checker Configuration
PATH_TO_CHECK="docs"
EXCLUDE="node_modules vendor"
IGNORE_URLS="localhost,mysite.local"
TIMEOUT=15
RETRY_COUNT=3
VERBOSE=true
USER_AGENT="MyCustomAgent/1.0"
```

Values from the config file take precedence over workflow inputs. Unknown keys are reported as warnings so typos are easy to spot.

Then reference it in your workflow:

```yml
- name: Check Markdown Links
  uses: harryvasanth/markdown-link-checker@v1
  with:
    config-file: ".linkcheck.conf"
```

## Output

The action reports each file it checks and any broken links it finds, then prints a summary and exits non-zero if any links were broken:

```console
=== Markdown Link Checker ===
Starting link check process...
Checking links in README.md
Found 15 links in README.md
Checking links in docs/guide.md
x docs/guide.md:25 - Broken link: https://example.com/broken-link (Status: 404)
x docs/guide.md:42 - Broken link: ./non-existent-file.md (File not found: ./docs/non-existent-file.md)
Found 10 links in docs/guide.md
=== Link Check Summary ===
Files checked: 2
Total links: 25
Found 2 broken links!
```

## Exit Codes

| Code | Meaning                           |
| ---- | --------------------------------- |
| `0`  | All links are valid               |
| `1`  | One or more broken links found    |
| `2`  | Bash < 4 (drop-in action support) |

## Testing

The project ships an offline test suite (`test/run-tests.sh`) that runs the checker against a fake `curl`, so it needs no network:

```sh
bash test/run-tests.sh
```

Run it locally on Linux, macOS (`bash` ≥ 4, e.g. via Homebrew) or in the container - every test uses sandboxed temp dirs and canned HTTP responses (`200`, `404`, `500`, timeouts, flaky servers), verifying link extraction, fragments, caching, retries, ignore rules, config files, JSON output, and edge cases.
