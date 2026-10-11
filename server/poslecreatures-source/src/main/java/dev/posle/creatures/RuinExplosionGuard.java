package dev.posle.creatures;

import java.util.Set;

import net.minecraft.resources.ResourceLocation;
import net.minecraft.world.entity.Entity;
import net.minecraftforge.event.level.ExplosionEvent;
import net.minecraftforge.eventbus.api.EventPriority;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.registries.ForgeRegistries;

/** Prevent block damage from creeper blasts while retaining entity damage. */
public final class RuinExplosionGuard {
    private static final ResourceLocation MUTANT_CREEPER =
            new ResourceLocation("mutantmonsters", "mutant_creeper");
    private static final Set<ResourceLocation> CREEPERS_WITH_BLOCK_GUARD = Set.of(
            new ResourceLocation("minecraft", "creeper"),
            new ResourceLocation("unique_mobs", "blossom_creeper"),
            new ResourceLocation("unique_mobs", "burrowing_creeper"),
            new ResourceLocation("unique_mobs", "ender_creeper"),
            new ResourceLocation("unique_mobs", "frost_creeper"),
            new ResourceLocation("unique_mobs", "lightning_creeper"),
            new ResourceLocation("unique_mobs", "magma_creeper"),
            new ResourceLocation("unique_mobs", "sculk_creeper"),
            new ResourceLocation("unique_mobs", "toxic_creeper"),
            new ResourceLocation("unique_mobs", "wither_creeper"));

    private RuinExplosionGuard() {}

    static boolean shouldPreventBlockDamage(ResourceLocation sourceId, boolean allowCreeperTerrainDamage) {
        if (MUTANT_CREEPER.equals(sourceId)) return true;
        return !allowCreeperTerrainDamage && CREEPERS_WITH_BLOCK_GUARD.contains(sourceId);
    }

    @SubscribeEvent(priority = EventPriority.LOWEST)
    public static void onDetonate(ExplosionEvent.Detonate event) {
        if (event.getLevel().isClientSide()) return;
        Entity source = event.getExplosion().getDirectSourceEntity();
        if (source == null) return;
        ResourceLocation sourceId = ForgeRegistries.ENTITY_TYPES.getKey(source.getType());
        if (shouldPreventBlockDamage(sourceId, PosleCreatures.BREAK_BLOCKS.get())) {
            event.getAffectedBlocks().clear();
        }
    }
}
