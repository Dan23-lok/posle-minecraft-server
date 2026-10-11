package com.authmod;

import com.mojang.logging.LogUtils;
import net.minecraft.network.chat.Component;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.GameType;
import net.minecraftforge.event.CommandEvent;
import net.minecraftforge.event.ServerChatEvent;
import net.minecraftforge.event.TickEvent;
import net.minecraftforge.event.entity.item.ItemTossEvent;
import net.minecraftforge.event.entity.player.*;
import net.minecraftforge.event.level.BlockEvent;
import net.minecraftforge.event.server.ServerStartingEvent;
import net.minecraftforge.event.server.ServerStoppingEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;
import org.slf4j.Logger;

import java.util.Locale;
import java.util.WeakHashMap;

@Mod.EventBusSubscriber(modid = AuthMod.MODID, bus = Mod.EventBusSubscriber.Bus.FORGE)
public class AuthEventHandler {

    private static final Logger LOGGER = LogUtils.getLogger();
    private static final AuthSessionStore<ServerPlayer> sessions = new AuthSessionStore<>();
    private static final WeakHashMap<ServerPlayer, double[]> lastPosition = new WeakHashMap<>();
    private static final WeakHashMap<ServerPlayer, GameType> previousGameMode = new WeakHashMap<>();
    private static final WeakHashMap<ServerPlayer, String> greetedLocale = new WeakHashMap<>();
    private static final WeakHashMap<ServerPlayer, Long> loginDeadlines = new WeakHashMap<>();
    private static long loginDeadline() {
        return System.currentTimeMillis() + AuthConfig.loginTimeoutSeconds() * 1000L;
    }

    @SubscribeEvent
    public static void onServerStarting(ServerStartingEvent event) {
        AuthData.init();
        InviteCode.load();
    }

    @SubscribeEvent
    public static void onServerStopping(ServerStoppingEvent event) {
        AuthData.save();
    }

    // === ВХОД / ВЫХОД ===

    @SubscribeEvent
    public static void onPlayerJoin(PlayerEvent.PlayerLoggedInEvent event) {
        if (!(event.getEntity() instanceof ServerPlayer player)) return;

        String username = player.getGameProfile().getName().toLowerCase(Locale.ROOT);
        LOGGER.info("[AuthMod] Player joined: {}", username);

        sessions.join(player.getUUID(), player);
        loginDeadlines.put(player, loginDeadline());
        lastPosition.put(player, new double[]{player.getX(), player.getY(), player.getZ()});

        lockPlayer(player);
        syncInventoryMenu(player);
        sendAuthMessage(player, Lang.joinLocale(player));
    }

    @SubscribeEvent
    public static void onPlayerQuit(PlayerEvent.PlayerLoggedOutEvent event) {
        if (event.getEntity() instanceof ServerPlayer player) {
            sessions.leave(player.getUUID(), player);
            lastPosition.remove(player);
            previousGameMode.remove(player);
            greetedLocale.remove(player);
            loginDeadlines.remove(player);
        }
    }

    /** Respawn and return from the End create a different ServerPlayer object. */
    @SubscribeEvent
    public static void onPlayerClone(PlayerEvent.Clone event) {
        if (!(event.getOriginal() instanceof ServerPlayer original)
                || !(event.getEntity() instanceof ServerPlayer replacement)) return;
        if (!original.getUUID().equals(replacement.getUUID())) return;

        if (!sessions.transfer(original.getUUID(), original, replacement)) {
            // Missing state starts locked; a stale clone must not displace a newer connection.
            sessions.joinIfAbsent(replacement.getUUID(), replacement);
        }

        GameType priorMode = previousGameMode.remove(original);
        if (priorMode != null) previousGameMode.put(replacement, priorMode);
        Long deadline = loginDeadlines.remove(original);
        if (deadline != null) loginDeadlines.put(replacement, deadline);
        lastPosition.remove(original);
        greetedLocale.remove(original);

        if (!isAuthenticated(replacement)) {
            loginDeadlines.putIfAbsent(replacement, loginDeadline());
            lastPosition.put(replacement, new double[]{replacement.getX(), replacement.getY(), replacement.getZ()});
        }
    }

    @SubscribeEvent
    public static void onPlayerRespawn(PlayerEvent.PlayerRespawnEvent event) {
        if (!(event.getEntity() instanceof ServerPlayer player)) return;
        sessions.joinIfAbsent(player.getUUID(), player);
        if (isAuthenticated(player)) return;

        loginDeadlines.putIfAbsent(player, loginDeadline());
        lastPosition.put(player, new double[]{player.getX(), player.getY(), player.getZ()});
        if (previousGameMode.containsKey(player)) player.setGameMode(GameType.SPECTATOR);
        else lockPlayer(player);
        sendAuthMessage(player, Lang.localeOf(player));
    }

