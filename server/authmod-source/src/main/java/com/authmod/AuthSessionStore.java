package com.authmod;

import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/** A login belongs to one live player connection, never to a shared nickname. */
final class AuthSessionStore<T> {
    private final Map<UUID, Session<T>> sessions = new HashMap<>();

    private static final class Session<T> {
        final T player;
        boolean authenticated;

        Session(T player) {
            this.player = player;
        }
    }

    void join(UUID uuid, T player) {
        sessions.put(uuid, new Session<>(player));
    }

    boolean joinIfAbsent(UUID uuid, T player) {
        if (sessions.containsKey(uuid)) return false;
        sessions.put(uuid, new Session<>(player));
        return true;
    }

    /** Forge replaces ServerPlayer on respawn. Preserve only the current player's login. */
    boolean transfer(UUID uuid, T original, T replacement) {
        Session<T> session = sessions.get(uuid);
        if (session == null || session.player != original) return false;
        Session<T> next = new Session<>(replacement);
        next.authenticated = session.authenticated;
        sessions.put(uuid, next);
        return true;
    }

    boolean authenticate(UUID uuid, T player) {
        Session<T> session = sessions.get(uuid);
        if (session == null || session.player != player) return false;
        session.authenticated = true;
        return true;
    }

    void relock(UUID uuid, T player) {
        Session<T> session = sessions.get(uuid);
        if (session != null && session.player == player) session.authenticated = false;
    }

    boolean isAuthenticated(UUID uuid, T player) {
        Session<T> session = sessions.get(uuid);
        return session != null && session.player == player && session.authenticated;
    }

    boolean isCurrent(UUID uuid, T player) {
        Session<T> session = sessions.get(uuid);
        return session != null && session.player == player;
    }

    void leave(UUID uuid, T player) {
        Session<T> session = sessions.get(uuid);
        if (session != null && session.player == player) sessions.remove(uuid);
    }
}
