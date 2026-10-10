#include "voice_enhancer/Engine.h"

#include <cmath>
#include <algorithm>

namespace voice_enhancer {

Engine::Engine() noexcept
    : m_sample_rate(48000.0)
    , m_max_block_size(512)
    , m_input_gain_linear(1.0f)
    , m_output_gain_linear(1.0f)
    , m_preset_output_gain_linear(1.0f)
    , m_pending_preset(static_cast<int>(PresetId::Natural))
    , m_pending_input_gain(1.0f)
    , m_pending_output_gain(1.0f)
    , m_pending_comp_threshold(get_preset(PresetId::Natural).comp_threshold_db)
    , m_pending_deesser_threshold(get_preset(PresetId::Natural).deesser_threshold_db)
    , m_control_changes(AllChanges)
    , m_bypass(false)
    , m_input_peak(0.0f)
    , m_output_peak(0.0f)
    , m_comp_gr_db(0.0f)
    , m_dees_gr_db(0.0f)
{}

void Engine::prepare(SampleRate sr, FrameCount max_block_size) noexcept {
    m_sample_rate = sr;
    m_max_block_size = max_block_size;

    m_hpf.prepare(sr);
    m_compressor.prepare(sr);
    m_eq.prepare(sr);
    m_deesser.prepare(sr);
    m_limiter.prepare(sr);

    // Consume before reading scalars so a concurrently published newer update
    // remains dirty for the next block. Restore overrides after factory setup.
    apply_pending_controls(m_control_changes.exchange(0, std::memory_order_acquire) | AllChanges);

    reset();
}

void Engine::reset() noexcept {
    m_hpf.reset();
    m_compressor.reset();
    m_eq.reset();
    m_deesser.reset();
    m_limiter.reset();
}

void Engine::set_preset(PresetId id) noexcept {
    const auto& preset = get_preset(id);
    m_pending_preset.store(static_cast<int>(id), std::memory_order_relaxed);
    m_pending_comp_threshold.store(preset.comp_threshold_db, std::memory_order_relaxed);
    m_pending_deesser_threshold.store(preset.deesser_threshold_db, std::memory_order_relaxed);
    m_control_changes.fetch_or(PresetChange | CompChange | DeesserChange, std::memory_order_release);
}

void Engine::set_bypass(bool bypass) noexcept {
    m_bypass.store(bypass, std::memory_order_relaxed);
}

void Engine::set_input_gain_db(Sample db) noexcept {
    m_pending_input_gain.store(db_to_linear(db), std::memory_order_relaxed);
    m_control_changes.fetch_or(InputGainChange, std::memory_order_release);
}

void Engine::set_output_gain_db(Sample db) noexcept {
    m_pending_output_gain.store(db_to_linear(db), std::memory_order_relaxed);
    m_control_changes.fetch_or(OutputGainChange, std::memory_order_release);
}

void Engine::set_comp_threshold_db(Sample db) noexcept {
    m_pending_comp_threshold.store(db, std::memory_order_relaxed);
    m_control_changes.fetch_or(CompChange, std::memory_order_release);
}

void Engine::set_deesser_threshold_db(Sample db) noexcept {
    m_pending_deesser_threshold.store(db, std::memory_order_relaxed);
    m_control_changes.fetch_or(DeesserChange, std::memory_order_release);
}

void Engine::apply_pending_controls(unsigned changes) noexcept {
    if (changes & PresetChange) {
        apply_preset(get_preset(static_cast<PresetId>(m_pending_preset.load(std::memory_order_relaxed))));
    }
    if (changes & CompChange) m_compressor.set_threshold_db(m_pending_comp_threshold.load(std::memory_order_relaxed));
    if (changes & DeesserChange) m_deesser.set_threshold_db(m_pending_deesser_threshold.load(std::memory_order_relaxed));
    if (changes & InputGainChange) m_input_gain_linear = m_pending_input_gain.load(std::memory_order_relaxed);
    if (changes & OutputGainChange) m_output_gain_linear = m_pending_output_gain.load(std::memory_order_relaxed);
}

void Engine::apply_preset(const PresetConfig& cfg) noexcept {
    m_hpf.set_cutoff(cfg.hpf_cutoff_hz);

    m_compressor.set_threshold_db(cfg.comp_threshold_db);
    m_compressor.set_ratio       (cfg.comp_ratio);
    m_compressor.set_knee_db     (cfg.comp_knee_db);
    m_compressor.set_attack_ms   (cfg.comp_attack_ms);
    m_compressor.set_release_ms  (cfg.comp_release_ms);
    m_compressor.set_auto_makeup (true);

    for (std::size_t i = 0; i < dsp::ParametricEQ::BandCount; ++i) {
        m_eq.set_band(static_cast<dsp::ParametricEQ::BandIndex>(i), cfg.eq_bands[i]);
    }

    m_deesser.set_crossover_hz    (cfg.deesser_crossover_hz);
    m_deesser.set_threshold_db    (cfg.deesser_threshold_db);
    m_deesser.set_ratio           (cfg.deesser_ratio);
    m_deesser.set_max_reduction_db(cfg.deesser_max_reduction_db);

    m_preset_output_gain_linear = db_to_linear(cfg.output_gain_db);

    m_limiter.set_ceiling_db(cfg.limiter_ceiling_db);
    m_limiter.set_release_ms(50.0f);
}

void Engine::process_block(Sample* buffer, FrameCount num_frames) noexcept {
    apply_pending_controls(m_control_changes.exchange(0, std::memory_order_acquire));

    // 2. Input meter + input gain.
    Sample input_peak = 0.0f;
    {
        const Sample g = m_input_gain_linear;
        for (FrameCount i = 0; i < num_frames; ++i) {
            buffer[i] *= g;
            const Sample a = std::fabs(buffer[i]);
            if (a > input_peak) input_peak = a;
        }
    }
    m_input_peak.store(input_peak, std::memory_order_relaxed);

    // 3. Bypass short-circuit. We still update meters above so the UI sees
    //    something useful even in bypass mode.
    if (m_bypass.load(std::memory_order_relaxed)) {
        m_output_peak.store(input_peak, std::memory_order_relaxed);
        m_comp_gr_db.store(0.0f, std::memory_order_relaxed);
        m_dees_gr_db.store(0.0f, std::memory_order_relaxed);
        return;
    }

    // 4. DSP chain.
    m_hpf.process_block(buffer, num_frames);
    m_compressor.process_block(buffer, num_frames);
    m_eq.process_block(buffer, num_frames);
    m_deesser.process_block(buffer, num_frames);

    // 5. Static output gain (preset + user) then limiter.
    const Sample out_gain = m_preset_output_gain_linear * m_output_gain_linear;
    if (out_gain != 1.0f) {
        for (FrameCount i = 0; i < num_frames; ++i) {
            buffer[i] *= out_gain;
        }
    }
    m_limiter.process_block(buffer, num_frames);

    // 6. Output meter + GR meters.
    Sample output_peak = 0.0f;
    for (FrameCount i = 0; i < num_frames; ++i) {
        const Sample a = std::fabs(buffer[i]);
        if (a > output_peak) output_peak = a;
    }
    m_output_peak.store(output_peak, std::memory_order_relaxed);
    m_comp_gr_db.store(m_compressor.get_gain_reduction_db(), std::memory_order_relaxed);
    m_dees_gr_db.store(m_deesser.get_gain_reduction_db(),    std::memory_order_relaxed);
}

} // namespace voice_enhancer
