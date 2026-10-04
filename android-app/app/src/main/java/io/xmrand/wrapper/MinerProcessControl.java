package io.xmrand.wrapper;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;

/**
 * Pauses and resumes the {@code libxmrig.so} subprocess without killing it.
 *
 * <p><b>Why not just stop and restart it.</b> The wrapper starts the miner with
 * {@link ProcessBuilder}, which gives only start and destroy. Killing the miner to
 * yield the CPU means that every resume rebuilds the RandomX dataset, which is a
 * multi second all core burst and a fresh 2 GB allocation. That burst lands right
 * after a pause ends, which is the worst possible moment, and it throws away
 * the pool connection and any partial work every single time.
 *
 * <p>SIGSTOP freezes every thread in the miner immediately and SIGCONT thaws it.
 * The process, its dataset, its JIT mappings and its pool socket all survive, so a
 * resume costs nothing. This is the Android equivalent of the {@code p} and
 * {@code r} controls the iOS build drives on the libuv loop thread.
 *
 * <p><b>A signal that is not verified is not a pause.</b> {@code sendSignal} can
 * return without the process having stopped. Since a miner that silently keeps
 * running defeats the whole feature, every pause is confirmed by reading the
 * process state out of {@code /proc}. If it cannot be confirmed the caller is told
 * to fall back to the stop and restart path, which is slower but always works.
 *
 * <p>All process access goes through {@link ProcTable}, {@link Signaller} and
 * {@link Sleeper} so the logic is exercised on the host JVM with no device.
 */
public final class MinerProcessControl {

    /**
     * Linux signal numbers. These values are the same on arm, arm64, x86 and x86_64,
     * which is every ABI Android ships. They differ only on alpha, mips and sparc,
     * which Android does not target.
     */
    public static final int SIGCONT = 18;
    public static final int SIGSTOP = 19;
    public static final int SIGKILL = 9;

    private static final int VERIFY_ATTEMPTS = 12;
    private static final long VERIFY_BACKOFF_MS = 25L;

    public enum Outcome {
        /** The signal was sent and the resulting process state was confirmed. */
        OK,
        /** There is no miner process to act on. Not an error. */
        NO_PROCESS,
        /** The signal path did not work. The caller must stop and restart instead. */
        FALLBACK
    }

    /** The subset of {@code /proc} this needs, so tests can supply a fake one. */
    public interface ProcTable {
        int[] pids();

        /** Contents of {@code /proc/<pid>/stat}, or null if the process is gone. */
        String stat(int pid);

        /** Contents of {@code /proc/<pid>/cmdline}, or null if the process is gone. */
        String cmdline(int pid);
    }

    public interface Signaller {
        void send(int pid, int signal);
    }

    public interface Sleeper {
        void sleep(long ms);
    }

    private final ProcTable proc;
    private final Signaller signaller;
    private final Sleeper sleeper;
    private final int ownPid;
    private final String exePath;

    public MinerProcessControl(ProcTable proc, Signaller signaller, Sleeper sleeper,
                               int ownPid, String exePath) {
        this.proc = proc;
        this.signaller = signaller;
        this.sleeper = sleeper;
        this.ownPid = ownPid;
        this.exePath = exePath;
    }

    // ---------------------------------------------------------------
    // /proc/<pid>/stat parsing
    // ---------------------------------------------------------------

    /**
     * Process state character from a stat line, or {@code '?'} if it cannot be read.
     *
     * <p>The second field is the executable name in parentheses and it may itself
     * contain spaces and parentheses, so the only correct anchor is the last closing
     * parenthesis in the line.
     */
    public static char parseState(String statLine) {
        int close = lastParen(statLine);
        if (close < 0) {
            return '?';
        }
        int i = close + 1;
        while (i < statLine.length() && statLine.charAt(i) == ' ') {
            i++;
        }
        return i < statLine.length() ? statLine.charAt(i) : '?';
    }

