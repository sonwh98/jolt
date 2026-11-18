# P1a-MT witnesses — multithreaded-4.9.8 experiment (jolt FFI track).
#
# The codex review's experiment (Q3 "Experiment needed", steps 1-5):
#   1. pinned 4.9.8 build with --enable-multiple-threaded-vms --enable-smp
#      --enable-max-processors=8, out-of-tree in ../gambit-builds/mt
#   2. EXPLICIT parallelism: W0MT/W2MT via -:p2 on the command line (the
#      gsi/gsc driver parses it, main.c:46-49); W3MT (server pattern) via
#      setup_params.parallelism_level = 2 in w3mt-main.c
#   3. W2MT blocking-GC witness with A/B synchronized before A enters C, B
#      on a different processor, C released only after B's real GC rounds
#      mutate live rooted objects, verdict from observed state, watchdogged
#   4. W3MT foreign-pthread witness with (int int) signatures, owner-thread
#      control first, then naive serialized/concurrent entry and the
#      best-effort undocumented attach bridge (ingredients cited in
#      w3mt-main.c), allocation/GC pressure, teardown, repeated attachment
#   5. macOS arm64 now; Linux leg pending (follow-up, not run here)
#
# Every run is executed under ./watchdog.sh so a deadlock or crash is a
# recorded FAILURE, never a hang. Outputs are recorded verbatim under
# results/ with a "### exit=" line per run. Qualification is decided by the
# witness verdicts (observed state), NOT by make's exit status.
#
# Toolchain: the MT build's OWN gsc (NOT the installed single-threaded one,
# and NEVER bare `gsc` from PATH — that is Ghostscript). The build tree has no
# bin/gsc (make install is broken out-of-tree), so gsc lives in gambit-builds/mt/gsc/
# and is given the build tree's gambitdir explicitly via -: runtime options
# (~~bin/~~lib/~~include), which gsc forwards to gambuild-C as
# GAMBITDIR_INCLUDE/GAMBITDIR_LIB (_gsclib.scm ##gambuild, ##shell-install-dirs).
# The compiler needs an explicit min-heap: on this MT build the stock default
# heap fails to boot when the processor count makes the initial msection pool
# insufficient (see results/mt-default-parallelism.out for the recorded
# side-experiment), and heap GROWTH during a -:p2 gsc -exe of a multi-module
# program segfaults deterministically inside the compiler (___H___gvm, data
# abort writing near-NULL, processor 1 idle in the scheduler; recorded in
# BUILD-CONFIG.md). A large initial heap avoids growth entirely.
GSCBUILD ?= /Users/sto/workspace/jolt-ffi-mt/p1a-mt/gambit-builds/mt
GSCOPTS  ?= -:~~bin=$(GSCBUILD)/bin,~~lib=$(GSCBUILD)/lib,~~include=$(GSCBUILD)/include,min-heap=256M,max-heap=1G,p2
GSC ?= $(GSCBUILD)/gsc/gsc $(GSCOPTS)
SH  ?= ./watchdog.sh
RES ?= results

.PHONY: all clean build-witnesses record

all: build-witnesses record

build-witnesses: w0mt.exe w2mt.exe w3mt.exe

record: record-build-config record-w0mt record-w2mt record-w3mt

$(RES):
	mkdir -p $(RES)

# ---- build configuration record (review step 1) --------------------------

