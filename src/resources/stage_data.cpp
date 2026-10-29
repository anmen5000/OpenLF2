// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/resources/stage_data.hpp"
#include "openlf2/resources/data_file.hpp"
#include "openlf2/detail/resources/scan_stream.hpp"

namespace openlf2::stage_data {
namespace {
using scanning::ParseFailure;
using scanning::TokenStream;
constexpr std::size_t word_capacity = 200;
// `music:` is read into the phase record 0xe0 bytes before its first entry.
constexpr std::size_t music_capacity = 0xe0;
constexpr std::size_t max_diagnostics = 64;
constexpr std::size_t max_input = 4 * 1024 * 1024;

class Parser {
public:
    explicit Parser(std::string_view text) : stream_(text) {
        stream_.on_overrun([this](std::string message) { note(std::move(message)); });
    }

    StageList run() {
        while (!stream_.at_end()) {
            if (!stream_.word(word_, word_capacity)) break;
            if (word_ == "<stage>") stage();
        }
        return std::move(list_);
    }

    [[nodiscard]] std::size_t line() const { return stream_.line(); }

private:
    // Inside a block the original loops until its end word; at end of file it would repeat the
    // last word forever, so the port rejects the file instead.
    void next_in(std::string_view block) {
        if (!stream_.word(word_, word_capacity)) {
            throw ParseFailure{ErrorCode::format, "unterminated " + std::string(block) + " at end of file"};
        }
    }

    void note(std::string message) {
        if (list_.diagnostics.size() < max_diagnostics) {
            list_.diagnostics.push_back("line " + std::to_string(stream_.line()) + ": " + std::move(message));
        }
    }

    void read_int(std::int32_t& field) {
        if (stream_.integer(field) == TokenStream::Scan::mismatch) {
            note("`" + word_ + "` expects an integer; value left unchanged");
        }
    }

    void stage() {
        do {
            next_in("<stage>");
            if (word_ == "id:") {
                std::int32_t id = current_;
                read_int(id);
                if (id < 0 || static_cast<std::size_t>(id) >= max_stages) {
                    throw ParseFailure{ErrorCode::unsupported, "stage id outside 0-59: " + std::to_string(id)};
                }
                current_ = id;
                // `id:` resets every phase and entry of the stage and the phase count.
                list_.stages[static_cast<std::size_t>(id)] = Stage{};
            }
            if (word_ == "<phase>") phase();
        } while (word_ != "<stage_end>");
    }

    Stage& current_stage() {
        if (current_ < 0 || !list_.stages[static_cast<std::size_t>(current_)]) {
            throw ParseFailure{ErrorCode::unsupported, "<phase> before a stage `id:`"};
        }
        return *list_.stages[static_cast<std::size_t>(current_)];
    }

    Entry& current_entry(Phase& phase) {
        if (phase.entries.empty()) {
            throw ParseFailure{ErrorCode::unsupported, "`" + word_ + "` before the phase's first `id:`"};
        }
        return phase.entries.back();
    }

    void phase() {
        auto& stage = current_stage();
        if (stage.phases.size() >= max_phases) throw ParseFailure{ErrorCode::unsupported, "more than 100 phases"};
        stage.phases.emplace_back();
        auto& phase = stage.phases.back();
        // Entries not yet opened keep the x of the stage reset or of the latest `bound:`.
        std::int32_t unopened_x = 500;
        do {
            next_in("<phase>");
            if (word_ == "bound:") {
                read_int(phase.bound);
                unopened_x = phase.bound + 80;
                for (auto& entry : phase.entries) entry.x = unopened_x;
            }
            if (word_ == "id:") {
                if (phase.entries.size() >= max_entries) {
                    throw ParseFailure{ErrorCode::unsupported, "more than 60 entries in a phase"};
                }
                Entry entry;
                entry.x = unopened_x;
                phase.entries.push_back(entry);
                read_int(phase.entries.back().id);
            }
            if (word_ == "music:") {
                std::string music;
                if (stream_.word(music, music_capacity)) phase.music = std::move(music);
            }
            if (word_ == "x:") read_int(current_entry(phase).x);
            if (word_ == "hp:") read_int(current_entry(phase).hp);
            if (word_ == "times:") read_int(current_entry(phase).times);
            if (word_ == "reserve:") read_int(current_entry(phase).reserve);
            if (word_ == "<boss>") current_entry(phase).kind = EntryKind::boss;
            if (word_ == "join:") read_int(current_entry(phase).join);
            if (word_ == "join_reserve:") read_int(current_entry(phase).join_reserve);
            if (word_ == "<soldier>") {
                auto& entry = current_entry(phase);
                entry.kind = EntryKind::soldier;
                entry.times = 50;
            }
            if (word_ == "when_clear_goto_phase:") read_int(phase.when_clear_goto_phase);
            if (word_ == "ratio:") {
                if (stream_.real(current_entry(phase).ratio) == TokenStream::Scan::mismatch) {
                    note("`ratio:` expects a number; value left unchanged");
                }
            }
            if (word_ == "y:") read_int(current_entry(phase).y);
            if (word_ == "act:") read_int(current_entry(phase).act);
        } while (word_ != "<phase_end>");
    }

