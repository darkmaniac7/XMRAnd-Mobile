package io.xmrand.wrapper;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Host JVM tests for the pause mechanism.
 *
 * <p>The miner is a {@code libxmrig.so} subprocess. Pausing it with SIGSTOP keeps the
 * RandomX dataset, the pool socket and the process itself alive, so a resume costs
 * nothing. That only holds if the stop actually took effect, so every pause is
 * verified by reading the process state out of {@code /proc} rather than assumed
 * from the return code of a signal. These tests cover the parsing, the discovery,
 * the verification and the fallback, none of which needs a device.
 */
public class MinerProcessControlTest {

    private static final String EXE = "/data/app/x/lib/arm64/libxmrig.so";

    // ---------------------------------------------------------------
    // /proc/<pid>/stat parsing. The comm field is attacker shaped: it is
    // whatever the binary is called, it sits in parentheses, and it may
    // contain spaces and parentheses of its own. Splitting on whitespace
    // is the classic way to get this wrong.
    // ---------------------------------------------------------------

    @Test
    public void parsesAPlainStatLine() {
        String stat = "4242 (libxmrig.so) S 4100 4242 4242 0 -1 4194560 123 0 0 0 5 6";
        assertEquals('S', MinerProcessControl.parseState(stat));
        assertEquals(4100, MinerProcessControl.parsePpid(stat));
    }

    @Test
    public void parsesAStoppedProcess() {
        String stat = "4242 (libxmrig.so) T 4100 4242 4242 0 -1 4194560 123 0 0 0 5 6";
        assertEquals('T', MinerProcessControl.parseState(stat));
    }

    @Test
    public void parsesACommContainingSpaces() {
        String stat = "4242 (lib xmrig so) R 4100 4242 4242 0 -1 4194560";
        assertEquals('R', MinerProcessControl.parseState(stat));
        assertEquals(4100, MinerProcessControl.parsePpid(stat));
    }

    @Test
    public void parsesACommContainingParentheses() {
        String stat = "4242 (lib(x)mrig.so) T 4100 4242 4242 0 -1 4194560";
        assertEquals('T', MinerProcessControl.parseState(stat));
        assertEquals(4100, MinerProcessControl.parsePpid(stat));
    }

    @Test
    public void malformedStatIsNotMistakenForAState() {
        assertEquals('?', MinerProcessControl.parseState("garbage with no parens"));
        assertEquals('?', MinerProcessControl.parseState(""));
        assertEquals('?', MinerProcessControl.parseState(null));
        assertEquals(-1, MinerProcessControl.parsePpid("garbage"));
        assertEquals(-1, MinerProcessControl.parsePpid(null));
        assertEquals(-1, MinerProcessControl.parsePpid("4242 (comm) S notanumber"));
    }

    // ---------------------------------------------------------------
    // Discovery
    // ---------------------------------------------------------------

