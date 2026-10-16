#include "WPShaderValueUpdater.hpp"
#include "Eigen/src/Core/Matrix.h"
#include "Eigen/src/Geometry/Transform.h"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "SpriteAnimation.hpp"
#include "SpecTexs.hpp"
#include "Core/ArrayHelper.hpp"
#include "Utils/Algorism.h"
#include "Utils/TimeOfDay.hpp"

#include <Eigen/Dense>
#include <Eigen/Geometry>
#include <iostream>
#include <chrono>
#include <ctime>
#include <numeric>
#include <vector>
#include <span>
#include <algorithm>
#include <cmath>

using namespace wallpaper;
using namespace Eigen;

namespace
{

constexpr std::string_view G_AUDIO_SPECTRUM16_LEFT  = "g_AudioSpectrum16Left";
constexpr std::string_view G_AUDIO_SPECTRUM16_RIGHT = "g_AudioSpectrum16Right";
constexpr std::string_view G_AUDIO_SPECTRUM32_LEFT  = "g_AudioSpectrum32Left";
constexpr std::string_view G_AUDIO_SPECTRUM32_RIGHT = "g_AudioSpectrum32Right";
constexpr std::string_view G_AUDIO_SPECTRUM64_LEFT  = "g_AudioSpectrum64Left";
constexpr std::string_view G_AUDIO_SPECTRUM64_RIGHT = "g_AudioSpectrum64Right";
constexpr std::string_view G_NORMALMODEL            = "g_NormalModelMatrix";

constexpr std::string_view G_LPOINT_COLOR         = "g_LPoint_Color";
constexpr std::string_view G_LPOINT_ORIGIN        = "g_LPoint_Origin";
constexpr std::string_view G_LSPOT_COLOR          = "g_LSpot_Color";
constexpr std::string_view G_LSPOT_ORIGIN         = "g_LSpot_Origin";
constexpr std::string_view G_LSPOT_DIRECTION      = "g_LSpot_Direction";
constexpr std::string_view G_LSPOT_EXPONENT       = "g_LSpot_Exponent";
constexpr std::string_view G_LTUBE_COLOR          = "g_LTube_Color";
constexpr std::string_view G_LTUBE_ORIGINA        = "g_LTube_OriginA";
constexpr std::string_view G_LTUBE_ORIGINB        = "g_LTube_OriginB";
constexpr std::string_view G_LDIRECTIONAL_COLOR   = "g_LDirectional_Color";
constexpr std::string_view G_LDIRECTIONAL_DIRECTION = "g_LDirectional_Direction";
constexpr std::array       kLightingV1Uniforms {
    G_LPOINT_COLOR,  G_LPOINT_ORIGIN,  G_LSPOT_COLOR,        G_LSPOT_ORIGIN,
    G_LSPOT_DIRECTION, G_LSPOT_EXPONENT, G_LTUBE_COLOR,      G_LTUBE_ORIGINA,
    G_LTUBE_ORIGINB, G_LDIRECTIONAL_COLOR, G_LDIRECTIONAL_DIRECTION,
};

/// One frame's `LightingV1` uniform arrays, four floats per slot, laid out as
/// Wallpaper Engine fills them: each kind's visible lights in scene order, up
/// to the count the scene's light config compiled its shaders for, with unused
/// slots left zero.
struct LightingV1Arrays {
    std::vector<float> point_color, point_origin;
    std::vector<float> spot_color, spot_origin, spot_direction, spot_exponent;
    std::vector<float> tube_color, tube_origin_a, tube_origin_b;
    std::vector<float> directional_color, directional_direction;
};

void PutVec4(std::vector<float>& array, std::size_t slot, const Vector3d& xyz, float w) {
    array[slot * 4 + 0] = static_cast<float>(xyz.x());
    array[slot * 4 + 1] = static_cast<float>(xyz.y());
    array[slot * 4 + 2] = static_cast<float>(xyz.z());
    array[slot * 4 + 3] = w;
}

LightingV1Arrays PackLightingV1(const Scene& scene) {
    const auto&      config = scene.light_config;
    LightingV1Arrays arrays;
    for (auto* array : { &arrays.point_color, &arrays.point_origin }) array->assign(config.point * 4, 0.0f);
    for (auto* array : { &arrays.spot_color, &arrays.spot_origin, &arrays.spot_direction,
                         &arrays.spot_exponent })
        array->assign(config.spot * 4, 0.0f);
    for (auto* array : { &arrays.tube_color, &arrays.tube_origin_a, &arrays.tube_origin_b })
        array->assign(config.tube * 4, 0.0f);
    for (auto* array : { &arrays.directional_color, &arrays.directional_direction })
        array->assign(config.directional * 4, 0.0f);

    std::size_t point = 0, spot = 0, tube = 0, directional = 0;
    constexpr double kDegrees = 3.14159265358979323846 / 180.0;
    for (const auto& light : scene.lights) {
        if (light == nullptr || light->node() == nullptr || ! light->visible()) continue;
        auto* node = light->node();
        node->UpdateTrans();
        const Matrix4d  world  = node->ModelTrans();
        const Vector3d  origin = world.block<3, 1>(0, 3);
        // The light's own x axis, scale included, is the way a spot or
        // directional light points.
        const Vector3d  axis   = world.block<3, 1>(0, 0);
        const Vector3d  color  = (light->color() * light->intensity()).cast<double>();
        switch (light->type()) {
        case SceneLightType::Point:
            if (point >= config.point) break;
            PutVec4(arrays.point_color, point, color, light->radius());
            PutVec4(arrays.point_origin, point, origin, light->exponent());
            ++point;
            break;
        case SceneLightType::Spot:
            if (spot >= config.spot) break;
            PutVec4(arrays.spot_color, spot, color, light->radius());
            PutVec4(arrays.spot_origin, spot, origin,
                    static_cast<float>(std::cos(light->innerCone() * kDegrees)));
            PutVec4(arrays.spot_direction, spot, axis,
                    static_cast<float>(std::cos(light->outerCone() * kDegrees)));
            arrays.spot_exponent[spot * 4] = light->exponent();
            ++spot;
            break;
        case SceneLightType::Tube: {
            if (tube >= config.tube) break;
            const Vector4d far_end =
                world * light->controlPoint().cast<double>().homogeneous();
            PutVec4(arrays.tube_color, tube, color, light->radius());
            PutVec4(arrays.tube_origin_a, tube, origin, light->exponent());
            PutVec4(arrays.tube_origin_b, tube, far_end.head<3>(), 0.0f);
            ++tube;
            break;
        }
        case SceneLightType::Directional:
            if (directional >= config.directional) break;
            PutVec4(arrays.directional_color, directional, color, 1.0f);
            // Towards the light: it shines along its own x axis.
            PutVec4(arrays.directional_direction, directional, -axis, 0.0f);
            ++directional;
            break;
        case SceneLightType::Legacy: break;
        }
    }
    return arrays;
}

/// The legacy four-light packing: positions in `g_LightsPosition`, colours
/// premultiplied by intensity and radius squared in three vec4s, the fourth
/// light's channels in their w lanes.
struct LegacyLightArrays {
    std::array<float, 16> positions { 0 };
    std::array<float, 12> colors { 0 };
};

LegacyLightArrays PackLegacyLights(const Scene& scene) {
    LegacyLightArrays arrays;
    uint              i = 0;
    for (const auto& l : scene.lights) {
        if (i == 4) break;
        if (l == nullptr || l->type() != SceneLightType::Legacy || l->node() == nullptr) continue;
        if (! l->visible()) continue;
        l->node()->UpdateTrans();
        const Vector3d trans = l->node()->ModelTrans().block<3, 1>(0, 3);
        for (size_t axis = 0; axis < 3; ++axis) {
            arrays.positions[i * 4 + axis] = static_cast<float>(trans[axis]);
        }
        const auto color = l->premultipliedColor();
        if (i < 3) {
            std::copy(color.begin(), color.end(), arrays.colors.begin() + i * 4);
        } else {
            // Three vec4 uniforms hold four RGB lights: the last light's
            // channels occupy the w component of each of the first three.
            for (size_t channel = 0; channel < 3; ++channel) {
                arrays.colors[channel * 4 + 3] = color[channel];
            }
        }
        i++;
    }
    return arrays;
}

uint64_t HashFloats(uint64_t hash, const float* values, std::size_t count) {
    const auto* bytes = reinterpret_cast<const unsigned char*>(values);
    for (std::size_t i = 0; i < count * sizeof(float); ++i) {
        hash = (hash ^ bytes[i]) * 0x100000001b3ULL;
    }
    return hash;
}

} // namespace

