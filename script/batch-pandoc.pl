#!/usr/bin/env perl
use 5.014;
use strict;
use warnings FATAL => 'all';

use utf8::all;

use autodie 2.12;

no warnings qw[ uninitialized numeric ];

no indirect;
no autovivification;

use Getopt::Long
  qw[ GetOptionsFromArray :config no_ignore_case no_auto_abbrev pass_through ];

use Path::Tiny 0.068 qw[ path cwd tempdir ];
use Capture::Tiny qw[ capture_stderr ];

my $cwd;
BEGIN { $cwd = cwd }
END { chdir $cwd }

use subs qw[ dir2target ];

my %opt = (    #
    input_dir        => undef,       #
    output_dir       => undef,       #
    from_extension   => '.md',       #
    to_extension     => '.html',     #
    exclude_matching => undef,       #
    copy_matching    => undef,       #
    read_css         => 1,
    include_yaml     => undef,       #
    titles           => undef,       #
    wikilinks        => undef,       #
    pandoc           => 'pandoc',    #
);                                   #

GetOptionsFromArray(
    \@ARGV,
    \%opt,
    'input_dir|input-dir|inputdir|i=s',
    'output_dir|output-dir|outputdir|o=s',
    'from_extension|from-extension|fromextension|f=s',
    'to_extension|to-extension|toextension|t=s',
    'exclude_matching|exclude-matching|excludematching|x=s',
    'copy_matching|copy-matching|copymatching|c=s',
    'read_css|read-css|readcss|C:1',
    'include_yaml|include-yaml|includeyaml|y:1',
    'titles:1',
    'wikilinks|W:s',
    'pandoc|P=s',
) or die "Error getting options\n";

for my $this ( qw[ from to ] ) {
    $opt{"${this}_extension"} =~ s/\A\.//;
    $opt{"${this}_extension"} || die "--$this-extension '.EXT' required!\n";
}
my $ext_re = qr/\Q.$opt{from_extension}\E\z/;

$opt{input_dir} &&= path( $opt{input_dir} );
$opt{input_dir} || die "--input-dir PATH required!\n";
$opt{output_dir}
  ||= $opt{input_dir}->sibling( $opt{input_dir}->basename . "-$opt{to_extension}" );
$opt{output_dir} = path( $opt{output_dir} ) unless ref $opt{output_dir};

# $opt{output_dir}->mkpath;

for my $this ( qw[ input output ] ) {
    my $key = "${this}_dir";
    $opt{$key} = $opt{$key}->absolute;
    $opt{$key}->is_dir || die "--$this-dir not a directory: $opt{$key}\n";
}

if ( defined $opt{wikilinks} ) {
    $opt{wikilinks} ||= "[%s](%s.$opt{to_extension})";
}

for my $key ( qw[ exclude_matching copy_matching ] ) {
    $opt{$key} &&= qr/$opt{$key}/;
}

chdir $opt{input_dir};

dir2target( $opt{input_dir} );

