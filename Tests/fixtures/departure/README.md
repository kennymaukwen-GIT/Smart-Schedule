# 「該出發了」 contract samples

One set of samples for both sides of `POST /v1/departure/routes`, so the app and the Worker can't drift apart:

- `request.*.json`: the exact body the app sends (`Shared/Departure/DepartureRoutes.swift`,
  `Tests/Unit/DepartureRoutesTests.swift`), which the Worker must accept (`server/worker/test/departure.test.ts`).
- `google.*.json`: Google's computeRoutes answer for that request, as the Worker's field mask returns it (built from
  Google's protos; a real answer has more of the same).
- `response.*.json`: what the Worker answers for that request and Google answer (its test produces it and compares,
  with the random `plan` token replaced by `AAAA…`), which the app must read.

Only `.json` files at the top of `Tests/fixtures` are Gemini fixtures; this folder is not one of them.
