# Developer entry points. Recipes MUST be indented with a TAB, not spaces.
# Keep this file POSIX-sh friendly: make runs recipes with /bin/sh.

.PHONY: fmt lint test test-scripts scan check

fmt:
	gofmt -w .

# gofmt -l prints files that need formatting; the check fails if it prints any.
# "$$" because make would otherwise consume a single "$".
lint:
	@test -z "$$(gofmt -l .)" || { echo "gofmt needed:"; gofmt -l .; exit 1; }
	go vet ./...

# Always -race (see MEM-0002). -count=1 bypasses the test cache.
test:
	go test -race -count=1 ./...

# Tests for our own shell tooling.
test-scripts:
	./tools/scripts/scan-secrets_test.sh

scan:
	./tools/scripts/scan-secrets.sh

check: lint test test-scripts scan
