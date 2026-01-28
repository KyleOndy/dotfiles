#!/usr/bin/env bash
# Smart testing hook for Claude Code
# Intelligently detects and runs appropriate test suites

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log function
log() {
	echo -e "${BLUE}[smart-test]${NC} $1" >&2
}

error() {
	echo -e "${RED}[smart-test ERROR]${NC} $1" >&2
}

success() {
	echo -e "${GREEN}[smart-test]${NC} $1" >&2
}

warn() {
	echo -e "${YELLOW}[smart-test WARN]${NC} $1" >&2
}

# Check if we're in a git repository
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	log "Not in a git repository, skipping testing"
	exit 0
fi

# Get project root
PROJECT_ROOT=$(git rev-parse --show-toplevel)
cd "$PROJECT_ROOT"

log "Running intelligent test detection and execution..."

# Track test results
TESTS_RUN=0
TESTS_FAILED=0

# Python testing
if [ -f "pyproject.toml" ] || [ -f "setup.py" ] || [ -f "requirements.txt" ] || [ -f "Pipfile" ]; then
	log "Python project detected"

	# Look for pytest
	if command -v pytest >/dev/null 2>&1 && ([ -f "pytest.ini" ] || [ -f "pyproject.toml" ] || find . -name "test_*.py" -o -name "*_test.py" | head -1 | grep -q .); then
		log "Running pytest..."
		if pytest --tb=short; then
			success "Python: pytest passed"
		else
			error "Python: pytest failed"
			TESTS_FAILED=$((TESTS_FAILED + 1))
		fi
		TESTS_RUN=$((TESTS_RUN + 1))
	# Look for unittest
	elif python -c "import unittest; unittest.main(module=None, exit=False)" >/dev/null 2>&1; then
		log "Running Python unittest..."
		if python -m unittest discover; then
			success "Python: unittest passed"
		else
			error "Python: unittest failed"
			TESTS_FAILED=$((TESTS_FAILED + 1))
		fi
		TESTS_RUN=$((TESTS_RUN + 1))
	else
		warn "Python project detected but no test framework found"
	fi
fi

# Go testing
if [ -f "go.mod" ]; then
	log "Go project detected"

	if command -v go >/dev/null 2>&1; then
		# Check if there are any test files
		if find . -name "*_test.go" | head -1 | grep -q .; then
			log "Running go test..."
			if go test ./...; then
				success "Go: tests passed"
			else
				error "Go: tests failed"
				TESTS_FAILED=$((TESTS_FAILED + 1))
			fi
			TESTS_RUN=$((TESTS_RUN + 1))
		else
			warn "Go project detected but no test files found"
		fi
	else
		warn "Go project detected but go command not available"
	fi
fi

# Clojure testing
if [ -f "project.clj" ] || [ -f "deps.edn" ] || [ -f "shadow-cljs.edn" ]; then
	log "Clojure project detected"

	# Leiningen project
	if [ -f "project.clj" ] && command -v lein >/dev/null 2>&1; then
		log "Running lein test..."
		if lein test; then
			success "Clojure: lein test passed"
		else
			error "Clojure: lein test failed"
			TESTS_FAILED=$((TESTS_FAILED + 1))
		fi
		TESTS_RUN=$((TESTS_RUN + 1))
	# Clojure CLI project
	elif [ -f "deps.edn" ] && command -v clojure >/dev/null 2>&1; then
		# Look for common test aliases
		if grep -q ":test" deps.edn; then
			log "Running clojure -M:test..."
			if clojure -M:test; then
				success "Clojure: tests passed"
			else
				error "Clojure: tests failed"
				TESTS_FAILED=$((TESTS_FAILED + 1))
			fi
			TESTS_RUN=$((TESTS_RUN + 1))
		elif find . -path "*/test/*" -name "*.clj" | head -1 | grep -q .; then
			# Try to run with cognitect test runner
			log "Running clojure test runner..."
			if clojure -X:test 2>/dev/null || clojure -M -e "(require 'clojure.test) (clojure.test/run-all-tests)"; then
				success "Clojure: tests passed"
			else
				error "Clojure: tests failed"
				TESTS_FAILED=$((TESTS_FAILED + 1))
			fi
			TESTS_RUN=$((TESTS_RUN + 1))
		else
			warn "Clojure project detected but no test configuration found"
		fi
	else
		warn "Clojure project detected but no test runner available"
	fi