    /** Parent pid from a stat line, or -1 if it cannot be read. */
    public static int parsePpid(String statLine) {
        int close = lastParen(statLine);
        if (close < 0) {
            return -1;
        }
        String[] fields = statLine.substring(close + 1).trim().split("\\s+");
        if (fields.length < 2) {
            return -1;
        }
        try {
            return Integer.parseInt(fields[1]);
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    private static int lastParen(String statLine) {
        return statLine == null ? -1 : statLine.lastIndexOf(')');
    }

    private static boolean isGone(char state) {
        // Z is a zombie and X is dead. Neither is something we can pause or resume.
        return state == '?' || state == 'Z' || state == 'X' || state == 'x';
    }

    private static boolean isStopped(char state) {
        // T is stopped by a job control signal, t is stopped by a tracer.
        return state == 'T' || state == 't';
    }

    // ---------------------------------------------------------------
    // Discovery
    // ---------------------------------------------------------------

    /** Pid of the miner started by this process, or -1 if it is not running. */
    public static int findChildMinerPid(ProcTable proc, int ownPid, String exePath) {
        for (int pid : proc.pids()) {
            if (!isMiner(proc, pid, exePath)) {
                continue;
            }
            String stat = proc.stat(pid);
            if (stat != null && parsePpid(stat) == ownPid) {
                return pid;
            }
        }
        return -1;
    }

    /**
     * Miners that are not our child. After the wrapper process is killed the miner
     * is reparented to init, and if it was paused at the time it stays SIGSTOPped
     * forever holding its dataset. Those are the processes this finds.
     */
    public static int[] findOrphanMinerPids(ProcTable proc, int ownPid, String exePath) {
        List<Integer> found = new ArrayList<>();
        for (int pid : proc.pids()) {
            if (pid == ownPid || !isMiner(proc, pid, exePath)) {
                continue;
            }
            String stat = proc.stat(pid);
            if (stat != null && parsePpid(stat) != ownPid) {
                found.add(pid);
            }
        }
        int[] out = new int[found.size()];
        for (int i = 0; i < out.length; i++) {
            out[i] = found.get(i);
        }
        return out;
    }

    private static boolean isMiner(ProcTable proc, int pid, String exePath) {
        String cmdline = proc.cmdline(pid);
        return cmdline != null && cmdline.contains(exePath);
    }

    // ---------------------------------------------------------------
    // Pause and resume
    // ---------------------------------------------------------------

    /** Freezes the miner. See {@link Outcome}. */
    public Outcome pause() {
        return signalAndVerify(SIGSTOP, true);
    }

    /** Thaws the miner. See {@link Outcome}. */
    public Outcome resume() {
        return signalAndVerify(SIGCONT, false);
    }

    private Outcome signalAndVerify(int signal, boolean wantStopped) {
        int pid = findChildMinerPid(proc, ownPid, exePath);
        if (pid < 0) {
            return Outcome.NO_PROCESS;
        }
        try {
            signaller.send(pid, signal);
        } catch (RuntimeException e) {
            return Outcome.FALLBACK;
        }
        for (int attempt = 0; attempt < VERIFY_ATTEMPTS; attempt++) {
            String stat = proc.stat(pid);
            if (stat == null) {
                return Outcome.NO_PROCESS;
            }
            char state = parseState(stat);
            if (isGone(state)) {
                return Outcome.NO_PROCESS;
            }
            if (isStopped(state) == wantStopped) {
                return Outcome.OK;
            }
            sleeper.sleep(VERIFY_BACKOFF_MS);
        }
        return Outcome.FALLBACK;
    }

    /**
     * Continues then kills any miner left behind by a previous run. The SIGCONT is
     * not optional: a stopped process does not act on SIGTERM until it is running
     * again, so cleaning up with a kill alone would leave exactly the orphan this
     * is meant to remove.
     *
     * @return how many orphans were cleaned up
     */
    public int cleanUpOrphans() {
        int[] orphans = findOrphanMinerPids(proc, ownPid, exePath);
        for (int pid : orphans) {
            try {
                signaller.send(pid, SIGCONT);
                signaller.send(pid, SIGKILL);
            } catch (RuntimeException ignored) {
                // Best effort. A pid that vanished between the scan and the signal
                // is already what we wanted.
            }
        }
        return orphans.length;
    }

    // ---------------------------------------------------------------
    // Real implementations
    // ---------------------------------------------------------------

    /** Reads the real {@code /proc}. */
    public static final class RealProcTable implements ProcTable {
        @Override
        public int[] pids() {
            String[] names = new File("/proc").list();
            if (names == null) {
                return new int[0];
            }
            int[] out = new int[names.length];
            int n = 0;
            for (String name : names) {
                try {
                    out[n] = Integer.parseInt(name);
                    n++;
                } catch (NumberFormatException notAPid) {
                    // /proc also holds non numeric entries such as "self" and
                    // "meminfo". Skip them.
                }
            }
            int[] trimmed = new int[n];
            System.arraycopy(out, 0, trimmed, 0, n);
            return trimmed;
        }

        @Override
        public String stat(int pid) {
            return read("/proc/" + pid + "/stat");
        }

        @Override
        public String cmdline(int pid) {
            String raw = read("/proc/" + pid + "/cmdline");
            // cmdline separates arguments with NUL bytes.
            return raw == null ? null : raw.replace('\0', ' ');
        }

        private static String read(String path) {
            try {
                return new String(Files.readAllBytes(new File(path).toPath()), StandardCharsets.UTF_8);
            } catch (IOException | RuntimeException e) {
                // A process that exited between the listing and the read, or one we
                // are not allowed to see, is simply not there as far as we care.
                return null;
            }
        }
    }

    /** Sends real signals via {@code android.os.Process.sendSignal}. */
    public static final class RealSignaller implements Signaller {
        @Override
        public void send(int pid, int signal) {
            android.os.Process.sendSignal(pid, signal);
        }
    }

    /** Sleeps for real, without swallowing interruption. */
    public static final class RealSleeper implements Sleeper {
        @Override
        public void sleep(long ms) {
            try {
                Thread.sleep(ms);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }
}
