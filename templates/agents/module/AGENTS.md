# Project Overview
Cloudflare Landing Zone framework managed via Terraform and GitHub Actions.
This repo is a supporting Terraform Modules.

# Customer Context
- This Repo is completely customer agnostic - all customer information and terraform layeres are stored within the Management Repo.

# Code Repositories & State
- Upstream Base: https://github.com/itsharryshelton/CloudflareLandingZone
- Modules follow a repo-per-module model for clean isolation and tagging.

# Architecture & Safety Rules
- Keep `.tf` files strictly customer-agnostic. Never hardcode tenant-specific.
- Never run `terraform init` (state is remote in R2 and managed via CI/CD pipelines). If you have to to validate something, create a copy and run locally; never run it on the main Repo.
- Always work on feature branches; never commit to `main` directly.
- Never commit code or create PRs automatically without human review.
- Write concise HCL comments explaining the *why*, not the *what*.
- Ensure all code strictly conforms to `terraform fmt`.

# Git & Commit Standards
- When prompted to generate commit messages or PR titles/descriptions, strictly format them using **Conventional Commits** (e.g., `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`).
- Align commit types with **Semantic Versioning (SemVer)**:
  - `fix:` for patch releases (bug fixes, minor non-breaking HCL adjustments) - `#patch`
  - `feat:` for minor releases (new features, backward-compatible additions) - `#minor`
  - `feat!:` or `BREAKING CHANGE:` in footer for major releases (breaking module inputs/outputs or state changes) - `#major`