    // === БЛОКИРОВКА ДО АВТОРИЗАЦИИ ===

    @SubscribeEvent
    public static void onPlayerTick(TickEvent.PlayerTickEvent event) {
        if (event.side.isClient() || event.phase != TickEvent.Phase.END) return;
        if (!(event.player instanceof ServerPlayer player)) return;
        if (isAuthenticated(player)) return;

        Long deadline = loginDeadlines.get(player);
        if (deadline != null && System.currentTimeMillis() >= deadline) {
            player.connection.disconnect(Lang.msg(player, "authmod.login.timeout"));
            return;
        }

        // Замок позиции
        double[] last = lastPosition.get(player);
        if (last != null) {
            double dist = player.distanceToSqr(last[0], last[1], last[2]);
            if (dist > 0.01) {
                player.teleportTo(last[0], last[1], last[2]);
                sendReminder(player);
            } else {
                lastPosition.put(player, new double[]{player.getX(), player.getY(), player.getZ()});
            }
        }

        // Когда от клиента дошёл его язык — повторяем приветствие на нём
        if (player.tickCount >= 40 && player.tickCount % 40 == 0) {
            String locale = Lang.localeOf(player);
            if (!locale.equals(greetedLocale.get(player))) {
                sendAuthMessage(player, locale);
            }
        }
    }

    /** До авторизации доступны только /login и /register. */
    @SubscribeEvent
    public static void onCommand(CommandEvent event) {
        ServerPlayer player = event.getParseResults().getContext().getSource().getPlayer();
        if (player == null || isAuthenticated(player)) return;

        String command = event.getParseResults().getReader().getString().trim().toLowerCase(Locale.ROOT);
        if (command.startsWith("/")) command = command.substring(1);
        String head = command.split("\\s+", 2)[0];
        if (head.equals("login") || head.equals("register")) return;

        event.setCanceled(true);
        player.sendSystemMessage(Lang.msg(player, "authmod.command.blocked"));
    }

    @SubscribeEvent
    public static void onChat(ServerChatEvent event) {
        ServerPlayer player = event.getPlayer();
        if (!isAuthenticated(player)) {
            event.setCanceled(true);
            player.sendSystemMessage(Lang.msg(player, "authmod.chat.blocked"));
        }
    }

    @SubscribeEvent
    public static void onInteract(PlayerInteractEvent.RightClickBlock event) {
        if (event.getEntity() instanceof ServerPlayer player && !isAuthenticated(player)) {
            event.setCanceled(true);
            sendReminder(player);
            player.inventoryMenu.broadcastChanges();
        }
    }

    @SubscribeEvent
    public static void onInteractItem(PlayerInteractEvent.RightClickItem event) {
        if (event.getEntity() instanceof ServerPlayer player && !isAuthenticated(player)) {
            event.setCanceled(true);
            sendReminder(player);
        }
    }

    @SubscribeEvent
    public static void onEntityInteract(PlayerInteractEvent.EntityInteract event) {
        if (event.getEntity() instanceof ServerPlayer player && !isAuthenticated(player)) {
            event.setCanceled(true);
            sendReminder(player);
        }
    }

    @SubscribeEvent
    public static void onLeftClickBlock(PlayerInteractEvent.LeftClickBlock event) {
        if (event.getEntity() instanceof ServerPlayer player && !isAuthenticated(player)) {
            event.setCanceled(true);
        }
    }

    @SubscribeEvent
    public static void onBreakBlock(BlockEvent.BreakEvent event) {
        if (event.getPlayer() instanceof ServerPlayer player && !isAuthenticated(player)) {
            event.setCanceled(true);
            sendReminder(player);
        }
    }

    @SubscribeEvent
    public static void onPlaceBlock(BlockEvent.EntityPlaceEvent event) {
        if (event.getEntity() instanceof ServerPlayer player && !isAuthenticated(player)) {
            event.setCanceled(true);
            sendReminder(player);
        }
    }

    @SubscribeEvent
    public static void onAttack(AttackEntityEvent event) {
        if (event.getEntity() instanceof ServerPlayer player && !isAuthenticated(player)) {
            event.setCanceled(true);
            sendReminder(player);
        }
    }

    // === ДРОП ПРЕДМЕТА — ВОЗВРАЩАЕМ В ИНВЕНТАРЬ ===

