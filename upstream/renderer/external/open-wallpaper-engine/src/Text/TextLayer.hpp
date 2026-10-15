#pragma once

#include <Eigen/Dense>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace wallpaper
{

class SharedFontData {
public:
    using const_iterator = std::vector<uint8_t>::const_iterator;

    SharedFontData() = default;
    SharedFontData(std::vector<uint8_t> data) {
        if (! data.empty()) {
            m_data = std::make_shared<std::vector<uint8_t>>(std::move(data));
        }
    }
    SharedFontData(const SharedFontData&) noexcept            = default;
    SharedFontData(SharedFontData&&) noexcept                 = default;
    SharedFontData& operator=(const SharedFontData&) noexcept = default;
    SharedFontData& operator=(SharedFontData&&) noexcept      = default;

    SharedFontData& operator=(std::vector<uint8_t> data) {
        m_data.reset();
        if (! data.empty()) {
            m_data = std::make_shared<std::vector<uint8_t>>(std::move(data));
        }
        return *this;
    }

    bool empty() const { return storage().empty(); }
    std::size_t size() const { return storage().size(); }
    const uint8_t* data() const { return storage().data(); }
    const std::vector<uint8_t>& bytes() const { return storage(); }
    const_iterator begin() const { return storage().begin(); }
    const_iterator end() const { return storage().end(); }

private:
    const std::vector<uint8_t>& storage() const {
        static const std::vector<uint8_t> empty;
        return m_data == nullptr ? empty : *m_data;
    }

    std::shared_ptr<const std::vector<uint8_t>> m_data;
};

/// The look Wallpaper Engine gives text through its signed-distance-field font
/// shader: an outline around the glyphs, soft edges, and a drop shadow. The
/// fields are the scene file's, in the units it writes them in; they are pixels
/// of the rasterised text, as Wallpaper Engine scales them with the point size.
/// `msdf` alone only changes how that shader reconstructs the glyph edges, which
/// FreeType's own coverage already gives, so it has no field here.
struct TextStyle {
    bool            outline { false };
    float           outline_thickness { 4.0f };
    Eigen::Vector3f outline_color { Eigen::Vector3f::Zero() };
    bool            blur { false };
    float           blur_size { 6.0f };
    bool            drop_shadow { false };
    float           shadow_size { 6.0f };
    float           shadow_opacity { 1.0f };
    Eigen::Vector2f shadow_offset { 4.0f, 4.0f };
    Eigen::Vector3f shadow_color { Eigen::Vector3f::Zero() };
};

/// True when the text is drawn through the font shader's outline, blur or
/// shadow combos, which Wallpaper Engine turns on from the same fields.
bool TextStyleActive(const TextStyle& style);

/// Where a text layer's origin sits along each axis of its text. Wallpaper
/// Engine registers `horizontalalign` and `verticalalign` as enumerations whose
/// words match exactly (case counts) and, when nothing matches, takes the
/// registry's first entry: `left` for the horizontal one, `center` for the
/// vertical one (its registry is built in the order center, top, bottom).
enum class TextHorizontalAlign
{
    Left,
    Center,
    Right,
};

enum class TextVerticalAlign
{
    Bottom,
    Center,
    Top,
};

TextHorizontalAlign ParseTextHorizontalAlign(std::string_view word);
TextVerticalAlign   ParseTextVerticalAlign(std::string_view word);
std::string_view    TextHorizontalAlignWord(TextHorizontalAlign align);
std::string_view    TextVerticalAlignWord(TextVerticalAlign align);

/// The anchor string the node's placement reads for an alignment, as
/// "<horizontal> <vertical>" ("left top", "center center"): its edge words move the
/// layer's origin onto the edge the text is aligned to, and the string being there
/// at all marks the layer as placed by its own anchor, which a centred one is too.
std::string TextAlignmentAnchor(TextHorizontalAlign horizontal, TextVerticalAlign vertical);

struct TextLayerState {
    std::string          text;
    std::string          layer_key;
    std::string          font_key;
    std::string          resolved_font_kind { "family" };
    std::string          resolved_font_identity;
    std::string          resolved_font_path;
    // The PostScript name of the face to open in `resolved_font_path`, for a file
    // that holds several (a collection). Empty opens the file's first face.
    std::string          resolved_font_face;
    SharedFontData       resolved_font_data;
    float                point_size { 12.0f };
    // The margin the card keeps clear around the text on each axis, in pixels.
    // This is the authored `padding` where Wallpaper Engine applies it -- the
    // layer has effect passes, a colour blend or an opaque background -- and
    // zero on a plain text layer.
    Eigen::Vector2f      padding { Eigen::Vector2f::Zero() };
    // The authored `spacing`: pixels added to every glyph's advance (x) and to
    // the line pitch (y), at the rasterised size.
    Eigen::Vector2f      spacing { Eigen::Vector2f::Zero() };
    Eigen::Vector2f      explicit_size { Eigen::Vector2f::Zero() };
    Eigen::Vector3f      color { Eigen::Vector3f::Ones() };
    float                alpha { 1.0f };
    float                brightness { 1.0f };
    // The words `horizontalalign` and `verticalalign` take, read through
    // `ParseTextHorizontalAlign` and `ParseTextVerticalAlign`.
    std::string          horizontal_align { "center" };
    std::string          vertical_align { "center" };
    float                max_width { 0.0f };
    uint32_t             max_rows { 0 };
    bool                 limit_width { false };
    bool                 limit_rows { false };
    bool                 use_ellipsis { false };
    // `blockalign`: rows that end at a word wrap are justified to `max_width`.
    bool                 block_align { false };
    TextStyle            style;
    bool                 dirty { false };
    bool                 cache_dirty { false };
    bool                 full_dirty { false };
    bool                 layout_pending { false };
    uint64_t             cache_revision { 0 };
    std::string          texture_cache_key;
    std::string          render_backend { "runtime-rgba-texture" };
    Eigen::Vector2f      layout_size { Eigen::Vector2f::Zero() };
    Eigen::Vector2f      raster_size { Eigen::Vector2f::Zero() };
};

/// Wallpaper Engine's text `anchor`: pins the layer to an edge or corner of the
/// area the display actually shows, which is smaller or larger than the scene's
/// canvas when the display's shape differs from it. It is separate from the
/// layer's horizontal and vertical alignment, which place the text around the
/// layer's own origin.
enum class TextScreenAnchor
{
    None,
    Center,
    Top,
    TopRight,
    Right,
    BottomRight,
    Bottom,
    BottomLeft,
    Left,
    TopLeft,
};

/// How far the presented area reaches into the scene's canvas on each side, in
/// scene units: positive where the canvas is cropped, negative where the display
/// shows more than the canvas. All zero when the display shows the canvas as is.
struct PresentedMargins {
    float left { 0.0f };
    float top { 0.0f };
    float right { 0.0f };
    float bottom { 0.0f };

    bool operator==(const PresentedMargins&) const = default;
};

/// The anchor named by a scene file; anything unnamed is `None`.
TextScreenAnchor ParseTextScreenAnchor(std::string_view name);

/// The shift an anchor adds to the layer's placement in its parent's space, y up:
/// the layer follows the edge or corner of the presented area it is pinned to.
Eigen::Vector2f TextScreenAnchorOffset(TextScreenAnchor anchor, const PresentedMargins& margins);

struct TextLayerRenderBounds {
    float left { 0.0f };
    float right { 0.0f };
    float bottom { 0.0f };
    float top { 0.0f };
};

struct TextLayerRenderFrame {
    TextLayerRenderBounds bounds;
    Eigen::Vector2f       size { Eigen::Vector2f::Zero() };
    Eigen::Vector2f       center { Eigen::Vector2f::Zero() };
};

struct TextLayerTextureBounds {
    float left { 0.0f };
    float right { 1.0f };
    float bottom { 1.0f };
    float top { 0.0f };
};

class TextLayer {
public:
    explicit TextLayer(TextLayerState state);

    const TextLayerState& state() const { return m_state; }
    const std::string&    text() const { return m_state.text; }
    Eigen::Vector2f       size() const { return m_state.layout_size; }
    Eigen::Vector2f       rasterSize() const;
    TextLayerRenderBounds renderBounds() const;
    bool                  dirty() const { return m_state.dirty; }
    bool                  layoutPending() const { return m_state.layout_pending; }

    void SetText(std::string text);
    // What a script changes about how the text is set, as `thisLayer.pointsize`,
    // `.font` and `.horizontalalign` / `.verticalalign` do. Each one that
    // changes anything schedules a new layout and raster, as new text does.
    void SetPointSize(float point_size);
    void SetFont(std::string font_key, std::string kind, std::string identity, std::string path,
                 std::string face, SharedFontData data);
    void SetAlignment(std::string horizontal, std::string vertical);
    bool ApplyPreparedLayout(uint64_t revision, Eigen::Vector2f layout_size,
                             Eigen::Vector2f raster_size);
    void ClearDirty();

private:
    void Relayout();
    void EnsureCacheIdentity();
    void MarkCacheDirty();

    TextLayerState m_state;
    uint64_t m_prepared_revision { 0 };
};

/// How far the outline, blur and shadow reach past the text on each side, in
/// pixels. The raster is this much larger than the card on every side, and the
/// card the layer draws grows with it, so nothing is cut off at the layout box.
float TextStyleMargin(const TextLayerState& state);

Eigen::Vector2f EstimateTextLayerSize(std::string_view text, float point_size, float padding);
Eigen::Vector2f MeasureTextLayerSize(const TextLayerState& state);
Eigen::Vector2f TextLayerLayoutSize(const TextLayerState& state);
Eigen::Vector2f TextLayerRasterSize(const TextLayerState& state);
/// `TextLayerRasterSize` for a text already measured: the authored size where the
/// text fits in it, else the text's card, and the room the style reaches on every side.
Eigen::Vector2f TextLayerRasterSizeForMeasured(const TextLayerState& state,
                                               const Eigen::Vector2f& measured);
TextLayerRenderBounds TextLayerRenderBoundsForRasterSize(const TextLayerState& state,
                                                         Eigen::Vector2f raster_size);
TextLayerRenderFrame TextLayerRenderFrameForRasterSize(const TextLayerState& state,
                                                       Eigen::Vector2f raster_size);
TextLayerRenderFrame TextLayerRenderFrameForCapacity(const TextLayerState& state,
                                                     Eigen::Vector2f raster_size,
                                                     Eigen::Vector2f capacity_size);
TextLayerRenderFrame TextLayerRenderFrameForTargetExtent(const TextLayerRenderFrame& frame,
                                                         Eigen::Vector2f target_extent);
TextLayerRenderFrame TextLayerRenderFrameClampedToTarget(const TextLayerRenderFrame& frame,
                                                         const TextLayerRenderFrame& target);
TextLayerTextureBounds TextLayerTextureBoundsForRenderTarget(const TextLayerRenderFrame& frame,
                                                             Eigen::Vector2f target_size,
                                                             Eigen::Vector2f target_center);
std::string     TextTextureName(std::string_view layer_key);
void            RasterizeTextLayer(const TextLayerState& state, uint32_t width, uint32_t height,
                                   std::vector<uint8_t>& rgba);
#ifdef WESCENE_BUILD_TESTS
uint64_t        TextLayerMeasurementCountForTests();
void            ResetTextLayerMeasurementCountForTests();
/// What the font faces have cost since `ResetTextFontCacheForTests`, which also drops
/// every face the cache holds: font files opened (a face found in the cache is not
/// one), glyph-fallback faces asked for (one per layout that lacks a glyph), and
/// faces the cache holds now.
uint64_t        TextFontFilesOpenedForTests();
uint64_t        TextFallbackFaceRequestsForTests();
std::size_t     TextFontFacesCachedForTests();
/// Whether every face the cache holds reads from its file (a mapping, as FreeType opens
/// one) and not from a copy of the font in memory.
bool            TextFontFacesAreReadFromFilesForTests();
void            ResetTextFontCacheForTests();
#endif

} // namespace wallpaper
