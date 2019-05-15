#lang typed/syndicate/roles

(require rackunit/turnstile)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Type Abstraction
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define id
 (Λ [τ]
   (lambda ([x : τ])
     x)))

(check-type id : (∀ (τ) (→fn τ τ)))

(check-type ((inst id Int) 1)
            : Int
            ⇒ 1)
(check-type ((inst id String) "hello")
            : String
            ⇒ "hello")

(define poly-first
  (Λ [τ σ]
     (lambda ([t : (Tuple τ σ)])
       (select 0 t))))

(check-type poly-first : (∀ (A B) (→fn (Tuple A B) A)))

(check-type ((inst poly-first Int String) (tuple 13 "XD"))
            : Int
            ⇒ 13)

(check-type ((inst poly-first Int String) (tuple 13 "XD"))
            : Int
            ⇒ 13)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Polymorphic Definitions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (∀ (X) (id2 [x : X] -> X))
  x)

(check-type ((inst id2 Int) 42)
            : Int
            ⇒ 42)

(define (∀ (X) (id3 [x : X]))
  x)

(check-type (+ ((inst id3 Int) 42) 1)
            : Int
            ⇒ 43)
