/*
 * BSA 103 archive reader. The TES4 record layout and compression rules were
 * cross-checked against OpenMW's components/bsa implementation. This file is
 * an independent, bounded reader for the subset used by Oblivion.
 */
#pragma once

#include <cstdint>
#include <filesystem>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace oblivion {

class BsaArchive {
public:
    void open(const std::filesystem::path& path);
    [[nodiscard]] bool contains(std::string_view asset_path) const;
    [[nodiscard]] std::vector<std::uint8_t> read(std::string_view asset_path) const;
    [[nodiscard]] std::vector<std::string> list_paths(std::string_view prefix = {}) const;
    [[nodiscard]] std::size_t file_count() const noexcept { return entries_.size(); }
    [[nodiscard]] const std::filesystem::path& path() const noexcept { return path_; }

private:
    struct Entry {
        std::uint32_t stored_size = 0;
        std::uint32_t offset = 0;
        bool size_compression_override = false;
        std::string path;
    };

    [[nodiscard]] std::vector<std::uint8_t> read_entry(const Entry& entry) const;

    std::filesystem::path path_;
    std::uint64_t archive_size_ = 0;
    std::uint32_t archive_flags_ = 0;
    std::map<std::string, Entry, std::less<>> entries_;
};

[[nodiscard]] std::string normalize_asset_path(std::string_view path);

} // namespace oblivion
