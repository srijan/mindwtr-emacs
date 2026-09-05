EMACS ?= emacs

TESTS := $(wildcard test/*-test.el)

.PHONY: test
test:
	$(EMACS) -Q --batch -L . -L smoke -L test \
	  $(foreach t,$(TESTS),-l $(t)) \
	  -f ert-run-tests-batch-and-exit

.PHONY: compile
compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile mindwtr*.el

# Compare the model's synced-field registry against the Mindwtr core's own
# sync-schema fixtures.  Needs no server -- point MINDWTR_CORE_PATH at an
# upstream checkout (monorepo root or packages/core/src).  Skips cleanly when
# unset; exits 1 on drift.  Also runs inside `make test' as an ERT gate.
.PHONY: parity
parity:
	$(EMACS) -Q --batch -L . -L smoke -l mindwtr-parity \
	  --eval '(kill-emacs (if (mindwtr-parity-report) 1 0))'

.PHONY: smoke
smoke:
	$(EMACS) -Q --batch -L . -L smoke -l smoke/run.el

.PHONY: smoke-write
smoke-write:
	MINDWTR_SMOKE_WRITE=1 $(EMACS) -Q --batch -L . -L smoke -l smoke/run.el

# Spin up a real Mindwtr cloud server in Docker, run the smoke suite against it,
# and cross-validate the /v1/data wire with an independent curl client.  Skips
# cleanly when Docker/Emacs are unavailable.  Pin a version with
# MINDWTR_CLOUD_TAG=0.9.7.  See test/integration/README.md.
.PHONY: smoke-docker
smoke-docker:
	EMACS=$(EMACS) test/integration/run.sh
