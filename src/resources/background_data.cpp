// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/resources/background_data.hpp"
#include "openlf2/resources/data_file.hpp"
#include "openlf2/detail/resources/scan_stream.hpp"

namespace openlf2::background_data {
namespace {
using scanning::ParseFailure;
using scanning::TokenStream;
constexpr std::size_t word_capacity = 100;
constexpr std::size_t max_diagnostics = 64;
constexpr std::size_t max_input = 1024 * 1024;

class Parser {
public:
    explicit Parser(std::string_view text) : stream_(text) {
        stream_.on_overrun([this](std::string message) { note(std::move(message)); });
    }

    Background run() {
        bool first = true;
        while (!stream_.at_end()) {
            // At EOF the previous word is evaluated again, as in the original loop.
            if (!stream_.word(word_, word_capacity) && first) {
                throw ParseFailure{ErrorCode::format, "background description contains no words"};
            }
            first = false;
            scanning::add_token_checksum(data_.token_checksum, word_);
            if (word_ == "name:") name();
            else if (word_ == "width:") read_int(data_.width);
            else if (word_ == "zboundary:") read_pair(data_.zboundary);
            else if (word_ == "perspective:") {
                if (read_int(data_.perspective[0])) read_int(data_.perspective[1]);
            } else if (word_ == "shadow:") shadow();
            else if (word_ == "layer:") layer();
            else if (word_ != "layer_end") note("ignored word `" + word_ + "`");
        }
        return std::move(data_);
    }

    [[nodiscard]] std::size_t line() const { return stream_.line(); }

private:
    void note(std::string message) {
        if (data_.diagnostics.size() < max_diagnostics) {
            data_.diagnostics.push_back("line " + std::to_string(stream_.line()) + ": " +
                                        std::move(message));
        }
    }
    bool read_int(std::int32_t& field) {
        const auto result = stream_.integer(field);
        if (result == TokenStream::Scan::mismatch) {
            note("`" + word_ + "` expects an integer; value left unchanged");
        }
        return result == TokenStream::Scan::value;
    }
    bool read_int(std::optional<std::int32_t>& field) {
        std::int32_t value = field.value_or(0);
        if (!read_int(value)) return false;
        field = value;
        return true;
    }
    void read_pair(std::array<std::optional<std::int32_t>, 2>& fields) {
        if (read_int(fields[0])) read_int(fields[1]);
    }

    void name() {
        std::string value;
        if (!stream_.word(value, word_capacity)) return;
        if (value.size() > 29) value.resize(29);
        for (auto& character : value) {
            if (character == '_') character = ' ';
        }
        data_.name = std::move(value);
    }

    // `%s %s %d %d`: path, a discarded word (`shadowsize:` in the files), width, height.
    void shadow() {
        std::string path;
        std::string ignored;
        if (!stream_.word(path, 40)) return;
        data_.shadow = std::move(path);
        if (!stream_.word(ignored, word_capacity)) return;
        read_pair(data_.shadow_size);
    }

    void layer() {
        if (data_.layers.size() == max_layers) {
            throw ParseFailure{ErrorCode::unsupported, "more than thirty background layers"};
        }
        auto& layer = data_.layers.emplace_back();
        if (!stream_.word(layer.path, 30)) unterminated();
        next_word();
        while (word_ != "layer_end") {
            if (word_ == "transparency:") read_int(layer.transparency);
            else if (word_ == "width:") read_int(layer.width);
            else if (word_ == "x:") read_int(layer.x);
            else if (word_ == "y:") read_int(layer.y);
            else if (word_ == "height:") read_int(layer.height);
            else if (word_ == "rect:") {
                // The original converts the field even when the read fails.
                read_int(layer.color);
                layer.color = convert_rgb565(layer.color);
            } else if (word_ == "rect32:") read_int(layer.color);
            else if (word_ == "loop:") read_int(layer.loop);
            else if (word_ == "cc:") read_int(layer.cc);
            else if (word_ == "c1:") read_int(layer.c1);
            else if (word_ == "c2:") read_int(layer.c2);
            else note("ignored layer word `" + word_ + "`");
            next_word();
        }
    }

    // The layer loop never tests EOF in the original, which would loop forever.
    void next_word() {
        if (!stream_.word(word_, word_capacity)) unterminated();
    }
    [[noreturn]] static void unterminated() {
        throw ParseFailure{ErrorCode::format, "unterminated layer: at end of file"};
    }

    TokenStream stream_;
    Background data_;
    std::string word_;
};

ScriptValue integer(std::int32_t value) { return ScriptValue{value}; }

void set_pair(ScriptTable& target, std::string key, const std::array<std::optional<std::int32_t>, 2>& values) {
    ScriptTable pair;
    for (std::size_t index = 0; index < values.size(); ++index) {
        if (values[index]) set_field(pair, static_cast<std::int32_t>(index + 1), integer(*values[index]));
    }
    set_field(target, std::move(key), ScriptValue{std::move(pair)});
}
}

std::int32_t convert_rgb565(std::int32_t value) {
    const auto red = (value >> 11) & 0x1f;
    const auto green = (value >> 5) & 0x3f;
    const auto blue = value & 0x1f;
    return ((red * 0x200 + green) * 0x80 + blue) * 8 + 0x070707;
}

Result<Background> parse(std::string_view text) {
    Parser parser(text);
    try {
        return parser.run();
    } catch (const ParseFailure& failure) {
        return fail(failure.code, "line " + std::to_string(parser.line()) + ": " + failure.message);
    }
}

Result<Background> load(const ResourceSource& resources, std::string_view path) {
    auto bytes = read_data_text(resources, path, max_input);
    if (!bytes) return std::unexpected(bytes.error());
    auto parsed = parse(std::string_view(bytes->data(), bytes->size()));
    if (!parsed) parsed.error().message = std::string(path) + ": " + parsed.error().message;
    return parsed;
}

ScriptValue to_script_value(const Background& background) {
    ScriptTable layers;
    for (std::size_t index = 0; index < background.layers.size(); ++index) {
        const auto& layer = background.layers[index];
        set_field(layers, static_cast<std::int32_t>(index + 1),
                  ScriptValue{ScriptTable{{"path", ScriptValue{layer.path}},
                      {"transparency", integer(layer.transparency)}, {"width", integer(layer.width)},
                      {"x", integer(layer.x)}, {"y", integer(layer.y)},
                      {"height", integer(layer.height)}, {"color", integer(layer.color)},
                      {"loop", integer(layer.loop)}, {"cc", integer(layer.cc)},
                      {"c1", integer(layer.c1)}, {"c2", integer(layer.c2)}}});
    }
    ScriptTable diagnostics;
    for (std::size_t index = 0; index < background.diagnostics.size(); ++index) {
        set_field(diagnostics, static_cast<std::int32_t>(index + 1), ScriptValue{background.diagnostics[index]});
    }
    ScriptTable result{{"perspective", ScriptValue{ScriptTable{{1, integer(background.perspective[0])},
                                                               {2, integer(background.perspective[1])}}}},
                       {"layers", ScriptValue{std::move(layers)}},
                       {"token_checksum", integer(background.token_checksum)},
                       {"diagnostics", ScriptValue{std::move(diagnostics)}}};
    if (background.name) set_field(result, "name", ScriptValue{*background.name});
    if (background.width) set_field(result, "width", integer(*background.width));
    if (background.shadow) set_field(result, "shadow", ScriptValue{*background.shadow});
    set_pair(result, "zboundary", background.zboundary);
    set_pair(result, "shadow_size", background.shadow_size);
    return ScriptValue{std::move(result)};
}
}
