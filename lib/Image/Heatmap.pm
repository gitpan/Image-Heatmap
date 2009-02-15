package Image::Heatmap;

use strict;
use warnings;

use Image::Magick;

INIT {
    foreach my $accessor ( qw(

        processes
        statement

        map
        tmp_dir
        output
        parent

        thumbnail
        thumbnail_scale

        colors
        plot_base

        plot_size
        image_width
        image_height
        zoom
        x_adjust
        y_adjust
        width
        width_adjust
        height
        height_adjust

    ) ) {
        {
            no strict 'refs';
            *{ __PACKAGE__ . "::$accessor" } = sub {
                return &Image::Heatmap::private::accessor( shift, $accessor, @_ );
            }
        }
    }
}

our $VERSION = join( '.', 0, map{ $_ - 47 } ( '$Rev: 51 $' =~ /(\d+)/g ) ); 
our $DEBUG = 0;

sub new {
    my $self = bless( Image::Heatmap::private::next_oid(), shift ); 

    # Defaults
    $self->tmp_dir('/tmp/');
    $self->processes(1);
    $self->x_adjust(0);
    $self->y_adjust(0);
    $self->width_adjust(0);
    $self->height_adjust(0);
    $self->output('heatmap.png');
    $self->colors('colors.png');
    $self->plot_base('bolilla.png');

    return $self;
}

sub process {
    my ( $self ) = @_;

    if ( my $error = Image::Heatmap::private::validate($self) ) {
        Image::Heatmap::private::throw($error);
    }

    my $max_rep = 0;

    my $width  = $self->width();
    my $height = $self->height();
    my $map    = Image::Magick->new();
    $map->Read( $self->map() );
    $self->image_width( $map->Get('width') );
    $self->image_height( $map->Get('height') );

    # If there is no width/height defined then we will default
    # to what the image is defined to.  We will trust the implementor
    # of this module knows what they're doing, otherwise.
    unless ( $width && $height ) {
        $width  = $self->image_width();
        $height = $self->image_height();
    }
    note("W x H: $width x $height");

    unless ( $self->width_adjust() && $self->height_adjust() ) {
        $self->width_adjust( $self->image_width() );
        $self->height_adjust( $self->image_height() );
        note('W x H Adjust: ' . join( ' x ', map{ $self->$_() } qw( width_adjust height_adjust ) ) );
    }

    my $sth = $self->statement();
    $sth->execute();
    while ( my $point = $sth->fetchrow_hashref() ) {
        my ( $lat, $lng ) = @$point{ qw( latitude longitude ) };

        # Make sure a lat/lng exist
        Image::Heatmap::private::throw(
            'Invalid parameters in statement, must include "latitude" and "longitude"'
        ) unless ( defined($lat) && defined($lng) ); 

        my $x = ( 180 + $lng ) * ( $width / 360 );
        my $y = ( 90 - $lat ) * ( $height / 180 );

        $_ *= $self->zoom() || 1 for ( ( $x, $y ) );

        $x += $self->x_adjust();
        $y += $self->y_adjust();

        my $coords = join( '|', $lat, $lng );
        Image::Heatmap::private::shove( $self => 'coords', [ $x, $y ] );
        my $reps = Image::Heatmap::private::get( $self => 'reps' => $coords );
        $max_rep = $reps->{$coords} if ( ++$reps->{$coords} > $max_rep );
    }

    my $x_canvas = $width * ( $self->width_adjust() / $width );
    my $y_canvas = $height * ( $self->height_adjust() / $height );
    note("$width x $height vs. $x_canvas x $y_canvas");

    my $kid_seed  = int( rand( time() ) );
    my $kid_layer = "layer_slice-%d-$kid_seed.png";
    my $kids      = $self->processes();
    my @children  = ();
    foreach my $child_num ( 1 .. $kids ) {
        $children[ $child_num - 1 ] = Image::Heatmap::private::distribute_work($self);

        Image::Heatmap::private::throw(
            'Error when generating sub-process'
        ) unless ( defined( $children[-1] ) );

        unless ( $children[-1] ) {

            note("Resize -geometry ${x_canvas}x${y_canvas}");
            my $child_layer = Image::Magick->new( size => "${x_canvas}x${y_canvas}");
            $child_layer->Read('pattern:gray100');

            my $cperc  = int( 100 / ( $max_rep || 1 ) );
            $cperc    /= 2 if ( $cperc > 80 );
            note("Colorize -fill white -opacity $cperc%");
            my $plot = Image::Magick->new();
            $plot->Read( $self->plot_base() );
            $plot->Resize( $self->plot_size() ) if ( $self->plot_size() );
            $plot->Colorize( fill => 'white', 'opacity' => "$cperc%" );

            my @coords        = @{ Image::Heatmap::private::get( $self => 'coords' ) || [] };
            my $bucket_size   = scalar( @coords ) / $kids;
            my $bucket_offset = ( $child_num - 1 ) * $bucket_size;
            my @new_coords    = splice( @coords, $bucket_offset, $bucket_size ); 

            foreach my $coordinate ( @new_coords ) {
                my ( $x, $y ) = @$coordinate;
                note("Composite -compose Multiply -geometry +$x+$y");

                $child_layer->Composite(
                    'image'    => $plot,
                    'compose'  => 'Multiply',
                    'geometry' => "+$x+$y",
                );
            }

            my $child_image = sprintf( $kid_layer, $child_num );
            note("Write $child_image"); 
            $child_layer->Write( $self->tmp_dir() . $child_image ); 

            Image::Heatmap::private::finish_work($self);
        }
    }

    foreach my $child ( @children ) {
        note("Blocking wait on pid:$child");
        my $pid_state = waitpid( $child, 0 );
        note("pid:$child - $pid_state :: $?");
    }

    my $layer = Image::Magick->new( size => "${x_canvas}x${y_canvas}");
    $layer->Read('pattern:gray100');

    foreach my $child_num ( 1 .. $kids ) {
        my $child_image = $self->tmp_dir() . sprintf( $kid_layer, $child_num );
        my $child_slice = Image::Magick->new();
        $child_slice->Read($child_image);

        note("Composite -image $child_image -compose Multiply -geometry +0+0");
        $layer->Composite( 
            'image'    => $child_slice,
            'compose'  => 'Multiply',
            'geometry' => '+0+0',
        );
    }

    note("Negate && Fx -expression v.p{0,u*v.h}");
    $layer->Negate();
    $layer->Read( $self->colors() );
    my $fx = $layer->Fx( 'expression' => 'v.p{0,u*v.h}' );

    note("Composite -image $map -compose Blend -blend 40%");
    $fx->Composite(
        'image'   => $map,
        'compose' => 'Blend',
        'blend'   => '40%',
    );
    $fx->Write( $self->output() );

    if ( my $thumbnail = $self->thumbnail() ) {
        note("Thumbnail : $thumbnail");
        if ( my $scale = $self->thumbnail_scale() ) {
            note('Scale to : ' . ( int( $scale * 100 ) ) . '%');
            $fx->Resize( 'geometry' => join( 'x', ( $x_canvas * $scale ), ( $y_canvas * $scale ) ) );
            $fx->Write($thumbnail);
        }
    }

    return;
}

