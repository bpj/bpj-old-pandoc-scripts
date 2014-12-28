#!/usr/bin/env perl

# You can set the following options in the document metadata: # {{{1}}}
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
# -M OPTION='VALUE'
#

# SETUP                                         # {{{1}}}
package _BPJ::PandocFilter::Span2Cmd;
use base 'Class::Accessor';

# use 5.014;
use strict;
use warnings FATAL => 'all';
no warnings qw[ uninitialized numeric ];

use utf8;    # No UTF-8 I/O with JSON.pm!

use autodie 2.12;

no indirect;
no autovivification;    # Don't pullute the AST!

# use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case ];

# IMPORTS                                       # {{{1}}}

use CLASS;
use Carp;
use Class::Load qw[ load_class ];
use Data::Rmap qw[ cut rmap_array rmap_hash rmap_scalar ];    # Data structure traversal support.
use JSON;
use List::AllUtils qw[ all apply notall uniq ];
use List::UtilsBy qw[ extract_by ];
use Scalar::Util qw[ blessed refaddr ];

use Data::Printer;

CLASS->mk_accessors(                              # {{{1}}}
    qw[

      classes
      contents
      _default
      found
      id
      key_vals
      other
      raw_type
      to_contents
      to_contents_ref
      to_type
      type
      _wanted_re

      ],
);

# HELPER FUNCTIONS                              # {{{1}}}

sub _object_slice {
    my $obj = shift;
    confess "Not an object: $obj" unless my $class = blessed $obj;
    confess "Some of these methods were not found through $class: @_"
        if notall { $class->can($_) } @_;
    my %slice = map { $_ => $obj->$_ } @_;
    return wantarray ? %slice : \%slice;
}

sub _mk_elem {    # {{{2}}}
    my ( $type => $contents ) = @_;
    return +{ t => $type, c => $contents };
}

# READ IN DATA                                  # {{{1}}}

my $to_format = shift @ARGV;
sub to_format { $to_format }

my $JSON = JSON->new->utf8->convert_blessed;

my $doc = $JSON->decode( do { local $/; <>; } );

my $option                                           # {{{2}}}
  = CLASS->_get_meta_opts(
    +{  doc     => $doc,
        opts    => [qw[ cmd_class_prefix env_class_prefix span2cmd_plugin ]],
        default => +{},
        prefix  => q{},
    }
  );

sub option { $option ||= +{} }

# DISPATCH                                      # {{{1}}}

my %handler_for = (    # {{{2}}}
    html  => { map { $_ => \&process_html } qw[ Code CodeBlock Div Span ], },
    latex => { map { $_ => \&process_latex } qw[ Code CodeBlock Div Span ], },
);

my %set_to_contents_for = (    # {{{2}}}
    Code => sub {
        my($elem) = @_;
        $elem->to_type( 'Span' ) unless $elem->to_type;
        my $str = _mk_elem( Str => $elem->contents );
        $elem->to_contents_ref( \$str->{c} );
        $elem->to_contents( [ $str ] );
    },
    CodeBlock => sub {
        my($elem) = @_;
        $elem->to_type( 'Div' ) unless $elem->to_type;
        my $str = _mk_elem( Str => $elem->contents );
        $elem->to_contents_ref( \$str->{c} );
        $elem->to_contents( [ _mk_elem( Para => [ $str ] ) ] );
    },
);

my %elem_params_for = (    # {{{2}}}
    (   map {
            $_ => sub {
                return +{
                    to_type   => 'Span',            #
                    _default   => 'cmd',             #
                    _wanted_re => qr/\Acmd\z/,       #
                    raw_type  => 'RawInline',       #
                };    #
              }
        } qw[ Span Code ]
    ),
    (   map {
            $_ => sub {
                return +{
                    to_type   => 'Div',                  #
                    _default   => 'env',                  #
                    _wanted_re => qr/\A(?:cmd|env)\z/,    #
                    raw_type  => 'RawBlock',             #
                };
              }
        } qw[ Div CodeBlock ]
    ),
);

my %pad_format_for = (           # {{{2}}}
    cmd => { begin => '\\%1$s%2$s{',           end => '}%3$s', },
    env => { begin => '\\begin{%1$s}%2$s%3$s', end => '\\end{%1$s}', },
);

