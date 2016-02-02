#lang racket/base

(provide actor
         network
         ;; background
         state

         until
         forever

         assert!
         retract!
         send!
         return!
         return/no-link-result!
         perform-core-action!

         ;; forall

         actor-body->spawn-action

         ;;----------------------------------------
         (struct-out actor-state)
         pretty-print-actor-state

         (for-syntax analyze-pattern)
         )

(require (for-syntax racket/base))
(require (for-syntax racket/sequence))
(require "support/dsl.rkt")
(require "pretty.rkt")

(define&provide-dsl-helper-syntaxes "state/until/forever form"
  [on
   assert
   track

   asserted
   retracted
   message
   rising-edge

   exists
   ])

(require (for-syntax racket/match))
(require (for-syntax racket/list))
(require (for-syntax syntax/parse))
(require (for-syntax syntax/stx))

(require racket/set)
(require racket/match)

(require (except-in "core.rkt" assert network)
         (rename-in "core.rkt" [assert core:assert] [network core:network]))
(require "route.rkt")
(require "mux.rkt")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Actor State

;; A Variables is a (Vectorof Any), storing the explicit state
;; variables of an actor.

;; An Aggregates is a (Hashtable Nat Any), storing implicit state of
;; an actor, including tracked and implicit aggregates.

;; A Script is a (-> Variables). It is to be executed inside
;; the special syndicate-hll prompt, and so may have Instruction
;; side-effects.

