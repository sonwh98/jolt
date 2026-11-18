# P1a witnesses — Gambit 4.9.8 FFI runtime audit (jolt FFI track).
#
# p1a-r2 build hygiene (per the codex review): ALL build artifacts live under
# build/ — never beside the tracked sources, and `clean` NEVER touches the
# tracked results/ (the P1a Makefile wrote executables beside the sources and
# its `clean` deleted results/).
#
# Recording flow:
#   make all              builds every witness under build/ (byte-identical
#                         copies of the sources), runs each under
#                         build/watchdog.sh (SIGKILL + exit 124 on timeout, so
#                         a deadlock is a recorded FAILURE, never a hang),
#                         records verbatim outputs under build/results/, then
#                         VERIFYs every expected verdict marker. A missing or
#                         wrong marker fails `make all`.
#   make record-tracked   AFTER a full PASS-verified run: copies the repaired
#                         witnesses' fresh outputs into the TRACKED results/.
#                         The tracked results/*.out are overwritten ONLY by
#                         this target, and only after `verify` passed.
#
# W3 repair verification: the w3 build regenerates with -keep-temp and
# VERIFIES the generated C shows two C arguments and ___NARGS 2 for BOTH
# exported entries BEFORE any run (review finding F1).
#
# Provisioned toolchain (absolute mise paths — NEVER bare gsc from PATH,
# that gsc is Ghostscript):
GSC ?= /Users/sto/.local/share/mise/installs/gambit/4.9.8/bin/gsc
SH  ?= ./watchdog.sh
BUILD ?= build
BRES ?= $(BUILD)/results
RES ?= results

.PHONY: all build-witnesses record verify verify-w3-c record-tracked clean

all: build-witnesses record verify

build-witnesses: $(BUILD)/w0-config.exe $(BUILD)/w1.exe $(BUILD)/w2.exe $(BUILD)/w3.exe $(BUILD)/w4.exe

record: record-w0 record-w1 record-w2 record-w3 record-w4

$(BUILD) $(BRES):
	mkdir -p $@

$(BUILD)/watchdog.sh: watchdog.sh | $(BUILD)
	cp $< $@

# ---- sources into build/ (byte-identical copies) -------------------------

$(BUILD)/w0-config.scm: w0-config.scm | $(BUILD)
	cp $< $@
$(BUILD)/w1-errno.scm: w1-errno.scm | $(BUILD)
	cp $< $@
$(BUILD)/w1-fixture.c: w1-fixture.c | $(BUILD)
	cp $< $@
$(BUILD)/w2-blocking.scm: w2-blocking.scm | $(BUILD)
	cp $< $@
$(BUILD)/w2-fixture.c: w2-fixture.c | $(BUILD)
	cp $< $@
$(BUILD)/w3-fthread.c: w3-fthread.c | $(BUILD)
	cp $< $@
$(BUILD)/w3-server.scm: w3-server.scm | $(BUILD)
	cp $< $@
$(BUILD)/w4-callables.scm: w4-callables.scm | $(BUILD)
	cp $< $@
$(BUILD)/w4-fixture.c: w4-fixture.c | $(BUILD)
	cp $< $@

# ---- builds (inside build/) ----------------------------------------------

$(BUILD)/w0-config.exe: $(BUILD)/w0-config.scm $(BUILD)/watchdog.sh
	cd $(BUILD) && $(GSC) -warnings -exe -o w0-config.exe w0-config.scm

$(BUILD)/w1.exe: $(BUILD)/w1-errno.scm $(BUILD)/w1-fixture.c $(BUILD)/watchdog.sh
	cd $(BUILD) && $(GSC) -warnings -exe -o w1.exe w1-errno.scm w1-fixture.c

$(BUILD)/w2.exe: $(BUILD)/w2-blocking.scm $(BUILD)/w2-fixture.c $(BUILD)/watchdog.sh
	cd $(BUILD) && $(GSC) -warnings -exe -o w2.exe w2-blocking.scm w2-fixture.c

