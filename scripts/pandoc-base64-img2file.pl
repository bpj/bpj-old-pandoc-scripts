#!/usr/bin/env perl

=pod

Pandoc filter which intercepts image elements with data URIs
with Base64 encoded image data, decodes the data and writes
the image to a file with a hopefully correct extension in a
directory designated by the user as a metadata value.

Usage:

    pandoc -F pandoc-base64-img2file.pl \
          [-M image_dir=decoded_images] \
          -f html some.html -t FORMAT -o FILE

image_dir defaults to ./decoded_images

Filenames are on the pattern "decodedImage0000.EXT",
where "0000" is incremented for each data URI encountered
and "EXT" actually is whatever comes after "image/" in the
MIME type of the data URI.

IMPORTANT: You must make sure that there is no whitespace in
the data URIs in the source, and thus that each is all on
one line, or pandoc will become confused.

=cut

use 5.008005;
use strict;
use warnings;
no warnings qw[ uninitialized numeric ];

# IMPORTS                                       # {{{1}}}

use utf8;

# use autodie 2.12;

# no indirect;
# no autovivification;

use Path::Tiny 0.011;

my @modules = qw[ MIME::Base64 MIME::Base64::Perl ];
my $decode;
for my $module ( @modules ) {
    eval "use $module; 1;" or next;
    $decode = $module->can('decode_base64') or next;
}
unless ( defined $decode ) {
    die "Couldn't load any of @modules";
}

my $data_url_re  = qr{^data:image/(\w+)(?:;charset=[^;]*)?;base64,(.+)}s;
my $non_base64_re = qr{[^A-Za-z0-9+/=]+}s;

my $filter_doc = _Text::Pandoc::FilterUtils->new(
    +{ output_format => shift( @ARGV ), data => \*STDIN } );

$filter_doc->get_meta_opts( +{defaults => +{ image_dir=>'decoded_images' } } );
my $opt = $filter_doc->options;
die "'image_dir' must be a string" unless $opt->{image_dir};
my $dir = path $opt->{image_dir};
die "$dir is a file" if $dir->is_file;

my $img_count = 'decodedImage0000';
my $dispatch = +{ 
    Image => sub {
        my $elem = $_;
        my($text,$target) = @{ $elem->{c} };
        my($url, $title) = @$target;
        return unless $url =~ /$data_url_re/;
        my($suffix, $data) = ( $1, $2 );
        $data =~ s/$non_base64_re//g;
        my $img = decode_base64($data);
        $dir->mkpath unless $dir->is_dir;
        my $file = $dir->child($img_count++ . ".$suffix");
        $file->spew_raw($img);
        $url = $file->stringify;
        return $filter_doc->mk_elem( Image => [$text,[$url,$title]] );
    },
};

$filter_doc->traverse( +{ dispatch => $dispatch } );

print $filter_doc->as_json;

