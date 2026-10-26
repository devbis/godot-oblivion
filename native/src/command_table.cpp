#include "oblivion/command_table.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <system_error>
#include <cctype>
#include <cstring>
#include <fstream>
#include <iterator>
#include <limits>
#include <map>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string_view>

namespace oblivion {
namespace {

constexpr std::size_t kEntrySize = 40;
constexpr std::uint32_t kMinOpcode = 0x1000;
constexpr std::uint32_t kMaxOpcode = 0x4000;
constexpr std::uint32_t kMaxParameters = 20;
constexpr std::size_t kMaxNameLength = 256;
constexpr std::string_view kCacheTrailer = "end";
constexpr std::string_view kCacheHeader = "openob-command-table 2";

// Parameter type ids as the executable's command table stores them.
constexpr std::array<std::string_view, 38> kParameterTypeNames = {
    "String", "Integer", "Float", "ObjectID", "ObjectReferenceID", "ActorValue", "Actor",
    "SpellItem", "Axis", "Cell", "AnimationGroup", "MagicItem", "Sound", "Topic",
    "Quest", "Race", "Class", "Faction", "Sex", "Global", "Furniture", "Object",
    "VariableName", "Stage", "MapMarker", "ActorBase", "Container", "Worldspace",
    "CrimeType", "Package", "CombatStyle", "MagicEffect", "Birthsign", "FormType",
    "WeatherID", "NPC", "Owner", "EffectShader",
};

std::string parameter_type_name(std::uint32_t type_id) {
    if (type_id < kParameterTypeNames.size()) return std::string(kParameterTypeNames[type_id]);
    return std::to_string(type_id);
}

struct Section {
    std::uint32_t virtual_address = 0;
    std::uint32_t raw_size = 0;
    std::uint32_t raw_pointer = 0;
};

struct Image {
    std::uint32_t image_base = 0;
    std::vector<Section> sections;
};

class Executable {
public:
    explicit Executable(const std::vector<std::uint8_t>& bytes) : bytes_(bytes), image_(parse_image(bytes)) {}

    std::uint32_t u32(std::size_t offset) const {
        if (offset > bytes_.size() || bytes_.size() - offset < 4) throw std::runtime_error("command table: read past the end of the executable");
        return static_cast<std::uint32_t>(bytes_[offset]) | (static_cast<std::uint32_t>(bytes_[offset + 1]) << 8)
            | (static_cast<std::uint32_t>(bytes_[offset + 2]) << 16) | (static_cast<std::uint32_t>(bytes_[offset + 3]) << 24);
    }

    std::uint16_t u16(std::size_t offset) const {
        if (offset > bytes_.size() || bytes_.size() - offset < 2) throw std::runtime_error("command table: read past the end of the executable");
        return static_cast<std::uint16_t>(bytes_[offset] | (bytes_[offset + 1] << 8));
    }

    std::size_t size() const { return bytes_.size(); }

    // File offset of a virtual address, or nullopt when it is not backed by file data.
    std::optional<std::size_t> file_offset(std::uint64_t address) const {
        if (address < image_.image_base) return std::nullopt;
        const auto rva = address - image_.image_base;
        for (const auto& section : image_.sections) {
            if (rva >= section.virtual_address && rva - section.virtual_address < section.raw_size)
                return section.raw_pointer + (rva - section.virtual_address);
        }
        return std::nullopt;
    }

    // Virtual address of a file offset, or nullopt when it is outside every section.
    std::optional<std::uint32_t> address_of(std::size_t offset) const {
        for (const auto& section : image_.sections) {
            if (offset >= section.raw_pointer && offset - section.raw_pointer < section.raw_size)
                return image_.image_base + section.virtual_address + static_cast<std::uint32_t>(offset - section.raw_pointer);
        }
        return std::nullopt;
    }

    std::optional<std::string> c_string(std::uint64_t address) const {
        const auto start = file_offset(address);
        if (!start) return std::nullopt;
        std::string text;
        for (std::size_t i = *start; i < bytes_.size() && text.size() <= kMaxNameLength; ++i) {
            if (bytes_[i] == 0) return text;
            text.push_back(static_cast<char>(bytes_[i]));
        }
        return std::nullopt;
    }

    const std::vector<std::uint8_t>& bytes() const { return bytes_; }

private:
    const std::vector<std::uint8_t>& bytes_;
    Image image_;

