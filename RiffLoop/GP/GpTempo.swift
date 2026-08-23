import Foundation

let gpMinimumCustomBpm = 30.0
let gpMaximumCustomBpm = 300.0
let gpMinimumEffectivePlaybackSpeed = 0.125
let gpMaximumEffectivePlaybackSpeed = 8.0

func gpCustomBaseBpmRange(originalBpm: Double) -> ClosedRange<Double> {
    let original = originalBpm.isFinite && originalBpm > 0 ? originalBpm : 120
    let lower = max(
        gpMinimumCustomBpm,
        ceil(original * gpMinimumEffectivePlaybackSpeed / 0.5)
    )
    let upper = min(
        gpMaximumCustomBpm,
        floor(original * gpMaximumEffectivePlaybackSpeed / 1.5)
    )
    guard lower <= upper else {
        let fallback = min(max(original, gpMinimumCustomBpm), gpMaximumCustomBpm)
        return fallback ... fallback
    }
    return lower ... upper
}

func gpEffectivePlaybackSpeed(
    originalBaseBpm: Double,
    baseBpm: Double,
    practiceMultiplier: Double
) -> Double {
    let original = originalBaseBpm.isFinite && originalBaseBpm > 0 ? originalBaseBpm : 120
    let custom = baseBpm.isFinite && baseBpm > 0 ? baseBpm : original
    let multiplier = practiceMultiplier.isFinite && practiceMultiplier > 0 ? practiceMultiplier : 1
    return min(
        max(custom / original * multiplier, gpMinimumEffectivePlaybackSpeed),
        gpMaximumEffectivePlaybackSpeed
    )
}

func gpScaledCurrentBpm(
    originalTempo: Double,
    originalBaseBpm: Double,
    baseBpm: Double,
    practiceMultiplier: Double
) -> Double {
    let tempo = originalTempo.isFinite && originalTempo > 0 ? originalTempo : originalBaseBpm
    return tempo * gpEffectivePlaybackSpeed(
        originalBaseBpm: originalBaseBpm,
        baseBpm: baseBpm,
        practiceMultiplier: practiceMultiplier
    )
}
