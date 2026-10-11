package com.authmod;

import java.util.IdentityHashMap;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.Executor;
import java.util.concurrent.FutureTask;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BiPredicate;
import java.util.function.Consumer;

/**
 * Bounded off-thread password verification. Connection objects are compared by
 * identity, so someone using the owner's offline nickname cannot reserve or
 * lock out the owner's separate connection.
 *
 * Only the verifier runs on a worker. The caller supplies the server-thread
 * executor for consuming results and touching Minecraft state.
 */
final class LoginVerificationQueue implements AutoCloseable {
    enum Submission { ACCEPTED, ALREADY_PENDING, BUSY }

    private static final AtomicInteger THREAD_IDS = new AtomicInteger();
    private final ThreadPoolExecutor workers;
    private final BiPredicate<String, String> verifier;
    private final Map<Object, Request> pending = new IdentityHashMap<>();

    private static final class Request {
        FutureTask<Void> task;
    }

    LoginVerificationQueue(int workerCount, int waitingCapacity,
                           BiPredicate<String, String> verifier) {
        if (workerCount < 1 || waitingCapacity < 1) throw new IllegalArgumentException("Queue capacity must be positive");
        this.verifier = verifier;
        ThreadFactory threadFactory = task -> {
            Thread thread = new Thread(task, "AuthMod-password-" + THREAD_IDS.incrementAndGet());
            thread.setDaemon(true);
            return thread;
        };
        workers = new ThreadPoolExecutor(workerCount, workerCount, 0, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(waitingCapacity), threadFactory,
                new ThreadPoolExecutor.AbortPolicy());
        workers.prestartAllCoreThreads();
    }

    synchronized Submission submit(Object connection, String password, String stored,
                                   Executor completionExecutor, Consumer<Boolean> onResult) {
        if (pending.containsKey(connection)) return Submission.ALREADY_PENDING;
        if (workers.isShutdown()) return Submission.BUSY;

        Request request = new Request();
        request.task = new FutureTask<>(() -> {
            boolean verified;
            try {
                verified = verifier.test(password, stored);
            } catch (RuntimeException e) {
                // A malformed stored value must fail closed without crashing a worker.
                verified = false;
            }
            boolean result = verified;
            try {
                completionExecutor.execute(() -> {
                    synchronized (LoginVerificationQueue.this) {
                        if (pending.get(connection) != request) return;
                        pending.remove(connection);
                    }
                    onResult.accept(result);
                });
            } catch (RejectedExecutionException e) {
                synchronized (LoginVerificationQueue.this) {
                    if (pending.get(connection) == request) pending.remove(connection);
                }
            }
        }, null);

        pending.put(connection, request);
        try {
            workers.execute(request.task);
            return Submission.ACCEPTED;
        } catch (RejectedExecutionException e) {
            pending.remove(connection);
            return Submission.BUSY;
        }
    }

    synchronized void forget(Object connection) {
        Request request = pending.remove(connection);
        if (request == null) return;
        request.task.cancel(true);
        workers.remove(request.task);
    }

    @Override
    public synchronized void close() {
        for (Request request : pending.values()) request.task.cancel(true);
        pending.clear();
        workers.shutdownNow();
    }
}
