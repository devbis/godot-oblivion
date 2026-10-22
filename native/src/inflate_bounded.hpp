#pragma once

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include <zlib.h>

namespace oblivion {

// Upper bound on a single inflated payload. Oblivion's largest archived assets
// are far below this; the limit keeps a corrupt size field from requesting a
// multi-gigabyte allocation before zlib gets a chance to reject the stream.
inline constexpr std::uint32_t kMaxInflatedSize = 256u * 1024u * 1024u;

// DEFLATE cannot expand data by more than 1032:1, so a declared output size
// beyond that ratio is corrupt regardless of the absolute limit.
inline constexpr std::size_t kMaxDeflateRatio = 1032;

// Inflates a zlib stream whose output size is declared by the file. The
// declared size is validated against both the absolute limit and the maximum
// possible deflate expansion of the compressed input before any allocation.
inline std::vector<std::uint8_t> inflate_bounded(const std::uint8_t* compressed, std::size_t compressed_size,
                                                 std::uint32_t output_size, std::string_view what) {
    if (output_size > kMaxInflatedSize
        || static_cast<std::size_t>(output_size) > (compressed_size + 1) * kMaxDeflateRatio)
        throw std::runtime_error(std::string(what) + " declares an implausible output size");
    std::vector<std::uint8_t> result(output_size);
    if (output_size == 0) return result;
    uLongf actual = static_cast<uLongf>(result.size());
    const int status = uncompress(result.data(), &actual, compressed, static_cast<uLong>(compressed_size));
    if (status != Z_OK || actual != result.size())
        throw std::runtime_error("zlib failed to unpack " + std::string(what));
    return result;
}

} // namespace oblivion
