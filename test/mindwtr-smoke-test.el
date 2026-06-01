;;; mindwtr-smoke-test.el --- Tests for the live smoke suite -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-smoke)

(ert-deftest mindwtr-smoke-summary-exit-code ()
  "Summary returns non-zero exactly when a fail was recorded."
  (mindwtr-smoke-reset)
  (mindwtr-smoke-pass "a")
  (mindwtr-smoke-warn "b")
  (should (= 0 (mindwtr-smoke-summary)))
  (mindwtr-smoke-reset)
  (mindwtr-smoke-pass "a")
  (mindwtr-smoke-fail "c")
  (should (= 1 (mindwtr-smoke-summary)))
  ;; warn alone never fails the run
  (mindwtr-smoke-reset)
  (mindwtr-smoke-warn "only a warning")
  (should (= 0 (mindwtr-smoke-summary))))
