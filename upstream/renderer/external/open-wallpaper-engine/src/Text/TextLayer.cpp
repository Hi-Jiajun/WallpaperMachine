#include "Text/TextLayer.hpp"
#include "Text/SystemFontResolver.hpp"

#include <algorithm>
#include <atomic>
#include <array>
#include <cmath>
#include <functional>
#include <fstream>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string_view>
#include <type_traits>
#include <utility>

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_ADVANCES_H

namespace wallpaper
{

namespace
{
// Wallpaper Engine sets a face's size in points at 300 dpi, so one point of
// `pointsize` is 300 / 72 pixels, and clamps `pointsize` to 1..256 first.
constexpr float kTextDpi       = 300.0f;
constexpr float kPointsPerInch = 72.0f;
constexpr float kMinPointSize  = 1.0f;
constexpr float kMaxPointSize  = 256.0f;
#ifdef WESCENE_BUILD_TESTS
std::atomic_uint64_t g_measurement_count { 0 };
#endif
std::mutex g_freetype_mutex;

class FtLibrary {
public:
    static FtLibrary& Get() {
        static FtLibrary instance;
        return instance;
    }

    FT_Library handle() const { return m_library; }

private:
    FtLibrary() {
        if (FT_Init_FreeType(&m_library) != 0) m_library = nullptr;
    }

    ~FtLibrary() {
        if (m_library != nullptr) FT_Done_FreeType(m_library);
    }

    FtLibrary(const FtLibrary&)            = delete;
    FtLibrary& operator=(const FtLibrary&) = delete;

    FT_Library m_library { nullptr };
};

struct FtFaceDeleter {
    void operator()(FT_Face face) const {
        if (face != nullptr) FT_Done_Face(face);
    }
};

float ClampedPointSize(float point_size) {
    if (! std::isfinite(point_size)) point_size = 12.0f;
    return std::clamp(point_size, kMinPointSize, kMaxPointSize);
}

// The size in whole pixels of a point size as the layout and fallback
// estimates see it. A real face is sized by `FreeTypeCharHeight` instead, which
// leaves the rounding to FreeType as Wallpaper Engine does.
float PointSizeToPixels(float point_size) {
    return ClampedPointSize(point_size) * kTextDpi / kPointsPerInch;
}

// The nominal height Wallpaper Engine requests from FreeType: `pointsize` in
// 26.6 fixed point, truncated.
FT_F26Dot6 FreeTypeCharHeight(float point_size) {
    return static_cast<FT_F26Dot6>(static_cast<int>(ClampedPointSize(point_size) * 64.0f));
}

// One placed glyph. Distances are pixels, `advance` is the pen step including
// the layer's `spacing.x`, and the ink box is relative to the pen and the
// baseline (y up). A glyph without ink, a space, has an empty box at the pen.
struct GlyphRun {
    uint32_t codepoint { 0 };
    float    advance { 0.0f };
    bool     fallback { false };
    float    left { 0.0f };
    float    right { 0.0f };
    float    top { 0.0f };
    float    bottom { 0.0f };
    bool     has_ink { false };
    // What `advance` is made of: the glyph's unhinted advance and the kerning it
    // takes against the glyph after it, in 26.6 fixed point.
    uint32_t glyph_index { 0 };
    int32_t  advance_26_6 { 0 };
    int32_t  kerning_26_6 { 0 };
};

// One row of text. Its extents are those of the ink and of the pen at every
// glyph start, always including the row origin, as Wallpaper Engine measures
// them: a trailing advance that carries no ink is not part of the row.
struct LineRun {
    std::vector<GlyphRun> glyphs;
    float                 advance_width { 0.0f };
    float                 bounds_left { 0.0f };
    float                 bounds_right { 0.0f };
    float                 bounds_top { 0.0f };
    float                 bounds_bottom { 0.0f };
    // The row ended at an automatic word wrap and a row follows it; the only
    // kind of row `blockalign` justifies.
    bool                  wrapped { false };

    float ExtentLeft() const { return bounds_left; }
    float ExtentRight() const { return bounds_right; }
    float LayoutWidth() const { return bounds_right - bounds_left; }
};

// A text block's box. `top` and `bottom` are heights above the first row's
// baseline, y up; rows step down by `pitch`.
struct TextBlock {
    float min_x { 0.0f };
    float max_x { 0.0f };
    float top { 0.0f };
    float bottom { 0.0f };
    float pitch { 0.0f };

