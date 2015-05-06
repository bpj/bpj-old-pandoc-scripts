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

my $VERSION = '0.003000';

use utf8;  # No UTF-8 I/O with JSON.pm!

use autodie 2.12;

no indirect;
no autovivification; # Don't pullute the AST!

# use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case ];

use JSON qw[ decode_json encode_json ];
use Data::Rmap qw[ rmap_hash rmap_array cut ]; # Data structure traversal support.
use List::AllUtils qw[ max all any];
use Scalar::Util qw[refaddr];
use File::Basename qw[ basename ];
use Roman;
use Number::Latin;

my $to_format = shift @ARGV;

# die "$0 requires 'plain' as --to format" unless 'plain' eq $to_format;

my $doc = decode_json do { local $/; <>; };

my $option 
    = get_meta_opts( 
      +{ 
          doc => $doc, 
          opts => [ qw[ escape_lt_gt cut ] ], 
          default => +{ escape_lt_gt => 0, cut => 1 },
          prefix => q{pod_},
      }
  );

# if(1) {
#     use Data::Printer; 1;
#     die p($option), p($doc->[0]);
# }

sub rmap_element_lists (&@);

our $Nested;

# HELPER FUNCTIONS      # {{{1}}}
# We define them in a BEGIN block so that we 
# can use them in generating constants below
BEGIN {
    sub _mk_elem {	# {{{2}}}
        my( $tag, $contents ) = @_;
        return +{ t => $tag, c => $contents };
    }

    sub _mk_pod_inline {	# {{{2}}}
        my( $text ) = @_;
        return _mk_elem( Str => $text );
    }

    sub _mk_pod_block {	# {{{2}}}
        return _mk_elem( Para => [ &_mk_pod_inline ] );
    }

    sub _mk_elem_with_class {	# {{{2}}}
        my( $tag, $contents, $class ) = @_;
        return _mk_elem( $tag => [ ['',["$class"],[]], $contents ] );
    }
    
    sub _max_angles {
        my($str_ref) = @_;
        return $option->{escape_lt_gt} ? 1
        : max map { length $_ } $$str_ref =~ /(\<+|\>+)/g;
    }
    
    sub _get_delimiters {
      my($width) = @_;
      return( ('<' x $width), ('>' x $width) );
    }
}

use constant OVER   => _mk_pod_block( q{=over} );
use constant ITEM   => _mk_pod_inline( q{=item } );
use constant BULLET => _mk_pod_block( q{=item *} );
use constant BACK   => _mk_pod_block( q{=back} );

# Escape < and > in literal strings.
my %angle2ent = qw[ < E<lt> > E<gt> ];

# LIST STYLES {{{1}}}
my $idem = sub { shift };    #
my %list = (    #
    style => {    #
        DefaultStyle => $idem,    #
        Example      => $idem,    #
        Decimal      => $idem,    #
        LowerRoman => \&roman,            #
        UpperRoman => \&Roman,            #
        LowerAlpha => \&int2latin,        #
        UpperAlpha => \&int2LATIN,        #
    },    #
    delim => {    #
        DefaultDelim => '=item %s.',     #
        Period       => '=item %s.',     #
        OneParen     => '=item %s)',     #
        TwoParens    => '=item (%s)',    #
    },    #
);        #

# CONVERSION DISPATCH TABLE     {{{1}}}

