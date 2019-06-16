;
; lg-compare.scm -- Compare parses from two different LG dictionaries.
;
; -----------------------------------------------------------------
; Overview:
; ---------
; The general goal of the code here is to obtain the accuracy, recall
; and other statistics of a test-dictionary, compared to a gold-standard
; dictionary. This is done by creating a comparison function that can
; parse sentences with both dictionaries, and then verifies the presence
; or absence of links between words.
;
(use-modules (srfi srfi-1))
(use-modules (opencog) (opencog exec) (opencog nlp))
(use-modules (opencog nlp lg-dict) (opencog nlp lg-parse))


(define-public (make-lg-comparator en-dict other-dict)
"
  lg-compare GOLD-DICT OTHER-DICT - Return a sentence comparison function.

  GOLD-DICT and OTHER-DICT should be the two LgDictNodes to compare.
  The code makes weak assumptions that GOLD-DICT is the reference or
  \"golden\" lexis to compare to, so that any differences found in
  OTHER-DICT are blamed on OTHER-DICT.

  This returns a comparison function.  To use it, pass one or more
  sentence strings to it; it will compare the resulting parses.
  When finished, pass it `#f`, and it will print a summary report.

  Example usage:
     (define compare (make-lg-comparator
        (LgDictNode \"en\") (LgDictNode \"micro-fuzz\")))
     (compare \"I saw her face\")
     (compare \"I swooned to the floor\")
     (compare #f)
"
	; -------------------
	; Stats we are keeping
	(define total-compares 0)
	(define total-words 0)
	(define total-links 0)
	(define length-miscompares 0)
	(define word-miscompares 0)
	(define link-count-miscompares 0)
	(define missing-links 0)
	(define extra-links 0)
	(define missing-link-types '())

	; ----------------------------------------
	; Misc utilities

	; Get the word of the word instance, i.e. the WordNode.
	(define (get-word-of-winst WRD)
		(gdr (car (cog-incoming-by-type WRD 'ReferenceLink))))

	; Get the index of the word instance, i.e. the NumberNode.
	(define (get-index-of-winst WRD)
		(gdr (car (cog-incoming-by-type WRD 'WordSequenceLink))))

	; ------
	; Place the word-instance list into sequential order.
	; i.e. left-to-right order, as the word appear in a sentence.
	(define (sort-word-inst-list LST)
		(sort LST
			(lambda (wa wb)
				(define (get-num wi)
					(string->number (cog-name (get-index-of-winst wi))))
				(< (get-num wa) (get-num wb)))))

	; ------
	; Return a sorted list of the other word-instances that this
	; word links to. To avoid double-counting, this returns only the
	; links connecting to the right.
	(define (get-linked-winst WIN)
		(sort-word-inst-list
			(map gdr
				; Accept only those ListLinks that are bonfide word-links
				(filter
					(lambda (lili)
						(and
							; Is the first word (left word) ours?
							(equal? (gar lili) WIN)
							; Are any of the possible EvaluationLink's
							; an LG relation? If so, we are happy.
							(any
								(lambda (evlnk)
									(equal? 'LinkGrammarRelationshipNode
										(cog-type (gar evlnk))))
								(cog-incoming-by-type lili 'EvaluationLink))
						))
					(cog-incoming-by-type WIN 'ListLink)))))

	; ------
	; Return the name of a link connecting lwin (left word
	; instance) and rwin (right word instance). There must actually
	; be a link connecting them, else bad things happen.
	(define (get-link-name lwin rwin)
		(gar (car (filter
			(lambda (evl)
				(equal? (cog-type (gar evl)) 'LinkGrammarRelationshipNode))
			(cog-incoming-by-type (ListLink lwin rwin)
				'EvaluationLink)))))

	; Return the string-name of a link. Truncate link subtypes.
	(define (get-link-str-name lwin rwin)
		(string-trim-right
			(cog-name (get-link-name lwin rwin))
			(char-set-adjoin char-set:lower-case #\*)))

	; ------
	; Increment count for a missing link type
	(define (incr-link-str-count link-name)
		(define cnt (assoc-ref missing-link-types link-name))
		(if (not cnt) (set! cnt 0))
		(set! missing-link-types
			(assoc-set! missing-link-types link-name (+ 1 cnt))))

	(define (incr-link-count lwin rwin)
		(incr-link-str-count (get-link-str-name lwin rwin)))

	; ----------------------------------------
	; Comparison functions

	; The length of the sentences should match.
	(define (compare-lengths en-sorted other-sorted)
		(define ewlilen (length en-sorted))
		(define owlilen (length other-sorted))

		(set! total-words (+ total-words ewlilen))

		; Both should have the same length, assuming the clever
		; English tokenizer hasn't tripped.
		(if (not (equal? ewlilen owlilen))
			(begin
				(format #t "Length miscompare: ~A vs ~A\n" ewlilen owlilen)
				(set! length-miscompares (+ 1 length-miscompares)))))

	; ---
	; The words should compare. We are not currently comparing the
	; sequence; doing so would be complicated, and I don't see how
	; the sequences could ever mis-compare...
	(define (compare-words ewrd owrd)
		(if (not (equal? (get-word-of-winst ewrd) (get-word-of-winst owrd)))
			(begin
				(format #t "Word miscompare at ~A: ~A vs ~A\n"
					(get-index-of-winst ewrd)
					(get-word-of-winst ewrd) (get-word-of-winst owrd))
				(set! word-miscompares (+ 1 word-miscompares)))))

	; ---
	; Compare links. For the given words, find the words that link to
	; the right. Verify that there are the same number of them, and
	; that they have the same targets.
	; ewin should be a word-instance from the EN side
	; owin should be the OTHER word instance.
	(define (compare-links ewin owin)
		(define ewrd (get-word-of-winst ewin))
		(define elinked (get-linked-winst ewin))
		(define olinked (get-linked-winst owin))
		(define elinked-len (length elinked))
		(define olinked-len (length olinked))

		; Obtain sets of the links words (not the word-instances)
		(define ewords (map get-word-of-winst elinked))
		(define owords (map get-word-of-winst olinked))

		; A set of words in ewords that are not in owords
		(define miss-w (lset-difference equal? ewords owords))

		; Keep only word-instances that are in the word-set.
		(define (trim-wili wili wrd-set)
			(filter
				(lambda (wi)
					(any
						(lambda (wrd) (equal? (get-word-of-winst wi) wrd))
						wrd-set))
				wili))

		; Missing linked word-instances...
		(define missing-wi (trim-wili elinked miss-w))

		; Keep statistics
		(set! total-links (+ total-links elinked-len))
		(if (< elinked-len olinked-len)
			(set! extra-links (+ extra-links (- olinked-len elinked-len)))
			(set! missing-links (+ missing-links (- elinked-len olinked-len))))

		; Compare number of links
		(if (not (equal? elinked-len olinked-len))
			(begin
				(format #t "Miscompare number of right-links: ~A vs ~A for ~A"
					elinked-len olinked-len ewrd)
				(set! link-count-miscompares (+ 1 link-count-miscompares))))

		; Make a note of missing link types.
		(for-each
			(lambda (misw) (incr-link-count ewin misw))
			missing-wi)
	)

	; -------------------
	; The main comparison function
	(define (do-compare SENT)
		; Get a parse, one for each dictionary.
		(define en-sent (cog-execute!
			(LgParseLink (PhraseNode SENT) en-dict (NumberNode 1))))
		(define other-sent (cog-execute!
			(LgParseLink (PhraseNode SENT) other-dict (NumberNode 1))))

		; Since only one parse, we expect only one...
		(define en-parse (gar (car
			(cog-incoming-by-type en-sent 'ParseLink))))
		(define other-parse (gar (car
			(cog-incoming-by-type other-sent 'ParseLink))))

		; Get a list of the words in each parse.
		(define other-word-inst-list
			(map gar (cog-incoming-by-type other-parse 'WordInstanceLink)))

		(define left-wall (WordNode "###LEFT-WALL###"))
		(define right-wall (WordNode "###RIGHT-WALL###"))

		; Get the list of words in the standard dict.
		; XXX Temp hack. Currently, the test dicts are missing LEFT-WALL
		; and RIGHT-WALL and so we filter these out manually. This
		; should be made more elegant.
		(define en-word-inst-list
			(filter
				(lambda (winst)
					(define wrd (get-word-of-winst winst))
					(and
						(not (equal? wrd left-wall))
						(not (equal? wrd right-wall))))
				(map gar (cog-incoming-by-type en-parse 'WordInstanceLink))))

		; Sort into sequential order. Pain-in-the-neck. Hardly worth it.
		(define en-sorted (sort-word-inst-list en-word-inst-list))
		(define other-sorted (sort-word-inst-list other-word-inst-list))

		(set! total-compares (+ total-compares 1))

		; Compare sentence lengths
		(compare-lengths en-sorted other-sorted)

		; Compare words and links
		(for-each
			(lambda (ewrd owrd)
				(compare-words ewrd owrd)
				(compare-links ewrd owrd)
			)
			en-sorted other-sorted)

		(format #t "Finish compare of sentence ~A: \"~A\"\n"
			total-compares SENT)
	)

	; -------------------
	(define (report-stats)
		(format #t "Finished comparing ~A parses (~A words, ~A links)\n"
			total-compares total-words total-links)
		(format #t "Found ~A length-miscompares\n" length-miscompares)
		(format #t "Found ~A word-miscompares\n" word-miscompares)
		(format #t
			"Found ~A link-count miscompares with ~A missing and ~A extra links\n"
			link-count-miscompares
			missing-links extra-links)
		(format #t "Missing link-type counts: ~A\n" missing-link-types)
	)

	; -------------------
	; The main comparison function
	(lambda (SENT)
		(if (not SENT)
			(report-stats)
			(do-compare SENT)))
)
