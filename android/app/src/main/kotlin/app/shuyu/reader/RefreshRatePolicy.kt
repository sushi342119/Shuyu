package app.shuyu.reader

/** Resolution-preserving selection, without assuming a particular panel rate. */
internal object RefreshRatePolicy {
    data class Mode(val id: Int, val width: Int, val height: Int, val rate: Float)
    data class Preference(val modeId: Int, val rate: Float)

    fun select(sdk: Int, current: Mode, modes: List<Mode>, target: Float = 0f): Preference? {
        if (target == -1f) return Preference(0, 0f)
        val available = modes.asSequence()
            .filter { it.width == current.width && it.height == current.height }
            .filter { it.rate.isFinite() && it.rate > 0f }
            .toList()
        val eligible = if (target > 0f) available.filter { it.rate <= target + .5f }.ifEmpty { available.minByOrNull { it.rate }?.let { listOf(it) } ?: emptyList() } else available
        val fastest = eligible.asSequence()
            .maxWithOrNull(compareBy<Mode> { it.rate }.thenBy { it.id == current.id })
            ?: return null
        // All candidates already match the current physical resolution, so binding
        // fastest.id across all SDKs locks high refresh rate on OEM Android 14+ ROMs
        // that ignore rate-only votes when preferredDisplayModeId is left at 0.
        return Preference(fastest.id, fastest.rate)
    }

    fun rates(current: Mode, modes: List<Mode>): List<Float> = modes
        .filter { it.width == current.width && it.height == current.height && it.rate.isFinite() && it.rate > 0f }
        .map { it.rate }.sorted().fold(mutableListOf<Float>()) { rates, rate ->
            if (rates.none { kotlin.math.abs(it - rate) < .5f }) rates.add(rate)
            rates
        }
}

/** One vote per live surface/rate, not one vote per layout or rendered frame. */
internal class SurfaceRateVote {
    private var applied: Float? = null
    val appliedRate: Float? get() = applied
    fun apply(rate: Float, valid: Boolean, submit: (Float) -> Unit): Boolean {
        if (!valid) { applied = null; return false }
        if (applied == rate) return false
        submit(rate)
        applied = rate
        return true
    }
    fun invalidate() { applied = null }
}
