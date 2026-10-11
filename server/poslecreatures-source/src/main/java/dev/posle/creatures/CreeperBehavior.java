package dev.posle.creatures;

import java.util.ArrayList;
import java.util.List;

import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.entity.EntityType;
import net.minecraft.world.entity.ai.attributes.AttributeInstance;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.entity.ai.goal.Goal;
import net.minecraft.world.entity.ai.goal.SwellGoal;
import net.minecraft.world.entity.ai.goal.WrappedGoal;
import net.minecraft.world.entity.monster.Creeper;
import net.minecraft.world.level.Level;
import net.minecraftforge.event.entity.EntityJoinLevelEvent;
import net.minecraftforge.event.entity.living.LivingEvent;
import net.minecraftforge.eventbus.api.EventPriority;
import net.minecraftforge.eventbus.api.SubscribeEvent;

/** Server-side changes to vanilla creepers only; modded creeper types retain their own AI. */
public final class CreeperBehavior {
    private CreeperBehavior() {}

    private static boolean isVanillaCreeper(Object entity) {
        return entity instanceof Creeper creeper && creeper.getType() == EntityType.CREEPER;
    }

    @SubscribeEvent(priority = EventPriority.LOWEST)
    public static void onJoin(EntityJoinLevelEvent event) {
        if (event.getLevel().isClientSide() || !isVanillaCreeper(event.getEntity())) return;
        Creeper creeper = (Creeper) event.getEntity();

        // The vanilla swell goal stops navigation and begins its fuse about three blocks away.
        // Remove it so the creeper can keep following its target until our proximity check.
        List<Goal> oldSwellGoals = new ArrayList<>();
        for (WrappedGoal wrapped : creeper.goalSelector.getAvailableGoals()) {
            if (wrapped.getGoal() instanceof SwellGoal) oldSwellGoals.add(wrapped.getGoal());
        }
        for (Goal goal : oldSwellGoals) creeper.goalSelector.removeGoal(goal);

        AttributeInstance speed = creeper.getAttribute(Attributes.MOVEMENT_SPEED);
        if (speed != null) speed.setBaseValue(PosleCreatures.MOVE_SPEED.get());
    }

    @SubscribeEvent(priority = EventPriority.HIGHEST)
    public static void onLivingTick(LivingEvent.LivingTickEvent event) {
        if (!isVanillaCreeper(event.getEntity())) return;
        Creeper creeper = (Creeper) event.getEntity();
        if (creeper.level().isClientSide() || !creeper.isAlive()) return;
        if (creeper.getPersistentData().getBoolean("posleImmediateExplosion")) return;

        double gap = PosleCreatures.TRIGGER_GAP.get();
        List<ServerPlayer> nearby = creeper.level().getEntitiesOfClass(ServerPlayer.class,
                creeper.getBoundingBox().inflate(gap),
                p -> p.isAlive() && !p.isCreative() && !p.isSpectator());
        for (ServerPlayer player : nearby) {
            if (!CreeperProximity.withinGap(creeper.getBoundingBox(), player.getBoundingBox(), gap)) continue;
            if (creeper.hasLineOfSight(player)) {
                creeper.getPersistentData().putBoolean("posleImmediateExplosion", true);
                double selectedPower = creeper.isPowered()
                        ? PosleCreatures.CHARGED_POWER.get()
                        : PosleCreatures.NORMAL_POWER.get();
                float power = (float) selectedPower;
                Level.ExplosionInteraction interaction = PosleCreatures.BREAK_BLOCKS.get()
                        ? Level.ExplosionInteraction.MOB : Level.ExplosionInteraction.NONE;
                creeper.level().explode(creeper, creeper.getX(), creeper.getY(), creeper.getZ(),
                        power, false, interaction);
                creeper.discard();
                return;
            }
        }
    }
}
