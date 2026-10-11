package dev.posle.creatures;

import net.minecraft.world.phys.AABB;

/** Standalone geometry regression test; run with Gradle's geometryTest task. */
public final class CreeperProximityTest {
    private CreeperProximityTest() {}

    public static void main(String[] args) {
        AABB target = new AABB(-0.3, 0.0, -0.3, 0.3, 1.8, 0.3);
        AABB axial = new AABB(1.2, 0.0, -0.3, 1.8, 1.7, 0.3);
        AABB diagonal = new AABB(1.2, 0.0, 1.2, 1.8, 1.7, 1.8);
        if (!CreeperProximity.withinGap(axial, target, 1.0)) {
            throw new AssertionError("0.9-block axial hitbox gap must trigger");
        }
        if (CreeperProximity.withinGap(diagonal, target, 1.0)) {
            throw new AssertionError("1.27-block diagonal hitbox gap must not trigger");
        }
        System.out.println("PASS: axial 0.9 triggers; diagonal sqrt(0.9^2+0.9^2) does not");
    }
}
