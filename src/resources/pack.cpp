// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/resources/pack.hpp"
#include "openlf2/core/binary.hpp"
#include "openlf2/core/files.hpp"
#include "openlf2/resources/installer.hpp"
#include <algorithm>
#include <optional>
#include <system_error>
#include <vector>

namespace openlf2 {
namespace {
constexpr std::uint32_t end_signature = 0x06054b50;
constexpr std::uint32_t central_signature = 0x02014b50;
constexpr std::uint32_t local_signature = 0x04034b50;
constexpr std::size_t end_size = 22;
constexpr std::size_t central_size = 46;
constexpr std::size_t local_size = 30;
constexpr std::size_t max_comment = 65535;
constexpr std::size_t max_directory = 32 * 1024 * 1024;
constexpr std::size_t max_entries = 65535;
constexpr std::uint32_t max_entry_size = 256 * 1024 * 1024; // the decompressor's limit

Result<Bytes> read_range(std::ifstream& file, std::uintmax_t offset, std::size_t size) {
    Bytes bytes(size);
    file.clear();
    file.seekg(static_cast<std::streamoff>(offset));
    if (!file || !file.read(bytes.data(), static_cast<std::streamsize>(size))) {
        return fail(ErrorCode::io, "game pack: short read at " + std::to_string(offset));
    }
    return bytes;
}
std::string lower(std::string text) {
    for (auto& character : text) {
        if (character >= 'A' && character <= 'Z') character = static_cast<char>(character - 'A' + 'a');
    }
    return text;
}
// A game folder: at most as many files as a pack, this deep (a mod's folders are a few levels at most).
constexpr std::size_t max_folder_files = 100000;
constexpr int max_folder_depth = 16;
// A path's UTF-8 text; messages and names never go through the Windows code page, where a folder named in another
// script cannot be written.
std::string utf8(const std::filesystem::path& path) {
    const auto text = path.generic_u8string();
    return {text.begin(), text.end()};
}
// The entry of `directory` named `name` (lowercase ASCII) in any case.
std::optional<std::filesystem::path> child(const std::filesystem::path& directory, std::string_view name) {
    std::error_code error;
    std::filesystem::directory_iterator entries(directory, std::filesystem::directory_options::skip_permission_denied, error);
    if (error) return std::nullopt;
    for (const std::filesystem::directory_iterator end{}; entries != end; entries.increment(error)) {
        if (error) return std::nullopt;
        if (lower(utf8(entries->path().filename())) == name) return entries->path();
    }
    return std::nullopt;
}
Result<Bytes> read_whole(const std::filesystem::path& file, const std::string& name) {
    std::ifstream stream(file, std::ios::binary | std::ios::ate);
    if (!stream) return fail(ErrorCode::io, "cannot open " + name + " in the game folder");
    const auto end = stream.tellg();
    if (end < 0) return fail(ErrorCode::io, "cannot read " + name + " in the game folder");
    if (static_cast<std::uintmax_t>(end) > max_entry_size) return fail(ErrorCode::limit, name + " exceeds 256 MiB");
    Bytes bytes(static_cast<std::size_t>(end));
    stream.seekg(0);
    if (!stream.read(bytes.data(), static_cast<std::streamsize>(bytes.size()))) {
        return fail(ErrorCode::io, "short read of " + name + " in the game folder");
    }
    return bytes;
}
}

bool is_game_folder(const std::filesystem::path& directory) {
    const auto data = child(directory, "data");
    std::error_code error;
    if (!data || !std::filesystem::is_directory(*data, error)) return false;
    const auto listing = child(*data, "data.txt");
    return listing && std::filesystem::is_regular_file(*listing, error);
}

Result<std::unique_ptr<PackFolder>> PackFolder::open(const std::filesystem::path& path) {
    std::unique_ptr<PackFolder> folder(new PackFolder());
    auto indexed = folder->index(path);
    if (!indexed) return std::unexpected(indexed.error());
    return folder;
}

Result<void> PackFolder::index(const std::filesystem::path& path) {
    std::error_code error;
    if (!std::filesystem::is_directory(path, error)) return fail(ErrorCode::io, "the game folder is not a folder");
    struct Found {
        std::string name; // UTF-8, from the folder, '/' between parts
        std::filesystem::path file;
    };
    std::vector<Found> found;
    std::filesystem::recursive_directory_iterator entries(path, std::filesystem::directory_options::skip_permission_denied, error);
    if (error) return fail(ErrorCode::io, "cannot list the game folder: " + error.message());
    for (const std::filesystem::recursive_directory_iterator end{}; entries != end; entries.increment(error)) {
        if (error) return fail(ErrorCode::io, "cannot list the game folder: " + error.message());
        std::error_code type;
        if (entries->is_directory(type)) {
            if (entries.depth() >= max_folder_depth) entries.disable_recursion_pending();
            continue;
        }
        if (!entries->is_regular_file(type)) continue;
        if (found.size() == max_folder_files) return fail(ErrorCode::limit, "the game folder has too many files");
        found.push_back({utf8(entries->path().lexically_relative(path)), entries->path()});
    }
    // The game folder is the one holding data/data.txt nearest the top, as in a pack.
    std::optional<std::string> root;
    for (const auto& item : found) {
        const auto name = lower(item.name);
        constexpr std::string_view marker = "data/data.txt";
        if (name.size() < marker.size() || name.compare(name.size() - marker.size(), marker.size(), marker) != 0) continue;
        const auto folder = name.substr(0, name.size() - marker.size());
        if (!folder.empty() && folder.back() != '/') continue;
        if (!root || folder.size() < root->size()) root = folder;
    }
    if (!root) return fail(ErrorCode::format, "no data/data.txt in the game folder");
    std::vector<std::pair<std::string, std::uintmax_t>> executables;
    for (auto& item : found) {
        // Files outside the game folder and names a game cannot ask for (not printable ASCII) are skipped; the first
        // of names differing only in case wins.
        if (item.name.size() <= root->size() || lower(item.name.substr(0, root->size())) != *root) continue;
        auto normalized = virtual_path(std::string_view(item.name).substr(root->size()));
        if (!normalized) continue;
        if (normalized->find('/') == std::string::npos && normalized->ends_with(".exe")) {
            std::error_code size_error;
            const auto size = std::filesystem::file_size(item.file, size_error);
            if (!size_error && !files_.contains(*normalized)) executables.emplace_back(*normalized, size);
        }
        files_.emplace(std::move(*normalized), std::move(item.file));
    }
    // lf2.exe first, then the largest: the first with LF2's pictures (WORDS0) is the game's. OpenLF2's program, there
    // when the folder is a published mod, has none and names itself.
    std::stable_sort(executables.begin(), executables.end(), [](const auto& a, const auto& b) {
        if ((a.first == "lf2.exe") != (b.first == "lf2.exe")) return a.first == "lf2.exe";
        return a.second > b.second;
    });
    std::string fallback;
    for (const auto& candidate : executables) {
        auto bytes = read_whole(files_.at(candidate.first), candidate.first);
        if (!bytes) continue;
        if (bitmap_resource(*bytes, "WORDS0")) {
            executable_ = candidate.first;
            break;
        }
        constexpr std::string_view own_name = "OpenLF2";
        if (fallback.empty() && std::string_view(bytes->data(), bytes->size()).find(own_name) == std::string_view::npos) {
            fallback = candidate.first;
        }
    }
    if (executable_.empty()) executable_ = fallback;
    if (executable_.empty()) return fail(ErrorCode::format, "no game executable (lf2.exe) at the top of the game folder");
    if (executable_ != "lf2.exe") files_.insert_or_assign("lf2.exe", std::filesystem::path(files_.at(executable_)));
    return {};
}

Result<Bytes> PackFolder::read(std::string_view path) const {
    auto normalized = virtual_path(path);
    if (!normalized) return std::unexpected(normalized.error());
    const auto found = files_.find(*normalized);
    if (found == files_.end()) return fail(ErrorCode::io, "game folder resource missing: " + *normalized);
    return read_whole(found->second, *normalized);
}

PackArchive::PackArchive(const std::filesystem::path& path, const Decompressor& decompressor)
    : decompressor_(decompressor), file_(path, std::ios::binary) {}

Result<std::unique_ptr<PackArchive>> PackArchive::open(const std::filesystem::path& path,
                                                       const Decompressor& decompressor) {
    std::unique_ptr<PackArchive> archive(new PackArchive(path, decompressor));
    if (!archive->file_) return fail(ErrorCode::io, "cannot open game pack " + path.string());
    std::error_code error;
    archive->file_size_ = std::filesystem::file_size(path, error);
    if (error) return fail(ErrorCode::io, "cannot read game pack " + path.string() + ": " + error.message());
    auto indexed = archive->index();
    if (!indexed) {
        indexed.error().message = path.filename().string() + ": " + indexed.error().message;
        return std::unexpected(indexed.error());
    }
    return archive;
}

Result<void> PackArchive::index() {
    try {
        if (file_size_ < end_size) throw FormatError("not a ZIP file (too short)");
        if (file_size_ > 0xffffffffULL) throw FormatError("ZIP files over 4 GiB are not supported");
        // The end record is within the last 22 bytes plus the longest comment.
        const auto tail_size = static_cast<std::size_t>(std::min<std::uintmax_t>(file_size_, end_size + max_comment));
        auto tail = read_range(file_, file_size_ - tail_size, tail_size);
        if (!tail) return std::unexpected(tail.error());
        const BinaryView tail_view(*tail);
        std::optional<std::size_t> end;
        for (std::size_t position = tail_size - end_size + 1; position-- > 0;) {
            if (tail_view.u32(position) == end_signature && position + end_size + tail_view.u16(position + 20) == tail_size) {
                end = position;
                break;
            }
        }
        if (!end) throw FormatError("not a ZIP file (no end of central directory)");
        const auto entry_count = tail_view.u16(*end + 10);
        const auto directory_size = tail_view.u32(*end + 12);
        const auto directory_offset = tail_view.u32(*end + 16);
        if (tail_view.u16(*end + 4) != 0 || tail_view.u16(*end + 6) != 0 || tail_view.u16(*end + 8) != entry_count) {
            throw FormatError("split ZIP files are not supported");
        }
        if (entry_count == 0xffff || directory_size == 0xffffffffU || directory_offset == 0xffffffffU) {
            throw FormatError("ZIP64 files are not supported");
        }
        if (directory_size > max_directory || std::uintmax_t{directory_offset} + directory_size > file_size_) {
            throw FormatError("invalid central directory");
        }
        auto directory = read_range(file_, directory_offset, directory_size);
        if (!directory) return std::unexpected(directory.error());
        const BinaryView view(*directory);
        struct Found {
            std::string name;
            Entry entry;
        };
        std::vector<Found> found;
        std::size_t cursor = 0;
        for (std::size_t index = 0; index < entry_count; ++index) {
            if (view.u32(cursor) != central_signature) throw FormatError("invalid central directory entry");
            const auto flags = view.u16(cursor + 8);
            const auto method = view.u16(cursor + 10);
            const auto compressed = view.u32(cursor + 20);
            const auto size = view.u32(cursor + 24);
            const auto name_length = view.u16(cursor + 28);
            const auto extra_length = view.u16(cursor + 30);
            const auto comment_length = view.u16(cursor + 32);
            const auto offset = view.u32(cursor + 42);
            auto name = view.text(cursor + central_size, name_length);
            cursor += central_size + name_length + extra_length + comment_length;
            if (name.empty() || name.back() == '/' || name.back() == '\\') continue; // a folder
            if (flags & 1) throw FormatError("encrypted ZIP entries are not supported: " + name);
            if (method != 0 && method != 8) {
                throw FormatError("ZIP entry " + name + " uses an unsupported compression method (use Deflate)");
            }
            if (size > max_entry_size) throw FormatError("ZIP entry " + name + " exceeds 256 MiB");
            found.push_back({std::move(name), Entry{offset, compressed, size,
                method == 8 ? Compression::deflate : Compression::stored}});
        }
        if (found.empty()) throw FormatError("the ZIP file is empty");
        if (found.size() > max_entries) throw FormatError("too many ZIP entries");
        // The game folder is the one holding data/data.txt nearest the top (a zipped game folder, maybe
        // with notes beside it or an older copy of the game inside); paths start from there.
        std::optional<std::string> root;
        for (const auto& item : found) {
            const auto name = lower(item.name);
            constexpr std::string_view marker = "data/data.txt";
            constexpr std::string_view marker_backslash = "data\\data.txt";
            for (const auto suffix : {marker, marker_backslash}) {
                if (name.size() < suffix.size() || name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0) continue;
                const auto folder = item.name.substr(0, name.size() - suffix.size());
                if (!folder.empty() && folder.back() != '/' && folder.back() != '\\') continue;
                if (!root || folder.size() < root->size()) root = folder;
            }
        }
        if (!root) throw FormatError("no data/data.txt in the pack");
        const auto prefix = *root;
        std::vector<std::pair<std::string, std::uint32_t>> executables;
        for (auto& item : found) {
            // Files outside the game folder and names a game cannot ask for (not printable ASCII)
            // are skipped; the first of names differing only in case wins.
            if (item.name.size() <= prefix.size() || lower(item.name.substr(0, prefix.size())) != lower(prefix)) continue;
            auto normalized = virtual_path(std::string_view(item.name).substr(prefix.size()));
            if (!normalized) continue;
            if (normalized->find('/') == std::string::npos && normalized->ends_with(".exe")) {
                executables.emplace_back(*normalized, item.entry.size);
            }
            entries_.emplace(std::move(*normalized), item.entry);
        }
        if (entries_.contains("lf2.exe")) {
            executable_ = "lf2.exe";
        } else if (executables.size() == 1) {
            executable_ = executables.front().first;
            entries_.emplace("lf2.exe", entries_.at(executable_));
        } else if (!executables.empty()) {
            // Several: the largest with LF2's pictures (WORDS0) is the game's, as in a game folder (PackFolder). A
            // published mod zipped up holds OpenLF2's program too, larger than the game and naming itself; with no
            // pictures anywhere, the largest that is not OpenLF2's (the error about a packed game comes later).
            std::stable_sort(executables.begin(), executables.end(),
                [](const auto& a, const auto& b) { return a.second > b.second; });
            std::string fallback;
            for (const auto& candidate : executables) {
                auto bytes = read(candidate.first);
                if (!bytes) continue;
                if (bitmap_resource(*bytes, "WORDS0")) {
                    executable_ = candidate.first;
                    break;
                }
                constexpr std::string_view own_name = "OpenLF2";
                if (fallback.empty() && std::string_view(bytes->data(), bytes->size()).find(own_name) == std::string_view::npos) {
                    fallback = candidate.first;
                }
            }
            if (executable_.empty()) executable_ = fallback.empty() ? executables.front().first : fallback;
            entries_.emplace("lf2.exe", entries_.at(executable_));
        } else {
            throw FormatError("no game executable (lf2.exe) at the top of the pack");
        }
        return {};
    } catch (const FormatError& error) {
        return fail(ErrorCode::format, error.what());
    }
}

Result<Bytes> PackArchive::read(std::string_view path) const {
    auto normalized = virtual_path(path);
    if (!normalized) return std::unexpected(normalized.error());
    const auto found = entries_.find(*normalized);
    if (found == entries_.end()) return fail(ErrorCode::io, "game pack resource missing: " + *normalized);
    const auto& entry = found->second;
    Bytes compressed;
    {
        std::lock_guard lock(mutex_);
        auto header = read_range(file_, entry.header_offset, local_size);
        if (!header) return std::unexpected(header.error());
        const BinaryView view(*header);
        if (view.u32(0) != local_signature) return fail(ErrorCode::format, *normalized + ": invalid ZIP entry header");
        const auto data = std::uintmax_t{entry.header_offset} + local_size + view.u16(26) + view.u16(28);
        if (data + entry.compressed_size > file_size_) return fail(ErrorCode::format, *normalized + ": ZIP entry outside the file");
        auto bytes = read_range(file_, data, entry.compressed_size);
        if (!bytes) return std::unexpected(bytes.error());
        compressed = std::move(*bytes);
    }
    auto result = decompressor_.decode(entry.method, compressed, entry.size);
    if (!result) result.error().message = *normalized + ": " + result.error().message;
    return result;
}
}
