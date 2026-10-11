package com.authmod;

import net.minecraftforge.common.ForgeConfigSpec;
import net.minecraftforge.fml.event.config.ModConfigEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;

/**
 * Конфиг сервера (файл authmod-server.toml создаётся автоматически).
 * Значения кешируются на загрузке/перезагрузке конфига.
 */
@Mod.EventBusSubscriber(modid = AuthMod.MODID, bus = Mod.EventBusSubscriber.Bus.MOD)
public final class AuthConfig {
    public static final ForgeConfigSpec SPEC;

    private static final ForgeConfigSpec.IntValue MIN_PASSWORD_LENGTH;
    private static final ForgeConfigSpec.IntValue MAX_LOGIN_ATTEMPTS;
    private static final ForgeConfigSpec.IntValue LOGIN_TIMEOUT_SECONDS;
    private static final ForgeConfigSpec.IntValue LOCKOUT_SECONDS;
    private static final ForgeConfigSpec.IntValue MAX_REGISTERED_ACCOUNTS;
    private static final ForgeConfigSpec.ConfigValue<String> LANGUAGE;
    private static final ForgeConfigSpec.ConfigValue<String> OWNER_USERNAME;

    private static int minPasswordLength = 12;
    private static int maxLoginAttempts = 5;
    private static int loginTimeoutSeconds = 300;
    private static int lockoutSeconds = 60;
    private static int maxRegisteredAccounts = 256;
    private static String language = "auto";
    private static String ownerUsername = "";

    static {
        ForgeConfigSpec.Builder builder = new ForgeConfigSpec.Builder();
        builder.comment("AuthMod server configuration").push("auth");
        MIN_PASSWORD_LENGTH = builder.comment("Minimum password length for /register and password changes")
                .defineInRange("minPasswordLength", 12, 4, 64);
        MAX_LOGIN_ATTEMPTS = builder.comment("Failed /login attempts before a temporary lockout")
                .defineInRange("maxLoginAttempts", 5, 1, 100);
        LOGIN_TIMEOUT_SECONDS = builder.comment("Seconds allowed to use /login or /register after joining")
                .defineInRange("loginTimeoutSeconds", 300, 30, 3600);
        LOCKOUT_SECONDS = builder.comment("Per-connection fifth-failure cooldown and maximum retry delay in seconds (legacy key name)")
                .defineInRange("lockoutSeconds", 60, 1, 3600);
        MAX_REGISTERED_ACCOUNTS = builder.comment("Maximum number of registered names; existing accounts continue to work if already above this limit")
                .defineInRange("maxRegisteredAccounts", 256, 10, 100000);
        LANGUAGE = builder.comment("Message language: auto (client language), ru or en")
                .define("language", "auto");
        OWNER_USERNAME = builder.comment("Exact-case owner Minecraft nickname for /owner. Empty disables temporary owner commands. Keep this server-only.")
                .define("ownerUsername", "");
        builder.pop();
        SPEC = builder.build();
    }

    private AuthConfig() {
    }

    @SubscribeEvent
    public static void onLoad(ModConfigEvent.Loading event) {
        if (event.getConfig().getSpec() == SPEC) cache();
    }

    @SubscribeEvent
    public static void onReload(ModConfigEvent.Reloading event) {
        if (event.getConfig().getSpec() == SPEC) cache();
    }

    private static void cache() {
        minPasswordLength = MIN_PASSWORD_LENGTH.get();
        maxLoginAttempts = MAX_LOGIN_ATTEMPTS.get();
        loginTimeoutSeconds = LOGIN_TIMEOUT_SECONDS.get();
        lockoutSeconds = LOCKOUT_SECONDS.get();
        maxRegisteredAccounts = MAX_REGISTERED_ACCOUNTS.get();
        language = LANGUAGE.get();
        ownerUsername = OWNER_USERNAME.get();
    }

    public static int minPasswordLength() {
        return minPasswordLength;
    }

    public static int maxLoginAttempts() {
        return maxLoginAttempts;
    }

    public static int loginTimeoutSeconds() {
        return loginTimeoutSeconds;
    }

    public static int lockoutSeconds() {
        return lockoutSeconds;
    }

    public static int maxRegisteredAccounts() {
        return maxRegisteredAccounts;
    }

    public static String language() {
        return language;
    }

    public static String ownerUsername() {
        return ownerUsername;
    }
}
