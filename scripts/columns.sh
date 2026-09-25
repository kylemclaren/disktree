#!/bin/sh
# Every line of the given files longer than 80 characters, by file and line;
# fails when there is one.
#
#   scripts/columns.sh FILE...
#
# `make lint` runs this after `swift format lint`, which cannot rewrap a
# comment or a string and so lets a long one through. Characters, not bytes:
# `⌘` and `—` are one column each.
exec perl -CSD -ne '
    chomp;
    if (length > 80) {
        print "$ARGV:$.: " . length . " columns, over 80\n";
        $long = 1;
    }
    close ARGV if eof;
    END { exit($long ? 1 : 0) }
' "$@"
