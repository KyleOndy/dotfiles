#!/usr/bin/env bash
# Smart linting hook for Claude Code
# Runs appropriate linters based on file types modified

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log function
log() {
	echo -e "${BLUE}[smart-lint]${NC} $1" >&2
}

error() {
	echo -e "${RED}[smart-lint ERROR]${NC} $1" >&2
}

success() {
	echo -e "${GREEN}[smart-lint]${NC} $1" >&2
}

warn() {
	echo -e "${YELLOW}[smart-lint WARN]${NC} $1" >&2
}

# Check if we're in a git repository
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	log "Not in a git repository, skipping linting"
	exit 0
fi

# Get list of modified files (excluding deleted files)
MODIFIED_FILES=$(git diff --name-only --diff-filter=d HEAD~1 HEAD 2>/dev/null || git ls-files --modified --others --exclude-standard)

if [[ -z $MODIFIED_FILES ]]; then
	log "No modified files detected"
	exit 0
fi

# Filter out files that don't exist (safety check for edge cases)
EXISTING_FILES=""
while IFS= read -r file; do
	if [[ -f $file ]]; then
		EXISTING_FILES="${EXISTING_FILES}${file}"$'\n'
	fi
done <<<"$MODIFIED_FILES"
MODIFIED_FILES="${EXISTING_FILES%$'\n'}"

if [[ -z $MODIFIED_FILES ]]; then
	log "No existing modified files to lint"
	exit 0
fi

log "Running smart linting on modified files..."

# Track if any linting failed
LINT_FAILED=0

# Python files
PYTHON_FILES=$(echo "$MODIFIED_FILES" | grep -E '\.(py)$' || true)
if [[ -n $PYTHON_FILES ]]; then
	log "Linting Python files..."

	# Run ruff if available
	if command -v ruff >/dev/null 2>&1; then
		if echo "$PYTHON_FILES" | tr '\n' '\0' | xargs -0 ruff check --quiet; then
			success "Python: ruff passed"
		else
			error "Python: ruff failed"
			LINT_FAILED=1
		fi

		# Run ruff format check
		if echo "$PYTHON_FILES" | tr '\n' '\0' | xargs -0 ruff format --check --quiet; then
			success "Python: ruff format passed"
		else
			error "Python: ruff format failed"
			LINT_FAILED=1
		fi
	else
		warn "ruff not found, skipping Python linting"
	fi
fi

# Go files
GO_FILES=$(echo "$MODIFIED_FILES" | grep -E '\.(go)$' || true)
if [[ -n $GO_FILES ]]; then
	log "Linting Go files..."

	# Run gofmt
	if command -v gofmt >/dev/null 2>&1; then
		UNFORMATTED=$(echo "$GO_FILES" | tr '\n' '\0' | xargs -0 gofmt -l)
		if [[ -z $UNFORMATTED ]]; then
			success "Go: gofmt passed"
		else
			error "Go: gofmt failed - unformatted files: $UNFORMATTED"
			LINT_FAILED=1
		fi
	fi

	# Run go vet if we're in a go module
	if [[ -f "go.mod" ]] && command -v go >/dev/null 2>&1; then
		if go vet ./...; then
			success "Go: go vet passed"
		else
			error "Go: go vet failed"
			LINT_FAILED=1
		fi
	fi
fi

