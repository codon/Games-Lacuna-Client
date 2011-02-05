#!/usr/bin/perl 
use strict;
use warnings;
use 5.010000;
use feature ':5.10';
use FindBin;
use lib "$FindBin::Bin/../lib";
use Games::Lacuna::Client;
use List::Util qw(min max sum);
use Data::Dumper;
use Getopt::Long qw(GetOptions);
use AnyEvent;

use constant MINUTE => 60;

our $TimePerIteration = 10;

my $min_waste = 1000;

my $balanced = my $rate = 0;
my ($water_perc, $energy_perc, $ore_perc) = (0, 0, 0);
GetOptions(
        'i|interval=f' => \$TimePerIteration,
        'b|balanced!'  => \$balanced,
        'r|rate!'      => \$rate,
        'm|minwaste=i' => \$min_waste,
        'water=i'      => \$water_perc,
        'ore=i'        => \$ore_perc,
        'energy=i'     => \$energy_perc,
        );
$TimePerIteration = int($TimePerIteration * MINUTE);

if ($water_perc or $ore_perc or $energy_perc) {
	die "Percentages need to add up to 100\n" if $water_perc + $ore_perc + $energy_perc != 100;
	for ($water_perc, $ore_perc, $energy_perc) { $_ = $_ / 100; }
}

my $config_file = shift @ARGV || 'lacuna.yml';
unless ( $config_file and -e $config_file ) {
  $config_file = eval{
    require File::HomeDir;
    require File::Spec;
    my $dist = File::HomeDir->my_dist_config('Games-Lacuna-Client');
    File::Spec->catfile(
      $dist,
      'login.yml'
    ) if $dist;
  };
  usage() unless $config_file and -e $config_file;
}

my $client = Games::Lacuna::Client->new(
        cfg_file => $config_file,
        #debug => 1,
);

my $program_exit = AnyEvent->condvar;
my $int_watcher = AnyEvent->signal(
    signal => "INT",
    cb => sub {
        output("Interrupted!");
        undef $client;
        exit(1);
    }
);

#my $res = $client->alliance->find("The Understanding");
#my $id = $res->{alliances}->[0]->{id};

my $empire = $client->empire;
my $estatus = $empire->get_status->{empire};
my %planets_by_name = map { ($estatus->{planets}->{$_} => $client->body(id => $_)) }
    keys %{$estatus->{planets}};
# Beware. I think these might contain asteroids, too.
# TODO: The body status has a 'type' field that should be listed as 'habitable planet'


my @wrs;
foreach my $planet (values %planets_by_name) {
    my $buildings = $planet->get_buildings->{buildings};

    my @waste_ids = grep { $buildings->{$_}{name} eq 'Waste Recycling Center' }
    keys %$buildings;
    push @wrs, map  { $client->building(type => 'WasteRecycling', id => $_) } @waste_ids;
}

my @wr_handlers;
my @wr_timers;
foreach my $iwr (0 .. $#wrs) {
    my $wr = $wrs[$iwr];
    push @wr_handlers, sub {
        my $wait_sec = update_wr($wr, $iwr);
        return if not $wait_sec;
        $wr_timers[$iwr] = AnyEvent->timer(
            after => $wait_sec,
            cb    => sub {
                output("Waited for $wait_sec on WR @{[ $wr->view()->{status}{body}{name} ]} [$iwr]");
                $wr_handlers[$iwr]->()
            },
        );
    };
}

foreach my $wrh (@wr_handlers) {
    $wrh->();
}

output("Done setting up initial jobs. Waiting for events.");
$program_exit->recv;
undef $client; # for session persistence
exit(0);

sub output {
    my $str = join ' ', @_;
    $str .= "\n" if $str !~ /\n$/;
    print "[" . localtime() . "] " . $str;
}

sub usage {
    die <<"END_USAGE";
Usage: $0 myempire.yml
           --interval MINUTES  (defaults to 20)

           Need to generate an API key at https://us1.lacunaexpanse.com/apikey
           and create a configuration YAML file that should look like this

           ---
           api_key: the_public_key
           empire_name: Name of empire
           empire_password: password of empire
           server_uri: https://us1.lacunaexpanse.com/

END_USAGE

}

