#ifndef VOICE_ENHANCER_ENGINE_H
#define VOICE_ENHANCER_ENGINE_H

#include "voice_enhancer/Types.h"
#include "voice_enhancer/Preset.h"
#include "voice_enhancer/dsp/HighPassFilter.h"
#include "voice_enhancer/dsp/Compressor.h"
#include "voice_enhancer/dsp/ParametricEQ.h"
#include "voice_enhancer/dsp/DeEsser.h"
#include "voice_enhancer/dsp/Limiter.h"

#include <atomic>

namespace voice_enhancer {

// The DSP coordinator.
//
// Owns one instance of each stage and runs them in a fixed order:
//   input → HPF → Compressor → EQ → DeEsser → gain → Limiter → output
//
// One Engine instance processes one channel. For stereo, create two and
// call process_block on each. We do not support interleaved I/O at this
// layer — it's the caller's job to deinterleave on the way in.
//
// Thread safety:
//   * prepare(...)     must be called from a non-audio thread.
//   * set_preset(...)  may be called from any thread (atomically queues a
//                      preset swap that takes effect before the next buffer).
//   * set_bypass(...)  may be called from any thread.
//   * process_block    must be called from the audio thread only.
class Engine {
public:
    Engine() noexcept;

    // Set up internal state for the given sample rate. Allocates internal
    // buffers where needed. Must be called before any process_block call.
    // Not RT-safe.
    void prepare(SampleRate sr, FrameCount max_block_size) noexcept;

    // Clear all filter / envelope state. RT-safe.
    void reset() noexcept;

    // Swap to a new preset. Thread-safe. Takes effect at the start of the
    // next process_block call.
    void set_preset(PresetId id) noexcept;

    // Bypass entirely (passes input through unchanged). Thread-safe.
    void set_bypass(bool bypass) noexcept;

    // Per-block input/output gain. Thread-safe.
    void set_input_gain_db (Sample db) noexcept;
    void set_output_gain_db(Sample db) noexcept;

    // Direct threshold overrides (bypass the preset for these params).
    void set_comp_threshold_db(Sample db) noexcept;
    void set_deesser_threshold_db(Sample db) noexcept;

    // Peak-level readbacks for meters (0..1 linear). Thread-safe, set from
    // audio thread, read from UI thread.
    Sample get_input_peak () const noexcept { return m_input_peak.load (std::memory_order_relaxed); }
    Sample get_output_peak() const noexcept { return m_output_peak.load(std::memory_order_relaxed); }

    // Gain reduction meters in dB (negative values). Thread-safe.
    Sample get_compressor_gr_db() const noexcept { return m_comp_gr_db.load(std::memory_order_relaxed); }
    Sample get_deesser_gr_db   () const noexcept { return m_dees_gr_db.load(std::memory_order_relaxed); }

    // Main entry point: process one mono block in-place. RT-safe.
    void process_block(Sample* buffer, FrameCount num_frames) noexcept;

private:
    // Bounded coefficient updates; owned by prepare or the audio thread.
    void apply_pending_controls(unsigned changes) noexcept;
    enum ControlChange : unsigned { PresetChange = 1, InputGainChange = 2,
        OutputGainChange = 4, CompChange = 8, DeesserChange = 16, AllChanges = 31 };
    // Apply a preset before overlaying the pending threshold overrides.
    void apply_preset(const PresetConfig& cfg) noexcept;

    SampleRate m_sample_rate;
    FrameCount m_max_block_size;

    // DSP stages, in chain order.
    dsp::HighPassFilter m_hpf;
    dsp::Compressor     m_compressor;
    dsp::ParametricEQ   m_eq;
    dsp::DeEsser        m_deesser;
    dsp::Limiter        m_limiter;

    // Additional gain stages.
    Sample m_input_gain_linear;
    Sample m_output_gain_linear;
    Sample m_preset_output_gain_linear;

    // Single control producer publishes bounded scalar updates. Stage state
    // and linear gain caches are mutated only by prepare/the audio owner.
    // Whole configuration transactions are a separate future API.
    std::atomic<int> m_pending_preset;
    std::atomic<Sample> m_pending_input_gain;
    std::atomic<Sample> m_pending_output_gain;
    std::atomic<Sample> m_pending_comp_threshold;
    std::atomic<Sample> m_pending_deesser_threshold;
    std::atomic<unsigned> m_control_changes;
    static_assert(std::atomic<Sample>::is_always_lock_free, "Audio controls must be lock-free");

    std::atomic<bool> m_bypass;

    // Meter state.
    std::atomic<Sample> m_input_peak;
    std::atomic<Sample> m_output_peak;
    std::atomic<Sample> m_comp_gr_db;
    std::atomic<Sample> m_dees_gr_db;
};

} // namespace voice_enhancer

#endif // VOICE_ENHANCER_ENGINE_H