# Clojure files with configurable formatting
CLOJURE_FILES=$(echo "$MODIFIED_FILES" | grep -E '\.(clj|cljs|cljc|edn)$' || true)
if [[ -n $CLOJURE_FILES ]]; then
	log "Linting Clojure files..."

	# Run clj-kondo if available
	if command -v clj-kondo >/dev/null 2>&1; then
		if echo "$CLOJURE_FILES" | tr '\n' '\0' | xargs -0 clj-kondo --lint; then
			success "Clojure: clj-kondo passed"
		else
			error "Clojure: clj-kondo failed"
			LINT_FAILED=1
		fi
	else
		warn "clj-kondo not found, skipping Clojure linting"
	fi

	# Clojure formatting (opt-in via environment variable)
	# This gets set by the Nix module based on clojureFormatting.enable
	if [[ ${CLAUDE_CLOJURE_FORMATTING:-false} == "true" ]]; then
		FORMATTER="${CLAUDE_CLOJURE_FORMATTER:-cljstyle}"
		log "Running Clojure formatting with $FORMATTER..."

		case "$FORMATTER" in
		"cljstyle")
			if command -v cljstyle >/dev/null 2>&1; then
				if echo "$CLOJURE_FILES" | tr '\n' '\0' | xargs -0 cljstyle check; then
					success "Clojure: cljstyle formatting passed"
				else
					error "Clojure: cljstyle formatting failed"
					LINT_FAILED=1
				fi
			else
				warn "cljstyle not found, skipping Clojure formatting"
			fi
			;;
		"zprint")
			if command -v zprint >/dev/null 2>&1; then
				# Check if files would be reformatted
				if echo "$CLOJURE_FILES" | tr '\n' '\0' | xargs -0 -I {} sh -c 'diff -q "{}" <(zprint < "{}")' >/dev/null 2>&1; then
					success "Clojure: zprint formatting passed"
				else
					error "Clojure: zprint formatting failed"
					LINT_FAILED=1
				fi
			else
				warn "zprint not found, skipping Clojure formatting"
			fi
			;;
		"cljfmt")
			if command -v cljfmt >/dev/null 2>&1; then
				if echo "$CLOJURE_FILES" | tr '\n' '\0' | xargs -0 cljfmt --dry-run; then
					success "Clojure: cljfmt formatting passed"
				else
					error "Clojure: cljfmt formatting failed"
					LINT_FAILED=1
				fi
			else
				warn "cljfmt not found, skipping Clojure formatting"
			fi
			;;
		esac
	fi
fi

# Nix files
NIX_FILES=$(echo "$MODIFIED_FILES" | grep -E '\.(nix)$' || true)
if [[ -n $NIX_FILES ]]; then
	log "Linting Nix files..."

	# Run nixfmt
	if command -v nixfmt >/dev/null 2>&1; then
		if echo "$NIX_FILES" | tr '\n' '\0' | xargs -0 nixfmt --check; then
			success "Nix: nixfmt passed"
		else
			error "Nix: nixfmt failed"
			LINT_FAILED=1
		fi
	else
		warn "nixfmt not found, skipping Nix formatting check"
	fi

	# Run nix-instantiate to check syntax
	while IFS= read -r file; do
		if nix-instantiate --parse "$file" >/dev/null 2>&1; then
			success "Nix: $file syntax valid"
		else
			error "Nix: $file has syntax errors"
			LINT_FAILED=1
		fi
	done <<<"$NIX_FILES"
fi

# Haskell files
HASKELL_FILES=$(echo "$MODIFIED_FILES" | grep -E '\.(hs|lhs)$' || true)
if [[ -n $HASKELL_FILES ]]; then
	log "Linting Haskell files..."

	# Run hlint if available
	if command -v hlint >/dev/null 2>&1; then
		if echo "$HASKELL_FILES" | tr '\n' '\0' | xargs -0 hlint; then
			success "Haskell: hlint passed"
		else
			error "Haskell: hlint failed"
			LINT_FAILED=1
		fi
	else
		warn "hlint not found, skipping Haskell linting"
	fi
fi

# Shell scripts
SHELL_FILES=$(echo "$MODIFIED_FILES" | grep -E '\.(sh|bash)$' || true)
if [[ -n $SHELL_FILES ]]; then
	log "Linting shell files..."

	# Run shellcheck
	if command -v shellcheck >/dev/null 2>&1; then
		if echo "$SHELL_FILES" | tr '\n' '\0' | xargs -0 shellcheck; then
			success "Shell: shellcheck passed"
		else
			error "Shell: shellcheck failed"
			LINT_FAILED=1
		fi
	else
		warn "shellcheck not found, skipping shell linting"
	fi

	# Run shfmt
	if command -v shfmt >/dev/null 2>&1; then
		if echo "$SHELL_FILES" | tr '\n' '\0' | xargs -0 shfmt -d -i 2 -ci -bn -s; then
			success "Shell: shfmt passed"
		else
			error "Shell: shfmt failed"
			LINT_FAILED=1
		fi
	else
		warn "shfmt not found, skipping shell formatting check"
	fi
