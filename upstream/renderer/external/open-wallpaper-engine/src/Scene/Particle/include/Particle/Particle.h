#pragma once

#include <Eigen/Core>

namespace wallpaper
{

struct Particle {
    struct InitValue {
        Eigen::Vector3f color { 1.0f, 1.0f, 1.0f };
        float           alpha { 1.0f };
        float           size { 20 };
        float           lifetime { 1.0f };
        /// Fixed per particle, in [0, 1). Picks a `randomframe` sprite.
        float           frame { 0.0f };
    };
    Eigen::Vector3f position { 0.0f, 0.0f, 0.0f };
    Eigen::Vector3f color { 1.0f, 1.0f, 1.0f };
    float           alpha { 1.0f };
    float           size { 20 };
    float           lifetime { 1.0f };

    Eigen::Vector3f rotation { 0.0f, 0.0f, 0.0f }; // radian  z x y
    Eigen::Vector3f velocity { 0.0f, 0.0f, 0.0f };
    Eigen::Vector3f acceleration { 0.0f, 0.0f, 0.0f };
    Eigen::Vector3f angularVelocity { 0.0f, 0.0f, 0.0f };
    Eigen::Vector3f angularAcceleration { 0.0f, 0.0f, 0.0f };

    /// Fixed per particle, in [0, 1). One draw at spawn that every operator
    /// reading "this particle's random" shares (oscillators, turbulence),
    /// as Wallpaper Engine keeps one per particle.
    float     seed { 0.0f };

    /// Where the movement operator found the particle at the start of its
    /// last step, kept only while an operator asks for it (a control point
    /// attraction that removes particles it passes). Equal to the spawn
    /// position until the first step.
    Eigen::Vector3f prev_position { 0.0f, 0.0f, 0.0f };

    bool      mark_new { true };
    InitValue init {};
};
} // namespace wallpaper
