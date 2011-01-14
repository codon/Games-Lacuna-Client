#!/usr/bin/perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use List::Util            (qw(first max));
use Getopt::Long          (qw(GetOptions));
use Games::Lacuna::Client ();

my $planet_name;

GetOptions(
    'planet=s' => \$planet_name,
);

my $cfg_file = shift(@ARGV) || 'lacuna.yml';
unless ( $cfg_file and -e $cfg_file ) {
	die "Did not provide a config file";
}

my $client = Games::Lacuna::Client->new(
	cfg_file => $cfg_file,
	# debug    => 1,
);

# Load the planets
my $empire  = $client->empire->get_status->{empire};

# reverse hash, to key by name instead of id
my %planets = map { $empire->{planets}{$_}, $_ } keys %{ $empire->{planets} };

my %all_plans;
my $total_plans = 0;

# Scan each planet
foreach my $name ( sort keys %planets ) {

    next if defined $planet_name && $planet_name ne $name;

    # Load planet data
    my $planet    = $client->body( id => $planets{$name} );
    my $result    = $planet->get_buildings;
    my $body      = $result->{status}->{body};

    my $buildings = $result->{buildings};

    # Find the PPC
    my $ppc_id = first {
            $buildings->{$_}->{name} eq 'Planetary Command Center'
    } keys %$buildings;

    my $ppc   = $client->building( id => $ppc_id, type => 'PlanetaryCommand' );
    my $plans = $ppc->view_plans->{plans};

    next if !@$plans;

    printf "%s (%d plans)\n", $name, scalar @$plans;
    print "=" x length $name;
    print "\n";

    my $max_length = max map { length $_->{name} } @$plans;

    for my $plan (@$plans) {
        my $plan_txt = "$plan->{name} " . ($plan->{level}+$plan->{extra_build_level}||0);
        $total_plans++;
        $all_plans{$plan_txt}++;
        printf "%${max_length}s, level %d",
            $plan->{name},
            $plan->{level};

        if ( $plan->{extra_build_level} ) {
            printf "+%d", $plan->{extra_build_level};
        }


        print "\n";
    }

    print "\n";
}

for my $plan (sort { $all_plans{$b} <=> $all_plans{$a} } keys %all_plans) {
    printf "%3s X %s\n", $all_plans{$plan}, $plan;
}
print "=" x 40;
print "\n";
printf "%3s total plans\n", $total_plans;

print "$client->{total_calls} api calls made.\n";
