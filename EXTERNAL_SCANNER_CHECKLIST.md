# External Scanner Checklist

This checklist turns the deferred external-scanner work from the first lexer/scanner stage into a concrete execution plan.

Its purpose is to move the project from a serialized lexical boundary with explicit external-token blockers to the first real external-scanner integration boundary.

## Goal

- [ ] support the first external-token grammar shape beyond the current blocked-only lexical boundary
- [ ] keep the first external-scanner stage narrow enough to verify locally and close cleanly
- [ ] avoid claiming full upstream scanner ABI parity before the emitted/runtime contract is explicit

## Implementation Sequence

### 1. Define the first supported external-scanner boundary

- [ ] choose the first external-token grammar shape to support
- [ ] decide which scanner/runtime behaviors stay deferred from this first external-scanner stage
- [ ] document the first supported external-scanner comparison surface

### 2. Introduce external-scanner IR and serialization boundary

- [ ] define the minimal external-scanner IR needed beyond the current blocked lexical boundary
- [ ] keep that IR deterministic and emitter-oriented
- [ ] preserve explicit blockers for unsupported external-scanner features rather than hiding them

### 3. Add deterministic external-scanner artifacts

- [ ] add exact artifacts for the first supported external-token grammar
- [ ] cover both ready and explicitly blocked external-scanner cases where applicable
- [ ] keep output deterministic across `grammar.json` and `grammar.js` load paths where supported

### 4. Add emitted or runtime-facing external-scanner checks

- [ ] add structural checks for the first external-scanner boundary
- [ ] add compile-oriented or smoke-oriented proof if this stage reaches emitted scanner/runtime code
- [ ] keep checks aligned with the staged compatibility boundary rather than claiming full upstream scanner ABI support

### 5. Connect external-scanner work to behavioral proof

- [ ] add at least one real grammar/input case that specifically requires external-token handling
- [ ] make the new behavioral coverage explicit
- [ ] document what still remains deferred after the first external-scanner stage

### 6. Record deferrals and closeout boundary

- [ ] document what remains deferred to broader compatibility hardening
- [ ] document what remains deferred to richer scanner/runtime parity work
- [ ] decide whether the first external-scanner stage is strong enough to close the checklist

## Exit Criteria

- [ ] at least one external-scanner-driven grammar shape is supported end to end
- [ ] deterministic artifacts exist for the supported external-scanner subset
- [ ] the emitted/runtime external-scanner boundary has structural proof, and compile proof if applicable
- [ ] the new behavioral coverage enabled by external-token handling is explicit
- [ ] remaining scanner/runtime and compatibility gaps are documented rather than implicit

## Explicit Non-Goals For This Checklist

- [ ] do not claim full upstream external-scanner ABI parity here
- [ ] do not fold broad compatibility hardening into the first external-scanner stage
- [ ] do not take on parse-table compression/minimization here
- [ ] do not broaden into general real-grammar/repo compatibility until this boundary is real