fi

# JavaScript/TypeScript files
JS_FILES=$(echo "$MODIFIED_FILES" | grep -E '\.(js|ts|jsx|tsx)$' || true)
if [[ -n $JS_FILES ]]; then
	log "Linting JavaScript/TypeScript files..."

	# Run prettier check if available
	if command -v prettier >/dev/null 2>&1; then
		if echo "$JS_FILES" | tr '\n' '\0' | xargs -0 prettier --check; then
			success "JS/TS: prettier passed"
		else
			error "JS/TS: prettier failed"
			LINT_FAILED=1
		fi
	else
		warn "prettier not found, skipping JS/TS formatting check"
	fi
fi

# SQL files
SQL_FILES=$(echo "$MODIFIED_FILES" | grep -E '\.(sql)$' || true)
if [[ -n $SQL_FILES ]]; then
	log "Linting SQL files..."

	if command -v sqlfluff >/dev/null 2>&1; then
		# Check if .sqlfluff configuration exists
		if [[ -f ".sqlfluff" ]]; then
			# Run sqlfluff lint and capture output
			if echo "$SQL_FILES" | tr '\n' '\0' | xargs -0 sqlfluff lint >/dev/null 2>&1; then
				success "SQL: sqlfluff passed"
			else
				error "SQL: sqlfluff failed (run 'sqlfluff lint' for details)"
				LINT_FAILED=1
			fi
		else
			warn "SQL: .sqlfluff config file not found, skipping SQL linting"
			warn "SQL: Create .sqlfluff with:"
			warn "SQL:   [sqlfluff]"
			warn "SQL:   dialect = postgres"
			warn "SQL: Common dialects: postgres, mysql, sqlite, bigquery, snowflake"
		fi
	else
		warn "sqlfluff not found, skipping SQL linting"
	fi
fi

# Terraform files
TF_FILES=$(echo "$MODIFIED_FILES" | grep -E '\.(tf|tfvars)$' || true)
if [[ -n $TF_FILES ]]; then
	log "Linting Terraform files..."

	# Run terraform fmt check
	if command -v terraform >/dev/null 2>&1; then
		if terraform fmt -check -diff; then
			success "Terraform: fmt passed"
		else
			error "Terraform: fmt failed"
			LINT_FAILED=1
		fi
	else
		warn "terraform not found, skipping Terraform formatting check"
	fi
fi

# Markdown files
MARKDOWN_FILES=$(echo "$MODIFIED_FILES" | grep -E '\.(md|markdown)$' || true)
if [[ -n $MARKDOWN_FILES ]]; then
	log "Linting Markdown files..."

	if command -v markdownlint-cli2 >/dev/null 2>&1; then
		# Check if configuration file exists
		if [[ -f ".markdownlint.json" ]] || [[ -f ".markdownlint-cli2.jsonc" ]] || [[ -f ".markdownlint.jsonc" ]] || [[ -f ".markdownlint.yaml" ]] || [[ -f ".markdownlint.yml" ]]; then
			if echo "$MARKDOWN_FILES" | tr '\n' '\0' | xargs -0 markdownlint-cli2 --fix; then
				success "Markdown: markdownlint-cli2 passed"
			else
				error "Markdown: markdownlint-cli2 failed"
				LINT_FAILED=1
			fi
		else
			# Run with default configuration but warn about missing config
			if echo "$MARKDOWN_FILES" | tr '\n' '\0' | xargs -0 markdownlint-cli2; then
				success "Markdown: markdownlint-cli2 passed (using defaults)"
				warn "Markdown: Consider creating .markdownlint.json for custom rules"
			else
				error "Markdown: markdownlint-cli2 failed"
				LINT_FAILED=1
			fi
		fi
	else
		warn "markdownlint-cli2 not found, skipping Markdown linting"
	fi
fi

# Exit with appropriate code
if [[ $LINT_FAILED -eq 1 ]]; then
	error "Some lint checks failed"
	exit 2
else
	success "All lint checks passed"
	exit 0
fi
