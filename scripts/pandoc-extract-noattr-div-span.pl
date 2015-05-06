#!/usr/bin/env perl
use 5.014;
use strict;
use warnings FATAL => 'all';
no warnings qw[ uninitialized numeric ];

use utf8;
use autodie 2.12;

no indirect;
no autovivification;

use JSON::MaybeXS qw[ decode_json encode_json ];
use Scalar::Util qw[ blessed ];
use Data::Rmap qw[ rmap_array cut ];
use List::AllUtils qw[ none ];

use Data::Printer;

# HELPER FUNCTIONS                              # {{{1}}}
sub is_elem {                                   # {{{2}}}
    my ( $elem, @tags ) = @_;
    # p @_;
    return !!0 unless 'HASH' eq ref $elem;
    return !!0 unless exists $elem->{t};
    return !!0 unless exists $elem->{c};
    if ( @tags ) {
        for my $tag ( @tags ) {
            return !!1 if $tag eq $elem->{t};
        }
        return !!0;
    }
    return !!1;
} ## end sub is_elem

# READ IN JSON                                  # {{{1}}}
my $to_format = shift @ARGV;
my $doc = decode_json do { local $/; <>; };

rmap_array {
    my $aref = $_;
    {
        local $_;
        return if none { is_elem( $_, qw[ Div Span ] ) } @$aref;
    }
    my @ret;
    for my $elem ( @$aref ) {
        if ( is_elem( $elem, qw[ Div Span ] ) ) {
            if ( # Does it have any attributes?
                length( $elem->{c}[-2][0] )         # id
                or scalar( @{ $elem->{c}[-2][1] } ) # classes
                or scalar( @{ $elem->{c}[-2][2] } ) # key_vals
            ) {
                push @ret, $elem;
            }
            else {  # No attributes!
                push @ret, @{ $elem->{c}[-1] };  # Contents
            }
        }
        else {
            push @ret, $elem;
        }
    }
    $_ = \@ret;
} $doc;

print encode_json( $doc );


__END__
