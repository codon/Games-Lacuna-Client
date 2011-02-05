#!/usr/bin/perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use List::Util            (qw(first));
use Games::Lacuna::Client ();
use Getopt::Long          (qw(GetOptions));
use YAML::Any             (qw(LoadFile));
my $cfg_file;
my $push_file;

if ( @ARGV && $ARGV[0] !~ /^--/) {
	$cfg_file = shift @ARGV;
}
else {
	$cfg_file = 'lacuna.yml';
}
unless ( $cfg_file and -e $cfg_file ) {
  $cfg_file = eval{
    require File::HomeDir;
    require File::Spec;
    my $dist = File::HomeDir->my_dist_config('Games-Lacuna-Client');
    File::Spec->catfile(
      $dist,
      'login.yml'
    ) if $dist;
  };
  unless ( $cfg_file and -e $cfg_file ) {
    die "Did not provide a config file";
  }
}

if ( @ARGV && $ARGV[0] !~ /^--/) {
    $push_file = shift @ARGV;
}
else {
    $push_file = 'push.yml';
}

unless ( $cfg_file && -e $cfg_file ) {
    die "config file not found: '$cfg_file'";
}

unless ( $push_file && -e $push_file ) {
    die "push config file not found: '$push_file'";
}

my $from;
my $to;
my $ship_name;

GetOptions(
    'from=s' => \$from,
    'to=s'   => \$to,
    'ship=s' => \$ship_name,
);

my $push_config = LoadFile( $push_file );

$from      ||= $push_config->{from};
$to        ||= $push_config->{to};
$ship_name ||= $push_config->{ship_name};

usage() if !$from || !$to;

usage() if ref( $push_config->{items} ) ne 'ARRAY';


my $client = Games::Lacuna::Client->new(
	cfg_file => $cfg_file,
	 #debug    => 1,
);

my $empire  = $client->empire->get_status->{empire};
my $planets = $empire->{planets};

# reverse hash, to key by name instead of id
my %planets_by_name = map { $planets->{$_}, $_ } keys %$planets;

my $to_id = $planets_by_name{$to}
    or die "to planet not found";

# Load planet data
my $body      = $client->body( id => $planets_by_name{$from} );
my $result    = $body->get_buildings;
my $buildings = $result->{buildings};

# Find the TradeMin
my $trade_min_id = first {
        $buildings->{$_}->{name} eq 'Trade Ministry'
} keys %$buildings;

my $trade_min = $client->building( id => $trade_min_id, type => 'Trade' );
my @options;

if ($ship_name) {
    my $trade_ships = $trade_min->get_trade_ships($to_id)->{ships};
    
    my $ship = first
        {
            $_->{name} =~ m/$ship_name/i;
        }
        @$trade_ships;
    
    if ($ship) {
        push @options, { ship_id => $ship->{id} };
    }
    else {
        warn "ship '$ship_name' not available,\n";
        warn "proceeding without specifying which ship to use\n";
    }
}

my $return = $trade_min->push_items(
    $to_id,
    $push_config->{items},
    @options,
);

printf "Pushed from '%s' to '%s' using '%s', arriving '%s'\n",
    $from,
    $to,
    $return->{ship}{name},
    $return->{ship}{date_arrives};


sub usage {
  die <<"END_USAGE";
Usage: $0 push.yml CONFIG_FILE PUSH_CONFIG_FILE
       --from PLANET_NAME
       --to   PLANET_NAME
       --ship SHIP_NAME

CONFIG_FILE  defaults to 'lacuna.yml'

PUSH_CONFIG_FILE defaults to 'push.yml'

If --from arg is missing, it must be set in PUSH_CONFIG_FILE

If --to arg is missing, it must be set in PUSH_CONFIG_FILE

PUSH_CONFIG_FILE must be a YAML hash, and must contain an 'items' key whose
value must be a list  of definitions suitable for passing to the Trade
buildings push_items() method (see API documentation).

If --ship if provided, we try to use a ship containing SHIP_NAME in its name,
using SHIP_NAME as a case-insensitive regex.

--ship can also be set in PUSH_CONFIG_FILE.

EXAMPLE PUSH_CONFIG_FILE

    ---
    from: 'origin'
    to: 'recipient'
    ship: 'dory 20k'
    items:
      - type: 'apple'
        quantity: 10000
      - type: 'water'
        quantity: 10000

END_USAGE

}

