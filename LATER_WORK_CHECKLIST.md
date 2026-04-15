# Later Work Checklist

This checklist covers the longer-tail generator work that remains after the currently active milestone sequence.

Use this file for follow-on implementation once the active milestone work in [MASTER_PLAN.md](./MASTER_PLAN.md) has moved far enough that broader generator parity becomes the immediate priority.

## Fuller Generator Parity

- [x] fuller parser output closer to upstream `parser.c`
- [ ] lexer/scanner emission
- [ ] external scanner integration
- [ ] parse-table compression/minimization
- [ ] broader real-grammar/repo compatibility coverage
- [ ] compatibility polish and ergonomics after correctness is credible

Immediate promotion candidates after the first behavioral-equivalence stage:
- [ ] turn `lexer/scanner emission` into a dedicated execution checklist
- [ ] decide whether `external scanner integration` stays coupled to that same checklist or becomes a separate follow-on checklist
- [ ] decide whether `broader real-grammar/repo compatibility coverage` waits on lexer/scanner support or starts with parser-only repo cases first

## Notes

- These items are intentionally separated from the active milestone checklist.
- They are still real project work, but they should not dilute the milestone-by-milestone closeout process in `MASTER_PLAN.md`.
- When one of these becomes the next concrete implementation target, it should usually be promoted into its own milestone checklist first.
- The completed behavioral-equivalence stage establishes only the first scanner-free parser-walk boundary; broader real-grammar/repo coverage remains active later work here.
