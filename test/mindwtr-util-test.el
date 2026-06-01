;;; mindwtr-util-test.el --- Tests for mindwtr-util -*- lexical-binding: t; -*-
(require 'ert)
(require 'mindwtr-util)

(ert-deftest mindwtr-util-loads ()
  "The util library provides its feature."
  (should (featurep 'mindwtr-util)))