record-build-config: | $(RES)
	@echo "### configure invocation (cwd=$(CURDIR)/../gambit-builds/mt, out-of-tree from /Users/sto/workspace/gambit-v4.9.8-src):" > $(RES)/build-configure.txt
	@echo "### /Users/sto/workspace/gambit-v4.9.8-src/configure --enable-single-host --enable-multiple-threaded-vms --enable-smp --enable-max-processors=8" >> $(RES)/build-configure.txt
	@echo "### compiler:" >> $(RES)/build-configure.txt
	@clang --version | head -2 >> $(RES)/build-configure.txt 2>&1
	@echo "### make: make -j8 (Apple clang 21.0.0, macOS 26.6.2 / Darwin 25.6.0, arm64, 8 CPUs)" >> $(RES)/build-configure.txt
	@echo "### out-of-tree build fixes applied inside the build tree ONLY:" >> $(RES)/build-configure.txt
	@echo "###   1. copied gsc-boot.unix + gsc-boot.bat.windows from the source root into the build root (dummy-gsc-boot rule uses bare relative paths)" >> $(RES)/build-configure.txt
	@echo "###   2. rewrote GAMBITDIR_INCLUDE and the \$(srcdirpfx)\$(rootfromhere)/include dependency paths in generated makefiles to the build tree's include dir (configure-generated gambit.h lives there, not in the source tree)" >> $(RES)/build-configure.txt
	@echo "### generated gambit.h threading macros (build tree):" >> $(RES)/build-configure.txt
	@grep -n "___MULTIPLE_THREADED_VMS\|___SINGLE_THREADED_VMS\|___MAX_PROCESSORS" ../gambit-builds/mt/include/gambit.h | head -8 >> $(RES)/build-configure.txt 2>&1
	@echo "### installed single-threaded provisioned gambit.h (mise) for comparison:" >> $(RES)/build-configure.txt
	@grep -n "___SINGLE_THREADED_VMS\|___MULTIPLE_THREADED_VMS\|___MAX_PROCESSORS" /Users/sto/.local/share/mise/installs/gambit/4.9.8/include/gambit.h | head -6 >> $(RES)/build-configure.txt 2>&1
	@echo "### source pin:" >> $(RES)/build-configure.txt
	@cd /Users/sto/workspace/gambit-v4.9.8-src && git rev-parse HEAD >> $(CURDIR)/$(RES)/build-configure.txt 2>&1 && git describe --tags >> $(CURDIR)/$(RES)/build-configure.txt 2>&1
	@echo "### this worktree pin:" >> $(RES)/build-configure.txt
	@cd /Users/sto/workspace/jolt-ffi-mt && git rev-parse HEAD >> $(CURDIR)/$(RES)/build-configure.txt 2>&1
	@cat $(RES)/build-configure.txt

# ---- builds -------------------------------------------------------------

w0mt.exe: w0mt-config.scm
	$(GSC) -warnings -exe -o $@ $<

w2mt.exe: w2mt.scm w2mt-fixture.c
	$(GSC) -warnings -exe -o $@ w2mt.scm w2mt-fixture.c

# The manual's documented "Scheme server" build pattern
# (doc/gambit.txi §c-define; tests/makefile.in pattern). -keep-temp retains
# the generated C so the (int int) signature check can be recorded verbatim.
w3mt.exe: w3mt-main.c w3mt-server.scm
	$(GSC) -warnings -keep-temp -exe -cc-options "-D___LIBRARY" -o $@ w3mt-main.c w3mt-server.scm

# ---- recorded runs ------------------------------------------------------

record-w0mt: w0mt.exe | $(RES)
	@echo "### cmd: $(SH) 60 ./w0mt.exe -:p2,d5,min-heap=64M,max-heap=512M" > $(RES)/w0mt.out
	@$(SH) 60 ./w0mt.exe -:p2,d5,min-heap=64M,max-heap=512M >> $(RES)/w0mt.out 2>&1; echo "### exit=$$?" >> $(RES)/w0mt.out
	@cat $(RES)/w0mt.out
	@echo "### side-record: stock DEFAULT parallelism (0 -> 50% of 8 CPUs = 4) on this MT build:" > $(RES)/mt-default-parallelism.out
	@echo "### cmd: ./w0mt.exe   (NO runtime options: default parallelism 4 processors)" >> $(RES)/mt-default-parallelism.out
	@$(SH) 30 ./w0mt.exe >> $(RES)/mt-default-parallelism.out 2>&1; echo "### exit=$$?" >> $(RES)/mt-default-parallelism.out
	@echo "### cmd: ./w0mt.exe -:p2  (EXPLICIT parallelism: works)" >> $(RES)/mt-default-parallelism.out
	@$(SH) 30 ./w0mt.exe -:p2 >> $(RES)/mt-default-parallelism.out 2>&1; echo "### exit=$$?" >> $(RES)/mt-default-parallelism.out
	@cat $(RES)/mt-default-parallelism.out

record-w2mt: w2mt.exe | $(RES)
	@echo "### cmd: $(SH) 90 ./w2mt.exe -:p2,d5,min-heap=64M,max-heap=512M control" > $(RES)/w2mt-control.out
	@$(SH) 90 ./w2mt.exe -:p2,d5,min-heap=64M,max-heap=512M control >> $(RES)/w2mt-control.out 2>&1; echo "### exit=$$?" >> $(RES)/w2mt-control.out
	@cat $(RES)/w2mt-control.out
	@echo "### cmd: $(SH) 90 ./w2mt.exe -:p2,d5,min-heap=64M,max-heap=512M blocked" > $(RES)/w2mt-blocked.out
	@$(SH) 90 ./w2mt.exe -:p2,d5,min-heap=64M,max-heap=512M blocked >> $(RES)/w2mt-blocked.out 2>&1; echo "### exit=$$?" >> $(RES)/w2mt-blocked.out
	@cat $(RES)/w2mt-blocked.out

record-w3mt: w3mt.exe | $(RES)
	@echo "### generated C signature check (review F1 correction: two formals for (int int)):" > $(RES)/w3mt-generated-signatures.txt
	@grep -n "int scheme_w3mt_add\|___NARGS" w3mt-server.c w3mt-server_.c 2>/dev/null | head -16 >> $(RES)/w3mt-generated-signatures.txt 2>&1
	@cat $(RES)/w3mt-generated-signatures.txt
	@echo "### cmd: $(SH) 60 ./w3mt.exe owner" > $(RES)/w3mt-owner.out
	@$(SH) 60 ./w3mt.exe owner >> $(RES)/w3mt-owner.out 2>&1; echo "### exit=$$?" >> $(RES)/w3mt-owner.out
	@cat $(RES)/w3mt-owner.out
	@echo "### cmd: $(SH) 60 ./w3mt.exe p1" > $(RES)/w3mt-p1.out
	@$(SH) 60 ./w3mt.exe p1 >> $(RES)/w3mt-p1.out 2>&1; echo "### exit=$$?" >> $(RES)/w3mt-p1.out
	@cat $(RES)/w3mt-p1.out
	@echo "### cmd: $(SH) 60 ./w3mt.exe p2" > $(RES)/w3mt-p2.out
	@$(SH) 60 ./w3mt.exe p2 >> $(RES)/w3mt-p2.out 2>&1; echo "### exit=$$?" >> $(RES)/w3mt-p2.out
	@cat $(RES)/w3mt-p2.out
	@echo "### cmd: $(SH) 120 ./w3mt.exe bridge" > $(RES)/w3mt-bridge.out
	@$(SH) 120 ./w3mt.exe bridge >> $(RES)/w3mt-bridge.out 2>&1; echo "### exit=$$?" >> $(RES)/w3mt-bridge.out
	@cat $(RES)/w3mt-bridge.out
	@echo "### cmd: $(SH) 120 ./w3mt.exe bridge-concurrent" > $(RES)/w3mt-bridge-concurrent.out
	@$(SH) 120 ./w3mt.exe bridge-concurrent >> $(RES)/w3mt-bridge-concurrent.out 2>&1; echo "### exit=$$?" >> $(RES)/w3mt-bridge-concurrent.out
	@cat $(RES)/w3mt-bridge-concurrent.out
	@echo "### cmd: $(SH) 180 ./w3mt.exe reattach" > $(RES)/w3mt-reattach.out
	@$(SH) 180 ./w3mt.exe reattach >> $(RES)/w3mt-reattach.out 2>&1; echo "### exit=$$?" >> $(RES)/w3mt-reattach.out
	@cat $(RES)/w3mt-reattach.out

clean:
	rm -f *.exe *.o
	rm -f w0mt-config.c w2mt.c w2mt_.c w3mt-server.c w3mt-server_.c
	rm -rf $(RES)
