#!/usr/bin/env perl
use 5.014;
use strict;
# use warnings FATAL => 'all';

=head1 DESCRIPTION

 A [pandoc][] filter written in Perl for numbering paragraphs and other top level 
 blocks sequentially throughout a document by injecting raw HTML or LaTeX code.

 <https://groups.google.com/forum/#!msg/pandoc-discuss/aR0Fa2bKXZ8/vf4UbN8rcmsJ>

 For paragraphs it inserts the sequential number a raw span in HTML
 and a raw command in LaTeX at the beginning of the paragraph.
 Other blocks, like lists, are wrapped in a div with a raw div/command
 containing the sequential number as first content.
 Divs are not numbered unless they have a class `number_me`.
 OTOH the inserted divs around non-paragraph blocks get the same class,
 and additionally a class corresponding to the Pandoc element type
 of the contained block, in case you need to style it or the sequential 
 number it contains specially.

 The inserted raw markup looks as follows, where NUM is the sequential
 number of the paragraph/block -- actually a string of digits --
 and STRINGLEN is the width in characters of NUM -- actually a digit
 (more on that below!)

    html:
        Div:  <div class="blockNum blockNumLenSTRINGLEN">NUM</div>
        Para: <span class="paraNum blockNumLenSTRINGLEN">NUM</span>
    latex:
        Div:  \blockNum{NUM}
        Para: \paraNum{NUM}


 You will have to define CSS for these elements , and/or define the custom
 LaTeX commands with `\newcommand` in their respective files and include 
 those files with pandoc's `--css` or `--include-in-header` options.

 I defined the LaTeX commands as follows:
 
     \usepackage{marginnote}
     % positive dimension moves down!
     \newcommand{\blockNum}[1]{\marginnote{{\tiny #1}}[2\parskip]}
     \newcommand{\paraNum}[1]{\marginnote{{\tiny #1}}[0.25\baselineskip]}
 
 The reason I use the `marginnote` package rather than `marginpar`
 is that it doesn't use floats, so that there is no risk to run
 out of float memory.
 
 Unfortunately the CSS styling has its problems, so it is more complicated:
 
    body { padding-left: 6em; padding-right: 5em; }
    span.paraNum, div.blockNum { /* NB negative margin! */
        font-size: xx-small;
        position: relative; 
        left: -5em;
    }
    /* Remove unwanted indent */
    .paraNumLen1, .blockNumLen1 {
        margin-left: -0.75em; 
    }
    .paraNumLen2, .blockNumLen2 {
        margin-left: -1.5em; 
    }
    /* Vertical adjustment */
    div.blockNum {
        /* top: 1em; */
        margin-bottom: -3em;
    }

 The positioned span leaves behind an indent at the beginning of
 the paragraph which must be compensated for with a negative left
 margin, and the amount of negative margin must be adjusted to the
 width of the span contents. On the flip side all ASCII digits are
 the same width even in most proportional fonts, so the amount of
 negative margin needed is proportional to the number of digits in
 the block index number. Therefore I have inserted an extra class
 `paraNumLenSTRINGLEN`, where `STRINGLEN` is the length of the
 block index number in characters, so you can style the spans
 separately based on them.
 
 The divs numbering the non-paragraph blocks needs vertical adjustment,
 sometimes differently for different block types. You can achieve that
 with CSS like:
 
     div.CodeBlock:first-child { margin-bottom: -3.5em }
 
 Its LaTeX counterpart would also need vertical adjustment but I
 haven't got that to actually work. At least you can make the
 number `\tiny` to minimalize the effect.
 
 What's worse a `\marginnote` right before a `\paragraph` pulls the
 `\paragraph` with it into the margin. The workaround seems to be to only
 use three header levels! :-(

=cut

no warnings qw[ uninitialized numeric ];

use utf8;  # No UTF-8 I/O with JSON!

# no indirect;
# no autovivification; # Don't pullute the AST!

use subs qw[ cut ];

use JSON::MaybeXS;
use Data::Rmap qw[ rmap_hash rmap_array cut ]; # Data structure traversal support.
use List::AllUtils 0.09 qw[ all none pairs ];
use Scalar::Util qw[ refaddr blessed ];

# The block element types to number: 1 == true, 0 == false
my %block_type = (
    'Plain'          => 0,
    'Para'           => 1,
    'CodeBlock'      => 1,
    'RawBlock'       => 0,
    'BlockQuote'     => 1,
    'OrderedList'    => 1,
    'BulletList'     => 1,
    'DefinitionList' => 1,
    'Header'         => 0,
    'HorizontalRule' => 0,
    'Table'          => 1,
    'Div'            => 1,  # Don't falsify this!
);

# sprintf formats for the raw html/latex to insert
my %num_fmt = (
    html => +{
        Div  => '<div class="blockNum blockNumLen%d">%d</div>',
        Para => '<span class="paraNum blockNumLen%d">%d</span>',
    },
    latex => +{
        Div  => '\blockNum{%d}',
        Para => '\paraNum{%d}',
    },
);

my %sprintf_args = (
    html  => sub { ( length($_[0]), $_[0] ) },
    latex => sub { $_[0] },
);

for my $href ( \%num_fmt, \%sprintf_args ) {
    $href->{html5} = $href->{html};
}

# GET DOCUMENT	

my $to_format = shift @ARGV;

my $json = do { local $/; <>; };

# List of supported formats
print $json and exit 0 if none { $_ eq $to_format }  qw[ html html5 latex ];

my $JSON = JSON::MaybeXS->new( utf8 => 1 );

my $doc = $JSON->decode( $json );

my $num_fmt = $num_fmt{$to_format};

my $i = 1;

rmap_hash {
    my $type = $_->{t};
    $block_type{$type} or cut;
    if ( 'Div' eq $type ) {
        return unless grep { /^number_me$/ } @{ $_->{c}[-2][1] }; # look for "number_me" class
        unshift @{ $_->{c}[-1] }, mk_num( qw[ Block Div ] );
        # local $block_type{Div} = 0;
        # $_[0]->recurse;
        return;
    }
    elsif ( 'Para' eq $type ) {
        unshift @{ $_->{c} }, mk_num( qw[ Inline Para ] );
        cut;
    }
    else {
        my $num = mk_num( qw[ Block Div ] );
        my $div = mk_elem( Div => [ ["",['number_me', ($type)],[]], [ $num, $_ ] ] );
        $_ = $div;
        cut;
    }
} $doc;

print {*STDOUT} $JSON->encode( $doc );

# mk_elem( $type => $contents );
sub mk_elem {
    my($type => $contents) = @_;
    return +{ t => $type, c => $contents };
}

sub mk_num {

    mk_elem( "Raw$_[0]" => [ 
            $to_format => sprintf $num_fmt->{$_[1]}, $sprintf_args{$to_format}->($i++) ] );
}

__END__