*note = \&Image::Heatmap::private::note;
# *poke = \&Image::Heatmap::private::poke;

sub DESTROY {
    my ($self) = @_;
    Image::Heatmap::private::release_oid($self);
}

1;

package Image::Heatmap::private;

use strict;
use warnings;

use File::Find;

use constant {
    FOUND_INDICATION => 'FOUND',
};

my %stash = ();

sub distribute_work {
    my ($self) = @_;

    $self->parent($$);

    return 0 if ( $self->processes() == 1 );
    return fork();
}

sub finish_work {
    my ($self) = @_;
    exit if ( $self->parent() != $$ );
    return;
}

{
    my %validators = (
        'map' => {
            'valid'   => sub{ 
                my $self = shift; 
                $self->map() && -r $self->map() && -f $self->map() 
            },
            'message' => 'Map image (map) must be defined and have accomidating file permissions.',
        },
        'tmp_dir' => {
            'valid'   => sub{ 
                my $self = shift; 
                $self->tmp_dir() && -d $self->tmp_dir() 
            },
            'message' => 'Working directory (tmp_dir) must be defined and have accomidating permissions.',
        },
    );
    sub validate {
        my ($self) = @_;

        foreach my $validator ( keys %validators ) {
            note("Validating \"$validator\"");
            unless ( &{ $validators{$validator}{'valid'} }( $self ) ) {
                return $validators{$validator}{'message'};
            }
        }

        my $tmp_dir  = $self->tmp_dir();
        $tmp_dir    .= '/' unless ( $tmp_dir =~ /\/$/ );
        $self->tmp_dir($tmp_dir);

        foreach my $finder ( qw( colors plot_base ) ) {
            my $file = $self->$finder();
            note( join( ' :: ', map{ $_ || 'n/a' } ( $file, -r $file ) ) ); 
            unless ( -r $file ) {

                my $file_location;
                my $did_find =  FOUND_INDICATION;
                eval{
                    File::Find::find(
                        {
                            'no_chdir'    => 1,
                            'follow_fast' => 1,
                            'wanted'      => sub {
                                return unless ( $_ =~ /.*\/$file$/ );
                                $file_location = $_;
                                throw($did_find);
                            },
                        },
                        $INC{'Image/Heatmap.pm'} =~ /^(.*)\/lib\/IGuard\/Config.pm$/ || '.'
                    );
                };

                if ( my $e = $@ ) {
                    if ( $file_location && "$e" =~ /$did_find/ ) {
                        note("Setting \"$finder\" to \"$file_location\"");
                        $self->$finder($file_location);
                        next;
                    }
                    else {
                        throw($e);
                    }
                }
                else {
                    throw('Invalid return in seeking file: "' . ( $self->$finder() ) . '"');
                }
            }
        }

        return undef;
    }
}

