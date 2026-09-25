#!/bin/sh
# mutation-check.sh --- do the tests actually bite?
#
# The suite passing proves nothing unless it would FAIL on the bugs it exists to
# catch.  Each mutant below breaks one of the traps the package was written
# around -- the shr keymap write, the empty-field guard, the exact "@ref "
# prefix, the shr-link TAB retarget, and the `[tab]' vector bindings -- and the
# suite must go red for each.  It refuses to run at all while the unmutated
# suite is red, because then every mutant looks caught.
#
# A mutant is the package with one substitution, in a throwaway directory beside
# a copy of the suite (the test file puts its own directory on `load-path').
#
# Run:  sh mutation-check.sh     Exit code is the verdict: 0 = all caught.

set -u

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

caught=0
missed=0

# The baseline first.  A suite that is already red makes every mutant look
# caught -- and the failure lines then name whichever test is broken rather than
# the mutation, which reads as a clean sweep.  Seen for real on 2026-09-26: one
# broken assertion in one test made all five mutants report CAUGHT.
base="$work/baseline"
mkdir -p "$base"
cp "$here/julia-help.el" "$here/julia-help-test.el" "$base/"
if ! emacs -Q --batch -L "$base" -l "$base/julia-help-test.el" > "$base/out" 2>&1; then
    echo "BASELINE IS RED -- the unmutated suite fails, so nothing below would mean anything:"
    grep 'FAILED' "$base/out" | sed 's/^/  /'
    exit 2
fi

mutant () {
    name=$1
    expr=$2
    dir="$work/$name"
    mkdir -p "$dir"

    sed "$expr" "$here/julia-help.el" > "$dir/julia-help.el"
    cp "$here/julia-help-test.el" "$dir/"

    if cmp -s "$here/julia-help.el" "$dir/julia-help.el"; then
        echo "SKIP    $name -- the substitution did not apply, so nothing was tested"
        return
    fi

    if emacs -Q --batch -L "$dir" -l "$dir/julia-help-test.el" > "$dir/out" 2>&1; then
        echo "MISS    $name -- the suite PASSED on a mutated package"
        missed=$((missed + 1))
    else
        failed=$(grep 'FAILED' "$dir/out" | grep -o 'julia-help-test-[a-z-]*' | sort -u | tr '\n' ' ')
        if [ -z "$failed" ]; then
            # A run that died without a failing TEST proves nothing.  Seen for
            # real: an unbalanced test file made every mutant "fail", and this
            # printed CAUGHT with an empty name for all four.
            echo "SUSPECT $name -- failed without naming a test; a broken test file looks like a catch"
            missed=$((missed + 1))
        else
            echo "CAUGHT  $name -- by: $failed"
            caught=$((caught + 1))
        fi
    fi
}

# Replaces the `put-text-property' with a bare closing paren -- the keymap is
# never taken over, so SHR'S stays on the span.  Not `'keymap nil', which was
# the first spelling and is a different bug: nil *removes* shr's keymap as well,
# so RET falls through to the mode map and still works.  That unfaithful version
# passed the moment the fixture became a real doc buffer with a mode map.
mutant shr-keymap   "/put-text-property pos end 'keymap button-map/{s/.*/              )/}"
mutant empty-field  '/not (equal value ""))/d'
mutant loose-prefix 's/((string-prefix-p "@ref " href) (substring href 5))/((string-prefix-p "@ref" href) (substring href 4))/'
# The property is never the symbol `not-shr-map', so this really disables the
# retarget.  First written as `nil', which INVERTS it -- true wherever there is
# no keymap -- and still produced `forward-button', so it read as a caught
# mutation when it proved nothing.
mutant shr-tab-keys "s/pos 'keymap) shr-map)/pos 'keymap) 'not-shr-map)/"
# Deletes the two `[tab]' bindings, leaving only the "\t" ones -- exactly the
# state that looked correct to `key-binding' on the string form while the real
# TAB key ran something else.
mutant tab-vector-form '/define-key map \[tab\]/d'

echo
echo "caught $caught, missed $missed"
[ "$missed" -eq 0 ]
