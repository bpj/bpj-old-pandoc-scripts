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
        $cmd =~ s{\A(\pL+)\*}{$1\_star}; # starred commands
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

=head1 NAME

pandoc-span2cmd.pl - pandoc filter to help simulating Markdown inside
LaTeX commands/environments and produce HTML and LaTeX from the same
source.

=head1 VERSION

0.5

=head1 SYNOPSIS

In your Markdown file:

    \definecolor{blueborder}{rgb}{0,0,1}

    Press the button marked
    <span cmd=fcolorbox#blueborder%white>`POWER`{cmd=textsf cmd=color#blue}</span>.

    The shining blue light is a `led`{cmd=textsc}.

    **<span cmd=color#red>WARNING:</span>**
    `Always`{cmd=uuline} unplug the chord before smashing the device!

    There is no Russian version of the manual.
    `«Ничего!»`{.textrussian. lang=ru}

    <div env=greek#[variant=ancient] lang=grc>

    ---
    # Freely use markdown inside an 'environment'!
    ...

    | `Ἄφοβον`{.uline.} ὁ **θεός**,
    | `ἀνύποπτον`{.uline.} ὁ **θάνατος**
    | καὶ **τἀγαθὸν** μὲν `εὔκτητον`{.uline.},
    | τὸ δὲ **δεινὸν** `εὐεκκαρτέρητον`{.uline.}

    </div>

Produce LaTeX:

    pandoc -F pandoc-span2cmd.pl -w latex source.md


    \definecolor{blueborder}{rgb}{0,0,1}

    Press the button marked
    {\fcolorbox{blueborder}{white}{{\textsf{\color{blue}{POWER}}}}}.

    The shining blue light is a {\textsc{led}}.

    \textbf{{\color{red}{WARNING:}}} {\uuline{Always}} unplug the chord
    before smashing the device!

    There is no Russian version of the manual. {\textrussian{«Ничего!»}}

    \begin{greek}[variant=ancient]

    {\uline{Ἄφοβον}} ὁ \textbf{θεός},\\{\uline{ἀνύποπτον}} ὁ
    \textbf{θάνατος}\\καὶ \textbf{τἀγαθὸν} μὲν {\uline{εὔκτητον}},\\τὸ δὲ
    \textbf{δεινὸν} {\uline{εὐεκκαρτέρητον}}

    \end{greek}

Produce HTML (example reformatted for readability):

    pandoc -F pandoc-span2cmd.pl -w html source.md


    <p>
        Press the button marked <span
            class="fcolorbox-blueborder_white"><span
            class="textsf color-blue">POWER</span></span>.
    </p>
    <p>
        The shining blue light is a <span class="textsc">led</span>.
    </p>
    <p>
        <strong><span class="color-red">WARNING:</span></strong>
        <span class="uuline">Always</span> unplug the chord before
        smashing the device!
    </p>
    <p>
        There is no Russian version of the manual.
        <span class= "textrussian" lang="ru">«Ничего!»</span>
    </p>
    <div class="greek" lang="grc">
    <p>
        <span class="uline">Ἄφοβον</span> ὁ <strong>θεός</strong>,<br>
        <span class="uline">ἀνύποπτον</span> ὁ <strong>θάνατος</strong><br>
        καὶ <strong>τἀγαθὸν</strong> μὲν <span class="uline">εὔκτητον</span>,<br>
        τὸ δὲ <strong>δεινὸν</strong> <span class="uline">εὐεκκαρτέρητον</span>
    </p>
    </div>

=head1 DESCRIPTION

script_name.pl is a pandoc filter to help simulating Markdown inside
LaTeX commands/environments and produce HTML and LaTeX from the same
source.

This is done by defining custom 'magic' attributes or classes. When
producing HTML these become ordinary classes which can be styled with
CSS, but when producing LaTeX they become command/environment names with
or without extra attributes, while span contents become the (main)
command attribute contents and div contents become either environment
body contents, or command attribute contents.

=head1 NORMAL USAGE

There are three ways to mark out a span, div, code or codeblock element
for special treatment by this filter:

=over

=item 1.

The special span or code attribute I<< cmd >> (the span body may contain
Markdown):

