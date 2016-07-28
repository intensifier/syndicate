#lang syndicate/actor
;; Test case for a bug relating to use of parameters to accumulate
;; actions across react/suspend when an intermediate parameterization
;; for current-dataflow-subject-id has taken place.
;;
;; Expected output:
;;     flag: 'clear
;;     - 'first
;;     flag: 'set
;;     - '(saw ping)
;;
;; Buggy output:
;;     flag: 'clear
;;     - 'first
;;     flag: 'clear

(struct x (v) #:prefab)

(actor (forever (on (message (x 'ping))
                    (send! (x 'pong)))))

(actor (react
        (field [flag 'clear])
        (begin/dataflow
          (printf "flag: ~v\n" (flag)))

        (field [spec #f])
        (begin/dataflow
          (when (spec)
            (let-event [(asserted (observe (x (spec))))]
                       (send! (x (list 'saw (spec))))
                       (flag 'set))))

        (on-start (send! (x 'first)))
        (on (message (x 'first))
            (spec 'ping))))

(actor (forever (on (message (x $v))
                    (printf "- ~v\n" v))))