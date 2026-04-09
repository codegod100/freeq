#!/bin/bash
# Panproto Protocol Validation for FreeQ
# Run this after spec changes to analyze impact

echo "🔬 Running Panproto Protocol Analysis..."
echo ""

# Run the pipeline first to generate fresh artifacts
echo "▶ Phase 1: Phoenix Pipeline"
node /home/nandi/code/phoenix/.pi/skills/phoenix-pipeline/pipeline.js .
echo ""

# Run protocol analysis
echo "▶ Phase 2: Protocol Analysis"
node analyze-migration.js
echo ""

# Check for drift
echo "▶ Phase 3: Drift Detection"
node /home/nandi/code/phoenix/.pi/skills/phoenix-drift/drift.js .

echo ""
echo "✅ Protocol validation complete!"
