#!/usr/bin/env perl
# use 5.014;
use strict;
use warnings;
no warnings qw[ uninitialized numeric ];

use utf8;  # No UTF-8 I/O with JSON!


=encoding UTF-8

=head1 NAME

C<pandoc-no-header-span-ids.pl> - pandoc filter to make sure spans embedded in headers have no id.

=head1 VERSION

0.003

=head1 SYNOPSIS

    pandoc --to=latex -F pandoc-no-header-span-ids.pl [OPTIONS] [FILE]...

=head1 DESCRIPTION

Works around a pandoc bug where spans with an id inside a header causes
invalid LaTeX to be generated, by transferring the span's id to the header,
I<unless> there is a metadata entry C<< -M keep_header_ids=true >>.
It is especially useful when you convert HTML fetched from the Web.

=head2 Warning

You should run this filter after any other filters which rely on span ids!

=head1 OPTIONS

You can pass options to the filter as Pandoc metadata values:

    -M <option>=<value>

Currently all the options expect boolean values C<true> or C<false>.

The currently recognised options are:

=over

=item C<< -M keep_header_ids=<true|false> >>

Don't replace the ids of headers with the id of the first contained span, if any.

=item C<< -M optimize_attrless=<true|false> >>

Optimize away divs and spans which have no attributes,
replacing them with their contents in their parent's
contents.

B<WARNING:> This affects I<all> divs and spans in the whole document,
not just those which have had their id removed by this filter!

=back

=cut

# use autodie 2.12;

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

my %opt;

for my $name ( qw [ keep_header_ids optimize_attrless ] ) {
    next unless exists( $doc->[0]{unMeta}{$name} );
    ( $opt{$name} ) = rmap_hash {
        return unless is_elem( $_, 'MetaBool' );
        cut $_->{c};
    } $doc->[0]{unMeta}{$name};
}


# Change elements in-place:
rmap_hash {
    return unless is_elem( $_, 'Header' );
    my $ret = fix_spans_in_header( $_ );
    return;
} $doc;

if ( $opt{optimize_attrless} ) {
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
}

print {*STDOUT} $JSON->encode( $doc );

sub fix_spans_in_header {
    my($header) = @_;
    my $header_id = \$header->{c}[-2][0];
    my($id) = # Change elements in-place:
    rmap_hash {
        return unless is_elem( $_, qw[ Span ] );
        my $span = $_;
        my $span_id = \$span->{c}[-2][0];
        return unless $$span_id;
        # Transfer span attrs if any to the header
        $$header_id = $$span_id unless $opt{keep_header_ids};
        $$span_id = q{};
        cut; # Already saw a span with id!
    } $header;
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
