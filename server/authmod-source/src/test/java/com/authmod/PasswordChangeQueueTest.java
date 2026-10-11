package com.authmod;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

class PasswordChangeQueueTest {
    @Test
    void oneRunningTwoWaitingAndFourthBusyWithoutDuplicatingConnection() throws Exception {
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        LinkedBlockingQueue<Runnable> mainThread = new LinkedBlockingQueue<>();
        List<PasswordChangeQueue.Result> results = new ArrayList<>();
        try (PasswordChangeQueue queue = new PasswordChangeQueue(1, 2, (old, next, stored) -> {
            started.countDown();
            try {
                release.await(5, TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return PasswordChangeQueue.Result.failure();
            }
            return new PasswordChangeQueue.Result(true, "hashed-" + next);
        })) {
            Object first = new Object();
            assertEquals(PasswordChangeQueue.Submission.ACCEPTED,
                    queue.submit(first, "old", "new1", "stored", mainThread::add, results::add));
            assertTrue(started.await(5, TimeUnit.SECONDS));
            assertEquals(PasswordChangeQueue.Submission.ALREADY_PENDING,
                    queue.submit(first, "old", "duplicate", "stored", mainThread::add, results::add));
            assertEquals(PasswordChangeQueue.Submission.ACCEPTED,
                    queue.submit(new Object(), "old", "new2", "stored", mainThread::add, results::add));
            assertEquals(PasswordChangeQueue.Submission.ACCEPTED,
                    queue.submit(new Object(), "old", "new3", "stored", mainThread::add, results::add));
            assertEquals(PasswordChangeQueue.Submission.BUSY,
                    queue.submit(new Object(), "old", "new4", "stored", mainThread::add, results::add));
            release.countDown();
            for (int i = 0; i < 3; i++) {
                Runnable completion = mainThread.poll(5, TimeUnit.SECONDS);
                assertNotNull(completion);
                completion.run();
            }
            assertEquals(List.of("hashed-new1", "hashed-new2", "hashed-new3"),
                    results.stream().map(PasswordChangeQueue.Result::newHash).toList());
        } finally {
            release.countDown();
        }
    }

    @Test
    void disconnectAndStopSuppressResultsWhileNewConnectionCanQueue() throws Exception {
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        LinkedBlockingQueue<Runnable> mainThread = new LinkedBlockingQueue<>();
        List<PasswordChangeQueue.Result> results = new ArrayList<>();
        PasswordChangeQueue queue = new PasswordChangeQueue(1, 2, (old, next, stored) -> {
            started.countDown();
            try { release.await(5, TimeUnit.SECONDS); }
            catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            return new PasswordChangeQueue.Result(true, "hash");
        });
        try {
            Object oldConnection = new Object();
            assertEquals(PasswordChangeQueue.Submission.ACCEPTED,
                    queue.submit(oldConnection, "old", "new", "stored", mainThread::add, results::add));
            assertTrue(started.await(5, TimeUnit.SECONDS));
            queue.forget(oldConnection);
            assertEquals(PasswordChangeQueue.Submission.ACCEPTED,
                    queue.submit(new Object(), "old", "new", "stored", mainThread::add, results::add));
            queue.close();
            release.countDown();
            Runnable completion;
            while ((completion = mainThread.poll(200, TimeUnit.MILLISECONDS)) != null) completion.run();
            assertTrue(results.isEmpty());
        } finally {
            release.countDown();
            queue.close();
        }
    }

    @Test
    void realVerificationAndNewHashAreDeliveredOnMainThread() throws Exception {
        LinkedBlockingQueue<Runnable> mainThread = new LinkedBlockingQueue<>();
        List<PasswordChangeQueue.Result> results = new ArrayList<>();
        String originalHash = PasswordHasher.hash("old-test-password");
        try (PasswordChangeQueue queue = new PasswordChangeQueue(1, 2, PasswordChangeQueue.DEFAULT_COMPUTER)) {
            assertEquals(PasswordChangeQueue.Submission.ACCEPTED,
                    queue.submit(new Object(), "old-test-password", "new-test-password", originalHash,
                            mainThread::add, results::add));
            Runnable completion = mainThread.poll(5, TimeUnit.SECONDS);
            assertNotNull(completion);
            assertTrue(results.isEmpty());
            completion.run();
            assertTrue(results.get(0).oldVerified());
            assertTrue(PasswordHasher.verify("new-test-password", results.get(0).newHash()));
            assertEquals(PasswordChangeQueue.Submission.ACCEPTED,
                    queue.submit(new Object(), "wrong-old", "new-test-password", originalHash,
                            mainThread::add, results::add));
            completion = mainThread.poll(5, TimeUnit.SECONDS);
            assertNotNull(completion);
            completion.run();
            assertFalse(results.get(1).oldVerified());
            assertNull(results.get(1).newHash());
        }
    }
}
