#!/usr/bin/env perl
# Copyright (c) 2013-, Simon Lundström <simlu@su.se>, IT Services, Stockholm University
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.
#
# Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# Neither the name of Stockholm University nor the names of its contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
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
foreach my $i (keys %{$res->{indices}}) {
  if ($res->{indices}->{$i}->{status} eq $ES_STATUS_CRITICAL) {
    foreach my $s (keys %{$res->{indices}->{$i}->{shards}}) {
      if ($res->{indices}->{$i}->{shards}->{$s}->{status} eq $ES_STATUS_CRITICAL) {
        push @{$indices_with_issues->{$i}}, $s;
      }
    }
  }
}

# Create an joined error string for all indexes and shards
if ($indices_with_issues) {
  my @indices_error_string;
  foreach my $i (keys %$indices_with_issues) {
    push @indices_error_string, "index $i shard(s) ".pretty_join($indices_with_issues->{$i});
  }
  check_status($ES_STATUS_CRITICAL, join(", ", @indices_error_string));
}

($code, my $message) = $np->check_messages(join => ", ");
$np->nagios_exit($code, $message);