sub accessor {
    my ( $self, $method, $content ) = @_;

    if ( defined($content) ) {
        return set( $self => $method, $content );
    }
    else {
        return get( $self => $method );
    }
}

sub throw {
    my $caller = caller;
    die( 
        "$caller :: " . ( join( 
            ' :: ', 
            map{ 
                ( ref( $_ ) ) ? ref($_) : $_
            } @_ 
        ) )
    );
}

sub shove {
    my ( $self, @depth ) = @_;

    my $content = pop(@depth);
    my $key     = pop(@depth);
    my $depth   = get_depth( ( $$self, @depth ) );
    push( @{ $depth->{$key} ||= [] }, $content );
    return $content;
}

sub set {
    my ( $self, @depth ) = @_;

    my $content    = pop(@depth);
    my $key        = pop(@depth);
    my $depth      = get_depth( ( $$self, @depth ) );
    $depth->{$key} = $content;
    return $content;
}

sub get {
    my ( $self, @depth ) = @_;

    my $key = pop(@depth);
    my $depth = get_depth( ( $$self, @depth ) );
    return $depth->{$key};
}

sub get_depth {
    my $level = \%stash;
    $level    = $level->{$_} ||= {} foreach ( @_ );
    return $level;
}

sub note {
    return unless ( $DEBUG );
    return notify(@_);
}

sub poke {
    return notify(@_);
}

sub notify {
    my ( $message ) = @_;

    my $stringer = ( ref($message) )
        ? sub{
            require Data::Dumper;
            return Data::Dumper::Dumper( $_[0] )
          }
        : sub{ return $_[0]; };

    print( sprintf( "[%s] - %d - %s\n", scalar(localtime()), $$, &$stringer($message) ) );
}

{
    my @oids = ();
    my $current_oid = 0;
    sub release_oid {
        my ($self) = @_;
        push( @oids, $$self );
        return;
    }

    sub next_oid {
        my $next = shift(@oids) || $current_oid++;
        return \$next;
    }
}

sub death {
    require Data::Dumper;
    die( Data::Dumper::Dumper(\%stash) );
}

1;

__END__

=head1 NAME

Image::Heatmap - Build heatmap images 

=head1 DESCRIPTION

Will effortlessly convert latitude/longitude coordinates into a graphical
heatmap of the geographical region relative the number of points outlined.

http://is.gd/jvew are two examples of such images built by early versions
of this module.

=head1 METHODS

=head2 new

Will instantiate and return a blessed scalar reference to an integer representing
the 'object id' (incremented unique integer for each object).  

Does not use any 3rd party modules such as L<Moose> or L<Class::Accessor> to
obtain good object management.  Albeit a potentially better design, I simply
didn't want to mess with it.

=head2 process

Will generate the heatmap, saving a file of chosen type (based off file suffix)
to the location defined in 'output' (see ATTRIBUTES)

=head1 ATTRIBUTES

=head2 processes

Default: 1

Will define the number of processes to use for the image processing.  Will only 
add each plot to the full image with the processes, where the final image will
be generated with only a single process.  Furthermore, being the module will
iterate over the set twice (for reasons I will leave out), the first iteration
will, too, only be processed in single-thread mode.  