sub update_wr {
    my $wr = shift;
    my $iwr = shift;

    output("checking WR stats for WR $iwr");
    my $wr_stat = $wr->view;
    output("WR $iwr: $wr_stat->{status}{body}{name}");

    my $busy_seconds = $wr_stat->{building}{work}{seconds_remaining};
    if ($busy_seconds) {
        output("Still busy for $busy_seconds, waiting");
        return $busy_seconds+3;
    }

    output("Checking resource stats");
    my $pstatus = $wr_stat->{status}{body} or die "Could not get planet status via \$struct->{status}{body}: " . Dumper($wr_stat);
    my $waste_per_hour = $pstatus->{waste_hour};
    my $waste = $pstatus->{waste_stored};

    if (not $waste or $waste < $min_waste) {
        output("(virtually) no waste has accumulated, waiting");
        return $TimePerIteration;
    }

    my $sec_per_waste = $wr_stat->{recycle}{seconds_per_resource};
    die "seconds_per_resource not found" if not $sec_per_waste;

    my $rec_waste = min($waste, $TimePerIteration / $sec_per_waste, $wr_stat->{recycle}{max_recycle});

    # yeah, I know this is a bit verbose.
    my $ore_c    = $pstatus->{ore_capacity};
    my $water_c  = $pstatus->{water_capacity};
    my $energy_c = $pstatus->{energy_capacity};

    my $ore_s    = $pstatus->{ore_stored};
    my $water_s  = $pstatus->{water_stored};
    my $energy_s = $pstatus->{energy_stored};

    my $ore_r    = $pstatus->{ore_hour};
    my $water_r  = $pstatus->{water_hour};
    my $energy_r = $pstatus->{energy_hour};

    # produce boolean = capacity > stored + 1
    my $produce_ore    = $ore_c > $ore_s+1;
    my $produce_water  = $water_c > $water_s+1;
    my $produce_energy = $energy_c > $energy_s+1;
    my $total_s        = $ore_s + $water_s + $energy_s;

    my $produce_count = $produce_ore + $produce_water + $produce_energy;
    if ($produce_count == 0) {
        output("All storage full! Producing equal amounts of resources to keep waste low.");
        $produce_count = 3;
    }

    # balanced
    my $ore = 0;
    my $water = 0;
    my $energy = 0;

    if ( $rate ) {
        # get the name of our resource with the lowest production
        my ($resource) = sort { $pstatus->{"${a}_hour"} <=> $pstatus->{"${b}_hour"} } qw( ore water energy );
        given ($resource) {
            when ('ore') {
                output('spending it all on ore');
                $ore = $rec_waste;
            }
            when ('water') {
                output('spending it all on water');
                $water = $rec_waste;
            }
            when ('energy') {
                output('spending it all on energy');
                $energy = $rec_waste;
            }
        }
    }
    elsif ( $balanced ) {
        # if balanced is set, just divide evenly
        output('spending as evenly as possible');
        $ore    = $rec_waste * (1 / $produce_count) if $produce_ore;
        $water  = $rec_waste * (1 / $produce_count) if $produce_water;
        $energy = $rec_waste * (1 / $produce_count) if $produce_energy;
    }
    else {
        # otherwise, spend 100% on the lowest resource that won't go over capacity
        if ($ore_s < $water_s && $ore_s < $energy_s && $ore_s + $rec_waste < $ore_c) {
            # if ore is less than water and energy and we won't cap it
            output('spending it all on ore');
            $ore = $rec_waste;
        }
        if ($water_s < $ore_s && $water_s < $energy_s && $water_s + $rec_waste < $water_c) {
            output('spending it all on water');
            $water = $rec_waste;
        }
        if ($energy_s < $water_s && $energy_s < $ore_s && $energy_s + $rec_waste < $energy_c) {
            output('spending it all on energy');
            $energy = $rec_waste;
        }
    }


    # TODO warn if we aren't keeping pace
    output("WARNING!!! WASTE RECYCLER NOT KEEPING PACE WITH WASTE PER HOUR!!!") if ((60 * 60) / $sec_per_waste < $waste_per_hour);

    # don't do anything if waste production is negative and will put below threshold
    if ($waste - $rec_waste > $min_waste) {
        output(sprintf("RECYCLING %0d waste to ore=%0d, water=%0d, energy=%0d", $rec_waste, $ore, $water, $energy));
        eval {
            $wr->recycle(int($water), int($ore), int($energy), 0);
        };
        output("Recycling failed: $@"), return($TimePerIteration) if $@;
        output("Waiting for recycling job to finish");
        return int($rec_waste*$sec_per_waste)+3;
    }
    else {
        output("Choosing not to recycle right this moment. -- It would put us below $min_waste waste threshold.");
        return $TimePerIteration;
    }

}
