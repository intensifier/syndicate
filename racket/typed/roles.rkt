#lang turnstile

(provide (rename-out [syndicate:#%module-begin #%module-begin])
         (rename-out [typed-app #%app])
         #%top-interaction
         require only-in
         ;; Types
         Int Bool String Tuple Bind Discard → List
         Role Reacts Shares Know ¬Know Message
         FacetName Field ★/t
         Observe Inbound Outbound Actor U
         ;; Statements
         #;let spawn #;dataspace start-facet set! #;begin #;stop #;unsafe-do
         ;; endpoints
         assert on
         ;; expressions
         tuple #;λ ref observe inbound outbound
         ;; values
         #%datum
         ;; patterns
         bind discard
         ;; primitives
         + - * / and or not > < >= <= = equal? displayln
         ;; making types
         define-type-alias
         define-constructor
         ;; DEBUG and utilities
         print-type print-role
         (rename-out [printf- printf])
         ;; Extensions
         ;; match if cond
         )

(require (prefix-in syndicate: syndicate/actor-lang))

(require (for-meta 2 macrotypes/stx-utils racket/list syntax/stx))
(require (for-syntax turnstile/examples/util/filter-maximal))
(require macrotypes/postfix-in)
(require (rename-in racket/math [exact-truncate exact-truncate-]))
(require (postfix-in - racket/list))
(require (postfix-in - racket/set))

(module+ test
  (require rackunit)
  (require turnstile/rackunit-typechecking))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Type Checking Conventions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; : describes the immediate result of evaluation
;; a key aggregates `assert` endpoints as `Shares`
;; r key aggregates each `on` endpoint as a `Reacts`
;; f key aggregates facet effects (starting a facet) as `Role`s
;; s key aggregates spawned actors as `Actor`s

;; TODO - chan the `a` and `r` keys be merged into one 'endpoint' key?


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Types
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-binding-type Role #:arity >= 0 #:bvs = 1)
(define-type-constructor Shares #:arity = 1)
(define-type-constructor Reacts #:arity >= 1)
(define-type-constructor Know #:arity = 1)
(define-type-constructor ¬Know #:arity = 1)
(define-type-constructor Message #:arity = 1)
(define-type-constructor Field #:arity = 1)
(define-type-constructor Bind #:arity = 1)

(define-type-constructor → #:arity > 0)
(define-type-constructor Tuple #:arity >= 0)
(define-type-constructor Observe #:arity = 1)
(define-type-constructor Inbound #:arity = 1)
(define-type-constructor Outbound #:arity = 1)
(define-type-constructor Actor #:arity = 1)
(define-type-constructor AssertionSet #:arity = 1)
(define-type-constructor Patch #:arity = 2)
(define-type-constructor List #:arity = 1)
(define-type-constructor Set #:arity = 1)

(define-base-types Int Bool String Discard ★/t FacetName)

(define-for-syntax (type-eval t)
  ((current-type-eval) t))

(define-type-constructor U* #:arity >= 0)

(define-for-syntax (prune+sort tys)
  (stx-sort 
   (filter-maximal 
    (stx->list tys)
    typecheck?)))
  
(define-syntax (U stx)
  (syntax-parse stx
    [(_ . tys)
     ;; canonicalize by expanding to U*, with only (sorted and pruned) leaf tys
     #:with ((~or (~U* ty1- ...) ty2-) ...) (stx-map (current-type-eval) #'tys)
     #:with tys- (prune+sort #'(ty1- ... ... ty2- ...))
     (if (= 1 (stx-length #'tys-))
         (stx-car #'tys-)
         (syntax/loc stx (U* . tys-)))]))

;; for looking at the "effects"
(begin-for-syntax
  (define-syntax ~effs
    (pattern-expander
     (syntax-parser
       [(_ eff:id ...)
        #:with tmp (generate-temporary 'effss)
        #'(~and tmp
                (~parse (eff ...) (stx-or #'tmp #'())))])))

  (define (stx-truth? a)
    (and a (not (and (syntax? a) (false? (syntax-e a))))))
  (define (stx-or a b)
    (cond [(stx-truth? a) a]
          [else b])))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; User Defined Types, aka Constructors
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; τ.norm in 1st case causes "not valid type" error when referring to ⊥ in another file.
;; however, this version expands the type at every reference, incurring a potentially large
;; overhead---2x in the case of book-club.rkt
;; (copied from ext-stlc example)
(define-syntax define-type-alias
  (syntax-parser
    [(_ alias:id τ)
     #'(define-syntax- alias
         (make-variable-like-transformer #'τ))]
    [(_ (f:id x:id ...) ty)
     #'(define-syntax- (f stx)
         (syntax-parse stx
           [(_ x ...)
            #:with τ:any-type #'ty
            #'τ.norm]))]))

(begin-for-syntax
  (define-splicing-syntax-class type-constructor-decl
    (pattern (~seq #:type-constructor TypeCons:id))
    (pattern (~seq) #:attr TypeCons #f))

  (struct user-ctor (typed-ctor untyped-ctor)
    #:property prop:procedure
    (lambda (v stx)
      (define transformer (user-ctor-typed-ctor v))
      (syntax-parse stx
        [(_ e ...)
         #`(#,transformer e ...)]))))

(define-syntax (define-constructor stx)
  (syntax-parse stx
    [(_ (Cons:id slot:id ...)
        ty-cons:type-constructor-decl
        (~seq #:with
              Alias AliasBody) ...)
     #:with TypeCons (or (attribute ty-cons.TypeCons) (format-id stx "~a/t" (syntax-e #'Cons)))
     #:with MakeTypeCons (format-id #'TypeCons "make-~a" #'TypeCons)
     #:with GetTypeParams (format-id #'TypeCons "get-~a-type-params" #'TypeCons)
     #:with TypeConsExpander (format-id #'TypeCons "~~~a" #'TypeCons)
     #:with TypeConsExtraInfo (format-id #'TypeCons "~a-extra-info" #'TypeCons)
     #:with (StructName Cons- type-tag) (generate-temporaries #'(Cons Cons Cons))
     (define arity (stx-length #'(slot ...)))
     #`(begin-
         (struct- StructName (slot ...) #:reflection-name 'Cons #:transparent)
         (define-syntax (TypeConsExtraInfo stx)
           (syntax-parse stx
             [(_ X (... ...)) #'('type-tag 'MakeTypeCons 'GetTypeParams)]))
         (define-type-constructor TypeCons
           #:arity = #,arity
           #:extra-info 'TypeConsExtraInfo)
         (define-syntax (MakeTypeCons stx)
           (syntax-parse stx
             [(_ t (... ...))
              #:fail-unless (= #,arity (stx-length #'(t (... ...)))) "arity mismatch"
              #'(TypeCons t (... ...))]))
         (define-syntax (GetTypeParams stx)
           (syntax-parse stx
             [(_ (TypeConsExpander t (... ...)))
              #'(t (... ...))]))
         (define-syntax Cons
           (user-ctor #'Cons- #'StructName))
         (define-typed-syntax (Cons- e (... ...)) ≫
           #:fail-unless (= #,arity (stx-length #'(e (... ...)))) "arity mismatch"
           [⊢ e ≫ e- (⇒ : τ) (⇒ a (~effs)) (⇒ r (~effs)) (⇒ f (~effs)) (⇒ s (~effs))] (... ...)
           ----------------------
           [⊢ (#%app- StructName e- (... ...)) (⇒ : (TypeCons τ (... ...)))])
         (define-type-alias Alias AliasBody) ...)]))

(begin-for-syntax
  (define-syntax ~constructor-extra-info
    (pattern-expander
     (syntax-parser
       [(_ tag mk get)
        #'(_ (_ tag) (_ mk) (_ get))])))

  (define-syntax ~constructor-type
    (pattern-expander
     (syntax-parser
       [(_ tag . rst)
        #'(~and it
                (~fail #:unless (user-defined-type? #'it))
                (~parse tag (get-type-tag #'it))
                (~Any _ . rst))])))

  (define-syntax ~constructor-exp
    (pattern-expander
     (syntax-parser
       [(_ cons . rst)
        #'(~and (cons . rst)
                (~fail #:unless (ctor-id? #'cons)))])))

  (define (inspect t)
    (syntax-parse t
      [(~constructor-type tag t ...)
       (list (syntax-e #'tag) (stx-map type->str #'(t ...)))]))

  (define (tags-equal? t1 t2)
    (equal? (syntax-e t1) (syntax-e t2)))
    
  (define (user-defined-type? t)
    (get-extra-info (type-eval t)))

  (define (get-type-tag t)
    (syntax-parse (get-extra-info t)
      [(~constructor-extra-info tag _ _)
       (syntax-e #'tag)]))

  (define (get-type-args t)
    (syntax-parse (get-extra-info t)
      [(~constructor-extra-info _ _ get)
       (define f (syntax-local-value #'get))
       (syntax->list (f #`(get #,t)))]))

  (define (make-cons-type t args)
    (syntax-parse (get-extra-info t)
      [(~constructor-extra-info _ mk _)
       (define f (syntax-local-value #'mk))
        (type-eval (f #`(mk #,@args)))]))

  (define (ctor-id? stx)
    (and (identifier? stx)
         (user-ctor? (syntax-local-value stx (const #f)))))

  (define (untyped-ctor stx)
    (user-ctor-untyped-ctor (syntax-local-value stx (const #f)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Conveniences
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Syntax
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(begin-for-syntax

  ;; constructors with arity one
  (define-syntax-class kons1
    (pattern (~or (~datum observe)
                  (~datum inbound)
                  (~datum outbound))))

  (define (kons1->constructor stx)
    (syntax-parse stx
      #:datum-literals (observe inbound outbound)
      [observe #'syndicate:observe]
      [inbound #'syndicate:inbound]
      [outbound #'syndicate:outbound]))

  (define-syntax-class basic-val
    (pattern (~or boolean
                  integer
                  string)))

  (define-syntax-class prim-op
    (pattern (~or (~literal +)
                  (~literal -)
                  (~literal displayln)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Utilities Over Types
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-for-syntax (bot? t)
  (<: t (type-eval #'(U*))))

(define-for-syntax (flat-type? τ)
  (syntax-parse τ
    [(~→ τ ...) #f]
    [(~Actor τ) #f]
    [_ #t]))

(define-for-syntax (strip-? t)
  (type-eval
   (syntax-parse t
     [(~U* τ ...) #`(U #,@(stx-map strip-? #'(τ ...)))]
     [~★/t #'★/t]
     [(~Observe τ) #'τ]
     [_ #'(U*)])))

(define-for-syntax (strip-inbound t)
  (type-eval
   (syntax-parse t
     [(~U* τ ...) #`(U #,@(stx-map strip-? #'(τ ...)))]
     [~★/t #'★/t]
     [(~Inbound τ) #'τ]
     [_ #'(U*)])))

(define-for-syntax (strip-outbound t)
  (type-eval
   (syntax-parse t
     [(~U* τ ...) #`(U #,@(stx-map strip-? #'(τ ...)))]
     [~★/t #'★/t]
     [(~Outbound τ) #'τ]
     [_ #'(U*)])))

(define-for-syntax (relay-interests t)
  (type-eval
   (syntax-parse t
     ;; TODO: probably need to `normalize` the result
     [(~U* τ ...) #`(U #,@(stx-map strip-? #'(τ ...)))]
     [~★/t #'★/t]
     [(~Observe (~Inbound τ)) #'(Observe τ)]
     [_ #'(U*)])))

;; (SyntaxOf RoleType ...) -> (Syntaxof Type Type)
(define-for-syntax (analyze-roles rs)
  (define-values (lis los)
    (for/fold ([is '()]
               [os '()])
              ([r (in-syntax rs)])
      (define-values (i o) (analyze-role-input/output r))
      (values (cons i is) (cons o os))))
  #`(#,(type-eval #`(U #,@lis))
     #,(type-eval #`(U #,@los))))

;; Wanted test case, but can't use it bc it uses things defined for-syntax
#;(module+ test
 (let ([r (type-eval #'(Role (x) (Shares Int)))])
   (syntax-parse (analyze-role-input/output r)
     [(τ-i τ-o)
      (check-true (type=? #'τ-o (type-eval #'Int)))])))

;; RoleType -> (Values Type Type)
(define-for-syntax (analyze-role-input/output t)
  (syntax-parse t
    [(~Role (name:id)
       (~or (~Shares τ-s)
            (~Reacts τ-if τ-then ...)) ...
       (~and (~Role _ ...) sub-role) ...)
     (define-values (is os)
       (for/fold ([ins '()]
                  [outs '()])
                 ([t (in-syntax #'(τ-then ... ... sub-role ...))])
         (define-values (i o) (analyze-role-input/output t))
         (values (cons i ins) (cons o outs))))
     (define pat-types (stx-map event-desc-type #'(τ-if ...)))
     (values (type-eval #`(U #,@is #,@pat-types))
             (type-eval #`(U τ-s ... #,@os #,@(stx-map pattern-sub-type pat-types))))]))

;; EventDescriptorType -> Type
(define-for-syntax (event-desc-type desc)
  (syntax-parse desc
    [(~Know τ) #'τ]
    [(~¬Know τ) #'τ]
    [(~Message τ) desc]
    [_ (type-eval #'(U*))]))

;; PatternType -> Type
(define-for-syntax (pattern-sub-type pt)
  (define t (replace-bind-and-discard-with-★ pt))
  (type-eval #`(Observe #,t)))

(define-for-syntax (replace-bind-and-discard-with-★ t)
  (syntax-parse t
    [(~Bind _)
     (type-eval #'★/t)]
    [~Discard
     (type-eval #'★/t)]
    [(~U* τ ...)
     (type-eval #`(U #,@(stx-map replace-bind-and-discard-with-★ #'(τ ...))))]
    [(~Tuple τ ...)
     (type-eval #`(Tuple #,@(stx-map replace-bind-and-discard-with-★ #'(τ ...))))]
    [(~Observe τ)
     (type-eval #`(Observe #,(replace-bind-and-discard-with-★ #'τ)))]
    [(~Inbound τ)
     (type-eval #`(Inbound #,(replace-bind-and-discard-with-★ #'τ)))]
    [(~Outbound τ)
     (type-eval #`(Outbound #,(replace-bind-and-discard-with-★ #'τ)))]
    [(~constructor-type _ τ ...)
     (make-cons-type t (stx-map replace-bind-and-discard-with-★ #'(τ ...)))]
    [_ t]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Subtyping and Judgments on Types
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Type Type -> Bool
(define-for-syntax (<: t1 t2)
  (syntax-parse #`(#,t1 #,t2)
    [((~U* τ1 ...) _)
     (stx-andmap (lambda (t) (<: t t2)) #'(τ1 ...))]
    [(_ (~U* τ2:type ...))
     (stx-ormap (lambda (t) (<: t1 t)) #'(τ2 ...))]
    ;; TODO
    #;[((~Actor τ1:type) (~Actor τ2:type))
     ;; should these be .norm? Is the invariant that inputs are always fully
     ;; evalutated/expanded?
     (and (<: #'τ1 #'τ2)
          (<: (∩ (strip-? #'τ1) #'τ2) #'τ1))]
    [((~AssertionSet τ1) (~AssertionSet τ2))
     (<: #'τ1 #'τ2)]
    [((~Set τ1) (~Set τ2))
     (<: #'τ1 #'τ2)]
    [((~Patch τ11 τ12) (~Patch τ21 τ22))
     (and (<: #'τ11 #'τ21)
          (<: #'τ12 #'τ22))]
    [((~Tuple τ1:type ...) (~Tuple τ2:type ...))
     #:when (stx-length=? #'(τ1 ...) #'(τ2 ...))
     (stx-andmap <: #'(τ1 ...) #'(τ2 ...))]
    [(_ ~★/t)
     (flat-type? t1)]
    [((~Observe τ1:type) (~Observe τ2:type))
     (<: #'τ1 #'τ2)]
    [((~Inbound τ1:type) (~Inbound τ2:type))
     (<: #'τ1 #'τ2)]
    [((~Outbound τ1:type) (~Outbound τ2:type))
     (<: #'τ1 #'τ2)]
    [((~constructor-type t1 τ1:type ...) (~constructor-type t2 τ2:type ...))
     #:when (tags-equal? #'t1 #'t2)
     (and (stx-length=? #'(τ1 ...) #'(τ2 ...))
          (stx-andmap <: #'(τ1 ...) #'(τ2 ...)))]
    [((~→ τ-in1 ... τ-out1) (~→ τ-in2 ... τ-out2))
     #:when (stx-length=? #'(τ-in1 ...) #'(τ-in2 ...))
     (and (stx-andmap <: #'(τ-in2 ...) #'(τ-in1 ...))
          (<: #'τ-out1 #'τ-out2))]
    [(~Discard _)
     #t]
    ;; TODO: clauses for Roles, and so on
    ;; should probably put this first.
    [_ (type=? t1 t2)]))

;; Flat-Type Flat-Type -> Type
(define-for-syntax (∩ t1 t2)
  (unless (and (flat-type? t1) (flat-type? t2))
    (error '∩ "expected two flat-types"))
  (syntax-parse #`(#,t1 #,t2)
    [(_ ~★/t)
     t1]
    [(~★/t _)
     t2]
    [(_ _)
     #:when (type=? t1 t2)
     t1]
    [((~U* τ1:type ...) _)
     (type-eval #`(U #,@(stx-map (lambda (t) (∩ t t2)) #'(τ1 ...))))]
    [(_ (~U* τ2:type ...))
     (type-eval #`(U #,@(stx-map (lambda (t) (∩ t1 t)) #'(τ2 ...))))]
    [((~AssertionSet τ1) (~AssertionSet τ2))
     #:with τ12 (∩ #'τ1 #'τ2)
     (type-eval #'(AssertionSet τ12))]
    [((~Set τ1) (~Set τ2))
     #:with τ12 (∩ #'τ1 #'τ2)
     (type-eval #'(Set τ12))]
    [((~Patch τ11 τ12) (~Patch τ21 τ22))
     #:with τ1 (∩ #'τ11 #'τ12)
     #:with τ2 (∩ #'τ21 #'τ22)
     (type-eval #'(Patch τ1 τ2))]
    ;; all of these fail-when/unless clauses are meant to cause this through to
    ;; the last case and result in ⊥.
    ;; Also, using <: is OK, even though <: refers to ∩, because <:'s use of ∩ is only
    ;; in the Actor case.
    [((~Tuple τ1:type ...) (~Tuple τ2:type ...))
     #:fail-unless (stx-length=? #'(τ1 ...) #'(τ2 ...)) #f
     #:with (τ ...) (stx-map ∩ #'(τ1 ...) #'(τ2 ...))
     ;; I don't think stx-ormap is part of the documented api of turnstile *shrug*
     #:fail-when (stx-ormap (lambda (t) (<: t (type-eval #'(U)))) #'(τ ...)) #f
     (type-eval #'(Tuple τ ...))]
    [((~constructor-type tag1 τ1:type ...) (~constructor-type tag2 τ2:type ...))
     #:when (tags-equal? #'tag1 #'tag2)
     #:with (τ ...) (stx-map ∩ #'(τ1 ...) #'(τ2 ...))
     #:fail-when (stx-ormap (lambda (t) (<: t (type-eval #'(U)))) #'(τ ...)) #f
     (make-cons-type t1 #'(τ ...))]
    ;; these three are just the same :(
    [((~Observe τ1:type) (~Observe τ2:type))
     #:with τ (∩ #'τ1 #'τ2)
     #:fail-when (<: #'τ (type-eval #'(U))) #f
     (type-eval #'(Observe τ))]
    [((~Inbound τ1:type) (~Inbound τ2:type))
     #:with τ (∩ #'τ1 #'τ2)
     #:fail-when (<: #'τ (type-eval #'(U))) #f
     (type-eval #'(Inbound τ))]
    [((~Outbound τ1:type) (~Outbound τ2:type))
     #:with τ (∩ #'τ1 #'τ2)
     #:fail-when (<: #'τ (type-eval #'(U))) #f
     (type-eval #'(Outbound τ))]
    [_ (type-eval #'(U))]))

;; Type Type -> Bool
;; first type is the contents of the set
;; second type is the type of a pattern
(define-for-syntax (project-safe? t1 t2)
  (syntax-parse #`(#,t1 #,t2)
    [(_ (~Bind τ2:type))
     (and (finite? t1) (<: t1 #'τ2))]
    [(_ ~Discard)
     #t]
    [(_ ~★/t)
     #t]
    [((~U* τ1:type ...) _)
     (stx-andmap (lambda (t) (project-safe? t t2)) #'(τ1 ...))]
    [(_ (~U* τ2:type ...))
     (stx-andmap (lambda (t) (project-safe? t1 t)) #'(τ2 ...))]
    [((~Tuple τ1:type ...) (~Tuple τ2:type ...))
     #:when (overlap? t1 t2)
     (stx-andmap project-safe? #'(τ1 ...) #'(τ2 ...))]
    [((~constructor-type _ τ1:type ...) (~constructor-type _ τ2:type ...))
     #:when (overlap? t1 t2)
     (stx-andmap project-safe? #'(τ1 ...) #'(τ2 ...))]
    [((~Observe τ1:type) (~Observe τ2:type))
     (project-safe? #'τ1 #'τ2)]
    [((~Inbound τ1:type) (~Inbound τ2:type))
     (project-safe? #'τ1 #'τ2)]
    [((~Outbound τ1:type) (~Outbound τ2:type))
     (project-safe? #'τ1 #'τ2)]
    [_ #t]))

;; AssertionType PatternType -> Bool
;; Is it possible for things of these two types to match each other?
;; Flattish-Type = Flat-Types + ★/t, Bind, Discard (assertion and pattern types)
(define-for-syntax (overlap? t1 t2)
  (syntax-parse #`(#,t1 #,t2)
    [(~★/t _) #t]
    [(_ (~Bind _)) #t]
    [(_ ~Discard) #t]
    [(_ ~★/t) #t]
    [((~U* τ1:type ...) _)
     (stx-ormap (lambda (t) (overlap? t t2)) #'(τ1 ...))]
    [(_ (~U* τ2:type ...))
     (stx-ormap (lambda (t) (overlap? t1 t)) #'(τ2 ...))]
    [((~List _) (~List _))
     ;; share the empty list
     #t]
    [((~Tuple τ1:type ...) (~Tuple τ2:type ...))
     (and (stx-length=? #'(τ1 ...) #'(τ2 ...))
          (stx-andmap overlap? #'(τ1 ...) #'(τ2 ...)))]
    [((~constructor-type t1 τ1:type ...) (~constructor-type t2 τ2:type ...))
     (and (tags-equal? #'t1 #'t2)
          (stx-andmap overlap? #'(τ1 ...) #'(τ2 ...)))]
    [((~Observe τ1:type) (~Observe τ2:type))
     (overlap? #'τ1 #'τ2)]
    [((~Inbound τ1:type) (~Inbound τ2:type))
     (overlap? #'τ1 #'τ2)]
    [((~Outbound τ1:type) (~Outbound τ2:type))
     (overlap? #'τ1 #'τ2)]
    [_ (<: t1 t2)]))

;; Flattish-Type -> Bool
(define-for-syntax (finite? t)
  (syntax-parse t
    [~★/t #f]
    [(~U* τ:type ...)
     (stx-andmap finite? #'(τ ...))]
    [(~Tuple τ:type ...)
     (stx-andmap finite? #'(τ ...))]
    [(~constructor-type _ τ:type ...)
     (stx-andmap finite? #'(τ ...))]
    [(~Observe τ:type)
     (finite? #'τ)]
    [(~Inbound τ:type)
     (finite? #'τ)]
    [(~Outbound τ:type)
     (finite? #'τ)]
    [(~Set τ:type)
     (finite? #'τ)]
    [_ #t]))

;; !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
;; MODIFYING GLOBAL TYPECHECKING STATE!!!!!
;; !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

(begin-for-syntax
  (current-typecheck-relation <:))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Effect Checking

;; DesugaredSyntax EffectName -> Bool
(define-for-syntax (effect-free? e- eff)
  (define prop (syntax-property e- eff))
  (or (false? prop) (stx-null? prop)))

;; DesugaredSyntax -> Bool
(define-for-syntax (pure? e-)
  (for/and ([key (in-list '(a r f s))])
    (effect-free? e- key)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Core forms

(define-typed-syntax (start-facet name:id ((~datum fields) [x:id τ-f:type e:expr] ...) ep ...+) ≫
  #:fail-unless (stx-andmap flat-type? #'(τ-f ...)) "keep your uppity data outta my fields"
  ;; TODO - probably don't want these expressions to have any effects
  [⊢ e ≫ e- (⇐ : τ-f)] ...
  [[name ≫ name- : FacetName] [x ≫ x- : (Field τ-f.norm)] ...
   ⊢ [ep ≫ ep- (⇒ r (~effs τ-r ...))
                (⇒ a (~effs τ-a ...))
                (⇒ f (~effs))
                (⇒ s (~effs))] ...]
  #:with τ (type-eval #'(Role (name-)
                          τ-a ... ...
                          τ-r ... ...))
  --------------------------------------------------------------
  [⊢ (syndicate:react (let- ([name- (syndicate:current-facet-id)])
                            #,(make-fields #'(x- ...) #'(e- ...))
                            ep- ...))
     (⇒ : ★/t)
     (⇒ r ())
     (⇒ a ())
     (⇒ s ())
     (⇒ f (τ))])

(define-for-syntax (make-fields names inits)
  (syntax-parse #`(#,names #,inits)
    [((x:id ...) (e ...))
     #'(syndicate:field [x e] ...)]))

(define-typed-syntax (assert e:expr) ≫
  [⊢ e ≫ e- (⇒ : τ)]
  #:fail-unless (pure? #'e-) "expression not allowed to have effects"
  -------------------------------------
  [⊢ (syndicate:assert e-) (⇒ : ★/t)
                           (⇒ a ((Shares τ)))
                           (⇒ r ())
                           (⇒ f ())
                           (⇒ s ())])

(begin-for-syntax
  (define-syntax-class asserted-or-retracted
    #:datum-literals (asserted retracted)
    (pattern (~or (~and asserted
                        (~bind [syndicate-kw #'syndicate:asserted]
                               [react-con #'Know]))
                  (~and retracted
                        (~bind [syndicate-kw #'syndicate:retracted]
                               [react-con #'¬Know]))))))

(define-typed-syntax on
  ;; TODO - on start/stop
  #;[(on (~literal start) s) ≫
   [⊢ s ≫ s- (⇒ :i τi) (⇒ :o τ-o) (⇒ :a τ-a)]
   -----------------------------------
   [⊢ (syndicate:on-start s-) (⇒ : (U)) (⇒ :i τi) (⇒ :o τ-o) (⇒ :a τ-a)]]
  #;[(on (~literal stop) s) ≫
   [⊢ s ≫ s- (⇒ :i τi) (⇒ :o τ-o) (⇒ :a τ-a)]
   -----------------------------------
   [⊢ (syndicate:on-stop s-) (⇒ : (U)) (⇒ :i τi) (⇒ :o τ-o) (⇒ :a τ-a)]]
  [(on (a/r:asserted-or-retracted p) s) ≫
   [⊢ p ≫ p-- (⇒ : τp)]
   #:fail-unless (pure? #'p--) "pattern not allowed to have effects"
   #:with p- (compile-syndicate-pattern #'p)
   #:with ([x:id τ:type] ...) (pat-bindings #'p)
   [[x ≫ x- : τ] ... ⊢ s ≫ s- (⇒ a (~effs))
                               (⇒ r (~effs))
                               (⇒ f (~effs τ-f ...))
                               (⇒ s (~effs τ-s ...))]
   #:with τ-r #'(Reacts (a/r.react-con τp) τ-f ...)
   -----------------------------------
   [⊢ (syndicate:on (a/r.syndicate-kw p-)
                    (let- ([x- x] ...) s-))
      (⇒ : ★/t)
      (⇒ r (τ-r))
      (⇒ f ())
      (⇒ a ())
      (⇒ s ())]])

;; pat -> ([Id Type] ...)
(define-for-syntax (pat-bindings stx)
  (syntax-parse stx
    #:datum-literals (bind tuple)
    [(bind x:id τ:type)
     #'([x τ])]
    [(tuple p ...)
     #:with (([x:id τ:type] ...) ...) (stx-map pat-bindings #'(p ...))
     #'([x τ] ... ...)]
    [(k:kons1 p)
     (pat-bindings #'p)]
    [(~constructor-exp cons p ...)
     #:with (([x:id τ:type] ...) ...) (stx-map pat-bindings #'(p ...))
     #'([x τ] ... ...)]
    [_
     #'()]))

(define-for-syntax (compile-pattern pat bind-id-transformer exp-transformer)
  (let loop ([pat pat])
    (syntax-parse pat
      #:datum-literals (tuple discard bind)
      [(tuple p ...)
       #`(list 'tuple #,@(stx-map loop #'(p ...)))]
      [(k:kons1 p)
       #`(#,(kons1->constructor #'k) #,(loop #'p))]
      [(bind x:id τ:type)
       (bind-id-transformer #'x)]
      [discard
       #'_]
      [(~constructor-exp ctor p ...)
       (define/with-syntax uctor (untyped-ctor #'ctor))
       #`(uctor #,@(stx-map loop #'(p ...)))]
      [_
       (exp-transformer pat)])))

(define-for-syntax (compile-syndicate-pattern pat)
  (compile-pattern pat
                   (lambda (id) #`($ #,id))
                   identity))

(define-typed-syntax (spawn τ-c:type s) ≫
  #:fail-unless (flat-type? #'τ-c.norm) "Communication type must be first-order"
  [⊢ s ≫ s- (⇒ a (~effs)) (⇒ r (~effs)) (⇒ s (~effs)) (⇒ f (~effs τ-f ...))]
  ;; TODO: s shouldn't refer to facets or fields!
  #:with (τ-i τ-o) (analyze-roles #'(τ-f ...))
  #:fail-unless (<: #'τ-o #'τ-c.norm)
                (format "Output ~a not valid in dataspace ~a" (type->str #'τ-o) (type->str #'τ-c.norm))
  ;; TODO - type of spawned actors
  ;; #:fail-unless (<: (type-eval #'(Actor τ-a.norm))
  ;;                  (type-eval #'(Actor τ-c.norm))) "Spawned actors not valid in dataspace"
  #:fail-unless (project-safe? (∩ (strip-? #'τ-o) #'τ-c.norm)
                               #'τ-i)
                "Not prepared to handle all inputs"
  --------------------------------------------------------------------------------------------
  [⊢ (syndicate:spawn (syndicate:on-start s-)) (⇒ : ★/t)
                                               (⇒ s ((Actor τ-c)))
                                               (⇒ a ())
                                               (⇒ r ())
                                               (⇒ f ())])

(define-typed-syntax (set! x:id e:expr) ≫
  [⊢ e ≫ e- (⇒ : τ)]
  #:fail-unless (pure? #'e-) "expression not allowed to have effects"
  [⊢ x ≫ x- (⇒ : (~Field τ-x:type))]
  #:fail-unless (<: #'τ #'τ-x) "Ill-typed field write"
  ----------------------------------------------------
  [⊢ (x- e-) (⇒ : ★/t)])

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Expressions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-typed-syntax (ref x:id) ≫
  [⊢ x ≫ x- ⇒ (~Field τ)]
  ------------------------
  [⊢ (x-) (⇒ : τ)])

(define-typed-syntax (typed-app e_fn e_arg ...) ≫
  ;; TODO : other keys
  [⊢ e_fn ≫ e_fn- (⇒ : (~→ τ_in ... τ_out))]
  #:fail-unless (pure? #'e_fn-) "expression not allowed to have effects"
  #:fail-unless (stx-length=? #'[τ_in ...] #'[e_arg ...])
                (num-args-fail-msg #'e_fn #'[τ_in ...] #'[e_arg ...])
  [⊢ e_arg ≫ e_arg- (⇐ : τ_in)] ...
  #:fail-unless (stx-andmap pure? #'(e_arg- ...)) "expressions not allowed to have effects"
  ------------------------------------------------------------------------
  [⊢ (#%app- e_fn- e_arg- ...) (⇒ : τ_out)])

(define-typed-syntax (tuple e:expr ...) ≫
  [⊢ e ≫ e- (⇒ : τ)] ...
  #:fail-unless (stx-andmap pure? #'(e- ...)) "expressions not allowed to have effects"
  -----------------------
  [⊢ (list- 'tuple e- ...) (⇒ : (Tuple τ ...))])

(define-typed-syntax (select n:nat e:expr) ≫
  [⊢ e ≫ e- (⇒ : (~Tuple τ ...))]
  #:fail-unless (pure? #'e-) "expression not allowed to have effects"
  #:do [(define i (syntax->datum #'n))]
  #:fail-unless (< i (stx-length #'(τ ...))) "index out of range"
  #:with τr (list-ref (stx->list #'(τ ...)) i)
  --------------------------------------------------------------
  [⊢ (tuple-select n e-) (⇒ : τr)])

(define- (tuple-select n t)
  (list-ref- t (add1 n)))

;; it would be nice to abstract over these three
(define-typed-syntax (observe e:expr) ≫
  [⊢ e ≫ e- (⇒ : τ)]
  #:fail-unless (pure? #'e-) "expression not allowed to have effects"
  ---------------------------------------------------------------------------
  [⊢ (syndicate:observe e-) (⇒ : (Observe τ))])

(define-typed-syntax (inbound e:expr) ≫
  [⊢ e ≫ e- (⇒ : τ)]
  #:fail-unless (pure? #'e-) "expression not allowed to have effects"
  ---------------------------------------------------------------------------
  [⊢ (syndicate:inbound e-) (⇒ : (Inbound τ))])

(define-typed-syntax (outbound e:expr) ≫
  [⊢ e ≫ e- (⇒ : τ)]
  #:fail-unless (pure? #'e-) "expression not allowed to have effects"
  ---------------------------------------------------------------------------
  [⊢ (syndicate:outbound e-) (⇒ : (Outbound τ))])

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Patterns
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-typed-syntax (bind x:id τ:type) ≫
  ----------------------------------------
  [⊢ (error- 'bind "escaped") (⇒ : (Bind τ))])

(define-typed-syntax discard
  [_ ≫
   --------------------
   ;; TODO: change void to _
   [⊢ (error- 'discard "escaped") (⇒ : Discard)]])

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Core-ish forms
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Primitives
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; hmmm
(define-primop + (→ Int Int Int))
(define-primop - (→ Int Int Int))
(define-primop * (→ Int Int Int))
#;(define-primop and (→ Bool Bool Bool))
(define-primop or (→ Bool Bool Bool))
(define-primop not (→ Bool Bool))
(define-primop < (→ Int Int Bool))
(define-primop > (→ Int Int Bool))
(define-primop <= (→ Int Int Bool))
(define-primop >= (→ Int Int Bool))
(define-primop = (→ Int Int Bool))

(define-typed-syntax (/ e1 e2) ≫
  [⊢ e1 ≫ e1- (⇐ : Int)]
  [⊢ e2 ≫ e2- (⇐ : Int)]
  #:fail-unless (pure? #'e1-) "expression not allowed to have effects"
  #:fail-unless (pure? #'e2-) "expression not allowed to have effects"
  ------------------------
  [⊢ (exact-truncate- (/- e1- e2-)) (⇒ : Int)])

;; for some reason defining `and` as a prim op doesn't work
(define-typed-syntax (and e ...) ≫
  [⊢ e ≫ e- (⇐ : Bool)] ...
  #:fail-unless (stx-andmap pure? #'(e- ...)) "expressions not allowed to have effects"
  ------------------------
  [⊢ (and- e- ...) (⇒ : Bool)])

(define-typed-syntax (equal? e1:expr e2:expr) ≫
  [⊢ e1 ≫ e1- (⇒ : τ1)]
  #:fail-unless (flat-type? #'τ1)
  (format "equality only available on flat data; got ~a" (type->str #'τ1))
  [⊢ e2 ≫ e2- (⇐ : τ1)]
  #:fail-unless (pure? #'e1-) "expression not allowed to have effects"
  #:fail-unless (pure? #'e2-) "expression not allowed to have effects"
  ---------------------------------------------------------------------------
  [⊢ (equal?- e1- e2-) (⇒ : Bool)])

(define-typed-syntax (empty? e) ≫
  [⊢ e ≫ e- (⇒ : (~List _))]
  #:fail-unless (pure? #'e-) "expression not allowed to have effects"
  -----------------------
  [⊢ (empty?- e-) (⇒ : Bool)])

(define-typed-syntax (first e) ≫
  [⊢ e ≫ e- (⇒ : (~List τ))]
  #:fail-unless (pure? #'e-) "expression not allowed to have effects"
  -----------------------
  [⊢ (first- e-) (⇒ : τ)])

(define-typed-syntax (rest e) ≫
  [⊢ e ≫ e- (⇒ : (~List τ))]
  #:fail-unless (pure? #'e-) "expression not allowed to have effects"
  -----------------------
  [⊢ (rest- e-) (⇒ : (List τ))])

(define-typed-syntax (member? e l) ≫
  [⊢ e ≫ e- (⇒ : τe:type)]
  [⊢ l ≫ l- (⇒ : (~List τl:type))]
  #:fail-unless (<: #'τe.norm #'τl.norm) "incompatible list"
  #:fail-unless (pure? #'e-) "expression not allowed to have effects"
  #:fail-unless (pure? #'l-) "expression not allowed to have effects"
  ----------------------------------------
  [⊢ (member?- e- l-) (⇒ : Bool)])

(define- (member?- v l)
  (and- (member- v l) #t))

(define-typed-syntax (displayln e:expr) ≫
  [⊢ e ≫ e- (⇒ : τ)]
  #:fail-unless (pure? #'e-) "expression not allowed to have effects"
  ---------------
  [⊢ (displayln- e-) (⇒ : ★/t)])

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Basic Values
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-typed-syntax #%datum
  [(_ . n:integer) ≫
  ----------------
  [⊢ (#%datum- . n) (⇒ : Int)]]
  [(_ . b:boolean) ≫
  ----------------
  [⊢ (#%datum- . b) (⇒ : Bool)]]
  [(_ . s:string) ≫
  ----------------
  [⊢ (#%datum- . s) (⇒ : String)]])

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Utilities
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-typed-syntax (print-type e) ≫
  [⊢ e ≫ e- (⇒ : τ) (⇒ a as) (⇒ r rs) (⇒ f es)]
  #:do [(displayln (type->str #'τ))]
  ----------------------------------
  [⊢ e- (⇒ : τ) (⇒ a as) (⇒ r rs) (⇒ f es)])

(define-typed-syntax (print-role e) ≫
  [⊢ e ≫ e- (⇒ : τ) (⇒ a as) (⇒ r rs) (⇒ f es)]
  #:do [(for ([r (in-syntax #'es)])
          (displayln (type->str r)))]
  ----------------------------------
  [⊢ e- (⇒ : τ) (⇒ a as) (⇒ r rs) (⇒ f es)])

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Tests
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;