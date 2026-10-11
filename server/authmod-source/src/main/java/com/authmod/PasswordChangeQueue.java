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

/** Bounded verification and hashing for authenticated players changing a password. */
final class PasswordChangeQueue implements AutoCloseable {
    enum Submission { ACCEPTED, ALREADY_PENDING, BUSY }
    record Result(boolean oldVerified, String newHash) {
        static Result failure() { return new Result(false, null); }
    }

    @FunctionalInterface
    interface Computer {
        Result apply(String oldPassword, String newPassword, String stored);
    }

    static final Computer DEFAULT_COMPUTER = (oldPassword, newPassword, stored) -> {
        boolean valid = PasswordHasher.isLegacy(stored)
                ? stored.equals(oldPassword) : PasswordHasher.verify(oldPassword, stored);
        if (!valid) return Result.failure();
        return new Result(true, PasswordHasher.hash(newPassword));
    };

    private static final AtomicInteger THREAD_IDS = new AtomicInteger();
    private final ThreadPoolExecutor workers;
    private final Computer computer;
    private final Map<Object, Request> pending = new IdentityHashMap<>();

    private static final class Request {
        FutureTask<Void> task;
    }

    PasswordChangeQueue(int workerCount, int waitingCapacity, Computer computer) {
        if (workerCount < 1 || waitingCapacity < 1) throw new IllegalArgumentException("Queue capacity must be positive");
        this.computer = computer;
        ThreadFactory threadFactory = task -> {
            Thread thread = new Thread(task, "AuthMod-change-" + THREAD_IDS.incrementAndGet());
            thread.setDaemon(true);
            return thread;
        };
        workers = new ThreadPoolExecutor(workerCount, workerCount, 0, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(waitingCapacity), threadFactory,
                new ThreadPoolExecutor.AbortPolicy());
        workers.prestartAllCoreThreads();
    }

    synchronized Submission submit(Object connection, String oldPassword, String newPassword,
                                   String stored, Executor completionExecutor, Consumer<Result> onResult) {
        if (pending.containsKey(connection)) return Submission.ALREADY_PENDING;
        if (workers.isShutdown()) return Submission.BUSY;

        Request request = new Request();
        request.task = new FutureTask<>(() -> {
            Result result;
            try {
                result = computer.apply(oldPassword, newPassword, stored);
            } catch (RuntimeException e) {
                result = Result.failure();
            }
            Result finished = result;
            try {
                completionExecutor.execute(() -> {
                    synchronized (PasswordChangeQueue.this) {
                        if (pending.get(connection) != request) return;
                        pending.remove(connection);
                    }
                    onResult.accept(finished);
                });
            } catch (RuntimeException e) {
                synchronized (PasswordChangeQueue.this) {
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
