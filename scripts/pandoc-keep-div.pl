#!/usr/bin/env perl

# You can set the following options in the document metadata:
# 
# ---
# # option: '`value`'    # description
#
#
# # For best performance wrap value in backticks *and* single quotes!
# ...
#
# or on the commandline:
#
# -M option='value'
#

# use 5.014;
use strict;
use warnings FATAL => 'all';
no warnings qw[ uninitialized numeric ];

use utf8;  # No UTF-8 I/O with JSON.pm!

use autodie 2.12;

no indirect;
no autovivification; # Don't pullute the AST!

# use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case ];

use JSON qw[ decode_json encode_json ];
use Data::Rmap qw[ rmap_hash rmap_array cut ]; # Data structure traversal support.
use List::AllUtils qw[ all any ];
use Scalar::Util qw[refaddr];

sub traverse_element_lists (&@);
sub get_meta_opts;

my $to_format = shift @ARGV;

# warn "read JSON";
my $doc = decode_json do { local $/; <>; };

# Gather options from the document metadata:    # {{{1}}}
# warn 'Gather options from the document metadata';

my $option = get_meta_opts(
    +{  doc     => $doc,        #
        opts    => [qw[ id class ]],    #
        default => +{ },         #
        prefix  => q{keep_div_},         #
    }
);

my $want_id = $option->{id};
my $want_class = $option->{class};
for my $var ( $want_id, $want_class ) {
    next unless defined $var;
    $var = [$var] unless 'ARRAY' eq ref $var;
}

# Traverse document:                            # {{{1}}}

# Change elements in-place:                     # {{{2}}}
# warn 'Change elements in-place';

my @divs = rmap_hash {
    return unless 'Div' eq $_->{t};
    return unless defined $_->{c};
    if ( $want_id ) {
        my $id = $_->{c}[-2][0];
        cut $_ if any { "$_" eq "$id" } @$want_id;
    }
    if ( $want_class ) {
        my $classes = $_->{c}[-2][1];
        for my $class ( @$classes ) {
            cut $_ if any { "$_" eq "$class" } @$want_class;
        }
    }
    return;
} $doc;

@{ $doc->[1] } = @divs;

# Change lists of elements in-place             # {{{2}}}

# traverse_element_lists {
#     return $_ unless '...' eq $_->{t};
#     return $_ unless defined $_->{c};
#     ...
# } $doc;

# warn 'print';
print {*STDOUT} encode_json $doc;

# HELPER FUNCTIONS                              # {{{1}}}
sub _mk_elem {	# {{{2}}}
    my($type => $contents) = @_;
    return +{ t => $type, c => $contents };
}

# sub traverse_element_lists (&@) {                   # {{{2}}}
#     my($callback, @data) = @_;
#     # my %seen;
#     rmap_array {
#         my($rmap) = @_;
#         $rmap->recurse;
#         return unless all { 'HASH' eq uc ref $_ } @$_;
#         my @origs = @$_;
#         my @new;
#         for my $orig ( @origs ) {
#             # next if $seen{ refaddr $orig }++;
#             local $_ = $orig;
#             my @ret = $callback->(@_);
#             next unless scalar @ret;
#             push @new, @ret;
#         }
#         $_ = \@new;
#         return;
#     } @data;
#     return;
# }

# Getting options:                              # {{{2}}}

sub get_meta_opts {                             # {{{3}}}
	my $p = shift;
	my $doc = $p->{doc};
	my $meta = $doc->[0]{unMeta};
	my %opt = %{ $p->{default} || +{} };
	my @opts = @{ $p->{opts} || [] };
	my $pfx = $p->{prefix} || q{};
	@opts = keys %opt unless @opts;
	OPT:
	for my $opt ( @opts ) {
		my $key = $pfx . $opt;
		next unless exists $meta->{$key};
		$opt{$opt} = _get_opt_val( $meta->{$key} );
	}
	return \%opt;
}

# Turn one pandoc metadata value into an option value # {{{3}}}
sub _get_opt_val {
	my($data) = @_;
	if ( 'MetaMap' eq $data->{t} ) {
		return _get_opt_map( $data->{c} );
	}
	elsif ( 'MetaList' eq $data->{t} ) {
		return _get_opt_list( $data->{c} );
	}
	else {
        # Should we return a concatenation instead of 
        # just the first string-ish contents value?
		my($opt) = rmap_hash {
			if ( $_->{t} =~ /\A(?:Str|Meta(?:String|Bool))\z/ ) {
				cut $_->{c};
			}
			elsif ( $_->{t} =~ /\ACode(?:Block)?\z/ ) {
				cut $_->{c}[-1];
			}
			return;
		} $data;
		return $opt;
	}
	return;
}

# Turn a pandoc metadata map into a plain hashref # {{{3}}}
sub _get_opt_map {
	my($href) = @_;
	my %ret;
	while ( my( $k, $v ) = each %$href ) {
		$ret{$k} = _get_opt_val($v);
	}
	return \%ret;
}

# Turn a pandoc metadata list into a plain arrayref # {{{3}}}
sub _get_opt_list {
	my( $aref ) = @_;
	my @ret = map { _get_opt_val($_) } @$aref;
	return \@ret;
}

# # Getting and setting attributes       # {{{2}}}
#
# sub _get_attrs_hash_for {	# {{{3}}}
#     my($elem) = @_;
#     my $attr_a = $elem->{c}[-2];
#     my($id, $classes, $key_vals) = @$attr_a;
#     tie my %attr => 'Tie::IxHash', map { @$_ } @$key_vals;
#     @attr{ qw[ __id__ __class__ ] } = ( $id, $classes );
#     if ( 'Header' eq $elem->{t} ) {
#         $attr{__header_level__} = $elem->{c}[-3];
#     }
#     return \%attr;
# }

# sub _get_attrs {	# {{{3}}}
#     my($attr, $default_level) = @_;
#     $attr->{class} ||= [];
#     die "'class' for $elem->{t} is not aref" unless 'ARRAY' eq ref $attr->{class};
#     my($header_level, $id, $class) = delete @{$attr}{ qw[ __header_level__ __id__ __class__ ] };
#     $header_level ||= $default_level and $header_level += 0;    # Force number
#     $id = "$id";                                                # Force string
#     my @class = map { "$_" } @{ 'ARRAY' eq ref $class ? $class : [$class] }; # Force array of strings
#     my @kvs = map_pairwise { [ "$a" => "$b" ] } %$attr; # Force array of pairs of strings
#     return( ($header_level || () ), [ $id, \@class, \@kvs ] );
# }

__END__
