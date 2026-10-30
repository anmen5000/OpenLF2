// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include "openlf2/core/script_value.hpp"
#include "openlf2/ports/resources.hpp"
#include "openlf2/ports/network.hpp"
#include "openlf2/ports/settings.hpp"
#include "openlf2/ports/platform.hpp"
#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>

namespace openlf2 {
enum class ScriptData { object, background, stage };
// Parsed game data offered to scripts. Implementations must outlive the runtime.
class ScriptDataSource {
public:
    virtual ~ScriptDataSource() = default;
    virtual Result<ScriptValue> read(ScriptData kind, std::string_view path) const = 0;
};
// The part of the game random state a recording keeps: the 3000-entry table and its index.
struct RandomState {
    std::array<std::uint8_t, 3000> table{};
    std::int32_t index = 0;
};
// Seeded compatibility random numbers; scripts must not use host randomness.
class ScriptRandom {
public:
    virtual ~ScriptRandom() = default;
    [[nodiscard]] virtual RandomState state() const noexcept = 0;
    virtual void restore(const RandomState& state) noexcept = 0;
    virtual void reset_sequence() noexcept = 0;
    // The counter next() adds to table entries (0..1233): with state(), all of the generator, so that a script
    // can draw numbers privately and put the generator back as it was.
    [[nodiscard]] virtual std::int32_t sequence() const noexcept = 0;
    virtual void restore_sequence(std::int32_t sequence) noexcept = 0;
    virtual std::int32_t next(std::int32_t range) noexcept = 0;
    // The C runtime rand() stream (0..32767) the original also calls directly. Must not throw.
    virtual std::int32_t crt() noexcept = 0;
};
// Recordings: saving a finished recording block under a file name, the block of the recording a
// player chose to replay (once), and the local time for file names.
class ScriptRecordings {
public:
    virtual ~ScriptRecordings() = default;
    virtual Result<void> save(std::string_view name, std::span<const char> block) = 0;
    virtual std::optional<Result<Bytes>> take() = 0;
    // "YYYYMMDD_HHMMSS" (the original's SYSTEMTIME format).
    [[nodiscard]] virtual std::string local_time() const = 0;
};
// One committed script tick. All frame commands cross the Lua boundary as a
// numeric opcode batch and are decoded once into these owned values.
struct ScriptFrame {
    Viewport viewport;
    bool waiting = false;
    std::optional<bool> fast, text_input, fullscreen, replay_drop;
    std::optional<RenderFilter> render_filter;
    std::vector<DrawCommand> commands;
    std::vector<SoundCommand> sounds;
    std::vector<MusicCommand> music;
    std::vector<RumbleCommand> rumbles;
    std::vector<std::string> actions;
    std::optional<FileDialogText> file_dialog; // for a "replay" action in this frame
};
class ScriptRuntime {
public:
    virtual ~ScriptRuntime() = default;
    virtual Result<void> load(std::string_view bundle) = 0;
    virtual Result<ScriptFrame> frame(std::string_view input) = 0;
    // Diagnostic text from the active screen's optional describe(); for tests and traces.
    virtual Result<std::string> describe() = 0;
};
// All services must outlive the runtime.
Result<std::unique_ptr<ScriptRuntime>> make_script_runtime(bool enable_jit, const ResourceSource& resources,
                                                           const ScriptDataSource& data, ScriptRandom& random,
                                                           SettingsStore& settings, ScriptRecordings& recordings,
                                                           NetworkTransport& network);
}
