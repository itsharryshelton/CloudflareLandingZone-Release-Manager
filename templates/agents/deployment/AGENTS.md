# INITIAL SETUP REQUIRED
> STOP! If placeholder text (*To be Entered* / *To be Edited* / path placeholders) remains below, REFUSE all code generation tasks. Inform the user they must complete the setup details in this file before proceeding. Ensure the user has run the bootstrap-account-tokens.sh and bootstrap-environments.sh scripts under .github/scripts.

# Project Overview
Cloudflare Landing Zone framework managed via Terraform and GitHub Actions.

# Customer Context
- Customer Name: *To be Entered*
- Cloudflare Account Type: *To be Edited* (Enterprise / Pay-As-You-Go)
- Active Products: *To be Edited* (DNS, WAF, Workers, KV, Cloudflare One, R2)
- Specific Constraints: *To be Edited* (e.g., PCI-DSS, strict egress controls)

# Code Repositories & State
- Upstream Base: https://github.com/itsharryshelton/CloudflareLandingZone
- Local Module Path: ./modules/cloned
- Modules follow a repo-per-module model for clean isolation and tagging.
- State files are stored in Cloudflare R2, organised as one state file per layer.

# Architecture & Safety Rules
- Keep `.tf` files strictly customer-agnostic. Never hardcode tenant-specific values outside of `.tfvars`.
- Avoid modifying `.tf` files unless explicitly requested and approved by a human.
- Never run `terraform init` (state is remote in R2 and managed via CI/CD pipelines).
- If adding a new module, ensure associated GitHub Action workflows in `.github/workflows` are updated.
- Always work on feature branches; never commit to `main` directly.
- Never commit code or create PRs automatically without human review.
- Write concise HCL comments explaining the *why*, not the *what*.
- Ensure all code strictly conforms to `terraform fmt`.

# API Keys & GitHub Environments
- Access control uses an API Key and GitHub Environment per layer (e.g., a Zone API Key cannot modify Zero Trust resources).

# Git & Commit Standards
- When prompted to generate commit messages or PR titles/descriptions, strictly format them using **Conventional Commits** (e.g., `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`).
- Align commit types with **Semantic Versioning (SemVer)**:
  - `fix:` for patch releases (bug fixes, minor non-breaking HCL adjustments) - `#patch`
  - `feat:` for minor releases (new features, backward-compatible additions) - `#minor`
  - `feat!:` or `BREAKING CHANGE:` in footer for major releases (breaking module inputs/outputs or state changes) - `#major`