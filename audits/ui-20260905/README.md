# iPad UI audit capture

Audit baseline: app source from b3c24b3 (0.25.55 / 99), documentation HEAD ab0d7eb.
This branch adds only an explicitly dispatched simulator capture workflow and test sources.
The workflow generates a temporary XcodeGen UI-test target; production source, project.yml,
Bundle ID and the real iPad remain unchanged. Fixtures are synthetic and seeded only under
`targetEnvironment(simulator)`. No user's documents or private screenshots are uploaded.

Run `gh workflow run ios-ui-audit.yml --ref codex/ui-audit-20260905`.
Download `RiffLoop-UI-audit-synthetic` and inspect every image before accepting it as evidence.
A passing test is capture completion, not a claim of complete visual or functional correctness.
Simulator iOS 18.5 evidence must be labeled separately from iPadOS 27 real-device evidence.
