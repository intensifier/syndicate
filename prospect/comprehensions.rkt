#lang racket

(provide for-trie/list
         for-trie/set
         for-trie/patch
         for-trie/fold)

(require "core.rkt"
         (only-in "actor.rkt" analyze-pattern)
         (for-syntax racket/syntax)
         (for-syntax syntax/strip-context)
         (for-syntax racket/match))

(begin-for-syntax
  ; Pattern-Syntax Syntax -> (SyntaxOf TempVar TempVar Projection-Pattern Match-Pattern)
  (define (helper pat-stx outer-stx)
    (match-define (list temp1 temp2) (generate-temporaries #'(tmp1 tmp2)))
    (define-values (proj-stx pat match-pat bindings)
      (analyze-pattern outer-stx pat-stx))
    (datum->syntax
     outer-stx
     (list temp1 temp2 pat match-pat))))

(define-syntax (for-trie/fold stx)
  (syntax-case stx ()
    [(_ ([acc-id acc-init] ...)
        ((pat_0 trie_0)
         (pat_n trie_n) ...
         #:where pred)
        body)
     (with-syntax* ([(set-tmp loop-tmp proj-stx match-pat)
                     (helper #'pat_0 #'body)]
                    [new-acc (generate-temporary 'acc)])
       #`(let ([set-tmp (trie-project/set trie_0
                                          (compile-projection (?! proj-stx)))])
           (for/fold/derived #,stx ([acc-id acc-init]
                                    ...)
             ([loop-tmp (in-set set-tmp)])
             (match loop-tmp
               [(list match-pat)
                (for-trie/fold ([acc-id acc-id]
                                ...)
                               ([pat_n trie_n]
                                ...
                                #:where pred)
                  body)]
               [_ (values acc-id ...)]))))]
    [(_ ([acc-id acc-init] ...)
        (#:where pred)
        body)
     #'(if pred body (values acc-id ...))]
    [(_ ([acc-id acc-init] ...) ([pat exp] ...) body)
     #'(for-trie/fold ([acc-id acc-init] ...) ([pat exp] ... #:where #t) body)]
    [(_ (accs ...) (clauses ...) body_0 body_1 body_n ...)
     (with-syntax [(new-body (replace-context #'body_0
                                              #'(begin body_0 body_1 body_n ...)))]
       #'(for-trie/fold (accs ...) (clauses ...) new-body))]))

(define-syntax (make-fold stx)
  (syntax-case stx ()
    [(_ name folder initial)
     #'(define-syntax (name stx)
         (syntax-case stx ()
           [(_ ([pat expr] (... ...) #:where pred) body)
            (with-syntax* ([acc (replace-context #'body (generate-temporary 'acc))]
                           [new-body #'(folder body acc)]
                           [new-body (replace-context #'body #'new-body)])
              #'(for-trie/fold ([acc initial])
                               ([pat expr]
                                (... ...)
                                #:where pred)
                  new-body))]
           [(_ ([pat exp] (... ...)) body)
            #'(name ([pat exp] (... ...) #:where #t) body)]
           [(_ (clauses (... ...)) body_0 body_1 body_n (... ...))
            (with-syntax [(new-body (replace-context #'body_0
                                                     #'(begin body_0 body_1 body_n (... ...))))]
              #'(name (clauses (... ...)) new-body))]))]))


(make-fold for-trie/list cons empty)

(define (set-folder x acc)
  (set-add acc x))

(make-fold for-trie/set set-folder (set))

(make-fold for-trie/patch patch-seq empty-patch)

(module+ test
  (require rackunit)
  
  (require "route.rkt")
  
  (define (make-trie . vs)
    (for/fold ([acc (trie-empty)])
              ([v (in-list vs)])
      (trie-union acc (pattern->trie 'a v))))
  
  (check-equal? (for-trie/list ([$x (make-trie 1 2 3 4)]
                                #:where (even? x))
                  (+ x 1))
                '(3 5))
  
  (check-equal? (for-trie/set ([$x (make-trie 1 2 3 4)]
                               #:where (even? x))
                  (+ x 1))
                (set 3 5))
  (check-equal? (for-trie/set ([(cons $x _) (make-trie 1 2 (list 0) (list 1 2 3) (cons 'x 'y) (cons 3 4) (cons 'a 'b) "x" 'foo)])
                  x)
                (set 'x 3 'a))
  (check-equal? (for-trie/fold ([acc 0])
                               ([$x (make-trie 1 2 3 4)]
                                #:where (even? x))
                  (+ acc x))
                6)
  (check-equal? (for-trie/fold ([acc 0])
                               ([$x (make-trie 1 2 3 4)]
                                [x (make-trie 0 1 2 4)]
                                #:where (even? x))
                  (+ acc x))
                6)
  (let-values ([(acc1 acc2)
                (for-trie/fold ([acc1 0]
                                [acc2 0])
                               ([(cons $x $y) (make-trie (cons 1 2)
                                                         (cons 3 8)
                                                         (cons 9 7))])
                  (values (+ acc1 x)
                          (+ acc2 y)))])
    (check-equal? acc1 13)
    (check-equal? acc2 17))
  (check-equal? (for-trie/set ([$x (make-trie 1 2 3)]
                               [$y (make-trie 4 5 6)])
                  (cons x y))
                (set (cons 1 4) (cons 1 5) (cons 1 6)
                     (cons 2 4) (cons 2 5) (cons 2 6)
                     (cons 3 4) (cons 3 5) (cons 3 6)))
  (let ([p (for-trie/patch ([$x (make-trie 1 2 3 4)])
             (retract x))])
    (check-equal? (trie-project/set (patch-removed p) (compile-projection (?!)))
                  (set '(1) '(2) '(3) '(4))))
  (check-equal? (for-trie/set ([$x (make-trie 1 2 3)]
                               [(cons x 3) (make-trie (cons 'x 'y)
                                                      (cons 5 5)
                                                      (cons 2 4)
                                                      (cons 3 3)
                                                      (cons 4 3))])
                  (cons x 4))
                (set (cons 3 4)))
  (check-equal? (for-trie/set ([(cons $x $x) (make-trie 'a 'b
                                                        (cons 'x 'y)
                                                        (cons 2 3)
                                                        3 4
                                                        'x
                                                        (cons 1 1)
                                                        "abc"
                                                        (cons 'x 'x))])
                  x)
                (set 1 'x))
  (check-equal? (for-trie/set ([$x (make-trie 1 2 3)])
                  (void)
                  x)
                (set 1 2 3))
  (check-equal? (for-trie/fold ([acc 0])
                               ([$x (make-trie 1 2 3)])
                  (void)
                  (+ acc x))
                6))