sub dir2target {
    my ( $sourcedir ) = @_;
    $sourcedir = path( $sourcedir );
    die "Usage: dir2target(\$dirpath)\n" unless $sourcedir->is_dir;
  LOOP:
    for my $source ( $sourcedir->children ) {
        if ( $opt{exclude_matching} and $source =~ $opt{exclude_matching} ) {
            warn "Excluding: $source\n";
            next LOOP;
        }
        if ( $source->is_dir ) {
            dir2target( $source );
        }
        elsif ( $source->is_file ) {
            my $rootname = $source->basename( $ext_re );
            my $target
              = $opt{output_dir}->child( $source->relative( $opt{input_dir} ) );
            if ( $source =~ $ext_re ) {
                $target = $target->sibling(
                    $rootname . ".$opt{to_extension}" );
                die "Target exists and is not a file: $target"
                  if $target->exists and not $target->is_file;
                $target->parent->mkpath;
                warn "Processing: $source -> $target\n";
                $source = fix_wikilinks( $source ) if $opt{wikilinks};
                my @args;
                if ( $opt{titles} ) {
                    my $title = ucfirst $rootname;
                    $title =~ s/(?<!\\)-/\N{SPACE}/g;
                    $title =~ s/\\(\W)/$1/g;
                    $title =~ s/([^\w\s]|_)/\\$1/g;
                    push @args, ( -M => "title=$title" );
                } ## end if ( $opt{titles} )
                if ( $opt{read_css} ) {
                    my $css_file = $source->sibling( "$rootname.css" );
                    if ( $css_file->is_file ) {
                        my $css = $css_file->slurp_utf8;
                        push @args, ( -M => "include_css=$css" ) if length $css;
                    }
                }
                if ( $opt{include_yaml} ) {
                    my $yaml
                      = $source->sibling( $rootname . '.yaml' );
                    push @args, ( $yaml ) if $yaml->is_file;
                }
                my $stderr = capture_stderr {
                    system { $opt{pandoc} } pandoc => @ARGV,
                      @args,
                      -o => $target,
                      $source;
                };
                die $stderr if $stderr;
            } ## end if ( $source =~ $ext_re)
            elsif ( $opt{copy_matching} and $source =~ $opt{copy_matching} ) {
                $source->copy( $target );
            }
        } ## end elsif ( $source->is_file )
    } ## end LOOP: for my $source ( $sourcedir...)
} ## end sub dir2target

sub fix_wikilinks {
    state $tmpdir = tempdir( CLEANUP => 1 );
    my ( $orig ) = @_;
    my $text = $orig->slurp_utf8;
    return $orig unless $text =~ s{\[\[(?:([^|]*)\|)?(.*?)\]\]}{
        my $linktext = $1;
        my $wikilink = $2;
        $linktext //= $wikilink;
        $wikilink =~ s/\s+/-/g;
        sprintf $opt{wikilinks}, $linktext, $wikilink;
    }seg;
    my $tmp = $tmpdir->child( $orig->basename );
    $tmp->spew_utf8( $text );
    return $tmp;
} ## end sub fix_wikilinks

__END__

=for pandoctext

# NAME

batch-pandoc.pl - batch-convert files under a directory with pandoc.

# SYNOPSIS

    perl batch-pandoc.pl -i INPUT_DIR [OPTIONS]  [PANDOC_OPTIONS]

# DESCRIPTION

batch-pandoc.pl is a perl script to batch-convert files with a
certain extension in a directory and its descendants with pandoc,
creating a mirror directory structure with converted files.

Suppose you have a directory-structure like:

    site-md/
        index.md
        introduction/
            bits.md
            image.png
            index.md
            pieces.md
        usage/
            index.md
            that.md
            this.md
            other/
                index.md
                more.md

Then the invocation

    perl batch-pandoc.pl -i site-md -o site -f md -t html -c '\.png\z'

will create a directory tree under `site` which is
identical to `site-md`, except that each `.md` file
has been replaced by a `.html` file which has been
converted with pandoc.

Any commandline argument which is not recognised as a
batch-pandoc.pl option is passed on to pandoc,
so that if you for example want to use a certain pandoc template
in the conversion you can just add the pandoc option
`-- template=mytemplate.html` to your commandline.

This script doesn't try to be smarter than that. If you for
example want to include a navigation bar or document-specific
CSS you will have to solve that with a pandoc template and
document metadata.

# OPTIONS

batch-pandoc.pl recognises the following options. All other
commandline arguments are passed along to pandoc. Where there is
a name-clash between batch-pandoc.pl and pandoc short options you
have to use the long pandoc option names, or in the case of
`-f` and `-t` the synonymous `-r` and `-w`. Note
that it is useless to specify an `-o/--output` option as one
will be added automatically to the end of the pandoc commandline,
overriding it.

**-i** _path/to/dir_, **--input-dir**=_path/to/dir_

:   (Required)

:   The directory containing the input files. This option has no
    default, and thus it is an error to omit it.

**-o** _path/to/dir_, **--output-dir**=_path/to/dir_

:   The directory below which to put the output files. If omitted a sibling to
    **--input-dir** with `-TO-EXTENSION` appended will be
    used. This directory and its descendant directories will be
    created as needed.

**-f** _.ext_, **--from-extension**=_.ext_

:   (Default: `.md`)

:   The file extension for input files. The leading dot will be added if missing.

**-t** _.ext_, **--to-extension**=_.ext_

:   (Default: `.html`)

:   The file extension for output files. The leading dot will be added if missing.

**-c** _regex_, **--copy-matching**=_regex_

:   A Perl regular expression. If supplied any files below **--input-
    dir** with a name matching it will be copied to the
    corresponding position below **--output-dir**. Typically it
    should match one or more file extensions and anchor to the end-of-
    string, e.g. `\.(?:jpe?g|png|gif)\z`.

**-W** \[_sprintf-format_\], **--wikilinks**\[=_sprintf-format_\]

:   If present, with or without an argument any input file
    containing wikilinks of the form `[[LINK TEXT|WIKILINK]]` or `[[WIKILINK]]` will be copied to a temporary
    file with those links substituted by the return value of
    `sprintf($sprintf_format, $linktext, $wikilink)`, and
    the temporary file will be used as input file instead of
    the original.

:   The sprintf-format defaults to `"[%s](%s.$to_extension")"`
    and the link text defaults to the wikilink text. The wikilink
    text will have any whitespace replaced with hyphens. Thus a
    wikilink like `[[normal usage]]` will become
    `[normal usage](normal- usage.html)` and a wikilink like
    `[[when used normally|normal usage]]` will become
    `[when used normally](normal- usage.html)` with the defaults.

:   This option is useful for example if you have cloned a
    [GitHub wiki](https://help.github.com/articles/about-github-wikis/)
    and want to convert it to some other format:

    :   perl batch-pandoc.pl -i myproject.wiki -t pdf -W -r markdown_github

:   will create a directory `myproject.wiki-pdf` containing the wiki pages in PDF format.

**--titles**_[=0|1]_

:    If the argument is true (!=0) or missing a title will be constructed from the input filename by removing the `--from-extension`, replacing hyphens with spaces and capitalizing the first word, and included in the pandoc arguments as `-M title=TITLE`.
    This option is useful when converting a cloned GitHub wiki but should not be used when the source files contain their own title information e.g. as Pandoc metadata or as HTML `<title>` elements.

**-C** _[0|1]_, **--include-css**_[=0|1]_

:    If the argument is true (!=0) or missing and there is a sibling file with the same basename as the source file but a `.css` extension that file will be copied and linked by including `--css=FILENAME` in the pandoc argument list.

**-Y** _[0|1]_, **--include-yaml**_[=0|1]_

:    If the argument is true (!=0) or missing and there is a sibling file with the same basename as the source file but a `.yaml` extension that file will be included as an input file on the pandoc argument list. This is useful if you want to make metadata accessible to external tools by keeping them in a separate file. To work as a pandoc metadata block the file has to begin and end with the `---` and `...` delimiters.

    On the other hand you can copy YAML metadata from markdown files to external files by saving a file `yaml.markdown` with the contents

    ````pandoc-template
    $if(titleblock)$
    $titleblock$
    $else$
    --- {}
    $endif$
    ````
    
    and then run with the commandline
    
    ````shell
    $ perl batch-pandoc.pl -i sourcedir -o sourcedir -f .md -t .yaml \
    -w markdown --template=yaml.markdown
    ````

**-P** _path/to/pandoc_, **--pandoc**=_path/to/pandoc_

:   (Default: `pandoc`)

:   Gives the path to the pandoc executable. Useful if you have
    several versions installed or use a wrapper script (in which case
    you would give the name or path of the wrapper).

# AUTHOR

Benct Philip Jonsson <bpjonsson@gmail.com>

# COPYRIGHT

Copyright 2015- Benct Philip Jonsson

# LICENSE

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

# SEE ALSO

[Pandoc](http://pandoc.org)
