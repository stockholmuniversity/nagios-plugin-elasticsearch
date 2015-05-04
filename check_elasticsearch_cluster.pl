#!/usr/bin/env perl
use strict;
use warnings;
use JSON;
use Nagios::Plugin;
use Data::Dumper;
use LWP::UserAgent;

# TODO
# * Add warnings
# * Check that index/shard status is status or higher.
my $np = Nagios::Plugin->new(
  shortname => "#",
  usage => "Usage: %s [-v|--verbose] [-t <timeout>] [--critical=<critical cluster status>]",
  timeout => 10,
);

$np->add_arg(
  spec => 'critical=s',
  help => "--critical\n   Which cluster/index/shard status that is critical. (default %s)",
  default => "red",
);

$np->add_arg(
  spec => 'nodes-critical=s',
  help => "--nodes-critical\n   How many nodes which must be online, uses the Nagios threshhold format.
   See <https://nagios-plugins.org/doc/guidelines.html#THRESHOLDFORMAT>. (default %s)",
  default => '@0',
);

$np->getopts;

my $code;
my $json;
my $ua = LWP::UserAgent->new;
# NRPE timeout is 10 seconds, give us 1 second to run
$ua->timeout($np->opts->timeout-1);
# Time out 1 second before LWP times out.
my $url = "http://localhost:9200/_cluster/health?level=shards&timeout=".($np->opts->timeout-2)."s&pretty";
my $resp = $ua->get($url);

if (!$resp->is_success) {
  $np->nagios_exit(CRITICAL, $resp->status_line);
}
$json = $resp->decoded_content;

my %ES_STATUS = (
  "red" => 1,
  "yellow" => 2,
  "green" => 3,
);

my $ES_STATUS_CRITICAL = $np->opts->critical;
my $ES_NODES_ERROR = $np->opts->get('nodes-critical');

# Turns an array into "first, second & last"
sub pretty_join($) {
  my ($a) = @_;
  join("", map {
    if ($_ eq @$a[@$a-1]) {
      $_;
    }
    else {
      if ($_ eq @$a[@$a-2]) {
        $_.' & ';
      }
      else {
        $_.', ';
      }
    }
  } @$a);
}

sub check_status($$) {
  $code = $np->check_threshold(
    check => (ref $_[0] eq "HASH") ? $ES_STATUS{$_[0]->{status}} : $ES_STATUS{$_[0]},
    warning => "\@$ES_STATUS{$ES_STATUS_CRITICAL}",
    critical => "\@$ES_STATUS{$ES_STATUS_CRITICAL}",
  );
  $np->add_message($code, $_[1]);
}

my $res;
# Try to parse the JSON
eval {
  $res = decode_json($json);
};
if ($@) {
  $np->nagios_exit(CRITICAL, "JSON was invalid: $@");
}

# Check the cluster status
check_status($res, "Cluster $res->{cluster_name} is $res->{status}");

# Check that the cluster query didn't time out
if (defined $res->{timed_out} && $res->{timed_out}) {
  $np->add_message(CRITICAL, "Connection to cluster timed out!");
}

# Check that we have the number of nodes we prefer online.
$code = $np->check_threshold(
  check => $res->{number_of_nodes},
  warning => "$ES_NODES_ERROR",
  critical => "$ES_NODES_ERROR",
);
$np->add_message($code, "nodes online: $res->{number_of_nodes}");

# Check all the indices and shards
my $indices_with_issues;
# Loop over all indexes and then shards to find which has ES_STATUS_CRITICAL
# FIXME Make the check a >=yellow check
foreach my $i (keys $res->{indices}) {
  if ($res->{indices}->{$i}->{status} eq $ES_STATUS_CRITICAL) {
    foreach my $s (keys $res->{indices}->{$i}->{shards}) {
      if ($res->{indices}->{$i}->{shards}->{$s}->{status} eq $ES_STATUS_CRITICAL) {
        push @{$indices_with_issues->{$i}}, $s;
      }
    }
  }
}

# Create an joined error string for all indexes and shards
if ($indices_with_issues) {
  my @indices_error_string;
  foreach my $i (keys $indices_with_issues) {
    push @indices_error_string, "index $i shard(s) ".pretty_join($indices_with_issues->{$i});
  }
  check_status($ES_STATUS_CRITICAL, join(", ", @indices_error_string));
}

($code, my $message) = $np->check_messages(join => ", ");
$np->nagios_exit($code, $message);
