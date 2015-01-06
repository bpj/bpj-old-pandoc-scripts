#!/usr/bin/env perl
use strict;
use warnings;

# pandoc_texlogo.pl - turn "`LaTeX`{.logo}" etc. into "\LaTeX" when
# generating LaTeX and into "LaTeX" when generating HTML and other
# formats.

# You must install the CPAN modules JSON and Data::Rmap!

use File::Basename qw[basename];
$0 = basename($0);

use Pod::Usage;
use Getopt::Long qw[ GetOptions :config no_ignore_case no_auto_abbrev ];

use JSON qw[decode_json encode_json];
use Data::Rmap qw[rmap_hash];

no indirect;
no autovivification;

my %logo = (
    html => {
        TeX     => q[<span class="texlogo">T<sub>e</sub>X</span>],

        LaTeX   => q[<span class="texlogo">L<sup>a</sup>T<sub>e</sub>X</span>],

        LaTeX2e => q[<span class="texlogo">L<sup>a</sup>T<sub>e</sub>X 2<sub class="lc">&epsilon;</sub></span>],

        XeTeX   => q[<span class="texlogo">X<sub>&#x01dd;</sub>T<sub>e</sub>X</span>],

        XeLaTeX =>
          q[<span class="texlogo">X<sub>&#x01dd;</sub>L<sup>a</sup>T<sub>e</sub>X</span>],
    },
);

my $css = <<'END_CSS';
.texlogo {
    font-family: serif;	
    letter-spacing: 1px;
    white-space: nowrap;
}

.texlogo sup {
    text-transform: uppercase;
    letter-spacing: 1px;
    font-size: 0.85em;
    vertical-align: 0.15em;
    margin-left: -0.36em;
    margin-right: -0.15em;
}

.texlogo sub {
    text-transform: uppercase;
    vertical-align: -0.5ex;
    margin-left: -0.1667em;
    margin-right: -0.125em;
    font-size: 1em;
}

.texlogo sub.lc {
    text-transform: lowercase !important;
}
END_CSS

GetOptions (
    'help|h' => sub { pod2usage(-verbose => 99, -sections=>[qw/NAME DESCRIPTION OPTIONS VERSION/]) },
    'man' => sub { pod2usage(-verbose => 2 ) },
    'css' => sub { print STDOUT $css and exit 0 },
) or pod2usage(1);

my $format = shift @ARGV;
my $raw = $format =~ /latex|context/ ? 'tex' : $format =~ /html/ ? 'html' : $format;
my $data = decode_json do { local $/; <>; };

rmap_hash {
    my $elem = $_;
    return unless 'HASH' eq ref $elem;
    # return unless 2 == grep { /^[tc]$/ } keys %$elem;
    return unless $elem->{t} and 'Code' eq $elem->{t};
    return unless grep { /^(?:tex)?logo$/ } @{$elem->{c}[0][1]};
    my $name = $elem->{c}[-1];
    if ( 'tex' eq $raw ) {
        $_ = +{ t => 'RawInline', c => [ $raw, "\\$name\{}" ] };
    }
    elsif ( $logo{$raw}{$name} ) {
        $_ = +{ t => 'RawInline', c => [ $raw, $logo{$raw}{$name} ] };
    }
    elsif ( $logo{$raw}{TeX} ) {
        (my $logo = $name ) =~ s/TeX/$logo{$raw}{TeX}/g;
        $_ = +{ t => 'RawInline', c => [ $raw, $logo ] };
    }
    else { $_ = +{ t => 'Str', c => $name } }
    return;
} $data;

if ( 'html' eq $raw and exists $data->[0]{unMeta} ) {
    my $css_meta =$data->[0]{unMeta}{'include-css'} ||= +{t=>'MetaList', c=>[]};
    if ( eval { 'MetaList' eq $css_meta->{t} } ) {
        push @{$css_meta->{c}}, +{ t=> 'MetaString', c => $css };
    }
}

print encode_json $data;

__END__

# BEGIN GENERATED POD #

=pod

=encoding UTF-8

=head1 NAME

pandoc-texlogo.pl - pandoc filter to display TeX logos intelligently.

=head1 VERSION

0.03

=head1 SYNOPSIS

    pandoc -F pandoc-texlogo.pl [OPTIONS] [-|FILE...]

=head1 DESCRIPTION

pandoc-texlogo.pl is a L<< pandoc|http://pandoc.org/ >> filter to help
display the logos for TeX, LaTeX etc. correctly in in LaTeX (including
when generating PDF!) and ConTeXt output while also rendering them
sensibly in other formats.

=head1 OPTIONS

In normal usage, as a pandoc filter, you need not and can not pass any
options. Nevertheless there are a few options which you can use when
invoking the script directly:

=head2 B<< --css >>

Will print the CSS code needed to render the HTML logos generated by
this script to STDOUT and then exit.

=head2 B<< -h >>, B<< --help >>

Will print some help.

=head2 B<< --man >>

Will display the full manual for the script.

=head1 HOW IT WORKS

If your pandoc-markdown input file contains inline code elements with a
class C<< .texlogo >> (or for backwards compatibility also C<< .logo >>)
like C<< `LaTeX`{.texlogo} >> (although the text of the 'code' --
hereafter the I<< CODETEXT >> -- can be anything) then this filter will
replace it with something it thinks makes sense in the current output
format:

=head2 If the output format is C<< latex >> or C<< context >>:

Will output a raw C<< tex >> element C<< \CODETEXT{} >> (i.e.
C<< `TeX`{.texlogo} >> -E<gt> C<< \TeX >>,
C<< `AnyThing`{.texlogo} >> -E<gt> C<< \AnyThing >> etc. -- no
validation is performed!)

=head2 If the output format is another supported format

The filter has predefined output strings for some output formats and
some _CODETEXT_s. Each C<< .texlogo >> code element will be replaced in
the pandoc AST with a raw markup element of the appropriate format.

If the filter has a special output string value associated with the
output format and the exact C<< CODETEXT >> the output string will be
set to that value. Otherwise if there is an output string value
associated with C<< TeX >> for that output format every occurrence of
the substring C<< TeX >> within the I<< CODETEXT >> with that value, so
that e.g. for HTML C<< `ConTeXt`{.texlogo} >> will become
C<< Con<span class="texlogo">T<sub>e</sub>t >> even if no special string
is associated with the I<< CODETEXT >> C<< ConTeXt >>.

The currently supported output formats and their _CODETEXT_s with
predefined raw markup replacement strings are:

=over

=item *

C<< html >>

(Actually any output format with the substring C<< html >> in the output
format name pandoc gives to the filter!)

=over

=item *

C<< TeX >>

=item *

C<< LaTeX >>

=item *

C<< LaTeX2e >>

=item *

C<< XeTeX >>

=item *

C<< XeLaTeX >>

=back

=back

=head2 Any other output format:

The code element will be replaced with a plain string element with a
text equal to the I<< CODETEXT >>, e.g. C<< `LaTeX`{.texlogo} >> will
become C<< LaTeX >> without any special formatting.

=head1 CSS

If the output format is HTML (Actually any output format with the
substring C<< html >> in the output format name pandoc gives to the
filter!) some CSS appropriate for rendering the HTML code for TeX logos
which this filter generates will be inserted into the metadata of your
document. More exactly these steps are performed:

=over

=item 1.

If the metadata entry C<< include-css >> does not exist it is created as
a metadata list.

=item 2.

If the metadata entry C<< include-css >> exists (or was just created)
and is a metadata list a metadata string element containing the
appropriate CSS code is added to it.

=back

You can now insert code like that shown L<<< under I<< In your HTML
template: >> in the SYNOPSIS|#In-your-HTML-template >>> into your HTML
template and the CSS code will be inserted into your standalone HTML
output as needed.

Alternatively you can invoce the script with the B<< --css >> option and
redirect the output to a file which you then link from your HTML
document:

    perl pandoc_texlogo.pl --css >texlogo.css

=head1 NEEDED CPAN MODULES

Install these with your favorite CPAN client. (try C<< perldoc cpan >>
on the commandline if you don't have one!)

=over

=item *

JSON

=item *

Data::Rmap

=item *

autovivification

=item *

indirect

=back

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 AUTHOR

Benct Philip Jonsson E<lt>bpjonsson@gmail.comE<gt>

=head1 COPYRIGHT

Copyright 2014- Benct Philip Jonsson

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

