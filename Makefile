EMACS ?= emacs
.PHONY: all compile checkdoc package-lint test test-tramp clean

all: compile checkdoc package-lint test

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile eshell-nix-shell.el eshell-nix-shell-tests.el

checkdoc:
	$(EMACS) -Q --batch -L . \
	  --eval '(progn (require (quote checkdoc)) (checkdoc-file "eshell-nix-shell.el"))'

package-lint:
	$(EMACS) -Q --batch -L . \
	  --eval '(unless (require (quote package-lint) nil t) (message "package-lint unavailable; skipping") (kill-emacs 0))' \
	  --eval '(package-lint-batch-and-exit)' eshell-nix-shell.el

test:
	$(EMACS) -Q --batch -L . \
	  -l eshell-nix-shell-tests.el -f ert-run-tests-batch-and-exit

test-tramp:
	test -n "$(ENS_TRAMP_DIRECTORY)" || \
	  { echo "Set ENS_TRAMP_DIRECTORY to a writable Tramp directory" >&2; exit 2; }
	$(EMACS) -Q --batch -L . \
	  -l eshell-nix-shell-tests.el \
	  --eval '(ert-run-tests-batch-and-exit "^eshell-nix-shell-tramp-integration$$")'

clean:
	rm -f *.elc
