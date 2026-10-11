package com.authmod;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AuthSessionStoreTest {
    @Test
    void loggingInAliceDoesNotAuthenticateSimultaneousCaseVariant() {
        UUID aliceId = offlineUuid("Alice");
        UUID variantId = offlineUuid("aLiCe");
        Object alice = new Object();
        Object variant = new Object();
        AuthSessionStore<Object> sessions = new AuthSessionStore<>();

        sessions.join(aliceId, alice);
        sessions.join(variantId, variant);
        sessions.authenticate(aliceId, alice);

        assertTrue(sessions.isAuthenticated(aliceId, alice));
        assertFalse(sessions.isAuthenticated(variantId, variant));
    }

    @Test
    void lateLogoutCannotClearNewConnectionWithSameOfflineUuid() {
        UUID aliceId = offlineUuid("Alice");
        Object oldConnection = new Object();
        Object newConnection = new Object();
        AuthSessionStore<Object> sessions = new AuthSessionStore<>();

        sessions.join(aliceId, oldConnection);
        sessions.authenticate(aliceId, oldConnection);
        sessions.join(aliceId, newConnection);
        sessions.leave(aliceId, oldConnection);

        assertFalse(sessions.isAuthenticated(aliceId, newConnection));
        sessions.authenticate(aliceId, newConnection);
        assertTrue(sessions.isAuthenticated(aliceId, newConnection));
    }

    @Test
    void cloneTransfersAuthenticatedSessionToReplacementPlayerOnly() {
        UUID id = offlineUuid("Alice");
        Object original = new Object();
        Object replacement = new Object();
        AuthSessionStore<Object> sessions = new AuthSessionStore<>();

        sessions.join(id, original);
        sessions.authenticate(id, original);
        assertTrue(sessions.transfer(id, original, replacement));
        sessions.leave(id, original);

        assertFalse(sessions.isAuthenticated(id, original));
        assertTrue(sessions.isAuthenticated(id, replacement));
    }

    @Test
    void cloneKeepsUnauthenticatedSessionLocked() {
        UUID id = offlineUuid("Alice");
        Object original = new Object();
        Object replacement = new Object();
        AuthSessionStore<Object> sessions = new AuthSessionStore<>();

        sessions.join(id, original);
        assertTrue(sessions.transfer(id, original, replacement));

        assertFalse(sessions.isAuthenticated(id, replacement));
        assertTrue(sessions.isCurrent(id, replacement));
        assertFalse(sessions.isCurrent(id, original));
    }

    @Test
    void staleCloneCannotStealNewerSession() {
        UUID id = offlineUuid("Alice");
        Object oldConnection = new Object();
        Object currentConnection = new Object();
        Object staleReplacement = new Object();
        AuthSessionStore<Object> sessions = new AuthSessionStore<>();

        sessions.join(id, oldConnection);
        sessions.join(id, currentConnection);
        sessions.authenticate(id, currentConnection);

        assertFalse(sessions.transfer(id, oldConnection, staleReplacement));
        assertFalse(sessions.joinIfAbsent(id, staleReplacement));
        assertTrue(sessions.isAuthenticated(id, currentConnection));
        assertFalse(sessions.isCurrent(id, staleReplacement));
    }

    private static UUID offlineUuid(String name) {
        return UUID.nameUUIDFromBytes(("OfflinePlayer:" + name).getBytes(StandardCharsets.UTF_8));
    }
}
