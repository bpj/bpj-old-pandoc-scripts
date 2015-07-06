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

# use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case ];

use Path::Tiny 0.068 qw[ path tempfile tempdir cwd ];
use Git::Repository;
use Pod::Abstract;
use Pod::Abstract::BuildNode qw[ node ];
use Pod::Abstract::Filter::cut;
use WWW::Shorten 'GitHub';
 
my $url = 'https://github.com/bpj/bpj-pandoc-scripts/blob/master/scripts/';

my $cut = Pod::Abstract::Filter::cut->new;

my( $scripts_dir, $wiki_dir ) = qw[ scripts wiki ];
for my $dir  ( $scripts_dir, $wiki_dir ) {
    my $name = $dir;
    $dir = path( $name );
    $dir->is_dir or die "Couldn't find '$name' directory\n";
}

my $repo = Git::Repository->new( work_tree => '.' );


my @summaries;

DOC:
for my $perl ( sort grep { m!\Ascripts/! and /\.pl\z/ and $_->is_file } map { path $_ } $repo->run( 'ls-files' ) ) {
    my $name = $perl->basename;
    my $base = $perl->basename('.pl');
    my $pod = $wiki_dir->child( $base . '.pod' );
    my $fh = $perl->openr_utf8;
    my $pa = Pod::Abstract->load_filehandle($fh);
    $pa = $cut->filter( $pa );
    my($summary) = $pa->select(q{/head1[@heading eq 'DESCRIPTION']/:paragraph(0)});
    push @summaries, "=head3 $name", $summary ? $summary->pod : "Documentation for $name still to be written!";
    $repo->run( add => $perl );
    next DOC unless !$pod->is_file or $perl->stat->mtime > $pod->stat->mtime;
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

if ( @summaries ) {
    my $readme = path 'README.pod';
    my $preamble = path 'readme-preamble.pod';
    $preamble->copy( $readme );
    $readme->append_utf8(join "\n\n", @summaries);
    $repo->run( add => $readme );
}

__END__