my %join_for = ( Span => q{}, Div => "\n" );    # {{{2}}}

# PLUGINS                                       # {{{1}}}

if ( $option->{span2cmd_plugin} ) {
    my ( @plugs );
    my $names = $option->{span2cmd_plugin};
    $names = [$names] unless 'ARRAY' eq ref( $names );
    for my $plug ( @$names ) {
        push @plugs, load_class( $plug );
    }
    if ( @plugs ) {
      PLUG:
        for my $plug ( @plugs ) {
            if ( $plug->can('get_meta_opts_args') ) {
                CLASS->_get_meta_opts( $plug->get_meta_opts_args );
            }
          TYPE:
            for my $type ( qw[ Code CodeBlock Span Div ] ) {
                my $name = "$to_format\_$type";
                my $code = $plug->can( $name );
                next TYPE unless defined $code;
                $handler_for{$to_format}{$type} = $code;
                next PLUG;
            }
        }
    }
}

$to_format = 'html' unless exists $handler_for{ $to_format };    # {{{2}}}

# CHANGE ELEMENTS IN-PLACE:                     # {{{1}}}

rmap_hash {
    my $elem = $_;
    return unless all { exists $elem->{$_} } qw[ t c ];
    return unless exists $handler_for{$to_format}{ $elem->{t} };
    my $obj = CLASS->new( $elem, $to_format ) || return;
    my $result = $handler_for{$to_format}{ $elem->{t} }->( $obj, $to_format, @_, ) || return;
    $_ = $result;
    return;
}
$doc;

print {*STDOUT} $JSON->encode( $doc );

# METHODS                                   # {{{1}}}

# GET META-OPTS                                 # {{{2}}}

sub _get_meta_opts {    # {{{3}}}
    my $class = shift;
    my $p     = shift;
    my $doc   = $p->{doc};
    my $meta
      = ref( $doc )       ? $doc->[0]{unMeta}
      : ref( $p->{meta} ) ? $p->{meta}
      :                     confess "get_meta_opts() needs a 'doc' or 'meta' arg";
    my $pfx  = $p->{prefix} || q{};
    my $opts = $class->option;
    my @opts = @{ $p->{opts} || [] };
    %$opts = ( %$opts, %{ $p->{default} || +{} } );
    @opts = keys %$opts unless @opts;
  OPT:
    for my $opt ( @opts ) {
        my $key = $pfx . $opt;
        next unless exists $meta->{$key};
        $opts->{$opt} = $class->_get_opt_val( $meta->{$key} );
    }
    return $opts;
}

# Turn one pandoc metadata value into an option value # {{{3}}}
sub _get_opt_val {    # {{{4}}}
    my ( $class, $data ) = @_;
    my $tag = $data->{t};
    if ( 'MetaMap' eq $tag ) {
        return $class->_get_opt_map( $data->{c} );
    }
    elsif ( 'MetaList' eq $tag ) {
        return $class->_get_opt_list( $data->{c} );
    }
    else {
        my ( $opt ) = rmap_hash {
            my $tag = $_->{t};
            if ( 'Str' eq $tag or 'MetaString' eq $tag ) {
                cut $_->{c};
            }
            elsif ( 'Code' eq $tag or 'CodeBlock' eq $tag ) {
                cut $_->{c}[-1];
            }
            return;
        }
        $data;
        return $opt;
    }
    return;
}

# Turn a pandoc metadata map into a plain hashref # {{{3}}}
sub _get_opt_map {    # {{{4}}}
    my ( $class, $href ) = @_;
    my %ret;
    while ( my ( $k, $v ) = each %$href ) {
        $ret{$k} = $class->_get_opt_val( $v );
    }
    return \%ret;
}

# Turn a pandoc metadata list into a plain arrayref # {{{3}}}
sub _get_opt_list {    # {{{4}}}
    my ( $class, $aref ) = @_;
    my @ret = map { $class->_get_opt_val( $_ ) } @$aref;
    return \@ret;
}

# PROCESS ELEMENTS                              # {{{2}}}

