# todo.md - active sprint backlog

## Phase 0: environment and skeleton (branch: phase/0-setup)
- [x] 0.0 Environment check (Go 1.24.13, git, Xcode, Docker optional)
- [x] 0.1 Race detector experiment (Mutex, mutation check)
- [x] 0.2 Repository skeleton, .gitignore, .env.example, first commit
- [x] 0.3 Makefile, scan-secrets.sh and its tests, MEM-0001..0003, doc.go per layer
      (make check verified on macOS 11.7.11 / bash 3.2 / BSD grep)
- [x] 0.3d README.md merged with the full plan
- [ ] 0.4 Clean CLAUDE.md (adapted spec)
- [ ] 0.5 GitHub Actions CI (race tests, gitleaks, govulncheck)

## Backlog
- [ ] Phase 1: check-coverage.sh (80 percent gate on domain and application)
