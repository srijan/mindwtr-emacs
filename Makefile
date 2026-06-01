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

.PHONY: smoke
smoke:
	$(EMACS) -Q --batch -L . -L smoke -l smoke/run.el

.PHONY: smoke-write
smoke-write:
	MINDWTR_SMOKE_WRITE=1 $(EMACS) -Q --batch -L . -L smoke -l smoke/run.el
