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

use 5.010_001;
use strict;
use warnings FATAL => 'all';
no warnings qw[ uninitialized numeric ];

my $VERSION = '0.001000';

use utf8;  # No UTF-8 I/O with JSON.pm!

use autodie 2.12;

no indirect;
no autovivification; # Don't pullute the AST!

# use Getopt::Long qw[ GetOptionsFromArray :config no_ignore_case ];

use JSON qw[ decode_json encode_json ];
use Data::Rmap qw[ rmap_hash rmap_array cut ]; # Data structure traversal support.
use List::MoreUtils qw[ all ];
use Scalar::Util qw[refaddr];
use List::UtilsBy qw[ max_by ];
use Path::Class qw[ tempdir ];

sub rmap_element_lists (&@);

my $to_format = shift @ARGV;

my $doc = decode_json do { local $/; <>; };

my $option 
    = get_meta_opts( 
      +{ 
          doc => $doc, 
          opts => [ qw[ atx_headers bold_delimiter strikeout_style smallcaps_style tex_scripts links_as_notes ] ], 
        default => +{
            atx_headers     => 0,
            bold_delimiter => '*',
            strikeout_style => 'curly',
            smallcaps_style => 'lc2uc',
            tex_scripts => 0,
            links_as_notes => 1,
        },
          prefix => q{email_},
      }
  );

my %strike_style = (
    curly => sub {
        my($contents) = @_;
        unshift @$contents, mk_elem( Str => '{' );
        push @$contents, mk_elem( Str => '}' );
        return $contents;
    },
    square => sub {
        my($contents) = @_;
        unshift @$contents, mk_elem( Str => '[' );
        push @$contents, mk_elem( Str => ']' );
        return $contents;
    },
    uc => sub {
        my($contents) = @_;
        rmap_hash {
            return unless 'Str' eq $_->{t};
            $_->{c} = uc $_->{c};
            return;
        } $contents;
        return $contents;
    },
    lc2uc => sub {
        my($contents) = @_;
        rmap_hash {
            return unless 'Str' eq $_->{t};
            return if $_->{c} =~ /\p{Lu}/;
            $_->{c} = uc $_->{c};
            return;
        } $contents;
        return $contents;
    },
);