    static Image parse_image(const std::vector<std::uint8_t>& bytes) {
        const auto read16 = [&](std::size_t offset) -> std::uint16_t {
            if (offset + 2 > bytes.size()) throw std::runtime_error("command table: truncated PE header");
            return static_cast<std::uint16_t>(bytes[offset] | (bytes[offset + 1] << 8));
        };
        const auto read32 = [&](std::size_t offset) -> std::uint32_t {
            if (offset + 4 > bytes.size()) throw std::runtime_error("command table: truncated PE header");
            return static_cast<std::uint32_t>(bytes[offset]) | (static_cast<std::uint32_t>(bytes[offset + 1]) << 8)
                | (static_cast<std::uint32_t>(bytes[offset + 2]) << 16) | (static_cast<std::uint32_t>(bytes[offset + 3]) << 24);
        };
        if (bytes.size() < 0x40 || bytes[0] != 'M' || bytes[1] != 'Z') throw std::runtime_error("command table: not a PE file");
        const std::size_t pe = read32(0x3C);
        if (pe + 24 > bytes.size() || std::memcmp(&bytes[pe], "PE\0\0", 4) != 0)
            throw std::runtime_error("command table: missing PE signature");
        const std::size_t coff = pe + 4;
        const std::size_t section_count = read16(coff + 2);
        const std::size_t optional_size = read16(coff + 16);
        const std::size_t optional = coff + 20;
        if (read16(optional) != 0x10B) throw std::runtime_error("command table: expected a 32-bit (PE32) executable");
        Image image;
        image.image_base = read32(optional + 28);
        std::size_t header = optional + optional_size;
        for (std::size_t index = 0; index < section_count; ++index, header += 40) {
            Section section;
            section.virtual_address = read32(header + 12);
            section.raw_size = read32(header + 16);
            section.raw_pointer = read32(header + 20);
            image.sections.push_back(section);
        }
        return image;
    }
};

struct Entry {
    std::uint32_t name = 0;
    std::uint32_t short_name = 0;
    std::uint32_t opcode = 0;
    std::uint32_t help = 0;
    std::uint16_t parent = 0;
    std::uint16_t parameter_count = 0;
    std::uint32_t parameters = 0;
};

Entry read_entry(const Executable& exe, std::size_t offset) {
    Entry entry;
    entry.name = exe.u32(offset);
    entry.short_name = exe.u32(offset + 4);
    entry.opcode = exe.u32(offset + 8);
    entry.help = exe.u32(offset + 12);
    entry.parent = exe.u16(offset + 16);
    entry.parameter_count = exe.u16(offset + 18);
    entry.parameters = exe.u32(offset + 20);
    return entry;
}

bool is_valid_entry(const Executable& exe, std::size_t offset) {
    if (offset > exe.size() || exe.size() - offset < kEntrySize) return false;
    const auto entry = read_entry(exe, offset);
    const auto name = exe.c_string(entry.name);
    if (!name || name->empty() || !std::isalpha(static_cast<unsigned char>((*name)[0]))) return false;
    for (const char c : *name)
        if (!std::isprint(static_cast<unsigned char>(c))) return false;
    return entry.opcode >= kMinOpcode && entry.opcode < kMaxOpcode && entry.parameter_count < kMaxParameters;
}

// Extends a run of valid entries from a record that is known to be valid, in both directions.
std::pair<std::size_t, std::size_t> entry_run(const Executable& exe, std::size_t anchor) {
    std::size_t first = anchor;
    std::size_t last = anchor;
    while (first >= kEntrySize && is_valid_entry(exe, first - kEntrySize)) first -= kEntrySize;
    while (is_valid_entry(exe, last + kEntrySize)) last += kEntrySize;
    return {first, last};
}

std::string command_table_cache_name(const std::vector<std::uint8_t>& executable) {
    // FNV-1a, 64-bit: enough to tell builds apart; the cache is not a security boundary.
    std::uint64_t hash = 0xcbf29ce484222325ull;
    for (const auto byte : executable) {
        hash ^= byte;
        hash *= 0x100000001b3ull;
    }
    std::ostringstream name;
    name << "command-table-" << std::hex;
    name.width(16);
    name.fill('0');
    name << hash << ".tsv";
    return name.str();
}

std::string serialize(const std::vector<ScriptCommand>& commands, const std::string& cache_name) {
    std::ostringstream text;
    text << kCacheHeader << '\t' << cache_name << '\n';
    for (const auto& command : commands) {
        text << std::hex << command.opcode << std::dec << '\t' << command.name << '\t' << command.short_name << '\t'
             << (command.needs_parent ? 1 : 0) << '\t';
        bool first = true;
        for (const auto& parameter : command.parameters) {
            if (!first) text << ';';
            first = false;
            text << parameter.type_name << ':' << parameter.type_id << ':' << (parameter.optional ? 1 : 0);
        }
        text << '\n';
    }
    // The trailer lets a reader tell a complete cache from one cut at a line boundary.
    text << kCacheTrailer << '\t' << commands.size() << '\n';
    return text.str();
}

std::vector<std::string> split(const std::string& text, char separator) {
    std::vector<std::string> parts;
    std::string current;
    for (const char c : text) {
        if (c == separator) {
            parts.push_back(current);
            current.clear();
        } else {
            current.push_back(c);
        }
    }
    parts.push_back(current);
    return parts;
}

// Returns nullopt when the cache does not match this executable or is malformed.
std::optional<std::vector<ScriptCommand>> deserialize(const std::string& text, const std::string& cache_name) {
    std::istringstream input(text);
    std::string header;
    if (!std::getline(input, header) || header != std::string(kCacheHeader) + '\t' + cache_name) return std::nullopt;
    std::vector<ScriptCommand> commands;
    std::string line;
    bool complete = false;
    while (std::getline(input, line)) {
        if (complete) return std::nullopt;
        const auto fields = split(line, '\t');
        if (fields.size() == 2 && fields[0] == kCacheTrailer) {
            if (std::stoul(fields[1]) != commands.size()) return std::nullopt;
            complete = true;
            continue;
        }
        if (fields.size() != 5) return std::nullopt;
        ScriptCommand command;
        command.opcode = static_cast<std::uint32_t>(std::stoul(fields[0], nullptr, 16));
        command.name = fields[1];
        command.short_name = fields[2];
        command.needs_parent = fields[3] == "1";
        if (!fields[4].empty()) {
            for (const auto& item : split(fields[4], ';')) {
                const auto parts = split(item, ':');
                if (parts.size() != 3) return std::nullopt;
                CommandParameter parameter;
                parameter.type_name = parts[0];
                parameter.type_id = static_cast<std::uint32_t>(std::stoul(parts[1]));
                parameter.optional = parts[2] == "1";
                command.parameters.push_back(parameter);
            }
        }
        commands.push_back(std::move(command));
    }
    if (!complete) return std::nullopt;
    return commands;
}

// Names are written into a tab/newline separated cache, so a name holding a separator
// would corrupt it. Such a name is treated as absent.
std::string cache_safe_name(std::string name) {
    for (const char c : name)
        if (c == '\t' || c == '\n' || c == '\r' || c == '\0') return {};
    return name;
}

} // namespace

ScriptCommandLookup make_command_lookup(const std::vector<ScriptCommand>& commands) {
    std::map<std::string, ScriptCommandSignature> signatures;
    for (const auto& command : commands) {
        ScriptCommandSignature signature;
        signature.max_arguments = command.parameters.size();
        for (const auto& parameter : command.parameters)
            if (!parameter.optional) ++signature.required_arguments;
        for (const auto& name : {command.name, command.short_name}) {
            if (name.empty()) continue;
            std::string key(name);
            for (auto& c : key) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            signatures.emplace(std::move(key), signature);
        }
    }
    // The table lists MessageBox with one parameter, but scripts pass button labels after the
    // message (for example `MessageBox "Text" "Yes" "No"`), so its argument count is not limited.
    if (const auto it = signatures.find("messagebox"); it != signatures.end())
        it->second.max_arguments = std::numeric_limits<std::size_t>::max();
    // Message's first string may contain format placeholders followed by substitution values;
    // the executable table records only the format string, as in ValenDrethScript's debug message.
    if (const auto it = signatures.find("message"); it != signatures.end())
        it->second.max_arguments = std::numeric_limits<std::size_t>::max();
    return [signatures = std::move(signatures)](std::string_view name) -> std::optional<ScriptCommandSignature> {
        std::string key(name);
        for (auto& c : key) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        const auto it = signatures.find(key);
        if (it == signatures.end()) return std::nullopt;
        return it->second;
    };
}

std::vector<ScriptCommand> read_command_table(const std::vector<std::uint8_t>& executable) {
    const Executable exe(executable);
    const std::string anchor_text = "SetStage";
    const auto& bytes = exe.bytes();
    const auto anchor_at = std::search(bytes.begin(), bytes.end(), anchor_text.begin(), anchor_text.end());
    if (anchor_at == bytes.end() || anchor_at + anchor_text.size() >= bytes.end() || *(anchor_at + anchor_text.size()) != 0)
        throw std::runtime_error("command table: SetStage is not in this executable");
    const auto name_address = exe.address_of(static_cast<std::size_t>(anchor_at - bytes.begin()));
    if (!name_address) throw std::runtime_error("command table: SetStage is not in a section");

    // A record refers to its name by address, and the name is the first field.
    std::optional<std::pair<std::size_t, std::size_t>> best;
    for (std::size_t offset = 0; offset + 4 <= bytes.size(); ++offset) {
        if (exe.u32(offset) != *name_address) continue;
        if (!is_valid_entry(exe, offset)) continue;
        const auto run = entry_run(exe, offset);
        if (!best || run.second - run.first > best->second - best->first) best = run;
    }
    if (!best) throw std::runtime_error("command table: no record refers to SetStage");

    std::vector<ScriptCommand> commands;
    for (std::size_t offset = best->first; offset <= best->second; offset += kEntrySize) {
        const auto entry = read_entry(exe, offset);
        ScriptCommand command;
        command.name = cache_safe_name(exe.c_string(entry.name).value_or(""));
        command.short_name = cache_safe_name(exe.c_string(entry.short_name).value_or(""));
        command.opcode = entry.opcode;
        command.needs_parent = entry.parent != 0;
        const auto parameters_at = exe.file_offset(entry.parameters);
        for (std::uint16_t index = 0; parameters_at && index < entry.parameter_count; ++index) {
            const auto record = *parameters_at + 12u * index;
            CommandParameter parameter;
            const auto type_name = exe.c_string(exe.u32(record)).value_or("");
            parameter.type_id = exe.u32(record + 4);
            parameter.optional = exe.u32(record + 8) != 0 || type_name.find("(optional)") != std::string::npos;
            parameter.type_name = parameter_type_name(parameter.type_id);
            command.parameters.push_back(parameter);
        }
        commands.push_back(std::move(command));
    }
    return commands;
}

std::filesystem::path command_table_cache_path(const std::filesystem::path& cache_dir,
                                               const std::vector<std::uint8_t>& executable) {
    return cache_dir / command_table_cache_name(executable);
}

std::vector<ScriptCommand> load_command_table(const std::filesystem::path& executable_path,
                                              const std::filesystem::path& cache_dir) {
    std::ifstream input(executable_path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot open " + executable_path.string());
    const std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    const auto cache_name = command_table_cache_name(bytes);
    const auto cache_file = cache_dir / cache_name;

    if (std::ifstream cached(cache_file, std::ios::binary); cached) {
        std::ostringstream text;
        text << cached.rdbuf();
        try {
            if (auto commands = deserialize(text.str(), cache_name)) return *commands;
        } catch (const std::exception&) {
            // A malformed cache is rebuilt below.
        }
    }

    auto commands = read_command_table(bytes);
    // The cache is an optimization: failing to write it must not lose the parsed table.
    try {
        std::filesystem::create_directories(cache_dir);
        // Write to a process-unique temporary name first, so an interrupted run or a
        // concurrent process never leaves a half-written cache in place.
        static std::atomic<unsigned> counter{0};
        const auto temporary = cache_file.string() + "." +
            std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + "." +
            std::to_string(counter.fetch_add(1)) + ".tmp";
        const auto payload = serialize(commands, cache_name);
        bool written = false;
        {
            std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
            output.write(payload.data(), static_cast<std::streamsize>(payload.size()));
            output.flush();
            written = static_cast<bool>(output);
        }
        std::error_code error;
        if (written) std::filesystem::rename(temporary, cache_file, error);
        if (!written || error) std::filesystem::remove(temporary, error);
    } catch (const std::exception&) {
    }
    return commands;
}

} // namespace oblivion
