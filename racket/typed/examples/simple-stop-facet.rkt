#lang typed/syndicate

;; Expected Output:
;; +42
;; +18
;; +9
;; +88
;; -18
;; -9

(define-type-alias ds-type
  (U (Tuple Int)
     (Observe (Tuple ★/t))))

(run-ground-dataspace ds-type
  (spawn #:type ds-type
   (print-role
   (start-facet doomed
     (assert (tuple 18))
     (on (asserted (tuple 42))
         (stop doomed
                (start-facet the-afterlife
                  (assert (tuple 88))))))))

  (spawn #:type ds-type
    (start-facet obs
      (assert (tuple 42))
      (on (asserted (tuple (bind x Int)))
          (printf "+~v\n" x))
      (on (retracted (tuple (bind x Int)))
          (printf "-~v\n" x))))

  ;; null-ary stop
  (spawn #:type ds-type
    (start-facet meep
      (assert (tuple 9))
      (on (asserted (tuple 88))
          (stop meep)))))
