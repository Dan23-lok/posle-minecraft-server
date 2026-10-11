package com.authmod;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.File;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AuthDataRegistrationTest {
    @TempDir Path directory;

    @Test
    void registrationIsPersistedBeforeTheAccountBecomesVisible() throws Exception {
        withIsolatedStore(directory.resolve("accounts.json"), () -> {
            String hash = PasswordHasher.hash("synthetic-password-123");
            assertTrue(AuthData.registerHashedAndSave("newplayer", hash));
            assertTrue(AuthData.isRegistered("newplayer"));
            assertTrue(Files.readString(directory.resolve("accounts.json")).contains("newplayer"));
            String originalHash = AuthData.getStoredPassword("newplayer");
            assertFalse(AuthData.registerHashedAndSave("newplayer", hash));
            assertEquals(originalHash, AuthData.getStoredPassword("newplayer"));
        });
    }

    @Test
    void failedSaveLeavesExistingAccountAndRejectsNewRegistration() throws Exception {
        Path saved = directory.resolve("accounts.json");
        withIsolatedStore(saved, () -> {
            AuthData.setPlayerPassword("existing", "existing-password-123");
            AuthData.save();
            String before = Files.readString(saved);
            dataFileField().set(null, directory.resolve("missing-directory/accounts.json").toFile());
            String newHash = PasswordHasher.hash("synthetic-password-123");
            assertThrows(IllegalStateException.class,
                    () -> AuthData.registerHashedAndSave("newplayer", newHash));
            assertTrue(AuthData.isRegistered("existing"));
            assertFalse(AuthData.isRegistered("newplayer"));
            assertTrue(Files.readString(saved).equals(before));
        });
    }

    @Test
    void passwordChangePersistsBeforeReplacingExistingHash() throws Exception {
        Path saved = directory.resolve("accounts.json");
        withIsolatedStore(saved, () -> {
            AuthData.setPlayerPassword("existing", "existing-password-123");
            AuthData.save();
            String priorHash = AuthData.getStoredPassword("existing");
            String nextHash = PasswordHasher.hash("next-password-456");
            assertFalse(AuthData.replacePasswordHashAndSave("existing", "stale-hash", nextHash));
            assertEquals(priorHash, AuthData.getStoredPassword("existing"));
            assertTrue(AuthData.replacePasswordHashAndSave("existing", priorHash, nextHash));
            assertEquals(nextHash, AuthData.getStoredPassword("existing"));
            assertTrue(Files.readString(saved).contains(nextHash));
        });
    }

    @Test
    void failedPasswordChangeSavePreservesOldPassword() throws Exception {
        Path saved = directory.resolve("accounts.json");
        withIsolatedStore(saved, () -> {
            AuthData.setPlayerPassword("existing", "existing-password-123");
            AuthData.save();
            String priorHash = AuthData.getStoredPassword("existing");
            dataFileField().set(null, directory.resolve("missing-directory/accounts.json").toFile());
            String nextHash = PasswordHasher.hash("next-password-456");
            assertThrows(IllegalStateException.class,
                    () -> AuthData.replacePasswordHashAndSave("existing", priorHash, nextHash));
            assertEquals(priorHash, AuthData.getStoredPassword("existing"));
            assertTrue(Files.readString(saved).contains(priorHash));
        });
    }

    @Test
    void resetPersistsRemovalWithoutTouchingOtherAccounts() throws Exception {
        Path saved = directory.resolve("accounts.json");
        withIsolatedStore(saved, () -> {
            AuthData.setPlayerPassword("existing", "existing-password-123");
            AuthData.setPlayerPassword("other", "other-password-456");
            AuthData.save();
            assertTrue(AuthData.removePlayerAndSave("existing"));
            assertFalse(AuthData.isRegistered("existing"));
            assertTrue(AuthData.isRegistered("other"));
            String persisted = Files.readString(saved);
            assertFalse(persisted.contains("existing"));
            assertTrue(persisted.contains("other"));
        });
    }

    @Test
    void failedResetSaveKeepsAccountInMemoryAndOnDisk() throws Exception {
        Path saved = directory.resolve("accounts.json");
        withIsolatedStore(saved, () -> {
            AuthData.setPlayerPassword("existing", "existing-password-123");
            AuthData.save();
            String before = Files.readString(saved);
            dataFileField().set(null, directory.resolve("missing-directory/accounts.json").toFile());
            assertThrows(IllegalStateException.class, () -> AuthData.removePlayerAndSave("existing"));
            assertTrue(AuthData.isRegistered("existing"));
            assertEquals(before, Files.readString(saved));
        });
    }

    @Test
    void nicknameNormalizationDoesNotDependOnSystemLocale() throws Exception {
        withIsolatedStore(directory.resolve("accounts.json"), () -> {
            Locale previous = Locale.getDefault();
            try {
                Locale.setDefault(Locale.forLanguageTag("tr-TR"));
                String hash = PasswordHasher.hash("synthetic-password-123");
                assertTrue(AuthData.registerHashedAndSave("PLAYERI", hash));
                assertTrue(AuthData.isRegistered("playeri"));
                assertEquals(hash, AuthData.getStoredPassword("PLAYERI"));
            } finally {
                Locale.setDefault(previous);
            }
        });
    }

    @SuppressWarnings("unchecked")
    private static void withIsolatedStore(Path path, ThrowingAction action) throws Exception {
        Field fileField = dataFileField();
        Field mapField = AuthData.class.getDeclaredField("playerPasswords");
        mapField.setAccessible(true);
        Map<String, String> accounts = (Map<String, String>) mapField.get(null);
        File oldFile = (File) fileField.get(null);
        Map<String, String> oldAccounts = new HashMap<>(accounts);
        accounts.clear();
        fileField.set(null, path.toFile());
        try {
            action.run();
        } finally {
            accounts.clear();
            accounts.putAll(oldAccounts);
            fileField.set(null, oldFile);
        }
    }

    private static Field dataFileField() throws Exception {
        Field field = AuthData.class.getDeclaredField("dataFile");
        field.setAccessible(true);
        return field;
    }

    @FunctionalInterface
    private interface ThrowingAction {
        void run() throws Exception;
    }
}
