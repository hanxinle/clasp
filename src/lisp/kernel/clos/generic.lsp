#+(or)(eval-when (:execute)
        (format t "!~%!~%!~%!~%!~%In generic.lsp !~%  Turning on :compare *feature*  for ensure-generic-function~%!~%!~%!~%!~%")
        (setq cl:*features* (cons :compare cl:*features*))
        (setq cl:*features* (cons :force-lots-of-gcs cl:*features*)))
;;;;  -*- Mode: Lisp; Syntax: Common-Lisp; Package: CLOS -*-
;;;;
;;;;  Copyright (c) 1992, Giuseppe Attardi.
;;;;
;;;;    This program is free software; you can redistribute it and/or
;;;;    modify it under the terms of the GNU Library General Public
;;;;    License as published by the Free Software Foundation; either
;;;;    version 2 of the License, or (at your option) any later version.
;;;;
;;;;    See file '../Copyright' for full details.

(in-package "CLOS")

;;; ----------------------------------------------------------------------
;;; DEFGENERIC
;;;

(defmacro defgeneric (&whole whole &rest args)
  (multiple-value-bind (function-specifier lambda-list options)
    (parse-defgeneric args)
    (parse-lambda-list lambda-list)
    ;; process options
    (multiple-value-bind (option-list method-list)
	(parse-generic-options options lambda-list)
      (let* ((output `(progn
                        (eval-when (:compile-toplevel)
                          (cmp:register-global-function-def 'defgeneric ',function-specifier))
                        (ensure-generic-function ',function-specifier
                                                 :delete-methods t ,@option-list))))
        (if method-list
            `(progn
               ,output
               (associate-methods-to-gfun
                ',function-specifier
                ,@(loop for m in method-list collect `(defmethod ,function-specifier ,@m))))
	    output)))))

(defun parse-defgeneric (args)
  ;; (values function-specifier lambda-list options)
  (let (function-specifier)
    (unless args
      (simple-program-error "Illegal defgeneric form: missing generic function name"))
    (setq function-specifier (pop args))
    (unless args
      (simple-program-error "Illegal defgeneric form: missing lambda-list"))
    (values function-specifier (first args) (rest args))))

(defun parse-generic-options (options lambda-list)
  (let* ((processed-options '())
	 (method-list '())
	 (declarations '())
	 arg-list)
    (dolist (option options)
      (let ((option-name (first option))
	    option-value)
	(cond ((eq option-name :method)
	       ;; We do not need to check the validity of this
	       ;; because DEFMETHOD will do it.
	       (push (rest option) method-list))
	      ((eq option-name 'declare)
	       (setf declarations (append (rest option) declarations)))
	      ((member option-name processed-options)
	       (simple-program-error "Option ~s specified more than once"
				     option-name))
	      (t
	       (push option-name processed-options)
	       ;; We leave much of the type checking for SHARED-INITIALIZE
	       (setq option-value
		     (case option-name
		       (:argument-precedence-order
			(rest option))
		       (:method-combination
			(rest option))
		       ((:documentation :generic-function-class :method-class)
			(unless (endp (cddr option))
			  (simple-program-error "Too many arguments for option ~A"
						option-name))
			(second option))
		       (otherwise
			(simple-program-error "~S is not a legal defgeneric option"
					      option-name))))
	       (setf arg-list `(',option-name ',option-value ,@arg-list))))))
    (values `(:lambda-list ',lambda-list ,@arg-list
	      ,@(when declarations `(:declarations ',declarations)))
	    method-list)))

(defun parse-lambda-list (lambda-list &optional post-keyword)
  (let ((arg (car lambda-list)))
    (cond ((null lambda-list))
	  ((eq arg '&AUX)
	   (simple-program-error "&aux is not allowed in a generic function lambda-list"))
	  ((member arg lambda-list-keywords)
	   (parse-lambda-list (cdr lambda-list) t))
	  (post-keyword
	   ;; After a lambda-list-keyword there can be no specializers.
	   (parse-lambda-list (cdr lambda-list) t))
	  (t
	   (if (listp arg)
	       (simple-program-error "the parameters cannot be specialized in generic function lambda-list")
	       (parse-lambda-list (cdr lambda-list)))))))

(defun valid-declaration-p (decl)
  (and (eq (first decl) 'OPTIMIZE)
       (loop for item in decl
	  always (or (atom item)
		     (and (consp item)
			  (member (first item)
				  '(SPEED SPACE COMPILATION-SPEED DEBUG SAFETY)))))))

;;; ----------------------------------------------------------------------
;;; GENERIC FUNCTION (RE)INITIALIZATION PROTOCOL
;;

(defun lambda-list-required-arguments (lambda-list)
  (rest (si::process-lambda-list lambda-list t)))

(defmethod shared-initialize ((gfun generic-function) slot-names &rest initargs
			      &key (name nil)
			      (lambda-list nil l-l-p)
			      (argument-precedence-order nil a-o-p)
			      (documentation nil)
			      (declarations nil)
			      (method-class (find-class 'method))
			      &aux
			      (gfun-name (if (slot-boundp gfun 'name)
					     (slot-value gfun 'name)
					     (or name :anonymous)))
			      )
  (declare (ignore initargs slot-names)
           (core:lambda-name shared-initialize.generic-function))
  ;;
  ;; Check the validity of several fields.
  ;;
  (when a-o-p
    (unless l-l-p
      (simple-program-error "When defining generic function ~A~%Supplied :argument-precedence-order, but :lambda-list is missing"
			    gfun-name))
    (dolist (l (lambda-list-required-arguments lambda-list))
      (unless (= (count l argument-precedence-order) 1)
	(simple-program-error "When defining generic function ~A~%The required argument ~A does not appear exactly once in the ARGUMENT-PRECEDENCE-ORDER list ~A"
			      gfun-name l argument-precedence-order))))
  (unless (every #'valid-declaration-p declarations)
    (simple-program-error "When defining generic function ~A~%Not a valid declaration list: ~A"
			  gfun-name declarations))
  (unless (or (null documentation) (stringp documentation))
    (error 'simple-type-error
	   :format-control "When defining generic function~A~%Not a valid documentation object ~"
	   :format-arguments (list gfun-name documentation)
	   :datum documentation
	   :expected-type '(or null string)))
  (unless (si::subclassp method-class (find-class 'method))
    (error 'simple-type-error
	   :format-control "When defining generic function~A~%Not a valid method class, ~A"
	   :format-arguments (list gfun-name method-class)
	   :datum method-class
	   :expected-type 'method))
  ;; When supplying a new lambda-list, ensure that it is compatible with
  ;; the old list of methods.
  (when (and l-l-p (slot-boundp gfun 'methods))
    (unless (every #'(lambda (x)
                       (declare (core:lambda-name shared-initialize.lambda))
		       (congruent-lambda-p lambda-list x))
		 (mapcar #'method-lambda-list (generic-function-methods gfun)))
      (simple-program-error "Cannot replace the lambda list of ~A with ~A because it is incongruent with some of the methods"
			    gfun lambda-list)))
  (call-next-method) ; now that we have completed the assertions.
  ;; Coerce a method combination if required.
  (let ((combination (generic-function-method-combination gfun)))
    (unless (typep combination 'method-combination)
      (setf (generic-function-method-combination gfun)
	    (find-method-combination gfun (first combination) (rest combination)))))
  ;; If we have a new lambda list but no argument precedence, default the latter.
  (when (and l-l-p (not a-o-p))
    (setf (generic-function-argument-precedence-order gfun)
	  (lambda-list-required-arguments lambda-list)))
  ;; If we have a new lambda list and no display-lambda-list set up already, do that.
  ;; (If we already have a display ll, we probably don't need to alter it?)
  (when (and l-l-p (eq (ext:function-lambda-list gfun) (core:unbound)))
    (setf-lambda-list gfun lambda-list))
  ;; And finally, set up the actual function.
  (set-funcallable-instance-function gfun (compute-discriminating-function gfun))
  gfun)

(defun force-generic-function-specializer-profile (gfun vec)
  (loop for existing = (generic-function-specializer-profile gfun)
        for exchange = (generic-function-specializer-profile-compare-exchange gfun existing vec)
        until (eq exchange vec)))

(defun initialize-generic-function-specializer-profile (gfun &key (errorp t))
  (cond ((slot-boundp gfun 'lambda-list)
         (let ((lambda-list (generic-function-lambda-list gfun)))
           (force-generic-function-specializer-profile
            gfun
            (make-array (length (lambda-list-required-arguments lambda-list))
                        :initial-element nil))))
        (errorp
         (error "The specializer profile could not be initialized - lambda list of ~a was unbound"
                gfun))))
  
(defmethod shared-initialize :after ((gfun generic-function) slot-names &rest initargs)
  "In Clasp we need to initialize the specializer-profile with an 
   array of (length (lambda-list-required-arguments lambda-list)) full of nil."
  (unless (generic-function-specializer-profile gfun)
    (initialize-generic-function-specializer-profile gfun :errorp nil))
  gfun)

(defmethod shared-initialize :after ((gfun standard-generic-function) slot-names
                                     &rest initargs)
  (declare (ignore slot-names)
           (core:lambda-name shared-initialize-standard-generic-function))
  (when (generic-function-methods gfun)
    (compute-g-f-spec-list gfun))
  (update-dependents gfun initargs))

(defmethod reinitialize-instance :after ((gfun standard-generic-function) &rest initargs)
  ;; Check if the redefinition is trivial.
  ;; I am not sure of the fine details here. What happens if you reinitialize-instance
  ;; and change the method-combination, but not the methods to have compatible qualifiers,
  ;; for example? So what I'm going with is a somewhat magical minimum:
  ;; ENSURE-GENERIC-FUNCTION-USING-CLASS below calls with :name and whatever args it was
  ;; passed, and DEFMETHOD will pass with no extra args.
  ;; By incorporating this case, we avoid erasing the entire call history after any defmethod.
  ;; Note that ADD-METHOD is smart and does modify the call history to include the new method,
  ;; So things will remain consistent.
  (unless (and (= (length initargs) 2)
               (eq (first initargs) :name))
    ;; OK, something complicated. Erase.
    (erase-generic-function-call-history gfun)
    (invalidate-discriminating-function gfun)))

(defun associate-methods-to-gfun (name &rest methods)
  (let ((gfun (fdefinition name)))
    (dolist (method methods)
      (setf (getf (method-plist method) :method-from-defgeneric-p) t))
    gfun))

(defmethod ensure-generic-function-using-class
    ((gfun generic-function) name
     &rest args
     &key
       (method-class 'STANDARD-METHOD method-class-p)
       (generic-function-class (class-of gfun))
       (delete-methods nil))
  (mlog "In ensure-generic-function-using-class (gfun generic-function) gfun -> %s  name -> %s args -> %s%N" gfun name args)
  ;; modify the existing object
  (setf args (copy-list args))
  (remf args :generic-function-class)
  (remf args :declare)
  (remf args :environment)
  (remf args :delete-methods)
  ;; FIXME! We should check that the class GENERIC-FUNCTION-CLASS is compatible
  ;; with the old one. In what sense "compatible" is ment, I do not know!
  ;; (See ANSI DEFGENERIC entry)
  (when (symbolp generic-function-class)
    (setf generic-function-class (find-class generic-function-class)))
  (unless (si::subclassp generic-function-class (find-class 'generic-function))
    (error "~A is not a valid :GENERIC-FUNCTION-CLASS argument for ENSURE-GENERIC-FUNCTION."
	   generic-function-class))
  (when (and method-class-p (symbolp method-class))
    (setf args (list* :method-class (find-class method-class) args)))
  (when delete-methods
    (dolist (m (copy-list (generic-function-methods gfun)))
      (when (getf (method-plist m) :method-from-defgeneric-p)
	(remove-method gfun m))))
  (if (eq (class-of gfun) generic-function-class)
      (progn
	(apply #'reinitialize-instance gfun :name name args))
      (progn
	(apply #'change-class gfun generic-function-class :name name args))))

(defmethod ensure-generic-function-using-class
    ((gfun null) name &rest args &key
                                   (method-class 'STANDARD-METHOD method-class-p)
                                   (generic-function-class 'STANDARD-GENERIC-FUNCTION)
                                   (delete-methods nil))
  (declare (ignore delete-methods gfun))
  (mlog "In ensure-generic-function-using-class (gfun generic-function) gfun -> %s  name -> %s args -> %s%N" gfun name args)
  ;; else create a new generic function object
  (setf args (copy-list args))
  (remf args :generic-function-class)
  (remf args :declare)
  (remf args :environment)
  (remf args :delete-methods)
  (when (and method-class-p (symbolp generic-function-class))
    (setf args (list* :method-class (find-class method-class) args)))
  (apply #'make-instance generic-function-class :name name args))

;;; Miscellany

;;; Returns as process-lambda-list, but with keys etc from the methods added to the gf's.
;;; Basically returns the valid lambda list as in CLHS 7.6.5.
(defun generic-function-augmented-lambda-list (gf applicable-methods)
  (multiple-value-bind (req opt restvar keyflag keysl aokp) ; aux, varest irrelevant
      (core:process-lambda-list (generic-function-lambda-list gf) 'function)
    ;; get a list of keywords accepted by the gf.
    (let ((known-keys (loop for (key) on (cdr keysl) by #'cddddr
                            collecting key)))
      (loop for method in applicable-methods
            do (multiple-value-bind (mreq mopt mrestvar mkeyflag mkeysl maokp)
                   (core:process-lambda-list (method-lambda-list method) 'function)
                 (declare (ignore mreq mopt mrestvar))
                 ;; If any method wants keywords the arguments have to match that.
                 ;; E.g. for when the gf has only &rest but a method has &key.
                 (unless keyflag (when mkeyflag (setf keyflag t)))
                 ;; If any method has &allow-other-keys, so does the effective method.
                 (unless aokp (when maokp (setf aokp t)))
                 ;; The acceptable keywords are the union of the gf's with the methods'.
                 ;; The variables, default values, and -p variables are irrelevant in
                 ;; this function.
                 ;; We collect the keywords even if aokp is true because we might also
                 ;; want to use this lambda list for a display to the programmer.
                 (loop for (key var default -p) on (cdr mkeysl) by #'cddddr
                       unless (member key known-keys)
                         ;; new keys - throw em in front
                         do (setf (cdr keysl) (list* key var default -p (cdr keysl))
                                  (car keysl) (1+ (car keysl))
                                  ;; also update the known-keys for later methods.
                                  known-keys (list* key known-keys))))))
    (values req opt restvar keyflag keysl aokp nil nil)))

;;; Kind of badly placed, but- returns minimum and maximum number of args allowed as values.
;;; max is NIL if infinite. Used by fastgf.
(defun generic-function-min-max-args (gf)
  ;; since we call this from fastgf, it can't use generic functions (like g-f-l-l)
  ;; but FIXME: this may be a problem if g-f-l-l being generic is relevant, e.g. for a user subclass.
  (with-early-accessors (+standard-generic-function-slots+)
    (multiple-value-bind (req opt restvar keyflag) ; rest are irrelevant
        (core:process-lambda-list (generic-function-lambda-list gf) 'function)
      (values (car req) (if (or restvar keyflag) nil (+ (car req) (car opt)))))))
