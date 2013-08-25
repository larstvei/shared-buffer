;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

(ql:quickload :usocket)
(ql:quickload :bt-semaphore)

(defconstant +port+ 3705
  "Shared-buffer uses port 3705.")

(defparameter *client-groups* nil
  "Hash table containing lists of clients working on the same buffer.")

(defparameter *colors* (list "green" "blue" "red" "yellow" "purple" "orange")
  "A list of colors for cursors.")

(defstruct client key stream id color 
           (semaphore (bt-semaphore:make-semaphore :name "ack")))

(defstruct client-group clients colors)

(defun string-chunks (max-len str)
  "Returns a list of strings, where max-len is the maximum length of each
string."
  (let* ((len (length str))
         (chunks (/ len max-len)))
    (loop for i to chunks collect
         (subseq str (* i max-len) (and (< (* (+ i 1) max-len) len)
                                        (* (+ i 1) max-len))))))

(defun send-package (message client-group)
  "Simply sends a message recived from a client to all clients sharing a
buffer."
  (loop for client in client-group do
     ;; -- DEBUG -- ;;
       (print message)
       (force-output)
     ;; ----------- ;;
       (mapc (lambda (str)
               (write-string str (client-stream client))
               (finish-output (client-stream client))
               (bt-semaphore:wait-on-semaphore
                (client-semaphore client) :timeout 1)
               ;; -- DEBUG -- ;;
               (format t "chunk size: ~d~%" (length str))
               (force-output)
               ;; ----------- ;;
               )
             (string-chunks (expt 2 10) message))))

(defun remove-from-group (client)
  "Fetches the client-group the given client is a part of, and returns it's
list of clients without the given client."
  (remove client (client-group-clients
                  (gethash (client-key client) *client-groups*))))

(defun stream-reader (client)
  "After a client has successfully connected to the server, this function
will be called. Every time it receives a package it will make a few changes
  to the package and send it on to all the other clients sharing the same
  buffer. "
  (loop for message = (read-line (client-stream client) nil)
     while message do
       (if (string-equal "ack" message)
           (bt-semaphore:signal-semaphore (client-semaphore client) 1)
           (send-package
            (format nil "~a ~a \"~a\"]"
                    (subseq message 0 (- (length message) 9))
                    (client-id client) (client-color client))
            (remove-from-group client))))
  ;; After reaching EOF we remove the client from the client group. If that
  ;; was the last connected client the key should no longer be associated
  ;; with a key.
  (unless (setf (client-group-clients
                 (gethash (client-key client) *client-groups*))
                (remove-from-group client))
    (remhash (client-key client) *client-groups*)))

(defun next-color (colors)
  "Receives a list of colors, and returns two values: the first color and
the same list of colors only rotated once to the left."
  (values (car colors)
          (append (cdr colors) (list (car colors)))))

(defun connect-client-to-existing-session (stream key)
  "This function is called if a client wants to be connected to an already
existing shared buffer session. Here it's given an id, and a color."
  (multiple-value-bind (color colors)
      (next-color (client-group-colors (gethash key *client-groups*)))
    (let ((client-group (gethash key *client-groups*))
          (client (make-client
                   :key key :stream stream :id (gensym) :color color)))
      (send-package "send-everything"
                    (last (client-group-clients client-group)))
      (setf (client-group-clients client-group)
            (cons client (client-group-clients client-group)))
      (setf (client-group-colors client-group) colors)
      (stream-reader client))))

(defun connect-client-to-new-session (stream key)
  "This function is called when a client wants to create a new shared buffer
session. We let the key be associated with a new client-group, which
  contains the new client and a list of colors."
  (multiple-value-bind (color colors)
      (next-color *colors*)
    (let ((client (make-client
                   :key key :stream stream :id (gensym) :color color)))
      (setf (gethash key *client-groups*)
            (make-client-group :clients (list client) :colors colors))
      (stream-reader client))))

(defun handler (stream)
  "When a connection to a client is established this function is run. It
  will read from the stream as long as the connection is open, and redirect
  messages to all clients that has provided the same key."
  (let* ((kind (read-line stream))
         (key (read-line stream)))
    (cond ((string= kind "new")
           (if (gethash key *client-groups*)
               (send-package "Choose a different key."
                             (list (make-client :stream stream)))
               (connect-client-to-new-session stream key)))
          ((string= kind "existing")
           (if (gethash key *client-groups*)
               (connect-client-to-existing-session stream key)
               (send-package
                (concatenate 'string
                             "The key " key " is not associated with any"
                             " shared buffer session.")
                (list (make-client :stream stream)))))
          (t (send-package "Error in format." (list stream))))))

(defun shared-buffer-server (host)
  "Starts a server for the emacs extension shared-buffer."
  (setf *client-groups* (make-hash-table :test #'equal))
  (usocket:socket-server host +port+
                         #'handler nil
                         :in-new-thread t
                         :reuse-address t
                         :multi-threading t))

(defvar *server* (shared-buffer-server "localhost"))