void WPShaderValueUpdater::FrameBegin() {
    for (auto& group : m_puppetAttachments) UpdatePuppetAttachments(group);
    if (const auto day_time = LocalTimeOfDay(m_wall_clock())) m_dayTime = *day_time;
    // A zero delay (authored as `cameraparallaxdelay: 0`) means no smoothing:
    // the cursor is followed at once, the limit of the ramp below. Dividing by
    // it made `t` NaN, which latched into the smoothed cursor and, through
    // parallax, into every layer's model matrix, so only the clear colour drew.
    double t = 1.0;
    if (m_parallax.delay > 0.0f) {
        double new_time    = m_mouseDelayedTime + m_scene->frameTime;
        new_time           = new_time > m_parallax.delay ? m_parallax.delay : new_time;
        m_mouseDelayedTime = new_time;
        t                  = new_time / m_parallax.delay;
    } else {
        m_mouseDelayedTime = 0.0;
    }
    m_mousePosLast     = m_mousePos;
    m_mousePos         = std::array { (float)algorism::lerp(t, m_mousePos[0], m_mousePosInput[0]),
                              (float)algorism::lerp(t, m_mousePos[1], m_mousePosInput[1]) };
}

void WPShaderValueUpdater::FrameEnd() {}

uint64_t WPShaderValueUpdater::LightStateHash(SceneNode* node, uint32_t material_slot) const {
    if (node == nullptr || m_scene == nullptr) return 0;
    const auto slots = m_nodeUniformInfoMap.find(node);
    if (slots == m_nodeUniformInfoMap.end()) return 0;
    auto it = slots->second.find(material_slot);
    if (it == slots->second.end()) it = slots->second.find(0);
    if (it == slots->second.end()) return 0;
    const auto& info = it->second;
    if (! info.has_LP && ! info.has_LCP && ! info.has_LIGHTS_V1) return 0;

    uint64_t hash = 0xcbf29ce484222325ULL;
    if (info.has_LP || info.has_LCP) {
        const auto legacy = PackLegacyLights(*m_scene);
        hash = HashFloats(hash, legacy.positions.data(), legacy.positions.size());
        hash = HashFloats(hash, legacy.colors.data(), legacy.colors.size());
    }
    if (info.has_LIGHTS_V1) {
        const auto lights = PackLightingV1(*m_scene);
        for (const auto* values : {
                 &lights.point_color, &lights.point_origin, &lights.spot_color, &lights.spot_origin,
                 &lights.spot_direction, &lights.spot_exponent, &lights.tube_color,
                 &lights.tube_origin_a, &lights.tube_origin_b, &lights.directional_color,
                 &lights.directional_direction }) {
            hash = HashFloats(hash, values->data(), values->size());
        }
    }
    // Zero is "reads no lights"; a material that does never hashes to it.
    return hash == 0 ? 1 : hash;
}