    float Width() const { return max_x - min_x; }
    float Height() const { return top - bottom; }
};

uint8_t ColorByte(float value) {
    if (! std::isfinite(value)) value = 1.0f;
    value = std::clamp(value, 0.0f, 1.0f);
    return static_cast<uint8_t>(std::lround(value * 255.0f));
}

std::array<uint8_t, 4> TextColorBytes(const TextLayerState& state) {
    const float brightness =
        std::isfinite(state.brightness) ? std::max(0.0f, state.brightness) : 1.0f;
    return {
        ColorByte(state.color.x() * brightness),
        ColorByte(state.color.y() * brightness),
        ColorByte(state.color.z() * brightness),
        ColorByte(state.alpha),
    };
}

std::vector<uint8_t> ReadFileBytes(std::string_view path) {
    if (path.empty()) return {};
    std::ifstream file(std::string(path), std::ios::binary | std::ios::ate);
    if (! file) return {};

    const auto size = file.tellg();
    if (size <= 0) return {};
    file.seekg(0, std::ios::beg);

    std::vector<uint8_t> data(static_cast<std::size_t>(size));
    if (! file.read(reinterpret_cast<char*>(data.data()), size)) {
        return {};
    }
    return data;
}

std::unique_ptr<std::remove_pointer_t<FT_Face>, FtFaceDeleter>
CreateFreeTypeFaceFromBytes(const std::vector<uint8_t>& data, float point_size) {
    FT_Library library = FtLibrary::Get().handle();
    if (library == nullptr) return nullptr;
    if (data.empty()) return nullptr;

    FT_Face raw_face = nullptr;
    if (FT_New_Memory_Face(library,
                           reinterpret_cast<const FT_Byte*>(data.data()),
                           static_cast<FT_Long>(data.size()),
                           0,
                           &raw_face) != 0) {
        return nullptr;
    }

    if (FT_Set_Char_Size(raw_face, 0, FreeTypeCharHeight(point_size),
                         static_cast<FT_UInt>(kTextDpi), static_cast<FT_UInt>(kTextDpi)) != 0) {
        FT_Done_Face(raw_face);
        return nullptr;
    }
    return std::unique_ptr<std::remove_pointer_t<FT_Face>, FtFaceDeleter>(raw_face);
}

std::unique_ptr<std::remove_pointer_t<FT_Face>, FtFaceDeleter>
CreateFreeTypeFace(const TextLayerState& state, std::vector<uint8_t>& owned_data) {
    // Keep an authored, usable font first. A package can also contain a broken
    // font, or a previously resolved file can disappear before rasterization.
    // Recover at the decoder boundary so measurement and rasterization choose
    // the same real face in all of these cases, not placeholder rectangles.
    if (! state.resolved_font_data.empty()) {
        if (auto face = CreateFreeTypeFaceFromBytes(state.resolved_font_data.bytes(), state.point_size)) {
            return face;
        }
    } else if (! state.resolved_font_path.empty()) {
        owned_data = ReadFileBytes(state.resolved_font_path);
        if (auto face = CreateFreeTypeFaceFromBytes(owned_data, state.point_size)) return face;
    }
#ifdef __APPLE__
    for (const auto& key : {state.font_key, std::string("systemfont_sansserif")}) {
        const auto path = ResolveSystemFontPath(key);
        if (path.empty()) continue;
        owned_data = ReadFileBytes(path);
        if (auto face = CreateFreeTypeFaceFromBytes(owned_data, state.point_size)) return face;
    }
#endif
    return nullptr;
}

struct FallbackFace {
    std::vector<uint8_t>                                           data;
    std::unique_ptr<std::remove_pointer_t<FT_Face>, FtFaceDeleter> face;
};

std::optional<FallbackFace> CreateFallbackFace(const TextLayerState& state) {
#ifdef __APPLE__
    for (std::string_view key :
         { "systemfont_PingFang SC", "systemfont_Arial Unicode MS", "systemfont_Helvetica" }) {
        const auto path = ResolveSystemFontPath(key);
        if (path.empty() || path == state.resolved_font_path) continue;

        FallbackFace fallback {
            .data = ReadFileBytes(path),
            .face = {},
        };
        fallback.face = CreateFreeTypeFaceFromBytes(fallback.data, state.point_size);
        if (fallback.face != nullptr) return fallback;
    }
#else
    (void)state;
#endif
    return std::nullopt;
}

std::vector<uint32_t> DecodeUtf8(std::string_view text) {
    std::vector<uint32_t> codepoints;
    codepoints.reserve(text.size());

    std::size_t index = 0;
    while (index < text.size()) {
        const auto  first     = static_cast<uint8_t>(text[index]);
        uint32_t    codepoint = 0;
        std::size_t extra     = 0;

        if (first < 0x80u) {
            codepoint = first;
        } else if ((first & 0xE0u) == 0xC0u) {
            codepoint = first & 0x1Fu;
            extra     = 1;
        } else if ((first & 0xF0u) == 0xE0u) {
            codepoint = first & 0x0Fu;
            extra     = 2;
        } else if ((first & 0xF8u) == 0xF0u) {
            codepoint = first & 0x07u;
            extra     = 3;
        } else {
            codepoints.push_back(0xFFFDu);
            ++index;
            continue;
        }

        if (index + extra >= text.size()) {
            codepoints.push_back(0xFFFDu);
            break;
        }

        bool valid = true;
        for (std::size_t offset = 1; offset <= extra; ++offset) {
            const auto next = static_cast<uint8_t>(text[index + offset]);
            if ((next & 0xC0u) != 0x80u) {
                valid = false;
                break;
            }
            codepoint = (codepoint << 6u) | (next & 0x3Fu);
        }
        if (! valid) {
            codepoints.push_back(0xFFFDu);
            ++index;
            continue;
        }

        codepoints.push_back(codepoint);
        index += extra + 1u;
    }
    return codepoints;
}

bool ContainsSubstring(std::string_view value, std::string_view needle) {
    return value.find(needle) != std::string_view::npos;
}

float HorizontalLineStart(const TextLayerState& state, float line_width, float padding,
                          uint32_t width) {
    const std::string_view align = state.horizontal_align;
    if (ContainsSubstring(align, "right")) {
        return std::max(0.0f, static_cast<float>(width) - padding - line_width);
    }
    if (ContainsSubstring(align, "center") || align.empty()) {
        return std::max(padding, (static_cast<float>(width) - line_width) * 0.5f);
    }
    return padding;
}

void AppendGlyphMetrics(LineRun& line, const GlyphRun& glyph) {
    const float pen    = line.advance_width;
    line.bounds_left   = std::min(line.bounds_left, pen + glyph.left);
    line.bounds_right  = std::max(line.bounds_right, pen + glyph.right);
    line.bounds_top    = std::max(line.bounds_top, glyph.top);
    line.bounds_bottom = std::min(line.bounds_bottom, glyph.bottom);
    line.advance_width += glyph.advance;
}

void AppendMeasuredGlyph(LineRun& line, const GlyphRun& glyph) {
    AppendGlyphMetrics(line, glyph);
    line.glyphs.push_back(glyph);
}

// What the layer adds to every glyph's advance (`spacing.x`) and to every
// line pitch (`spacing.y`), in pixels at the rasterised size.
float GlyphSpacing(const TextLayerState& state) {
    return std::isfinite(state.spacing.x()) ? state.spacing.x() : 0.0f;
}

float LineSpacing(const TextLayerState& state) {
    return std::isfinite(state.spacing.y()) ? state.spacing.y() : 0.0f;
}

// The card's margin on each axis. Wallpaper Engine caps it at 512 pixels and
// does not floor it: a negative padding takes the card in around the text.
Eigen::Vector2f CardPadding(const TextLayerState& state) {
    constexpr float kMaxCardPadding = 512.0f;
    const auto lane = [=](float value) {
        return std::isfinite(value) ? std::min(value, kMaxCardPadding) : 0.0f;
    };
    return { lane(state.padding.x()), lane(state.padding.y()) };
}

// A glyph's pen advance: its unhinted advance with its kerning, cut to whole
// pixels, plus `spacing` x.
float GlyphAdvance(const GlyphRun& glyph, float spacing_x) {
    return std::floor(static_cast<float>(glyph.advance_26_6 + glyph.kerning_26_6) / 64.0f) + spacing_x;
}

std::optional<GlyphRun> MeasureGlyph(FT_Face primary_face, FT_Face fallback_face, uint32_t codepoint,
                                     float spacing_x) {
    FT_Face face     = primary_face;
    bool    fallback = false;
    if (FT_Get_Char_Index(face, codepoint) == 0u && fallback_face != nullptr &&
        FT_Get_Char_Index(fallback_face, codepoint) != 0u) {
        face     = fallback_face;
        fallback = true;
    }
    if (FT_Get_Char_Index(face, codepoint) == 0u) return std::nullopt;
    if (FT_Load_Char(face, codepoint, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) != 0) return std::nullopt;

    const FT_GlyphSlot slot    = face->glyph;
    const bool         has_ink = slot->bitmap.width > 0u && slot->bitmap.rows > 0u;
    // Wallpaper Engine takes advances from its shaper, which reads them unhinted
    // and cuts them to whole pixels, then adds the layer's `spacing`.
    const FT_UInt glyph_index = FT_Get_Char_Index(face, codepoint);
    FT_Fixed      unhinted    = 0;
    int32_t       advance_26_6 = static_cast<int32_t>(slot->advance.x);
    if (FT_Get_Advance(face, glyph_index, FT_LOAD_NO_HINTING, &unhinted) == 0) {
        advance_26_6 = static_cast<int32_t>((unhinted + 512) >> 10); // 16.16 to 26.6
    }
    GlyphRun           glyph {
                  .codepoint = codepoint,
                  .fallback  = fallback,
                  .has_ink   = has_ink,
                  .glyph_index  = glyph_index,
                  .advance_26_6 = advance_26_6,
    };
    glyph.advance = GlyphAdvance(glyph, spacing_x);
    if (has_ink) {
        glyph.left   = static_cast<float>(slot->bitmap_left);
        glyph.right  = glyph.left + static_cast<float>(slot->bitmap.width);
        glyph.top    = static_cast<float>(slot->bitmap_top);
        glyph.bottom = glyph.top - static_cast<float>(slot->bitmap.rows);
    }
    return glyph;
}

// The width a row may fill: `maxwidth` as authored, with no allowance for the
// card's padding, and only when the layer limits its width.
float TextWidthLimit(const TextLayerState& state) {
    if (! state.limit_width || ! std::isfinite(state.max_width) || state.max_width <= 0.0f) return 0.0f;
    return state.max_width;
}

LineRun MakeLine(std::span<const GlyphRun> glyphs) {
    LineRun line;
    for (const auto& glyph : glyphs) AppendMeasuredGlyph(line, glyph);
    return line;
}

bool BreakSpace(const GlyphRun& glyph) { return glyph.codepoint == ' ' || glyph.codepoint == '\t'; }

// `blockalign`: a row that ended at a word wrap, with another row after it,
// is stretched to exactly `width_limit` by spreading the slack over its spaces
// and tabs. The last row of a paragraph, a row ended by a line break and a row
// the row limit cut are left as they are, and so is a row with no space.
void JustifyWrappedLines(std::vector<LineRun>& lines, float width_limit) {
    for (auto& line : lines) {
        if (! line.wrapped || line.glyphs.empty()) continue;
        const auto spaces = static_cast<std::size_t>(
            std::count_if(line.glyphs.begin(), line.glyphs.end(), BreakSpace));
        if (spaces == 0u) continue;
        const float extra = (width_limit - line.LayoutWidth()) / static_cast<float>(spaces);
        for (auto& glyph : line.glyphs) {
            if (BreakSpace(glyph)) glyph.advance += extra;
        }
        line               = MakeLine(std::span<const GlyphRun>(line.glyphs));
        line.wrapped       = true;
        line.bounds_right  = line.bounds_left + width_limit;
    }
}

// The glyph as it stands before a glyph that does not kern with it: the pen
// advance without the kerning its old neighbour asked for.
GlyphRun WithoutKerning(GlyphRun glyph, float spacing_x) {
    glyph.kerning_26_6 = 0;
    glyph.advance      = GlyphAdvance(glyph, spacing_x);
    return glyph;
}

// The last row `row_limit` allows ended in text that does not fit, and the
// layer asks for an ellipsis: the row keeps as many glyphs as leave room for the
// marker inside the width limit, dropping one glyph at a time from the end, and
// the marker follows the last glyph kept that is not a space or a tab.
// `trim_first` is the row of a line break that more text followed: its trailing
// white space goes before anything is measured, where a row cut at a glyph is
// measured with it and trimmed after.
template<typename Measure>
void EllipsizeLastRow(std::vector<LineRun>& lines, Measure measure, float width_limit,
                      float spacing_x, bool trim_first) {
    auto& line = lines.back();
    if (trim_first) {
        while (! line.glyphs.empty() && BreakSpace(line.glyphs.back())) line.glyphs.pop_back();
    }
    std::vector<GlyphRun> marker;
    if (auto glyph = measure(0x2026)) marker.push_back(*glyph);
    else if (auto dot = measure('.')) marker.assign(3, *dot);

    // Prefix metrics make fitting a suffix linear even for a long row. Entry `n`
    // holds the first `n` glyphs as they are laid out among their neighbours.
    std::vector<LineRun> prefix(1);
    for (const auto& glyph : line.glyphs) {
        auto metrics = prefix.back();
        AppendGlyphMetrics(metrics, glyph);
        prefix.push_back(std::move(metrics));
    }
    size_t count = line.glyphs.size();
    while (true) {
        // The marker does not kern with the glyph before it.
        LineRun candidate = prefix[count > 0 ? count - 1 : 0];
        if (count > 0) AppendGlyphMetrics(candidate, WithoutKerning(line.glyphs[count - 1], spacing_x));
        for (const auto& glyph : marker) AppendGlyphMetrics(candidate, glyph);
        if (width_limit == 0.0f || candidate.ExtentRight() <= width_limit) break;
        if (count == 0) { marker.clear(); break; }
        --count;
    }
    std::vector<GlyphRun> kept(line.glyphs.begin(), line.glyphs.begin() + static_cast<std::ptrdiff_t>(count));
    while (! kept.empty() && BreakSpace(kept.back())) kept.pop_back();
    // A row that already ends in the marker is not given another.
    if (! kept.empty() && kept.back().codepoint == 0x2026) marker.clear();
    if (! kept.empty() && ! marker.empty()) kept.back() = WithoutKerning(kept.back(), spacing_x);
    for (const auto& glyph : marker) kept.push_back(glyph);
    line = MakeLine(std::span<const GlyphRun>(kept));
}

// `measure(codepoint)` gives a glyph; `kerning(left, right)` the 26.6 kerning of two
// neighbouring glyphs of the same face, which narrows or widens the left one.
//
// Text is cut into paragraphs at line breaks, and a break with nothing after it
// ends the text without a row of its own. A row wraps before a glyph whose ink
// would end past the width limit. Where the row limit allows another row the
// wrap is at the last space or tab before that glyph (the row keeps everything
// up to it, the next row starts at the glyph with the white space before it
// dropped), or at the glyph itself when the row holds none. On the last row the
// limit allows, nothing wraps: the row keeps every glyph before the glyph that
// did not fit, and the layer's ellipsis, if it asks for one, replaces the end.
template<typename Measure, typename Kerning>
std::vector<LineRun> BuildLineRuns(const TextLayerState& state, Measure measure, Kerning kerning) {
    std::vector<LineRun> lines;
    lines.emplace_back();
    const float width_limit = TextWidthLimit(state);
    const float spacing_x   = GlyphSpacing(state);
    const size_t row_limit = state.limit_rows && state.max_rows != 0 ? state.max_rows : SIZE_MAX;
    bool omitted        = false;
    bool omitted_by_break = false;
    const auto codepoints = DecodeUtf8(state.text);
    for (std::size_t at = 0; at < codepoints.size(); ++at) {
        const uint32_t codepoint = codepoints[at];
        if (codepoint == '\n') {
            // Nothing after the break: the text ends with the row before it.
            if (at + 1 == codepoints.size()) break;
            if (lines.size() == row_limit) { omitted = omitted_by_break = true; break; }
            lines.emplace_back();
            continue;
        }
        if (codepoint == '\r') continue;
        auto glyph = measure(codepoint);
        if (! glyph) continue;
        if (! lines.back().glyphs.empty()) {
            auto&         previous = lines.back().glyphs.back();
            const int32_t kern     = kerning(previous, *glyph);
            if (kern != previous.kerning_26_6) {
                previous.kerning_26_6 = kern;
                const float advance   = GlyphAdvance(previous, spacing_x);
                lines.back().advance_width += advance - previous.advance;
                previous.advance = advance;
            }
        }
        // A row wraps before a glyph whose ink would end past the limit, once it
        // holds a glyph already; a space or tab never starts a wrap.
        const bool overflows = width_limit > 0.0f && ! lines.back().glyphs.empty() &&
                               ! BreakSpace(*glyph) &&
                               lines.back().advance_width + glyph->right > width_limit;
        AppendMeasuredGlyph(lines.back(), *glyph);
        if (! overflows) continue;

        auto& current = lines.back();
        if (lines.size() == row_limit) {
            // The last row: cut before the glyph that did not fit, no search for
            // a space.
            current.glyphs.pop_back();
            current = MakeLine(current.glyphs);
            omitted = true;
            break;
        }
        // Break at the last space or tab before the glyph, which stays out of the
        // next row along with the white space that follows it; a row with none is
        // cut at the glyph. Spaces before the break stay in the row.
        size_t split = current.glyphs.size() - 1;
        for (size_t index = split; index > 0; --index) {
            if (BreakSpace(current.glyphs[index - 1])) { split = index - 1; break; }
        }
        std::vector<GlyphRun> carry(current.glyphs.begin() + static_cast<std::ptrdiff_t>(split),
                                    current.glyphs.end());
        current.glyphs.resize(split);
        current         = MakeLine(current.glyphs);
        current.wrapped = true;
        while (! carry.empty() && BreakSpace(carry.front())) carry.erase(carry.begin());
        lines.push_back(MakeLine(carry));
    }
    if (omitted && state.use_ellipsis) {
        EllipsizeLastRow(lines, measure, width_limit, spacing_x, omitted_by_break);
    }
    if (state.block_align && width_limit > 0.0f) JustifyWrappedLines(lines, width_limit);
    return lines;
}

std::vector<LineRun> BuildFreeTypeLines(const TextLayerState& state, FT_Face face, FT_Face fallback) {
    const float spacing_x = GlyphSpacing(state);
    return BuildLineRuns(
        state,
        [&](uint32_t codepoint) { return MeasureGlyph(face, fallback, codepoint, spacing_x); },
        [&](const GlyphRun& left, const GlyphRun& right) -> int32_t {
            // Neighbours of one face only, as a shaper kerns a run of one font.
            FT_Face used = left.fallback ? fallback : face;
            if (left.fallback != right.fallback || used == nullptr || ! FT_HAS_KERNING(used)) return 0;
            FT_Vector kern {};
            if (FT_Get_Kerning(used, left.glyph_index, right.glyph_index, FT_KERNING_UNFITTED, &kern) != 0) {
                return 0;
            }
            return static_cast<int32_t>(kern.x);
        });
}

// The box of the rows, as Wallpaper Engine lays it out: from the first row's
// ascender line, or the tallest ink above it, down to one line pitch below that
// line for every row, or the lowest ink below it. The pitch is the face's line
// height plus the layer's `spacing.y`.
TextBlock MeasureTextBlock(const std::vector<LineRun>& lines, float ascender, float pitch) {
    const auto rows = static_cast<float>(lines.size());
    TextBlock  block {
         .top    = ascender,
         .bottom = ascender - rows * pitch,
         .pitch  = pitch,
    };
    for (std::size_t index = 0; index < lines.size(); ++index) {
        const auto& line = lines[index];
        const float drop = static_cast<float>(index) * pitch;
        block.min_x      = std::min(block.min_x, line.bounds_left);
        block.max_x      = std::max(block.max_x, line.bounds_right);
        block.top        = std::max(block.top, line.bounds_top - drop);
        block.bottom     = std::min(block.bottom, line.bounds_bottom - drop);
    }
    return block;
}

// Where the block's top edge sits in a card `height` tall: under the padding,
// or pushed down to the centre or the bottom of what the padding leaves.
float BlockTopY(const TextLayerState& state, float padding_y, uint32_t height, float block_height) {
    const float content_height = std::max(0.0f, static_cast<float>(height) - padding_y * 2.0f);
    const std::string_view align =
        state.vertical_align.empty() ? state.anchor : state.vertical_align;

    float top = padding_y;
    if (ContainsSubstring(align, "bottom")) {
        top = padding_y + std::max(0.0f, content_height - block_height);
    } else if (ContainsSubstring(align, "center") || ContainsSubstring(align, "middle")) {
        top = padding_y + std::max(0.0f, (content_height - block_height) * 0.5f);
    }
    return top;
}

struct FaceLayoutMetrics {
    float ascender { 0.0f };
    float pitch { 0.0f };
};

FaceLayoutMetrics FaceMetrics(const TextLayerState& state, FT_Face face) {
    const auto metrics = face->size->metrics;
    return {
        .ascender = static_cast<float>(metrics.ascender) / 64.0f,
        .pitch    = static_cast<float>(metrics.height >> 6) + LineSpacing(state),
    };
}

// Without a usable face the layout runs on boxes: 0.6 em advances, 0.9 em glyphs
// and a 1.2 em line.
constexpr float kFallbackAdvance = 0.6f;
constexpr float kFallbackInk     = 0.45f;
constexpr float kFallbackAscent  = 0.9f;
constexpr float kFallbackLine    = 1.2f;

std::vector<LineRun> BuildFallbackLines(const TextLayerState& state) {
    const float pixels    = PointSizeToPixels(state.point_size);
    const float spacing_x = GlyphSpacing(state);
    return BuildLineRuns(
        state,
        [=](uint32_t codepoint) -> std::optional<GlyphRun> {
            const float advance = std::max(1.0f, pixels * kFallbackAdvance);
            const float ink     = std::max(1.0f, pixels * kFallbackInk);
            const bool  has_ink = codepoint != ' ' && codepoint != '\t';
            GlyphRun    glyph {
                           .codepoint = codepoint,
                           .advance   = (codepoint == '\t' ? advance * 4.0f : advance) + spacing_x,
                           .has_ink   = has_ink,
            };
            if (has_ink) {
                glyph.right = ink;
                glyph.top   = pixels * kFallbackAscent;
            }
            return glyph;
        },
        [](const GlyphRun&, const GlyphRun&) -> int32_t { return 0; });
}

FaceLayoutMetrics FallbackMetrics(const TextLayerState& state) {
    const float pixels = PointSizeToPixels(state.point_size);
    return { .ascender = pixels * kFallbackAscent,
             .pitch    = pixels * kFallbackLine + LineSpacing(state) };
}

// The card that holds a block: the block plus the padding on both sides, and
// 2 by 2 plus the padding when there is no text to lay out.
Eigen::Vector2f CardSizeForBlock(const TextLayerState& state, const TextBlock& block) {
    const auto padding = CardPadding(state);
    if (state.text.empty()) {
        return { std::max(1.0f, 2.0f + padding.x() * 2.0f), std::max(1.0f, 2.0f + padding.y() * 2.0f) };
    }
    return { std::max(1.0f, block.Width() + padding.x() * 2.0f),
             std::max(1.0f, block.Height() + padding.y() * 2.0f) };
}

// ---------------------------------------------------------------------------
// Outline, blur and drop shadow.
//
// Wallpaper Engine draws a glyph from a signed-distance atlas made at 32 pixels
// to the em, padded by 12 pixels and scaled up by `ppem / 32` on the way to
// the screen. The scene file's sizes are scaled into that atlas by
// `k = 32 / pointsize * 0.24`, capped there, and `0.24 * ppem / pointsize` is
// one: they are pixels of the finished text. The caps stay in atlas units, so
// they grow with the text. Everything below is in raster pixels.
// ---------------------------------------------------------------------------

constexpr float kAtlasEm        = 32.0f;
constexpr float kAtlasRange     = 12.0f; // atlas pixels of distance the field holds each way
constexpr float kAtlasUnitScale = 0.24f;
constexpr float kOutlineCap     = 5.1f;
constexpr float kBlurCap        = 6.0f;
constexpr float kShadowCap      = 6.0f;
constexpr float kShadowOffsetCap = 6.0f;

struct StyleMetrics {
    bool            outline { false };
    bool            blur { false };
    bool            shadow { false };
    // Outline width, and how far each edge softens either way.
    float           outline_px { 0.0f };
    float           edge_half_px { 0.5f };
    float           shadow_half_px { 0.5f };
    Eigen::Vector2f shadow_offset_px { Eigen::Vector2f::Zero() };
    float           shadow_opacity { 1.0f };
    // How far the field reaches from a glyph; farther is outside every edge.
    float           range_px { 0.0f };
    // Edges are smoothed over a width, not a pixel, when blur or a shadow is on.
    bool            smooth { false };
};

float FiniteOr(float value, float fallback) { return std::isfinite(value) ? value : fallback; }

StyleMetrics ResolveStyleMetrics(const TextStyle& style, float point_size) {
    StyleMetrics metrics;
    if (! TextStyleActive(style)) return metrics;

    const float points = ClampedPointSize(point_size);
    const float k      = (kAtlasEm / points) * kAtlasUnitScale;
    const float scale  = PointSizeToPixels(point_size) / kAtlasEm; // pixels per atlas pixel

    // The outline asks for at least one pixel; blur and shadow sizes for a hair.
    const float outline = style.outline ? std::max(FiniteOr(style.outline_thickness, 1.0f), 1.0f) : 0.0f;
    const float blur    = style.blur ? std::max(FiniteOr(style.blur_size, 0.01f), 0.01f) : 0.0f;
    const float shadow  = style.drop_shadow ? std::max(FiniteOr(style.shadow_size, 0.01f), 0.01f) : 0.0f;
    const Eigen::Vector2f offset = style.drop_shadow
        ? Eigen::Vector2f(FiniteOr(style.shadow_offset.x(), 0.0f), FiniteOr(style.shadow_offset.y(), 0.0f))
        : Eigen::Vector2f::Zero();

    float outline_atlas = std::min(outline * k, kOutlineCap);
    const float blur_atlas   = std::min(blur * k, kBlurCap);
    const float shadow_atlas = std::min(shadow * k, kShadowCap);
    const Eigen::Vector2f offset_atlas(std::min(offset.x() * k, kShadowOffsetCap),
                                       std::min(offset.y() * k, kShadowOffsetCap));
    if (outline_atlas + blur_atlas > kOutlineCap) {
        outline_atlas = std::max(kOutlineCap - blur_atlas, 0.0f);
    }

    metrics.outline          = style.outline && outline >= 1.0f;
    metrics.blur             = blur > 0.0f;
    metrics.shadow           = style.drop_shadow && (shadow > 0.0f || offset.squaredNorm() > 1.1920929e-07f);
    metrics.smooth           = metrics.blur || metrics.shadow;
    metrics.outline_px       = metrics.outline ? outline_atlas * scale : 0.0f;
    // Blur softens in atlas pixels; a shadow alone softens the glyph over half a
    // pixel of the screen.
    metrics.edge_half_px     = metrics.blur ? std::max(blur_atlas, 0.5f) * scale : 0.5f;
    metrics.shadow_half_px   = std::max(shadow_atlas, 0.5f) * scale;
    metrics.shadow_offset_px = offset_atlas * scale;
    metrics.shadow_opacity   = FiniteOr(style.shadow_opacity, 1.0f);
    metrics.range_px         = kAtlasRange * scale;
    return metrics;
}

float StyleReach(const StyleMetrics& metrics) {
    float reach = 0.0f;
    if (metrics.outline) reach = metrics.outline_px;
    reach += metrics.smooth || metrics.outline ? metrics.edge_half_px : 0.5f;
    if (metrics.shadow) {
        const float shadow_reach = std::max(std::abs(metrics.shadow_offset_px.x()),
                                            std::abs(metrics.shadow_offset_px.y())) +
                                   metrics.outline_px + metrics.shadow_half_px;
        reach = std::max(reach, shadow_reach);
    }
    return std::min(reach, metrics.range_px);
}

float Smoothstep(float low, float high, float value) {
    const float t = std::clamp((value - low) / (high - low), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

// Felzenszwalb and Huttenlocher's squared distance transform along one line: the
// lower envelope of the parabolas rooted at each cell, `grid` read and rewritten
// in place.
void SquaredDistanceLine(float* grid, std::size_t offset, std::size_t stride, std::size_t length,
                         std::vector<float>& f, std::vector<std::size_t>& v, std::vector<float>& z) {
    constexpr float kInfinity = 1.0e20f;
    for (std::size_t q = 0; q < length; ++q) f[q] = grid[offset + q * stride];
    std::size_t k = 0;
    v[0]          = 0;
    z[0]          = -kInfinity;
    z[1]          = kInfinity;
    const auto intersection = [&](std::size_t q, std::size_t r) {
        return ((f[q] + static_cast<float>(q * q)) - (f[r] + static_cast<float>(r * r))) /
               (2.0f * static_cast<float>(q) - 2.0f * static_cast<float>(r));
    };
    for (std::size_t q = 1; q < length; ++q) {
        float s = intersection(q, v[k]);
        while (s <= z[k] && k > 0) {
            --k;
            s = intersection(q, v[k]);
        }
        ++k;
        v[k]     = q;
        z[k]     = s;
        z[k + 1] = kInfinity;
    }
    k = 0;
    for (std::size_t q = 0; q < length; ++q) {
        while (z[k + 1] < static_cast<float>(q)) ++k;
        const float delta = static_cast<float>(q) - static_cast<float>(v[k]);
        grid[offset + q * stride] = f[v[k]] + delta * delta;
    }
}

void SquaredDistanceTransform(std::vector<float>& grid, std::size_t width, std::size_t height) {
    const std::size_t longest = std::max(width, height);
    std::vector<float>       f(longest);
    std::vector<std::size_t> v(longest);
    std::vector<float>       z(longest + 1);
    for (std::size_t x = 0; x < width; ++x) SquaredDistanceLine(grid.data(), x, width, height, f, v, z);
    for (std::size_t y = 0; y < height; ++y) SquaredDistanceLine(grid.data(), y * width, 1, width, f, v, z);
}

// The signed distance, in pixels and positive inside, from each pixel's centre to
// the edge of the glyphs `coverage` holds, with the edge where coverage is half.
// A pixel only partly covered places the edge inside itself, so a straight edge
// comes out to the sub-pixel.
std::vector<float> SignedDistanceField(const std::vector<uint8_t>& coverage, std::size_t width,
                                       std::size_t height, float range) {
    constexpr float kInfinity = 1.0e20f;
    std::vector<float> outside(width * height), inside(width * height);
    for (std::size_t index = 0; index < coverage.size(); ++index) {
        const float a = static_cast<float>(coverage[index]) / 255.0f;
        if (a >= 1.0f) {
            outside[index] = 0.0f;
            inside[index]  = kInfinity;
        } else if (a <= 0.0f) {
            outside[index] = kInfinity;
            inside[index]  = 0.0f;
        } else {
            const float d  = 0.5f - a;
            outside[index] = d > 0.0f ? d * d : 0.0f;
            inside[index]  = d < 0.0f ? d * d : 0.0f;
        }
    }
    SquaredDistanceTransform(outside, width, height);
    SquaredDistanceTransform(inside, width, height);
    std::vector<float> field(width * height);
    for (std::size_t index = 0; index < field.size(); ++index) {
        field[index] = std::clamp(std::sqrt(inside[index]) - std::sqrt(outside[index]), -range, range);
    }
    return field;
}

float SampleField(const std::vector<float>& field, std::size_t width, std::size_t height, float x,
                  float y, float outside_value) {
    // Pixel centres sit at integers here; beyond the grid is far outside.
    const float fx = std::floor(x), fy = std::floor(y);
    const float tx = x - fx, ty = y - fy;
    const auto at = [&](float px, float py) {
        const long ix = static_cast<long>(px), iy = static_cast<long>(py);
        if (ix < 0 || iy < 0 || ix >= static_cast<long>(width) || iy >= static_cast<long>(height)) {
            return outside_value;
        }
        return field[static_cast<std::size_t>(iy) * width + static_cast<std::size_t>(ix)];
    };
    const float top    = at(fx, fy) * (1.0f - tx) + at(fx + 1.0f, fy) * tx;
    const float bottom = at(fx, fy + 1.0f) * (1.0f - tx) + at(fx + 1.0f, fy + 1.0f) * tx;
    return top * (1.0f - ty) + bottom * ty;
}

// Turns the coverage of the glyphs into the three masks the font shader mixes:
// red the glyph, green the glyph with its outline and blur, blue the shadow,
// already with its opacity. Alpha is whatever is drawn at all.
void ComposeStyledText(const StyleMetrics& style, const std::vector<uint8_t>& coverage,
                       uint32_t width, uint32_t height, std::vector<uint8_t>& rgba) {
    const std::size_t w = width, h = height;
    // The field is only needed where something could be drawn.
    std::size_t min_x = w, max_x = 0, min_y = h, max_y = 0;
    for (std::size_t y = 0; y < h; ++y) {
        for (std::size_t x = 0; x < w; ++x) {
            if (coverage[y * w + x] == 0u) continue;
            min_x = std::min(min_x, x);
            max_x = std::max(max_x, x);
            min_y = std::min(min_y, y);
            max_y = std::max(max_y, y);
        }
    }
    if (min_x > max_x) return;

    const auto  reach = static_cast<std::size_t>(std::ceil(StyleReach(style))) + 2u;
    const auto  shadow_x = static_cast<std::size_t>(std::ceil(std::abs(style.shadow_offset_px.x())));
    const auto  shadow_y = static_cast<std::size_t>(std::ceil(std::abs(style.shadow_offset_px.y())));
    const std::size_t pad_x = reach + (style.shadow ? shadow_x : 0u);
    const std::size_t pad_y = reach + (style.shadow ? shadow_y : 0u);
    const std::size_t x0 = min_x > pad_x ? min_x - pad_x : 0u;
    const std::size_t y0 = min_y > pad_y ? min_y - pad_y : 0u;
    const std::size_t x1 = std::min(w, max_x + pad_x + 1u);
    const std::size_t y1 = std::min(h, max_y + pad_y + 1u);
    const std::size_t rw = x1 - x0, rh = y1 - y0;

    std::vector<uint8_t> region(rw * rh);
    for (std::size_t y = 0; y < rh; ++y) {
        std::copy_n(coverage.begin() + static_cast<std::ptrdiff_t>((y0 + y) * w + x0), rw,
                    region.begin() + static_cast<std::ptrdiff_t>(y * rw));
    }
    const auto field = SignedDistanceField(region, rw, rh, style.range_px);

    const auto edge = [&](float distance, float extra) {
        if (style.smooth) {
            return Smoothstep(-style.edge_half_px, style.edge_half_px, distance + extra);
        }
        return std::clamp(distance + 0.5f + extra, 0.0f, 1.0f);
    };
    const auto byte = [](float value) {
        return static_cast<uint8_t>(std::lround(std::clamp(value, 0.0f, 1.0f) * 255.0f));
    };
    for (std::size_t y = 0; y < rh; ++y) {
        for (std::size_t x = 0; x < rw; ++x) {
            const float distance = field[y * rw + x];
            const float fill     = edge(distance, 0.0f);
            const float outer    = style.outline ? edge(distance, style.outline_px) : fill;
            float       shadow   = 0.0f;
            if (style.shadow) {
                const float sampled =
                    SampleField(field, rw, rh, static_cast<float>(x) - style.shadow_offset_px.x(),
                                static_cast<float>(y) - style.shadow_offset_px.y(), -style.range_px);
                const float extra = style.outline ? style.outline_px : 0.0f;
                shadow = std::clamp(
                    style.shadow_opacity *
                        Smoothstep(-style.shadow_half_px, style.shadow_half_px, sampled + extra),
                    0.0f, 1.0f);
            }
            const std::size_t offset = ((y0 + y) * w + (x0 + x)) * 4u;
            rgba[offset + 0u] = byte(fill);
            rgba[offset + 1u] = byte(outer);
            rgba[offset + 2u] = byte(shadow);
            rgba[offset + 3u] = byte(std::max(outer, shadow));
        }
    }
}

Eigen::Vector2f MeasureFallbackText(const TextLayerState& state) {
    const auto lines   = BuildFallbackLines(state);
    const auto metrics = FallbackMetrics(state);
    return CardSizeForBlock(state, MeasureTextBlock(lines, metrics.ascender, metrics.pitch));
}

// Paints the fallback's boxes, calling `plot(x, y, coverage)` for each pixel.
template<typename Plot>
void RasterizeFallbackText(const TextLayerState& state, uint32_t width, uint32_t height,
                           Plot&& plot) {
    const auto lines    = BuildFallbackLines(state);
    const auto metrics  = FallbackMetrics(state);
    const auto block    = MeasureTextBlock(lines, metrics.ascender, metrics.pitch);
    const auto padding  = CardPadding(state) + Eigen::Vector2f::Constant(TextStyleMargin(state));
    const float glyph_height = std::max(1.0f, metrics.ascender);
    float baseline = BlockTopY(state, padding.y(), height, block.Height()) + block.top;
    for (const auto& line : lines) {
        float pen = HorizontalLineStart(state, line.LayoutWidth(), padding.x(), width) - line.ExtentLeft();
        for (const auto& glyph : line.glyphs) {
            if (glyph.has_ink) {
                const float top = baseline - glyph_height;
                for (int y = std::max(0, int(std::floor(top))); y < std::min(int(height), int(std::ceil(baseline))); ++y) {
                    for (int x = std::max(0, int(std::floor(pen))); x < std::min(int(width), int(std::ceil(pen + glyph.right))); ++x) {
                        plot(x, y, uint8_t { 255 });
                    }
                }
            }
            pen += glyph.advance;
        }
        baseline += block.pitch;
        if (block.pitch > 0.0f && baseline - glyph_height >= static_cast<float>(height)) break;
    }
}

// Paints the text with FreeType, calling `plot(x, y, coverage)` for each pixel a
// glyph covers; the caller decides what a pixel of coverage becomes. False when
// there is no face to paint with.
template<typename Plot>
bool RasterizeFreeTypeText(const TextLayerState& state, uint32_t width, uint32_t height,
                           Plot&& plot) {
    if (state.text.empty()) return true;

    std::vector<uint8_t> font_data;
    auto                 face = CreateFreeTypeFace(state, font_data);
    if (face == nullptr) return false;
    auto fallback_face = CreateFallbackFace(state);

    const auto lines =
        BuildFreeTypeLines(state, face.get(), fallback_face ? fallback_face->face.get() : nullptr);

    const auto metrics = FaceMetrics(state, face.get());
    const auto block   = MeasureTextBlock(lines, metrics.ascender, metrics.pitch);
    // The style's margin is clear room around the card the text is laid out in.
    const auto padding = CardPadding(state) + Eigen::Vector2f::Constant(TextStyleMargin(state));

    float baseline_y = BlockTopY(state, padding.y(), height, block.Height()) + block.top;
    for (const auto& line : lines) {
        const float left_edge = HorizontalLineStart(state, line.LayoutWidth(), padding.x(), width);
        float pen_x = left_edge - line.ExtentLeft();
        for (const auto& glyph : line.glyphs) {
            FT_Face glyph_face =
                glyph.fallback && fallback_face ? fallback_face->face.get() : face.get();
            if (FT_Load_Char(glyph_face, glyph.codepoint, FT_LOAD_RENDER | FT_LOAD_TARGET_NORMAL) !=
                0) {
                pen_x += glyph.advance;
                continue;
            }

            const FT_GlyphSlot slot   = glyph_face->glyph;
            const FT_Bitmap&   bitmap = slot->bitmap;
            const int          left   = static_cast<int>(std::lround(pen_x)) + slot->bitmap_left;
            const int          top   = static_cast<int>(std::lround(baseline_y)) - slot->bitmap_top;
            const auto         pitch = static_cast<std::size_t>(std::abs(bitmap.pitch));

            for (uint32_t row = 0; row < bitmap.rows; ++row) {
                const int dest_y = top + static_cast<int>(row);
                if (dest_y < 0 || dest_y >= static_cast<int>(height)) continue;
                const uint32_t source_row = bitmap.pitch >= 0 ? row : bitmap.rows - 1u - row;

                for (uint32_t column = 0; column < bitmap.width; ++column) {
                    const int dest_x = left + static_cast<int>(column);
                    if (dest_x < 0 || dest_x >= static_cast<int>(width)) continue;

                    const auto coverage =
                        bitmap.buffer[static_cast<std::size_t>(source_row) * pitch + column];
                    if (coverage == 0u) continue;
                    plot(dest_x, dest_y, coverage);
                }
            }

            pen_x += glyph.advance;
            if (pen_x >= static_cast<float>(width)) break;
        }
        baseline_y += block.pitch;
        if (block.pitch > 0.0f && baseline_y >= static_cast<float>(height) + block.pitch) break;
    }

    return true;
}

std::optional<Eigen::Vector2f> MeasureFreeTypeText(const TextLayerState& state) {
    std::vector<uint8_t> font_data;
    auto                 face = CreateFreeTypeFace(state, font_data);
    if (face == nullptr) return std::nullopt;
    auto fallback_face = CreateFallbackFace(state);

    const auto lines =
        BuildFreeTypeLines(state, face.get(), fallback_face ? fallback_face->face.get() : nullptr);
    const auto metrics = FaceMetrics(state, face.get());
    return CardSizeForBlock(state, MeasureTextBlock(lines, metrics.ascender, metrics.pitch));
}

std::size_t LineCount(std::string_view text) {
    if (text.empty()) return 1;
    return static_cast<std::size_t>(std::count(text.begin(), text.end(), '\n')) + 1u;
}

std::size_t LongestLineCodepoints(std::string_view text) {
    std::size_t longest = 0;
    std::size_t current = 0;
    for (unsigned char ch : text) {
        if (ch == '\n') {
            longest = std::max(longest, current);
            current = 0;
            continue;
        }
        if ((ch & 0xC0u) != 0x80u) ++current;
    }
    return std::max(longest, current);
}

bool HasExplicitTextLayerSize(const TextLayerState& state) {
    return state.explicit_size.x() > 0.0f && state.explicit_size.y() > 0.0f;
}

} // namespace

// The raster holds the card, which is the authored size where the text fits in
// it, with the room its style reaches into on every side.
Eigen::Vector2f TextLayerRasterSizeForMeasured(const TextLayerState& state,
                                               const Eigen::Vector2f& measured) {
    const Eigen::Vector2f card =
        HasExplicitTextLayerSize(state) ? state.explicit_size.cwiseMax(measured) : measured;
    return card + Eigen::Vector2f::Constant(2.0f * TextStyleMargin(state));
}

bool TextStyleActive(const TextStyle& style) { return style.outline || style.blur || style.drop_shadow; }

float TextStyleMargin(const TextLayerState& state) {
    if (! TextStyleActive(state.style)) return 0.0f;
    // One pixel more than the style reaches, for the edge's own antialiasing.
    return std::ceil(StyleReach(ResolveStyleMetrics(state.style, state.point_size))) + 1.0f;
}

Eigen::Vector2f EstimateTextLayerSize(std::string_view text, float point_size, float padding) {
    if (! std::isfinite(padding) || padding < 0.0f) padding = 0.0f;

    const float pixel_size  = PointSizeToPixels(point_size);
    const float glyph_width = std::max(1.0f, pixel_size * 0.6f);
    const float line_height = std::max(1.0f, pixel_size * 1.2f);
    const auto  columns     = std::max<std::size_t>(1u, LongestLineCodepoints(text));
    const auto  lines       = std::max<std::size_t>(1u, LineCount(text));

    return Eigen::Vector2f(static_cast<float>(columns) * glyph_width + padding * 2.0f,
                           static_cast<float>(lines) * line_height + padding * 2.0f);
}

Eigen::Vector2f MeasureTextLayerSize(const TextLayerState& state) {
#ifdef WESCENE_BUILD_TESTS
    ++g_measurement_count;
#endif
    std::optional<Eigen::Vector2f> measured;
    {
        const std::lock_guard lock { g_freetype_mutex };
        measured = MeasureFreeTypeText(state);
    }
    if (measured.has_value()) {
        return *measured;
    }
    return MeasureFallbackText(state);
}

Eigen::Vector2f TextLayerLayoutSize(const TextLayerState& state) {
    if (HasExplicitTextLayerSize(state)) {
        return state.explicit_size;
    }
    return MeasureTextLayerSize(state);
}

Eigen::Vector2f TextLayerRasterSize(const TextLayerState& state) {
    return TextLayerRasterSizeForMeasured(state, MeasureTextLayerSize(state));
}

TextScreenAnchor ParseTextScreenAnchor(std::string_view name) {
    constexpr std::pair<std::string_view, TextScreenAnchor> kAnchors[] = {
        { "center", TextScreenAnchor::Center },
        { "top", TextScreenAnchor::Top },
        { "topright", TextScreenAnchor::TopRight },
        { "right", TextScreenAnchor::Right },
        { "bottomright", TextScreenAnchor::BottomRight },
        { "bottom", TextScreenAnchor::Bottom },
        { "bottomleft", TextScreenAnchor::BottomLeft },
        { "left", TextScreenAnchor::Left },
        { "topleft", TextScreenAnchor::TopLeft },
    };
    for (const auto& [text, anchor] : kAnchors) {
        if (name == text) return anchor;
    }
    return TextScreenAnchor::None;
}

Eigen::Vector2f TextScreenAnchorOffset(TextScreenAnchor anchor, const PresentedMargins& margins) {
    const float centre_x = (margins.left - margins.right) * 0.5f;
    const float centre_y = (margins.bottom - margins.top) * 0.5f;
    switch (anchor) {
    case TextScreenAnchor::Center: return { centre_x, centre_y };
    case TextScreenAnchor::Top: return { centre_x, -margins.top };
    case TextScreenAnchor::Bottom: return { centre_x, margins.bottom };
    case TextScreenAnchor::Left: return { margins.left, centre_y };
    case TextScreenAnchor::Right: return { -margins.right, centre_y };
    case TextScreenAnchor::TopLeft: return { margins.left, -margins.top };
    case TextScreenAnchor::TopRight: return { -margins.right, -margins.top };
    case TextScreenAnchor::BottomLeft: return { margins.left, margins.bottom };
    case TextScreenAnchor::BottomRight: return { -margins.right, margins.bottom };
    case TextScreenAnchor::None: break;
    }
    return Eigen::Vector2f::Zero();
}

TextLayerRenderBounds TextLayerRenderBoundsForRasterSize(const TextLayerState& state,
                                                         Eigen::Vector2f raster_size) {
    // The card is placed as the layout dictates; the room the style needs lies
    // outside it on every side.
    const float margin = TextStyleMargin(state);
    raster_size        = (raster_size - Eigen::Vector2f::Constant(2.0f * margin)).cwiseMax(1.0f);
    const Eigen::Vector2f layout_size =
        HasExplicitTextLayerSize(state) ? state.explicit_size : raster_size;

    TextLayerRenderBounds bounds {
        .left   = raster_size.x() * -0.5f,
        .right  = raster_size.x() * 0.5f,
        .bottom = raster_size.y() * -0.5f,
        .top    = raster_size.y() * 0.5f,
    };

    if (ContainsSubstring(state.horizontal_align, "left")) {
        bounds.left  = layout_size.x() * -0.5f;
        bounds.right = bounds.left + raster_size.x();
    } else if (ContainsSubstring(state.horizontal_align, "right")) {
        bounds.right = layout_size.x() * 0.5f;
        bounds.left  = bounds.right - raster_size.x();
    }

    const std::string_view vertical_align =
        state.vertical_align.empty() ? state.anchor : state.vertical_align;
    if (ContainsSubstring(vertical_align, "bottom")) {
        bounds.bottom = layout_size.y() * -0.5f;
        bounds.top    = bounds.bottom + raster_size.y();
    } else if (ContainsSubstring(vertical_align, "top")) {
        bounds.top    = layout_size.y() * 0.5f;
        bounds.bottom = bounds.top - raster_size.y();
    }

    bounds.left -= margin;
    bounds.right += margin;
    bounds.bottom -= margin;
    bounds.top += margin;
    return bounds;
}

TextLayerRenderFrame TextLayerRenderFrameForRasterSize(const TextLayerState& state,
                                                       Eigen::Vector2f raster_size) {
    const auto bounds = TextLayerRenderBoundsForRasterSize(state, raster_size);
    return {
        .bounds = bounds,
        .size   = Eigen::Vector2f(bounds.right - bounds.left, bounds.top - bounds.bottom),
        .center = Eigen::Vector2f((bounds.left + bounds.right) * 0.5f,
                                  (bounds.bottom + bounds.top) * 0.5f),
    };
}

TextLayerRenderFrame TextLayerRenderFrameForCapacity(const TextLayerState& state,
                                                     Eigen::Vector2f raster_size,
                                                     Eigen::Vector2f capacity_size) {
    const auto frame = TextLayerRenderFrameForRasterSize(state, raster_size);
    return TextLayerRenderFrameForTargetExtent(frame, capacity_size);
}

TextLayerRenderFrame TextLayerRenderFrameForTargetExtent(const TextLayerRenderFrame& frame,
                                                         Eigen::Vector2f target_extent) {
    return {
        .bounds = {
            .left = frame.center.x() - (target_extent.x() * 0.5f),
            .right = frame.center.x() + (target_extent.x() * 0.5f),
            .bottom = frame.center.y() - (target_extent.y() * 0.5f),
            .top = frame.center.y() + (target_extent.y() * 0.5f),
        },
        .size = target_extent,
        .center = frame.center,
    };
}

TextLayerRenderFrame TextLayerRenderFrameClampedToTarget(const TextLayerRenderFrame& frame,
                                                         const TextLayerRenderFrame& target) {
    const TextLayerRenderBounds bounds {
        .left   = std::clamp(frame.bounds.left, target.bounds.left, target.bounds.right),
        .right  = std::clamp(frame.bounds.right, target.bounds.left, target.bounds.right),
        .bottom = std::clamp(frame.bounds.bottom, target.bounds.bottom, target.bounds.top),
        .top    = std::clamp(frame.bounds.top, target.bounds.bottom, target.bounds.top),
    };
    return {
        .bounds = bounds,
        .size   = Eigen::Vector2f(bounds.right - bounds.left, bounds.top - bounds.bottom),
        .center = Eigen::Vector2f((bounds.left + bounds.right) * 0.5f,
                                  (bounds.bottom + bounds.top) * 0.5f),
    };
}

TextLayerTextureBounds TextLayerTextureBoundsForRenderTarget(const TextLayerRenderFrame& frame,
                                                             Eigen::Vector2f target_size,
                                                             Eigen::Vector2f target_center) {
    if (target_size.x() <= 0.0f || target_size.y() <= 0.0f) return {};

    const auto target_left   = target_center.x() - (target_size.x() * 0.5f);
    const auto target_bottom = target_center.y() - (target_size.y() * 0.5f);
    return {
        .left = (frame.bounds.left - target_left) / target_size.x(),
        .right = (frame.bounds.right - target_left) / target_size.x(),
        .bottom = 1.0f - ((frame.bounds.bottom - target_bottom) / target_size.y()),
        .top = 1.0f - ((frame.bounds.top - target_bottom) / target_size.y()),
    };
}

std::string TextTextureName(std::string_view layer_key) {
    return "runtime/text/" + std::string(layer_key);
}

void RasterizeTextLayer(const TextLayerState& state, uint32_t width, uint32_t height,
                        std::vector<uint8_t>& rgba) {
    // Paints the text, FreeType's part under its lock, into `plot`.
    const auto paint = [&](auto&& plot) {
        bool rasterized = false;
        {
            const std::lock_guard lock { g_freetype_mutex };
            rasterized = RasterizeFreeTypeText(state, width, height, plot);
        }
        if (! rasterized) RasterizeFallbackText(state, width, height, plot);
    };

    if (TextStyleActive(state.style)) {
        // The style mixes the coverage of the glyphs into three masks; see
        // ComposeStyledText.
        std::vector<uint8_t> coverage(static_cast<std::size_t>(width) * height, 0u);
        paint([&](int x, int y, uint8_t value) {
            auto& pixel = coverage[static_cast<std::size_t>(y) * width + static_cast<std::size_t>(x)];
            pixel       = std::max(pixel, value);
        });
        ComposeStyledText(ResolveStyleMetrics(state.style, state.point_size), coverage, width,
                          height, rgba);
        return;
    }

    const auto  color       = TextColorBytes(state);
    const float alpha_scale = static_cast<float>(color[3]) / 255.0f;
    paint([&](int x, int y, uint8_t coverage) {
        const auto alpha =
            static_cast<uint8_t>(std::lround(static_cast<float>(coverage) * alpha_scale));
        const std::size_t offset =
            (static_cast<std::size_t>(y) * width + static_cast<std::size_t>(x)) * 4u;
        rgba[offset + 0u] = color[0];
        rgba[offset + 1u] = color[1];
        rgba[offset + 2u] = color[2];
        rgba[offset + 3u] = std::max(rgba[offset + 3u], alpha);
    });
}

#ifdef WESCENE_BUILD_TESTS
uint64_t TextLayerMeasurementCountForTests() {
    return g_measurement_count.load();
}

void ResetTextLayerMeasurementCountForTests() {
    g_measurement_count.store(0);
}
#endif

TextLayer::TextLayer(TextLayerState state): m_state(std::move(state)) {
    if (m_state.resolved_font_identity.empty()) m_state.resolved_font_identity = m_state.font_key;
    if (m_state.resolved_font_kind.empty()) m_state.resolved_font_kind = "family";
    EnsureCacheIdentity();
    Relayout();
    MarkCacheDirty();
    m_state.dirty = false;
}

void TextLayer::SetText(std::string text) {
    if (m_state.text == text) return;
    m_state.text           = std::move(text);
    m_state.dirty          = true;
    m_state.layout_pending = true;
    MarkCacheDirty();
}

bool TextLayer::ApplyPreparedLayout(uint64_t revision, Eigen::Vector2f layout_size,
                                    Eigen::Vector2f raster_size) {
    if (revision <= m_prepared_revision || revision > m_state.cache_revision) return false;
    m_prepared_revision   = revision;
    m_state.layout_size   = layout_size;
    m_state.raster_size   = raster_size;
    m_state.layout_pending = revision != m_state.cache_revision;
    return true;
}

void TextLayer::ClearDirty() {
    m_state.dirty       = false;
    m_state.cache_dirty = false;
    m_state.full_dirty  = false;
}

Eigen::Vector2f TextLayer::rasterSize() const { return m_state.raster_size; }

TextLayerRenderBounds TextLayer::renderBounds() const {
    return TextLayerRenderBoundsForRasterSize(m_state, rasterSize());
}

void TextLayer::Relayout() {
    const auto measured_size = MeasureTextLayerSize(m_state);
    m_state.layout_size = HasExplicitTextLayerSize(m_state) ? m_state.explicit_size : measured_size;
    m_state.raster_size = TextLayerRasterSizeForMeasured(m_state, measured_size);
    m_state.layout_pending = false;
}

void TextLayer::EnsureCacheIdentity() {
    if (! m_state.texture_cache_key.empty()) return;
    const std::string material = m_state.layer_key + "|" + m_state.text + "|" +
                                 m_state.resolved_font_kind + "|" + m_state.resolved_font_identity +
                                 "|" + m_state.resolved_font_path + "|" +
                                 std::to_string(m_state.point_size) + "|" +
                                 std::to_string(m_state.max_width) + "|" +
                                 std::to_string(m_state.max_rows) + "|" +
                                 std::to_string(m_state.limit_width) + "|" +
                                 std::to_string(m_state.limit_rows) + "|" +
                                 std::to_string(m_state.use_ellipsis) + "|" +
                                 std::to_string(m_state.block_align) + "|" +
                                 std::to_string(m_state.padding.x()) + "|" +
                                 std::to_string(m_state.padding.y()) + "|" +
                                 std::to_string(m_state.spacing.x()) + "|" +
                                 std::to_string(m_state.spacing.y()) + "|" +
                                 std::to_string(m_state.style.outline) + "|" +
                                 std::to_string(m_state.style.outline_thickness) + "|" +
                                 std::to_string(m_state.style.blur) + "|" +
                                 std::to_string(m_state.style.blur_size) + "|" +
                                 std::to_string(m_state.style.drop_shadow) + "|" +
                                 std::to_string(m_state.style.shadow_size) + "|" +
                                 std::to_string(m_state.style.shadow_opacity) + "|" +
                                 std::to_string(m_state.style.shadow_offset.x()) + "|" +
                                 std::to_string(m_state.style.shadow_offset.y());
    m_state.texture_cache_key = "textcache:" + std::to_string(std::hash<std::string> {}(material));
}

void TextLayer::MarkCacheDirty() {
    ++m_state.cache_revision;
    m_state.cache_dirty = true;
    m_state.full_dirty  = true;
}

} // namespace wallpaper
