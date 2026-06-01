EMACS ?= emacs

TESTS := $(wildcard test/*-test.el)

.PHONY: test
test:
	$(EMACS) -Q --batch -L . -L test \
	  $(foreach t,$(TESTS),-l $(t)) \
	  -f ert-run-tests-batch-and-exit

.PHONY: compile
compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile mindwtr*.el