uint32_t WPShaderValueUpdater::FrameVaryingUniforms(SceneNode*          node,
                                                    uint32_t            material_slot,
                                                    const std::string& camera_override) const {
    // Reflection captured at InitUniforms is the authority. A node the updater
    // never saw is reported as varying in every way, because absence of a
    // record is not evidence that nothing advances.
    if (node == nullptr || ! exists(m_nodeUniformInfoMap, node)) return frame_varying_uniform::kAll;
    const auto& slot_infos = m_nodeUniformInfoMap.at(node);
    auto        it         = slot_infos.find(material_slot);
    if (it == slot_infos.end()) it = slot_infos.find(0);
    if (it == slot_infos.end()) return frame_varying_uniform::kAll;

    const auto& info  = it->second;
    uint32_t    flags = frame_varying_uniform::kNone;
    if (info.has_TIME || info.has_FRAMETIME) flags |= frame_varying_uniform::kTime;
    if (info.has_DAYTIME || info.has_DAYTIME_ALIAS) flags |= frame_varying_uniform::kDayTime;
    if (info.has_POINTERPOSITION || info.has_POINTERPOSITIONLAST || info.has_POINTERSTATE)
        flags |= frame_varying_uniform::kPointer;
    if (info.has_PARALLAXPOSITION) flags |= frame_varying_uniform::kParallax;
    if (info.has_BONES) flags |= frame_varying_uniform::kBones;
    if (info.has_AudioSpectrum16Left || info.has_AudioSpectrum16Right ||
        info.has_AudioSpectrum32Left || info.has_AudioSpectrum32Right ||
        info.has_AudioSpectrum64Left || info.has_AudioSpectrum64Right)
        flags |= frame_varying_uniform::kAudio;
    // Camera parallax moves a layer with the cursor through its model matrix.
    // No uniform the shader declares reveals that, and the static cache hashes
    // the node's transform without it: unreported, the pass is reused while the
    // cursor moves, and a still scene never wakes for the pointer. Decided for
    // the camera the pass draws through, as UpdateUniforms decides it: the
    // effect camera and a layer-local one never move a layer, so a composite
    // another layer samples stays reusable.
    if (m_parallax.enable && m_parallax.amount != 0.0f && m_parallax.mouseinfluence != 0.0f &&
        (info.has_M || info.has_MVP || info.has_MI || info.has_MVPI)) {
        const std::string& cam_name = camera_override.empty() ? node->Camera() : camera_override;
        const SceneCamera* camera   = m_scene->activeCamera;
        if (! cam_name.empty()) {
            const auto found = m_scene->cameras.find(cam_name);
            camera = found != m_scene->cameras.end() ? found->second.get() : nullptr;
        }
        const auto data_slots = m_nodeDataMap.find(node);
        if (camera != nullptr && cam_name != "effect" && ! camera->IsLayerLocal() &&
            data_slots != m_nodeDataMap.end()) {
            auto data = data_slots->second.find(material_slot);
            if (data == data_slots->second.end()) data = data_slots->second.find(0);
            if (data != data_slots->second.end() &&
                (data->second.parallaxDepth[0] != 0.0f || data->second.parallaxDepth[1] != 0.0f)) {
                flags |= frame_varying_uniform::kParallax;
            }
        }
    }
    return flags;
}

void WPShaderValueUpdater::RegisterPuppetAttachments(
    WPPuppetLayer layer, std::vector<PuppetAttachment> attachments) {
    auto& group = m_puppetAttachments.emplace_back(
        PuppetAttachmentGroup { std::move(layer), std::move(attachments) });
    UpdatePuppetAttachments(group);
}