# The manual's documented "Scheme server" build pattern
# (doc/gambit.txi §c-define; tests/makefile.in:166). -keep-temp retains the
# generated C in build/ for the F1 verification below.
$(BUILD)/w3.exe: $(BUILD)/w3-fthread.c $(BUILD)/w3-server.scm $(BUILD)/watchdog.sh
	cd $(BUILD) && $(GSC) -warnings -keep-temp -exe -cc-options "-D___LIBRARY" -o w3.exe w3-fthread.c w3-server.scm
	@$(MAKE) --no-print-directory verify-w3-c

# F1 repair verification: the generated C must declare TWO arguments for
# BOTH add entries and carry ___NARGS 2 — checked BEFORE any run.
verify-w3-c: $(BUILD)/w3.exe
	@echo "verify-w3-c: generated C must show (int int) and ___NARGS 2 for both exports"
	@grep -q 'extern int scheme_w3_add ___P((int ___arg1,int ___arg2)' $(BUILD)/w3-server.c \
	  || { echo "VERIFY-W3-C-FAIL: scheme_w3_add is not declared (int, int) in generated C"; exit 1; }
	@grep -q 'extern int scheme_w3_add_alloc ___P((int ___arg1,int ___arg2)' $(BUILD)/w3-server.c \
	  || { echo "VERIFY-W3-C-FAIL: scheme_w3_add_alloc is not declared (int, int) in generated C"; exit 1; }
	@awk '/extern int scheme_w3_add ___P/,/^}/' $(BUILD)/w3-server.c | grep -q '#define ___NARGS 2' \
	  || { echo "VERIFY-W3-C-FAIL: scheme_w3_add does not have ___NARGS 2"; exit 1; }
	@awk '/extern int scheme_w3_add_alloc ___P/,/^}/' $(BUILD)/w3-server.c | grep -q '#define ___NARGS 2' \
	  || { echo "VERIFY-W3-C-FAIL: scheme_w3_add_alloc does not have ___NARGS 2"; exit 1; }
	@awk '/extern int scheme_w3_phase3 ___P/,/^}/' $(BUILD)/w3-server.c | grep -q '#define ___NARGS 0' \
	  || { echo "VERIFY-W3-C-FAIL: scheme_w3_phase3 does not have ___NARGS 0 (void-arg consistency)"; exit 1; }
	@echo "VERIFY-W3-C: OK (scheme_w3_add + scheme_w3_add_alloc: two C args, ___NARGS 2; scheme_w3_phase3: ___NARGS 0)"

$(BUILD)/w4.exe: $(BUILD)/w4-callables.scm $(BUILD)/w4-fixture.c $(BUILD)/watchdog.sh
	cd $(BUILD) && $(GSC) -warnings -exe -o w4.exe w4-callables.scm w4-fixture.c

# ---- recorded runs (into build/results/ — scratch) -----------------------

record-w0: $(BUILD)/w0-config.exe | $(BRES)
	@echo "### cmd: $(SH) 60 ./w0-config.exe" > $(BRES)/w0.out
	@cd $(BUILD) && $(SH) 60 ./w0-config.exe >> ../$(BRES)/w0.out 2>&1; echo "### exit=$$?" >> ../$(BRES)/w0.out
	@cat $(BRES)/w0.out

record-w1: $(BUILD)/w1.exe | $(BRES)
	@echo "### cmd: $(SH) 120 ./w1.exe" > $(BRES)/w1.out
	@cd $(BUILD) && $(SH) 120 ./w1.exe >> ../$(BRES)/w1.out 2>&1; echo "### exit=$$?" >> ../$(BRES)/w1.out
	@cat $(BRES)/w1.out