    @SubscribeEvent
    public static void onItemDrop(ItemTossEvent event) {
        if (event.getPlayer() instanceof ServerPlayer player && !isAuthenticated(player)) {
            event.setCanceled(true);
            ItemStack stack = event.getEntity().getItem();
            if (!stack.isEmpty()) {
                player.getInventory().add(stack);
                player.inventoryMenu.broadcastChanges();
            }
        }
    }

    // === ПОДБОР ПРЕДМЕТА — БЛОКИРУЕМ ===

    @SubscribeEvent
    public static void onItemPickup(EntityItemPickupEvent event) {
        if (event.getEntity() instanceof ServerPlayer player && !isAuthenticated(player)) {
            event.setCanceled(true);
        }
    }

    // === РЕГИСТРАЦИЯ / ВХОД ===

    public static boolean registerPlayer(ServerPlayer player, String password) {
        if (!sessions.isCurrent(player.getUUID(), player)) return false;
        String username = player.getGameProfile().getName().toLowerCase(Locale.ROOT);
        if (AuthData.isRegistered(username)) return false;

        AuthData.setPlayerPassword(username, password);
        try {
            AuthData.save();
        } catch (RuntimeException e) {
            AuthData.removePlayer(username);
            throw e;
        }
        sessions.authenticate(player.getUUID(), player);
        restorePlayer(player);
        return true;
    }

    public static boolean loginPlayer(ServerPlayer player, String password) {
        if (!sessions.isCurrent(player.getUUID(), player)) return false;
        String username = player.getGameProfile().getName().toLowerCase(Locale.ROOT);
        if (AuthData.verifyPassword(username, password)) {
            sessions.authenticate(player.getUUID(), player);
            restorePlayer(player);
            return true;
        }
        return false;
    }

    /** Повторная блокировка онлайн-игрока (например, после сброса пароля админом). */
    public static void forceRelock(ServerPlayer player) {
        String username = player.getGameProfile().getName().toLowerCase(Locale.ROOT);
        sessions.relock(player.getUUID(), player);
        LoginLimiter.reset(username);
        loginDeadlines.put(player, loginDeadline());
        lastPosition.put(player, new double[]{player.getX(), player.getY(), player.getZ()});
        lockPlayer(player);
        sendAuthMessage(player, Lang.localeOf(player));
    }

    public static boolean isAuthenticated(ServerPlayer player) {
        return sessions.isAuthenticated(player.getUUID(), player);
    }

    // === РЕЖИМ НАБЛЮДАТЕЛЯ ДО АВТОРИЗАЦИИ ===

    private static void lockPlayer(ServerPlayer player) {
        GameType current = player.gameMode.getGameModeForPlayer();
        previousGameMode.put(player, current == GameType.SPECTATOR ? GameType.SURVIVAL : current);
        player.setGameMode(GameType.SPECTATOR);
    }

    private static void restorePlayer(ServerPlayer player) {
        GameType mode = previousGameMode.remove(player);
        player.setGameMode(mode == null ? GameType.SURVIVAL : mode);
        loginDeadlines.remove(player);
        syncInventoryMenu(player);
        lastPosition.remove(player);
    }

    /**
     * Отправляет полный InventoryMenu в его ванильном порядке: крафт, броню,
     * основной инвентарь, хотбар и левую руку. Нельзя отправлять только
     * player.getInventory().items: в нём 36 слотов, а в меню игрока — 46.
     */
    private static void syncInventoryMenu(ServerPlayer player) {
        player.server.getPlayerList().sendAllPlayerInfo(player);
    }

    private static void sendAuthMessage(ServerPlayer player, String locale) {
        greetedLocale.put(player, locale);
        player.sendSystemMessage(Component.literal(Lang.text(locale, "authmod.welcome.title")));
        player.sendSystemMessage(Component.literal(Lang.text(locale, "authmod.welcome.header")));
        player.sendSystemMessage(Component.literal(""));
        player.sendSystemMessage(Component.literal(Lang.text(locale, "authmod.welcome.choose")));
        player.sendSystemMessage(Component.literal(Lang.text(locale, "authmod.welcome.login_hint")));
        player.sendSystemMessage(Component.literal(Lang.text(locale, "authmod.welcome.register_hint")));
        player.sendSystemMessage(Component.literal(""));
        player.sendSystemMessage(Component.literal(Lang.text(locale, "authmod.welcome.min_length", AuthConfig.minPasswordLength())));
        player.sendSystemMessage(Component.literal(Lang.text(locale, "authmod.welcome.title")));
    }

    private static void sendReminder(ServerPlayer player) {
        player.sendSystemMessage(Lang.msg(player, "authmod.locked.reminder"));
    }
}
