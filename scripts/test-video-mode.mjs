import assert from "node:assert/strict";
import fs from "node:fs";

const viewModelSource = fs.readFileSync("RiffLoop/Media/PracticeViewModel.swift", "utf8");
const viewSource = fs.readFileSync("RiffLoop/UI/PracticeView.swift", "utf8");
const metronomeSource = fs.readFileSync("RiffLoop/Audio/MetronomeEngine.swift", "utf8");

const checks = [];

function check(name, callback) {
    try {
        callback();
        checks.push({ name, passed: true });
    } catch (error) {
        checks.push({ name, passed: false, message: error.message });
    }
}

function functionBody(source, signature) {
    const signatureIndex = source.indexOf(signature);
    assert.notEqual(signatureIndex, -1, `Missing function: ${signature}`);
    const openingBrace = source.indexOf("{", signatureIndex);
    assert.notEqual(openingBrace, -1, `Missing opening brace: ${signature}`);

    let depth = 0;
    for (let index = openingBrace; index < source.length; index += 1) {
        if (source[index] === "{") depth += 1;
        if (source[index] === "}") depth -= 1;
        if (depth === 0) return source.slice(openingBrace + 1, index);
    }
    assert.fail(`Missing closing brace: ${signature}`);
}

check("speed resynchronization replaces the stale metronome scheduler", () => {
    assert.match(metronomeSource, /private var schedulerGeneration: UInt64\?/);
    const body = functionBody(metronomeSource, "private func startSchedulerIfNeeded()");
    assert.match(body, /scheduler == nil \|\| schedulerGeneration != generation/);
    assert.match(body, /scheduler\?\.cancel\(\)/);
    assert.match(body, /schedulerGeneration = generation/);
});

check("enabling A/B loop seeks to point A through the coordinated transport", () => {
    const body = functionBody(viewModelSource, "func setLoopEnabled(_ enabled: Bool)");
    assert.match(body, /let loopEntryTarget = enabled \? pointA : nil/);
    assert.match(body, /seek\(to: loopEntryTarget\)/);
});

check("the paused video surface offers an explicit exit-loop button", () => {
    assert.match(viewSource, /Label\("退出 A\/B 循环"/);
    assert.match(viewSource, /Button\(action: viewModel\.clearLoop\)/);
});

check("manual speed and speed-ladder controls explain their distinct roles", () => {
    assert.ok(viewSource.includes('Text("手动 \\(rateLabel'));
    assert.match(viewSource, /"阶梯说明：/);
    assert.match(viewSource, /String\(format: "%\.2f×", rate\)/);
});

for (const result of checks) {
    console.log(`${result.passed ? "PASS" : "FAIL"}: ${result.name}`);
    if (!result.passed) console.log(`  ${result.message}`);
}

if (checks.some((result) => !result.passed)) process.exit(1);
