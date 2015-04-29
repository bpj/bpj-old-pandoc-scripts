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

use subs qw[ dir2pdf ];

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

dir2pdf( $opt{input_dir} );

sub dir2pdf {
    my ( $sourcedir ) = @_;
    $sourcedir = path( $sourcedir );
    die "Usage: dir2pdf(\$dirpath)\n" unless $sourcedir->is_dir;
  LOOP:
    for my $source ( $sourcedir->children ) {
        if ( $opt{exclude_matching} and $source =~ $opt{exclude_matching} ) {
            warn "Excluding: $source\n";
            next LOOP;
        }
        if ( $source->is_dir ) {
            dir2pdf( $source );
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
                    if ( -e $css_file and !-d $css_file ) {
                        my $css = $css_file->slurp_utf8;
                        push @args, ( -M => "include_css=$css" ) if length $css;
                    }
                }
                if ( $opt{include_yaml} ) {
                    my $yaml
                      = $source->sibling( $rootname . '.yaml' );
                    push @args, ( $yaml ) if -e $yaml and !-d $yaml;
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
} ## end sub dir2pdf

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
