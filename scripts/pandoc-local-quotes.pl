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

use utf8;    # No UTF-8 I/O with JSON.pm!

binmode STDERR, ':utf8';

use autodie 2.12;

no indirect;
no autovivification;    # Don't pullute the AST!

# use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case ];

use JSON qw[ decode_json encode_json ];
use Data::Rmap qw[ rmap_hash rmap_array cut ];    # Data structure traversal support.
use List::MoreUtils qw[ all firstval ];
use List::UtilsBy qw[ extract_by rev_nsort_by ];
use Scalar::Util qw[refaddr];
use HTML::Entities qw[ decode_entities ];
use Encode qw[find_encoding];

sub _msg {
    my $msg = shift;
    $msg = sprintf $msg, @_ if @_;
    return $msg;
}

sub _die { die _msg( @_ ), "\n"; }

sub traverse_element_lists (&@);
sub get_meta_opts;

my $to_format = shift @ARGV;

my $doc = decode_json do { local $/; <>; };

my $latin1 = find_encoding( 'Latin-1' ) or _die "Couldn't find encoding Latin-1";

# Gather options from the document metadata:    # {{{1}}}

my $option = get_meta_opts +{
    doc    => $doc,
    opts   => [qw[ quotes subst quote_styles subst_styles delete_attr ]],
    prefix => 'punct_',
};

rmap_hash {
    my $href = $_;
    {
        local $_;
        %$href
          = map { ref( $_ ) ? $_ : utf8::is_utf8( $_ ) ? $_ : $latin1->decode( $_ ) }
          map { /\&[^;]+;/ ? decode_entities( $_ ) : $_ } %$href;
    }
} ## end rmap_hash
$option;

# warn encode_json($option);

use vars qw[ $Quote $Subst $Regex  %Data ];
$Quote = {
    '“' => _mk_elem( Str => '“' ),
    '”' => _mk_elem( Str => '”' ),
    '‘' => _mk_elem( Str => '‘' ),
    '’' => _mk_elem( Str => '’' ),
};

my %quote_for = (
    DoubleQuote => +{ start => '“', end => '”', },
    SingleQuote => +{ start => '‘', end => '’', },
);

my $delete = $option->{punct_delete_attr};

{
  DATA:
    for my $key ( qw[ quotes subst ] ) {
        my $style_key = "$key\_styles";
        my $styles = $option->{$style_key} || +{};
        'HASH' eq ref( $styles ) and all { 'HASH' eq ref $_ } values %$styles
          or _die "metadata $style_key must be mapping of mappings";
        $Data{$key} = $styles;
        my $default = $option->{$key};
        $default ||= 'default' if exists $styles->{default};
        next DATA unless defined $default;
        exists $Data{$key}{$default}
          or _die "metadata $key must be key from $style_key";
        $Data{default}{$key} = $default;
    } ## end DATA: for my $key ( qw[ quotes subst ])
    for my $style ( grep { defined } values %{ $Data{quotes} } ) {
      QUOTE:
        for my $quote ( values %$style ) {
            next QUOTE if ref $quote;
            $quote = _mk_elem( Str => $quote );
        }
    } ## end for my $style ( grep { ...})
    while ( my ( $style, $data ) = each %{ $Data{subst} } ) {
        my @keys = map { quotemeta } rev_nsort_by { length } keys %$data;
        local $" = ')|(?:';
        $Data{regex}{$style} = qr/((?:@keys))/;
    }
    $Quote = $Data{quotes}{ $Data{default}{quotes} } if $Data{default}{quotes};
    $Subst = $Data{subst}{ $Data{default}{subst} }   if $Data{default}{subst};
    $Regex = $Data{regex}{ $Data{default}{subst} }   if $Data{default}{subst};
}

