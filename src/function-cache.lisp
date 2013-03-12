(in-package :function-cache)
(cl-interpol:enable-interpol-syntax)

(defclass function-cache ()
  ((cached-results :accessor cached-results :initform nil :initarg
                   :cached-results)
   (timeout :accessor timeout :initform nil :initarg :timeout)
   (body-fn :accessor body-fn :initform nil :initarg :body-fn)
   (name :accessor name :initform nil :initarg :name)
   (lambda-list :accessor lambda-list :initform nil :initarg :lambda-list))
  (:documentation "an object that contains the cached results of function calls
    the original function to be run, to set cached values
    and other cache configuration parameters"))

(defmethod cached-results :around ((cache function-cache))
  "Coerce the refernce to the results into something we can use"
  (let ((result (call-next-method)))
    (typecase result
      (null nil)
      (function (funcall result))
      (symbol (cond ((boundp result) (symbol-value result))
                    ((fboundp result) (funcall result))))
      (t result))))

(defclass thunk-cache (function-cache)
  ()
  (:documentation "a cache optimized for functions of no arguments"))

(defclass hash-table-function-cache (function-cache)
  ((hash-init-args :accessor hash-init-args :initform
                   '(:test equal :synchronized t) :initarg :hash-init-args)
   (shared-results? :accessor shared-results? :initform nil :initarg
                    :shared-results?))
  (:documentation "a function cache that uses a hash-table to store results"))

(defmethod initialize-instance :after
    ((cache function-cache) &key &allow-other-keys)
  (ensure-cache-backing cache))

(defgeneric ensure-cache-backing (cache)
  (:documentation "ensures that cached-results has the expected init value")
  (:method ((cache function-cache)) t)
  (:method ((cache hash-table-function-cache))
    (unless (slot-value cache 'cached-results)
      (setf (slot-value cache 'cached-results)
            (apply #'make-hash-table (hash-init-args cache))))))

(defgeneric expired? ( cache result-timeout )
  (:documentation "Determines if the cache entry is expired")
  (:method (cache result-timeout)
    (let ((timeout (timeout cache)))
      (cond
        ;; things never expire
        ((null timeout) nil)
        ;; no valid cache entry - must be expiredish
        ((null result-timeout) t)
        ;; we have timeouts and times to compare, are we past expiration
        (t (let ((expires-at (+ timeout result-timeout)))
             (< expires-at (get-universal-time))))
        ))))

(defgeneric get-cached-value (cache cache-key)
  (:documentation "returns the result-values-list and at what time it was cached")
  (:method ((cache hash-table-function-cache) cache-key)
    ;; if we get no hash when we expect one then it probably means
    ;; that we should just run tthe body (eg: http-context cached results
    ;; a valid http context)
    (let* ((hash (cached-results cache))
           (cons (when hash (gethash cache-key (cached-results cache))))
           (res (car cons))
           (cached-at (cdr cons)))
      (values res cached-at)))
  (:method ((cache thunk-cache) cache-key)
    (declare (ignore cache-key))
    (let* ((res (car (cached-results cache)))
           (cached-at (cdr (cached-results cache))))
      (values res cached-at))))

(defgeneric (setf get-cached-value) (new cache cache-key)
  (:documentation "Set the cached value for the cache key")
  (:method (new (cache hash-table-function-cache) cache-key)
    ;; without our shared hash, we cannot cache
    (let ((hash (cached-results cache)))
      (when hash
        (setf (gethash cache-key hash)
              (cons new (get-universal-time))))))
  (:method (new (cache thunk-cache) cache-key)
    (declare (ignore cache-key))
    (setf (cached-results cache)
          (cons new (get-universal-time)))))

(defgeneric defcached-hashkey (thing)
  (:documentation "Turns a list of arguments into a valid cache-key
    (usually a tree of primatives)")
  (:method ((thing T))
    (typecase thing
      (null nil)
      (list (iter (for i in thing)
              (collect (defcached-hashkey i))))
      (t thing))))

(defgeneric compute-cashe-key (cache thing)
  (:documentation "Used to assemble cache keys for function-cache objects")
  (:method ((cache function-cache) thing)
    (defcached-hashkey thing))
  (:method ((cache hash-table-function-cache) thing)
    (let ((rest (ensure-list (defcached-hashkey thing))))
      (if (shared-results? cache)
          (list* (name cache) rest)
          rest))))

(defgeneric cacher (cache args)
  (:documentation "A function that takes a cache object and an arg list
    and either runs the computation and fills the caches or retrieves
    the cached value")
  (:method ((cache function-cache) args
            &aux (cache-key (compute-cashe-key cache args)))
    (multiple-value-bind (cached-res cached-at)
        (get-cached-value cache cache-key)
      (if (or (null cached-at) (expired? cache cached-at))
          (let ((results (multiple-value-list (apply (body-fn cache) args))))
            (setf (get-cached-value cache cache-key) results)
            (apply #'values results))
          (apply #'values cached-res)))))

(defvar *cache-names* nil
  "A list of all function-caches")

(defgeneric clear-cache (cache &optional args)
  (:documentation "Clears a given cache")
  (:method ((cache function-cache) &optional args)
    (declare (ignore args))
    (setf (cached-results cache) nil))
  (:method ((cache hash-table-function-cache)
            &optional (args nil args-input?)
            &aux
            (name (name cache))
            (hash (cached-results cache))
            (shared-results? (shared-results? cache)))
    ;; there was no cache, so there can be no results to clear
    (when hash
      (cond (args-input?
             (remhash (compute-cashe-key cache args) hash))
            ((not shared-results?)
             ;; clear the whole hash, as they didnt specify args and
             ;; it doesnt share storage
             (clrhash hash))
            ;; we need to sort out which keys to remove based on our name
            (shared-results?
             (iter (for (key value) in-hashtable hash)
               (when (eql name (first key))
                 (collect key into keys-to-rem))
               (finally (iter (for key in keys-to-rem)
                          (remhash key hash)))))))))

(defun clear-cache-all-function-caches (&optional package)
  (when package (setf package (find-package package)))
  (iter (for n in *cache-names*)
    (when (or (null package)
              (eql (symbol-package n) package))
      (clear-cache (symbol-value n)))))

(defun %cache-var-name (symbol)
  (symbol-munger:english->lisp-symbol #?"*${ symbol }-cache*"))

(defgeneric default-cache-class (symbol lambda-list &key cache-class)
  (:method (symbol lambda-list &key cache-class)
    (cond
      (cache-class cache-class)
      ((null lambda-list) 'thunk-cache)
      (t 'hash-table-function-cache))))

(defun %defcached-base-forms (symbol lambda-list body)
  (destructuring-bind (fn-name &key cache-class table timeout
                               (shared-results? nil shared-result-input?))
      (ensure-list symbol)
    (when (and table (not shared-result-input?))  (setf shared-results? t))
    (multiple-value-bind (args optional rest keys)
        (alexandria:parse-ordinary-lambda-list lambda-list)
      (let* ((cache-class (default-cache-class symbol lambda-list :cache-class cache-class))
             (cache (%cache-var-name fn-name))
             (doc (when (stringp (first body)) (first body)))
             (call-list (append args
                                (mapcar #'first optional)
                                (mapcan #'first keys)
                                ))
             (call-list (if rest
                            `(list* ,@call-list ,rest)
                            `(list ,@call-list))))
        `(progn
          (defvar ,cache nil)
          (pushnew ',cache *cache-names*)
          (setf ,cache
           (make-instance ',cache-class
            :body-fn (lambda ,lambda-list ,@body)
            :name ',fn-name
            :lambda-list ',lambda-list
            :timeout ,timeout
            :shared-results? ,shared-results?
            :cached-results ,table))
          (defun ,fn-name ,lambda-list
            ,doc
            (cacher ,cache ,call-list)))))))

(defmacro defcached (symbol lambda-list &body body)
  (%defcached-base-forms symbol lambda-list body))

#|

(defmacro defcached (symbol lambda-list &body fnbody)
  `(defcached*  ,symbol ,lambda-list
     ()
     ,@fnbody))

 (defmacro defcached* (symbol lambda-list
		      (&key
                       (hash-test '(quote equal))
                       (hash-table `(make-hash-table :test ,hash-test :synchronized T))
                       extra-hash-key
                       timeout-seconds)
		      &body fnbody)
  "defines 4 functions SYMBOL, SYMBOL-CLEAR-CACHE, SYMBOL-CACHE, and SYMBOL-SET-TIMEOUT
  The function of the name Symbol is the function you were defining cached.
  The function SYMBOL-CLEAR-CACHE will immediatly clear the cache.
  The function SYMBOL-CACHE returns the backing storage for this cache.
  The function SYMBOL-SET-TIMEOUT will clear the cache if it is not accessed with in the timeout period
    if the timeout is set to nil, then the cache will be permanent until manually cleared

   Extra hashkey is intended to be used when many functions share a single cache
   and we need a way to determine which function this cache entry belongs to
"
  (multiple-value-bind (args optional rest keys)
      (alexandria:parse-ordinary-lambda-list lambda-list)
    (let ((sym-clear-cache (intern #?"${symbol}-CLEAR-CACHE"))
	  (sym-set-timeout (intern #?"${symbol}-SET-TIMEOUT"))
	  (sym-cache (intern #?"${symbol}-CACHE"))
          (sym-special-cache (intern #?"*${symbol}-CACHE*"))
          (sym-special-timeout (intern #?"*${symbol}-TIMEOUT*"))
          (sym-special-extra-hash-key (intern #?"*${symbol}-EXTRA-HASH-KEY*"))
	  (arg-vals (append args
			    (mapcar #'first optional)
			    (ensure-list rest)
			    (mapcar (compose #'second #'first) keys)))
	  (call-list (append args
			     (mapcar #'first optional)
			     (ensure-list rest)
			     (mapcan #'first keys))))
      (with-unique-names  (fn mfn args memoize cache-the-val make-key)
	`(progn
          (defvar ,sym-special-cache)
          (defvar ,sym-special-timeout)
          (defvar ,sym-special-extra-hash-key)
          (setf
           ,sym-special-cache ,hash-table
           ,sym-special-timeout ,timeout-seconds
           ,sym-special-extra-hash-key ,extra-hash-key)
          (flet ((,memoize (func)
                   (lambda (,@lambda-list)
                     (bind ((:flet (,make-key (&rest args)
                                     (mapcar #'defcached-hashkey
                                             (if ,sym-special-extra-hash-key
                                                 (cons ,sym-special-extra-hash-key args)
                                                 args))))
                            ((value-cell in-hashp)
                             (when ,sym-special-cache
                               (gethash (,make-key ,@arg-vals)
                                        ,sym-special-cache)))
                            ((val . this-timeout) value-cell)
                            (age (and this-timeout
                                      (- (get-universal-time) this-timeout)))
                            (:flet
                             (,cache-the-val ()
                               (let ((val (funcall func ,@call-list)))
                                 (prog1 val
                                   (when ,sym-special-cache
                                     (setf (gethash (,make-key ,@arg-vals)
                                                    ,sym-special-cache)
                                           (cons val (get-universal-time)))))))))
                       (cond
                         ;; dont have a value, get one
                         ((not in-hashp)
                          (,cache-the-val))

                         ;; cache has expired
                         ((and ,sym-special-timeout age (>= age ,sym-special-timeout))
                          (when ,sym-special-cache
                            (remhash (list ,@arg-vals) ,sym-special-cache))
                          (,cache-the-val))

                         ;; reset the timeout and return the val
                         ((and ,sym-special-timeout age)
                          (setf (cdr value-cell) (get-universal-time))
                          val)

                         ;; no exp
                         (in-hashp val))))))

            (flet ((,fn ,lambda-list ,@fnbody))
              (let ((,mfn (funcall #',memoize #',fn)))
                (defun ,symbol ,lambda-list
                  (funcall ,mfn ,@call-list)))))
          (defun ,sym-clear-cache (&rest ,args)
            ;;(break "in clear cache with args:~a hash:~a" ,args ,cache )
            (when ,sym-special-cache
              (if ,args
                  (remhash ,args ,sym-special-cache)
                  (clrhash ,sym-special-cache))))
          (defun ,sym-set-timeout (new-timeout-in-seconds)
            (setq ,sym-special-timeout new-timeout-in-seconds))
          (defun ,sym-cache () ,sym-special-cache)
          )))))

 (defmacro def1cache* (symbol lambda-list
		      (&key (hash-test '(quote equal)) timeout-seconds)
		      &body fnbody)
  "defines 4 functions SYMBOL, SYMBOL-CLEAR-CACHE, SYMBOL-CACHE, and SYMBOL-SET-TIMEOUT
  The function of the name Symbol is the function you were defining cached.
  The function SYMBOL-CLEAR-CACHE will immediatly clear the cache.
  The function SYMBOL-CACHE returns the backing storage for this cache.
  The function SYMBOL-SET-TIMEOUT will clear the cache if it is not accessed with in the timeout period
    if the timeout is set to nil, then the cache will be permanent until manually cleared
"
  (multiple-value-bind (args optional rest keys)
      (alexandria:parse-ordinary-lambda-list lambda-list)
    (let ((sym-clear-cache (intern (string-upcase (concatenate 'string (symbol-name symbol) "-CLEAR-CACHE"))))
	  (sym-set-timeout (intern (string-upcase (concatenate 'string (symbol-name symbol) "-SET-TIMEOUT"))))
	  (sym-cache (intern (string-upcase (concatenate 'string (symbol-name symbol) "-CACHE"))))
	  (arg-vals (append args
			    (mapcar #'first optional)
			    (ensure-list rest)
			    (mapcar (compose #'second #'first) keys)))
	  (call-list (append args
			     (mapcar #'first optional)
			     (ensure-list rest)
			     (mapcan #'first keys)))
          (blank-cache-form `(cons nil (cons nil nil))))
      (with-unique-names  (fn mfn args cache memoize timeout cache-the-val)
        ;;cache structure: (arg-list . (value . last-accessed))
	`(let ((,cache ,blank-cache-form)
	       (,timeout ,timeout-seconds))
	   (flet ((,memoize (func)
		    (lambda (,@lambda-list)
                      (block nil
                        (flet ((,cache-the-val ()
                                 (cadr (setf ,cache
                                             (cons (list ,@arg-vals)
                                                   (cons (funcall func ,@call-list)
                                                         (get-universal-time)))))))
                        ;;want to make sure that no matter what other
                        ;;threads do we see one consistent version of
                        ;;this 'cache-line': get a fresh binding.
                        (let ((,cache ,cache))
                          (destructuring-bind (arg-list . (value . last-accessed)) ,cache
                            (if (or
                                 ;;cache timeout
                                 (and ,timeout
                                         (>= (- (get-universal-time)
                                                last-accessed) ;time when it was last accessed.
                                             ,timeout))
                                 ;;cache miss
                                 (not (funcall ,hash-test arg-list (list ,@arg-vals))))
                                (,cache-the-val) ;recalc
                                (progn
                                  ;;reset the timeout and return the val
                                  (setf (cddr ,cache) (get-universal-time))
                                  value)))))))))

	     (flet ((,fn ,lambda-list ,@fnbody))
	       (let ((,mfn (funcall #',memoize #',fn)))
		 (defun ,symbol ,lambda-list
		   (funcall ,mfn ,@call-list)))))
	   (defun ,sym-clear-cache (&rest ,args)
                                        ;(break "in clear cache with args:~a hash:~a" ,args ,cache )
             (setf ,cache ,blank-cache-form))
	   (defun ,sym-set-timeout (new-timeout-in-seconds) (setq ,timeout new-timeout-in-seconds))
	   (defun ,sym-cache () ,cache))))))
|#