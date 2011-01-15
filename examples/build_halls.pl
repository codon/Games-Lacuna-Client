#!/usr/bin/perl
#
# Build Halls of Vrbansk recipes, wherever they can be assembled
#

use strict;
use warnings;

use FindBin;
use Getopt::Long;
use Data::Dumper;
use List::Util qw(first min max);

use lib "$FindBin::Bin/../lib";
use Games::Lacuna::Client;

my %opts;
GetOptions(\%opts,
    'h|help',
    'v|verbose',
    'q|quiet',
    'config=s',
    'planet=s@',
    'max=i',
    'use-last',
    'dry-run',
    'type=s@',
);

usage() if $opts{h};

my %do_planets;
if ($opts{planet}) {
    %do_planets = map { normalize_planet($_) => 1 } @{$opts{planet}};
}

my $glc = Games::Lacuna::Client->new(
    cfg_file => $opts{config} || "$FindBin::Bin/../lacuna.yml",
);

my $empire = $glc->empire->get_status->{empire};

# reverse hash, to key by name instead of id
my %planets = map { $empire->{planets}{$_}, $_ } keys %{$empire->{planets}};

my @recipes = (
    [qw/ goethite  halite      gypsum        trona     /],
    [qw/ gold      anthracite  uraninite     bauxite   /],
    [qw/ kerogen   methane     sulfur        zircon    /],
    [qw/ monazite  fluorite    beryl         magnetite /],
    [qw/ rutile    chromite    chalcopyrite  galena    /],
);

my %build_types;
my %normalized_types = (
    (map { $_ => $_ - 1 } 1..5),
    a => 0,
    b => 1,
    c => 2,
    d => 3,
    e => 4,
);
if ($opts{type}) {
    # normalize type
    for (@{$opts{type}}) {
        $build_types{lc($normalized_types{$_})} = 1
            if defined lc($normalized_types{$_});
    }
}

# Scan each planet
my (%glyphs, %archmins, %plan_count);
for my $planet_name (sort keys %planets) {
    if (keys %do_planets) {
        next unless $do_planets{normalize_planet($planet_name)};
    }

    my %planet_buildings;

    # Load planet data
    my $planet    = $glc->body(id => $planets{$planet_name});
    my $result    = $planet->get_buildings;
    my $buildings = $result->{buildings};

    # Find the PCC
    my $pcc_id = first {
        $buildings->{$_}->{name} eq 'Planetary Command Center'
    } keys %$buildings;
    my $pcc = $glc->building(id => $pcc_id, type => 'PlanetaryCommand');
    my $plans = $pcc->view_plans;
    $plan_count{$planet_name} = scalar @{$plans->{plans}};

    # Find the Archaeology Ministry
    my $arch_id = first {
        $buildings->{$_}->{name} eq 'Archaeology Ministry'
    } keys %$buildings;

    next unless $arch_id;
    my $arch   = $glc->building(id => $arch_id, type => 'Archaeology');
    $archmins{$planet_name} = $arch;
    my $glyphs = $arch->get_glyphs->{glyphs};

    for my $glyph (@$glyphs) {
        push @{$glyphs{$planet_name}{$glyph->{type}}}, $glyph->{id};
    }
}

my $built = 0;
my $possible = 0;
for my $i (0..$#recipes) {
    next if $opts{type} and not $build_types{$i};

    my @builds;

    my $which = $i + 1;

    # Determine how many of each we're able to build
    PLANET:
    for my $planet (keys %glyphs) {
        my $can_build_here = min(
            map { $glyphs{$planet}{$_} ? scalar @{$glyphs{$planet}{$_}}: 0 } @{$recipes[$i]}
        );
        verbose("$planet can build $can_build_here Halls #$which\n")
            if $can_build_here;

        if ($can_build_here + $plan_count{$planet} > 20) {
            if ($plan_count{$planet} >= 20) {
                output("$planet is full of plans!\n");
                next PLANET;
            } else {
                my $new = 20 - $plan_count{$planet};
                output("Too many plans on $planet, reducing from $can_build_here to $new\n");
                $can_build_here = $new;
            }
        }

        for my $j (0 .. $can_build_here - 1) {
            push @builds, {
                planet => $planet,
                arch   => $archmins{$planet},
                glyphs => [
                    map { $glyphs{$planet}{$_}[$j] } @{$recipes[$i]}
                ],
            };
        }
    }

    # Do builds
    my $how_many = max(@builds - ($opts{'use-last'} ? 0 : 1), 0);
    $how_many = min($opts{max} - $built, $how_many) if $opts{max};

    $built += $how_many;
    $possible += @builds;

    for (0 .. $how_many - 1) {
        my $build = $builds[$_];
        if ($opts{'dry-run'}) {
            output("Would have built a Halls #$which on $build->{planet}\n");
        } else {
            output("Building a Halls #$which on $build->{planet}\n");
            $build->{arch}->assemble_glyphs($build->{glyphs});
        }
        $plan_count{$build->{planet}}++;
    }
}

if ($built) {
    if ($built > $possible) {
        my $diff = $possible - $built;
        output("$diff more Halls are possible, specify --use-last if you want to build all possible Halls\n");
    }
} else {
    if ($possible) {
        output("No Halls built ($possible possible), specify --use-last if you want to build all possible Halls\n");
    } else {
        output("Not enough glyphs to build any Halls recipes, sorry\n");
    }
}

sub normalize_planet {
    my ($planet_name) = @_;

    $planet_name =~ s/\W//g;
    $planet_name = lc($planet_name);
    return $planet_name;
}

sub verbose {
    return unless $opts{v};
    print @_;
}

sub output {
    return if $opts{q};
    print @_;
}

sub usage {
    print STDERR <<END;
Usage: $0 [options]

This will assemble Halls of Vrbansk recipes wherever there are enough
glyphs in the same location to do so.  By default, it will not use
the last of any particular type of glyph.

Options:

  --verbose       - Print more output
  --quiet         - Only output errors
  --config <file> - GLC config, defaults to lacuna.yml
  --max <n>       - Build at most <n> Halls
  --planet <name> - Build only on the specified planet(s)
  --use-last      - Use the last of any glyph if necessary
  --dry-run       - Print what would have been built, but don't do it
  --type <type>   - Specify a particular recipe to build (1-5 or A-E)
END

    exit 1;
}
