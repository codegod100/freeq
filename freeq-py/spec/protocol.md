# Phoenix Protocol Usage for FreeQ

This project follows the **Phoenix VCS Protocol** defined in the Phoenix skill system. Each transformation in the pipeline is a formal lensing morphism between Generalized Algebraic Theories (GATs).

## Pipeline Morphisms

```
ThSpec ──[μ_ingest]──► ThClause ──[μ_canon]──► ThCanon ──[μ_plan]──► ThIU ──[μ_codegen]──► ThCode
```

| Morphism | Source → Target | Description |
|----------|-----------------|-------------|
| μ_ingest | ThSpec → ThClause | Parse specs into content-addressed clauses |
| μ_canon | ThClause → ThCanon | Normalize requirements, collapse duplicates |
| μ_plan | ThCanon → ThIU | Group requirements into Implementation Units |
| μ_codegen | ThIU → ThCode | Generate Python Textual TUI code |

## Theory Instances in FreeQ

### ThSpec Instance
- **Documents**: 11 spec files (`spec/*.md`)
- **Clauses**: 21 requirements
- **Types**: REQUIREMENT, CONSTRAINT, DEFINITION

### ThCanon Instance
- **Canonical nodes**: 21
- **D-rate**: 0% (no duplication)
- **Classification**: All A-class (clean requirements)

### ThIU Instance
- **Implementation Units**: 3
- **Risk distribution**: { critical: 1, high: 1, medium: 1 }
- **Coverage**: 100%

### ThCode Instance
- **Language**: Python (Textual TUI)
- **Modules**: 10 files
- **Traceability**: Every function traces to ≥1 canon

## Running with GAT Validation

```bash
# Full pipeline with strict GAT enforcement
node .pi/skills/phoenix-pipeline/pipeline.js . --strict-gat

# Skip GAT validation (faster, less safe)
node .pi/skills/phoenix-pipeline/pipeline.js . --skip-gat
```

## Protocol Reference

- **Full GAT Specification**: `/home/nandi/code/phoenix/.pi/skills/phoenix/SKILL.md`
- **Panproto Engine**: `/home/nandi/code/phoenix/.pi/skills/panproto/`
- **Pipeline Implementation**: `/home/nandi/code/phoenix/.pi/skills/phoenix-pipeline/pipeline.js`

## Domain Mapping

| Domain | ThIU | ThCode Module | Risk |
|--------|------|---------------|------|
| Auth | iu:auth-domain | auth_screen.py | critical |
| Broker | iu:broker-domain | broker.py | critical |
| Messaging | iu:messaging-domain | message_list.py | high |
| Sidebar | iu:sidebar-domain | sidebar.py | medium |
| User List | iu:userlist-domain | user_list.py | low |

## Verification

```bash
# Run GAT validation manually
node analyze-migration.js

# Output shows:
# - Axiom satisfaction (deterministic, provenance, covering, etc.)
# - Morphism composition correctness
# - Coverage analysis
# - Traceability chain
```
