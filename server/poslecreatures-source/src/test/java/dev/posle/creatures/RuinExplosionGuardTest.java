package dev.posle.creatures;

import net.minecraft.resources.ResourceLocation;

/** Regression checks for the targeted explosion-source predicate. */
public final class RuinExplosionGuardTest {
    private RuinExplosionGuardTest() {}

    public static void main(String[] args) {
        String[] uniqueMobsCreepers = {
                "blossom_creeper", "burrowing_creeper", "ender_creeper", "frost_creeper",
                "lightning_creeper", "magma_creeper", "sculk_creeper", "toxic_creeper", "wither_creeper"
        };
        for (String name : uniqueMobsCreepers) {
            assertGuard("unique_mobs:" + name, false, true);
            assertGuard("unique_mobs:" + name, true, false);
        }
        assertGuard("minecraft:creeper", true, false);
        assertGuard("mutantmonsters:mutant_creeper", false, true);
        assertGuard("mutantmonsters:mutant_creeper", true, true);
        assertGuard("minecraft:tnt", false, false);
        assertGuard("unique_mobs:venomous_zombie", false, false);
        assertGuard("minecraft:creeper", false, true);
        System.out.println("PASS: exact creeper registry IDs protected; TNT and unrelated mobs unchanged");
    }

    private static void assertGuard(String entityId, boolean allowVanillaTerrainDamage, boolean expected) {
        boolean actual = RuinExplosionGuard.shouldPreventBlockDamage(
                new ResourceLocation(entityId), allowVanillaTerrainDamage);
        if (actual != expected) {
            throw new AssertionError(entityId + " allowVanillaTerrainDamage=" + allowVanillaTerrainDamage
                    + " expected=" + expected + " actual=" + actual);
        }
    }
}
