(in-package #:cl-stack-code)

;;; H3e-2b (0.16.0), part 2: what the servers add to the model's context
;;; besides their tools (their instructions), and how a large tool set is
;;; offered (deferred behind tool_search). Brief: cl-stack
;;; docs/capabilities/cl-stack-code.md, "H3e-2b — locked". Part 1 (sampling,
;;; elicitation) is src/mcp-requests.lisp. This file also amends
;;; src/mcp.lisp's snapshot, objects and /mcp lines (below); the
;;; implementation edits them there.
;;;
;;; SERVER INSTRUCTIONS
;;;   MCP-CONNECTION-INSTRUCTIONS connection → the text for the prompt, or NIL:
;;;     NIL unless the connection is :CONNECTED and its config passes
;;;     MCP-SERVER-INCLUDES-INSTRUCTIONS-P with the connection's approval (a
;;;     connected project or local server was approved: trusted servers unless
;;;     "includeInstructions" is false; project and local servers only when it
;;;     is true). Otherwise the client's
;;;     MCP-PROTOCOL:MCP-CLIENT-INSTRUCTIONS (initialize's, or
;;;     server/discover's, "instructions"): not a string, or blank → NIL;
;;;     trimmed of whitespace; longer than +MAX-MCP-INSTRUCTIONS-CHARS+ → its
;;;     first +MAX-MCP-INSTRUCTIONS-CHARS+ characters, LF, "[truncated]".
;;;   MCP-INSTRUCTION-BLOCK name text →
;;;     "<mcp-instructions server=\"NAME\">" LF TEXT LF "</mcp-instructions>",
;;;     with & < > " in NAME written &amp; &lt; &gt; &quot;.
;;;   Snapshot: each server entry's :INSTRUCTIONS (H3e-2a kept it NIL) is
;;;     INTERN-INSTRUCTION-TEXT of MCP-CONNECTION-INSTRUCTIONS, or NIL. A
;;;     reconnect that brings other instructions commits a new revision, as any
;;;     change of the snapshot.
;;;   MCP-INSTRUCTION-BLOCKS store id → the blocks of revision ID: for each
;;;     :mcp-servers entry with :INSTRUCTIONS, in snapshot order,
;;;     MCP-INSTRUCTION-BLOCK of its :NAME and the INSTRUCTION-TEXT; NIL when
;;;     the revision has no such entry (or no :mcp-servers role).
;;;   The system prompt: ASSEMBLE-SYSTEM-PROMPT with an :INSTRUCTION-SET adds
;;;     MCP-INSTRUCTION-BLOCKS of its current revision as its LAST sections,
;;;     after appendSystemPrompt. Everything before them (the base prompt, the
;;;     environment, the instruction files, rules, skills, appendSystemPrompt)
;;;     is byte for byte what it is without servers, so the provider's cached
;;;     prefix survives a change of the servers.
;;;   When: the prompt is rendered when a run starts, as all of it. -p and the
;;;     SDK render it after START-MCP-SERVERS settled; the TUI renders it again
;;;     when its background start settles, if no run started yet. A server that
;;;     connects later (ADD-MCP-SERVERS, /mcp reconnect, a lazy restore) joins
;;;     at the next run start (a new session, /clear, a rewind, a mode switch);
;;;     until then only its tools are offered. A rewind or a fork renders the
;;;     revision it continues (H3e-1's rule), so the model sees what it saw.
;;;
;;; DEFERRED TOOL LOADING (ai-agent-protocol 0.17.0: DEFERRED-TOOL-SOURCE,
;;; egao1980/ai-agent-protocol H3e-2b issue; brief ai-agent.md "0.17.0")
;;;   MCP-MANAGER-TOOL-SOURCE returns H3e-2a's source wrapped once:
;;;     (agent:make-deferred-tool-source <the 0.13 source>
;;;       :mode MODE :threshold THRESHOLD          ; MCP-TOOL-SEARCH-SETTINGS
;;;       :keep (lambda (context tool) …)          ; true for alwaysLoad servers' tools
;;;       :search-tool-name +TOOL-SEARCH-TOOL-NAME+
;;;       :on-load (lambda (names &key via) …))    ; a commit is owed
;;;   and nothing else in the product deals with deferral. The stack's rules,
;;;   as the product relies on them: deferral is on when MODE is :ALWAYS and a
;;;   tool can be deferred, or :AUTO and more than THRESHOLD can; :NEVER is the
;;;   inner source. While on, the listing is the inner listing without the
;;;   deferred tools not loaded yet, then tool_search, last. tool_search
;;;   {"query": string, "max_results": integer 1..20, default 5}: "select:A,B"
;;;   loads exactly those names; other text ranks the deferred tools by the
;;;   query's words in their names and descriptions; the matches are loaded and
;;;   listed in the result ("NAME: DESCRIPTION" lines), and the next step offers
;;;   them. It never asks (no approval, read-only: plan mode runs it); a deny
;;;   rule hides it as any tool. A deferred tool not loaded can still be called
;;;   by its exact (prefixed) name (decided by the user, 2026-11-23: a skill or
;;;   instructions may name it directly): the call goes through the normal
;;;   permission path (its rules, the ask default, -p's denial, plan mode), and
;;;   a call that runs loads the tool (ON-LOAD :VIA :CALL), recorded and
;;;   restored as a tool_search load is; a denied call loads nothing. A name no
;;;   server offers stays an unknown tool. A loaded tool is an MCP tool as
;;;   before.
;;;   The loaded set lives as long as the session's manager (every turn and
;;;   run of the session) and only grows, except by a restore. It is part of
;;;   the instruction set:
;;;   Snapshot: each server entry gains :DEFERRED (T when its tools were behind
;;;     tool_search at the commit) and :LOADED (the server's own names of its
;;;     loaded tools, in the server's order; NIL when not deferred). The entry
;;;     is (:name :scope :transport :config :status :tools :instructions
;;;     :deferred :loaded), in that order.
;;;   Commits: a load (by tool_search or by a call) owes a commit (made before
;;;     the next model call, as a list_changed is).
;;;   Restore: the loaded set becomes the revision's (MCP-TOOL-NAME of each
;;;     :LOADED name of each entry): a tool the revision had loaded is offered
;;;     again, one loaded after it is deferred again.
;;;
;;; VISIBILITY
;;;   MCP-CONNECTION-OBJECT gains "sampling" (the server may sample: its
;;;   config opts in), "elicitation" (its config allows it), "instructions"
;;;   (MCP-CONNECTION-INSTRUCTIONS is not NIL), "deferred" (its tools are
;;;   behind tool_search now), "loaded" (the prefixed names loaded, server
;;;   order; [] when none). So mcp/list, CLIENT-MCP-SERVERS and the init
;;;   event's "mcp_servers" have them.
;;;   The init event (-p stream-json, CODE-SESSION-INIT) gains, when at least
;;;   one server is configured, MCP-TOOL-SEARCH-OBJECT manager:
;;;   {"mode": "auto" | "always" | "never", "threshold": N, "active": bool,
;;;   "deferred": the number of deferred tools not loaded}; its "tools" are
;;;   the offered names (tool_search last while active).
;;;   MCP-STATUS-LINES: a connected server's line gains, in this order,
;;;   " · sampling" when "sampling" is true, " · instructions" when
;;;   "instructions" is, " · deferred (K loaded)" when "deferred" is; an
;;;   object without these keys (0.13's) prints as before.
;;;   ACP: tool_search's tool kind is "search" (src/acp/mapping.lisp).
;;;
;;; Non-goals: instructions of project and local servers that are not
;;; approved or not opted in; refreshing a running run's system prompt;
;;; deferring built-in tools; a load event (tool_search's result and the call
;;; itself show it);
;;; embeddings or BM25 for tool_search (the stack's ranking is words).

;;; Given: constants.

(defparameter +max-mcp-instructions-chars+ 8000
  "The longest server instructions text that goes into the prompt whole.")

(defparameter +tool-search-tool-name+ "tool_search"
  "The name of the tool that loads deferred MCP tools.")

;;; Stubbed (the header's rules).

(defun mcp-connection-instructions (connection)
  "→ CONNECTION's server instructions for the prompt, or NIL."
  (let ((client (mcp-connection-client connection)))
    (when (and client
               (eq :connected (mcp-connection-status connection))
               ;; Only approved project and local servers connect.
               (mcp-server-includes-instructions-p (mcp-connection-config connection)
                                                   :approval :approved))
      (let ((text (mcp-protocol:mcp-client-instructions client)))
        (when (stringp text)
          (let ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline #\Page) text)))
            (cond ((zerop (length trimmed)) nil)
                  ((> (length trimmed) +max-mcp-instructions-chars+)
                   (format nil "~a~%[truncated]" (subseq trimmed 0 +max-mcp-instructions-chars+)))
                  (t trimmed))))))))

(defun mcp-instruction-block (name text)
  "→ the <mcp-instructions server=\"NAME\"> block of TEXT."
  (format nil "<mcp-instructions server=\"~a\">~%~a~%</mcp-instructions>"
          (with-output-to-string (s)
            (loop for c across name
                  do (case c
                       (#\& (write-string "&amp;" s))
                       (#\< (write-string "&lt;" s))
                       (#\> (write-string "&gt;" s))
                       (#\" (write-string "&quot;" s))
                       (t (write-char c s)))))
          text))

(defun mcp-instruction-blocks (store id)
  "→ the MCP instruction blocks of revision ID of STORE, in snapshot order."
  (loop for entry in (cdr (assoc :mcp-servers (read-instruction-set store id)))
        for hash = (getf entry :instructions)
        when hash
          collect (mcp-instruction-block (getf entry :name) (instruction-text store hash))))

(defun mcp-tool-search-object (manager)
  "→ the init event's \"mcp_tool_search\" object of MANAGER."
  (multiple-value-bind (mode threshold) (mcp-tool-search-settings (mcp-manager-settings manager))
    (let ((deferred (%mcp-deferred-source manager)))
      (%json-object "mode" (string-downcase (symbol-name mode))
                    "threshold" threshold
                    "active" (and deferred (agent:deferred-tool-source-active-p deferred) t)
                    "deferred" (if deferred
                                   (length (agent:deferred-tool-source-deferred deferred))
                                   0)))))

;;; Exports.

(export '(+max-mcp-instructions-chars+ +tool-search-tool-name+
          mcp-connection-instructions mcp-instruction-block mcp-instruction-blocks
          mcp-tool-search-object))