traverse_element_lists {
    my ( $elem, $callback ) = @_;

    # my $elem = $_;
    my $t = $elem->{t};
    return $elem unless $t =~ /^(?:Span|Div|Quoted|Str)$/;
    my $c = $elem->{c};
    if ( 'Str' eq $t ) {
        return $elem unless $Regex;
        $c =~ s/$Regex/$Subst->{$1}/g and return _mk_elem( Str => $c );
        return $elem;
    }
    elsif ( $t =~ /Span|Div/ ) {
        my %local;
      STYLE:
        for my $key ( qw[ quotes subst ] ) {
            my ( $style );
            if ( $delete ) {
                ( $style ) = extract_by { $key eq $_->[0] } @{ $c->[-2][2] };
            }
            else {
                ( $style ) = firstval { $key eq $_->[0] } @{ $c->[-2][2] };
            }
            next STYLE unless $style;
            $style = $style->[1];
            _die "undefined $key style '$style'" unless exists $Data{$key}{$style};
            $local{$key} = $style;
        } ## end STYLE: for my $key ( qw[ quotes subst ])
        local $Quote = $Data{quotes}{ $local{quotes} } if $local{quotes};
        local $Subst = $Data{subst}{ $local{subst} }   if $local{subst};
        local $Regex = $Data{regex}{ $local{subst} }   if $local{subst};
        &traverse_element_lists( $callback, $elem );
        return $elem;
    } ## end elsif ( $t =~ /Span|Div/ )
    elsif ( 'Quoted' eq $t ) {
        my $type = $c->[0]{t};
        my $text = $c->[1];
        &traverse_element_lists( $callback, $text );
        my @ret = (
            $Quote->{ $quote_for{$type}{start} },    #
            @$text,                                  #
            $Quote->{ $quote_for{$type}{end} },      #
        );
        return @ret;
    } ## end elsif ( 'Quoted' eq $t )
    return $elem;
} ## end traverse_element_lists
$doc;

# die encode_json $doc;
print {*STDOUT} encode_json $doc;

# HELPER FUNCTIONS                              # {{{1}}}
sub _mk_elem {    # {{{2}}}
    my ( $type => $contents ) = @_;
    return +{ t => $type, c => $contents };
}

sub traverse_element_lists (&@) {    # {{{2}}}
    my ( $callback, @data ) = @_;

    # my %seen;
    rmap_array {
        my ( $rmap ) = @_;

        # $rmap->recurse;
        return unless all { 'HASH' eq uc ref $_ } @$_;
        my @origs = @$_;
        my @new;
        for my $orig ( @origs ) {

            # next if $seen{ refaddr $orig }++;
            my @ret = $callback->( $orig, $callback );
            next unless scalar @ret;
            push @new, @ret;
        } ## end for my $orig ( @origs )
        @$_ = @new;
        return;
    } ## end rmap_array
    @data;
    return;
} ## end sub traverse_element_lists (&@)

# Getting options:                              # {{{2}}}

sub get_meta_opts {    # {{{3}}}
    my $p    = shift;
    my $doc  = $p->{doc};
    my $meta = $doc->[0]{unMeta};
    my %opt  = %{ $p->{default} || +{} };
    my @opts = @{ $p->{opts} || [] };
    my $pfx  = $p->{prefix} || q{};
    @opts = keys %opt unless @opts;
  OPT:

    for my $opt ( @opts ) {
        my $key = $pfx . $opt;
        next unless exists $meta->{$key};
        $opt{$opt} = _get_opt_val( $meta->{$key} );
    } ## end OPT: for my $opt ( @opts )
    return \%opt;
} ## end sub get_meta_opts

# Turn one pandoc metadata value into an option value # {{{3}}}
sub _get_opt_val {
    my ( $data ) = @_;
    if ( 'MetaMap' eq $data->{t} ) {
        return _get_opt_map( $data->{c} );
    }
    elsif ( 'MetaList' eq $data->{t} ) {
        return _get_opt_list( $data->{c} );
    }
    else {
        # Should we return a concatenation instead of
        # just the first string-ish contents value?
        my ( $opt ) = rmap_hash {
            if ( $_->{t} =~ /\A(?:Str|Meta(?:String|Bool))\z/ ) {
                cut $_->{c};
            }
            elsif ( $_->{t} =~ /\ACode(?:Block)?\z/ ) {
                cut $_->{c}[-1];
            }
            return;
        } ## end rmap_hash
        $data;
        return $opt;
    } ## end else [ if ( 'MetaMap' eq $data...)]
    return;
} ## end sub _get_opt_val

# Turn a pandoc metadata map into a plain hashref # {{{3}}}
sub _get_opt_map {
    my ( $href ) = @_;
    my %ret;
    while ( my ( $k, $v ) = each %$href ) {
        $ret{$k} = _get_opt_val( $v );
    }
    return \%ret;
} ## end sub _get_opt_map

# Turn a pandoc metadata list into a plain arrayref # {{{3}}}
sub _get_opt_list {
    my ( $aref ) = @_;
    my @ret = map { _get_opt_val( $_ ) } @$aref;
    return \@ret;
}

__END__