sub new {              # {{{3}}}
    my ( $inv, $elem, $to_format ) = @_;
    my $class = blessed($inv) || $inv;

    # Get data                                  # {{{4}}}
    my $self = $elem_params_for{ $elem->{t} }->()
      || confess "Can't handle $elem->{t} elements";
    bless $self => $class;
    $self->to_format( $to_format );
    $self->id( $elem->{c}[-2][0] );
    $self->classes( my $classes = $elem->{c}[-2][1] );
    $self->key_vals( my $kvs = $elem->{c}[-2][2] );

    # Classes to key-vals                       # {{{4}}}
    my $default = $self->_default;
    for my $cmd ( apply { s/\.\z// } extract_by { /\.\z/ } @$classes ) {
        push @$kvs, [ $default => $cmd ];
    }

    # Process key-vals                          # {{{4}}}
    my $wanted_re = $self->_wanted_re;
    my $option    = $self->option;
    my @cmds      = extract_by { $_->[0] =~ /$wanted_re/ } @$kvs;
  KV:
    for my $kv ( @cmds ) {
        my ( $key, $cmd ) = @$kv;
        if ( $cmd =~ /[\[\]\{\}]/ ) {
            $cmd =~ /\A(\pL+)/    # The command
              and push @$classes, $option->{"$key\_class_prefix"} . $1;
        }
        else {
            $cmd =~ tr/#%/-_/;
            push @$classes, $option->{"$key\_class_prefix"} . $cmd;
        }
    }

    # Set params                                # {{{4}}}
    return unless @cmds;
    @$classes      = uniq @$classes;
    $self->{found} = \@cmds;
    $self->{other} = $kvs;
    $self->type( $elem->{t} );
    $self->contents( $elem->{c}[-1] );
    if ( my $conv = $set_to_contents_for{ $self->type } ) {
        $self->$conv;
    }
    else {
        $self->to_contents( $self->contents );
    }
    return $self;
}

sub process_html {    # {{{3}}}
    # my ( $elem ) = @_;
    # return unless defined $elem->found->[0];
    # return $elem;
    return $_[0];
}

sub process_latex {    # {{{3}}}
    my ( $elem ) = @_;
    my $cmds     = $elem->found;
    my $classes  = $elem->classes;
    return unless @$cmds;

    # Process commands                          # {{{4}}}
    my ( %pad );
  KV:
    for my $kv ( @$cmds ) {
        my ( $attr, $value ) = @$kv;
        my %cur;
        @cur{qw[ cmd begin end ]} = split /\#/, $value;
        for my $end ( qw[ begin end ] ) {
            my $pad = \$cur{$end};
            unless ( $$pad =~ /[\[\]\{\}]/ ) {
                $$pad =~ s/%/}{/g;
                $$pad = "{$$pad}" if length $$pad;
            }
        }
        for my $end ( qw[ begin end ] ) {
            my $pad = $pad{$end} ||= [];
            push @$pad, sprintf $pad_format_for{$attr}{$end}, @cur{qw[ cmd begin end ]};
        }
    }

    # Convert element                           # {{{4}}}
    return unless $cmds;
    my ( $begin, $end ) = @pad{qw[ begin end ]};
    @$end = reverse @$end;
    my $contents = $elem->to_contents;
    local $" = $join_for{ $elem->to_type };
    unshift @$contents, _mk_elem( $elem->raw_type => [ latex => "@$begin" ] );
    push @$contents, _mk_elem( $elem->raw_type => [ latex => "@$end" ] );
    return $elem;
}

sub TO_JSON {                                   # {{{2}}}
    my($elem) = @_;
    my $type = $elem->to_type || $elem->type;
    my %attr = _object_slice( $elem, qw[ id classes key_vals ] );
    my $contents = $elem->to_contents;
    # Force stringification!
    rmap_scalar { $_ = ref($_) ? "$$_" : "$_"; return; } \%attr;
    rmap_scalar { $_ = $$_ if ref($_); return; } $contents;
    return _mk_elem( $type => [ [@attr{ qw[ id classes key_vals ] }], $contents ] );
}

__END__

# BEGIN GENERATED POD #

=pod

=encoding UTF-8

No documentation yet!

=cut

