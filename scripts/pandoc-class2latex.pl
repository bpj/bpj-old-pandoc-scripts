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
use List::AllUtils 0.09 qw[ none firstval ];
use Scalar::Util qw[refaddr];

# GET DOCUMENT	

my $to_format = shift @ARGV;

my $json = do { local $/; <>; };

# List of supported formats
print $json and exit 0 if none { $_ eq $to_format } qw[ latex html html5 ];

my $JSON = JSON::MaybeXS->new( utf8 => 1 );

my $doc = $JSON->decode( $json );

# Gather options from the document metadata: 
my $option = get_meta_opts(
    +{  doc	 => $doc,		  #
        opts	=> [qw( lang_map )],	#
        default => +{},			#
        prefix	=> q{},		 # \
    }
);

if ( $option->{lang_map} ) {
    'HASH' eq $option->{lang_map} or die "Expected lang_map to be mapping";
}
else {
    $option->{lang_map} = +{};
}
my $lang_map = $option->{lang_map};

# DISPATCH TABLE
#	*	Each main key is an element type
#	*	Each main value is a hashref
#		*	Keys are target format names
#			*	or the empty string for a default handler
#		*	Values are coderefs
#		*	Taking an element hashref ($_) as first argument
#		*	Arguments to rmap_hash() as further args
#			*	Notably $_[1]->recurse goes down into descendants of %$_.
#		*	Should return an element or undef.
my %handler_for = (
    Span => +{
        "" => sub {
            my($elem, $rmap) = @_;
            is_elem( $elem, 'Span' ) or return;
            # Do something with elem
            my $cmds = get_cmds($elem->{c}[-2]);
            return unless @$cmds;
            my($begin, $end) = get_ends($cmds);
            my $contents = $elem->{c}[-1];
            unshift @$contents, $begin;
            push @$contents, $end;
            return;
        },
    },
    Div => +{
        "" => sub {
            my($elem, $rmap) = @_;
            is_elem( $elem, 'Div' ) or return;
            # Do something with elem
            my $envs = get_cmds($elem->{c}[-2]);
            return unless @$envs;
            my($begin, $end) = get_ends($envs, 1);
            my $contents = $elem->{c}[-1];
            unshift @$contents, $begin;
            push @$contents, $end;
            return;
        },
    },
    Code => +{
        "" => sub {
            my($elem, $rmap) = @_;
            is_elem( $elem, 'Code' ) or return;
            # Do something with elem
            my $text = $elem->{c}[-1];
            my @contents = ( mk_elem( Str => $text ) );
            my $attrs = $elem->{c}[-2];
            my $cmds = get_cmds($attrs);
            if ( @$cmds ) {
                my($begin, $end) = get_ends($cmds);
                @contents = ( $begin, @contents, $end );
            }
            return mk_elem( Span => [ $attrs, \@contents ] );
        },
    },
);

rmap_hash {
    return unless is_elem( $_ );
    my $type = $_->{t};
    my $handler = firstval { defined }
        $handler_for{$type}{$to_format},
        $handler_for{$type}{""};
    return unless 'CODE' eq ref $handler;
    my $result = $handler->($_, @_);
    return unless defined $result;
    is_elem($result) or die "Handler for $type -> $to_format didn't return an element!";
    $_ = $result;
    return;
} $doc;


print {*STDOUT} $JSON->encode( $doc );

sub get_cmds {
    my($attrs) = @_;
    my $classes = $attrs->[1];
    return unless @$classes;
    my $kvs = $attrs->[2];
    my @cmds;
    CLASS:
    for my $class ( @$classes ) {
        next CLASS unless $class =~ s/([.:])\z//;
        if ( ':' eq $1 ) {
            push @$kvs, [ lang => $lang_map->{$class} ] if $lang_map->{$class};
            next CLASS unless 'latex' eq $to_format;
            push @cmds, "text$class";
        }
        else {
            next CLASS unless 'latex' eq $to_format;
            push @cmds, $class;
        }
    } ## end for my $class ( @$classes)
    return \@cmds;
} ## end sub get_cmds

sub get_ends {
    my($cmds, $block ) = @_;
    my $joiner = $block ? "\n" : q{};
    my $begin = join $joiner, map { $block ? "\\begin\{$_\}" : "\\$_\{" } @$cmds;
    my $end = join $joiner, map { $block ? "\\end\{$_\}" : '}' } reverse @$cmds;
    my $type = $block ? 'Block' : 'Inline';
    for my $elem ( $begin, $end ) {
        $elem = mk_elem( "Raw$type" => [ latex => $elem ] );
    }
    return ( $begin, $end );
} ## end sub get_raw_cmds

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

sub get_meta_opts {								# {{{2}}}
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

# Turn one pandoc metadata value into an option value # {{{2}}}
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

# Turn a pandoc metadata map into a plain hashref # {{{2}}}
sub _get_opt_map {
    my($href) = @_;
    my %ret;
    while ( my( $k, $v ) = each %$href ) {
        $ret{$k} = _get_opt_val($v);
    }
    return \%ret;
}

# Turn a pandoc metadata list into a plain arrayref # {{{2}}}
sub _get_opt_list {
    my( $aref ) = @_;
    my @ret = map { _get_opt_val($_) } @$aref;
    return \@ret;
}

__END__
