package com.authmod;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PasswordBoundsTest {
    @Test
    void hashingRejectsOversizedRegistrationAndReplacementPasswords() {
        assertThrows(IllegalArgumentException.class, () -> PasswordHasher.hash("x".repeat(257)));
    }

    @Test
    void verificationRejectsOversizedLoginAndOldPasswords() {
        String stored = PasswordHasher.hash("bounded-password");
        assertFalse(PasswordHasher.verify("x".repeat(257), stored));
        assertTrue(PasswordHasher.verify("bounded-password", stored));
    }

    @Test
    void maximumLengthRemainsAccepted() {
        assertDoesNotThrow(() -> PasswordHasher.hash("x".repeat(256)));
    }
}
