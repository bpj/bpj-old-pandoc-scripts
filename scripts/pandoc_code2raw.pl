#!/usr/bin/env perl
use strict;
use warnings;

# A Pandoc filter to convert Code/Codeblock elements with an attribute
# raw=<format> into a <format> RawInline/RawBlock element, e.g.
#
#   ```{raw=latex}
#   \begin{foo}
#   ```
#
#   *   Some text with _markdown_ markup.
#   *   Will be visible **as markdown** to pandoc.
#   *   Still it will be wrapped in a foo environment
#       in [LaTeX][] output!
#
#   [LaTeX]: <http://en.wikipedia.org/wiki/LaTeX>
#
#   ```{raw=latex}
#   \end{foo}
#   ```

no warnings qw[uninitialized numeric];

no autovivification;
no indirect;

use JSON qw[ decode_json encode_json ];
use Data::Rmap qw[ rmap_hash ];

my $format = shift @ARGV;

my $data = decode_json do{ local $/; <>; };

# Change data in-place
rmap_hash {
    my $href = $_;
    return unless $href->{t} =~ /\ACode(Block)?\z/;
    my $type = $1 || 'Inline';
    return unless my($kv) = grep { 'raw' eq $_->[0] } @{$href->{c}[0][2]};
    $href->{t} = "Raw$type";
    $href->{c}[0] = $kv->[1];
} $data;

print encode_json $data;

__END__
