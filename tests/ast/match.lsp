; -*- scheme -*-
; tree regular expression pattern matching
; by Jeff Bezanson

(define (unique lst)
  (if (null? lst)
      ()
      (cons (car lst)
	    (filter (lambda (x) (not (eq x (car lst))))
		    (unique (cdr lst))))))

; list of special pattern symbols that cannot be variable names
(define metasymbols '(_ ...))

; expression tree pattern matching
; matches expr against pattern p and returns an assoc list ((var . expr) (var . expr) ...)
; mapping variables to captured subexpressions, or #f if no match.
; when a match succeeds, __ is always bound to the whole matched expression.
;
; p is an expression in the following pattern language:
;
; _       match anything, not captured
; <func>  any scheme function; matches if (func expr) returns #t
; <var>   match anything and capture as <var>. future occurrences of <var> in the pattern
;         must match the same thing.
; (head <p1> <p2> etc)   match an s-expr with 'head' matched literally, and the rest of the
;                        subpatterns matched recursively.
; (-/ <ex>)  match <ex> literally
; (-^ <p>)   complement of pattern <p>
; (-- <var> <p>)  match <p> and capture as <var> if match succeeds
;
; regular match constructs:
; ...                 match any number of anything
; (-$ <p1> <p2> etc)  match any of subpatterns <p1>, <p2>, etc
; (-* <p>)            match any number of <p>
; (-? <p>)            match 0 or 1 of <p>
; (-+ <p>)            match at least 1 of <p>
; all of these can be wrapped in (-- var   ) for capturing purposes
; This is NP-complete. Be careful.
;
(define (match- p expr state)
  (cond ((symbol? p)
	 (cond ((eq p '_) state)
	       (#t
		(let ((capt (assq p state)))
		  (if capt
		      (and (equal? expr (cdr capt)) state)
		      (cons (cons p expr) state))))))
	
	((procedure? p)
	 (and (p expr) state))
	
	((pair? p)
	 (cond ((eq (car p) '-/) (and (equal? (cadr p) expr)             state))
	       ((eq (car p) '-^) (and (not (match- (cadr p) expr state)) state))
	       ((eq (car p) '--)
		(and (match- (caddr p) expr state)
		     (cons (cons (cadr p) expr) state)))
	       ((eq (car p) '-$)  ; greedy alternation for toplevel pattern
		(match-alt (cdr p) () (list expr) state #f 1))
	       (#t
		(and (pair? expr)
		     (equal? (car p) (car expr))
		     (match-seq (cdr p) (cdr expr) state (length (cdr expr)))))))
	
	(#t
	 (and (equal? p expr) state))))

; match an alternation
(define (match-alt alt prest expr state var L)
  (if (null? alt) #f  ; no alternatives left
      (let ((subma (match- (car alt) (car expr) state)))
	(or (and subma
		 (match-seq prest (cdr expr)
			    (if var
				(cons (cons var (car expr))
				      subma)
				subma)
			    (- L 1)))
	    (match-alt (cdr alt) prest expr state var L)))))

; match generalized kleene star (try consuming min to max)
(define (match-star- p prest expr state var min max L sofar)
  (cond ; case 0: impossible to match
   ((> min max) #f)
   ; case 1: only allowed to match 0 subexpressions
   ((= max 0) (match-seq prest expr
                         (if var (cons (cons var (reverse sofar)) state)
			     state)
                         L))
   ; case 2: must match at least 1
   ((> min 0)
    (and (match- p (car expr) state)
         (match-star- p prest (cdr expr) state var (- min 1) (- max 1) (- L 1)
                      (cons (car expr) sofar))))
   ; otherwise, must match either 0 or between 1 and max subexpressions
   (#t
    (or (match-star- p prest expr state var 0 0   L sofar)
        (match-star- p prest expr state var 1 max L sofar)))))
(define (match-star p prest expr state var min max L) 
  (match-star- p prest expr state var min max L ()))

; match sequences of expressions
(define (match-seq p expr state L)
  (cond ((not state) #f)
	((null? p) (if (null? expr) state #f))
	(#t
	 (let ((subp (car p))
	       (var  #f))
	   (if (and (pair? subp)
		    (eq (car subp) '--))
	       (begin (set! var (cadr subp))
                      (set! subp (caddr subp)))
	       #f)
	   (let ((head (if (pair? subp) (car subp) ())))
	     (cond ((eq subp '...)
		    (match-star '_ (cdr p) expr state var 0 L L))
		   ((eq head '-*)
		    (match-star (cadr subp) (cdr p) expr state var 0 L L))
		   ((eq head '-+)
		    (match-star (cadr subp) (cdr p) expr state var 1 L L))
		   ((eq head '-?)
		    (match-star (cadr subp) (cdr p) expr state var 0 1 L))
		   ((eq head '-$)
		    (match-alt (cdr subp) (cdr p) expr state var L))
		   (#t
		    (and (pair? expr)
			 (match-seq (cdr p) (cdr expr)
				    (match- (car p) (car expr) state)
				    (- L 1))))))))))

(define (match p expr) (match- p expr (list (cons '__ expr))))

; given a pattern p, return the list of capturing variables it uses
(define (patargs- p)
  (cond ((and (symbol? p)
              (not (member p metasymbols)))
         (list p))
        
        ((pair? p)
         (if (eq (car p) '-/)
             ()
	     (unique (apply append (map patargs- (cdr p))))))
        
        (#t ())))
(define (patargs p)
  (cons '__ (patargs- p)))

; try to transform expr using a pattern-lambda from plist
; returns the new expression, or expr if no matches
(define (apply-patterns plist expr)
  (if (null? plist) expr
      (if (procedure? plist)
	  (let ((enew (plist expr)))
	    (if (not enew)
		expr
		enew))
	  (let ((enew ((car plist) expr)))
	    (if (not enew)
		(apply-patterns (cdr plist) expr)
		enew)))))

; top-down fixed-point macroexpansion. this is a typical algorithm,
; but it may leave some structure that matches a pattern unexpanded.
; the advantage is that non-terminating cases cannot arise as a result
; of expression composition. in other words, if the outer loop terminates
; on all inputs for a given set of patterns, then the whole algorithm
; terminates. pattern sets that violate this should be easier to detect,
; for example
; (pattern-lambda (/ 2 3) '(/ 3 2)), (pattern-lambda (/ 3 2) '(/ 2 3))
; TODO: ignore quoted expressions
(define (pattern-expand plist expr)
  (if (not (pair? expr))
      expr
      (let ((enew (apply-patterns plist expr)))
	(if (eq enew expr)
            ; expr didn't change; move to subexpressions
	    (cons (car expr)
		  (map (lambda (subex) (pattern-expand plist subex)) (cdr expr)))
	    ; expr changed; iterate
	    (pattern-expand plist enew)))))
