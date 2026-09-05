# iPad UI audit capture

Audit baseline: app source from b3c24b3 (0.25.55 / 99), documentation HEAD ab0d7eb.
This branch adds only a simulator capture workflow and test sources.
The workflow generates a temporary XcodeGen UI-test target; production source, project.yml,
Bundle ID and the real iPad remain unchanged. Fixtures are synthetic and seeded only under
`targetEnvironment(simulator)`. No user's documents or private screenshots are uploaded.

Pushes affecting this folder or ios-ui-audit.yml on this branch trigger capture.
The workflow also declares workflow_dispatch, but the CLI can return 404 while
the workflow file is absent from the default branch. Do not change release workflows to work around that.
Download `RiffLoop-UI-audit-synthetic` and inspect every image before accepting it as evidence.
A passing test is capture completion, not a claim of complete visual or functional correctness.
Simulator iOS 18.5 evidence must be labeled separately from iPadOS 27 real-device evidence.

Final accepted evidence: 41 images from run 33959744647 and 5 from 33960709029.
The workflow currently selects supplementary tests 04 and 05 only. Run 2 video/PDF
tests passed; test01 stops after its delete-confirmation capture because the
outside-popover title is not hittable. This test harness limitation is not a
product deletion failure. No deletion or real-device import was performed.
Run 1 images were cropped, and run 3 states were wrong; neither is accepted.
The final switch helper targets the nested UISwitch; tapping the outer Form row
does not toggle it. File importer capture waits for sheet/provider presentation.

Findings and coverage limits: docs/UI_AUDIT_20260905.md on codex/ipad-home-ui.
Permanent synthetic evidence: release v0.25.55-rc.1,
RiffLoop-UI-audit-synthetic-20260905.zip (46 original PNGs plus manifests/gallery).
No product source, project.yml, real-device data, or installed version was changed.
