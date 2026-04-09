# Project Specification

Describe what this project does in one paragraph.

## Overview

This project implements a [system/app/feature] that [main purpose].

## Requirements

- REQUIREMENT: The system shall [primary capability]
- REQUIREMENT: The system shall [secondary capability]
- CONSTRAINT: Must not exceed [limitation]
- CONSTRAINT: Must support [minimum requirement]

## Definitions

- DEFINITION: "[Term]" means [clear definition]

## Getting Started

1. Edit this file with specific requirements
2. Run the Phoenix pipeline:
   
   ```bash
   node .pi/skills/phoenix-ingest/ingest.js
   node .pi/skills/phoenix-canonicalize/canonicalize.js
   node .pi/skills/phoenix-plan/plan.js
   node .pi/skills/phoenix-regen/regen.js
   ```

3. Check status:
   
   ```bash
   node .pi/skills/phoenix-status/status.js
   ```

## Notes

Add any additional context, references, or design notes here.