fi

# Haskell testing
if [ -f "*.cabal" ] || [ -f "stack.yaml" ] || [ -f "cabal.project" ]; then
	log "Haskell project detected"

	# Stack project
	if [ -f "stack.yaml" ] && command -v stack >/dev/null 2>&1; then
		log "Running stack test..."
		if stack test; then
			success "Haskell: stack test passed"
		else
			error "Haskell: stack test failed"
			TESTS_FAILED=$((TESTS_FAILED + 1))
		fi
		TESTS_RUN=$((TESTS_RUN + 1))
	# Cabal project
	elif command -v cabal >/dev/null 2>&1; then
		log "Running cabal test..."
		if cabal test; then
			success "Haskell: cabal test passed"
		else
			error "Haskell: cabal test failed"
			TESTS_FAILED=$((TESTS_FAILED + 1))
		fi
		TESTS_RUN=$((TESTS_RUN + 1))
	else
		warn "Haskell project detected but no build tool available"
	fi
fi

# Node.js testing
if [ -f "package.json" ]; then
	log "Node.js project detected"

	# Check for test script in package.json
	if command -v npm >/dev/null 2>&1 && npm run | grep -q "test"; then
		log "Running npm test..."
		if npm test; then
			success "Node.js: npm test passed"
		else
			error "Node.js: npm test failed"
			TESTS_FAILED=$((TESTS_FAILED + 1))
		fi
		TESTS_RUN=$((TESTS_RUN + 1))
	# Try yarn if available
	elif command -v yarn >/dev/null 2>&1 && yarn run | grep -q "test"; then
		log "Running yarn test..."
		if yarn test; then
			success "Node.js: yarn test passed"
		else
			error "Node.js: yarn test failed"
			TESTS_FAILED=$((TESTS_FAILED + 1))
		fi
		TESTS_RUN=$((TESTS_RUN + 1))
	else
		warn "Node.js project detected but no test script found"
	fi
fi

# Rust testing
if [ -f "Cargo.toml" ]; then
	log "Rust project detected"

	if command -v cargo >/dev/null 2>&1; then
		log "Running cargo test..."
		if cargo test; then
			success "Rust: cargo test passed"
		else
			error "Rust: cargo test failed"
			TESTS_FAILED=$((TESTS_FAILED + 1))
		fi
		TESTS_RUN=$((TESTS_RUN + 1))
	else
		warn "Rust project detected but cargo not available"
	fi
fi

# Makefile-based testing
if [ -f "Makefile" ] && grep -q "^test:" Makefile; then
	log "Makefile with test target detected"

	if command -v make >/dev/null 2>&1; then
		log "Running make test..."
		if make test; then
			success "Make: test target passed"
		else
			error "Make: test target failed"
			TESTS_FAILED=$((TESTS_FAILED + 1))
		fi
		TESTS_RUN=$((TESTS_RUN + 1))
	fi
fi

# Nix-based testing (flake check)
if [ -f "flake.nix" ]; then
	# Check if nix tests should be skipped
	if [[ ${CLAUDE_SKIP_NIX_TESTS:-false} == "true" ]]; then
		warn "Nix: flake check skipped (CLAUDE_SKIP_NIX_TESTS=true)"
	else
		log "Nix flake detected"

		if command -v nix >/dev/null 2>&1; then
			log "Running nix flake check..."
			if nix flake check; then
				success "Nix: flake check passed"
			else
				error "Nix: flake check failed"
				TESTS_FAILED=$((TESTS_FAILED + 1))
			fi
			TESTS_RUN=$((TESTS_RUN + 1))
		fi
	fi
fi

# Summary
log "Test execution summary:"
log "  Tests run: $TESTS_RUN"
log "  Tests failed: $TESTS_FAILED"

if [ $TESTS_RUN -eq 0 ]; then
	warn "No test suites detected or runnable"
	exit 0
elif [ $TESTS_FAILED -eq 0 ]; then
	success "All test suites passed!"
	exit 0
else
	error "$TESTS_FAILED out of $TESTS_RUN test suites failed"
	exit 2
fi
