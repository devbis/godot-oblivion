/*
 * BSA 103 archive reader.
 *
 * OpenMW format reference: components/bsa/compressedbsafile.cpp and
 * components/bsa/compressedbsafile.hpp, Copyright (C) 2008-2010 Nicolay
 * Korslund; compressed BSA work Copyright (C) 2018 cc9cii. OpenMW's BSA
 * implementation is distributed under GPL-3.0. This file independently
 * implements the TES4 layout and compression rules.
 */
#include "oblivion/bsa_archive.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>

#include "inflate_bounded.hpp"

namespace oblivion {

struct BsaArchive::Stream {
    explicit Stream(const std::filesystem::path& path) : input(path, std::ios::binary | std::ios::ate) {}

    std::ifstream input;
    std::mutex mutex;
};

namespace {

constexpr std::uint32_t kBsaMagic = 0x00415342; // "BSA\0"
constexpr std::uint32_t kTes4Version = 0x67;
constexpr std::uint32_t kFolderNames = 0x0001;
constexpr std::uint32_t kFileNames = 0x0002;
constexpr std::uint32_t kArchiveCompress = 0x0004;
constexpr std::uint32_t kEmbeddedNames = 0x0100;
constexpr std::uint32_t kCompressedSizeBit = 0x40000000;
constexpr std::size_t kHeaderSize = 36;

class StreamReader {
public:
    StreamReader(std::ifstream& input, std::uint64_t size) : input_(input), size_(size) {}

    void seek(std::uint64_t position, std::string_view what) {
        if (position > size_ || position > static_cast<std::uint64_t>(std::numeric_limits<std::streamoff>::max()))
            throw std::runtime_error("BSA " + std::string(what) + " offset is out of bounds");
        input_.clear();
        input_.seekg(static_cast<std::streamoff>(position));
        if (!input_) throw std::runtime_error("cannot seek to BSA " + std::string(what));
        position_ = position;
    }

    void read(void* target, std::size_t length, std::string_view what) {
        if (position_ > size_ || length > size_ - position_)
            throw std::runtime_error("BSA " + std::string(what) + " is out of bounds");
        if (length > static_cast<std::size_t>(std::numeric_limits<std::streamsize>::max()))
            throw std::runtime_error("BSA " + std::string(what) + " is too large");
        input_.read(static_cast<char*>(target), static_cast<std::streamsize>(length));
        if (!input_) throw std::runtime_error("cannot read BSA " + std::string(what));
        position_ += length;
    }

    void skip(std::uint64_t length, std::string_view what) {
        if (position_ > size_ || length > size_ - position_)
            throw std::runtime_error("BSA " + std::string(what) + " is out of bounds");
        seek(position_ + length, what);
    }

    std::uint8_t u8(std::string_view what) {
        std::uint8_t result = 0;
        read(&result, sizeof(result), what);
        return result;
    }

    std::uint32_t u32(std::string_view what) {
        std::array<std::uint8_t, 4> bytes{};
        read(bytes.data(), bytes.size(), what);
        return static_cast<std::uint32_t>(bytes[0])
            | (static_cast<std::uint32_t>(bytes[1]) << 8)
            | (static_cast<std::uint32_t>(bytes[2]) << 16)
            | (static_cast<std::uint32_t>(bytes[3]) << 24);
    }

    std::uint64_t u64(std::string_view what) {
        const auto low = u32(what);
        const auto high = u32(what);
        return static_cast<std::uint64_t>(low) | (static_cast<std::uint64_t>(high) << 32);
    }

    std::string name(std::size_t length, std::string_view what) {
        std::string result(length, '\0');
        if (length != 0) read(result.data(), length, what);
        const auto nul = result.find('\0');
        if (nul == std::string::npos)
            throw std::runtime_error("BSA " + std::string(what) + " has no null terminator");
        result.resize(nul);
        return result;
    }

