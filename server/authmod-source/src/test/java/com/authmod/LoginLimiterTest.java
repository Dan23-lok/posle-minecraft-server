package com.authmod;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LoginLimiterTest {
    @Test
    void spoofedOwnerNameCannotLockASeparateOwnerConnection() {
        String attackerConnection = new String("owner-name");
        String ownerConnection = new String("owner-name");
        LoginLimiter.reset(attackerConnection);
        LoginLimiter.reset(ownerConnection);

        for (int i = 0; i < 5; i++) LoginLimiter.recordFailure(attackerConnection);

        assertTrue(LoginLimiter.isLocked(attackerConnection));
        assertFalse(LoginLimiter.isLocked(ownerConnection));
    }

    @Test
    void retryDelayAfterOneFailureExpiresWithoutLockingTheConnection() throws InterruptedException {
        String connection = new String("retry-delay-test");
        LoginLimiter.reset(connection);

        LoginLimiter.recordFailure(connection);
        assertFalse(LoginLimiter.isLocked(connection));
        assertTrue(LoginLimiter.remainingSeconds(connection) > 0);

        Thread.sleep(1200);
        assertFalse(LoginLimiter.isLocked(connection));
        assertTrue(LoginLimiter.remainingSeconds(connection) == 0);
        LoginLimiter.reset(connection);
    }

    @Test
    void fifthWrongPasswordLocksOnlyTheCurrentConnectionUntilReset() {
        String connection = new String("limiter-test-unique");
        LoginLimiter.reset(connection);
        for (int i = 0; i < 4; i++) {
            LoginLimiter.recordFailure(connection);
            assertFalse(LoginLimiter.isLocked(connection));
        }
        LoginLimiter.recordFailure(connection);
        assertTrue(LoginLimiter.isLocked(connection));
        LoginLimiter.reset(connection);
        assertFalse(LoginLimiter.isLocked(connection));
        assertEquals(0, LoginLimiter.remainingSeconds(connection));
    }

    @Test
    void successfulLoginResetClearsPendingRetryDelay() {
        String connection = new String("successful-login-test");
        LoginLimiter.reset(connection);
        LoginLimiter.recordFailure(connection);
        assertTrue(LoginLimiter.remainingSeconds(connection) > 0);

        LoginLimiter.reset(connection);
        assertEquals(0, LoginLimiter.remainingSeconds(connection));
    }
}
