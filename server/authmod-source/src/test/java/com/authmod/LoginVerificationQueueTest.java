package com.authmod;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LoginVerificationQueueTest {
    @Test
    void excessNewConnectionsDoNotStartUnboundedPasswordChecks() throws Exception {
        CountDownLatch firstStarted = new CountDownLatch(1);
        CountDownLatch releaseFirst = new CountDownLatch(1);
        AtomicInteger checksStarted = new AtomicInteger();
        LinkedBlockingQueue<Runnable> mainThread = new LinkedBlockingQueue<>();
        List<Boolean> results = new ArrayList<>();
        Object first = new Object();
        Object waiting = new Object();
        Object excess = new Object();

        try (LoginVerificationQueue queue = new LoginVerificationQueue(1, 1, (password, stored) -> {
            checksStarted.incrementAndGet();
            firstStarted.countDown();
            try {
                releaseFirst.await(5, TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
            return password.equals(stored);
        })) {
            assertEquals(LoginVerificationQueue.Submission.ACCEPTED,
                    queue.submit(first, "right", "right", mainThread::add, results::add));
            assertTrue(firstStarted.await(5, TimeUnit.SECONDS));
            assertEquals(LoginVerificationQueue.Submission.ACCEPTED,
                    queue.submit(waiting, "right", "right", mainThread::add, results::add));
            assertEquals(LoginVerificationQueue.Submission.BUSY,
                    queue.submit(excess, "right", "right", mainThread::add, results::add));
            assertEquals(1, checksStarted.get());

            queue.forget(waiting);
            assertEquals(LoginVerificationQueue.Submission.ACCEPTED,
                    queue.submit(excess, "right", "right", mainThread::add, results::add));
            releaseFirst.countDown();
            Runnable firstCompletion = mainThread.poll(5, TimeUnit.SECONDS);
            Runnable secondCompletion = mainThread.poll(5, TimeUnit.SECONDS);
            assertNotNull(firstCompletion);
            assertNotNull(secondCompletion);
            firstCompletion.run();
            secondCompletion.run();
            assertEquals(List.of(true, true), results);
            assertEquals(2, checksStarted.get());
        } finally {
            releaseFirst.countDown();
        }
    }

    @Test
    void oneConnectionCannotEnqueueDuplicateChecksButEqualNicknamesAreIndependent() throws Exception {
        CountDownLatch release = new CountDownLatch(1);
        CountDownLatch started = new CountDownLatch(1);
        Object impersonatorConnection = new String("owner-nickname");
        Object ownerConnection = new String("owner-nickname");
        LinkedBlockingQueue<Runnable> mainThread = new LinkedBlockingQueue<>();
        List<Boolean> results = new ArrayList<>();

        try (LoginVerificationQueue queue = new LoginVerificationQueue(1, 1, (password, stored) -> {
            started.countDown();
            try {
                release.await(5, TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
            return password.equals(stored);
        })) {
            assertEquals(LoginVerificationQueue.Submission.ACCEPTED,
                    queue.submit(impersonatorConnection, "wrong", "right", mainThread::add, results::add));
            assertTrue(started.await(5, TimeUnit.SECONDS));
            assertEquals(LoginVerificationQueue.Submission.ALREADY_PENDING,
                    queue.submit(impersonatorConnection, "wrong", "right", mainThread::add, results::add));
            assertEquals(LoginVerificationQueue.Submission.ACCEPTED,
                    queue.submit(ownerConnection, "right", "right", mainThread::add, results::add));
            release.countDown();
            Runnable firstCompletion = mainThread.poll(5, TimeUnit.SECONDS);
            Runnable secondCompletion = mainThread.poll(5, TimeUnit.SECONDS);
            assertNotNull(firstCompletion);
            assertNotNull(secondCompletion);
            firstCompletion.run();
            secondCompletion.run();
            assertEquals(List.of(false, true), results);
        } finally {
            release.countDown();
        }
    }

    @Test
    void disconnectedConnectionNeverReceivesQueuedResult() throws Exception {
        LinkedBlockingQueue<Runnable> mainThread = new LinkedBlockingQueue<>();
        List<Boolean> results = new ArrayList<>();
        Object connection = new Object();
        try (LoginVerificationQueue queue = new LoginVerificationQueue(1, 1, String::equals)) {
            assertEquals(LoginVerificationQueue.Submission.ACCEPTED,
                    queue.submit(connection, "right", "right", mainThread::add, results::add));
            Runnable completion = mainThread.poll(5, TimeUnit.SECONDS);
            assertNotNull(completion);
            queue.forget(connection);
            completion.run();
            assertTrue(results.isEmpty());
        }
    }

    @Test
    void realPbkdf2ResultIsDeliveredOnlyThroughCompletionExecutor() throws Exception {
        String stored = PasswordHasher.hash("correct-password-123");
        LinkedBlockingQueue<Runnable> mainThread = new LinkedBlockingQueue<>();
        List<Boolean> results = new ArrayList<>();
        try (LoginVerificationQueue queue = new LoginVerificationQueue(1, 1, PasswordHasher::verify)) {
            assertEquals(LoginVerificationQueue.Submission.ACCEPTED,
                    queue.submit(new Object(), "correct-password-123", stored, mainThread::add, results::add));
            Runnable completion = mainThread.poll(5, TimeUnit.SECONDS);
            assertNotNull(completion);
            assertFalse(results.contains(true));
            completion.run();
            assertEquals(List.of(true), results);
        }
    }
}
