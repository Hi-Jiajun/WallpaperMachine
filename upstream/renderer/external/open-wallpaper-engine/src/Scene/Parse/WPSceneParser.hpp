#pragma once
#include "Interface/ISceneParser.h"

#include <string>
#include <string_view>
#include <random>
#include <vector>

namespace wallpaper
{
struct SceneMaterial;
struct WPShaderInfo;
class RuntimeImageSource;

namespace wpscene
{
class WPMaterial;
struct WPUserTexture;
}

/// Substitutes the texture slots a material delegates. Two kinds arrive in the
/// same `usertextures` list: the cover slots the runtime supplies itself, and a
/// slot that names one of the wallpaper's own `scenetexture` properties. The
/// second kind needs the property table to resolve, so a parse without one
/// leaves those slots on their authored texture.
///
/// A cover slot whose position also has an authored texture keeps that texture
/// until the runtime has a cover to show, as Wallpaper Engine does, when
/// `covers` is given: the slot is then bound through `BindCoverSlot` and holds
/// the name that shows the authored picture until a cover arrives. Without
/// `covers` it names the cover itself.
void ApplySystemUserTextures(std::vector<std::string>& textures,
                             const std::vector<wpscene::WPUserTexture>& usertextures,
                             const ProjectProperties* properties = nullptr,
                             RuntimeImageSource* covers = nullptr);
/// The property a `usertextures` slot names (the bare-string form), or empty for
/// a slot the runtime supplies or one that names nothing. The scene reads such a
/// property once, while it loads.
std::string_view UserTexturePropertyName(const wpscene::WPUserTexture& user_texture);
void LoadMaterialConstantShaderValues(SceneMaterial& material, const wpscene::WPMaterial& wpmat,
                                      const WPShaderInfo& info);

class WPSceneParser : public ISceneParser {
public:
    WPSceneParser()  = default;
    ~WPSceneParser() = default;
    std::shared_ptr<Scene> Parse(const SceneParseRequest&, const std::string&, fs::VFS&, audio::SoundManager&) override;
    std::shared_ptr<Scene> Parse(std::string_view scene_id, const std::string&, fs::VFS&, audio::SoundManager&);
};
} // namespace wallpaper
