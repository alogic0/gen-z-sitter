# Master Plan 2

This document captures the follow-on milestone sequence after the current `MASTER_PLAN.md` milestone run.

The goal remains the same: bias the project toward real generated-parser usefulness, runtime credibility, and explicit compatibility boundaries instead of more internal layering for its own sake.

## Follow-On Sequence

## MILESTONES 16 (Behavioral Equivalence)

- [x] verify generated parser behavior on real grammars, not only fixture grammars
- [x] compare parse behavior and failure behavior, not only emitted file shape
- [x] add corpus-oriented checks that exercise generated parsers end to end
- [x] document the current behavioral-equivalence boundary and known gaps
- detail: [MILESTONES_16.md](./MILESTONES_16.md)

Current completed boundary:
- first staged behavioral equivalence is now in place for a scanner-free real-language-style grammar
- current proof includes deterministic JSON-path and JS-path emitted output, deterministic parser-walk behavior, and explicit failure classification on invalid input
- broader equivalence still belongs to later milestones:
  - `MILESTONES 18 (Lexer / Scanner Path)`
  - `MILESTONES 19 (External Scanner Integration)`
  - `MILESTONES 20 (Compatibility Hardening)`

## MILESTONES 17 (Fuller `parser.c` Output)

- [x] move emitted `parser.c` closer to an actually runtime-consumable Tree-sitter artifact
- [x] reduce the remaining gap between the current diagnostic-friendly emitter and a real generated parser translation unit
- [x] define concrete exit criteria for “closer to upstream `parser.c`” so the work can be marked complete objectively
- [x] keep exact ready/blocked emission goldens stable while the parser surface becomes more realistic
- detail: [MILESTONES_17.md](./MILESTONES_17.md)

## MILESTONES 18 (Lexer / Scanner Path)

- [x] implement lexer/scanner emission beyond parser-table-only coverage
- [x] prove the lexer/scanner path on real grammar cases that cannot be covered by the current parser-only boundary
- [x] document staged compatibility limits in the emitted scanner/runtime surface
- detail: [MILESTONES_18.md](./MILESTONES_18.md)

Execution notes:
- [x] use this milestone as the active implementation plan before compatibility hardening
- [x] prefer the sequence:
  - first lexer/scanner boundary
  - then first external-scanner boundary
  - then broader compatibility hardening

## MILESTONES 19 (External Scanner Integration)

- [x] add external scanner integration support beyond the first blocked-only lexical boundary
- [x] prove the external-scanner path on real grammar cases that require external-token handling
- [x] document staged compatibility limits in the emitted external-scanner/runtime surface
- detail: [MILESTONES_19.md](./MILESTONES_19.md)

## MILESTONES 20 (Compatibility Hardening)

- [ ] document the remaining runtime-surface mismatches against expected Tree-sitter contracts
- [ ] shrink the emitted compatibility gaps that still block credible runtime use
- [ ] make ABI and compatibility-layer boundaries explicit and testable
- [ ] add compatibility-oriented checks for the richer emitted parser surface
- detail: [MILESTONES_20.md](./MILESTONES_20.md)

Current staged boundary being hardened in this milestone:

- parser/runtime compatibility is currently proven more by emitter, golden, structural, compile-smoke, and behavioral-harness tests than by the top-level CLI surface
- `behavioral_config` and `hidden_external_fields` now have compatibility-safe valid-path checks
- `repeat_choice_seq` still preserves deterministic JSON/JS parity and progress, but remains on the staged `unresolved_decision` boundary for its valid path
- the top-level `generate` command still does not expose emitted `parser.c`, emitted `grammar.json`, or compatibility reporting as first-class outputs

## MILESTONES 21 (Optimization Later)

- [ ] implement parse-table compression and/or minimization only after correctness is credible
- [ ] avoid performance-oriented rewrites that blur unresolved correctness and compatibility gaps
- [ ] document the intended optimization boundary before changing table layout materially
- detail: [MILESTONES_21.md](./MILESTONES_21.md)

Current parser-only shortlist boundary before broader real-repo onboarding:

- the staged parser-only shortlist and checked-in report artifacts now live under `compat_targets/`
- current checked-in artifacts include:
  - `shortlist.json`
  - `shortlist_inventory.json`
  - `shortlist_report.json`
  - `shortlist_mismatch_inventory.json`
- current first-wave parser-only run set:
  - 3 intended first-wave targets pass within the staged boundary
  - 1 deferred later-wave target is tracked separately
  - 1 external-scanner target is tracked explicitly as out of scope

## Immediate Recommended Next Target

- [x] promote `fuller parser output closer to upstream parser.c` into a dedicated milestone with concrete exit criteria
- [x] promote behavioral equivalence into a dedicated milestone with concrete exit criteria
- [x] promote `Lexer / Scanner Path` into a dedicated milestone plan
- [x] promote external-scanner integration into its own follow-on milestone
- [x] make broader compatibility hardening the next concrete direction after the first external-scanner stage

## Guiding Rule

- [ ] prefer end-to-end generated parser correctness on real grammars over additional planning-heavy internal refactoring