{

    package _Text::Pandoc::FilterUtils;
    use Carp;
    use JSON::MaybeXS;
    use Data::Rmap qw[ rmap_hash rmap_array cut ];    # Data structure traversal support.
    use Encode qw[ encode_utf8 is_utf8 ];
    use List::AllUtils 0.09 qw[ all none pairs ];
    use Scalar::Util qw[ refaddr blessed ];
    use Data::Util qw[ :check instance install_subroutine ];

    # CONSTANTS                                     # {{{1}}}

    use constant TYPES_WITH_ATTRS => qw[ Code CodeBlock Div Header Span ];

    # ACCESSORS                                     # {{{1}}}
    BEGIN {
        my @props = qw[
          doc
          json
          options
          output_format
        ];
        my %prop;
    
        for my $prop ( @props ) {
            $prop{$prop} = sub { shift->{$prop} };
        }
        install_subroutine( __PACKAGE__, %prop );
    }

    # METHODS                                       # {{{1}}}

    sub new {    # {{{2}}}
        my ( $class, $p ) = @_;
        is_hash_ref( $p ||= +{} ) or croak "Expected params to be hashref";
        my $self = bless +{} => $class;
        $self->{output_format} = $p->{output_format} || shift @ARGV;
        my $jp = $p->{json_params} || +{};
        is_hash_ref( $jp ) or croak "Expected json_params to be hashref";
        $self->{json} = JSON::MaybeXS->new( %$jp, utf8 => 1, convert_blessed => 1 );
        my $data = $p->{data} || \*STDIN;

        if ( is_string( $data ) and -f $data ) {
            open my $fh, '<:encoding(UTF-8)', $data;
            $data = $fh;
        }
        if ( is_glob_ref( $data ) or is_instance( $data, 'IO::Handle' ) ) {
            my $json = do { local $/; <$data>; };
            $data = \$json;
        }
        if ( is_scalar_ref( $data ) ) {
            $$data = encode_utf8 $$data if is_utf8( $$data );
            $self->{doc} = $self->{json}->decode( $$data );
        }
        else {
            croak "Expected data to be filehandle, filename or scalar ref with JSON";
        }
        for my $key ( qw[ callback dispatch wanted_types ] ) {
            $self->{$key} = $p->{$key} if exists $p->{$key};
        }
        if ( $p->{option_params} ) {
            is_hash_ref $p->{option_params}
              or croak "Expected option_params to be hashref";
            $self->get_meta_opts( $p->{option_params} );
        }
        else {
            $self->{options} = +{};
        }
        return $self;
    } ## end sub new

    sub as_json {    # {{{2}}}
        my ( $self ) = @_;
        return $self->json->encode( $self->doc );
    }

    sub traverse {    # {{{2}}}
        my ( $self, $p ) = @_;
        my $fmt = $self->output_format;
        is_hash_ref( $p ||= +{} ) or croak "Expected params to be hashref";
        ref( my $data = $p->{data} || $self->doc )
          or croak "Expected data to be reference";
        my %p = (
            callback     => \my $callback,
            dispatch     => \my $dispatch,
            wanted_types => \my $wanted_types,
        );
        while ( my ( $k, $v ) = each %p ) {
            $$v = $p->{$k} || $self->{$k};
        }
        if ( $dispatch ) {
            is_hash_ref( $dispatch ) or croak "Expected dispatch to be hashref";
            my $name = '{dispatch}';
            if ( exists $dispatch->{$fmt} ) {
                $name .= "->{$fmt}";
                $dispatch = $dispatch->{$fmt};
            }
            if ( is_hash_ref $dispatch ) {
                my %disp = %$dispatch;
                while ( my ( $type, $disp ) = each %disp ) {
                    next if is_code_ref $disp;
                    $disp{$type}
                      = $self->_get_callback_closure( $disp, "$type\_$fmt" );
                }
                $dispatch = \%disp;
            } ## end if ( is_hash_ref $dispatch)
            unless ( is_hash_ref( $dispatch )
                and all { is_code_ref( $_ ) } values %$dispatch )
            {
                croak "Invalid dispatch destination(s) in $name";
            }
            $wanted_types ||= [ keys %$dispatch ];
        } ## end if ( $dispatch )
        if ( $callback ) {
            is_code_ref( $callback )
              or $callback = $self->_get_callback_closure( $callback, $fmt );
        }
        $wanted_types ||= [];
        is_array_ref $wanted_types or $wanted_types = [$wanted_types];
        our ( %disp, @wanted );
        local *wanted = $wanted_types;
        local *disp = $dispatch if $dispatch;
        rmap_hash {
            my $elem = $_;
            my $type = $self->is_elem( $elem, @wanted ) or return;
            my $cb   = $disp{$type} || $callback || croak "No handler for $type";
            my $ret  = $cb->( $self, $type, @_ );
            return unless defined $ret;
            $_ = $ret;
        } ## end rmap_hash
        $data;
        return $p->{data} || $self;
    } ## end sub traverse

    sub _get_callback_closure {    # {{{3}}}
        my ( $self, $arg, $default_method ) = @_;
        $arg = [$arg] unless is_array_ref $arg;
        my ( $handler, $method ) = @$arg;
        $method ||= lc $default_method;
        unless ( is_invocant $handler ) {
            $handler = 'undef'        unless defined $handler;
            $handler = 'empty string' unless length $handler;
            croak "Expected an object or perl class name, not $handler";
        }
        my $class = ref $handler || $handler;
        $class->can( $method ) or croak "Found no method $method through $class";
        return sub { $handler->$method( @_ ) };
    } ## end sub _get_callback_closure

    sub simplify {    # {{{2}}}
         # Replace spans/divs with no id/classes/attributes with their contents
         # in their parents' content list.
         # This is generally much more robust than trying to call callbacks on hashes
         # while traversing with rmap_array!
        my ( $self, $arg ) = @_;
        ref( my $data = $arg || $self->doc )
          or croak "Expected data to be reference";
        rmap_array {
            my $aref = $_;
            {
                local $_;
                return if none { is_elem( $_, qw[ Div Span ] ) } @$aref;
            }
            my @ret;
            for my $elem ( @$aref ) {
                if ( is_elem( $elem, qw[ Div Span ] ) ) {
                    if (    # Does it have any attributes?
                        length( $elem->{c}[-2][0] )            # id
                        or scalar( @{ $elem->{c}[-2][1] } )    # classes
                        or scalar( @{ $elem->{c}[-2][2] } )    # key_vals
                      )
                    {
                        push @ret, $elem;
                    } ## end if (  length( $elem->{...}))
                    else {                                     # No attributes!
                        push @ret, @{ $elem->{c}[-1] };        # Contents
                    }
                } ## end if ( is_elem( $elem, qw[ Div Span ]...))
                else {
                    push @ret, $elem;
                }
            } ## end for my $elem ( @$aref )
            $_ = \@ret;
        } ## end rmap_array
        $data;
        return $arg || $self;
    } ## end sub simplify

    sub get_meta_opts {    # {{{2}}}
                           # Gather options from the document metadata:
                           # my $option = get_meta_opts(
                           #     +{  doc	 => $doc,		  #
                           #         opts	=> [qw( option, )],	#
                           #         default => +{ option => $default, },			#
                           #         prefix	=> q{${{5:_}},		 # \
                           #     }
                           # );
        my ( $self, $p ) = @_;
        is_hash_ref( $p ||= +{} ) or croak "Expected params to be hashref";
        is_array_ref( my $doc = $p->{doc} || $self->doc )
          or croak "Expected doc to be arrayref";
        my $meta = $p->{meta} || $doc->[0];

        if ( is_hash_ref $meta ) {
            $meta = $meta->{unMeta} if exists $meta->{unMeta};
        }
        is_hash_ref( $meta ) or croak "Expected meta to be hashref";
        is_hash_ref( my $default = $p->{defaults} || $p->{default} || +{} )
          or croak "Expected default to be hashref";
        my %opt = %$default;
        my $opts = $p->{opts} || $p->{opt} || [];
        is_array_ref( $opts ) or $opts = [$opts];
        my @opts = @$opts;
        my $pfx = $p->{prefix} || q{};
        @opts = keys %opt unless @opts;
      OPT:

        for my $opt ( @opts ) {
            my $key = $pfx . $opt;
            next unless exists $meta->{$key};
            $opt{$opt} = $self->_get_opt_val( $meta->{$key} );
        }
        return $self->{options} = \%opt;
    } ## end sub get_meta_opts

    # Getopt helpers                                # {{{3}}}

    sub _get_opt_val {    # {{{4}}}
                          # Turn one pandoc metadata value into an option value
        my ( $self, $data ) = @_;
        if ( 'MetaMap' eq $data->{t} ) {
            return $self->_get_opt_map( $data->{c} );
        }
        elsif ( 'MetaList' eq $data->{t} ) {
            return $self->_get_opt_list( $data->{c} );
        }
        else {
            # Should we return a concatenation instead of
            # just the first string-ish contents value?
            my ( $opt ) = rmap_hash {
                if ( $_->{t} =~ /\A(?:Str|Meta(?:String|Bool))\z/ ) {
                    cut $_->{c};
                }
                elsif ( $_->{t} =~ /\ACode(?:Block)?\z/ ) {
                    cut $_->{c}[-1];
                }
                return;
            } ## end rmap_hash
            $data;
            return $opt;
        } ## end else [ if ( 'MetaMap' eq $data...)]
        return;
    } ## end sub _get_opt_val

    sub _get_opt_map {    # {{{4}}}
                          # Turn a pandoc metadata map into a plain hashref #
        my ( $self, $href ) = @_;
        my %ret;
        while ( my ( $k, $v ) = each %$href ) {
            $ret{$k} = $self->_get_opt_val( $v );
        }
        return \%ret;
    } ## end sub _get_opt_map

    sub _get_opt_list {    # {{{4}}}
                           # Turn a pandoc metadata list into a plain arrayref #
        my ( $self, $aref ) = @_;
        my @ret = map { $self->_get_opt_val( $_ ) } @$aref;
        return \@ret;
    } ## end sub _get_opt_list

    # Element inspection and creation methods       # {{{2}}}

    sub is_elem {          # {{{3}}}
                           # is_elem( $elem, ?@types );
        my ( $self, $elem, @types ) = @_;
        return !!0 unless is_hash_ref $elem;
        return !!0 unless exists $elem->{t};
        return !!0 unless exists $elem->{c};
        if ( @types ) {
            for my $type ( @types ) {
                return $type if $type eq $elem->{t};    # Tag matches
            }
            return !!0;                                 # No type matched
        } ## end if ( @types )
        return $elem->{t};    # No types supplied, all checks ok
    } ## end sub is_elem

    sub mk_elem {             # {{{3}}}
                              # mk_elem( $type => $contents );
        my ( $self, $type => $contents ) = @_;
        return +{ t => $type, c => $contents };
    }

    sub mk_attr_elem {        # {{{3}}}
                              # mk_attr_elem( $type, $contents, ?\%attr );
        my ( $self, $type, $contents, $attr ) = @_;
        is_hash_ref( $attr ||= +{} ) or croak "Expected attributes to be hashref";
        my @level = ( 'Header' eq $type ? 0+ delete( $attr->{header_level} ) : () );
        my $id    = delete $attr->{id}    || "";
        my $class = delete $attr->{class} || [];

        # my $key_val = $attr->{key_val} || +{};
        is_array_ref( $class ) or $class = [$class];
        my @kv = pairs %$attr;
        my $elem = mk_elem( $type => [ @level, [ $id, $class, \@kv ], $contents ] );
        is_elem( $elem, TYPES_WITH_ATTRS )
          or croak "A $type element doesn't have any attributes";
        return $elem;
    } ## end sub mk_attr_elem

    sub attrs2hash {    # {{{3}}}
        my ( $self, $arg ) = @_;
        my $type = $self->is_elem( $arg, TYPES_WITH_ATTRS );
        is_array_ref( my $attrs = $type ? $arg->{c}[-2] : $arg )
          or croak "Expected element or arrayref with attributes";
        my ( $id, $classes, $kvs ) = @$attrs;
        my %hash = ( id => $id, class => $classes, map { @$_ } @$kvs );
        if ( 'Header' eq $type ) {
            $hash{header_level} = $arg->{c}[-3];
        }
        return \%hash;
    } ## end sub attrs2hash

    sub elem_content {
        my ( $self, $elem ) = @_;
        my $type = is_elem( $elem ) or croak "Expected an element";
        if ( any { $_ eq $type } TYPES_WITH_ATTRS ) {
            return $elem->{c}[-1];
        }
        return $elem->{c};
    } ## end sub elem_content

}

1;    # END                                        # {{{1}}}
__END__

