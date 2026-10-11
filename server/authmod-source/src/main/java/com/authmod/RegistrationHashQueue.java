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
import java.util.function.Consumer;
import java.util.function.Function;

/** Only password hashing runs off-thread; account data stays on the server thread. */
final class RegistrationHashQueue implements AutoCloseable {
    enum Submission { ACCEPTED, ALREADY_PENDING, BUSY }

    private static final AtomicInteger THREAD_IDS = new AtomicInteger();
    private final ThreadPoolExecutor workers;
    private final Function<String, String> hasher;
    private final Map<Object, Request> pending = new IdentityHashMap<>();

    private static final class Request {
        FutureTask<Void> task;
    }

    RegistrationHashQueue(int workerCount, int waitingCapacity, Function<String, String> hasher) {
        if (workerCount < 1 || waitingCapacity < 1) throw new IllegalArgumentException("Queue capacity must be positive");
        this.hasher = hasher;
        ThreadFactory threadFactory = task -> {
            Thread thread = new Thread(task, "AuthMod-register-" + THREAD_IDS.incrementAndGet());
            thread.setDaemon(true);
            return thread;
        };
        workers = new ThreadPoolExecutor(workerCount, workerCount, 0, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(waitingCapacity), threadFactory,
                new ThreadPoolExecutor.AbortPolicy());
        workers.prestartAllCoreThreads();
    }

    synchronized Submission submit(Object connection, String password, Executor completionExecutor,
                                   Consumer<String> onHash) {
        if (pending.containsKey(connection)) return Submission.ALREADY_PENDING;
        if (workers.isShutdown()) return Submission.BUSY;

        Request request = new Request();
        request.task = new FutureTask<>(() -> {
            String hashed;
            try {
                hashed = hasher.apply(password);
            } catch (RuntimeException e) {
                // Fail closed. Never log the password or pass a failed hash to storage.
                hashed = null;
            }
            String result = hashed;
            try {
                completionExecutor.execute(() -> {
                    synchronized (RegistrationHashQueue.this) {
                        if (pending.get(connection) != request) return;
                        pending.remove(connection);
                    }
                    onHash.accept(result);
                });
            } catch (RejectedExecutionException e) {
                synchronized (RegistrationHashQueue.this) {
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