;; An Instruction is one of
;; - (patch-instruction Patch (Void -> Instruction))
;; - (action-instruction Action (Void -> Instruction))
;; - (return-instruction (Option (Listof Any)))
;; - (spawn-instruction LinkageKind (Symbol Symbol -> Spawn) (Void -> Instruction))
;; - (script-complete-instruction Variables)
;; and represents a side-effect for an actor to take in its
;; interactions with the outside world.
;;
;; A LinkageKind is one of
;; - 'call, a blocking, exception-linked connection
;; - 'actor, a non-blocking, non-exception-linked connection
;; - 'network, a non-blocking, nested, non-exception-linked connection
;;
;; Patch Instructions are issued when the actor uses `assert!` and
;; `retract!`. Action instructions are issued when the actor uses
;; `perform-core-action!`, and return instructions when `return!` is
;; called. Script-complete instructions are automatically issued when
;; a Script terminates successfully.
;;
;; Spawn instructions are issued when `actor`, `network`, and `state`
;; are used, directly or indirectly. (TODO: `background`?) The
;; spawn-action-producing function is given the IDs of the spawned and
;; spawning actors, and is to return an action which spawns the new
;; actor, which in turn engages in the appropriate linkage protocol
;; with the spawning actor. The (Void -> Instruction) continuation is
;; released when the spawned actor terminates (for blocking variants)
;; or immediately following the spawn (for non-blocking variants).
;;
;; (Background is done differently, with a new continuation for the
;; background script, and a self-send to activate it. (TODO))
;;
(struct patch-instruction (patch k) #:transparent)
(struct action-instruction (action k) #:transparent)
(struct return-instruction (result-values) #:transparent)
(struct spawn-instruction (linkage-kind action-fn k) #:transparent)
(struct script-complete-instruction (variables) #:transparent)

;; An ActorState is an (actor-state ... as below), describing the
;; state of an HLL actor.
;;
(struct actor-state (continuation-table ;; (Hashtable Symbol (Variables Any ... -> Instruction))
                     caller-id          ;; Symbol
                     self-id            ;; Symbol
                     variables          ;; Variables
                     aggregates         ;; Aggregates
                     pending-patch      ;; (Option Patch) - aggregate patch being accumulated
                     mux                ;; Mux
                     )
  #:transparent
  #:methods gen:prospect-pretty-printable
  [(define (prospect-pretty-print s [p (current-output-port)])
     (pretty-print-actor-state s p))])

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Linkage protocol
;;
;; Linkages are used to both propagate values from callee to caller
;; and to monitor callee presence for exception-propagation.
;;   - assertion: LinkActive
;;   - message: LinkResult
;;   - role: Caller
;;       Monitors LinkActive to detect termination of the Callee,
;;       normal or abnormal. If LinkResult is received before
;;       LinkActive vanishes, termination was normal; otherwise, it
;;       was abnormal.
;;   - role: Callee
;;       Asserts LinkActive while it runs. Should send LinkResult
;;       before termination to indicate success and communicate values
;;       to Caller.
;;
;; A LinkActive is a (link-active Symbol Symbol), describing an
;; ongoing relationship between the indicated caller and callee.
(struct link-active (caller-id callee-id) #:prefab)
;;
;; A LinkResult is a (link-result Symbol Symbol (Listof Any)),
;; describing the final values yielded by a callee to its caller.
(struct link-result (caller-id callee-id values) #:prefab) ;; message

;; Projection for observing LinkActive.
(define link-active-projection (compile-projection (link-active ? (?!))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Producing Instruction side-effects

(define prompt (make-continuation-prompt-tag 'syndicate-hll))

;; (Any ... -> Nothing) -> (Any ... -> Instruction)
(define (reply-to k)
  (lambda reply-values
    (call-with-continuation-prompt (lambda ()
                                     (apply k reply-values)
                                     (error 'reply-to "Script returned directly"))
                                   prompt)))

;; (-> Instruction) -> Nothing
(define (call-in-raw-context/abort proc)
  (abort-current-continuation prompt proc))

;; ((Any ... -> Instruction) -> Instruction)
(define (call-in-raw-context proc)
  (call-with-composable-continuation
   (lambda (k) (abort-current-continuation prompt (lambda () (proc (reply-to k)))))
   prompt))

;; Returns void
(define (assert! P #:meta-level [meta-level 0])
  (call-in-raw-context
   (lambda (k) (patch-instruction (core:assert P #:meta-level meta-level) k))))

;; Returns void
(define (retract! P #:meta-level [meta-level 0])
  (call-in-raw-context
   (lambda (k) (patch-instruction (retract P #:meta-level meta-level) k))))

;; Returns void
(define (send! M #:meta-level [meta-level 0])
  (perform-core-action! (message (prepend-at-meta M meta-level))))

;; Returns void
(define (perform-core-action! A)
  (call-in-raw-context
   (lambda (k) (action-instruction A k))))

;; Does not return to caller; instead, terminates the current actor
;; after sending a link-result to the calling actor.
(define (return! . result-values)
  (call-in-raw-context/abort
   (lambda () (return-instruction result-values))))

;; Does not return to caller; instead, terminates the current actor
;; without sending a link-result to the calling actor.
(define (return/no-link-result!)
  (call-in-raw-context/abort
   (lambda () (return-instruction #f))))

;; Returns new variables, plus values from spawned actor if any.
(define (spawn! linkage-kind action-fn)
  (call-in-raw-context
   (lambda (k) (spawn-instruction linkage-kind action-fn k))))

(begin-for-syntax
  (define-splicing-syntax-class init
    (pattern (~seq #:init [I ...]))
    (pattern (~seq) #:attr [I 1] '()))

  (define-splicing-syntax-class bindings
    (pattern (~seq #:collect [(id init) ...]))
    (pattern (~seq) #:attr [id 1] '() #:attr [init 1] '())))

;; Syntax for spawning a 'call-linked actor.
(define-syntax (state stx)
  (syntax-parse stx
    [(_ init:init [bs:bindings O ...] [E Oe ...] ...)
     (expand-state 'call #'(init.I ...) #'(bs.id ...) #'(bs.init ...) #'(O ...) #'([E Oe ...] ...))]))

;; Sugar
(define-syntax (until stx)
  (syntax-parse stx
    [(_ E init:init bs:bindings O ...)
     #'(state #:init [init.I ...] [#:collect [(bs.id bs.init) ...] O ...] [E (values)])]))

;; Sugar
(define-syntax (forever stx)
  (syntax-parse stx
    [(_ init:init bs:bindings O ...)
     #'(state #:init [init.I ...] [#:collect [(bs.id bs.init) ...] O ...])]))

;; Spawn actors with 'actor linkage
(define-syntax (actor stx)
  (syntax-parse stx
    [(_ I ...)
     (expand-state 'actor #'(I ... (return/no-link-result!)) #'() #'() #'() #'())]))

;; Spawn whole networks
(define-syntax (network stx)
  (syntax-parse stx
    [(_ I ...)
     (expand-state 'network
                   #'(I
                      ...
                      (perform-core-action! (quit-network))
                      (return/no-link-result!))
                   #'()
                   #'()
                   #'()
                   #'())]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Main behavior of HLL actors

;; Special mux label used to track ad-hoc assertions
;; TODO: Revisit this, it is a bit ugly
(define *adhoc-label* -1)

;; Special mux label used to track linkage between actors.
;; TODO: Revisit this, it is a bit ugly
(define *linkage-label* -2)

;; Behavior
(define (generic-actor-behavior e s)
  (match e
    [(? patch/removed? p)
     (define continuation-table (actor-state-continuation-table s))
     (define quit?
       (for/or [(callee-id (trie-project/set/single (patch-removed p) link-active-projection))]
         (hash-has-key? continuation-table callee-id)))
     (if quit? ;; TODO: raise exception instead? Signal the cause of the quit somehow?
         (quit)
         #f)]
    [(message (link-result _ callee-id reply-values))
     (invoke-stored-continuation s callee-id reply-values)]
    [_ #f]))

;; ActorState Symbol (Variables Any ... -> Instruction) -> ActorState
(define (store-continuation s callee-id get-next-instr)
  (struct-copy actor-state s
               [continuation-table
                (hash-set (actor-state-continuation-table s)
                          callee-id
                          get-next-instr)]))

;; ActorState Symbol (Listof Any) -> Transition
(define (invoke-stored-continuation s callee-id reply-values)
  (define continuation-table (actor-state-continuation-table s))
  (define continuation (hash-ref continuation-table callee-id #f))
  (define new-table (hash-remove continuation-table callee-id))
  ;; (log-info "invoke-stored-continuation self=~a callee=~a values=~v k=~v"
  ;;           (actor-state-self-id s)
  ;;           callee-id
  ;;           reply-values
  ;;           continuation)
  (handle-actor-syscall (transition (struct-copy actor-state s [continuation-table new-table])
                                    '())
                        (apply continuation
                               (append reply-values (vector->list (actor-state-variables s))))))

;; ActorState -> Transition
(define (perform-pending-patch s)
  (transition (struct-copy actor-state s [pending-patch #f]) (actor-state-pending-patch s)))

;; Label Patch -> ActorState -> Transition
(define ((extend-pending-patch label p) s)
  (define-values (new-mux _label _p p-aggregate)
    (mux-update-stream (actor-state-mux s) label p))
  (define p0 (actor-state-pending-patch s))
  (define new-pending-patch (if p0 (patch-seq p0 p-aggregate) p-aggregate))
  (transition (struct-copy actor-state s
                           [pending-patch new-pending-patch]
                           [mux new-mux])
              '()))

;; ActorState Script -> Transition
(define (run-script s script)
  (handle-actor-syscall (transition s '())
                        ((reply-to (lambda (dummy)
                                     (define new-variables (script))
                                     (call-in-raw-context/abort
                                      (lambda ()
                                        (script-complete-instruction new-variables)))))
                         (void))))

(define (actor-body->spawn-action thunk)
  (match ((reply-to (lambda (dummy)
                      (actor (thunk))
                      (error '%%boot "Reached end of boot thunk")))
          (void))
    [(spawn-instruction 'actor action-fn _get-next-instr)
     (action-fn (gensym 'root-actor) (gensym 'boot-actor))]))

;; Transition Instruction -> Transition
(define (handle-actor-syscall t instr)
  (match instr
    [(patch-instruction p get-next-instr)
     (handle-actor-syscall (sequence-transitions t
                                                 (extend-pending-patch *adhoc-label* p))
                           (get-next-instr (void)))]
    [(action-instruction a get-next-instr)
     (handle-actor-syscall (sequence-transitions t
                                                 perform-pending-patch
                                                 (lambda (s) (transition s a)))
                           (get-next-instr (void)))]
    [(return-instruction result-values)
     (sequence-transitions t
                           perform-pending-patch
                           (lambda (s)
                             (if result-values
                                 (quit (message (link-result (actor-state-caller-id s)
                                                             (actor-state-self-id s)
                                                             result-values)))
                                 (quit))))]
    [(spawn-instruction linkage-kind action-fn get-next-instr)
     (define blocking? (eq? linkage-kind 'call))
     (define next-t
       (sequence-transitions t
                             perform-pending-patch
                             (lambda (s)
                               (define callee-id (gensym linkage-kind))
                               (define spawn-action (action-fn callee-id (actor-state-self-id s)))
                               (transition (if blocking?
                                               (store-continuation s callee-id get-next-instr)
                                               s)
                                           (if (eq? linkage-kind 'network)
                                               (spawn-network spawn-action)
                                               spawn-action)))))
     (if blocking?
         next-t
         (handle-actor-syscall next-t (get-next-instr (void))))]
    [(script-complete-instruction new-variables)
     (sequence-transitions t
                           ;; NB: Does not perform-pending-patch here.
                           ;; Instead, the script runner will now
                           ;; update ongoing subscriptions and
                           ;; incorporate the pending patch into that
                           ;; process.
                           (lambda (s)
                             (transition (struct-copy actor-state s [variables new-variables])
                                         '())))]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Compilation of HLL actors

;; TODO: track
;; TODO: default to hll
;; TODO: some better means of keeping track of nested network levels

(begin-for-syntax
  (define-splicing-syntax-class when-pred
    (pattern (~seq #:when Pred))
    (pattern (~seq) #:attr Pred #'#t))

  (define-splicing-syntax-class meta-level
    (pattern (~seq #:meta-level level))
    (pattern (~seq) #:attr level #'0))

  (define (expand-state linkage-kind init-actions binding-names binding-inits ongoings edges)
    ;; ----------------------------------------
    (define binding-count (length (syntax->list binding-names)))
    ;; ----------------------------------------
    ;; A StageProducer is a ((Syntax <Expr:Event>) -> (Syntax <Expr:(ActorState -> Transition)>)).
    ;; It computes a behavior stage suitable for composition using sequence-transitions.
    ;; It is given syntax for an expression yielding the actor's current event.

    ;; Records syntaxes for aggregate initializers.
    ;; (Boxof (Listof (Syntax <Expr:Any>)))
    (define aggregate-init-stxs (box '()))

    ;; Records aggregate updaters.
    ;; (Boxof (Listof StageProducer))
    (define track-updaters (box '()))

    ;; Records both actual event handlers and termination check handlers.
    ;; (Boxof (Listof StageProducer))
    (define event-handlers (box '()))

    ;; (Boxof (Listof StageProducer))
    (define assertion-maintainers (box '()))

    (define (box-adjoin! v val) (set-box! v (append (unbox v) (list val))))
    ;; ----------------------------------------

    (define (allocate-aggregate! init-stx)
      (box-adjoin! aggregate-init-stxs init-stx)
      (- (length (unbox aggregate-init-stxs)) 1))

    ;; StageProducer -> Void
    (define (add-track-updater! stage-producer) (box-adjoin! track-updaters stage-producer))
    (define (add-event-handler! stage-producer) (box-adjoin! event-handlers stage-producer))

    (define (mapply v fs) (map (lambda (f) (f v)) fs))

    (define (make-run-script-call outer-expr-stx state-stx I-stxs)
      (cond
        [(zero? binding-count)
         #`(run-script #,state-stx (lambda ()
                                     #,@I-stxs
                                     (vector)))]
        [(stx-null? I-stxs)
         (raise-syntax-error #f "Empty expression sequence not permitted" outer-expr-stx I-stxs)]
        [else
         #`(run-script #,state-stx (lambda ()
                                     (call-with-values (lambda () #,@I-stxs)
                                                       vector)))]))

    (define (add-assertion-maintainer! endpoint-index
                                       assert-stx
                                       pat-stx
                                       maybe-Pred-stx
                                       L-stx)
      (box-adjoin! assertion-maintainers
                   (lambda (evt-stx)
                     #`(lambda (s)
                         (match-define (vector #,@binding-names)
                           (actor-state-variables s))
                         (define old-assertions
                           (strip-interests
                            (mux-interests-of (actor-state-mux s) #,endpoint-index)))
                         (define (compute-new-assertions)
                           (patch-added (#,assert-stx #,pat-stx #:meta-level #,L-stx)))
                         (define new-assertions
                           #,(if maybe-Pred-stx
                                 #`(if #,maybe-Pred-stx
                                       (compute-new-assertions)
                                       (trie-empty))
                                 #`(compute-new-assertions)))
                         (and (not (eq? old-assertions new-assertions))
                              ((extend-pending-patch
                                #,endpoint-index
                                (patch-seq (patch (trie-empty) old-assertions)
                                           (patch new-assertions (trie-empty))))
                               s))))))

    (define (analyze-asserted-or-retracted! endpoint-index asserted? outer-expr-stx P-stx I-stxs L-stx)
      (define-values (proj-stx pat match-pat bindings) (analyze-pattern outer-expr-stx P-stx))
      (add-assertion-maintainer! endpoint-index #'sub pat #f L-stx)
      (add-event-handler!
       (lambda (evt-stx)
         #`(let ((proj (compile-projection (prepend-at-meta #,proj-stx #,L-stx))))
             (lambda (s)
               (match #,evt-stx
                 [(? #,(if asserted? #'patch/added? #'patch/removed?) p)
                  (sequence-transitions0*
                   s
                   (for/list [(entry (in-set (trie-project/set
                                              #,(if asserted?
                                                    #'(patch-added p)
                                                    #'(patch-removed p))
                                              proj)))]
                     (lambda (s)
                       (match (actor-state-variables s)
                         [(vector #,@binding-names)
                          (match-define (list #,@bindings) entry)
                          #,(make-run-script-call outer-expr-stx #'s I-stxs)]))))]
                 [_ #f]))))))

    (define (prepend-at-meta-stx stx level)
      (if (zero? level)
          stx
          #`(at-meta #,(prepend-at-meta-stx stx (- level 1)))))

    (define (analyze-message-subscription! endpoint-index outer-expr-stx P-stx I-stxs L-stx)
      (define-values (proj pat match-pat bindings) (analyze-pattern outer-expr-stx P-stx))
      (add-assertion-maintainer! endpoint-index #'sub pat #f L-stx)
      (add-event-handler!
       (lambda (evt-stx)
         #`(lambda (s)
             (match (actor-state-variables s)
               [(vector #,@binding-names)
                (match #,evt-stx
                  [(message #,(prepend-at-meta-stx match-pat (syntax-e L-stx)))
                   #,(make-run-script-call outer-expr-stx #'s I-stxs)]
                  [_ #f])])))))

    (define (analyze-event! index E-stx I-stxs)
      (syntax-parse E-stx
        #:literals [asserted retracted message rising-edge]
        [(asserted P L:meta-level)
         (analyze-asserted-or-retracted! index #t E-stx #'P I-stxs #'L.level)]
        [(retracted P L:meta-level)
         (analyze-asserted-or-retracted! index #f E-stx #'P I-stxs #'L.level)]
        [(message P L:meta-level)
         (analyze-message-subscription! index E-stx #'P I-stxs #'L.level)]
        [(rising-edge Pred)
         ;; TODO: more kinds of Pred than just expr
         (define aggregate-index (allocate-aggregate! #'#f))
         (add-event-handler!
          (lambda (evt-stx)
            #`(lambda (s)
                (match-define (vector #,@binding-names) (actor-state-variables s))
                (define old-val (hash-ref (actor-state-aggregates s) #,aggregate-index))
                (define new-val Pred)
                (if (eq? old-val new-val)
                    #f
                    (let ((s (struct-copy actor-state s
                                          [aggregates (hash-set (actor-state-aggregates s)
                                                                #,aggregate-index
                                                                new-val)])))
                      (if new-val
                          #,(make-run-script-call E-stx #'s I-stxs)
                          (transition s '())))))))]))

    (define (analyze-assertion! index Pred-stx outer-expr-stx P-stx L-stx)
      (define-values (proj pat match-pat bindings) (analyze-pattern outer-expr-stx P-stx))
      (add-assertion-maintainer! index #'core:assert pat Pred-stx L-stx))

    (define (analyze-tracks! index track-spec-stxs I-stxs)
      (error 'analyze-tracks! "unimplemented"))

    ;; Track analysis happens first, because we need the tracked
    ;; bindings to be in scope everywhere else.
    (for [(ongoing (in-list (syntax->list ongoings)))
          (ongoing-index (in-naturals))]
      (syntax-parse ongoing
        #:literals [track]
        [(track [track-spec ...] I ...)
         (analyze-tracks! ongoing-index #'(track-spec ...) #'(I ...))]
        [_ (void)]))

    ;; Now make another pass over the ongoings, ignoring tracks this
    ;; time.
    (for [(ongoing (in-list (syntax->list ongoings)))
          (ongoing-index (in-naturals))]
      (syntax-parse ongoing
        #:literals [on assert track]
        [(on E I ...)
         (analyze-event! ongoing-index #'E #'(I ...))]
        [(assert w:when-pred P L:meta-level)
         (analyze-assertion! ongoing-index #'w.Pred ongoing #'P #'L.level)]
        [(track [track-spec ...] I ...)
         (void)]))

    ;; Finally, add in the termination conditions...
    (for [(edge (in-list (syntax->list edges)))
          (edge-index (in-naturals (length (syntax->list ongoings))))]
      (syntax-parse edge
        [(E I0 I ...)
         (analyze-event! edge-index #'E #'((call-with-values (lambda () I0 I ...) return!)))]))

    ;; ...and generic linkage-related behaviors.
    (add-event-handler!
     (lambda (evt-stx)
       #`(lambda (s) (generic-actor-behavior #,evt-stx s))))

    (define action-fn-stx
      #`(lambda (self-id caller-id)
          (<spawn>
           (lambda ()
             (define ((maintain-assertions e) s)
               (sequence-transitions0 s #,@(mapply #'e (unbox assertion-maintainers))))

             (define (behavior e s)
               (and e
                    (sequence-transitions0 s
                                           #,@(mapply #'e (unbox track-updaters))
                                           #,@(mapply #'e (unbox event-handlers))
                                           (maintain-assertions e)
                                           perform-pending-patch)))

             (define initial-state
               (actor-state (hasheq)
                            caller-id
                            self-id
                            (vector #,@binding-inits)
                            (make-immutable-hash
                             (list
                              #,@(for/list [(init-stx (unbox aggregate-init-stxs))
                                            (init-idx (in-naturals))]
                                   #`(cons #,init-idx #,init-stx))))
                            #f
                            (mux)))

             (define (subscribe-to-linkage s)
               (define sub-to-callees
                 (patch-seq (sub (link-active self-id ?))
                            (sub (link-result self-id ? ?))))
               (define initial-subs
                 #,(if (eq? linkage-kind 'call)
                       #`(patch-seq sub-to-callees
                                    (core:assert (link-active caller-id self-id)))
                       #`sub-to-callees))
               ((extend-pending-patch *linkage-label* initial-subs) s))

             (define (run-init-actions s)
               (match (actor-state-variables s)
                 [(vector #,@binding-names)
                  ;; TODO: At the moment we are *not* letting the
                  ;; init-actions update the variables. Is this the
                  ;; right thing?
                  ;; TODO: what about intermediate (state)s? How are the variables updated?
                  (run-script s (lambda ()
                                  #,@init-actions
                                  (vector #,@binding-names)))]))

             (list behavior
                   (sequence-transitions0 initial-state
                                          subscribe-to-linkage
                                          (maintain-assertions #f)
                                          perform-pending-patch
                                          run-init-actions))))))

    ;; (local-require racket/pretty)
    ;; (pretty-print (syntax->datum action-fn-stx))

    #`(spawn! '#,linkage-kind #,action-fn-stx))
  )

    ;; ;; Given a Pred, computes (and perhaps allocates):
    ;; ;;   - an optional StageProducer for taking on board information from the outside world
    ;; ;;   - syntax for retrieving the current value of the Pred
    ;; ;;   - syntax for evaluating a new value for the Pred
    ;; ;;   - optional syntax for an updater for an aggregate
    ;; ;; (Syntax <Pred>) -> (Values (Option StageProducer)
    ;; ;;                            (Syntax <Expr:Boolean>)
    ;; ;;                            (Syntax <Expr:Boolean>)
    ;; ;;                            (Option (Syntax <Expr:(Any ActorState -> ActorState)>)))
    ;; (define (analyze-pred! Pred-stx)
    ;;   (syntax-parse Pred-stx
    ;;     #:literals [not or and exists]
    ;;     [(not Pred)
    ;;      (define-values (upd curr next store) (analyze-pred! #'Pred))
    ;;      (values upd #`(not #,curr) #`(not ,next))]
    ;;     [((~and HEAD (~or or and)) PredN ...)
    ;;      (define-values (upds currs nexts) (analyze-preds! #'(PredN ...)))
    ;;      (values (and (not (null? upds))
    ;;                   (lambda (evt-stx)
    ;;                     #`(lambda (s) (sequence-transitions0 s #,@(mapply evt-stx upds)))))
    ;;              #`(HEAD #,@currs)
    ;;              #`(HEAD #,@nexts))]
    ;;     [(exists P Pred)
    ;;      ...]

    ;;     [expr
    ;;      (define index (allocate-aggregate!))
    ;;      (values #f
    ;;              #'
    ;;      ...]))

    ;; (define (analyze-preds! Pred-stxs)
    ;;   (define-values (upds-rev currs-rev nexts-rev)
    ;;     (for/fold [(upds-rev '())
    ;;                (currs-rev '())
    ;;                (nexts-rev '())]
    ;;               [(Pred-stx (in-list (syntax->list Pred-stxs)))]
    ;;       (define-values (upd curr next) (analyze-pred! Pred-stx))
    ;;       (values (if upd (cons upd upds-rev) upds-rev)
    ;;               (cons curr currs-rev)
    ;;               (cons next nexts-rev))))
    ;;   (values (reverse upds-rev)
    ;;           (reverse currs-rev)
    ;;           (reverse nexts-rev)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; HLL pattern analysis

(begin-for-syntax
  (define (dollar-id? stx)
    (and (identifier? stx)
         (char=? (string-ref (symbol->string (syntax-e stx)) 0) #\$)))

  (define (undollar stx ctx)
    (and (dollar-id? stx)
         (datum->syntax ctx (string->symbol (substring (symbol->string (syntax-e stx)) 1)))))

  ;; Syntax -> (Values Projection AssertionSetPattern MatchPattern (ListOf Identifier))
  (define (analyze-pattern outer-expr-stx pat-stx0)
    (let walk ((pat-stx pat-stx0))
      (syntax-case pat-stx ($ ? quasiquote unquote quote)
        ;; Extremely limited support for quasiquoting and quoting
        [(quasiquote (unquote p)) (walk #'p)]
        [(quasiquote (p ...)) (walk #'(list (quasiquote p) ...))]
        [(quasiquote p) (values #''p #''p #''p '())]
        [(quote p) (values #''p #''p #''p '())]

        [$v
         (dollar-id? #'$v)
         (with-syntax [(v (undollar #'$v outer-expr-stx))]
           (values #'(?!)
                   #'?
                   #'v
                   (list #'v)))]

        [($ v p)
         (let ()
           (define-values (pr g m bs) (walk #'p))
           (when (not (null? bs))
             (raise-syntax-error #f "nested bindings not supported" outer-expr-stx pat-stx))
           (values #`(?! #,pr)
                   g
                   #`(and v #,m)
                   (list #'v)))]

        [(? pred? p)
         ;; TODO: support pred? in asserted/retracted as well as message events
         (let ()
           (syntax-parse outer-expr-stx
             #:literals [message]
             [(message _ ...) 'ok]
             [_ (raise-syntax-error #f
                                    "Predicate '?' matching only supported in message events"
                                    outer-expr-stx
                                    pat-stx)])
           (define-values (pr g m bs) (walk #'p))
           (values pr
                   g
                   #`(? pred? #,m)
                   bs))]

        [(ctor p ...)
         (let ()
           (define parts (if (identifier? #'ctor) #'(p ...) #'(ctor p ...)))
           (define-values (pr g m bs)
             (for/fold [(pr '()) (g '()) (m '()) (bs '())] [(p (syntax->list parts))]
               (define-values (pr1 g1 m1 bs1) (walk p))
               (values (cons pr1 pr)
                       (cons g1 g)
                       (cons m1 m)
                       (append bs1 bs))))
           (if (identifier? #'ctor)
               (values (cons #'ctor (reverse pr))
                       (cons #'ctor (reverse g))
                       (cons #'ctor (reverse m))
                       bs)
               (values (reverse pr)
                       (reverse g)
                       (reverse m)
                       bs)))]

        [?
         (raise-syntax-error #f
                             "Invalid use of '?' in pattern; use '_' instead"
                             outer-expr-stx
                             pat-stx)]

        [non-pair
         (if (and (identifier? #'non-pair)
                  (free-identifier=? #'non-pair #'_))
             (values #'?
                     #'?
                     #'_
                     '())
             (values #'non-pair
                     #'non-pair
                     #'(== non-pair)
                     '()))])))

  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (pretty-print-actor-state s [p (current-output-port)])
  (match-define
    (actor-state continuation-table caller-id self-id variables aggregates pending-patch mux)
    s)
  (fprintf p "ACTOR id ~a (caller-id ~a):\n" self-id caller-id)
  (fprintf p " - ~a pending continuations\n" (hash-count continuation-table))
  (fprintf p " - variables:\n")
  (for ((v variables))
    (fprintf p "    - ")
    (display (indented-port-output 6 (lambda (p) (prospect-pretty-print v p)) #:first-line? #f) p)
    (newline p))
  (fprintf p " - aggregates:\n")
  (for (((index a) (in-hash aggregates)))
    (define leader (format "    - ~a: " index))
    (fprintf p "~a" leader)
    (display (indented-port-output #:first-line? #f
                                   (string-length leader)
                                   (lambda (p) (prospect-pretty-print a p)))
             p)
    (newline p))
  (fprintf p " - pending-patch:\n")
  (display (indented-port-output 3 (lambda (p) (prospect-pretty-print pending-patch p))) p)
  (newline p)
  (fprintf p " - ")
  (display (indented-port-output 3 (lambda (p) (prospect-pretty-print mux p)) #:first-line? #f) p)
  (newline p))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(module+ test
  (require racket/pretty (for-syntax racket/pretty))

  (define (expand-and-print stx)
    (pretty-print (syntax->datum (expand stx))))

  (begin-for-syntax
    (define (analyze-and-print pat-stx)
      (let-values (((pr g m bs) (analyze-pattern pat-stx pat-stx)))
        (pretty-print `((pr ,(map syntax->datum pr))
                        (g ,(map syntax->datum g))
                        (m ,(map syntax->datum m))
                        (bs ,(map syntax->datum bs))))))

    #;(analyze-and-print #'`(hello ,$who)))

  (expand
   #'(actor
      (until (rising-edge (= count 10))
             #:collect [(count 0)]
             (on (message `(hello ,$who))
                 (println "Got hello: ~a" who)
                 (+ count 1))))))
