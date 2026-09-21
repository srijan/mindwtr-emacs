;;; mindwtr-parity-test.el --- -*- lexical-binding: t; -*-
;;; Commentary:
;; Offline gate for `mindwtr-parity': the model's synced-field registry must
;; match the Mindwtr core's own sync-schema fixtures.  Skips when
;; MINDWTR_CORE_PATH names no upstream checkout, so `make test' stays green on
;; a machine that has only this repo.
;;; Code:

(require 'ert)
(require 'mindwtr-model)
(require 'mindwtr-parity)

(ert-deftest mindwtr-parity-every-entity-has-a-fixture ()
  "Each checked entity resolves to a readable upstream fixture."
  (let ((dir (mindwtr-parity-core-dir)))
    (skip-unless dir)
    (dolist (entity mindwtr-parity-entities)
      (let ((fx (mindwtr-parity-fixture entity dir)))
        (should (file-readable-p (plist-get fx :file)))
        (should (plist-get fx :wire))
        ;; Any integer: the fixture's schemaVersion is reported, never gated
        ;; on (see `mindwtr-parity-fixture'), so pinning an allow-list here
        ;; only turns every upstream schema bump into a false failure.
        (should (integerp (plist-get fx :version)))))))

(ert-deftest mindwtr-parity-covers-every-known-entity-type ()
  "Every type in the model registry is checked -- notably `person'.
`mindwtr-smoke-schema-coverage' omits person, so without this the newest
entity type would have no drift detection at all."
  (dolist (entry mindwtr-model-known-fields)
    (should (memq (car entry) mindwtr-parity-entities))))

(ert-deftest mindwtr-parity-no-drift ()
  "The model declares exactly the fields upstream declares.
A failure here means the server learned a field (or dropped one) and
`mindwtr-model-known-fields' has not caught up.  Adopting a new field into
that registry is recognition only -- it does NOT put the field on the
`mindwtr-model-content-fields' allow-list, which stays allow-list-LAST and
requires a proven byte-stable round-trip first."
  (let ((dir (mindwtr-parity-core-dir)))
    (skip-unless dir)
    ;; Formatted rather than raw so a failure names the drifted fields.
    (should-not (mindwtr-parity-format
                 (mindwtr-parity-drift (mindwtr-parity-check dir))))))

(ert-deftest mindwtr-parity-detects-injected-drift ()
  "The check reports a field the fixture declares but the model lacks.
Guards the gate itself: a comparison that silently passed everything would
look identical to a clean run."
  (let ((dir (mindwtr-parity-core-dir)))
    (skip-unless dir)
    (let* ((mindwtr-model-known-fields
            (mapcar (lambda (entry)
                      (if (eq (car entry) 'task)
                          (cons 'task (remq :title (cdr entry)))
                        entry))
                    mindwtr-model-known-fields))
           (result (mindwtr-parity-check dir))
           (task (cdr (assq 'task result))))
      (should (memq :title (plist-get task :missing)))
      (should (mindwtr-parity-drift result)))))

(ert-deftest mindwtr-parity-extra-field-is-not-drift ()
  "A field the model knows but the fixture omits is noted, never a failure.
CI reads the fixtures at the pinned server version (`DEFAULT_CLOUD_TAG'),
which normally lags upstream, so recognizing a newer field must not turn the
build red.  Only `:missing' -- a field the server can send that nothing here
recognizes -- is drift."
  (let ((dir (mindwtr-parity-core-dir)))
    (skip-unless dir)
    (let* ((mindwtr-model-known-fields
            (mapcar (lambda (entry)
                      (if (eq (car entry) 'area)
                          (cons 'area (cons :notAFieldUpstreamHas (cdr entry)))
                        entry))
                    mindwtr-model-known-fields))
           (result (mindwtr-parity-check dir))
           (area (cdr (assq 'area result))))
      (should (memq :notAFieldUpstreamHas (plist-get area :extra)))
      (should-not (plist-get area :missing))
      (should-not (mindwtr-parity-drift result)))))

(ert-deftest mindwtr-parity-ignores-legacy-aliases ()
  "A deprecated upstream alias is noted, never reported as missing.
Task `orderNum' is `legacy-alias' upstream; the model still reads it as an
order fallback, which must not register as drift."
  (let ((dir (mindwtr-parity-core-dir)))
    (skip-unless dir)
    (let ((task (cdr (assq 'task (mindwtr-parity-check dir)))))
      (should (memq :orderNum (plist-get task :legacy)))
      (should-not (memq :orderNum (plist-get task :missing))))))

(ert-deftest mindwtr-parity-skips-without-a-checkout ()
  "With MINDWTR_CORE_PATH unset the check returns nil rather than failing."
  (let ((process-environment (cons "MINDWTR_CORE_PATH=" process-environment)))
    (should-not (mindwtr-parity-core-dir))
    (should-not (mindwtr-parity-check))))

;;; mindwtr-parity-test.el ends here
