;;;
;;;    File: cmpbundle.lsp
;;;

;; Copyright (c) 2014, Christian E. Schafmeister
;;
;; CLASP is free software; you can redistribute it and/or
;; modify it under the terms of the GNU Library General Public
;; License as published by the Free Software Foundation; either
;; version 2 of the License, or (at your option) any later version.
;;
;; See directory 'clasp/licenses' for full details.
;;
;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;; THE SOFTWARE.

;; -^-

(in-package :cmp)


(defun bundle-type-as-string (bundle-type)
  (cond
    ((eq bundle-type 'kernel) "kernel")
    ((eq bundle-type 'user) "user")
    (t (error "Illegal bundle-type ~a - only kernel or user are allowed" bundle-type))))

(defun bundle-name-as-string (bundle-name)
  (string-downcase (symbol-name bundle-name)))


#||
(defun make-bundle-wrapper (parts bundle-name)
  (let* ((module (create-bundle-module parts :output-pathname bundle-name))
	 (wrapper-name (pathname-name bundle-name))
	 (wrapper-pathname (make-pathname :name wrapper-name
                                          :type "bc"
                                          :defaults bundle-name)))
    (bformat t "Writing bundle module to %s\n" (namestring wrapper-pathname))
    (llvm-sys:write-bitcode-to-file module (core:coerce-to-filename wrapper-pathname))
    wrapper-pathname)
  )
||#

(defvar *echo-system* nil)
(defun safe-system (cmd-list)
  (if *echo-system*
      (bformat t "%s\n" cmd-list))
  (multiple-value-bind (retval error-message)
      (ext:vfork-execvp cmd-list)
    (when retval
      (error "Could not execute command with ext:vfork-execvp with ~s~%  return-value: ~d  error-message: ~s~%" cmd-list retval error-message))))




(defun generate-compile-command (bitcode-pathname)
  (let* ((bitcode-physical-pathname (translate-logical-pathname bitcode-pathname))
         (file (namestring bitcode-physical-pathname))
         (output-file (namestring (make-pathname :type "o" :defaults bitcode-physical-pathname))))
    (cond
      ((and (member :target-os-linux *features*)
            (member :address-model-64 *features*))
       (return-from generate-compile-command (values (bformat nil "llc -filetype=obj -relocation-model=pic -o %s %s" output-file file) output-file)))
      ((and (member :target-os-darwin *features*)
            (member :address-model-64 *features*))
       (if (member :use-clang *features*)
           (let* ((clasp-clang-path (ext:getenv "CLASP_CLANG_PATH"))
                  (clang-executable (if clasp-clang-path
                                        clasp-clang-path
                                        "clang")))
             (return-from generate-compile-command (values (bformat nil "%s -c -o %s %s" clang-executable output-file file) output-file)))
           (return-from generate-compile-command (values (bformat nil "llc -filetype=obj -relocation-model=pic -o %s %s" output-file file) output-file))))
      (t (error "Add support for running external clang to cmpbundle.lsp>generate-compile-command on this system")))))




;;; This function will compile a bitcode file in PART-BITCODE-PATHNAME with clang and put the output in the
;;; same directory as PART-BITCODE-PATHNAME
(defun generate-object-file (part-bitcode-pathname &key test)
  (let ((output-pathname (compile-file-pathname part-bitcode-pathname :output-type :object))
        (reloc-model (cond
                      ((member :target-os-linux *features*) 'llvm-sys:reloc-model-pic-)
                      (t 'llvm-sys:reloc-model-default))))
    (bitcode-to-obj-file part-bitcode-pathname output-pathname :reloc-model reloc-model)
    (truename output-pathname)))


(defun ensure-string (name)
  (cond
    ((pathnamep name) (core:coerce-to-filename name))
    ((stringp name) name)
    (t (string name))))

(defun generate-link-command (in-all-names in-bundle-file)
  ;; options are a list of strings like (list "-v")
  (let ((options nil)
        (all-names (mapcar (lambda (n) (ensure-string n)) (if (listp in-all-names) in-all-names (list in-all-names))))
        (bundle-file (ensure-string in-bundle-file)))
    (cond
      ((member :target-os-darwin *features*)
       (return-from generate-link-command
         `("ld" ,@options 
                ,@all-names
                "-macosx_version_min" "10.7"
                "-flat_namespace" 
                "-undefined" "warning"
                "-bundle"
                "-o"
                ,bundle-file)))
      ((member :target-os-linux *features*)
       (let* ((clasp-clang-path (ext:getenv "CLASP_CLANG_PATH"))
              (clang-executable (if clasp-clang-path
                                    clasp-clang-path
                                    "clang")))
         (return-from generate-link-command
           `(,clang-executable
             ,@options
             ,@all-names
             "-shared"
             "-o"
             ,bundle-file))))
      (t (error "Add support for this operating system to cmp:execute-link")))))

(defun execute-link (bundle-pathname all-names &key test)
  "Link object files together to create a shared library/bundle"
  (let ((link-command (generate-link-command all-names bundle-pathname)))
    (if test
        (bformat t "About to execute: %s\n" link-command)
        (safe-system link-command)))
    (truename bundle-pathname))



#||
;;; Make a .bundle file on OS X or a .so file on linux
;;; Provide the pathnames for the bitcode files (parts-pathnames)
;;; if the bundle-name is _image then it's the one kernel image
;;; If it is anything else then it's a user image
;;;
(defun make-bundle (parts-pathnames &optional (bundle-name +image-pathname+)
		    &aux (bundle-type (if (eq bundle-name '_image) 'kernel 'user)))
  "Use (link-system _last-file_) to create the files for a bundle - then go to src/lisp/clasp and make-bundle.sh _image"
  (let* ((wrapper-pathname (make-bundle-wrapper parts bundle-name))
	 (wrapper-and-parts-pathnames (cons wrapper-pathname parts-pathnames))
	 (bundle-pathname (make-pathname :name (string-downcase (string bundle-name)) :defaults *image-directory*)))
    (let ((all-object-files (mapc #'(lambda (pn) (execute-clang pn)) wrapper-and-parts-pathnames)))
      (execute-link bundle-pathname all-object-files))))
||#


;;;
;;; Gather a list of boot parts as pathnames
;;; Skip over keyword symbols in the boot part lists
;;;
(defun boot-bitcode-pathnames (last-file &key first-file target-backend)
  (or first-file (error "You must provide first-file"))
  (let* ((source-files (mapcan #'(lambda (part) (and (not (keywordp part)) (list (core::get-pathname-with-type part "lsp"))))
                               (core::select-source-files last-file :first-file first-file)))
         (bitcode-files (mapcar (lambda (k) (compile-file-pathname k :target-backend target-backend))
                                source-files)))
    bitcode-files))
(export 'boot-bitcode-pathnames)

#||
(defun link-system (pathname-destination &key lisp-bitcode-files (target-backend (default-target-backend)) test) ;; &optional (bundle-pathname +image-pathname+))
  "Use (link-system _last-file_) to create the files for a bundle - then go to src/lisp/clasp and make-bundle.sh _image"
  (let* ((core:*target-backend* target-backend)
         (pathname-destination (target-backend-pathname pathname-destination :target-backend target-backend))
         (wrapper-fasl-pathname (make-bundle-wrapper lisp-bitcode-files pathname-destination))
	 (wrapper-and-parts-fasl-pathnames (cons wrapper-fasl-pathname lisp-bitcode-files)))
    (let ((object-files (mapcar #'(lambda (pn) (generate-object-file pn :test test)) wrapper-and-parts-fasl-pathnames)))
      (execute-link pathname-destination object-files :test test))))

(export '(make-bundle link-system))
||#




#+(or)(defun create-module-pass-manager-for-lto (&key output-pathname debug-ir)
        (let* ((pass-manager-builder (llvm-sys:make-pass-manager-builder))
               (pass-manager (llvm-sys:make-pass-manager)))
          ;;    (llvm-sys:populate-module-pass-manager pass-manager-builder pass-manager)
          ;;    (llvm-sys:pass-manager-builder-setf-inliner pass-manager-builder (llvm-sys:create-always-inliner-pass))
          (llvm-sys:populate-module-pass-manager pass-manager-builder pass-manager)
          ;;    (llvm-sys:add-global-boot-functions-size-pass pass-manager)   ;; I do this outside of a module pass
          #|    (when debug-ir
          (let ((
          (llvm-sys:pass-manager-add pass-manager (llvm-sys:create-debug-irpass nil nil )))
          |#
    pass-manager))


(defun link-bitcode-modules (part-pathnames &key additional-bitcode-pathnames
                                              (output-pathname +image-pathname+)
                                              prologue-module
                                              epilogue-module
                                              debug-ir
                             &aux conditions)
  "Link a bunch of modules together, return the linked module"
  (with-compiler-env (conditions)
    (multiple-value-bind (module function-pass-manager)
        (create-llvm-module-for-compile-file (pathname-name output-pathname))
      (let* ((*compile-file-pathname* (pathname (merge-pathnames output-pathname)))
	     (*compile-file-truename* (translate-logical-pathname *compile-file-pathname*))
	     (bcnum 0))
	(with-module ( :module module
                               :optimize t
                               :source-pathname (namestring output-pathname))
          (with-debug-info-generator (:module module :pathname output-pathname)
            (let* ((linker (llvm-sys:make-linker *the-module*)))
              ;; Don't enforce .bc extension for additional-bitcode-pathnames
              (if prologue-module
                  (progn
                    (bformat t "Linking prologue-form\n")
                    (remove-main-function-if-exists prologue-module)
                    (llvm-sys:link-in-module linker prologue-module)))
              ;; This is where I used to link the additional-bitcode-pathnames
              (dolist (part-pn part-pathnames)
                (let* ((bc-file (make-pathname :type "bc" :defaults part-pn)))
                  (bformat t "Linking %s\n" bc-file)
                  (let* ((part-module (llvm-sys:parse-bitcode-file (namestring (truename bc-file)) *llvm-context*)))
                    (remove-main-function-if-exists part-module) ;; Remove the ClaspMain FN if it exists
                    (multiple-value-bind (failure error-msg)
                        (llvm-sys:link-in-module linker part-module)
                      (when failure
                        (error "While linking part module: ~a  encountered error: ~a" part-pn error-msg))))))
              (if epilogue-module
                  (progn
                    (bformat t "Linking epilogue-form\n")
                    (remove-main-function-if-exists epilogue-module)
                    (llvm-sys:link-in-module linker epilogue-module)))
              (reset-global-boot-functions-name-size *the-module*)
              (add-main-function *the-module*) ;; Here add the main function
              ;; The following links in additional-bitcode-pathnames
              (dolist (part-pn additional-bitcode-pathnames)
                (let* ((bc-file part-pn))
                  (bformat t "Linking %s\n" bc-file)
                  (let* ((part-module (llvm-sys:parse-bitcode-file (namestring (truename bc-file)) *llvm-context*)))
                    (remove-main-function-if-exists part-module) ;; Remove the ClaspMain FN if it exists
                    (multiple-value-bind (failure error-msg)
                        (llvm-sys:link-in-module linker part-module)
                      (when failure
                        (error "While linking additional module: ~a  encountered error: ~a" bc-file error-msg))
                      ))))
              (when *debug-generate-prepass-llvm-ir*
                (llvm-sys:write-bitcode-to-file *the-module* (core:coerce-to-filename (pathname "image_test_prepass.bc"))))
              #+(or)(let* ((mpm (create-module-pass-manager-for-lto :output-pathname output-pathname :debug-ir debug-ir)))
                      (format t "Running link time optimization module pass manager~%")
                      (llvm-sys:pass-manager-run mpm *the-module*))
              *the-module*)))))))

#||
(load-system :start :cmp :interp t)
(compile-file "tiny1.lsp")
(compile-file "tiny2.lsp")
(cmp:link-system-lto #P"tiny.bundle" :lisp-bitcode-files (list #P"tiny1.bc" #P"tiny2.bc"))
||#

(defun link-system-lto (output-pathname
                        &key (intrinsics-bitcode-path (core:build-intrinsics-bitcode-pathname))
                          lisp-bitcode-files
                          prologue-form
                          epilogue-form
                          debug-ir
                          (target-backend (default-target-backend)))
  (let* ((*target-backend* target-backend)
         (output-pathname (pathname output-pathname))
         (part-pathnames lisp-bitcode-files)
         ;;         (bundle-filename (string-downcase (pathname-name output-pathname)))
	 (bundle-bitcode-pathname (cfp-output-file-default output-pathname :linked-bitcode)))
    (let* ((prologue-module (if prologue-form (compile-form-into-module prologue-form "prologueForm")))
           (epilogue-module (if epilogue-form (compile-form-into-module epilogue-form "epilogueForm")))
           (module (link-bitcode-modules part-pathnames
                                         :additional-bitcode-pathnames (if intrinsics-bitcode-path
                                                                           (list intrinsics-bitcode-path)
                                                                           nil)
                                         :output-pathname output-pathname
                                         :prologue-module prologue-module
                                         :epilogue-module epilogue-module
                                         :debug-ir debug-ir)))
      (ensure-directories-exist bundle-bitcode-pathname)
      (llvm-sys:write-bitcode-to-file module (core:coerce-to-filename bundle-bitcode-pathname))
      (let ((object-pathname (truename (generate-object-file bundle-bitcode-pathname))))
        (execute-link output-pathname (list object-pathname)))
      output-pathname)))

(export '(link-system-lto))


(defun builder (kind destination &rest keywords)
  (bformat t "builder kind[%s] destination[%s] keywords: %s\n" kind destination keywords)
  (break "Check parameters"))

(export '(builder))


(defun build-fasl (out-file &key lisp-files)
  "Link the object files in lisp-files into a shared library in out-file.
Return the truename of the output file"
;;  (bformat t "cmpbundle.lsp:build-fasl  building fasl for %s from files: %s\n" out-file lisp-files)
  (execute-link out-file lisp-files))

(export 'build-fasl)
