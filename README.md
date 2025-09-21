# Markdown Link Checker

This GitHub action checks all hyperlinks in Markdown files for broken links and reports their status. It's designed to be lightweight, fast, and compatible across different environments.

**Now updated with URL Caching and User-Agent spoofing to be vastly faster and avoid strict 403 blocks.**

## Features

- **Blazing Fast URL Caching**: Identical links shared across files are only pinged once.
- **Evades 403 Blocks**: Uses a modern User-Agent default so stringent sites (GitHub, Reddit, etc.) don't block the request.
- Checks external URLs and reports HTTP status codes
- Validates internal file links and fragment references
- Supports checking image links
- Recursive directory scanning
- Configurable timeout, retries, and ignore lists.
- Detailed JSON reporting of broken links

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
          user-agent: "MyCustomAgent/1.0"
```

## Inputs

| Input         | Description                                                            | Required | Default           |
| ------------- | ---------------------------------------------------------------------- | -------- | ----------------- |
| `path`        | Path to check for markdown files                                       | No       | `.`               |
| `files`       | Specific markdown files to check (comma, space, or both as separators) | No       |                   |
| `exclude`     | Files or directories to exclude (comma, space, or both as separators)  | No       |                   |
| `recursive`   | Check files recursively                                                | No       | `true`            |
| `timeout`     | Timeout for HTTP requests in seconds                                   | No       | `10`              |
| `retry-count` | Number of retries for failed requests                                  | No       | `3`               |
| `verbose`     | Show detailed output                                                   | No       | `false`           |
| `config-file` | Path to configuration file                                             | No       |                   |
| `ignore-urls` | Comma-separated list of domains/URLs to skip (e.g. `localhost`)        | No       |                   |
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
```

Then reference it in your workflow:

```yml
- name: Check Markdown Links
  uses: harryvasanth/markdown-link-checker@v1
  with:
    config-file: ".linkcheck.conf"
```

## Output

The action will output information about the links it checks and any broken links it finds:

```console
=== Markdown Link Checker ===
Starting link check process...
Checking links in README.md
Found 15 links in README.md
Checking links in docs/guide.md
✖ docs/guide.md:25 - Broken link: https://example.com/broken-link (Status: 404)
✖ docs/guide.md:42 - Broken link: ./non-existent-file.md (File not found: docs/non-existent-file.md)
Found 10 links in docs/guide.md
=== Link Check Summary ===
Files checked: 2
Total links: 25
✖ Found 2 broken links!
```