void WPShaderValueUpdater::UpdatePuppetAttachments(PuppetAttachmentGroup& group) {
    const auto bones = group.layer.genFrame(m_scene->elapsingTime);
    for (const auto& attachment : group.attachments) {
        if (attachment.node == nullptr || attachment.bone_index >= bones.size()) continue;
        attachment.node->SetAttachmentTransform(
            (bones[attachment.bone_index] * attachment.bind_transform).matrix().cast<double>());
    }
}

void WPShaderValueUpdater::MouseInput(double x, double y) {
    using namespace std::chrono;

    auto   now_time = steady_clock::now();
    double new_time = m_mouseDelayedTime -
                      duration_cast<duration<double>>(now_time - m_last_mouse_input_time).count();
    m_mouseDelayedTime = new_time < 0.0f ? 0.0f : new_time;

    m_mousePosInput[0] = (float)x;
    m_mousePosInput[1] = (float)y;

    m_last_mouse_input_time = now_time;
}

void WPShaderValueUpdater::InitUniforms(SceneNode* pNode, const ExistsUniformOp& existsOp) {
    InitUniforms(pNode, 0, existsOp);
}

void WPShaderValueUpdater::InitUniforms(SceneNode* pNode, uint32_t material_slot,
                                        const ExistsUniformOp& existsOp) {
    m_nodeUniformInfoMap[pNode][material_slot] = WPUniformInfo();
    auto& info                                = m_nodeUniformInfoMap[pNode][material_slot];
    info.has_MI                 = existsOp(G_MI);
    info.has_M                  = existsOp(G_M);
    info.has_AM                 = existsOp(G_AM);
    info.has_MVP                = existsOp(G_MVP);
    info.has_MVPI               = existsOp(G_MVPI);
    info.has_ETVP               = existsOp(G_ETVP);
    info.has_ETVPI              = existsOp(G_ETVPI);

    info.has_VP = existsOp(G_VP);
    info.has_layer_model  = existsOp("g_LayerModelMatrix");
    info.has_effect_mvp   = existsOp(G_EFFECTMVP);
    info.has_effect_model = existsOp(G_EFFECTMODEL);
    info.has_effect_mvpi  = existsOp(G_EFFECTMVPI);

    info.has_BONES            = existsOp(G_BONES);
    info.has_TIME             = existsOp(G_TIME);
    info.has_DAYTIME          = existsOp(G_DAYTIME);
    info.has_DAYTIME_ALIAS    = existsOp("g_Daytime");
    info.has_POINTERPOSITION  = existsOp(G_POINTERPOSITION);
    info.has_POINTERPOSITIONLAST   = existsOp(G_POINTERPOSITIONLAST);
    info.has_POINTERSTATE          = existsOp(G_POINTERSTATE);
    info.has_FRAMETIME             = existsOp(G_FRAMETIME);
    info.has_TEXTUREREDUCTIONSCALE = existsOp(G_TEXTUREREDUCTIONSCALE);
    info.has_PARALLAXPOSITION = existsOp(G_PARALLAXPOSITION);
    info.has_TEXELSIZE        = existsOp(G_TEXELSIZE);
    info.has_TEXELSIZEHALF    = existsOp(G_TEXELSIZEHALF);
    info.has_SCREEN           = existsOp(G_SCREEN);
    info.has_LP               = existsOp(G_LP);
    info.has_LCP              = existsOp(G_LCP);
    info.has_LIGHTS_V1        = std::any_of(kLightingV1Uniforms.begin(), kLightingV1Uniforms.end(),
                                     [&existsOp](std::string_view name) { return existsOp(name); });
    info.has_NORMALMODEL      = existsOp(G_NORMALMODEL);
    info.has_ORIENTATIONUP      = existsOp(G_ORIENTATIONUP);
    info.has_ORIENTATIONRIGHT   = existsOp(G_ORIENTATIONRIGHT);
    info.has_ORIENTATIONFORWARD = existsOp(G_ORIENTATIONFORWARD);
    info.has_EYE              = existsOp(G_EYEPOSITION);
    info.has_VIEWFORWARD      = existsOp(G_VIEWFORWARD);
    info.has_VIEWUP           = existsOp(G_VIEWUP);
    info.has_VIEWRIGHT        = existsOp(G_VIEWRIGHT);
    info.has_AudioSpectrum16Left = existsOp(G_AUDIO_SPECTRUM16_LEFT);
    info.has_AudioSpectrum16Right = existsOp(G_AUDIO_SPECTRUM16_RIGHT);
    info.has_AudioSpectrum32Left = existsOp(G_AUDIO_SPECTRUM32_LEFT);
    info.has_AudioSpectrum32Right = existsOp(G_AUDIO_SPECTRUM32_RIGHT);
    info.has_AudioSpectrum64Left = existsOp(G_AUDIO_SPECTRUM64_LEFT);
    info.has_AudioSpectrum64Right = existsOp(G_AUDIO_SPECTRUM64_RIGHT);

    if (info.has_AudioSpectrum16Left || info.has_AudioSpectrum16Right ||
        info.has_AudioSpectrum32Left || info.has_AudioSpectrum32Right ||
        info.has_AudioSpectrum64Left || info.has_AudioSpectrum64Right) {
        if (! m_audioSpectrumPacked) {
            m_audioSpectrumPacked.emplace(std::array<float, 64 * 4> {});
        }
        if (m_scene != nullptr && m_scene->runtime != nullptr) {
            m_scene->runtime->MarkSceneRequiresAudioResponse();
        }
    }

    std::accumulate(begin(info.texs), end(info.texs), 0, [&existsOp](uint index, auto& value) {
        value.has_resolution = existsOp(WE_GLTEX_RESOLUTION_NAMES[index]);
        value.has_mipmap     = existsOp(WE_GLTEX_MIPMAPINFO_NAMES[index]);
        value.has_texel      = existsOp(WE_GLTEX_TEXEL_NAMES[index]);
        return index + 1;
    });
}