record-w2: $(BUILD)/w2.exe | $(BRES)
	@echo "### cmd: $(SH) 60 ./w2.exe -:d5 control" > $(BRES)/w2-control.out
	@cd $(BUILD) && $(SH) 60 ./w2.exe -:d5 control >> ../$(BRES)/w2-control.out 2>&1; st=$$?; echo "### exit=$$st" >> ../$(BRES)/w2-control.out; \
	case $$st in \
	  0) echo "### w2-outcome: run completed (verdict derived inside; see the W2-CONTROL-VERDICT line)" >> ../$(BRES)/w2-control.out;; \
	  124) echo "### w2-outcome: FAILURE (independent watchdog timeout — recorded failure)" >> ../$(BRES)/w2-control.out;; \
	  *) echo "### w2-outcome: FAILURE (unexpected exit $$st)" >> ../$(BRES)/w2-control.out;; \
	esac
	@cat $(BRES)/w2-control.out
	@echo "### cmd: $(SH) 60 ./w2.exe -:d5 qualify" > $(BRES)/w2-qualify.out
	@cd $(BUILD) && $(SH) 60 ./w2.exe -:d5 qualify >> ../$(BRES)/w2-qualify.out 2>&1; st=$$?; echo "### exit=$$st" >> ../$(BRES)/w2-qualify.out; \
	case $$st in \
	  0) echo "### w2-outcome: run completed (verdict derived from observed state; see the W2-QUALIFY-VERDICT line)" >> ../$(BRES)/w2-qualify.out;; \
	  3) echo "### w2-outcome: FAILURE (observed state internally inconsistent)" >> ../$(BRES)/w2-qualify.out;; \
	  124) echo "### w2-outcome: FAILURE (independent watchdog timeout — recorded failure)" >> ../$(BRES)/w2-qualify.out;; \
	  *) echo "### w2-outcome: FAILURE (unexpected exit $$st)" >> ../$(BRES)/w2-qualify.out;; \
	esac
	@cat $(BRES)/w2-qualify.out
	@echo "### cmd: $(SH) 60 ./w2.exe -:d5 blocked" > $(BRES)/w2-blocked.out
	@cd $(BUILD) && $(SH) 60 ./w2.exe -:d5 blocked >> ../$(BRES)/w2-blocked.out 2>&1; st=$$?; echo "### exit=$$st" >> ../$(BRES)/w2-blocked.out; \
	case $$st in \
	  0) echo "### w2-outcome: run completed (starvation demonstration; verdict derived inside)" >> ../$(BRES)/w2-blocked.out;; \
	  2) echo "### w2-outcome: FAILURE (observed state contradicts the documented starvation)" >> ../$(BRES)/w2-blocked.out;; \
	  124) echo "### w2-outcome: FAILURE (independent watchdog timeout — recorded failure)" >> ../$(BRES)/w2-blocked.out;; \
	  *) echo "### w2-outcome: FAILURE (unexpected exit $$st)" >> ../$(BRES)/w2-blocked.out;; \
	esac
	@cat $(BRES)/w2-blocked.out

# W3 phase classification: fatal exits (70 = Gambit fatal, 134/138/139 =
# fatal signal: SIGABRT/SIGBUS/SIGSEGV) are ALL the documented
# refusal-failure (unsafe foreign-thread entry) — any of them is a valid
# record of the refusal, never a success; survival (exit 0) is
# REFUSAL-NOT-REPRODUCED — the reviewer-mandated nondeterminism caveat, also
# never a success; wrong values are UNSAFE-ENTRY-OBSERVED; timeouts,
# control failures and unexpected exits are failures.
define W3_PHASE_RECORD
	@echo "### cmd: $(SH) 60 ./w3.exe $(1)" > $(BRES)/$(2)
	@cd $(BUILD) && $(SH) 60 ./w3.exe $(1) >> ../$(BRES)/$(2) 2>&1; st=$$?; echo "### exit=$$st" >> ../$(BRES)/$(2); \
	case $$st in \
	  70|134|138|139) echo "### w3-outcome: UNSAFE-ENTRY-REPRODUCED (documented refusal-failure: exit $$st = the foreign pthread could not safely enter Scheme; never a success)" >> ../$(BRES)/$(2);; \
	  0) echo "### w3-outcome: REFUSAL-NOT-REPRODUCED (worker survived — undocumented serialized reuse of the single pstate, never qualification of foreign-thread entry)" >> ../$(BRES)/$(2);; \
	  1) echo "### w3-outcome: FAILURE (owner-thread control failed)" >> ../$(BRES)/$(2);; \
	  2) echo "### w3-outcome: UNSAFE-ENTRY-OBSERVED (worker entered with WRONG VALUES — corruption)" >> ../$(BRES)/$(2);; \
	  124) echo "### w3-outcome: FAILURE (independent watchdog timeout)" >> ../$(BRES)/$(2);; \
	  *) echo "### w3-outcome: FAILURE (unexpected exit $$st)" >> ../$(BRES)/$(2);; \
	esac
	cat $(BRES)/$(2)
endef