    TokenStream stream_;
    StageList list_;
    std::string word_;
    std::int32_t current_ = -1;
};

ScriptValue integer(std::int32_t value) { return ScriptValue{value}; }
}

Result<StageList> parse(std::string_view text) {
    Parser parser(text);
    try {
        return parser.run();
    } catch (const ParseFailure& failure) {
        return fail(failure.code, "line " + std::to_string(parser.line()) + ": " + failure.message);
    }
}

Result<StageList> load(const ResourceSource& resources, std::string_view path) {
    auto bytes = read_data_text(resources, path, max_input);
    if (!bytes) return std::unexpected(bytes.error());
    auto parsed = parse(std::string_view(bytes->data(), bytes->size()));
    if (!parsed) parsed.error().message = std::string(path) + ": " + parsed.error().message;
    return parsed;
}

ScriptValue to_script_value(const StageList& list) {
    ScriptTable stages;
    for (std::size_t id = 0; id < list.stages.size(); ++id) {
        if (!list.stages[id]) continue;
        ScriptTable phases;
        for (std::size_t index = 0; index < list.stages[id]->phases.size(); ++index) {
            const auto& phase = list.stages[id]->phases[index];
            ScriptTable entries;
            for (std::size_t position = 0; position < phase.entries.size(); ++position) {
                const auto& entry = phase.entries[position];
                set_field(entries, static_cast<std::int32_t>(position + 1),
                          ScriptValue{ScriptTable{{"id", integer(entry.id)}, {"x", integer(entry.x)},
                              {"hp", integer(entry.hp)}, {"times", integer(entry.times)},
                              {"reserve", integer(entry.reserve)}, {"join", integer(entry.join)},
                              {"join_reserve", integer(entry.join_reserve)}, {"act", integer(entry.act)},
                              {"y", integer(entry.y)}, {"ratio", ScriptValue{entry.ratio}},
                              {"kind", integer(static_cast<std::int32_t>(entry.kind))}}});
            }
            set_field(phases, static_cast<std::int32_t>(index),
                      ScriptValue{ScriptTable{{"bound", integer(phase.bound)}, {"music", ScriptValue{phase.music}},
                          {"when_clear_goto_phase", integer(phase.when_clear_goto_phase)},
                          {"entry_count", integer(static_cast<std::int32_t>(phase.entries.size()))},
                          {"entries", ScriptValue{std::move(entries)}}}});
        }
        set_field(stages, static_cast<std::int32_t>(id),
                  ScriptValue{ScriptTable{{"phase_count", integer(static_cast<std::int32_t>(list.stages[id]->phases.size()))},
                                          {"phases", ScriptValue{std::move(phases)}}}});
    }
    ScriptTable diagnostics;
    for (std::size_t index = 0; index < list.diagnostics.size(); ++index) {
        set_field(diagnostics, static_cast<std::int32_t>(index + 1), ScriptValue{list.diagnostics[index]});
    }
    return ScriptValue{ScriptTable{{"stages", ScriptValue{std::move(stages)}},
                                   {"diagnostics", ScriptValue{std::move(diagnostics)}}}};
}
}
