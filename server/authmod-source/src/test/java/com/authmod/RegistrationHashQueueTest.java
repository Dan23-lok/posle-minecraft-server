package com.authmod;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class RegistrationHashQueueTest {
    @Test
    void oneRunningTwoWaitingAndFourthConnectionBusy() throws Exception {
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        AtomicInteger hashes = new AtomicInteger();
        LinkedBlockingQueue<Runnable> mainThread = new LinkedBlockingQueue<>();
        List<String> results = new ArrayList<>();
        try (RegistrationHashQueue queue = new RegistrationHashQueue(1, 2, password -> {
            hashes.incrementAndGet();
            started.countDown();
            try {
                release.await(5, TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return null;
            }
            return "hashed-" + password;
        })) {
            Object first = new Object();
            Object second = new Object();
            Object third = new Object();
            Object fourth = new Object();
            assertEquals(RegistrationHashQueue.Submission.ACCEPTED,
                    queue.submit(first, "first", mainThread::add, results::add));
            assertTrue(started.await(5, TimeUnit.SECONDS));
            assertEquals(RegistrationHashQueue.Submission.ACCEPTED,
                    queue.submit(second, "second", mainThread::add, results::add));
            assertEquals(RegistrationHashQueue.Submission.ACCEPTED,
                    queue.submit(third, "third", mainThread::add, results::add));
            assertEquals(RegistrationHashQueue.Submission.BUSY,
                    queue.submit(fourth, "fourth", mainThread::add, results::add));
            assertEquals(RegistrationHashQueue.Submission.ALREADY_PENDING,
                    queue.submit(first, "duplicate", mainThread::add, results::add));
            assertEquals(1, hashes.get());
            release.countDown();
            for (int i = 0; i < 3; i++) {
                Runnable completion = mainThread.poll(5, TimeUnit.SECONDS);
                assertNotNull(completion);
                completion.run();
            }
            assertEquals(List.of("hashed-first", "hashed-second", "hashed-third"), results);
            assertEquals(3, hashes.get());
        } finally {
            release.countDown();
        }
    }

    @Test
    void disconnectCancelsQueuedHashAndSuppressesCompletedCallback() throws Exception {
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        LinkedBlockingQueue<Runnable> mainThread = new LinkedBlockingQueue<>();
        List<String> results = new ArrayList<>();
        Object live = new Object();
        Object disconnected = new Object();
        try (RegistrationHashQueue queue = new RegistrationHashQueue(1, 1, password -> {
            started.countDown();
            try {
                release.await(5, TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return null;
            }
            return "hashed-" + password;
        })) {
            assertEquals(RegistrationHashQueue.Submission.ACCEPTED,
                    queue.submit(live, "first", mainThread::add, results::add));
            assertTrue(started.await(5, TimeUnit.SECONDS));
            assertEquals(RegistrationHashQueue.Submission.ACCEPTED,
                    queue.submit(disconnected, "second", mainThread::add, results::add));
            queue.forget(disconnected);
            release.countDown();
            Runnable completion = mainThread.poll(5, TimeUnit.SECONDS);
            assertNotNull(completion);
            queue.forget(live);
            completion.run();
            assertTrue(results.isEmpty());
            assertTrue(mainThread.poll(250, TimeUnit.MILLISECONDS) == null);
        } finally {
            release.countDown();
        }
    }

    @Test
    void realHashIsOnlyDeliveredThroughServerExecutor() throws Exception {
        LinkedBlockingQueue<Runnable> mainThread = new LinkedBlockingQueue<>();
        List<String> results = new ArrayList<>();
        try (RegistrationHashQueue queue = new RegistrationHashQueue(1, 2, PasswordHasher::hash)) {
            assertEquals(RegistrationHashQueue.Submission.ACCEPTED,
                    queue.submit(new Object(), "stage-only-test-password", mainThread::add, results::add));
            Runnable completion = mainThread.poll(5, TimeUnit.SECONDS);
            assertNotNull(completion);
            assertTrue(results.isEmpty());
            completion.run();
            assertEquals(1, results.size());
            assertTrue(PasswordHasher.verify("stage-only-test-password", results.get(0)));
        }
    }

    @Test
    void reconnectUsesNewConnectionIdentityAndStopDiscardsOldWork() throws Exception {
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        LinkedBlockingQueue<Runnable> mainThread = new LinkedBlockingQueue<>();
        List<String> results = new ArrayList<>();
        Object oldConnection = new Object();
        Object newConnection = new Object();
        RegistrationHashQueue queue = new RegistrationHashQueue(1, 2, password -> {
            started.countDown();
            try {
                release.await(5, TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return null;
            }
            return password;
        });
        try {
            assertEquals(RegistrationHashQueue.Submission.ACCEPTED,
                    queue.submit(oldConnection, "old", mainThread::add, results::add));
            assertTrue(started.await(5, TimeUnit.SECONDS));
            queue.forget(oldConnection);
            assertEquals(RegistrationHashQueue.Submission.ACCEPTED,
                    queue.submit(newConnection, "new", mainThread::add, results::add));
            queue.close();
            release.countDown();
            Runnable completion;
            while ((completion = mainThread.poll(200, TimeUnit.MILLISECONDS)) != null) completion.run();
            assertTrue(results.isEmpty());
            assertEquals(RegistrationHashQueue.Submission.BUSY,
                    queue.submit(new Object(), "after-stop", mainThread::add, results::add));
        } finally {
            release.countDown();
            queue.close();
        }
    }
}