record-w3: $(BUILD)/w3.exe | $(BRES)
	@echo "### cmd: $(SH) 60 ./w3.exe control" > $(BRES)/w3-control.out
	@cd $(BUILD) && $(SH) 60 ./w3.exe control >> ../$(BRES)/w3-control.out 2>&1; st=$$?; echo "### exit=$$st" >> ../$(BRES)/w3-control.out; \
	case $$st in \
	  0) echo "### w3-outcome: CONTROL-PASS (owner-thread callbacks through the same c-define entries succeeded before any foreign-thread phase)" >> ../$(BRES)/w3-control.out;; \
	  *) echo "### w3-outcome: FAILURE (owner-thread control exit $$st)" >> ../$(BRES)/w3-control.out;; \
	esac
	@cat $(BRES)/w3-control.out
	$(call W3_PHASE_RECORD,phase1,w3-phase1.out)
	$(call W3_PHASE_RECORD,phase1-nobeat,w3-phase1-nobeat.out)
	$(call W3_PHASE_RECORD,phase2,w3-phase2-run1.out)
	$(call W3_PHASE_RECORD,phase2,w3-phase2-run2.out)
	$(call W3_PHASE_RECORD,phase3,w3-phase3.out)

record-w4: $(BUILD)/w4.exe | $(BRES)
	@echo "### cmd: $(SH) 60 ./w4.exe mode1" > $(BRES)/w4-mode1.out
	@cd $(BUILD) && $(SH) 60 ./w4.exe mode1 >> ../$(BRES)/w4-mode1.out 2>&1; echo "### exit=$$?" >> ../$(BRES)/w4-mode1.out
	@cat $(BRES)/w4-mode1.out
	@echo "### cmd: $(SH) 60 ./w4.exe mode4 (run 1 of 3)" > $(BRES)/w4-mode4-run1.out
	@cd $(BUILD) && $(SH) 60 ./w4.exe mode4 >> ../$(BRES)/w4-mode4-run1.out 2>&1; echo "### exit=$$?" >> ../$(BRES)/w4-mode4-run1.out
	@cat $(BRES)/w4-mode4-run1.out
	@echo "### cmd: $(SH) 60 ./w4.exe mode4 (run 2 of 3)" > $(BRES)/w4-mode4-run2.out
	@cd $(BUILD) && $(SH) 60 ./w4.exe mode4 >> ../$(BRES)/w4-mode4-run2.out 2>&1; echo "### exit=$$?" >> ../$(BRES)/w4-mode4-run2.out
	@cat $(BRES)/w4-mode4-run2.out
	@echo "### cmd: $(SH) 60 ./w4.exe mode4 (run 3 of 3)" > $(BRES)/w4-mode4-run3.out
	@cd $(BUILD) && $(SH) 60 ./w4.exe mode4 >> ../$(BRES)/w4-mode4-run3.out 2>&1; echo "### exit=$$?" >> ../$(BRES)/w4-mode4-run3.out
	@cat $(BRES)/w4-mode4-run3.out
	@echo "### cmd: $(SH) 60 ./w4.exe mode5" > $(BRES)/w4-mode5.out
	@cd $(BUILD) && $(SH) 60 ./w4.exe mode5 >> ../$(BRES)/w4-mode5.out 2>&1; echo "### exit=$$?" >> ../$(BRES)/w4-mode5.out
	@cat $(BRES)/w4-mode5.out

# ---- verify: assertive checks (a missing or wrong verdict marker FAILS) --