    @Test
    public void findsTheMinerChildAmongOtherProcesses() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "/system/bin/app_process", 'S');
        proc.add(4242, 4100, EXE + " --config=/data/x/config.json", 'S');
        proc.add(4300, 4100, "/system/bin/sh", 'S');
        assertEquals(4242, MinerProcessControl.findChildMinerPid(proc, 4100, EXE));
    }

    @Test
    public void returnsNoPidWhenTheMinerIsNotRunning() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "/system/bin/app_process", 'S');
        assertEquals(-1, MinerProcessControl.findChildMinerPid(proc, 4100, EXE));
    }

    @Test
    public void doesNotClaimAnotherProcessesMiner() {
        // A miner that is not our child is not ours to signal as the live one.
        FakeProcTable proc = new FakeProcTable();
        proc.add(9999, 1, EXE, 'T');
        assertEquals(-1, MinerProcessControl.findChildMinerPid(proc, 4100, EXE));
    }

    /**
     * The leak this closes: if the wrapper process is killed while the miner is
     * SIGSTOPped, the miner is reparented and stays stopped forever, holding its
     * RandomX dataset. On the next start we must find it and clean it up.
     */
    @Test
    public void findsOrphanedMinersLeftOverFromAPreviousRun() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "/system/bin/app_process", 'S');
        proc.add(4242, 4100, EXE, 'S');    // our current child
        proc.add(7777, 1, EXE, 'T');       // orphan, stopped, reparented to init
        proc.add(8888, 1, EXE, 'S');       // orphan, still running
        assertArrayEquals(new int[]{7777, 8888},
                MinerProcessControl.findOrphanMinerPids(proc, 4100, EXE));
    }

    @Test
    public void findsNoOrphansWhenOnlyOurChildIsRunning() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "/system/bin/app_process", 'S');
        proc.add(4242, 4100, EXE, 'S');
        assertEquals(0, MinerProcessControl.findOrphanMinerPids(proc, 4100, EXE).length);
    }

    // ---------------------------------------------------------------
    // Pause and resume, with verification
    // ---------------------------------------------------------------

    @Test
    public void pauseSendsSigstopAndVerifiesTheStoppedState() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "app", 'S');
        proc.add(4242, 4100, EXE, 'S');
        RecordingSignaller sig = new RecordingSignaller(proc);
        MinerProcessControl control = new MinerProcessControl(proc, sig, new NoSleep(), 4100, EXE);

        assertEquals(MinerProcessControl.Outcome.OK, control.pause());
        assertEquals(1, sig.sent.size());
        assertEquals("4242:19", sig.sent.get(0));
        assertEquals('T', proc.state(4242));
    }

    @Test
    public void resumeSendsSigcontAndVerifiesTheProcessIsRunningAgain() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "app", 'S');
        proc.add(4242, 4100, EXE, 'T');
        RecordingSignaller sig = new RecordingSignaller(proc);
        MinerProcessControl control = new MinerProcessControl(proc, sig, new NoSleep(), 4100, EXE);

        assertEquals(MinerProcessControl.Outcome.OK, control.resume());
        assertEquals("4242:18", sig.sent.get(0));
        assertEquals('S', proc.state(4242));
    }

    @Test
    public void pauseToleratesAStateThatTakesAFewReadsToSettle() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "app", 'S');
        proc.add(4242, 4100, EXE, 'S');
        RecordingSignaller sig = new RecordingSignaller(proc);
        sig.applyAfterReads = 3;
        MinerProcessControl control = new MinerProcessControl(proc, sig, new NoSleep(), 4100, EXE);

        assertEquals(MinerProcessControl.Outcome.OK, control.pause());
    }

    /**
     * The silent failure the design has to rule out: the signal call reports
     * success but the process keeps running. SIGSTOP that does not stop must be
     * reported as needing the fallback, never as a pause.
     */
    @Test
    public void aSignalThatDoesNotActuallyStopTheProcessFallsBack() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "app", 'S');
        proc.add(4242, 4100, EXE, 'S');
        RecordingSignaller sig = new RecordingSignaller(proc);
        sig.pretendSuccessButDoNothing = true;
        MinerProcessControl control = new MinerProcessControl(proc, sig, new NoSleep(), 4100, EXE);

        assertEquals(MinerProcessControl.Outcome.FALLBACK, control.pause());
    }

    @Test
    public void aSignalThatThrowsFallsBack() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "app", 'S');
        proc.add(4242, 4100, EXE, 'S');
        RecordingSignaller sig = new RecordingSignaller(proc);
        sig.throwOnSend = true;
        MinerProcessControl control = new MinerProcessControl(proc, sig, new NoSleep(), 4100, EXE);

        assertEquals(MinerProcessControl.Outcome.FALLBACK, control.pause());
    }

    @Test
    public void pausingWhenThereIsNoMinerIsNotAFailure() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "app", 'S');
        RecordingSignaller sig = new RecordingSignaller(proc);
        MinerProcessControl control = new MinerProcessControl(proc, sig, new NoSleep(), 4100, EXE);

        assertEquals(MinerProcessControl.Outcome.NO_PROCESS, control.pause());
        assertEquals(MinerProcessControl.Outcome.NO_PROCESS, control.resume());
        assertTrue(sig.sent.isEmpty());
    }

    /**
     * A resume must never leave the miner stopped. If SIGCONT cannot be verified we
     * report the fallback so the caller kills and restarts, which always works.
     */
    @Test
    public void aResumeThatCannotBeVerifiedFallsBack() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "app", 'S');
        proc.add(4242, 4100, EXE, 'T');
        RecordingSignaller sig = new RecordingSignaller(proc);
        sig.pretendSuccessButDoNothing = true;
        MinerProcessControl control = new MinerProcessControl(proc, sig, new NoSleep(), 4100, EXE);

        assertEquals(MinerProcessControl.Outcome.FALLBACK, control.resume());
    }

    @Test
    public void aProcessThatDiesDuringTheStopIsReportedGone() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "app", 'S');
        proc.add(4242, 4100, EXE, 'S');
        RecordingSignaller sig = new RecordingSignaller(proc);
        sig.removeOnSend = true;
        MinerProcessControl control = new MinerProcessControl(proc, sig, new NoSleep(), 4100, EXE);

        assertEquals(MinerProcessControl.Outcome.NO_PROCESS, control.pause());
    }

    @Test
    public void zombieCountsAsGoneNotAsStopped() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "app", 'S');
        proc.add(4242, 4100, EXE, 'Z');
        RecordingSignaller sig = new RecordingSignaller(proc);
        sig.pretendSuccessButDoNothing = true;
        MinerProcessControl control = new MinerProcessControl(proc, sig, new NoSleep(), 4100, EXE);

        assertEquals(MinerProcessControl.Outcome.NO_PROCESS, control.pause());
    }

    /**
     * Cleanup has to continue a stopped orphan before killing it. A SIGSTOPped
     * process does not act on SIGTERM until it is running again, so kill-only
     * cleanup would leave the very leak it is meant to close.
     */
    @Test
    public void orphanCleanupContinuesBeforeKilling() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "app", 'S');
        proc.add(7777, 1, EXE, 'T');
        RecordingSignaller sig = new RecordingSignaller(proc);
        MinerProcessControl control = new MinerProcessControl(proc, sig, new NoSleep(), 4100, EXE);

        assertEquals(1, control.cleanUpOrphans());
        assertEquals("7777:18", sig.sent.get(0));
        assertEquals("7777:9", sig.sent.get(1));
    }

    @Test
    public void orphanCleanupIsANoOpWhenThereAreNone() {
        FakeProcTable proc = new FakeProcTable();
        proc.add(4100, 1, "app", 'S');
        proc.add(4242, 4100, EXE, 'S');
        RecordingSignaller sig = new RecordingSignaller(proc);
        MinerProcessControl control = new MinerProcessControl(proc, sig, new NoSleep(), 4100, EXE);

        assertEquals(0, control.cleanUpOrphans());
        assertTrue(sig.sent.isEmpty());
    }

    // ---------------------------------------------------------------
    // Fakes
    // ---------------------------------------------------------------

    private static final class FakeProcTable implements MinerProcessControl.ProcTable {
        private final Map<Integer, String> cmdlines = new LinkedHashMap<>();
        private final Map<Integer, Integer> ppids = new LinkedHashMap<>();
        private final Map<Integer, Character> states = new LinkedHashMap<>();
        int reads;
        /** Applied once {@link #reads} reaches the trigger, to model a state that settles late. */
        Runnable deferred;
        int deferredAtRead = -1;

        void add(int pid, int ppid, String cmdline, char state) {
            cmdlines.put(pid, cmdline);
            ppids.put(pid, ppid);
            states.put(pid, state);
        }

        void remove(int pid) {
            cmdlines.remove(pid);
            ppids.remove(pid);
            states.remove(pid);
        }

        void setState(int pid, char state) {
            if (states.containsKey(pid)) {
                states.put(pid, state);
            }
        }

        char state(int pid) {
            Character c = states.get(pid);
            return c == null ? '?' : c;
        }

        @Override
        public int[] pids() {
            List<Integer> all = new ArrayList<>(cmdlines.keySet());
            int[] out = new int[all.size()];
            for (int i = 0; i < out.length; i++) {
                out[i] = all.get(i);
            }
            return out;
        }

        @Override
        public String stat(int pid) {
            reads++;
            if (deferredAtRead >= 0 && reads >= deferredAtRead) {
                deferredAtRead = -1;
                deferred.run();
            }
            if (!states.containsKey(pid)) {
                return null;
            }
            return pid + " (libxmrig.so) " + states.get(pid) + " " + ppids.get(pid) + " 0 0 0 -1 0";
        }

        @Override
        public String cmdline(int pid) {
            return cmdlines.get(pid);
        }
    }

    private static final class RecordingSignaller implements MinerProcessControl.Signaller {
        private final FakeProcTable proc;
        final List<String> sent = new ArrayList<>();
        boolean pretendSuccessButDoNothing;
        boolean throwOnSend;
        boolean removeOnSend;
        int applyAfterReads;

        RecordingSignaller(FakeProcTable proc) {
            this.proc = proc;
        }

        @Override
        public void send(int pid, int signal) {
            if (throwOnSend) {
                throw new RuntimeException("sendSignal refused");
            }
            sent.add(pid + ":" + signal);
            if (removeOnSend) {
                proc.remove(pid);
                return;
            }
            if (pretendSuccessButDoNothing) {
                return;
            }
            if (applyAfterReads > 0) {
                // The state settles only after a few reads, so the caller has to
                // poll rather than read once and give up.
                proc.deferredAtRead = proc.reads + applyAfterReads;
                proc.deferred = () -> apply(pid, signal);
                return;
            }
            apply(pid, signal);
        }

        void apply(int pid, int signal) {
            if (signal == MinerProcessControl.SIGSTOP) {
                proc.setState(pid, 'T');
            } else if (signal == MinerProcessControl.SIGCONT) {
                proc.setState(pid, 'S');
            } else if (signal == MinerProcessControl.SIGKILL) {
                proc.remove(pid);
            }
        }
    }

    private static final class NoSleep implements MinerProcessControl.Sleeper {
        @Override
        public void sleep(long ms) {
            // Nothing. Tests must not spend wall clock on retry backoff.
        }
    }
}
