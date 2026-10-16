---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m51c593zcqf0n8757spj6eg4
  text: |-
    ### implement — changed
    - New file `PendingElicitation+Validation.swift`: `public func validationFailure(of content: JSONValue?) -> String?`. It decodes the wire schema as Extras `ElicitationRequestedSchema`, decodes the content as `[String: ElicitationValue]`, and calls Extras. An undecodable schema or content gives nil and one warning log line. A URL-mode request gives nil. A nil content goes to Extras as nil, so a missing required field gives the Extras text.
    - The local Extras pin moved from f3d5cf1 to 6cfd13c (Package.resolved is in .gitignore, so no commit holds it; CI resolves Extras main).
    - New suite `PendingElicitationValidationTests` with 6 tests: the 3 asked tests, plus a missing required field, an undecodable answer, and a URL-mode request.
    - Full run: 574 tests in 46 suites pass. IntegrationTests builds.
  timestamp: 2026-10-16T03:30:14.783218+00:00
position_column: done
position_ordinal: ff8580
title: 'Elicitation phase 3: public bridge PendingElicitation.validationFailure(of:) to the Extras answer check, for AgentViewKit ^q6mny1d'
---
Source: request of the step owner, for AgentViewKit ^q6mny1d. AgentViewKit must not import FoundationModelsExtras, but it must check an answer with Extras `ElicitationRequestedSchema.validationFailure(of:)` before it sends it.

Work:
- Add `public func validationFailure(of content: JSONValue?) -> String?` on `PendingElicitation`.
- Decode the wire `ElicitationSchema` of the request as the Extras `ElicitationRequestedSchema` (the reverse of `wireSchema` of the agent relay). Decode the content as `[String: ElicitationValue]`. Call Extras.
- When the schema or the content does not decode, give `nil` and write one log line. A URL-mode request gives `nil`.
- The change is additive. The Extras pin moves to a main that has `validationFailure(of:)`.
- Tests in fixed order: a valid answer gives nil; a failing field gives the Extras text; an undecodable schema gives nil.
- One full run; push when green and the previous CI run has ended; report the head.

#elicitation-phase-3