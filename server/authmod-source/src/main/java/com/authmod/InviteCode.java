package com.authmod;

import com.mojang.logging.LogUtils;
import org.slf4j.Logger;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;

/**
 * A private invitation code is required for first-time registration.
 * The file stays on the server; it is never included in the client modpack.
 */
public final class InviteCode {
    private static final Logger LOGGER = LogUtils.getLogger();
    private static final Path FILE = Path.of("authmod_invite_code.txt");
    private static byte[] expected = new byte[0];

    private InviteCode() {
    }

    public static void load() {
        expected = new byte[0];
        try {
            String value = Files.readString(FILE, StandardCharsets.UTF_8).trim();
            if (value.length() < 16) {
                LOGGER.error("[AuthMod] Invite code must contain at least 16 characters. Registration is disabled.");
                return;
            }
            expected = value.getBytes(StandardCharsets.UTF_8);
            LOGGER.info("[AuthMod] Invite code loaded. New registrations require the code.");
        } catch (IOException e) {
            LOGGER.error("[AuthMod] Cannot read {}. Registration is disabled.", FILE);
        }
    }

    public static boolean verify(String supplied) {
        return expected.length > 0
                && MessageDigest.isEqual(expected, supplied.getBytes(StandardCharsets.UTF_8));
    }
}