    [[nodiscard]] std::uint64_t position() const noexcept { return position_; }

private:
    std::ifstream& input_;
    std::uint64_t size_;
    std::uint64_t position_ = 0;
};

struct FolderRecord { std::uint64_t hash; std::uint32_t count; };
struct FileRecord { std::uint64_t hash; std::uint32_t size; std::uint32_t offset; };

} // namespace

std::string normalize_asset_path(std::string_view path) {
    std::string result;
    result.reserve(path.size());
    for (unsigned char value : path) {
        char c = static_cast<char>(value);
        if (c == '/') c = '\\';
        result.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
    }
    while (!result.empty() && result.front() == '\\') result.erase(result.begin());
    return result;
}

void BsaArchive::open(const std::filesystem::path& path) {
    auto stream = std::make_shared<Stream>(path);
    if (!stream->input) throw std::runtime_error("cannot open " + path.string());
    const auto end = stream->input.tellg();
    if (end < 0 || static_cast<std::uint64_t>(end) < kHeaderSize)
        throw std::runtime_error("BSA header is truncated: " + path.string());
    const auto archive_size = static_cast<std::uint64_t>(end);
    StreamReader reader(stream->input, archive_size);
    reader.seek(0, "header");
    const auto magic = reader.u32("magic");
    const auto version = reader.u32("version");
    const auto folder_offset = reader.u32("folder table");
    const auto archive_flags = reader.u32("archive flags");
    const auto folder_count = reader.u32("folder count");
    const auto declared_file_count = reader.u32("file count");
    auto folder_names_remaining = reader.u32("folder name byte count");
    auto file_names_remaining = reader.u32("file name byte count");
    (void)reader.u32("file flags");

    if (magic != kBsaMagic)
        throw std::runtime_error("not a Bethesda BSA archive: " + path.string());
    if (version != kTes4Version)
        throw std::runtime_error("only Oblivion BSA version 103 is supported: " + path.string());
    if (!(archive_flags & kFileNames))
        throw std::runtime_error("BSA archives without a filename table are not supported: " + path.string());
    if (folder_count > 1'000'000 || declared_file_count > 10'000'000)
        throw std::runtime_error("BSA directory counts are unreasonable");

    reader.seek(folder_offset, "folder table");
    std::vector<FolderRecord> folders;
    folders.reserve(folder_count);
    for (std::uint32_t i = 0; i < folder_count; ++i) {
        const auto hash = reader.u64("folder record");
        const auto count = reader.u32("folder record");
        (void)reader.u32("folder record offset");
        folders.push_back({hash, count});
    }

    std::vector<std::pair<std::string, std::vector<FileRecord>>> folder_contents;
    folder_contents.reserve(folders.size());
    std::uint64_t total_files = 0;
    for (const auto& folder : folders) {
        std::string folder_name;
        if (archive_flags & kFolderNames) {
            const auto length = reader.u8("folder name length");
            if (length > folder_names_remaining)
                throw std::runtime_error("BSA folder name length exceeds header total");
            folder_name = reader.name(length, "folder name");
            folder_names_remaining -= length;
        }
        if (folder.count > declared_file_count || total_files + folder.count > declared_file_count)
            throw std::runtime_error("BSA folder file count exceeds header total");
        total_files += folder.count;
        std::vector<FileRecord> files;
        files.reserve(folder.count);
        for (std::uint32_t i = 0; i < folder.count; ++i)
            files.push_back({reader.u64("file record"), reader.u32("file record"), reader.u32("file record")});
        folder_contents.emplace_back(std::move(folder_name), std::move(files));
    }
    if (total_files != declared_file_count)
        throw std::runtime_error("BSA file count does not match its folder records");
    reader.skip(folder_names_remaining, "remaining folder names");

    std::vector<std::vector<std::string>> filenames(folder_contents.size());
    for (std::size_t i = 0; i < folder_contents.size(); ++i) {
        filenames[i].reserve(folder_contents[i].second.size());
        for (std::size_t j = 0; j < folder_contents[i].second.size(); ++j) {
            const auto name_start = reader.position();
            std::string name;
            bool terminated = false;
            while (reader.position() - name_start < file_names_remaining) {
                const char ch = static_cast<char>(reader.u8("filename table"));
                if (ch == '\0') { terminated = true; break; }
                name.push_back(ch);
            }
            if (!terminated) throw std::runtime_error("BSA filename is unterminated");
            const auto consumed = static_cast<std::uint32_t>(name.size() + 1);
            if (consumed > file_names_remaining) throw std::runtime_error("BSA filename table overrun");
            file_names_remaining -= consumed;
            filenames[i].push_back(std::move(name));
        }
    }

    std::map<std::string, Entry, std::less<>> entries;
    for (std::size_t i = 0; i < folder_contents.size(); ++i) {
        const auto& folder = folder_contents[i].first;
        const auto& files = folder_contents[i].second;
        for (std::size_t j = 0; j < files.size(); ++j) {
            std::string full_path = folder;
            if (!full_path.empty() && !filenames[i][j].empty()) full_path.push_back('\\');
            full_path += filenames[i][j];
            const auto& record = files[j];
            const auto plain_size = record.size & ~kCompressedSizeBit;
            if (record.offset > archive_size || plain_size > archive_size - record.offset)
                throw std::runtime_error("BSA entry offset is outside the archive");
            const auto normalized_path = normalize_asset_path(full_path);
            entries[normalized_path] = Entry{
                plain_size, record.offset, (record.size & kCompressedSizeBit) != 0, normalized_path};
        }
    }

    path_ = path;
    archive_size_ = archive_size;
    archive_flags_ = archive_flags;
    entries_ = std::move(entries);
    stream_ = std::move(stream);
}

bool BsaArchive::contains(std::string_view asset_path) const {
    return entries_.find(normalize_asset_path(asset_path)) != entries_.end();
}

std::vector<std::string> BsaArchive::list_paths(std::string_view prefix) const {
    const auto normalized_prefix = normalize_asset_path(prefix);
    std::vector<std::string> result;
    for (const auto& [path, entry] : entries_) {
        (void)entry;
        if (normalized_prefix.empty() || path.starts_with(normalized_prefix))
            result.push_back(path);
    }
    return result;
}

std::vector<std::uint8_t> BsaArchive::read(std::string_view asset_path) const {
    const auto it = entries_.find(normalize_asset_path(asset_path));
    if (it == entries_.end())
        throw std::runtime_error("asset not found in " + path_.string() + ": " + std::string(asset_path));
    return read_entry(it->second);
}

std::vector<std::uint8_t> BsaArchive::read_entry(const Entry& entry) const {
    if (!stream_) throw std::runtime_error("BSA archive is not open: " + path_.string());
    std::scoped_lock lock(stream_->mutex);
    StreamReader reader(stream_->input, archive_size_);
    std::uint64_t cursor = entry.offset;
    std::size_t stored_size = entry.stored_size;
    if (archive_flags_ & kEmbeddedNames) {
        reader.seek(cursor, "embedded asset name");
        const auto name_length = reader.u8("embedded asset name length");
        if (name_length > 0 && static_cast<std::size_t>(name_length) + 1 <= stored_size) {
            std::string embedded_name(name_length, '\0');
            reader.read(embedded_name.data(), embedded_name.size(), "embedded asset name");
            if (!embedded_name.empty() && embedded_name.back() == '\0') embedded_name.pop_back();
            const auto normalized_name = normalize_asset_path(embedded_name);
            const auto separator = entry.path.find_last_of('\\');
            const auto basename = separator == std::string::npos ? entry.path : entry.path.substr(separator + 1);
            if (normalized_name == entry.path || normalized_name == basename) {
                const auto prefix_size = static_cast<std::size_t>(name_length) + 1;
                cursor += prefix_size;
                stored_size -= prefix_size;
            }
        }
    }

    const bool compressed = entry.size_compression_override != ((archive_flags_ & kArchiveCompress) != 0);
    reader.seek(cursor, "asset payload");
    if (!compressed) {
        std::vector<std::uint8_t> result(stored_size);
        if (!result.empty()) reader.read(result.data(), result.size(), "asset payload");
        return result;
    }
    if (stored_size < 4) throw std::runtime_error("BSA compressed entry lacks an output size");
    const auto output_size = reader.u32("compressed asset output size");
    stored_size -= 4;
    std::vector<std::uint8_t> compressed_data(stored_size);
    if (!compressed_data.empty()) reader.read(compressed_data.data(), compressed_data.size(), "compressed asset");
    return inflate_bounded(compressed_data.data(), compressed_data.size(), output_size,
                           "BSA entry in " + path_.string());
}

} // namespace oblivion