verify: 
	@echo "=== verify: assertive verdict-marker checks over $(BRES)/ ==="
	@fail=0; \
	check() { if grep -qF -- "$$2" "$(BRES)/$$1" 2>/dev/null; then echo "verify: OK   $$1 :: $$2"; else echo "verify: FAIL $$1 :: missing [$$2]"; fail=1; fi; }; \
	checke() { if grep -Eq -- "$$2" "$(BRES)/$$1" 2>/dev/null; then echo "verify: OK   $$1 :: /$$2/"; else echo "verify: FAIL $$1 :: missing [/$2/]"; fail=1; fi; }; \
	check w0.out "W0-VERDICT: PASS"; \
	check w0.out "### exit=0"; \
	check w1.out "W1-NEGATIVE-CONTROL: OK"; \
	check w1.out "W1-FAILURES=0"; \
	check w1.out "W1-VERDICT: PASS"; \
	check w1.out "### exit=0"; \
	check w2-control.out "W2-CONTROL-VERDICT: PASS"; \
	check w2-control.out "### exit=0"; \
	check w2-qualify.out "W2-QUALIFY-VERDICT: FAIL (blocking unqualified on this build"; \
	check w2-qualify.out "rounds-during-block=0"; \
	check w2-qualify.out "handshake-during-block=0"; \
	check w2-qualify.out "### exit=0"; \
	check w2-blocked.out "W2-STARVATION-DEMO-VERDICT: STARVATION-DEMONSTRATED"; \
	check w2-blocked.out "### exit=0"; \
	check w3-control.out "W3-CONTROL-VERDICT: PASS"; \
	check w3-control.out "### exit=0"; \
	checke w3-phase1.out "w3-outcome: (UNSAFE-ENTRY-REPRODUCED|UNSAFE-ENTRY-OBSERVED|REFUSAL-NOT-REPRODUCED)"; \
	checke w3-phase1-nobeat.out "w3-outcome: (UNSAFE-ENTRY-REPRODUCED|UNSAFE-ENTRY-OBSERVED|REFUSAL-NOT-REPRODUCED)"; \
	checke w3-phase2-run1.out "w3-outcome: (UNSAFE-ENTRY-REPRODUCED|UNSAFE-ENTRY-OBSERVED|REFUSAL-NOT-REPRODUCED)"; \
	checke w3-phase2-run2.out "w3-outcome: (UNSAFE-ENTRY-REPRODUCED|UNSAFE-ENTRY-OBSERVED|REFUSAL-NOT-REPRODUCED)"; \
	checke w3-phase3.out "w3-outcome: (UNSAFE-ENTRY-REPRODUCED|UNSAFE-ENTRY-OBSERVED|REFUSAL-NOT-REPRODUCED)"; \
	check w4-mode1.out "W4-VERDICT: PASS"; \
	check w4-mode4-run1.out "W4-VERDICT: PASS-QUALIFIED"; \
	check w4-mode4-run2.out "W4-VERDICT: PASS-QUALIFIED"; \
	check w4-mode4-run3.out "W4-VERDICT: PASS-QUALIFIED"; \
	check w4-mode5.out "### exit=70"; \
	check w4-mode5.out "*** ERROR IN w4-m5"; \
	if [ $$fail -ne 0 ]; then echo "VERIFY: FAIL (assertive verdict checks failed — refusing to record)"; exit 1; fi; \
	echo "VERIFY: PASS (every expected verdict marker present in $(BRES)/)"

# ---- tracked recording: ONLY after a full PASS-verified run ---------------

# Copies the REPAIRED witnesses' fresh outputs into the tracked results/.
# w0/w4 sources are unchanged in this round; their tracked P1a recordings
# remain the ones in results/ (fresh equivalents live in build/results/).
record-tracked: all
	cp $(BRES)/w1.out $(RES)/w1.out
	cp $(BRES)/w2-control.out $(RES)/w2-control.out
	cp $(BRES)/w2-qualify.out $(RES)/w2-qualify.out
	cp $(BRES)/w2-blocked.out $(RES)/w2-blocked.out
	cp $(BRES)/w3-control.out $(RES)/w3-control.out
	cp $(BRES)/w3-phase1.out $(RES)/w3-phase1.out
	cp $(BRES)/w3-phase1-nobeat.out $(RES)/w3-phase1-nobeat.out
	cp $(BRES)/w3-phase2-run1.out $(RES)/w3-phase2-run1.out
	cp $(BRES)/w3-phase2-run2.out $(RES)/w3-phase2-run2.out
	cp $(BRES)/w3-phase3.out $(RES)/w3-phase3.out
	@echo "record-tracked: repaired witnesses' verified outputs copied to $(RES)/"

# clean removes build artifacts ONLY — never build/results/ (the reviewer's
# rerun artifacts and the working recordings live there; the p1a-r2 Makefile
# that shipped first had `rm -rf build`, which is exactly how the reviewer
# artifacts were lost once — never again).
clean:
	rm -f $(BUILD)/*.exe $(BUILD)/*.o $(BUILD)/*.c
	rm -f $(BUILD)/*.scm $(BUILD)/watchdog.sh
