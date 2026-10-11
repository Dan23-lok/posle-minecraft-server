package com.authmod;

import java.util.IdentityHashMap;
import java.util.Map;

/**
 * Limits password attempts for one live player connection. A guessed nickname
 * cannot impose a lockout on another player's connection.
 */
public final class LoginLimiter {
    private static final Map<Object, State> STATES = new IdentityHashMap<>();

    private static final class State {
        int failedAttempts;
        long nextAllowedAt;
    }

    private LoginLimiter() {
    }

    public static boolean isLocked(Object connection) {
        State state = STATES.get(connection);
        if (state == null || state.failedAttempts < AuthConfig.maxLoginAttempts()) return false;
        if (System.currentTimeMillis() < state.nextAllowedAt) return true;
        STATES.remove(connection);
        return false;
    }

    public static long remainingSeconds(Object connection) {
        State state = STATES.get(connection);
        if (state == null) return 0;
        long remaining = state.nextAllowedAt - System.currentTimeMillis();
        return remaining > 0 ? (remaining + 999) / 1000 : 0;
    }

    public static void recordFailure(Object connection) {
        State state = STATES.computeIfAbsent(connection, k -> new State());
        state.failedAttempts++;
        if (state.failedAttempts >= AuthConfig.maxLoginAttempts()) {
            state.nextAllowedAt = System.currentTimeMillis() + AuthConfig.lockoutSeconds() * 1000L;
        } else {
            long delaySeconds = Math.min(AuthConfig.lockoutSeconds(), 1L << Math.min(state.failedAttempts - 1, 4));
            state.nextAllowedAt = System.currentTimeMillis() + delaySeconds * 1000L;
        }
    }

    public static void reset(Object connection) {
        STATES.remove(connection);
    }
}
