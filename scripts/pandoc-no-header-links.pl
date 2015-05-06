#!/usr/bin/env perl
use 5.014;
use strict;
use warnings FATAL => 'all';
no warnings qw[ uninitialized numeric ];

use utf8;  # No UTF-8 I/O with JSON!

use autodie 2.12;

# no indirect;
# no autovivification; # Don't pullute the AST!

# use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case ];

use JSON::MaybeXS;
use Data::Rmap qw[ rmap_hash rmap_array cut ]; # Data structure traversal support.
use List::AllUtils 0.09 qw[ none pairs ];
use Scalar::Util qw[refaddr];

# GET DOCUMENT	

my $to_format = shift @ARGV;

my $json = do { local $/; <>; };

my $JSON = JSON::MaybeXS->new( utf8 => 1 );

my $doc = $JSON->decode( $json );

# Change elements in-place:
rmap_hash {
    return unless is_elem( $_, 'Header' );
    my $ret = fix_links_in_header( $_ );
    $_ = $ret if defined $ret;
    return;
} $doc;

# Replace spans/divs with no id/classes/attributes with their contents
# in their parents' content list.
# This is generally much more robust than trying to call callbacks on hashes
# while traversing with rmap_array!
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


print {*STDOUT} $JSON->encode( $doc );

sub fix_links_in_header {
    my($header) = @_;
    my @links = # Change elements in-place:
    rmap_hash {
        return unless is_elem( $_, qw[ Link Image ] );
        my $link = $_;
        my $text = $link->{c}[0];
        $_ = mk_attr_elem( Span => $text );
        return $link;
    } $header;
    return unless @links;
    @links = map { [ mk_elem( Plain => [$_] ) ] } @links;
    my $link_list = mk_elem( BulletList => \@links );
    return mk_attr_elem( Div => [ $header, $link_list ] );
}

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

# mk_attr_elem( $type, $contents, ?\%attr );
sub mk_attr_elem {
    my( $type, $contents, $attr ) = @_;
    $attr ||= +{};
    my @level = ( 0+$attr->{level} || () );
    my $id = $attr->{id} || "";
    my $class = $attr->{class} || [];
    my $key_val = $attr->{key_val} || +{};
    'ARRAY' eq uc ref($class) or $class = [$class];
    'HASH' eq uc ref($key_val)
        or die sprintf "Expected key_val to be hashref at %s, line %s.\n", @{[caller]}[1,2];
    my @kv = pairs %$key_val;
    return mk_elem( $type => [ @level, [$id,$class,\@kv], $contents ] );
}


__END__