my %handler_for = (

    Emph => _gen_emph('I'),

    Strong => _gen_emph('B'),

    Str => sub { 	# {{{2}}}
        # Escape < and > in literal strings.
        my($elem) = @_;
        $elem->{c} =~ s/([<>])/$angle2ent{$1}/g;
        return $elem;
    },

    Link => sub {	# {{{2}}}
        my($elem, $rmap) = @_;
        # get the current formatting code nesting level
        # so that we can reset it later if it was null!
        my $orig_nested = $Nested;
        # init the formatting code nesting level counter before we recurse.
        $Nested ||= 1;
        # recurse into the link text to insert formatting codes as appropriate.
        $rmap->recurse;
        my $text = $elem->{c}[0];      # link text: an array of inlines
        my $url = $elem->{c}[1][0];    # url: a string
        my $title = $elem->{c}[1][1];  # title: a string
        # we don't bother translating CPAN/man links into pod/perldoc links;
        # instead the author should provide the correct pod link string
        # in the link title with a perldoc:|cpan:|pod:|man: prefix,
        # and the url will be replaced with the rest of the title,
        # prepending a pipe if the text is not empty.
        # If the text is empty a link like 
        # [](0 "cpan:Some::Mod") will do the right thing,
        # and my pandoc-perldoc2non-pod.pl filter will do the right thing
        # with zero urls when generating other formats!
        if ( $title =~ s{ \A (?: perldoc|cpan|pod|man ) : }{}x ) {
            # if there is a text there should be a pipe before the url
            $url =  @$text ? "|$title" : $title;
        }
        else { $url = '|' . $url }
        # add a formatting code nesting level for the link,
        # making a minimum of two.
        $Nested += 1;
        # construct the opening/closing delimiters
        my($odel, $cdel) = _get_delimiters( $Nested );
        # add delimiters and url to the text
        unshift @$text, _mk_pod_inline(qq{L$odel } );
        push @$text, _mk_pod_inline("$url $cdel" );
        # reset delimiter nesting level *iff* it was null when we started,
        # otherwise it should propagate upwards!
        undef $Nested unless $orig_nested;
        # return a span, not a link element!
        return _mk_elem_with_class( Span => $text => 'link' );
    },

    Header => sub {	# {{{2}}}
        my($elem) = @_;
        my $contents = $elem->{c};    # [ \@attrs, \@text ]
        my $level = shift @$contents; # header level 1--6
        $level = 4 if $level > 4;     # pod knows only 4 levels
        $elem->{t} = 'Div';           # covert to div to suppress writer formatting
        my $text = $contents->[-1];  # header text as array of inlines
        unshift @$text, _mk_pod_inline(qq{=head$level } );  # prepend pod command
        $contents->[-1] = [ _mk_elem( Para => $text ) ];  # Div contents must be list of Blocks
        return $elem;
    },

    Code => sub {	# {{{2}}}
        my( $elem ) = @_;
        my $str = $elem->{c}[-1];
        return _mk_pod_inline($str) if 'raw_pod' eq $elem->{c}[-2][1][0]; # leave raw pod as is
        # local $Nested unless $Nested;
        # cf. Link handler_for code!
        my $orig_nested = $Nested;
        $Nested ||= 1;
        $Nested += _max_angles(\$str) || 1;
        my( $odel, $cdel) = _get_delimiters( $Nested);
        $str =~ s/([<>])/$angle2ent{$1}/g if $option->{escape_lt_gt};
        my $classes = $elem->{c}[-2][1];
        my $tag = 'C';
        if ( any { /\A(?:fn|file(?:name)?)\z/ } @$classes ) {
           $tag = 'F';
        }
        undef $Nested unless $orig_nested;
        return _mk_pod_inline("$tag$odel $str $cdel");
    },
    
    CodeBlock => sub {	# {{{2}}}
        my( $elem ) = @_;
        return _mk_pod_block( $elem->{c}[-1] ) if 'raw_pod' eq $elem->{c}[-2][1][0];  # text
        $elem->{c}[-2] = [q{},[],[]];   # Delete attributes
        return $elem;
    },

    DefinitionList => sub {	# {{{2}}}
        my( $elem ) = @_;
        my $list = $elem->{c}; # [ [ [t,e,r,m], [ [d,e,f,1], ...] ], ... ]
        my @new_list = ( OVER ); # init pod list
        for my $item ( @$list ) {  # an array of arrays
            my($term, $definitions) = @$item; # array of inlines, array of arrays
            unshift @$term, ITEM;  # prepend pod command
            push @new_list, _mk_elem_with_class( Div => [ _mk_elem( Para => $term ) ], 'dt' );  # wrap in para and div
            for my $definition ( @$definitions ) {  # array of arrays of blocks
                push @new_list, _mk_elem_with_class( Div => $definition, 'dd' ); # wrap ary of blocks
            }
        }
        push @new_list, BACK;  # close pod list
        return _mk_elem_with_class( Div => \@new_list, 'dl' );  # return div to suppress writer formatting
    },

    BulletList => sub {	# {{{2}}}
        my( $elem ) = @_;
        my $list = $elem->{c};
        my @new_list = ( OVER );
        for my $item ( @$list ) { # array of arrays of blocks
            push @new_list, BULLET;  # =item *
            push @new_list, _mk_elem_with_class( Div => $item, 'li' );
        }
        push @new_list, BACK;
        return _mk_elem_with_class( Div => \@new_list, 'ul' );
    },

    OrderedList => sub { 	# {{{2}}}
        my( $elem ) = @_;
        # first number, number-style, delimiter-style
        my($num, $style, $delim) = @{ $elem->{c}[0] };
        # { t => "Foo", c => [] } --> "Foo"
        for my $attr ( $style, $delim ) {
            $attr = $attr->{t};
        }
        my $list = $elem->{c}[1];
        my @new_list = ( OVER );
        for my $item ( @$list ) { # array of arrays of blocks
            push @new_list, _mk_pod_block(
                sprintf $list{delim}{$delim}, $list{style}{$style}->($num++)
            );
            push @new_list, _mk_elem_with_class( Div => $item, 'li' ); 
        }
        push @new_list, BACK;
        return _mk_elem_with_class( Div => \@new_list, 'ol' );
    },

);

