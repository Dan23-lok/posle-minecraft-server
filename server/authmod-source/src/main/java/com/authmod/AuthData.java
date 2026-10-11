package com.authmod;

import com.google.gson.Gson;
import com.google.gson.reflect.TypeToken;
import com.mojang.logging.LogUtils;
import net.minecraftforge.server.ServerLifecycleHooks;
import org.slf4j.Logger;

import java.io.File;
import java.io.IOException;
import java.lang.reflect.Type;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

public final class AuthData {
    private static final Logger LOGGER = LogUtils.getLogger();
    private static final Gson GSON = new Gson();
    private static final Type MAP_TYPE = new TypeToken<Map<String, String>>(){}.getType();
    private static final Map<String, String> playerPasswords = new HashMap<>();
    private static File dataFile;

    private AuthData() {
    }

    public static void init() {
        var server = ServerLifecycleHooks.getCurrentServer();
        if (server != null) {
            dataFile = new File(server.getServerDirectory(), "authmod_data.json");
            load();
        }
    }

    public static void load() {
        if (dataFile == null || !dataFile.exists()) return;
        try (var reader = Files.newBufferedReader(dataFile.toPath(), StandardCharsets.UTF_8)) {
            Map<String, String> loaded = GSON.fromJson(
                    reader, MAP_TYPE);
            if (loaded == null) throw new IOException("Authentication data is empty");
            playerPasswords.clear();
            playerPasswords.putAll(loaded);
        } catch (IOException | RuntimeException e) {
            LOGGER.error("Failed to load auth data from {}: {}", dataFile, e.toString());
            throw new IllegalStateException("Authentication data could not be loaded; refusing to start", e);
        }
    }

    public static void save() {
        if (dataFile == null) return;
        saveSnapshot(playerPasswords);
    }

    /** Persist first, then expose the account to other commands on the server thread. */
    static boolean registerHashedAndSave(String username, String encodedHash) {
        if (dataFile == null) throw new IllegalStateException("Authentication data is not initialized");
        if (encodedHash == null || !encodedHash.matches("pbkdf2:120000:[0-9a-f]{32}:[0-9a-f]{64}")) {
            throw new IllegalArgumentException("Invalid password hash");
        }
        String key = username.toLowerCase(Locale.ROOT);
        if (playerPasswords.containsKey(key)) return false;
        Map<String, String> snapshot = new HashMap<>(playerPasswords);
        snapshot.put(key, encodedHash);
        saveSnapshot(snapshot);
        playerPasswords.put(key, encodedHash);
        return true;
    }

    static int registeredPlayerCount() {
        return playerPasswords.size();
    }

    /** Compare the hash captured before worker verification, then persist before mutating memory. */
    static boolean replacePasswordHashAndSave(String username, String expectedStored, String encodedHash) {
        if (dataFile == null) throw new IllegalStateException("Authentication data is not initialized");
        if (encodedHash == null || !encodedHash.matches("pbkdf2:120000:[0-9a-f]{32}:[0-9a-f]{64}")) {
            throw new IllegalArgumentException("Invalid password hash");
        }
        String key = username.toLowerCase(Locale.ROOT);
        String current = playerPasswords.get(key);
        if (current == null || !Objects.equals(current, expectedStored)) return false;
        Map<String, String> snapshot = new HashMap<>(playerPasswords);
        snapshot.put(key, encodedHash);
        saveSnapshot(snapshot);
        playerPasswords.put(key, encodedHash);
        return true;
    }

    static boolean setPlayerPasswordAndSave(String username, String password) {
        if (!PasswordPolicy.withinNewPasswordLength(password)) {
            throw new IllegalArgumentException("New password exceeds usable command length");
        }
        return replacePasswordHashAndSave(username, getStoredPassword(username), PasswordHasher.hash(password));
    }

    static boolean removePlayerAndSave(String username) {
        if (dataFile == null) throw new IllegalStateException("Authentication data is not initialized");
        String key = username.toLowerCase(Locale.ROOT);
        if (!playerPasswords.containsKey(key)) return false;
        Map<String, String> snapshot = new HashMap<>(playerPasswords);
        snapshot.remove(key);
        saveSnapshot(snapshot);
        playerPasswords.remove(key);
        return true;
    }

    private static void saveSnapshot(Map<String, String> snapshot) {
        File tmp = new File(dataFile.getParentFile(), dataFile.getName() + ".tmp");
        try {
            Files.writeString(tmp.toPath(), GSON.toJson(snapshot), StandardCharsets.UTF_8);
            try {
                Files.move(tmp.toPath(), dataFile.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            } catch (AtomicMoveNotSupportedException e) {
                Files.move(tmp.toPath(), dataFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException | RuntimeException e) {
            LOGGER.error("Failed to save auth data to {}: {}", dataFile, e.toString());
            throw new IllegalStateException("Authentication data could not be saved", e);
        }
    }

    public static boolean isRegistered(String username) {
        return playerPasswords.containsKey(username.toLowerCase(Locale.ROOT));
    }

    public static String getStoredPassword(String username) {
        return playerPasswords.get(username.toLowerCase(Locale.ROOT));
    }

    public static void setPlayerPassword(String username, String password) {
        if (!PasswordPolicy.withinNewPasswordLength(password)) {
            throw new IllegalArgumentException("New password exceeds usable command length");
        }
        playerPasswords.put(username.toLowerCase(Locale.ROOT), PasswordHasher.hash(password));
    }

    /**
     * Проверяет пароль; старые (незахешированные) записи автоматически
     * переводятся в новый формат при первом успешном входе.
     */
    public static boolean verifyPassword(String username, String password) {
        if (!PasswordPolicy.withinMaxLength(password)) return false;
        String stored = getStoredPassword(username);
        if (stored == null) return false;
        if (PasswordHasher.isLegacy(stored)) {
            if (!stored.equals(password)) return false;
            // A legacy password may exceed the bound for newly chosen passwords.
            if (!replacePasswordHashAndSave(username, stored, PasswordHasher.hash(password))) return false;
            return true;
        }
        return PasswordHasher.verify(password, stored);
    }

    public static boolean removePlayer(String username) {
        return playerPasswords.remove(username.toLowerCase(Locale.ROOT)) != null;
    }

    /** Все зарегистрированные имена (в нижнем регистре) — для автодополнения. */
    public static Set<String> registeredPlayers() {
        return playerPasswords.keySet();
    }
}
