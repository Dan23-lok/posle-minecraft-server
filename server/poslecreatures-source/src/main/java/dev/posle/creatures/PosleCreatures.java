package dev.posle.creatures;

import net.minecraftforge.common.ForgeConfigSpec;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.fml.ModLoadingContext;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.config.ModConfig;

@Mod(PosleCreatures.MOD_ID)
public final class PosleCreatures {
    public static final String MOD_ID = "poslecreatures";

    private static final ForgeConfigSpec.Builder BUILDER = new ForgeConfigSpec.Builder();
    public static final ForgeConfigSpec.DoubleValue TRIGGER_GAP = BUILDER
            .comment("Distance in blocks between creeper and player hitboxes that triggers an immediate blast.")
            .defineInRange("triggerGapBlocks", 1.0D, 0.5D, 1.5D);
    public static final ForgeConfigSpec.DoubleValue MOVE_SPEED = BUILDER
            .comment("Movement speed of vanilla creepers. Vanilla base is 0.25.")
            .defineInRange("movementSpeed", 0.35D, 0.25D, 0.50D);
    public static final ForgeConfigSpec.DoubleValue NORMAL_POWER = BUILDER
            .comment("Explosion strength of an ordinary vanilla creeper.")
            .defineInRange("normalPower", 3.0D, 1.0D, 4.0D);
    public static final ForgeConfigSpec.DoubleValue CHARGED_POWER = BUILDER
            .comment("Explosion strength of a charged vanilla creeper.")
            .defineInRange("chargedPower", 5.0D, 2.0D, 6.0D);
    public static final ForgeConfigSpec.BooleanValue BREAK_BLOCKS = BUILDER
            .comment("Allow vanilla and Unique Mobs creeper explosions to damage terrain. Keep false until ruin support/cleanup is verified.")
            .define("breakBlocks", false);
    private static final ForgeConfigSpec SPEC = BUILDER.build();

    public PosleCreatures() {
        ModLoadingContext.get().registerConfig(ModConfig.Type.COMMON, SPEC);
        MinecraftForge.EVENT_BUS.register(CreeperBehavior.class);
        MinecraftForge.EVENT_BUS.register(RuinExplosionGuard.class);
    }
}
