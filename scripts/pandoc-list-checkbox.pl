#!/usr/bin/env perl

=for Description:

=encoding UTF-8

 pandoc-list-checkbox.pl

 Pandoc <http://pandoc.org> filter to turn Github-style list
 checkboxes

 # OPTIONS

 You can set the following options in the document metadata:
 
 ```yaml
 ---
 # option      '`value`'  # description
 check_box   '`STRING`' 
             # '`x`'       => U+2612 BALLOT BOX WITH X:'☒'
             # '`c`'       => U+2611 BALLOT BOX WITH CHECK:'☑'
             # '`g`'       => '[x]' (Github style)
             # 0|False[^1] => '[x]'
             # Other char  => That char
             # Default     => '[x]'

 uncheck_box '`STRING`'  
             # '`b`'       => U+2610 BALLOT BOX:'☐'
             # '`g`'       => '[ ]' (Github style. Doesn't work with pandoc![^2])
             # '`nb`'      => '[&nbsp;]' (Works with Pandoc and Github!)
             # 0|False[^1] => '[&nbsp;]' (Works with Pandoc and Github!)
             # Other char  => That char
             # Default     => '[&nbsp;]' (Works with Pandoc and Github!)
             #               but `b` if check_box is `x` or `c`!

 # For best performance wrap value in backticks *and* single quotes!
 ...
```

 or on the commandline:

 -M option='value'

    pandoc -F pandoc-list-check_box.pl -M uncheck_box=g -t markdown_github

 [^1]: If *both* check_box and uncheck_box are False|zero
       then no conversion will be performed,
       so you must set one of them to a true value
 [^2]: You can use "[-]" instead of "[&nbsp;]" in your text and have it 
       converted to an actual non-breaking space with uncheck_box=nb

 

=cut

# use 5.014;
use strict;
use warnings FATAL => 'all';
no warnings qw[ uninitialized numeric ];

my $VERSION = '0.001000';

use utf8;  # No UTF-8 I/O with JSON.pm!

use autodie 2.12;

no indirect;
no autovivification; # Don't pullute the AST!

# use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case ];

use JSON qw[ decode_json encode_json ];
use Data::Rmap qw[ rmap_hash rmap_array cut ]; # Data structure traversal support.
use List::MoreUtils qw[ all none ];
use Scalar::Util qw[refaddr];
use charnames qw[ :full ];

sub rmap_element_lists (&@);

my $to_format = shift @ARGV;

my $json = do { local $/; <>; };
my $doc = decode_json $json;


# Gather options from the document metadata:    # {{{1}}}

my $meta_opt 
    = get_meta_opts( 
      +{ 
          doc => $doc, 
          opts => [ qw[ check_box uncheck_box ] ], 
          default => +{},
          prefix => q{},
      }
  );

if ( none { defined } values %$meta_opt ) {
    print $json;
    exit(0);
}
my @check;
$meta_opt->{uncheck_box} ||= 'b' if $meta_opt->{check_box} =~ /\A[cx]\z/;
for ( $meta_opt->{check_box} ) {
    $check[1]   = /^x$/ ?   "\N{BALLOT BOX WITH X}"
                : /^c$/ ?   "\N{BALLOT BOX WITH CHECK}"
                : /^g$/ ?   "[x]"
                : $_    ?   $_
                :           "[x]"
                ;
}
for ( $meta_opt->{uncheck_box} ) {
    $check[0]   = /^b$/ ?   "\N{BALLOT BOX}"
                : /^g$/ ?   "[\N{SPACE}]"
                : /^nb$/?   "[\N{NBSP}]"
                : $_    ?   $_
                :           "[\N{NBSP}]"
                ;
}

my $check_re = qr/\A(\[x\])|\[[-\s]\]\z/i;

# Traverse document:                            # {{{1}}}

# Change elements in-place:                     # {{{2}}}

rmap_hash {
    return unless $_->{t} =~ /\A(?:(Ordered)|Bullet)List\z/;
    return unless defined $_->{c};
    my $items = $1 ? $_->{c}[-1] : $_->{c};
    ITEM:
    for my $item ( @$items ) {
        my $first = $item->[0]{c}[0];
        next ITEM unless 'HASH' eq ref $first;  # Sanity check
        next ITEM unless 'Str' eq $first->{t};
        next ITEM unless $first->{c} =~ /$check_re/;
        $first->{c} = $check[$1?1:0];
    }
    return;
} $doc;


# Change lists of elements in-place             # {{{2}}}

# rmap_element_lists {
#     return $_ unless '...' eq $_->{t};
#     return $_ unless defined $_->{c};
#     ...
# } $doc;


print {*STDOUT} encode_json $doc;

# HELPER FUNCTIONS                              # {{{1}}}
sub _mk_elem {	# {{{2}}}
    my($type => $contents) = @_;
    return +{ t => $type, c => $contents };
}

# sub rmap_element_lists (&@) {                   # {{{2}}}
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
  
