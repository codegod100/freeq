---
name: hotspots
description: Identify risky hotspots in the codebase by combining churn (how often files change) and complexity using churn_vs_complexity
allowed-tools: Bash Glob Read
---

# Hotspots Analysis

Identify the highest-risk files in the codebase — files that change frequently AND are complex. These are where bugs are most likely to hide.

## Steps

### Step 0: Check tool availability
Run `churn_vs_complexity --version 2>/dev/null` to verify installation.
If not found, tell the user: `gem install churn_vs_complexity`

### Step 1: Verify git repository
Run `git rev-parse --show-toplevel` to get the repo root.

### Step 2: Detect language
This is a multi-language project. Run analysis for each:
- **Rust** (`--rust`): `freeq-server/src/`, `freeq-sdk/src/`
- **TypeScript** (`--js`): `freeq-app/src/`

Count files to determine primary:
- `find . -name '*.rs' -not -path '*/target/*' | wc -l`
- `find . -name '*.ts' -o -name '*.tsx' -not -path '*/node_modules/*' | wc -l`

### Step 3: Run analysis
From the repo root:
```
churn_vs_complexity --hotspots --rust --quarter --json .
churn_vs_complexity --hotspots --js --quarter --json .
```

If `--quarter` returns empty, retry with `--year`.

### Step 4: Present results
Show a markdown table: File | Complexity | Churn | Gamma (risk score)

Explain that high gamma = high risk. These files should get the most careful review and testing.

Offer:
- `--graph` for visual chart
- `--triage <file>` for deeper analysis of specific files
- `--diff main` for comparison against a branch
