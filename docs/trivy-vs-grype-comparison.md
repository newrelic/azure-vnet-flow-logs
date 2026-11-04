# Trivy vs Grype: Scan Comparison (Experiment)

## What we did

We scanned this repository with two security scanners, **Trivy** and **Grype**. Both look for known security problems (vulnerabilities) in the libraries this project uses. We wanted to see if they find the same things.

- Trivy version: 0.74.0
- Grype version: 0.121.1
- Scan date: 2026-11-03
- What was scanned: the repository folder, mainly `package-lock.json`
- Settings used for both: HIGH and CRITICAL problems only, and only problems that already have a fix

The GitHub workflow for this experiment is `.github/workflows/trivy-scan.yml`. It runs both scanners and sends the results to the GitHub Security tab. It is for comparison only and is not meant for `main`.

## Result in one line

**Both tools found the same 12 problems in the same 4 libraries.**

## What was found

| Library | Version we use | Problems | Fixed in |
|---|---|---|---|
| axios | 1.18.1 | 7 | 1.20.0 |
| follow-redirects | 1.16.0 | 3 | 1.16.1 or 1.16.2 |
| fast-xml-parser | 5.9.3 | 1 | 5.10.1 |
| @azure/msal-node | 5.3.1 | 1 | 7.1.0 |

There were no CRITICAL problems. All 12 are HIGH.

## Side-by-side

| | Trivy | Grype |
|---|---|---|
| HIGH/CRITICAL problems found | 12 | 12 |
| Same libraries and versions | Yes | Yes |
| Name style for a problem | CVE number (for example CVE-2026-101898) | GHSA number (for example GHSA-3pq3-5fj3-cg6v) |
| Dev-only libraries | Skipped by default | Reads the lock file as is (no difference seen in this repo) |
| Can also scan Docker images | Yes | Yes |
| Extra checks (secrets, config files) | Yes, built in | No, it focuses on vulnerabilities |

## New workflow vs the existing `trivy.yml`

We ran the same settings that each workflow uses and compared the result files (SARIF):

| Scan | Findings sent to Security tab |
|---|---|
| Existing `trivy.yml` (Trivy) | 12 |
| New `trivy-scan.yml` – Trivy job | 12 (the file is byte-for-byte identical to the existing one) |
| New `trivy-scan.yml` – Grype job | 17 (the same 12 HIGH, plus 5 MEDIUM axios) |

- The Trivy job in the new file gives exactly the same result as the existing scan. It adds nothing new.
- Grype's `severity-cutoff: high` setting only controls when the build fails. It does not hide MEDIUM findings from the report, so 5 extra MEDIUM alerts would appear.
- Triggers differ: the existing scan also runs on every push to `main` and every pull request. The new file runs on manual start, on pull requests that change `package*.json`, and daily.

## Things to know

1. **The names differ, but the problems are the same.** Trivy shows CVE numbers and Grype shows GHSA numbers. Do not compare by name. Compare by library, version and fixed version.
2. **Duplicate alerts are possible.** If both results are sent to the Security tab, the same problem may appear twice. The workflow uses a separate category for each tool (`trivy` and `grype`) so they do not overwrite each other.
3. **We saw no real difference in quality on this repo.** The project is small and has one lock file, so this is a small test. A bigger project, or a Docker image, may show differences.

## Our pick

Keep **Trivy**. It is already set up in `.github/workflows/trivy.yml` and also checks for secrets and configuration issues. Grype gave the same answer here, so there is no strong reason to add it.

## Suggested next step

Fix the 12 problems by upgrading the four libraries above. Be careful with `@azure/msal-node`: going from 5.x to 7.x is a big jump and may break something, so run the tests after the upgrade.

## How to repeat this at home

```bash
# Trivy
trivy fs . --severity HIGH,CRITICAL --ignore-unfixed

# Grype
grype dir:. --only-fixed
```