Markdown source:

    <span cmd=textsf>**bold sans text**</span>

LaTeX output:

    {\textsf{\textbf{sans text}}}

HTML output:

    <span class="textsf"><strong>bold sans text</strong></span>

=item 2.

The special div or codeblock attributes I<< env >> or I<< cmd >> (the
div body may contain Markdown):

Markdown source:

    <div env=center>
    <div cmd="colorbox#yellow">
    This is a *centered* textbox with *yellow* background
    </div>
    </div>

LaTeX output:

    \begin{center}

    \colorbox{yellow}{

    This is a \emph{centered} textbox with \emph{yellow} background

    }

    \end{center}

HTML output:

    <div class="center">
    <div class="colorbox-yellow">
    <p>This is a <em>centered</em> textbox with <em>yellow</em> background</p>
    </div>
    </div>

=item 3.

Class names consisting of letters followed by a period ('code' becomes
ordinary text, but no Markdown inside!):

Markdown source:

    `sans text`{.textsf.}

    ``` {.center.}
    Centered text.
    ```

LaTeX output:

    {\textsf{sans text}}

    \begin{center}

    Centered text.

    \end{center}

HTML output:

    <p><span class="textsf">sans text</span></p>
    <div class="center">
    <p>Centered text</p>
    </div>

=over

=item B<< Notes: >>

=over

=item 1.

You can use e.g.
C<< <span class="textsc.">LaTeX</span> but it doesn't give the nice 'dot-delimited' look you get with code attributes, and is more to type than >>cmd=textsc`,
so no gain!

=item 2.

You can use I<< cmd >> or I<< env >> attributes with 'code'. This is
useful as it allows you to specify extra arguments or turning
'codeblocks' into commands.

=item 3.

The entire 'code' or 'codeblock' text becomes a single string element
wrapped in a span element or a paragraph and a div element, so you
cannot use any Markdown, LaTeX or HTML markup inside the 'code's text.
This means that this form is mainly useful for single words or phrases,
allowing you to avoid the extra noise introduced by HTML-like start and
end tags. If you are only going to produce LaTeX this gives you no
advantage over embedded raw LaTeX but it allows LaTeX commands to double
as HTML classes.

=item 4.

Note that while a 'dotted' class on inline 'code' is equivalent to a
span with a I<< cmd >> attribute, a 'dotted' class on a 'codeblock' is
equivalent to a div with an I<< env >> attribute.

=back

=back

=back

You may have more than one I<< cmd >>/I<< env >> attribute, or more than
one 'dotted' class at the same time. They will become several nested
LaTeX commands or several HTML classes:

    <span cmd=textsc cmd=textsf>sans small caps</span>

    {\textsc{\textsf{sans small caps}}}

    <span class="textsc textsf">sans small caps</span>

=head3 The 'syntax' of I<< cmd >> and I<< env >> attribute values

=head3 The clean way

It is probably cleanest to let the I<< cmd >> and I<< env >> attributes
be a single word (which must be a valid LaTeX command name, and so must
contain only letters, although XeLaTeX allows you to use any Unicode
character with General Category I<< L >>!),

    <span cmd=blueWhiteBox>bordered blue text on white</span>

and then define that command or environment in a LaTeX file

which you include with pandoc's C<< -H >> option:

    pandoc -F pandoc-span2cmd.pl -w latex -H defs.ltx source.md

=head3 The messy way

The filter also supports overloading the I<< cmd >> or I<< env >>
attribute value with information on extra arguments to insert before and
after the 'main' argument with the span or div contents, so that you in
many cases won't need to write any LaTeX command definitions. You will
always need to write your CSS stylesheet, however!

The value of the I<< cmd >> attribute can have between one and three
main parts, separated by C<< # >> characters:

    cmd="COMMAND#{ARGS}{BEFORE}{ELEMENT}{BODY}#{ARGS}{AFTER}{ELEMENT}{BODY}"

or

    cmd="COMMAND#ARGS%BEFORE%ELEMENT%BODY#ARGS%AFTER%ELEMENT%BODY"

In both forms only the first part (C<< COMMAND >>) is required. The
other two parts may be missing or empty, but if there are to be extra
arguments after the span/div body but not before, the second part must
of course be present but empty.

