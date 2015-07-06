#!/usr/bin/env perl
use 5.014;
use strict;
use warnings;
no warnings qw[ uninitialized numeric ];

use utf8;  # No UTF-8 I/O with JSON!

# use autodie 2.12;

# no indirect;
# no autovivification; # Don't pullute the AST!

use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case ];

use JSON::MaybeXS;
use Data::Rmap qw[ rmap_hash rmap_array cut ]; # Data structure traversal support.
use List::AllUtils 0.09 qw[ all none pairs any indexes ];
use Scalar::Util qw[ refaddr blessed ];
use Pod::Usage;

GetOptionsFromArray(
    \@ARGV,
    'help|h' => sub { pod2usage( -verbose => 1 ) },
    'man|m'  => sub { pod2usage( -verbose => 2 ) },
    'prereqs|p' => sub { pod2usage( -verbose => 99, -sections => 'PREREQUISITES' ) },
    'cpan-prereqs|cpan|c' => sub { pod2usage( -verbose => 99, -sections => 'PREREQUISITES/CPAN prerequisites' ) },
) or pod2usage(2);

our $tabularize_all;

my %align = (    #
    AlignLeft    => 'l',    #
    AlignRight   => 'r',    #
    AlignCenter  => 'c',    #
    AlignDefault => 'l',    #
);                          #

my $colsep        = mk_elem( RawBlock  => [ latex => q{ & } ] );
my $linebreak     = mk_elem( RawBlock  => [ latex => q{ \\\\ } ] );
my $hline         = mk_elem( RawBlock  => [ latex => q{ \\\\ \\hline } ] );
my $end_tabular   = mk_elem( RawBlock  => [ latex => '\\end{tabular}' ] );
my $begin_caption = mk_elem( RawInline => [ latex => '\\caption{' ] );
my $end_group     = mk_elem( RawInline => [ latex => '}' ] );

sub div2table {
    my($div) = @_;
    my $contents = $div->{c}[-1];
    my @table = rmap_hash {
        return unless exists $_->{t} and 'Table' eq $_->{t};
        return $_;
    } $contents;
    return unless @table;
    my @caption;
    TABLE:  # This loop doesn't mean there *should* be more than one table in a div!
    for my $table ( @table ) {
        my($tabular, $caption) = table2tabular($table);
        $table = $tabular;
        next TABLE unless $caption;
        push @caption, $caption;
    }
    my $attrs = $div->{c}[-2];
    my( $id, $classes ) = @{$attrs};
    my $float = grep { /^float$/ } @$classes;
    my( $pos ) = grep { /^pos:\S+$/ } @$classes;
    $pos and $pos =~ /:(\S+)$/ and $pos = "[$1]";
    $float ||= !!$pos || q{};
    $float &&= '*';
    if ( $float || $id || scalar @caption ) {
        my $begin_table = mk_elem( RawBlock => [ latex => "\\begin{table$float}$pos" ] );
        unshift @table, $begin_table;
        if ( scalar @caption ) {
            push @table, mk_elem( Plain => [ $begin_caption, @caption, $end_group ] );
        }
        if ( $id ) {
            push @table, mk_elem( RawBlock => [ latex => "\\label{tab:$id}" ] );
        }
        push @table, mk_elem( RawBlock  => [ latex => "\\end{table$float}" ] );
;
    }
    return mk_elem( Div => [ $attrs, \@table ] );
}

sub table2tabular {
    local $_;
    my($table) = @_;
    my($caption, $aligns, $widths, $headers, $rows) = @{ $table->{c} };
    undef $caption unless scalar @$caption; # No content in caption!
    $caption &&= mk_attr_elem( Span => $caption, +{class => 'caption'} );
    my $align = join q{ }, map { $align{ $_->{t} } } @$aligns;
    my @rows;
    if ( scalar @$headers ) {   # Not a headerless table!
        push @rows, row2div( $headers, 1 );
    }
    push @rows, map { row2div( $_ ) } @$rows;
    my $begin_tabular =  mk_elem( RawBlock => [ latex => "\\begin{tabular}{$align}" ] );
    my $tabular = mk_attr_elem( Div => [ $begin_tabular, @rows, $end_tabular ], +{ class => 'tabular' } );
    return (  $tabular, $caption  );
}

sub row2div {
    my($row, $is_header) = @_;
    my @row = map {; ( mk_attr_elem( Div => $_, +{class=>'cell'} ), $colsep ) } @$row;
    $row[-1] = $is_header ? $hline : $linebreak;
    return mk_attr_elem( Div => \@row, +{ class => $is_header ? 'header' : 'row' } );
}

# GET DOCUMENT	

my $to_format = shift @ARGV;

my $json = do { local $/; <>; };

# List of supported formats
# print $json and exit 0 if none { $_ eq $to_format }  qw[ latex ];

my $JSON = JSON::MaybeXS->new( utf8 => 1 );

my $doc = $JSON->decode( $json );

$tabularize_all = $doc->[0]{unMeta}{tabularize_all};

rmap_hash {
    return unless exists $_->{t} and $_->{t} =~ /^(Div|Table)$/;
    if ( 'Table' eq $1 ) {
        return unless $tabularize_all;
        my $table = $_;
        $_ = mk_attr_elem( Div => [ $table ], +{ class => 'tabularize' } );
    }
    return unless grep { /^tabularize$/ } @{$_->{c}[-2][1]}; # Have class?
    return unless my $ret = div2table( $_ );
    $_ = $ret;
    return;
} $doc;

