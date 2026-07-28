EMACS ?= emacs
ELISP = eshell-nix-shell.el
TESTS = eshell-nix-shell-tests.el

.PHONY: all compile checkdoc package-lint test clean

all: compile checkdoc package-lint test

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(ELISP) $(TESTS)

checkdoc:
	$(EMACS) -Q --batch -L . \
	  --eval '(progn (require (quote checkdoc)) (checkdoc-file "$(ELISP)"))'

package-lint:
	$(EMACS) -Q --batch -L . -l package-lint \
	  --eval '(package-lint-batch-and-exit)' $(ELISP)

test:
	$(EMACS) -Q --batch -L . \
	  -l $(TESTS) -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc
