#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Games::Lacuna::Client::Governor;
use Games::Lacuna::Client;
use YAML::Any;
use Getopt::Long;

$| = 1;

my $client_config   = '';
my $governor_config = '';

GetOptions(
    'client|c=s' => \$client_config,
    'governor|g=s' => \$governor_config,
);

unless ($client_config && $governor_config) {
    die usage();
}

my $client = Games::Lacuna::Client->new(
    cfg_file => $cfg_file,
    #debug    => 1,
);

if ( $^O !~ /MSWin32/) {
    $Games::Lacuna::Client::PrettyPrint::ansi_color = 1;
}

my $governor = Games::Lacuna::Client::Governor->new( $client, $governor_config );
my $arg = shift @ARGV;
$governor->run( defined $arg and $arg eq 'refresh' );

printf "%d total RPC calls this run.\n", $client->{total_calls};

exit;

sub usage {
    return qq{
    $0 <options>
        OPTIONS:
            -g, --governor      path to governor.yml
            -c, --client        path to client.yml\n};
}