# wrap doc in =pod, =encoding and =cut commands # {{{1}}}
if( $option->{cut} ) {
    my $script = basename($0);
    my $body = $doc->[1];
    unshift @$body, _mk_pod_block(
      join "\n\n", (
        '=pod',
        '=encoding UTF-8',
        "=for Info: POD generated by $script and pandoc.",
      )
    );
    push @$body, _mk_pod_block('=cut' );
}

# loop through all hashes/elements recursively  # {{{1}}}
rmap_hash {
    return unless exists $_->{t}; # minimal checks for valid element
    return unless exists $_->{c};
    my $tag = $_->{t};
    return unless exists $handler_for{$tag};  # do we have a handler for this type?
    # my( $rmap ) = @_; # get recursion object
    my $ret = $handler_for{$tag}->($_, @_); # $rmap);
    $_ = $ret if defined $ret;  # update current object unless handler aborted
    return;
} $doc;


print {*STDOUT} encode_json $doc;

# FUNCTIONS                                     # {{{1}}}

# sub rmap_element_lists (&@) {	# {{{2}}}
#     my($callback, @data) = @_;
#     # my %seen;
#     rmap_array {
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

sub get_meta_opts {	# {{{2}}}
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

# Turn one pandoc metadata value into an option value
sub _get_opt_val {	# {{{2}}}
	my($data) = @_;
	my $tag = $data->{t};
	if ( 'MetaMap' eq $tag ) {
		return _get_opt_map( $data->{c} );
	}
	elsif ( 'MetaList' eq $tag ) {
		return _get_opt_list( $data->{c} );
	}
	else {
		my($opt) = rmap_hash {
			my $tag = $_->{t};
			if ( any { $_ eq $tag } qw[ Str MetaString MetaBool ]  ) {
				cut $_->{c};
			}
			elsif ( any { $_ eq $tag } qw[ Code CodeBlock ]  ) {
				cut $_->{c}[-1];
			}
			return;
		} $data;
		return $opt;
	}
	return;
}

# Turn a pandoc metadata map into a plain hashref
sub _get_opt_map {	# {{{2}}}
	my($href) = @_;
	my %ret;
	while ( my( $k, $v ) = each %$href ) {
		$ret{$k} = _get_opt_val($v);
	}
	return \%ret;
}

# Turn a pandoc metadata list into a plain arrayref
sub _get_opt_list {	# {{{2}}}
	my( $aref ) = @_;
	my @ret = map { _get_opt_val($_) } @$aref;
	return \@ret;
}

# generator for Emph and Strong handlers
sub _gen_emph {	# {{{2}}}
	my($x) = @_;  # formatting code letter I|B
	return sub {
		my($elem,$rmap) = @_;
		    ## cf. Link handler
        my $orig_nested = $Nested;
        $Nested ||= 1;
        # local $Nested unless $Nested;
        $rmap->recurse;
		my $contents = $elem->{c};
        $Nested += 1;
        my $odel = '<' x $Nested;
        (my $cdel = $odel) =~ tr/</>/;
		unshift @$contents, _mk_pod_inline(qq($x$odel ) );
		push @$contents, _mk_pod_inline(qq( $cdel) );
        undef $Nested unless $orig_nested;
		return _mk_elem_with_class( Span => $contents, lc $x );
	};
}


__END__

# BEGIN GENERATED POD #

=pod

=encoding UTF-8

=head1 NAME

pandoc-plain2pod.pl - a pandoc filter to munge plain output into Perl
POD documentation.

=head1 VERSION

0.3

=head1 SYNOPSIS

    pandoc -w plain -F pandoc-plain2pod.pl [OPTIONS]  FILE_NAME ...

=head1 DESCRIPTION

pandoc-plain2pod.pl is a pandoc filter to munge plain output into Perl
POD documentation, a poor man's custom writer implemented as a filter if
you will.

It works by replacing or wrapping certain Pandoc AST elements with Span,
Div and other elements with raw POD markup injected into their contents
lists as inline Code elements which the plain writer renders as
unadorned verbatim text.

=head1 HOW TEXT ELEMENTS ARE 'TRANSLATED'

=head2 Start and end of document

The raw POD blocks

    =pod

    =encoding UTF-8

and

    =cut

are inserted at the beginning and end of the document.

=head2 Headers

Headers are turned into POD C<< =head1 >>..C<< =head4 >> command
paragraphs.

B<< Note >> that while Pandoc, like HTML, recognises six levels of
headers POD recognises only four, so level 5 and 6 headers are
'normalized' to C<< =head4 >> (moreover some ancient POD readers
recognise only two header levels, so you may want to use definition
lists below that!)

=head2 Bullet (unordered) lists

Bullet lists are converted into C<< =over...=back >> regions with an
C<< =item * >> for each list item.

=head2 Ordered lists

Ordered lists are converted into C<< =over...=back >> regions with an
C<< =item >> reflecting the list marker style of the original Markdown
list; however many POD converters only recognize digits followed by a
period as ordered list markers, so you might want to stick to that!

=head2 Definition lists

Ordered lists are converted into C<< =over...=back >> regions with an
C<< =item >> for each term and the contents of the definitions as
paragraphs or other block elements below them. You may want to put blank
lines between your terms and definitions to make sure that pandoc
renders the definition contents as paragraphs, so that there are blank
lines between them in the POD.

B<< Note >> that both Pandoc definitions and POD C<< =item >>s must fit
on a single line!

=head2 Code blocks

Are left as Pandoc's plain writer normally renders them, indented with
four spaces, which should get them rendered correctly by most POD
parsers and formatters, unless they have a
L<<< C<< .raw_pod >>|/"RAW POD" >>> class, in which case they will end
up as unindented verbatim plain text.

=head2 Inline code

Inline code (C<< `code()` >>) is wrapped in a POD C<<< C<< ... >> >>>
formatting code.
See L<< NESTED FORMATTING CODES|/"NESTED FORMATTING CODES" >> below for
how C<< < >> and C<< > >> inside code and nested formatting codes are
handled (i.e. hopefully correctly).

=head2 Ordinary emphasis

Ordinary emphasis (C<< *emph* >> or C<< _emph_ >>) is wrapped in a POD
C<<< I<< ... >> >>> formatting code. See L<< NESTED FORMATTING
CODES|/"NESTED FORMATTING CODES" >> below for how nested formatting
codes are handled (i.e. hopefully correctly).

=head2 Strong emphasis

Strong emphasis (C<< *strong* >> or C<< _strong_ >>) is wrapped in a POD
C<<< B<< ... >> >>> formatting code. See L<< NESTED FORMATTING
CODES|/"NESTED FORMATTING CODES" >> below for how nested formatting
codes are handled (i.e. hopefully correctly).

=head2 Special characters

The characters C<< < >> and C<< > >> in ordinary text are replaced by
the POD entities C<< E<lt> >> and C<< E<gt> >>. Other special characters
are left as literal UTF-8, and an C<< =encoding UTF-8 >> is inserted at
the beginning of the POD. If you run into problems with that you should
inform the maintainers of your POD formatters that we now live in the
21st century!

=head2 Links

The handling of links is a bit complicated. If a link has a title as in
C<< [link text](URL "title" >> and the I<< title >> has one of the
prefixes C<< perldoc: >>, C<< cpan: >>, C<< pod: >>, or C<< man: >> the
URL will be replaced with whatever comes after that prefix in the title,
hopefully resulting in correct podlinks to Perl documentation, a CPAN
module, some header in the current document or a man page. The following
examples should make clear how it all works:

    [the perlfunc docs](http://perldoc.perl.org/perlfunc.html "perldoc:perlfunc")

        L<< the perlfunc docs|perlfunc >>

    [the Try::Tiny module](https://metacpan.org/pod/Try::Tiny "cpan:Try::Tiny")

        L<< the Try::Tiny module|Try::Tiny >>

    [METHODS above](#METHODS "pod:/\"METHODS\"")

        L<< METHODS above|/"METHODS" >>

    [the which(1) manpage](http://man.he.net/man1/which "man:which(1)")

        L<< the which(1) manpage|which(1) >>

    [Pandoc](http://johnmacfarlane.net/pandoc "The Pandoc homepage")

        L<< Pandoc|http://johnmacfarlane.net/pandoc >>

(B<< Note >> the escaped inner quotes in the internal link example; they
are unfortunately necessary!)

This filter does not treat the different title prefixes differently, but
I plan to write a companion filter which will allow you to write things
like

    [](0 "perldoc:perlfunc")
    [](0 "cpan:Try::Tiny/\"CAVEATS\"")
    [](0 "pod:/\"METHODS\"")
    [](0 "man:which(1)")

and get empty link texts and/or false URL values replaced by something
sensible when not producing POD output.

=head1 RAW POD

If you want to insert some raw POD, e.g. a C<< =for >> paragraph, you
can use an inline code element or a code block with a class
C<< raw_pod >>:

    ```{.raw_pod}
    =for Something:
    foo
    bar
    baz
    ```

    reference`Z<>`{.raw_pod}(s)

I'm afraid that if you want to hide such raw POD when producing other
formats you will have to write your own filter. The reason this feature
exists is that it is so this filter itself inserts raw POD.

=head1 NESTED FORMATTING CODES

The filter tries to do the right thing with nested formatting codes,
i.e. as you go outwards each nesting level gets one angle bracket more
in its delimiters, starting with double brackets at the innermost level
because I find that more readable, except for C<< E<lt> >> and
C<< E<gt> >> for literal C<< < >> and C<< > >> outside code:
C<< **Foo _bar `baz`_** >> will be rendered as
C<<<<< B<<<< I<<< bar C<< baz >> >>> >>>> >>>>>, should your Markdown
contain something like that.

The way the number of angle brackets around inline code which contains
angle brackets is determined is rather crude but a least it avoids
getting too few brackets in the delimiters: It matches the code string
against the regex C<< /(\<+|\>+)/ >> and adds the length of the longest
match to the counter keeping track of the formatting code nesting level,
which is localized before the filtering routine recurses to process
inner elements before inserting the delimiters of an outer element, so
that the number of angle brackets in the delimiters increases outwards.

This means that something like C<< `$foo->bar->baz->quux` >> will be
rendered as C<<< C<< $foo->bar->baz->quux >> >>> and something like
C<<< `20 << 40` >>> will be correctly rendered as
C<<<< C<<< 20 << 40 >>> >>>>. However in some cases the outer delimiters
may get too 'wide', but they should never get too narrow.

If you prefer to have C<< E<lt> >> and C<< E<gt> >> for literal C<< < >>
and C<< > >> also in inline code you can set a metadata key
C<< pod_escape_lt_gt >> to a true value either in a YAML metadata block
in your Markdown file or with pandoc's C<< -M >> option on the command
line. This is especially handy if your inline code exemplifies POD
formatting codes, as any formatting code can be legally nested inside
the C<< C<> >> formatting code!

=head1 TODO

A hack to make inline code elements with a C<< .file >> class render as
C<<< F<< ... >> >>> formatting codes.

=head1 AUTHOR

Benct Philip Jonsson E<lt>bpjonsson@gmail.comE<gt>

=head1 COPYRIGHT

Copyright 2014- Benct Philip Jonsson

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