What distinguishes the first form from the second is the presence of one
or more of the characters C<< { } [ ] >> in the second or third part

When producing LaTeX both forms become

    \COMMAND{ARGS}{BEFORE}{ELEMENT}{BODY}{...}{ARGS}{AFTER}{ELEMENT}{BODY}

where C<< ... >> marks the spot where the LaTeX which pandoc produces
from the span/div contents will be. In the second form any C<< % >>
characters in the second or third part will be replaced with the
character pair C<< }{ >> making each subpart a separate argument.

When producing HTML the second form is turned into an HTML class so that
all C<< # >> characters will be replaced with a hyphen (C<< - >>) and
all percent characters will be replaced with an underscore

    class="COMMAND-ARGS_BEFORE_ELEMENT_BODY-ARGS_AFTER_ELEMENT_BODY"

If the needed extra LaTeX arguments are any more complicated than this,
e.g. there is an argument delimited by square brackets, or the result
will not be a valid HTML class, then you have to use the first form and
specify your HTML classes and your extra LaTeX arguments explicitly:

    <span cmd="colorbox#[rgb]{1,1,0}" class=yellowbox>text on yellow background</span>

    {\colorbox[rgb]{1,1,0}{text on yellow background}}

    <span class="yellowbox colorbox">text on yellow background</span>

The I<< env >> attribute is treated similarly, except that it doesn't
support any after-arguments; a second C<< # >> character will be treated
as if it were a C<< % >> character.

    <div env="minipage#10cm">
    Text in minipage.
    </div>

    \begin{minipage}{10cm}

    Text in minipage.

    \end{minipage}

    <div class="minipage-10cm">
    <p>Text in minipage.</p>
    </div>

=head1 DEFINING CSS RULES (OR LATEX COMMANDS)

For producing HTML you will have to define CSS rules for the classes
derived from I<< cmd >> and I<< env >> attributes. Most of the time this
means that you will have classes with the same names as LaTeX commands.
This is not a bad thing if those who read your HTML know LaTeX, at least
as long as yore CSS assigns reasonable properties to those classes! CSS
rules corresponding to simple commands can be comparably simple:

    span.textsf { font-family: sans-serif; }
    span.textsc { font-variant: small-caps; }
    div.center  { text-align: center; }
    span.uline  { text-decoration: underline; } /* \usepackage[normalem]{ulem} */
    div.fbox    { border: 1px solid black }

Commands which take extra arguments need one selector per
command+arguments combo:

    div.fcolorbox-red_yellow {    /* \usepackage{xcolor} */
        border: 1px solid red; background-color: yellow; }

(Note that this example wouldn't have worked if C<< red >> and
C<< yellow >> had been separate classes!)

Sometimes you can simplify your Markdown by defining both CSS rules and
LaTeX commands:

    <div cmd="wmbox#10cm">
    !!LIPSUM!!
    </div>

    div.wmbox-10cm { width: 10cm; margin-left: auto; margin-right: auto; }

    \newcommand{\wmbox}[2]{\makebox[#1][c]{#2}}

There are also cases where the best thing to do is to give HTML
attributes I<< and >> LaTeX commands or environments side by side, as
with the C<< lang >> attributes and [polyglossia][]
commands/environments example in the L<< SYNOPSIS|#synopsis >>.

    :lang(grc) { font-family: "GFS Neohellenic" }
    :lang(ru)  { font-style: italic }

    % See polyglossia and fontspec packages!
    \newfontfamily\greekfont{GFS Neohellenic}[Script=Greek]
    \newfontface\russianfont{Charis SIL Italic}[Script=Cyrillic] % <mainfont> Italic!

=head1 POWER USAGE (FOR PERL HACKERS)

TODO!

(Some code is in place but there is an API change underway!)

=head1 AUTHOR

Benct Philip Jonsson E<lt>bpjonsson@gmail.comE<gt>

=head1 COPYRIGHT

Copyright 2015- Benct Philip Jonsson

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

=head1 AUTHOR

Benct Philip Jonsson E<lt>bpjonsson@gmail.comE<gt>

=head1 COPYRIGHT

Copyright 2015- Benct Philip Jonsson

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