If one (1) process is selected, only one process will be used throughout the
use of this module.  If > 1 is required, there will be n + 1, where the parent
will fork the number of processes requested and block on their completion.

=head2 statement

Will accept the statement handle the module will use.  At the time of this writing,
this is the only method of giving a list of lat/long to the module (see TODO).

The module will assume the statement handle to take zero bind parameters and
assume (at least) two column names: 'latitude' and 'longitude', respectively.
A defficiency of these requirements will kill the processing.

    my $image = Image::Heatmap->new();
    my $dbh   = DBI->new( 'dsn', 'user', 'pass', {} );

    # Note that because the requirement of the named columns, if the columns of
    # the table do not match, you should select them as named columns.
    my $sth   = $dbh->prepare('select lat AS latitude, long AS longitude from table');

=head2 map

A string representng the readable location of the mapping image the plots will be layered
upon.

=head2 tmp_dir

Default: /tmp/

Used primarily when using multiple-processes, will cache some images along the way in 
the specified directory.

=head2 output

Default: heatmap.png

The literal path to the heatmap image. Will be of the type specified by it's file suffix.

=head2 parent

Used by the module, will hold the process id of the parent process.

=head2 thumbnail

OPTIONAL

The literal path to the heatamp thumbnail image.

=head2 thumbnail_scale

OPTIONAL

The scale of the thumbnail, relative to the size of the map.

=head2 colors

Default: colors.png

The semi-literal path to the color swatch that will be used for the plots.
If the file cannot be found, L<File::Find> will be used to hunt it down within
the directory root of the module its self.  'colors.png' is provided in this module.

=head2 plot_base

Default: bolilla.png

The semi-literal path to the plot that will be used as the basis for each plot added
to the heatmap.  If the file cannot be found, L<File::Find> will be used to hunt it down
within the directory root of the module.  'bolilla.png' is provided in this distribution and
is a 64px square image.

=head2 plot_size

Default: 64

The size, in pixels, of the plot image that will be used.  Will scale the image at 'plot_base'
to be a square with a width and height the size defined here.

=head2 image_width

The width of the image that will be mapped.  May be defined, but will otherwise be taken
from the demensions defined by the image.

=head2 image_height

The height of the image that will be mapped.  May be defined, but will otherwise be taken
from the demensions defined by the image.

=head2 zoom

Default: 1

Will zoom the view 'n' times the size of the image.  

As, by default, the module will plot relative to the entire planet, zooming
is useful (in conjunction with {x,y}_adjust) to view a particular area of 
Earth rather then the planet as a whole.

=head2 x_adjust

Will adjust the view by 'n' pixels relative to the x pan of a cartesian plane.

Useful with the zoom factor when concentrating on a particular area on Earth rather
than the planet as a whole.

=head2 y_adjust

Will adjust the view by 'n' pixels relative to the y pan of a cartesian plane.

Useful with the zoom factor when concentrating on a particular area on Earth rather
than the planet as a whole.

=head2 width

Will define the width, in pixels, of the plot area.  Will default to the width 
of the mapped image.

=head2 height

Will define the height, in pixels, of the plot area.  Will default to the height
of the mapped image.

=head1 EXAMPLES

    use Image::Heatmap;
    use DBI;

    my $heatmap = Image::Heatmap->new();
    my $dbh     = DBI->connect( 'dsn', 'username', 'password', {} );
    my $sth     = $dbh->prepare('select latitude, lon AS longitude from table');

    $heatmap->statement( $sth );
    $heatmap->process();

    $heatmap->tmp_dir('/tmp'); 
    $heatmap->output('/tmp/heatmap.gif');
    $heatmap->process();

    $heatmap->output('/tmp/heatmap.jpg');
    $heatmap->process();

    $heatmap->output('/tmp/heatmap.png');
    $heatmap->process();

=head1 SEE ALSO

=over

=item L<Image::Magick>

=item L<File::Find>

=back

=head1 TODO

=over

=item More input methods

At the time of this writing, the only method of which to give this module coordinates to plot
is via a L<DBI> statement handle with specifically named columns.  This is useful, but not what
everyone would necessarily want and it is my goal (not promise ;) ) to add this at some time
in the future.

=item $VERSION > 1

There are a few known bugs and missing unit tests that prevent me from making this module's
$VERSION >= 1.  It is my goal to fix this and release it as a 'production ready' module.

=back

=head1 AUTHOR

Trevor Hall, E<lt>wazzuteke@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by Trevor Hall

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut


