package com.authmod;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LoginLimiterTest {
    @Test
    void fifthWrongPasswordLocksAccountUntilCooldown() {
        String username = "limiter-test-unique";
        LoginLimiter.reset(username);
        for (int i = 0; i < 4; i++) {
            LoginLimiter.recordFailure(username);
            assertFalse(LoginLimiter.isLocked(username));
        }
        LoginLimiter.recordFailure(username);
        assertTrue(LoginLimiter.isLocked(username));
        LoginLimiter.reset(username);
        assertFalse(LoginLimiter.isLocked(username));
    }
}