print {*STDOUT} $JSON->encode( $doc );

# mk_elem( $type => $contents );
sub mk_elem {
    my($type => $contents) = @_;
    return +{ t => $type, c => $contents };
}

# mk_attr_elem( $type, $contents, ?\%attr );
sub mk_attr_elem {
    my( $type, $contents, $attr ) = @_;
    $attr ||= +{};
    'HASH' eq uc ref($attr)
        or die sprintf "Expected attr to be hashref at %s, line %s.\n", @{[caller]}[1,2];
    my @level = ( 0+$attr->{level} || () );
    my $id = delete $attr->{id} || "";
    my $class = delete $attr->{class} || [];
    # my $key_val = $attr->{key_val} || +{};
    'ARRAY' eq uc ref($class) or $class = [$class];
    my @kv = pairs %$attr;
    return mk_elem( $type => [ @level, [$id,$class,\@kv], $contents ] );
}


__END__

# # DOCUMENTATION # #

=encoding UTF-8

=head1 NAME

pandoc-tabularize.pl - pandoc filter to use tabular instead of longtable
in LaTeX

=head1 VERSION

0.001

Date: 2015-07-06

=head1 SYNOPSIS

    pandoc -t latex -F pandoc-tabularize.pl [-M tabularize_all=true] [OPTIONS] FILE_NAME ...

=head1 DESCRIPTION

C<< pandoc-tabularize.pl >> is a pandoc filter to use the C<< tabular >>
environment instead of the C<< longtable >> package in LaTeX output.
This is especially useful if you want to use C<< twocolumn >> mode,
which doesn't work with C<< longtable >>.

There are two ways to get a C<< tabular >> environment -- possibly
wrapped in a C<< table >> environment -- instead of a C<< longtable >>:

=over

=item 1.

Put a key-value pair C<< tabularize_all: true >> in your metadata block,
(or pass C<< -M tabularize_all=true >> on the commandline).

This will turn I<< all >> tables into C<< tabularize >> environments,
and if they have a caption also wrap them in a C<< table >> environment.

=item 2.

Wrap the table in a C<< <div> >> with a class C<< tabularize >>.

If you also add a class C<< float >> the C<< tabularize >> environment
will be wrapped in a C<< table* >> environment and hence become a float.

If you add a class like C<< pos:t >> or C<< pos:p >> there will also be
a C<< table* >> environment, with whatever came after C<< pos: >> in the
class name as the optional argument to that environment.

Any C<< id >> on the C<< <div> >> will also be added as a
C<< \label{tab:ID} >>. This is probably actually unnecessary since
pandoc will add a generally much more useful
C<< \hyperdef{}{ID}{\label{ID}} >> above the C<< <div> >>, but it's
there in case you find some use for it

=back

Note that the content of the div should be a normal Pandoc Markdown
table (of any type!) with whatever Markdown markup normally works in a
table.

=head2 Example

In your Markdown document:

    ---
    title: Test of twocolumn table hack filter
    classoption: twocolumn
    tabularize_all: true
    ...

    <div id=firsttable class=tabularize>

    Quia Iusto          Et Quisquam         Est Expedita
    ------------------  ------------------  -------------------
    Facilis Aut         Et Aut              *Veritatis* Eveniet
    Blanditiis Sit      Eligendi Provident  Sunt Ducimus

    : This should be a non-floating tabularize

    </div>

    Minus Amet           Pariatur Soluta     Voluptate Consectetur
    ------------------  ------------------  ----------------------
    Eos Possimus        A Quasi             Vel Autem
    Est Magni           Assumenda Volupta   Id Laboriosam

    : This also, with `tabularize_all: true`

    <div class="tabularize float">

    -------------------------------------------------------
    Quia Ut             Sint Ratione        Voluptas Magnam
    ------------------  ------------------  ---------------
    Blanditiis Enim     Animi Ut            Eaque Eum
    Quidem Aut          Et Vitae            Nesciunt Voluptatem

    Voluptatem Illo     Iste Cupiditate     Explicabo Vel
    Est [Dolorem][]     Consequuntur Eaque  In Impedit
    -------------------------------------------------------

    : This should be a floating table*

    </div>

    <div class="tabularize pos:b">

    Expedita Ut     Fugit Numquam       Quas Quia
    --------------  ------------------  ---------
    Nisi Aperiam    Quasi Unde  In Quis
    Repellat Tenet  Est Sit Facere Dolore

    : this floats to the bottom of the page

    </div>

=head1 PREREQUISITES

L<< pandoc|http://pandoc.org >>

L<< perl|https://www.perl.org/get.html >>

=head2 CPAN prerequisites

L<< Data::Rmap|Data::Rmap >>

L<< JSON::MaybeXS|JSON::MaybeXS >>

L<< List::AllUtils~0.09|List::AllUtils >>

=head1 NEW TO PERL?

Get perl:
L<< https://www.perl.org/get.html|https://www.perl.org/get.html >>

How to install modules:
L<< http://www.cpan.org/modules/INSTALL.html|http://www.cpan.org/modules/INSTALL.html >>

=head1 AUTHOR

Benct Philip Jonsson E<lt>bpjonsson@gmail.comE<gt>,
L<< https://github.com/bpj|https://github.com/bpj >>

=head1 COPYRIGHT

Copyright 2015- Benct Philip Jonsson

=head1 LICENSE

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut


