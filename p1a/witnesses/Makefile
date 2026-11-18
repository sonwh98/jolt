# P1a witnesses — Gambit 4.9.8 FFI runtime audit (jolt FFI track).
#
# Every run is executed under ./watchdog.sh so a deadlock or crash is a
# recorded FAILURE, never a hang. Outputs are recorded verbatim under
# results/ with a "### exit=" line per run.
#
# Provisioned toolchain (absolute mise paths — NEVER bare gsc from PATH,
# that gsc is Ghostscript):
GSC ?= /Users/sto/.local/share/mise/installs/gambit/4.9.8/bin/gsc
SH  ?= ./watchdog.sh
RES ?= results

.PHONY: all clean build-witnesses

all: build-witnesses record

build-witnesses: w0-config.exe w1.exe w2.exe w3.exe w4.exe

record: record-w0 record-w1 record-w2 record-w3 record-w4

$(RES):
	mkdir -p $(RES)

# ---- builds -------------------------------------------------------------

w0-config.exe: w0-config.scm
	$(GSC) -warnings -exe -o $@ $<

w1.exe: w1-errno.scm w1-fixture.c
	$(GSC) -warnings -exe -o $@ w1-errno.scm w1-fixture.c

w2.exe: w2-blocking.scm w2-fixture.c
	$(GSC) -warnings -exe -o $@ w2-blocking.scm w2-fixture.c

# The manual's documented "Scheme server" build pattern
# (doc/gambit.txi §c-define; tests/makefile.in:166).
w3.exe: w3-fthread.c w3-server.scm
	$(GSC) -warnings -exe -cc-options "-D___LIBRARY" -o $@ w3-fthread.c w3-server.scm

w4.exe: w4-callables.scm w4-fixture.c
	$(GSC) -warnings -exe -o $@ w4-callables.scm w4-fixture.c

# ---- recorded runs ------------------------------------------------------

record-w0: w0-config.exe | $(RES)
	@echo "### cmd: $(SH) 60 ./w0-config.exe" > $(RES)/w0.out
	@$(SH) 60 ./w0-config.exe >> $(RES)/w0.out 2>&1; echo "### exit=$$?" >> $(RES)/w0.out
	@cat $(RES)/w0.out

record-w1: w1.exe | $(RES)
	@echo "### cmd: $(SH) 120 ./w1.exe" > $(RES)/w1.out
	@$(SH) 120 ./w1.exe >> $(RES)/w1.out 2>&1; echo "### exit=$$?" >> $(RES)/w1.out
	@cat $(RES)/w1.out

record-w2: w2.exe | $(RES)
	@echo "### cmd: $(SH) 60 ./w2.exe -:d5 control" > $(RES)/w2-control.out
	@$(SH) 60 ./w2.exe -:d5 control >> $(RES)/w2-control.out 2>&1; echo "### exit=$$?" >> $(RES)/w2-control.out
	@cat $(RES)/w2-control.out
	@echo "### cmd: $(SH) 60 ./w2.exe -:d5 blocked" > $(RES)/w2-blocked.out
	@$(SH) 60 ./w2.exe -:d5 blocked >> $(RES)/w2-blocked.out 2>&1; echo "### exit=$$?" >> $(RES)/w2-blocked.out
	@cat $(RES)/w2-blocked.out

record-w3: w3.exe | $(RES)
	@echo "### cmd: $(SH) 60 ./w3.exe phase1" > $(RES)/w3-phase1.out
	@$(SH) 60 ./w3.exe phase1 >> $(RES)/w3-phase1.out 2>&1; echo "### exit=$$?" >> $(RES)/w3-phase1.out
	@cat $(RES)/w3-phase1.out
	@echo "### cmd: $(SH) 60 ./w3.exe phase1-nobeat" > $(RES)/w3-phase1-nobeat.out
	@$(SH) 60 ./w3.exe phase1-nobeat >> $(RES)/w3-phase1-nobeat.out 2>&1; echo "### exit=$$?" >> $(RES)/w3-phase1-nobeat.out
	@cat $(RES)/w3-phase1-nobeat.out
	@echo "### cmd: $(SH) 60 ./w3.exe phase2 (run 1 of 2)" > $(RES)/w3-phase2-run1.out
	@$(SH) 60 ./w3.exe phase2 >> $(RES)/w3-phase2-run1.out 2>&1; echo "### exit=$$?" >> $(RES)/w3-phase2-run1.out
	@cat $(RES)/w3-phase2-run1.out
	@echo "### cmd: $(SH) 60 ./w3.exe phase2 (run 2 of 2)" > $(RES)/w3-phase2-run2.out
	@$(SH) 60 ./w3.exe phase2 >> $(RES)/w3-phase2-run2.out 2>&1; echo "### exit=$$?" >> $(RES)/w3-phase2-run2.out
	@cat $(RES)/w3-phase2-run2.out
	@echo "### cmd: $(SH) 60 ./w3.exe phase3" > $(RES)/w3-phase3.out
	@$(SH) 60 ./w3.exe phase3 >> $(RES)/w3-phase3.out 2>&1; echo "### exit=$$?" >> $(RES)/w3-phase3.out
	@cat $(RES)/w3-phase3.out

record-w4: w4.exe | $(RES)
	@echo "### cmd: $(SH) 60 ./w4.exe mode1" > $(RES)/w4-mode1.out
	@$(SH) 60 ./w4.exe mode1 >> $(RES)/w4-mode1.out 2>&1; echo "### exit=$$?" >> $(RES)/w4-mode1.out
	@cat $(RES)/w4-mode1.out
	@echo "### cmd: $(SH) 60 ./w4.exe mode4 (run 1 of 3)" > $(RES)/w4-mode4-run1.out
	@$(SH) 60 ./w4.exe mode4 >> $(RES)/w4-mode4-run1.out 2>&1; echo "### exit=$$?" >> $(RES)/w4-mode4-run1.out
	@cat $(RES)/w4-mode4-run1.out
	@echo "### cmd: $(SH) 60 ./w4.exe mode4 (run 2 of 3)" > $(RES)/w4-mode4-run2.out
	@$(SH) 60 ./w4.exe mode4 >> $(RES)/w4-mode4-run2.out 2>&1; echo "### exit=$$?" >> $(RES)/w4-mode4-run2.out
	@cat $(RES)/w4-mode4-run2.out
	@echo "### cmd: $(SH) 60 ./w4.exe mode4 (run 3 of 3)" > $(RES)/w4-mode4-run3.out
	@$(SH) 60 ./w4.exe mode4 >> $(RES)/w4-mode4-run3.out 2>&1; echo "### exit=$$?" >> $(RES)/w4-mode4-run3.out
	@cat $(RES)/w4-mode4-run3.out
	@echo "### cmd: $(SH) 60 ./w4.exe mode5" > $(RES)/w4-mode5.out
	@$(SH) 60 ./w4.exe mode5 >> $(RES)/w4-mode5.out 2>&1; echo "### exit=$$?" >> $(RES)/w4-mode5.out
	@cat $(RES)/w4-mode5.out

clean:
	rm -f *.exe *.o
	rm -f w0-config.c w1-errno.c w1-errno_.c w2-blocking.c w2-blocking_.c \
	      w3-server.c w3-server_.c w4-callables.c w4-callables_.c
	rm -rf $(RES)