void WPShaderValueUpdater::UpdateUniforms(SceneNode* pNode, sprite_map_t& sprites,
                                          const UpdateUniformOp& updateOp) {
    UpdateUniforms(pNode, 0, sprites, updateOp);
}

void WPShaderValueUpdater::UpdateUniforms(SceneNode* pNode, uint32_t material_slot,
                                          sprite_map_t& sprites,
                                          const UpdateUniformOp& updateOp) {
    if (! pNode->Mesh()) return;

    pNode->UpdateTrans();

    SceneCamera*      camera;
    std::string_view   cam_name = pNode->Camera();
    if (! pNode->Camera().empty()) {
        camera = m_scene->cameras.at(cam_name.data()).get();
    } else
        camera = m_scene->activeCamera;

    if (! camera) return;

    auto* material = pNode->Mesh()->MaterialForSlot(material_slot);
    if (! material) return;
    // auto& shadervs = material->customShader.updateValueList;
    // const auto& valueSet = material->customShader.valueSet;

    assert(exists(m_nodeUniformInfoMap, pNode));
    const auto& slot_infos = m_nodeUniformInfoMap.at(pNode);
    assert(exists(slot_infos, material_slot));
    const auto& info = slot_infos.at(material_slot);

    WPShaderValueData* nodeData = nullptr;
    if (const auto node_it = m_nodeDataMap.find(pNode); node_it != m_nodeDataMap.end()) {
        auto& slot_data = node_it->second;
        auto        data_it   = slot_data.find(material_slot);
        if (data_it == slot_data.end()) data_it = slot_data.find(0);
        if (data_it != slot_data.end()) nodeData = &data_it->second;
    }
    bool hasNodeData = nodeData != nullptr;
    if (info.has_layer_model || info.has_effect_mvp || info.has_effect_model ||
        info.has_effect_mvpi) {
        auto* owner = hasNodeData && nodeData->effect_owner != nullptr
            ? nodeData->effect_owner : pNode;
        owner->UpdateTrans();
        const Matrix4d layer_model = owner->ModelTrans();
        if (info.has_layer_model) {
            updateOp("g_LayerModelMatrix", ShaderValue::fromMatrix(layer_model));
        }
        Matrix4d effect_model = layer_model;
        // Intermediate passes use a unit quad; final passes use the layer card.
        if (hasNodeData && nodeData->effect_owner != nullptr && cam_name == "effect") {
            effect_model = layer_model * Affine3d(Scaling(
                double(nodeData->effect_extent.x()) * 0.5,
                double(nodeData->effect_extent.y()) * 0.5, 1.0)).matrix();
        }
        // Where the effect quad lands in the scene, for lit effects that
        // shade by world position.
        if (info.has_effect_model) updateOp(G_EFFECTMODEL, ShaderValue::fromMatrix(effect_model));
        if ((info.has_effect_mvp || info.has_effect_mvpi) && m_scene->activeCamera != nullptr) {
            const Matrix4d effect_mvp =
                m_scene->activeCamera->GetViewProjectionMatrix() * effect_model;
            if (info.has_effect_mvp) updateOp(G_EFFECTMVP, ShaderValue::fromMatrix(effect_mvp));
            if (info.has_effect_mvpi)
                updateOp(G_EFFECTMVPI, ShaderValue::fromMatrix(Matrix4d(effect_mvp.inverse())));
        }
    }
    if (hasNodeData) {
        for (const auto& el : nodeData->renderTargets) {
            const auto rt_it = m_scene->renderTargets.find(el.second);
            if (rt_it == m_scene->renderTargets.end()) continue;
            const auto& rt = rt_it->second;

            const auto& unifrom_tex = info.texs[el.first];

            if (unifrom_tex.has_resolution) {
                std::array<i32, 4> resolution_uint({ rt.width, rt.height, rt.width, rt.height });
                updateOp(WE_GLTEX_RESOLUTION_NAMES[el.first],
                         ShaderValue(array_cast<float>(resolution_uint)));
            }
            if (unifrom_tex.has_mipmap) {
                updateOp(WE_GLTEX_MIPMAPINFO_NAMES[el.first], (float)rt.mipmap_level);
            }
            if (unifrom_tex.has_texel && rt.width > 0 && rt.height > 0) {
                const float width  = static_cast<float>(rt.width);
                const float height = static_cast<float>(rt.height);
                updateOp(WE_GLTEX_TEXEL_NAMES[el.first],
                         std::array { 1.0f / width, 1.0f / height, width, height });
            }
        }
        if (nodeData->puppet_layer.hasPuppet() && info.has_BONES) {
            const auto data = nodeData->puppet_layer.genFrame(m_scene->elapsingTime);
            if (! data.empty()) {
                updateOp(G_BONES, std::span<const float> { data.front().data(), data.size() * 16 });
            }
        }
    }

    bool reqMI    = info.has_MI;
    bool reqM     = info.has_M;
    bool reqAM    = info.has_AM;
    bool reqMVP   = info.has_MVP;
    bool reqMVPI  = info.has_MVPI;
    bool reqETVP  = info.has_ETVP;
    bool reqETVPI = info.has_ETVPI;

    // composelayer.vert draws a full local target using UVs, but its MVP is
    // used to sample the *screen* behind the layer. The effect camera and
    // identity render override lose the parent's translation/scale here. That
    // holds wherever the layer is drawn to, its own composite included: the
    // screen behind it is what its card holds.
    // A layer-local camera frames the card in the layer's own texture space,
    // so where the layer sits in the scene -- transform, scene camera and
    // parallax alike -- must not reach the image another layer samples.
    const bool layer_local = camera->IsLayerLocal();
    const bool samples_screen_background = material->name == "composelayer";
    SceneCamera* matrix_camera =
        samples_screen_background && m_scene->activeCamera != nullptr ? m_scene->activeCamera : camera;
    Matrix4d viewProTrans = matrix_camera->GetViewProjectionMatrix();

    if (info.has_VP) {
        updateOp(G_VP, ShaderValue::fromMatrix(viewProTrans));
    }
    if (info.has_ORIENTATIONUP || info.has_ORIENTATIONRIGHT || info.has_ORIENTATIONFORWARD) {
        // Screen-facing particles read the camera node's world axes. The parser
        // writes a constant screen-XY basis; that is only right for an unrotated
        // camera looking down -Z, so the live camera replaces it here.
        const auto axes = camera->GetAxes();
        if (info.has_ORIENTATIONRIGHT) {
            updateOp(G_ORIENTATIONRIGHT,
                     std::array { (float)axes.right.x(), (float)axes.right.y(),
                                  (float)axes.right.z() });
        }
        if (info.has_ORIENTATIONUP) {
            updateOp(G_ORIENTATIONUP,
                     std::array { (float)axes.up.x(), (float)axes.up.y(), (float)axes.up.z() });
        }
        if (info.has_ORIENTATIONFORWARD) {
            updateOp(G_ORIENTATIONFORWARD,
                     std::array { (float)axes.forward.x(), (float)axes.forward.y(),
                                  (float)axes.forward.z() });
        }
    }
    if (reqM || reqMVP || reqMI || reqMVPI || info.has_NORMALMODEL) {
        Matrix4d modelTrans = samples_screen_background ? pNode->ModelTrans()
                              : layer_local             ? Matrix4d::Identity()
                                                        : pNode->RenderTrans();
        if (hasNodeData && cam_name != "effect" && ! layer_local) {
            if (m_parallax.enable) {
                Vector2f depth(&nodeData->parallaxDepth[0]);
                Vector2f ortho { (float)m_scene->ortho[0], (float)m_scene->ortho[1] };
                // flip mouse y axis
                Vector2f mouseVec =
                    Scaling(1.0f, -1.0f) * (Vector2f { 0.5f, 0.5f } - Vector2f(&m_mousePos[0]));
                mouseVec = mouseVec.cwiseProduct(ortho) * m_parallax.mouseinfluence;
                // In a 2D scene parallax moves a layer by the cursor's offset
                // from the centre of the view, scaled by the layer's depth.
                // Where the layer sits plays no part: with the cursor centred
                // every layer rests where it was authored, as Wallpaper
                // Engine's own previews show. Offsetting by the layer's
                // distance from the camera as well pushed a deep layer near the
                // canvas edge -- a planet at the top of a 4K scene -- out of
                // the frame. A 3D scene keeps that distance term: nothing
                // checked so far says how its layers move.
                Vector2f offset = mouseVec;
                if (! m_parallax.canvas_scene) {
                    // Where the layer sits in the scene, not its parent-relative
                    // origin, which is near zero for the child of a centred group.
                    const Vector2f nodePos = modelTrans.block<2, 1>(0, 3).cast<float>();
                    offset += nodePos - camera->GetPosition().cast<float>().head<2>();
                }
                const Vector2f paraVec = offset.cwiseProduct(depth) * m_parallax.amount;
                modelTrans =
                    Affine3d(Translation3d(Vector3d(paraVec.x(), paraVec.y(), 0.0f))).matrix() *
                    modelTrans;
            }
        }

        if (reqM) updateOp(G_M, ShaderValue::fromMatrix(modelTrans));
        if (info.has_NORMALMODEL) {
            // The draw's rotation without its scale: each axis of the model
            // matrix normalised, as a std140 mat3 (three padded columns).
            std::array<float, 12> normal_model { 0 };
            for (int column = 0; column < 3; ++column) {
                Vector3d axis = modelTrans.block<3, 1>(0, column);
                if (axis.squaredNorm() > 0.0) axis.normalize();
                for (int row = 0; row < 3; ++row) {
                    normal_model[column * 4 + row] = static_cast<float>(axis[row]);
                }
            }
            updateOp(G_NORMALMODEL, normal_model);
        }
        if (reqAM) updateOp(G_AM, ShaderValue::fromMatrix(modelTrans));
        if (reqMI) updateOp(G_MI, ShaderValue::fromMatrix(modelTrans.inverse()));
        if (reqMVP) {
            Matrix4d mvpTrans = viewProTrans * modelTrans;
            updateOp(G_MVP, ShaderValue::fromMatrix(mvpTrans));
            if (reqMVPI) updateOp(G_MVPI, ShaderValue::fromMatrix(mvpTrans.inverse()));
        }
        if (reqETVP || reqETVPI) {
            /*
            Vector3d nodePos = pNode->Translate().cast<double>();
            nodePos.z()      = 1.0f;
            Matrix4d etvpTrans =
                viewProTrans * modelTrans * Affine3d(Eigen::Scaling(nodePos)).matrix();
            if (reqETVPI) updateOp(G_ETVP, ShaderValue::fromMatrix(etvpTrans));
            if (reqETVPI) updateOp(G_ETVPI, ShaderValue::fromMatrix(etvpTrans.inverse()));
            */
        }
    }

    //	g_EffectTextureProjectionMatrix
    // shadervs.push_back({"g_EffectTextureProjectionMatrixInverse",
    // ShaderValue::ValueOf(Eigen::Matrix4f::Identity())});
    if (info.has_TIME) updateOp(G_TIME, (float)m_scene->elapsingTime);

    if (info.has_DAYTIME) updateOp(G_DAYTIME, (float)m_dayTime);
    if (info.has_DAYTIME_ALIAS) updateOp("g_Daytime", (float)m_dayTime);

    if (info.has_AudioSpectrum16Left || info.has_AudioSpectrum16Right ||
        info.has_AudioSpectrum32Left || info.has_AudioSpectrum32Right ||
        info.has_AudioSpectrum64Left || info.has_AudioSpectrum64Right) {
        const auto snapshot = m_scene != nullptr && m_scene->runtime != nullptr
            ? m_scene->runtime->CurrentAudioSpectrumSnapshot()
            : wallpaper::audio::AudioSpectrumSnapshot {};

        const auto pushAudioSpectrum = [this, &updateOp](std::string_view name, const auto& values) {
            auto& packed = *m_audioSpectrumPacked;
            packed.setSize(values.size() * 4u);
            for (std::size_t index = 0; index < values.size(); ++index) {
                packed[index * 4u] = values[index];
            }
            updateOp(name, packed);
        };

        if (info.has_AudioSpectrum16Left) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM16_LEFT, snapshot.left16);
        }
        if (info.has_AudioSpectrum16Right) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM16_RIGHT, snapshot.right16);
        }
        if (info.has_AudioSpectrum32Left) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM32_LEFT, snapshot.left32);
        }
        if (info.has_AudioSpectrum32Right) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM32_RIGHT, snapshot.right32);
        }
        if (info.has_AudioSpectrum64Left) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM64_LEFT, snapshot.left64);
        }
        if (info.has_AudioSpectrum64Right) {
            pushAudioSpectrum(G_AUDIO_SPECTRUM64_RIGHT, snapshot.right64);
        }
    }

    if (info.has_POINTERPOSITION) updateOp(G_POINTERPOSITION, m_mousePos);
    // Simulation effects (cursor ripple, fluid) move by the cursor's travel
    // since the last frame and push harder while the primary button is held.
    if (info.has_POINTERPOSITIONLAST) updateOp(G_POINTERPOSITIONLAST, m_mousePosLast);
    if (info.has_POINTERSTATE) {
        const float down = (m_mouseButtonsDown & 1u) != 0 ? 1.0f : 0.0f;
        updateOp(G_POINTERSTATE, std::array { down, down, down, 0.0f });
    }
    // The seconds this frame advances the scene, which simulation steps scale by.
    if (info.has_FRAMETIME) updateOp(G_FRAMETIME, (float)m_scene->frameTime);
    // Textures are always loaded at their authored size, never reduced.
    if (info.has_TEXTUREREDUCTIONSCALE) updateOp(G_TEXTUREREDUCTIONSCALE, 1.0f);

    if (info.has_TEXELSIZE) updateOp(G_TEXELSIZE, m_texelSize);

    if (info.has_TEXELSIZEHALF)
        updateOp(G_TEXELSIZEHALF, std::array { m_texelSize[0] / 2.0f, m_texelSize[1] / 2.0f });

    if (info.has_SCREEN)
        updateOp(G_SCREEN,
                 std::array<float, 3> {
                     m_screen_size[0], m_screen_size[1], m_screen_size[0] / m_screen_size[1] });

    if (info.has_PARALLAXPOSITION) {
        Vector2f para { 0.5f, 0.5f };
        if (m_parallax.enable) {
            const Vector2f mouseCentered = Vector2f(&m_mousePos[0]) - Vector2f { 0.5f, 0.5f };
            para = Vector2f { 0.5f, 0.5f } +
                   (Scaling(1.0f, -1.0f) * mouseCentered) * m_parallax.mouseinfluence;
        }
        updateOp(G_PARALLAXPOSITION, std::array { para[0], para[1] });
    }

    for (auto& [i, sp] : sprites) {
        if (sp.numFrames() == 0) continue;
        const auto& f = pNode->TextureFrame().has_value()
                            ? sp.SetFrame(*pNode->TextureFrame())
                            : sp.GetAnimateFrame(m_scene->frameTime);
        auto        grot   = WE_GLTEX_ROTATION_NAMES[i];
        auto        gtrans = WE_GLTEX_TRANSLATION_NAMES[i];
        updateOp(grot, std::array { f.xAxis[0], f.xAxis[1], f.yAxis[0], f.yAxis[1] });
        updateOp(gtrans, std::array { f.x, f.y });
    }

    if (info.has_LP || info.has_LCP) {
        const auto legacy = PackLegacyLights(*m_scene);
        updateOp(G_LP, legacy.positions);
        updateOp(G_LCP, legacy.colors);
    }
    if (info.has_LIGHTS_V1) {
        const auto lights = PackLightingV1(*m_scene);
        for (const auto& [name, values] : {
                 std::pair { G_LPOINT_COLOR, &lights.point_color },
                 std::pair { G_LPOINT_ORIGIN, &lights.point_origin },
                 std::pair { G_LSPOT_COLOR, &lights.spot_color },
                 std::pair { G_LSPOT_ORIGIN, &lights.spot_origin },
                 std::pair { G_LSPOT_DIRECTION, &lights.spot_direction },
                 std::pair { G_LSPOT_EXPONENT, &lights.spot_exponent },
                 std::pair { G_LTUBE_COLOR, &lights.tube_color },
                 std::pair { G_LTUBE_ORIGINA, &lights.tube_origin_a },
                 std::pair { G_LTUBE_ORIGINB, &lights.tube_origin_b },
                 std::pair { G_LDIRECTIONAL_COLOR, &lights.directional_color },
                 std::pair { G_LDIRECTIONAL_DIRECTION, &lights.directional_direction },
             }) {
            if (! values->empty()) updateOp(name, std::span<const float> { *values });
        }
    }

    if (info.has_EYE || info.has_VIEWFORWARD || info.has_VIEWUP || info.has_VIEWRIGHT) {
        // 2D scenes keep the authored axis-aligned constants. Overwriting them
        // from the ortho camera node (canvas centre, z = 0) collapses particle
        // billboards that subtract g_EyePosition from a layer on the same plane.
        SceneCamera* view_camera = nullptr;
        if (camera != nullptr && camera->IsPerspective()) {
            view_camera = camera;
        } else if (m_scene->activeCamera != nullptr && m_scene->activeCamera->IsPerspective()) {
            view_camera = m_scene->activeCamera;
        }
        if (view_camera != nullptr) {
            const auto to_array = [](const Eigen::Vector3d& value) {
                return std::array<float, 3> { static_cast<float>(value.x()),
                                              static_cast<float>(value.y()),
                                              static_cast<float>(value.z()) };
            };
            if (info.has_EYE) updateOp(G_EYEPOSITION, to_array(view_camera->GetPosition()));
            if (info.has_VIEWFORWARD)
                updateOp(G_VIEWFORWARD, to_array(view_camera->GetDirection()));
            if (info.has_VIEWUP) updateOp(G_VIEWUP, to_array(view_camera->GetUp()));
            if (info.has_VIEWRIGHT) updateOp(G_VIEWRIGHT, to_array(view_camera->GetRight()));
        }
    }
}

void WPShaderValueUpdater::SetNodeData(void* nodeAddr, const WPShaderValueData& data) {
    SetNodeData(nodeAddr, 0, data);
}

void WPShaderValueUpdater::SetNodeData(void* nodeAddr, uint32_t material_slot,
                                       const WPShaderValueData& data) {
    m_nodeDataMap[nodeAddr][material_slot] = data;
}

void WPShaderValueUpdater::ForgetNode(SceneNode* node) {
    m_nodeDataMap.erase(node);
    m_nodeUniformInfoMap.erase(node);
}

void WPShaderValueUpdater::SetTexelSize(float x, float y) { m_texelSize = { x, y }; }
