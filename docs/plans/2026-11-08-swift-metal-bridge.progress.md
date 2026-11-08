- start bbbb649
- unblocked: dispatched T1 T2 T3 T4 at 11:30:52; waiting on fixes: T5
Ruling: skip Wave 0 T0 - skeleton exists, T1-T4 consume no task's Produces, only T5 does and waits for real code - cost: none
- unblocked: dispatched T1 T2 T3 T4 T6 at 11:32:43 (T1-T4 retried after Agent tool error); waiting on fixes: T5
Ruling: T5 router is Kind design on sonnet - lint rejected mechanical without exact test I/O - cost: slightly slower task
- commit T6 0b5d4ff03e Minimal SwiftUI window
- commit T3 7a4bfdb07f CLI albums
Ruling: archive prompt goes through out as a full line (newline after [y/N]) - Python print-vs-input difference is cosmetic - cost: prompt cursor on next line
- commit T4 6f2b19c782 CLI catalog
Ruling: T5 prints errors as "Ошибка: <message>" to stderr, exit 2 - cli.py:505 is the source of truth, plan text "ошибка:" was wrong - cost: none
Ruling: `models --models-dir` must be honored (pass dir to ModelStore or set AILBUM_MODELS_DIR before lookup) - fix in T4 package review - cost: small
- commit T1 bc127c8560 Desktop bridge
- commit T2 002a9c1fd3 Desktop job
Ruling: job argument errors emit an error event ("ArgumentError: ...") and exit 2 instead of argparse stderr usage - the app parses events, not stderr - cost: none
- unblocked: dispatched T5 at $(date +%H:%M:%S); waiting on fixes: none
- commit T4 578e683b3d CLI catalog
Ruling: leftovers accepted - CLIAlbums has no --opt=value form, archive prompt ends with newline, models/download-models print a status table - cosmetic CLI differences, the app does not use them - cost: minor CLI parity
- commit T5 53aefd0f30 Main router
- commit T1 eb50fc6f43 Desktop bridge
Ruling: bridge leftovers accepted (person.name stringifies, complete_archive dict iterates values, numeric error text) - the app sends well-typed payloads - cost: none expected
- commit T2 77d3b36396 Desktop job
- commit T6 c38b329eb6 Minimal SwiftUI window
Ruling: T6 leftovers accepted (all-photos shows missing/archived as placeholders, album order by date) - preview window, 5b replaces it - cost: none
Ruling: final-review findings are packet tooling gaps (pytest-only run_tests and Python contract checker on a Swift package) - respond(database:line:) exists at DesktopBridge.swift:311 with the plan example tested at DesktopBridgeTests.swift:132; per-test results come from the full `swift test` run - cost: none
