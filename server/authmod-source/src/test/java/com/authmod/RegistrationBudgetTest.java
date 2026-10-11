package com.authmod;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;

class RegistrationBudgetTest {
    @Test
    void burstAndRefillBoundAcceptedHashAttemptsAcrossReconnects() {
        AtomicLong clock = new AtomicLong();
        RegistrationBudget budget = new RegistrationBudget(3, Duration.ofSeconds(10),
                24, Duration.ofHours(1), clock::get);
        assertNotNull(budget.tryReserve());
        assertNotNull(budget.tryReserve());
        assertNotNull(budget.tryReserve());
        assertNull(budget.tryReserve());
        clock.addAndGet(Duration.ofSeconds(9).toNanos());
        assertNull(budget.tryReserve());
        clock.addAndGet(Duration.ofSeconds(1).toNanos());
        assertNotNull(budget.tryReserve());
        assertNull(budget.tryReserve());
    }

    @Test
    void acceptedAttemptsRemainChargedButRejectedQueueSubmissionRefunds() {
        AtomicLong clock = new AtomicLong();
        RegistrationBudget budget = new RegistrationBudget(1, Duration.ofSeconds(10),
                24, Duration.ofHours(1), clock::get);
        RegistrationBudget.Reservation failedEnqueue = budget.tryReserve();
        assertNotNull(failedEnqueue);
        assertNull(budget.tryReserve());
        failedEnqueue.refund();
        assertNotNull(budget.tryReserve());
        assertNull(budget.tryReserve());
    }

    @Test
    void hourlyLimitBoundsUnlimitedClockRefills() {
        AtomicLong clock = new AtomicLong();
        RegistrationBudget budget = new RegistrationBudget(1, Duration.ofSeconds(1),
                3, Duration.ofHours(1), clock::get);
        for (int i = 0; i < 3; i++) {
            assertNotNull(budget.tryReserve());
            clock.addAndGet(Duration.ofSeconds(1).toNanos());
        }
        assertNull(budget.tryReserve());
        clock.addAndGet(Duration.ofHours(1).toNanos());
        assertNotNull(budget.tryReserve());
    }
}
