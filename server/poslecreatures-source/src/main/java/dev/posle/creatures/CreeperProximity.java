package dev.posle.creatures;

import net.minecraft.world.phys.AABB;

/** Geometric range check for a creeper's hitbox against a player's hitbox. */
final class CreeperProximity {
    private CreeperProximity() {}

    static boolean withinGap(AABB creeper, AABB target, double gap) {
        double dx = Math.max(0.0, Math.max(creeper.minX - target.maxX, target.minX - creeper.maxX));
        double dy = Math.max(0.0, Math.max(creeper.minY - target.maxY, target.minY - creeper.maxY));
        double dz = Math.max(0.0, Math.max(creeper.minZ - target.maxZ, target.minZ - creeper.maxZ));
        return dx * dx + dy * dy + dz * dz <= gap * gap;
    }
}