my %handler_for = (
    Header => sub {
        my($elem) = @_;
        return unless $option->{atx_headers};
        my $level = shift @{ $elem->{c} };
        my $hash = '#' x $level;
        $hash .= q{ };
        $elem->{t} = 'Div';
        push @{ $elem->{c}[-2][1] }, "header-$level";
        unshift @{ $elem->{c}[-1] }, mk_elem( Str => $hash );
        $elem->{c}[-1] = [ mk_elem( Para => $elem->{c}[-1] ) ];
        return $elem;
    },
    Emph => sub {
        state $delimiter = mk_elem( Str => '_' );
        my($elem) = @_;
        my $text = $elem->{c};
        unshift @$text, $delimiter;
        push @$text, $delimiter;
        return mk_elem( Span => [ [q{}, ['emph'], [] ], $text ] );
    },
    Strong => sub {
        state $delimiter = mk_elem( Str => $option->{bold_delimiter} );
        my($elem) = @_;
        my $text = $elem->{c};
        unshift @$text, $delimiter;
        push @$text, $delimiter;
        return mk_elem( Span => [ [q{}, ['strong'], [] ], $text ] );
    },
    Strikeout => sub {
        my($elem) = @_;
        my $type = lc $elem->{t};
        die qq[Unknown $type style: $option->{"$type\_style"}\n] unless exists $strike_style{$option->{"$type\_style"}};
        return mk_elem(
            Span => [
                [q{}, [$type], []],
                $strike_style{$option->{"$type\_style"}}->($elem->{c}),
            ],
        );
    },
    Superscript => sub {
        state $prefix = mk_elem( Str => ($option->{tex_scripts} ? '^{' : '^') );
        state $suffix = mk_elem( Str => ($option->{tex_scripts} ? '}' : '^') );
        my($elem) = @_;
        my $text = $elem->{c};
        unshift @$text, $prefix;
        push @$text, $suffix;
        return mk_elem( Span => [[q{}, ['sup'],[]], $text ] );
    },
    Subscript => sub {
        state $prefix = mk_elem( Str => ($option->{tex_scripts} ? '_{' : '~') );
        state $suffix = mk_elem( Str => ($option->{tex_scripts} ? '}' : '~') );
        my($elem) = @_;
        my $text = $elem->{c};
        unshift @$text, $prefix;
        push @$text, $suffix;
        return mk_elem( Span => [[q{}, ['sub'],[]], $text ] );
    },
    Code => sub {
        my($elem) = @_;
        my $code = \$elem->{c}[-1];
        my $max = max_by { length $_ } $$code =~ /\`+/g;
        $$code = $max ? "`$max $$code $max`" : "`$$code`";
        return $elem;
    },
    Link => sub {
        my($elem) = @_;
        my $text = $elem->{c}[0];
        my $url = $elem->{c}[1][0];
        my $title = $elem->{c}[1][1];
        $url =~ s/\Amailto://;
        if ( 1 == @$text ) {
            if ( 'Str' eq $text->[0]{t} and $url eq $text->[0]{c} ) {
                $text->[0]{c} = qq{<$text->[0]{c}>};
                return $text->[0];
            }
        }
        $title = qq{"$title" } if length $title;
        my $note = mk_elem( Str => "$title<$url>" );
        push @$text, mk_elem( Note => [ mk_elem( Para => [$note] ) ] );
        return mk_elem( Span => [[q{},['link'],[]], $text] );
    },
    Image => sub {
        my($elem) = @_;
        my $url = $elem->{c}[1][0];
        my $title = $elem->{c}[1][1];
        $title =~ s/\Afig://;
        $title = qq{"$title" } if length $title;
        my $note = mk_elem( Str => "$title<$url>" );
        $note = mk_elem( Note => [ mk_elem( Para => [$note] ) ] );
        return mk_elem( Span => [[q{},['image'],[]], [$elem, $note] ] );
    },
    BlockQuote => sub {
        state $temp = tempdir( CLEANUP => 1 );
        state $filecount = 'a';
        my($elem, $rmap, $meta) = @_;
        $rmap->recurse;
        my $doc = encode_json([ +{unMeta=>+{}}, [$elem] ]);
        my $text = $temp->file( "$filecount.txt" );
        my $json = $temp->file( $filecount++ . '.json' );
        $json->spew($doc);
        system ( "pandoc -r json -w plain $json > $text" )
            and die "Error converting blockquote with pandoc\n";
        $text = $text->slurp( iomode=>'<:encoding(UTF-8)' );
        # $text =~ s/\s+\z//;
        $text =~ s{^ ?}{>}mg;
        $text = mk_elem( Str => $text );
        return mk_elem( Plain => [$text] );
    },
);

rmap_hash {
    my($rmap) = @_;
    return unless exists $handler_for{$_->{t}};
    return unless defined $_->{c};
    return unless defined( my $res = $handler_for{$_->{t}}->($_, $rmap) );
    $_ = $res;
} $doc;


print {*STDOUT} encode_json $doc;

sub rmap_element_lists (&@) {
    my($callback, @data) = @_;
    # my %seen;
    rmap_array {
        return unless all { 'HASH' eq uc ref $_ } @$_;
        my @origs = @$_;
        my @new;
        for my $orig ( @origs ) {
            # next if $seen{ refaddr $orig }++;
            local $_ = $orig;
            my @ret = $callback->(@_);
            next unless scalar @ret;
            push @new, @ret;
        }
        $_ = \@new;
        return;
    } @data;
    return;
}

sub get_meta_opts {
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
sub _get_opt_val {
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
			if ( 'Str' eq $tag or 'MetaString' eq $tag or 'MetaBool' eq $tag ) {
				cut $_->{c};
			}
			elsif ( 'Code' eq $tag or 'CodeBlock' eq $tag ) {
				cut $_->{c}[-1];
			}
			return;
		} $data;
		return $opt;
	}
	return;
}

# Turn a pandoc metadata map into a plain hashref
sub _get_opt_map {
	my($href) = @_;
	my %ret;
	while ( my( $k, $v ) = each %$href ) {
		$ret{$k} = _get_opt_val($v);
	}
	return \%ret;
}

# Turn a pandoc metadata list into a plain arrayref
sub _get_opt_list {
	my( $aref ) = @_;
	my @ret = map { _get_opt_val($_) } @$aref;
	return \@ret;
}

sub mk_elem {
    my( $tag, $contents ) = @_;
    return +{ t => $tag, c => $contents };
}

__END__

# BEGIN GENERATED POD #

=pod

=encoding UTF-8

=head1 DESCRIPTION

No documentation yet!

TODO!

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

