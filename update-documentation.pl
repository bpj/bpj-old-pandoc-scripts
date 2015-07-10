#!/usr/bin/env perl
use 5.014;
use strict;
use warnings;
no warnings qw[ uninitialized numeric ];


use utf8::all;

# use utf8;

# use open ':utf8';
# use open ':std';

# use autodie 2.12;

no indirect;
no autovivification;

use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case ];

use Path::Tiny 0.068 qw[ path tempfile tempdir cwd ];
use Git::Repository;
use Pod::Abstract;
use Pod::Abstract::BuildNode qw[ node ];
use Pod::Abstract::Filter::cut;
use WWW::Shorten 'GitHub';

GetOptionsFromArray( \@ARGV, 'force|f' => \my $force ) or die "Bad options";
 
my $url = 'https://github.com/bpj/bpj-pandoc-scripts/blob/master/scripts/';

my $cut = Pod::Abstract::Filter::cut->new;

my( $scripts_dir, $wiki_dir ) = qw[ scripts wiki ];
for my $dir  ( $scripts_dir, $wiki_dir ) {
    my $name = $dir;
    $dir = path( $name );
    $dir->is_dir or die "Couldn't find '$name' directory\n";
}

my $repo = Git::Repository->new( work_tree => '.' );

my $readme          = path 'README.pod';
my $wiki_home       = $wiki_dir->child( 'Home.md' );
my $readme_mtime    = $readme->is_file ? $readme->stat->mtime : 0;
my $wiki_home_mtime = $wiki_home->is_file ? $wiki_home->stat->mtime : 0;

my(@summaries, @wiki_index, );
my $update_readme = my $update_wiki = $force;

DOC:
for my $perl ( sort grep { m!\Ascripts/! and /\.pl\z/ and $_->is_file } map { path $_ } $repo->run( 'ls-files' ) ) {
    my $perl_mtime = $perl->stat->mtime;
    my $name = $perl->basename;
    my $base = $perl->basename('.pl');
    push @wiki_index, "- [[$name|$base]]";
    my $pod = $wiki_dir->child( $base . '.pod' );
    my $fh = $perl->openr_utf8;
    my $pa = Pod::Abstract->load_filehandle($fh);
    $pa = $cut->filter( $pa );
    my($summary) = $pa->select(q{/head1[@heading eq 'DESCRIPTION']/:paragraph(0)});
    push @summaries, "=head3 $name", $summary ? $summary->pod : "Documentation for $name still to be written!";
    $update_readme ||= $perl_mtime > $readme_mtime;
    $update_wiki ||= $perl_mtime > $wiki_home_mtime;
    next DOC unless
           $force
        or !$pod->is_file
        or $perl_mtime > $pod->stat->mtime
        ;
    $repo->run( add => $perl );
    my $short_url = makeashorterlink($url . "/$name");
    my($link) = node->from_pod( qq!This is the documentation for L<< $name|$short_url >>.\n\n! );
    if (my($h1) = $pa->select('/head1(0)') ) {
        $link->insert_before($h1);
    }
    elsif ( my($enc) = $pa->select('/encoding(0)') ) {
        $link->insert_after($enc);
    }
    elsif ( my($child) = $pa->children ) {
        $link->insert_before($child);
    }
    else {
        $pa->unshift($link);
    }
    $pod->spew_utf8( $pa->pod );
    $repo->run( add => $pod );
}

if ( $update_readme ) {
    my $preamble = path 'readme-preamble.pod';
    $preamble->copy( $readme );
    $readme->append_utf8(join "\n\n", @summaries);
    $repo->run( add => $readme );
}

if ( $update_wiki ) {
    my $preamble = path 'wiki-preamble.md';
    $preamble->copy( $wiki_home );
    $wiki_home->append_utf8(join "\n", @wiki_index);
    $repo->run( add => $wiki_home );
}

__END__
