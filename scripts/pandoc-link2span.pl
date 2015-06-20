#!/usr/bin/env perl
use 5.014;
use strict;
use warnings;
no warnings qw[ uninitialized numeric ];

use utf8;

# use autodie 2.12;

# no indirect;
# no autovivification;

use JSON::MaybeXS;
use Data::Rmap qw[ rmap_hash rmap_array cut ]; # Data structure traversal support.
use List::AllUtils 0.09 qw[ all none pairs ];
use Scalar::Util qw[ refaddr blessed ];
use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case no_auto_abbrev ];
use Pod::Usage;

GetOptionsFromArray(
    \@ARGV,
    'help|h'    => sub { pod2usage( -verbose => 1, -exit => 1 ) },
    'man|m'     => sub { pod2usage( -verbose => 3, -exit => 1 ) },
    'version|v' => sub {
        pod2usage(
            -verbose  => 99,
            -exit     => 1,
            -sections => 'NAME|VERSION|AUTHOR|LICENSE'
        );
    },
) or pod2usage( -verbose => 1, -exit => 2, -msg => 'Error getting options!' );

my( $dquoted, $squoted ) = qw[ \" \' ];
for my $quoted ( $dquoted, $squoted ) {
    my $q = $quoted;
    # match a double/single quoted string, using the doubled quote to escape the quote
    $quoted = qr{ $q ( (?: [^$q]* (?: $q$q [^$q]* )* )* ) $q }msx;
}

my $attr_re = qr{
    (?<!\S)         # Not preceded by non-whitespace
    (?: \#(\S+)     # an id
    |   \.(\S+)     # or a class
    |   # or an attr=value pair
        ([^\s\=]+)=(?=(.))(?:$dquoted|$squoted|(\S+)) 
    )
}msx;

# GET DOCUMENT	

my $to_format = shift @ARGV;

my $json = do { local $/; <>; };

my $JSON = JSON::MaybeXS->new( utf8 => 1 );

my $doc = $JSON->decode( $json );

rmap_hash {
    return unless is_elem( $_, 'Link');
    return unless '*' eq $_->{c}[-1][0];
    my $attr_str = $_->{c}[-1][1];
    my $text = $_->{c}[-2];
    $attr_str =~ s/\\(.)/$1/g;
    my($id, @class,@attrs);
    $id = q{};
    while ( $attr_str =~ /$attr_re/g ) {
        if ( length $1 ) {
            $id = $1;
        }
        elsif ( length $2 ) {
            push @class, $2;
        }
        elsif ( length $3 ) {
            my $key = $3;
            my $val = $+;
            my $q = $4;
            my $unquoted = $7;
            unless ( defined $unquoted ) {
                $val =~ s/\Q$q$q/$q/g;
            }
            push @attrs, [$key,$val];
        }
    }
    $_ = mk_elem( Span => [ [$id, \@class, \@attrs], $text ] );
} $doc;

print {*STDOUT} $JSON->encode( $doc );

# is_elem( $elem, ?@types );
sub is_elem {
    my ( $elem, @types ) = @_;
    return !!0 unless 'HASH' eq ref $elem;
    return !!0 unless exists $elem->{t};
    return !!0 unless exists $elem->{c};
    if ( @types ) {
        for my $type ( @types ) {
            return !!1 if $type eq $elem->{t}; # Tag matches
        }
        return !!0; # No type matched
    }
    return !!1; # No types supplied, all checks ok
} ## end sub is_elem

# mk_elem( $type => $contents );
sub mk_elem {
    my($type => $contents) = @_;
    return +{ t => $type, c => $contents };
}


__END__

# # DOCUMENTATION # #

=encoding UTF-8

=head1 NAME

pandoc-link2span.pl - filter which overloads link syntax to define spans.

=head1 VERSION

0.001

=head1 SYNOPSIS

    pandoc -F pandoc-link2span.pl [PANDOC-OPTIONS] FILE_NAME ...

=head1 DESCRIPTION

C<< pandoc-link2span.pl >> is a pandoc filter which overloads link
syntax to define spans.

You write a 'link' where the 'URL' is an asterisk (C<< * >>) and the
'title' is an attribute spec similar to that used with headers, fenced
code blocks or inline code:

    [foo bar](* "#foo .bar baz=biz buz="b&ouml;p" quo='it''s ok'")

This is actually converted into:

    <span id="foo" class="bar" baz="biz" buz="böp" quo="it's ok">foo bar</span>

Note that reference links do what you would expect:

    [quux blort][zigzag]

    [plugh xyzzy][zigzag]

    [zigzag]: * ".zig .zag"

    <span class="zig zag">quux blort</span>

    <span class="zig zag">plugh xyzzy</span>

=head2 The 'link'text'

The link text will become the content of the span. It can contain any
inline constructs I<< except links >>. This unfortunately means that you
also cannot include a similarly defined span inside the first one!

=head2 Quoting rules

Pandoc may have trouble with double quotes inside a title string, but
you can always escape them with backslashes for clarification. The
filter's parsing on the other hand is rather primitive, being based on a
regular expression. Attribute values which neither contain whitespace or
begin with a quote character can just be written wiithout any outer
quotes. You I<< can >> have multi-word attribute values (but not ids or
classes) by double- or single-quoting the value after the equals sign,
and quote marks of the 'opposite' kind are readily accepted inside such
values, but since backslash-escaped punctuation characters would be
resolved by pandoc -- and since second-level backslash-escaping
(C<< \\\" >>) may be hard to keep track of -- to have quote marks I<< of
the same kind >> inside such a value you have to I<< double the quote
mark >> (either single or double), but as you can see from these
examples you will probably still prefer to always use single quotes to
quote attribute values to avoid having repeated backslash-escaped double
quotes:

    [the text]( * "title='It''s ok'")

    <span title="It's ok">the text</span>

    [the text]( * "title=\"Plan \"\"B\"\"\"" )

    <span title="Plan &quot;B&quot;">the text</span>

    [the text]( * "title='Plan \"B\"'")

    <span title="Plan &quot;B&quot;">the text</span>

    [viz.](* "title=videlicet")

    <span title="videlicet">viz.</span>

=head1 AUTHOR

Benct Philip Jonsson E<lt>bpjonsson@gmail.comE<gt>, L<< https://github.com/bpj >>

=head1 COPYRIGHT

Copyright 2015- Benct Philip Jonsson

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

L<< http://pandoc.org >>

=cut
