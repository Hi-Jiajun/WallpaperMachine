#pragma once

#include <string>
#include <string_view>

namespace wallpaper
{

/// An installed face: its file, and the name the system gives it. A font file can
/// hold several faces (`PingFang.ttc` holds the Hong Kong, Macau, Taiwan and
/// Simplified Chinese cuts of the font, `Songti.ttc` its four weights), and the
/// name is what tells them apart: the face to open is the one that has it.
struct SystemFontFace {
    std::string path;
    /// The PostScript name, empty where the platform does not say.
    std::string postscript_name;
};

/// The installed face a `systemfont_` key (or a bare family) names, or the
/// platform's stand-in for a family it does not have. Empty where nothing is
/// installed.
SystemFontFace ResolveSystemFont(std::string_view system_font_key);

/// The file of `ResolveSystemFont`.
std::string ResolveSystemFontPath(std::string_view system_font_key);

} // namespace wallpaper
