package com.authmod;

import java.time.Duration;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.function.LongSupplier;

/** Monotonic, server-wide budget for accepted registration hashing attempts. */
final class RegistrationBudget {
    private final int burst;
    private final long refillNanos;
    private final int hourlyLimit;
    private final long windowNanos;
    private final LongSupplier clock;
    private final Deque<Attempt> attempts = new ArrayDeque<>();
    private long lastRefill;
    private int tokens;

    private static final class Attempt {
        final long at;
        Attempt(long at) { this.at = at; }
    }

    final class Reservation {
        private final Attempt attempt;
        private boolean settled;
        private Reservation(Attempt attempt) { this.attempt = attempt; }

        /** Only a queue rejection is refunded. Disconnects remain charged. */
        synchronized void refund() {
            if (settled) return;
            settled = true;
            RegistrationBudget.this.refund(attempt);
        }
    }

    RegistrationBudget(int burst, Duration refill, int hourlyLimit, Duration window,
                       LongSupplier clock) {
        if (burst < 1 || refill.isZero() || refill.isNegative() || hourlyLimit < 1
                || window.isZero() || window.isNegative()) {
            throw new IllegalArgumentException("Budget limits must be positive");
        }
        this.burst = burst;
        this.refillNanos = refill.toNanos();
        this.hourlyLimit = hourlyLimit;
        this.windowNanos = window.toNanos();
        this.clock = clock;
        this.tokens = burst;
        this.lastRefill = clock.getAsLong();
    }

    synchronized Reservation tryReserve() {
        long now = clock.getAsLong();
        refill(now);
        while (!attempts.isEmpty() && now - attempts.peekFirst().at >= windowNanos) {
            attempts.removeFirst();
        }
        if (tokens == 0 || attempts.size() >= hourlyLimit) return null;
        tokens--;
        Attempt attempt = new Attempt(now);
        attempts.addLast(attempt);
        return new Reservation(attempt);
    }

    private synchronized void refund(Attempt attempt) {
        if (attempts.remove(attempt)) tokens = Math.min(burst, tokens + 1);
    }

    private void refill(long now) {
        long elapsed = now - lastRefill;
        if (elapsed < refillNanos) return;
        long periods = elapsed / refillNanos;
        tokens = Math.min(burst, tokens + (int) Math.min(periods, burst));
        lastRefill += periods * refillNanos;
    }
}
